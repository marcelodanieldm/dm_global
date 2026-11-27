-- RF-03 Gestión de reservas por WhatsApp (fase 2).
-- Agenda propia en Postgres. Si el cliente usa Odoo o Google Calendar, un workflow sincroniza
-- bookings hacia/desde allá; el motor siempre consulta estas tablas (rápido y sin depender de la API).
-- Se activa por cliente con tenants.settings.features.rf03 = true.

CREATE TABLE IF NOT EXISTS services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name VARCHAR(100) NOT NULL,
  description VARCHAR(200),
  duration_min INTEGER NOT NULL DEFAULT 30 CHECK (duration_min BETWEEN 5 AND 480),
  price NUMERIC(12, 2),
  currency VARCHAR(3) DEFAULT 'ARS',
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Franjas de atención por día de la semana (0 = domingo). service_id NULL = vale para todos los servicios
CREATE TABLE IF NOT EXISTS availability_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  service_id UUID REFERENCES services(id) ON DELETE CASCADE,
  weekday SMALLINT NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  start_time TIME NOT NULL,
  end_time TIME NOT NULL CHECK (end_time > start_time),
  slot_min INTEGER NOT NULL DEFAULT 30 CHECK (slot_min BETWEEN 5 AND 480),
  capacity INTEGER NOT NULL DEFAULT 1 CHECK (capacity >= 1)
);

-- Feriados, vacaciones o días sin atención
CREATE TABLE IF NOT EXISTS closed_dates (
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  day DATE NOT NULL,
  reason VARCHAR(100),
  PRIMARY KEY (tenant_id, day)
);

CREATE TABLE IF NOT EXISTS bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  service_id UUID NOT NULL REFERENCES services(id),
  phone VARCHAR(50) NOT NULL,
  customer_name VARCHAR(150) NOT NULL,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'cancelled', 'attended', 'no_show')),
  source VARCHAR(20) NOT NULL DEFAULT 'whatsapp',
  external_ref TEXT,                 -- id del evento en Odoo / Google Calendar, si se sincroniza
  reminder_sent_at TIMESTAMPTZ,      -- lo usa RF-09
  cancelled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS bookings_tenant_time_idx ON bookings (tenant_id, starts_at) WHERE status = 'confirmed';

-- Horarios libres de un servicio en un día (hora local del cliente)
CREATE OR REPLACE FUNCTION bot_rf03_free_slots(p_tenant UUID, p_service UUID, p_day DATE, p_tz TEXT, p_min_notice INTERVAL DEFAULT '2 hours')
RETURNS TABLE (slot TIMESTAMPTZ) LANGUAGE sql STABLE AS $$
  SELECT DISTINCT s.slot
  FROM services sv
  JOIN availability_rules r ON r.tenant_id = sv.tenant_id AND (r.service_id IS NULL OR r.service_id = sv.id)
       AND r.weekday = extract(dow FROM p_day)::int
  CROSS JOIN LATERAL generate_series(
       (p_day + r.start_time) AT TIME ZONE p_tz,
       (p_day + r.end_time) AT TIME ZONE p_tz - make_interval(mins => sv.duration_min),
       make_interval(mins => r.slot_min)) AS s(slot)
  WHERE sv.id = p_service AND sv.tenant_id = p_tenant AND sv.is_active
    AND NOT EXISTS (SELECT 1 FROM closed_dates cd WHERE cd.tenant_id = p_tenant AND cd.day = p_day)
    AND s.slot >= NOW() + p_min_notice
    AND (SELECT count(*) FROM bookings b
          WHERE b.tenant_id = p_tenant AND b.status = 'confirmed'
            AND b.starts_at < s.slot + make_interval(mins => sv.duration_min) AND b.ends_at > s.slot) < r.capacity
  ORDER BY s.slot
$$;

CREATE OR REPLACE FUNCTION bot_day_label(d DATE) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT (ARRAY['Dom', 'Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb'])[extract(dow FROM d)::int + 1] || ' ' || to_char(d, 'DD/MM')
$$;

