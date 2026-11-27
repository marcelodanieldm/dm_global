-- Fase 4: POST-VENTA. RF-09 recordatorio interactivo de reserva, RF-10 modificar o anular reserva,
-- RF-11 estado de pedido y ticket de soporte. Se activan con tenants.settings.features.rfNN = true.

ALTER TABLE bookings ADD COLUMN IF NOT EXISTS customer_confirmed_at TIMESTAMPTZ;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancel_reason TEXT;

CREATE OR REPLACE FUNCTION bot_booking_when(p TIMESTAMPTZ, p_tz TEXT) RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT bot_day_label((p AT TIME ZONE p_tz)::date) || ' a las ' || to_char(p AT TIME ZONE p_tz, 'HH24:MI') || ' h'
$$;

-- ---------- RF-09: recordatorio de reserva ----------
-- Devuelve un mensaje por reserva a recordar (settings.rf09.hours_before, 24 por defecto) y la marca como recordada.
-- Con settings.rf09.template usa la plantilla aprobada por Meta ({{1}} nombre, {{2}} servicio, {{3}} fecha y hora,
-- botones de respuesta rápida 0 Confirmar, 1 Modificar, 2 Anular). Sin plantilla manda botones interactivos
-- (solo llegan si el cliente escribió en las últimas 24 h; sirve para probar).
CREATE OR REPLACE FUNCTION bot_rf09_due() RETURNS SETOF JSONB LANGUAGE plpgsql AS $$
DECLARE b RECORD; v_when TEXT; v_msg JSONB; v_tpl TEXT; v_t JSONB;
BEGIN
  FOR b IN
    SELECT bk.*, sv.name AS service_name, t.name AS tenant_name, t.settings
      FROM bookings bk JOIN services sv ON sv.id = bk.service_id JOIN tenants t ON t.id = bk.tenant_id
     WHERE bk.status = 'confirmed' AND bk.reminder_sent_at IS NULL AND t.is_active
       AND coalesce((t.settings #>> '{features,rf09}')::boolean, false)
       AND bk.starts_at > NOW() + INTERVAL '1 hour'
       AND bk.starts_at <= NOW() + make_interval(hours => coalesce((t.settings #>> '{rf09,hours_before}')::int, 24))
       AND bk.created_at < NOW() - INTERVAL '30 minutes'
     ORDER BY bk.starts_at
     FOR UPDATE OF bk SKIP LOCKED
  LOOP
    v_when := bot_booking_when(b.starts_at, coalesce(b.settings->>'timezone', 'America/Argentina/Buenos_Aires'));
    v_tpl := nullif(b.settings #>> '{rf09,template}', '');
    IF v_tpl IS NOT NULL THEN
      v_msg := jsonb_build_object('type', 'template', 'template', jsonb_build_object(
        'name', v_tpl, 'language', jsonb_build_object('code', coalesce(b.settings #>> '{rf09,lang}', 'es_AR')),
        'components', jsonb_build_array(
          jsonb_build_object('type', 'body', 'parameters', jsonb_build_array(
            jsonb_build_object('type', 'text', 'text', b.customer_name),
            jsonb_build_object('type', 'text', 'text', b.service_name),
            jsonb_build_object('type', 'text', 'text', v_when))),
          jsonb_build_object('type', 'button', 'sub_type', 'quick_reply', 'index', '0',
            'parameters', jsonb_build_array(jsonb_build_object('type', 'payload', 'payload', 'rm:confirm:' || b.id))),
          jsonb_build_object('type', 'button', 'sub_type', 'quick_reply', 'index', '1',
            'parameters', jsonb_build_array(jsonb_build_object('type', 'payload', 'payload', 'rm:change:' || b.id))),
          jsonb_build_object('type', 'button', 'sub_type', 'quick_reply', 'index', '2',
            'parameters', jsonb_build_array(jsonb_build_object('type', 'payload', 'payload', 'rm:cancel:' || b.id))))));
    ELSE
      v_msg := bot_msg_buttons('Hola ' || b.customer_name || ', te recordamos tu turno en ' || b.tenant_name || ':' || chr(10) ||
                               '• ' || b.service_name || chr(10) || '• ' || v_when || chr(10) || '¿Nos confirmás tu asistencia?',
        jsonb_build_array(jsonb_build_object('id', 'rm:confirm:' || b.id, 'title', 'Confirmar'),
                          jsonb_build_object('id', 'rm:change:' || b.id, 'title', 'Modificar'),
                          jsonb_build_object('id', 'rm:cancel:' || b.id, 'title', 'Anular')));
    END IF;
    v_t := bot_wa_target(b.tenant_id, b.phone, v_msg);
    UPDATE bookings SET reminder_sent_at = NOW() WHERE id = b.id;
    IF v_t IS NOT NULL THEN RETURN NEXT v_t || jsonb_build_object('booking_id', b.id); END IF;
  END LOOP;
END $$;

-- ---------- RF-10: modificar o anular una reserva ----------
CREATE OR REPLACE FUNCTION bot_rf10_cancel_booking(p_id UUID, p_reason TEXT) RETURNS BOOLEAN LANGUAGE sql AS $$
  WITH u AS (UPDATE bookings SET status = 'cancelled', cancelled_at = NOW(), cancel_reason = p_reason
              WHERE id = p_id AND status = 'confirmed' RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM u)
$$;

CREATE OR REPLACE FUNCTION bot_rf10_start(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_t UUID := (ctx->>'tenant_id')::uuid; v_from TEXT := ctx->>'from'; v_tz TEXT := ctx #>> '{settings,timezone}';
  v_action TEXT; v_id UUID; b RECORD; v_when TEXT; r JSONB;
BEGIN
  IF (ctx->>'reply_id') ~ '^rm:(confirm|change|cancel):[0-9a-f-]{36}$' THEN
    v_action := split_part(ctx->>'reply_id', ':', 2);
    v_id := split_part(ctx->>'reply_id', ':', 3)::uuid;
  ELSIF (ctx->>'msg') ~ '(cancelar|anular|suspender|dar de baja) (mi |el |la )?(turno|reserva|cita)' THEN v_action := 'cancel';
  ELSIF (ctx->>'msg') ~ '(cambiar|modificar|reprogramar|mover|pasar|correr) (mi |el |la )?(turno|reserva|cita)' THEN v_action := 'change';
  ELSIF (ctx->>'msg') ~ '(confirmo|confirmar) (mi |el |la )?(turno|reserva|cita|asistencia)' THEN v_action := 'confirm';
  ELSE RETURN NULL;
  END IF;

  -- La reserva tiene que ser de este número, de este cliente, futura y vigente
  SELECT bk.*, sv.name AS service_name INTO b FROM bookings bk JOIN services sv ON sv.id = bk.service_id
   WHERE bk.tenant_id = v_t AND bk.phone = v_from AND bk.status = 'confirmed' AND bk.starts_at > NOW()
     AND (v_id IS NULL OR bk.id = v_id)
   ORDER BY bk.starts_at LIMIT 1;
  IF NOT FOUND THEN
    RETURN bot_reply('rf10_none', jsonb_build_array(bot_msg_text(CASE WHEN v_id IS NULL
      THEN 'No encontré turnos próximos a tu nombre. Si querés sacar uno, escribí "turno".'
      ELSE 'Ese turno ya no está vigente (puede que ya lo hayas cambiado o anulado). Si querés uno nuevo, escribí "turno".' END)));
  END IF;
  v_when := bot_booking_when(b.starts_at, v_tz);

  IF v_action = 'confirm' THEN
    UPDATE bookings SET customer_confirmed_at = NOW() WHERE id = b.id;
    RETURN bot_reply('rf10_confirmed', jsonb_build_array(bot_msg_text('¡Gracias, ' || b.customer_name || '! Te esperamos el ' || v_when || '.')));
  ELSIF v_action = 'cancel' THEN
    PERFORM bot_conv_set(v_t, v_from, 'rbk_cancel', jsonb_build_object('booking_id', b.id, 'when', v_when, 'service', b.service_name));
    RETURN bot_reply('rf10_flow', jsonb_build_array(bot_msg_buttons(
      '¿Seguro que querés anular tu turno de ' || b.service_name || ' del ' || v_when || '?',
      '[{"id":"rbk:yes","title":"Sí, anular"},{"id":"rbk:no","title":"No, lo mantengo"}]'::jsonb)));
  END IF;

  -- Modificar: se libera el horario anterior y se vuelve a elegir día y hora (RF-03)
  PERFORM bot_rf10_cancel_booking(b.id, 'reprogramado por el cliente');
  r := bot_rf03_ask_day(ctx, b.service_id, jsonb_build_object('name', b.customer_name, 'rescheduled_from', b.id));
  RETURN r || jsonb_build_object('status', 'rf10_reschedule',
    'messages', jsonb_build_array(bot_msg_text('Listo, liberé tu turno del ' || v_when || '. Elegí el nuevo día y horario.')) || (r->'messages'),
    'notify', jsonb_build_array(jsonb_build_object('type', 'booking_cancelled', 'booking_id', b.id,
      'text', '🔁 Reprogramación (' || (ctx->>'tenant_name') || ')' || chr(10) || 'Se liberó: ' || b.service_name || ' · ' || v_when || chr(10) ||
              'Cliente: ' || b.customer_name || ' · +' || v_from || ' (está eligiendo un nuevo horario)')));
END $$;

CREATE OR REPLACE FUNCTION bot_rf10_step(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_t UUID := (ctx->>'tenant_id')::uuid; v_from TEXT := ctx->>'from'; v_data JSONB := coalesce(ctx->'data', '{}');
BEGIN
  IF ctx->>'state' <> 'rbk_cancel' THEN RETURN NULL; END IF;
  IF ctx->>'reply_id' = 'rbk:yes' OR (ctx->>'reply_id' IS NULL AND bot_is_yes(ctx->>'raw')) THEN
    PERFORM bot_conv_clear(v_t, v_from);
    IF NOT bot_rf10_cancel_booking((v_data->>'booking_id')::uuid, 'anulado por el cliente') THEN
      RETURN bot_reply('rf10_none', jsonb_build_array(bot_msg_text('Ese turno ya no estaba vigente.')));
    END IF;
    RETURN bot_reply('rf10_cancelled',
      jsonb_build_array(bot_msg_text('Listo, anulé tu turno de ' || (v_data->>'service') || ' del ' || (v_data->>'when') ||
                                     '. Si querés sacar otro, escribí "turno".')),
      jsonb_build_array(jsonb_build_object('type', 'booking_cancelled', 'booking_id', v_data->>'booking_id',
        'text', '❌ Turno anulado (' || (ctx->>'tenant_name') || ')' || chr(10) || (v_data->>'service') || ' · ' || (v_data->>'when') || chr(10) ||
                'Cliente: +' || v_from)));
  ELSIF ctx->>'reply_id' = 'rbk:no' OR (ctx->>'reply_id' IS NULL AND bot_is_no(ctx->>'raw')) THEN
    PERFORM bot_conv_clear(v_t, v_from);
    RETURN bot_reply('rf10_kept', jsonb_build_array(bot_msg_text('Perfecto, tu turno del ' || (v_data->>'when') || ' sigue en pie.')));
  END IF;
  RETURN bot_reply('rf10_flow', jsonb_build_array(bot_msg_buttons('¿Anulo el turno del ' || (v_data->>'when') || '?',
    '[{"id":"rbk:yes","title":"Sí, anular"},{"id":"rbk:no","title":"No, lo mantengo"}]'::jsonb)));
END $$;

-- ---------- RF-11: pedidos y soporte ----------
CREATE TABLE IF NOT EXISTS orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  source VARCHAR(20) NOT NULL DEFAULT 'generic',
  external_id TEXT NOT NULL,
  number TEXT NOT NULL,             -- el número que ve el cliente
  customer_name VARCHAR(150),
  email VARCHAR(200),
  phone VARCHAR(50),
  tax_id VARCHAR(20),
  status VARCHAR(30),               -- open, closed, cancelled
  payment_status VARCHAR(30),       -- pending, paid, refunded...
  shipping_status VARCHAR(30),      -- unpacked, fulfilled, shipped, delivered, pickup_ready...
  tracking_number TEXT,
  tracking_url TEXT,
  total NUMERIC(12, 2),
  currency VARCHAR(3) DEFAULT 'ARS',
  items JSONB NOT NULL DEFAULT '[]'::jsonb,
  ordered_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source, external_id)
);
CREATE INDEX IF NOT EXISTS orders_phone_idx ON orders (tenant_id, phone);
CREATE INDEX IF NOT EXISTS orders_number_idx ON orders (tenant_id, number);

CREATE TABLE IF NOT EXISTS support_tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  number SERIAL,
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone VARCHAR(50) NOT NULL,
  order_id UUID REFERENCES orders(id) ON DELETE SET NULL,
  description TEXT NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'closed')),
  external_ref TEXT,                -- id del ticket en Odoo Helpdesk / WordPress, si se sincroniza
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Pedido normalizado: {source, external_id, number, name, email, phone, tax_id, status, payment_status, shipping_status,
--                      tracking_number, tracking_url, total, currency, items, created_at}
CREATE OR REPLACE FUNCTION bot_rf11_upsert_order(p_tenant UUID, o JSONB) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  IF coalesce(o->>'external_id', o->>'number', '') = '' THEN RETURN NULL; END IF;
  INSERT INTO orders AS x (tenant_id, source, external_id, number, customer_name, email, phone, tax_id, status, payment_status,
                           shipping_status, tracking_number, tracking_url, total, currency, items, ordered_at, updated_at)
  VALUES (p_tenant, coalesce(nullif(o->>'source', ''), 'generic'), coalesce(nullif(o->>'external_id', ''), o->>'number'),
          coalesce(nullif(o->>'number', ''), o->>'external_id'), left(o->>'name', 150), lower(nullif(o->>'email', '')),
          nullif(regexp_replace(coalesce(o->>'phone', ''), '\D', '', 'g'), ''), nullif(regexp_replace(coalesce(o->>'tax_id', ''), '\D', '', 'g'), ''),
          lower(nullif(o->>'status', '')), lower(nullif(o->>'payment_status', '')), lower(nullif(o->>'shipping_status', '')),
          nullif(o->>'tracking_number', ''), nullif(o->>'tracking_url', ''), nullif(o->>'total', '')::numeric,
          coalesce(nullif(o->>'currency', ''), 'ARS'), CASE WHEN jsonb_typeof(o->'items') = 'array' THEN o->'items' ELSE '[]' END, nullif(o->>'created_at', '')::timestamptz, NOW())
  ON CONFLICT (tenant_id, source, external_id) DO UPDATE SET
    number = EXCLUDED.number, customer_name = coalesce(EXCLUDED.customer_name, x.customer_name), email = coalesce(EXCLUDED.email, x.email),
    phone = coalesce(EXCLUDED.phone, x.phone), tax_id = coalesce(EXCLUDED.tax_id, x.tax_id), status = EXCLUDED.status,
    payment_status = EXCLUDED.payment_status, shipping_status = EXCLUDED.shipping_status,
    tracking_number = coalesce(EXCLUDED.tracking_number, x.tracking_number), tracking_url = coalesce(EXCLUDED.tracking_url, x.tracking_url),
    total = EXCLUDED.total, currency = EXCLUDED.currency, items = EXCLUDED.items, ordered_at = coalesce(EXCLUDED.ordered_at, x.ordered_at),
    updated_at = NOW()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Webhook genérico: POST /webhook/rf11-pedido?key=<hook_secret> con un pedido normalizado o {"orders": [...]}
CREATE OR REPLACE FUNCTION bot_rf11_ingest(p_key TEXT, p_body JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_t UUID := bot_tenant_by_hook(p_key); v_n INTEGER;
BEGIN
  IF v_t IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'clave inválida'); END IF;
  SELECT count(bot_rf11_upsert_order(v_t, o)) INTO v_n
    FROM jsonb_array_elements(CASE WHEN p_body ? 'orders' THEN p_body->'orders' ELSE jsonb_build_array(p_body) END) o;
  RETURN jsonb_build_object('ok', true, 'orders', v_n);
END $$;

-- Datos para pedir un pedido a Tiendanube cuando llega su webhook ({store_id, event, id})
CREATE OR REPLACE FUNCTION bot_hook_context(p_key TEXT, p_provider TEXT) RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('tenant_id', t.id, 'store_id', ci.store_id, 'access_token', ci.access_token,
                            'user_agent', coalesce(ci.config->>'user_agent', 'Chatbot DM Global'))
    FROM tenants t LEFT JOIN commerce_integrations ci ON ci.tenant_id = t.id AND ci.provider = p_provider AND ci.is_active
   WHERE t.id = bot_tenant_by_hook(p_key)
$$;

CREATE OR REPLACE FUNCTION bot_rf11_label(kind TEXT, v TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE kind
    WHEN 'payment' THEN CASE v WHEN 'pending' THEN 'pendiente' WHEN 'authorized' THEN 'autorizado' WHEN 'paid' THEN 'acreditado'
                               WHEN 'refunded' THEN 'reintegrado' WHEN 'voided' THEN 'anulado' WHEN 'abandoned' THEN 'no realizado' ELSE v END
    WHEN 'shipping' THEN CASE v WHEN 'unpacked' THEN 'lo estamos preparando' WHEN 'unfulfilled' THEN 'lo estamos preparando'
                                WHEN 'packed' THEN 'listo para despachar' WHEN 'fulfilled' THEN 'despachado, en camino'
                                WHEN 'shipped' THEN 'en camino' WHEN 'delivered' THEN 'entregado' WHEN 'pickup_ready' THEN 'listo para retirar' ELSE v END
  END
$$;

-- Muestra un pedido: estado, link de seguimiento y botones de ayuda
CREATE OR REPLACE FUNCTION bot_rf11_show(ctx JSONB, p_order UUID) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE o RECORD; v_txt TEXT; v_msgs JSONB;
BEGIN
  SELECT * INTO o FROM orders WHERE id = p_order;
  v_txt := '📦 Pedido #' || o.number || coalesce(' (' || bot_money(o.total, o.currency) || ')', '') || chr(10) ||
    CASE WHEN o.status = 'cancelled' THEN '• Estado: cancelado'
         ELSE coalesce('• Pago: ' || bot_rf11_label('payment', o.payment_status) || chr(10), '') ||
              coalesce('• Envío: ' || bot_rf11_label('shipping', o.shipping_status), '• Envío: todavía sin despachar') END ||
    coalesce(chr(10) || '• Código de seguimiento: ' || o.tracking_number, '');
  v_msgs := jsonb_build_array(bot_msg_text(v_txt));
  IF o.tracking_url IS NOT NULL AND coalesce(o.status, '') <> 'cancelled' THEN
    v_msgs := v_msgs || jsonb_build_object('type', 'interactive', 'interactive', jsonb_build_object('type', 'cta_url',
      'body', jsonb_build_object('text', 'Seguí tu envío en tiempo real:'),
      'action', jsonb_build_object('name', 'cta_url', 'parameters', jsonb_build_object('display_text', 'Ver seguimiento', 'url', o.tracking_url))));
  END IF;
  v_msgs := v_msgs || bot_msg_buttons('¿Necesitás algo más con este pedido?',
    '[{"id":"ord:help","title":"Necesito ayuda"},{"id":"ord:ok","title":"No, todo bien"}]'::jsonb);
  PERFORM bot_conv_set((ctx->>'tenant_id')::uuid, ctx->>'from', 'order_after', jsonb_build_object('order_id', o.id, 'number', o.number));
  RETURN bot_reply('rf11_order', v_msgs);
END $$;

CREATE OR REPLACE FUNCTION bot_rf11_ask_support(ctx JSONB, p_data JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
  PERFORM bot_conv_set((ctx->>'tenant_id')::uuid, ctx->>'from', 'support_desc', p_data);
  RETURN bot_reply('rf11_support', jsonb_build_array(bot_msg_text(
    'Contame en un mensaje qué pasó' || coalesce(' con el pedido #' || (p_data->>'number'), '') || ' y lo paso a un agente.')));
END $$;

CREATE OR REPLACE FUNCTION bot_rf11_start(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_t UUID := (ctx->>'tenant_id')::uuid; v_rows JSONB; v_n INTEGER; v_one UUID;
BEGIN
  IF (ctx->>'msg') ~ '(^| )(soporte|reclamo|reclamar|devolucion|devolver|garantia)( |$)'
     OR (ctx->>'msg') ~ '(problema|ayuda) con (mi |el |la )?(pedido|compra|producto|envio)' THEN
    RETURN bot_rf11_ask_support(ctx, '{}');
  END IF;
  IF NOT ((ctx->>'msg') ~ '(mi|mis|el|del) (pedido|pedidos|compra|envio|paquete|orden)'
          OR (ctx->>'msg') ~ '(^| )(seguimiento|tracking)( |$)' OR (ctx->>'msg') ~ '(donde esta|cuando llega|estado de)') THEN
    RETURN NULL;
  END IF;
  SELECT count(*), min(id::text)::uuid INTO v_n, v_one FROM orders
   WHERE tenant_id = v_t AND phone = ctx->>'from' AND coalesce(ordered_at, updated_at) > NOW() - INTERVAL '120 days';
  IF v_n = 1 THEN RETURN bot_rf11_show(ctx, v_one); END IF;
  IF v_n > 1 THEN
    SELECT jsonb_agg(jsonb_build_object('id', 'o:' || id, 'title', 'Pedido #' || number,
             'description', coalesce(to_char(ordered_at AT TIME ZONE (ctx #>> '{settings,timezone}'), 'DD/MM') || ' · ', '') ||
                            coalesce(bot_money(total, currency), '')) ORDER BY coalesce(ordered_at, updated_at) DESC)
      INTO v_rows FROM (SELECT * FROM orders WHERE tenant_id = v_t AND phone = ctx->>'from'
                         ORDER BY coalesce(ordered_at, updated_at) DESC LIMIT 10) x;
    PERFORM bot_conv_set(v_t, ctx->>'from', 'order_pick', jsonb_build_object('options', v_rows));
    RETURN bot_reply('rf11_flow', jsonb_build_array(bot_msg_list('Encontré estos pedidos a tu número. ¿Cuál querés ver?', 'Ver pedidos', v_rows)));
  END IF;
  PERFORM bot_conv_set(v_t, ctx->>'from', 'order_lookup', '{}');
  RETURN bot_reply('rf11_flow', jsonb_build_array(bot_msg_text('Te ayudo con tu pedido. ¿Me pasás el número de pedido? Lo encontrás en el email de confirmación de la compra.')));
END $$;

CREATE OR REPLACE FUNCTION bot_rf11_step(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_t UUID := (ctx->>'tenant_id')::uuid; v_from TEXT := ctx->>'from'; v_raw TEXT := trim(ctx->>'raw');
  v_state TEXT := ctx->>'state'; v_data JSONB := coalesce(ctx->'data', '{}'); v_pick TEXT; o RECORD; v_num TEXT; v_tries INTEGER;
  v_ticket RECORD;
BEGIN
  v_tries := coalesce((v_data->>'tries')::int, 0);
  IF v_state = 'order_pick' THEN
    v_pick := bot_pick(ctx, v_data->'options');
    IF v_pick IS NULL THEN
      RETURN bot_reply('rf11_flow', jsonb_build_array(bot_msg_text('Elegí un pedido de la lista o escribí su número:' || chr(10) || bot_options_text(v_data->'options'))));
    END IF;
    RETURN bot_rf11_show(ctx, substr(v_pick, 3)::uuid);

  ELSIF v_state = 'order_lookup' THEN
    v_num := regexp_replace(v_raw, '[^0-9A-Za-z-]', '', 'g');
    SELECT * INTO o FROM orders WHERE tenant_id = v_t AND (number = v_num OR number = ltrim(v_num, '0')) ORDER BY updated_at DESC LIMIT 1;
    IF NOT FOUND THEN
      IF v_tries >= 2 THEN
        PERFORM bot_conv_clear(v_t, v_from);
        RETURN bot_reply('rf11_notfound', jsonb_build_array(bot_msg_text('No encuentro ese pedido. Escribí "asesor" y una persona lo busca por vos.')));
      END IF;
      PERFORM bot_conv_set(v_t, v_from, 'order_lookup', jsonb_build_object('tries', v_tries + 1));
      RETURN bot_reply('rf11_flow', jsonb_build_array(bot_msg_text('No encontré un pedido con el número "' || left(v_raw, 30) || '". Revisalo y escribilo de nuevo, solo el número.')));
    END IF;
    IF o.phone = v_from THEN RETURN bot_rf11_show(ctx, o.id); END IF;
    -- El pedido no es de este número: se pide un segundo dato para no mostrar pedidos ajenos
    PERFORM bot_conv_set(v_t, v_from, 'order_verify', jsonb_build_object('order_id', o.id));
    RETURN bot_reply('rf11_flow', jsonb_build_array(bot_msg_text('Lo encontré. Para cuidar tus datos, confirmame el email o el DNI con el que hiciste la compra.')));

  ELSIF v_state = 'order_verify' THEN
    SELECT * INTO o FROM orders WHERE id = (v_data->>'order_id')::uuid;
    IF (o.email IS NOT NULL AND lower(v_raw) = o.email)
       OR (o.tax_id IS NOT NULL AND regexp_replace(v_raw, '\D', '', 'g') = o.tax_id) THEN
      RETURN bot_rf11_show(ctx, o.id);
    END IF;
    IF v_tries >= 2 THEN
      PERFORM bot_conv_clear(v_t, v_from);
      RETURN bot_reply('rf11_notfound', jsonb_build_array(bot_msg_text('Los datos no coinciden con el pedido. Escribí "asesor" y una persona te ayuda.')));
    END IF;
    PERFORM bot_conv_set(v_t, v_from, 'order_verify', v_data || jsonb_build_object('tries', v_tries + 1));
    RETURN bot_reply('rf11_flow', jsonb_build_array(bot_msg_text('Ese dato no coincide con el pedido. Probá con el email o el DNI de quien compró.')));

  ELSIF v_state = 'order_after' THEN
    IF ctx->>'reply_id' = 'ord:help' OR (ctx->>'reply_id' IS NULL AND (ctx->>'msg') ~ '^(ayuda|necesito ayuda|si|tengo un problema)') THEN
      RETURN bot_rf11_ask_support(ctx, v_data);
    ELSIF ctx->>'reply_id' = 'ord:ok' OR (ctx->>'reply_id' IS NULL AND (bot_is_no(v_raw) OR (ctx->>'msg') ~ '^(gracias|todo bien|listo)')) THEN
      PERFORM bot_conv_clear(v_t, v_from);
      RETURN bot_reply('rf11_done', jsonb_build_array(bot_msg_text('¡Genial! Cualquier cosa, escribime.')));
    END IF;
    RETURN NULL;

  ELSIF v_state = 'support_desc' THEN
    IF length(v_raw) < 5 THEN
      RETURN bot_reply('rf11_support', jsonb_build_array(bot_msg_text('Contame un poco más, así el agente ya sabe cómo ayudarte.')));
    END IF;
    INSERT INTO support_tickets (tenant_id, phone, order_id, description)
    VALUES (v_t, v_from, (v_data->>'order_id')::uuid, left(v_raw, 2000)) RETURNING * INTO v_ticket;
    INSERT INTO human_handovers (tenant_id, phone, message, reason) VALUES (v_t, v_from, left(v_raw, 2000), 'support_ticket');
    PERFORM bot_conv_clear(v_t, v_from);
    RETURN bot_reply('rf11_ticket',
      jsonb_build_array(bot_msg_text('Listo, abrí el ticket #' || v_ticket.number || '. Un agente te va a escribir por acá a la brevedad.')),
      jsonb_build_array(jsonb_build_object('type', 'ticket_created', 'ticket_id', v_ticket.id,
        'text', '🛟 Ticket #' || v_ticket.number || ' (' || (ctx->>'tenant_name') || ')' || chr(10) ||
                coalesce('Pedido #' || (v_data->>'number') || chr(10), '') || 'Cliente: +' || v_from || chr(10) || 'Mensaje: ' || left(v_raw, 400))));
  END IF;
  RETURN NULL;
END $$;