-- Crea la reserva volviendo a validar el horario bajo un lock (dos personas no pueden tomar el mismo turno)
CREATE OR REPLACE FUNCTION bot_rf03_book(p_tenant UUID, p_service UUID, p_phone TEXT, p_name TEXT, p_slot TIMESTAMPTZ, p_tz TEXT, p_source TEXT DEFAULT 'whatsapp')
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID; v_dur INTEGER;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text, 3));
  IF NOT EXISTS (SELECT 1 FROM bot_rf03_free_slots(p_tenant, p_service, (p_slot AT TIME ZONE p_tz)::date, p_tz, '0 minutes') f
                  WHERE f.slot = p_slot) THEN
    RETURN NULL;
  END IF;
  SELECT duration_min INTO v_dur FROM services WHERE id = p_service;
  INSERT INTO bookings (tenant_id, service_id, phone, customer_name, starts_at, ends_at, source)
  VALUES (p_tenant, p_service, p_phone, left(p_name, 150), p_slot, p_slot + make_interval(mins => v_dur), p_source)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Paso: lista de días con lugar (próximos 21 días, hasta 10)
CREATE OR REPLACE FUNCTION bot_rf03_ask_day(ctx JSONB, p_service UUID, p_data JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_t UUID := (ctx->>'tenant_id')::uuid; v_tz TEXT := ctx #>> '{settings,timezone}'; v_rows JSONB; sv RECORD;
BEGIN
  SELECT * INTO sv FROM services WHERE id = p_service;
  SELECT jsonb_agg(r ORDER BY d) INTO v_rows FROM (
    SELECT d, jsonb_build_object('id', 'd:' || d::text, 'title', bot_day_label(d), 'description', n || ' horarios libres') AS r
      FROM (SELECT g::date AS d, (SELECT count(*) FROM bot_rf03_free_slots(v_t, p_service, g::date, v_tz)) AS n
              FROM generate_series((NOW() AT TIME ZONE v_tz)::date, (NOW() AT TIME ZONE v_tz)::date + 21, '1 day') g) x
     WHERE n > 0 ORDER BY d LIMIT 10) y;
  IF v_rows IS NULL THEN
    PERFORM bot_conv_clear(v_t, ctx->>'from');
    RETURN bot_reply('booking_flow', jsonb_build_array(bot_msg_text(
      'Por ahora no hay turnos libres para ' || sv.name || ' en las próximas tres semanas. ¿Querés que un asesor te contacte? Escribí "asesor".')));
  END IF;
  PERFORM bot_conv_set(v_t, ctx->>'from', 'booking_day', p_data || jsonb_build_object('service_id', p_service, 'options', v_rows));
  RETURN bot_reply('booking_flow', jsonb_build_array(bot_msg_list(
    sv.name || ' (' || sv.duration_min || ' min). ¿Qué día te queda bien?', 'Elegir día', v_rows)));
END $$;

CREATE OR REPLACE FUNCTION bot_rf03_start(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_t UUID := (ctx->>'tenant_id')::uuid; v_rows JSONB; v_n INTEGER; v_only UUID;
BEGIN
  IF NOT (ctx->>'msg') ~ '(^| )(turno|turnos|reserva|reservar|reservas|agendar|agenda|cita|sacar turno|pedir turno|appointment)( |$)' THEN
    RETURN NULL;
  END IF;
  SELECT count(*), min(id::text)::uuid INTO v_n, v_only FROM services WHERE tenant_id = v_t AND is_active;
  IF v_n = 0 THEN RETURN NULL; END IF;
  IF v_n = 1 THEN RETURN bot_rf03_ask_day(ctx, v_only, '{}'); END IF;
  SELECT jsonb_agg(jsonb_build_object('id', 's:' || id, 'title', name,
           'description', coalesce(description, duration_min || ' min' ||
                                   CASE WHEN price IS NOT NULL THEN ' · ' || bot_money(price, currency) ELSE '' END))
           ORDER BY sort_order, name)
    INTO v_rows FROM (SELECT * FROM services WHERE tenant_id = v_t AND is_active ORDER BY sort_order, name LIMIT 10) s;
  PERFORM bot_conv_set(v_t, ctx->>'from', 'booking_service', jsonb_build_object('options', v_rows));
  RETURN bot_reply('booking_flow', jsonb_build_array(bot_msg_list('¡Dale! ¿Qué servicio querés reservar?', 'Ver servicios', v_rows)));
END $$;

CREATE OR REPLACE FUNCTION bot_rf03_step(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_t UUID := (ctx->>'tenant_id')::uuid; v_from TEXT := ctx->>'from'; v_tz TEXT := ctx #>> '{settings,timezone}';
  v_state TEXT := ctx->>'state'; v_data JSONB := coalesce(ctx->'data', '{}'); v_pick TEXT; v_rows JSONB;
  v_day DATE; v_slot TIMESTAMPTZ; v_name TEXT; v_id UUID; sv RECORD; v_when TEXT;
BEGIN
  v_pick := bot_pick(ctx, v_data->'options');

  IF v_state = 'booking_service' THEN
    IF v_pick IS NULL THEN
      RETURN bot_reply('booking_flow', jsonb_build_array(bot_msg_text('No te entendí. Elegí un servicio de la lista o escribí su número:' || chr(10) || bot_options_text(v_data->'options'))));
    END IF;
    RETURN bot_rf03_ask_day(ctx, substr(v_pick, 3)::uuid, '{}');

  ELSIF v_state = 'booking_day' THEN
    IF v_pick IS NULL THEN
      RETURN bot_reply('booking_flow', jsonb_build_array(bot_msg_text('Elegí un día de la lista o escribí su número:' || chr(10) || bot_options_text(v_data->'options'))));
    END IF;
    v_day := substr(v_pick, 3)::date;
    SELECT jsonb_agg(jsonb_build_object('id', 't:' || to_char(slot AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI"Z"'),
                                        'title', to_char(slot AT TIME ZONE v_tz, 'HH24:MI') || ' h') ORDER BY slot)
      INTO v_rows FROM (SELECT slot FROM bot_rf03_free_slots(v_t, (v_data->>'service_id')::uuid, v_day, v_tz) LIMIT 10) s;
    IF v_rows IS NULL THEN
      RETURN bot_rf03_ask_day(ctx, (v_data->>'service_id')::uuid, v_data - 'options');
    END IF;
    PERFORM bot_conv_set(v_t, v_from, 'booking_slot', (v_data - 'options') || jsonb_build_object('day', v_day, 'options', v_rows));
    RETURN bot_reply('booking_flow', jsonb_build_array(bot_msg_list(bot_day_label(v_day) || ': ¿a qué hora?', 'Elegir horario', v_rows)));

  ELSIF v_state = 'booking_slot' THEN
    IF v_pick IS NULL THEN
      RETURN bot_reply('booking_flow', jsonb_build_array(bot_msg_text('Elegí un horario de la lista o escribí su número:' || chr(10) || bot_options_text(v_data->'options'))));
    END IF;
    v_slot := substr(v_pick, 3)::timestamptz;
    v_data := (v_data - 'options') || jsonb_build_object('slot', v_slot);
    IF coalesce(ctx->>'contact_name', v_data->>'name') IS NULL THEN
      PERFORM bot_conv_set(v_t, v_from, 'booking_name', v_data);
      RETURN bot_reply('booking_flow', jsonb_build_array(bot_msg_text('¿A nombre de quién hago la reserva?')));
    END IF;
    v_data := v_data || jsonb_build_object('name', coalesce(v_data->>'name', ctx->>'contact_name'));
    v_state := 'booking_name_done';
  END IF;

  IF v_state = 'booking_name' THEN
    v_data := v_data || jsonb_build_object('name', left(trim(ctx->>'raw'), 150));
    v_state := 'booking_name_done';
  END IF;

  IF v_state = 'booking_name_done' THEN
    SELECT * INTO sv FROM services WHERE id = (v_data->>'service_id')::uuid;
    v_when := bot_day_label(((v_data->>'slot')::timestamptz AT TIME ZONE v_tz)::date) || ' a las ' ||
              to_char((v_data->>'slot')::timestamptz AT TIME ZONE v_tz, 'HH24:MI') || ' h';
    PERFORM bot_conv_set(v_t, v_from, 'booking_confirm', v_data || jsonb_build_object('when', v_when));
    RETURN bot_reply('booking_flow', jsonb_build_array(bot_msg_buttons(
      'Reviso tu reserva:' || chr(10) || '• ' || sv.name || chr(10) || '• ' || v_when || chr(10) || '• A nombre de ' || (v_data->>'name') || chr(10) || '¿La confirmo?',
      '[{"id":"bk:confirm","title":"Confirmar"},{"id":"bk:change","title":"Cambiar horario"}]'::jsonb)));

  ELSIF v_state = 'booking_confirm' THEN
    IF ctx->>'reply_id' = 'bk:change' OR (ctx->>'reply_id' IS NULL AND bot_is_no(ctx->>'raw')) THEN
      RETURN bot_rf03_ask_day(ctx, (v_data->>'service_id')::uuid, jsonb_strip_nulls(jsonb_build_object('name', v_data->>'name', 'order_id', v_data->>'order_id')));
    ELSIF ctx->>'reply_id' = 'bk:confirm' OR bot_is_yes(ctx->>'raw') THEN
      v_id := bot_rf03_book(v_t, (v_data->>'service_id')::uuid, v_from, v_data->>'name', (v_data->>'slot')::timestamptz, v_tz, ctx->>'channel');
      IF v_id IS NULL THEN
        v_rows := bot_rf03_ask_day(ctx, (v_data->>'service_id')::uuid, jsonb_strip_nulls(jsonb_build_object('name', v_data->>'name', 'order_id', v_data->>'order_id')));
        RETURN v_rows || jsonb_build_object('messages',
          jsonb_build_array(bot_msg_text('Uy, ese horario se acaba de ocupar. Elegí otro, por favor.')) || (v_rows->'messages'));
      END IF;
      SELECT * INTO sv FROM services WHERE id = (v_data->>'service_id')::uuid;
      PERFORM bot_conv_clear(v_t, v_from);
      IF v_data ? 'order_id' THEN  -- turno de un servicio ya pagado (recorrido de contratación)
        UPDATE service_orders SET booking_id = v_id WHERE id = (v_data->>'order_id')::uuid AND tenant_id = v_t AND phone = v_from;
      END IF;
      RETURN bot_reply('booking_created',
        jsonb_build_array(bot_msg_text('✅ ¡Listo, ' || (v_data->>'name') || '! Tu reserva quedó confirmada:' || chr(10) ||
                                       '• ' || sv.name || chr(10) || '• ' || (v_data->>'when') || chr(10) ||
                                       'Te vamos a mandar un recordatorio antes del turno.')),
        jsonb_build_array(jsonb_build_object('type', 'booking_created', 'booking_id', v_id,
          'text', '📅 Nueva reserva (' || (ctx->>'tenant_name') || ')' || chr(10) || sv.name || ' · ' || (v_data->>'when') || chr(10) ||
                  'Cliente: ' || (v_data->>'name') || ' · +' || v_from)));
    END IF;
    RETURN bot_reply('booking_flow', jsonb_build_array(bot_msg_buttons('¿Confirmo la reserva?',
      '[{"id":"bk:confirm","title":"Confirmar"},{"id":"bk:change","title":"Cambiar horario"}]'::jsonb)));
  END IF;
  RETURN NULL;
END $$;
