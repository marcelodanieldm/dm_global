-- Recorrido del cliente para negocios de servicios: CONSULTAS → CONTRATACIÓN Y PAGO → POST VENTA.
-- Encadena los flujos existentes (RF-01 FAQs, RF-02 asesor, RF-03 turnos, RF-10, RF-11 soporte) y agrega:
--   * menú de inicio con tres caminos,
--   * compra de un servicio con pago único (Mercado Pago, Stripe o simulado) y turno después del pago,
--   * encuesta de satisfacción programada y "mis compras".
-- Se activa con tenants.settings.features.journey = true. Opciones en settings.journey:
--   {menu_text, survey_after_hours (2 tras el turno / 24 tras el pago), survey_template, survey_lang, review_url}

ALTER TABLE services ADD COLUMN IF NOT EXISTS bookable BOOLEAN NOT NULL DEFAULT TRUE;   -- después de pagar, ¿se agenda turno?
ALTER TABLE payment_events ADD COLUMN IF NOT EXISTS service_order_id UUID;

CREATE TABLE IF NOT EXISTS service_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  number SERIAL,
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  service_id UUID NOT NULL REFERENCES services(id),
  customer_id UUID NOT NULL REFERENCES customers(id),
  phone VARCHAR(50) NOT NULL,
  amount NUMERIC(12, 2) NOT NULL,
  currency VARCHAR(3) NOT NULL DEFAULT 'ARS',
  status VARCHAR(20) NOT NULL DEFAULT 'pending_payment'
         CHECK (status IN ('pending_payment', 'paid', 'completed', 'cancelled', 'refunded', 'expired')),
  provider VARCHAR(20),
  provider_ref TEXT,
  checkout_url TEXT,
  booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
  paid_at TIMESTAMPTZ,
  survey_sent_at TIMESTAMPTZ,
  rating SMALLINT CHECK (rating BETWEEN 1 AND 5),
  feedback TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS service_orders_phone_idx ON service_orders (tenant_id, phone);
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS service_order_id UUID REFERENCES service_orders(id) ON DELETE SET NULL;

-- ---------- etapa 1: menú y consultas ----------
CREATE OR REPLACE FUNCTION bot_journey_menu(ctx JSONB) RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT bot_reply('journey_menu', jsonb_build_array(bot_msg_buttons(
    coalesce(ctx #>> '{settings,journey,menu_text}',
             '¡Hola! Soy el asistente virtual de ' || (ctx->>'tenant_name') || '. ¿Qué querés hacer?'),
    '[{"id":"j:faq","title":"Hacer una consulta"},{"id":"j:hire","title":"Contratar"},{"id":"j:post","title":"Mis compras y ayuda"}]'::jsonb)))
$$;

-- ---------- etapa 2: contratación y pago ----------
CREATE OR REPLACE FUNCTION bot_journey_ask_service(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_t UUID := (ctx->>'tenant_id')::uuid; v_rows JSONB; v_n INTEGER; v_one UUID;
BEGIN
  SELECT count(*), min(id::text)::uuid INTO v_n, v_one FROM services WHERE tenant_id = v_t AND is_active AND price > 0;
  IF v_n = 0 THEN
    IF ctx->>'reply_id' IS NULL THEN RETURN NULL; END IF;  -- texto libre: que lo tome otro flujo (p. ej. RF-04 planes)
    RETURN bot_reply('journey_flow', jsonb_build_array(bot_msg_text('Por ahora no hay servicios para contratar por acá. Escribí "asesor" y te ayudamos.')));
  END IF;
  IF v_n = 1 THEN RETURN bot_journey_pick_service(ctx, v_one); END IF;
  SELECT jsonb_agg(jsonb_build_object('id', 'sv:' || id, 'title', name,
           'description', bot_money(price, currency) || coalesce(' · ' || description, '')) ORDER BY sort_order, name)
    INTO v_rows FROM (SELECT * FROM services WHERE tenant_id = v_t AND is_active AND price > 0 ORDER BY sort_order, name LIMIT 10) s;
  PERFORM bot_conv_set(v_t, ctx->>'from', 'j_service', jsonb_build_object('options', v_rows));
  RETURN bot_reply('journey_flow', jsonb_build_array(bot_msg_list('¿Qué servicio querés contratar?', 'Ver servicios', v_rows)));
END $$;

-- Con el servicio elegido: si ya conocemos al cliente, va directo a confirmar; si no, pide nombre y email
CREATE OR REPLACE FUNCTION bot_journey_pick_service(ctx JSONB, p_service UUID) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_t UUID := (ctx->>'tenant_id')::uuid; sv RECORD; cu RECORD; v_data JSONB;
BEGIN
  SELECT * INTO sv FROM services WHERE id = p_service AND tenant_id = v_t AND is_active;
  v_data := jsonb_build_object('service_id', sv.id, 'service', sv.name, 'price', bot_money(sv.price, sv.currency));
  SELECT * INTO cu FROM customers WHERE tenant_id = v_t AND phone = ctx->>'from';
  IF FOUND AND cu.email IS NOT NULL THEN
    RETURN bot_journey_confirm(ctx, v_data || jsonb_build_object('name', cu.name, 'email', cu.email));
  END IF;
  PERFORM bot_conv_set(v_t, ctx->>'from', 'j_name', v_data);
  RETURN bot_reply('journey_flow', jsonb_build_array(bot_msg_text(
    '*' || sv.name || '* · ' || bot_money(sv.price, sv.currency) || coalesce(chr(10) || sv.description, '') || chr(10) || chr(10) ||
    'Para emitir el comprobante necesito dos datos. Primero: ¿nombre y apellido?')));
END $$;

CREATE OR REPLACE FUNCTION bot_journey_confirm(ctx JSONB, p_data JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
  PERFORM bot_conv_set((ctx->>'tenant_id')::uuid, ctx->>'from', 'j_confirm', p_data);
  RETURN bot_reply('journey_flow', jsonb_build_array(bot_msg_buttons(
    'Reviso tu contratación:' || chr(10) || '• Servicio: ' || (p_data->>'service') || chr(10) || '• Precio: ' || (p_data->>'price') || chr(10) ||
    '• Titular: ' || (p_data->>'name') || chr(10) || '• Email: ' || (p_data->>'email') || chr(10) || '¿Te genero el link de pago?',
    '[{"id":"j:pay","title":"Sí, pagar"},{"id":"j:cancel","title":"Cancelar"}]'::jsonb)));
END $$;

-- ---------- etapa 3: post venta ----------
CREATE OR REPLACE FUNCTION bot_journey_status_label(p_status TEXT, p_booked BOOLEAN) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_status
    WHEN 'pending_payment' THEN 'esperando el pago'
    WHEN 'paid' THEN CASE WHEN p_booked THEN 'pagado, con turno' ELSE 'pagado' END
    WHEN 'completed' THEN 'realizado'
    WHEN 'cancelled' THEN 'cancelado' WHEN 'refunded' THEN 'reintegrado' ELSE 'vencido' END
$$;

CREATE OR REPLACE FUNCTION bot_journey_my_orders(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_t UUID := (ctx->>'tenant_id')::uuid; v_rows JSONB;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('id', 'jo:' || o.id, 'title', '#' || o.number || ' ' || sv.name,
           'description', bot_journey_status_label(o.status, o.booking_id IS NOT NULL) || ' · ' || to_char(o.created_at AT TIME ZONE (ctx #>> '{settings,timezone}'), 'DD/MM'))
           ORDER BY o.created_at DESC)
    INTO v_rows FROM (SELECT * FROM service_orders WHERE tenant_id = v_t AND phone = ctx->>'from' AND status <> 'expired'
                       ORDER BY created_at DESC LIMIT 9) o JOIN services sv ON sv.id = o.service_id;
  IF v_rows IS NULL THEN
    RETURN bot_reply('journey_post', jsonb_build_array(bot_msg_buttons('Todavía no tenés compras con este número. ¿Querés ver los servicios?',
      '[{"id":"j:hire","title":"Ver servicios"},{"id":"j:faq","title":"Hacer una consulta"}]'::jsonb)));
  END IF;
  v_rows := v_rows || '[{"id":"j:help","title":"Otra consulta","description":"Hablar con una persona"}]'::jsonb;
  PERFORM bot_conv_set(v_t, ctx->>'from', 'j_orders', jsonb_build_object('options', v_rows));
  RETURN bot_reply('journey_post', jsonb_build_array(bot_msg_list('Estas son tus compras. Elegí una para ver el detalle o pedir ayuda.', 'Mis compras', v_rows)));
END $$;

CREATE OR REPLACE FUNCTION bot_journey_show_order(ctx JSONB, p_order UUID) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE o RECORD; v_btn JSONB := '[]'; v_txt TEXT; v_tz TEXT := ctx #>> '{settings,timezone}';
BEGIN
  SELECT so.*, sv.name AS service_name, sv.bookable, b.starts_at, b.status AS booking_status
    INTO o FROM service_orders so JOIN services sv ON sv.id = so.service_id LEFT JOIN bookings b ON b.id = so.booking_id
   WHERE so.id = p_order AND so.tenant_id = (ctx->>'tenant_id')::uuid AND so.phone = ctx->>'from';
  IF NOT FOUND THEN RETURN bot_reply('journey_post', jsonb_build_array(bot_msg_text('No encontré esa compra.'))); END IF;
  v_txt := '🧾 Compra #' || o.number || chr(10) || '• ' || o.service_name || ' · ' || bot_money(o.amount, o.currency) || chr(10) ||
           '• Estado: ' || bot_journey_status_label(o.status, o.booking_id IS NOT NULL AND o.booking_status = 'confirmed') ||
           CASE WHEN o.starts_at IS NOT NULL AND o.booking_status = 'confirmed' THEN chr(10) || '• Turno: ' || bot_booking_when(o.starts_at, v_tz) ELSE '' END;
  IF o.status = 'pending_payment' AND o.checkout_url IS NOT NULL THEN
    v_btn := v_btn || jsonb_build_object('id', 'j:paylink:' || o.id, 'title', 'Ver link de pago');
  ELSIF o.status = 'paid' AND o.bookable AND (o.booking_id IS NULL OR o.booking_status <> 'confirmed') THEN
    v_btn := v_btn || jsonb_build_object('id', 'j:book:' || o.id, 'title', 'Elegir turno');
  END IF;
  v_btn := v_btn || jsonb_build_object('id', 'j:help:' || o.id, 'title', 'Necesito ayuda') || '[{"id":"j:ok","title":"Todo bien"}]'::jsonb;
  PERFORM bot_conv_clear((ctx->>'tenant_id')::uuid, ctx->>'from');
  RETURN bot_reply('journey_post', jsonb_build_array(bot_msg_buttons(v_txt, v_btn)));
END $$;

-- Respuesta a la encuesta: jr:<puntaje>:<compra>
CREATE OR REPLACE FUNCTION bot_journey_survey_answer(ctx JSONB, p_rating INTEGER, p_order UUID) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE o RECORD; v_url TEXT := ctx #>> '{settings,journey,review_url}';
BEGIN
  SELECT so.*, sv.name AS service_name INTO o FROM service_orders so JOIN services sv ON sv.id = so.service_id
   WHERE so.id = p_order AND so.tenant_id = (ctx->>'tenant_id')::uuid AND so.phone = ctx->>'from';
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE service_orders SET rating = p_rating, status = CASE WHEN status = 'paid' THEN 'completed' ELSE status END WHERE id = o.id;
  IF p_rating >= 4 THEN
    RETURN bot_reply('journey_survey', CASE WHEN v_url IS NOT NULL THEN
      jsonb_build_array(jsonb_build_object('type', 'interactive', 'interactive', jsonb_build_object('type', 'cta_url',
        'body', jsonb_build_object('text', '¡Qué bueno! Gracias por elegirnos. Si tenés un minuto, tu reseña nos ayuda muchísimo.'),
        'action', jsonb_build_object('name', 'cta_url', 'parameters', jsonb_build_object('display_text', 'Dejar reseña', 'url', v_url)))))
      ELSE jsonb_build_array(bot_msg_text('¡Qué bueno! Gracias por elegirnos. Cuando quieras volver, escribí "menú".')) END);
  ELSIF p_rating = 3 THEN
    PERFORM bot_conv_set((ctx->>'tenant_id')::uuid, ctx->>'from', 'j_feedback', jsonb_build_object('order_id', o.id, 'number', o.number));
    RETURN bot_reply('journey_survey', jsonb_build_array(bot_msg_text('Gracias por contarnos. ¿Qué podríamos mejorar?')));
  END IF;
  -- Mala experiencia: se abre un ticket con el relato del cliente y se avisa en el momento
  PERFORM bot_conv_set((ctx->>'tenant_id')::uuid, ctx->>'from', 'support_desc',
                       jsonb_build_object('service_order_id', o.id, 'number', o.number::text));
  RETURN bot_reply('journey_survey',
    jsonb_build_array(bot_msg_text('Lamentamos que no haya salido bien. Contame qué pasó y una persona del equipo te escribe hoy mismo.')),
    jsonb_build_array(jsonb_build_object('type', 'survey_alert',
      'text', '⚠️ Encuesta negativa (' || (ctx->>'tenant_name') || ')' || chr(10) || 'Compra #' || o.number || ' · ' || o.service_name || chr(10) ||
              'Cliente: +' || (ctx->>'from') || ' · puntaje ' || p_rating || '/5')));
END $$;

-- ---------- entrada al recorrido ----------
CREATE OR REPLACE FUNCTION bot_journey_start(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_r TEXT := coalesce(ctx->>'reply_id', ''); v_t UUID := (ctx->>'tenant_id')::uuid; o RECORD; r JSONB;
BEGIN
  IF v_r ~ '^jr:[1-5]:[0-9a-f-]{36}$' THEN
    RETURN bot_journey_survey_answer(ctx, split_part(v_r, ':', 2)::int, split_part(v_r, ':', 3)::uuid);
  ELSIF v_r = 'j:faq' THEN
    RETURN bot_reply('journey_faq', jsonb_build_array(bot_msg_text('Dale, escribime tu consulta y te respondo al instante.')));
  ELSIF v_r = 'j:hire' OR (v_r = '' AND (ctx->>'msg') ~ '(contratar|comprar|quiero el servicio|precio del servicio|me interesa contratar)') THEN
    RETURN bot_journey_ask_service(ctx);
  ELSIF v_r = 'j:post' OR (v_r = '' AND (ctx->>'msg') ~ '(mis compras|mis servicios|post venta|postventa)') THEN
    RETURN bot_journey_my_orders(ctx);
  ELSIF v_r = 'j:ok' THEN
    RETURN bot_reply('journey_post', jsonb_build_array(bot_msg_text('¡Genial! Si necesitás algo más, escribí "menú".')));
  ELSIF v_r = 'j:help' THEN
    RETURN bot_rf11_ask_support(ctx, '{}');
  ELSIF v_r ~ '^j:(help|book|paylink):[0-9a-f-]{36}$' THEN
    SELECT so.*, sv.name AS service_name, cu.name AS customer_name INTO o
      FROM service_orders so JOIN services sv ON sv.id = so.service_id JOIN customers cu ON cu.id = so.customer_id
     WHERE so.id = split_part(v_r, ':', 3)::uuid AND so.tenant_id = v_t AND so.phone = ctx->>'from';
    IF NOT FOUND THEN RETURN bot_reply('journey_post', jsonb_build_array(bot_msg_text('No encontré esa compra.'))); END IF;
    IF split_part(v_r, ':', 2) = 'help' THEN
      RETURN bot_rf11_ask_support(ctx, jsonb_build_object('service_order_id', o.id, 'number', o.number::text));
    ELSIF split_part(v_r, ':', 2) = 'paylink' THEN
      RETURN bot_reply('journey_post', jsonb_build_array(jsonb_build_object('type', 'interactive', 'interactive', jsonb_build_object('type', 'cta_url',
        'body', jsonb_build_object('text', 'Este es tu link para pagar ' || o.service_name || '.'),
        'action', jsonb_build_object('name', 'cta_url', 'parameters', jsonb_build_object('display_text', 'Pagar ahora', 'url', o.checkout_url))))));
    END IF;
    IF o.status <> 'paid' THEN RETURN bot_reply('journey_post', jsonb_build_array(bot_msg_text('Esa compra todavía no está pagada.'))); END IF;
    r := bot_rf03_ask_day(ctx, o.service_id, jsonb_build_object('name', o.customer_name, 'order_id', o.id));
    RETURN r || jsonb_build_object('status', 'journey_book');
  ELSIF v_r = '' AND (ctx->>'msg') ~ '^(menu|inicio|empezar|volver|opciones|(hola|holi|buenas|buen dia|buenos dias|buenas tardes|buenas noches|hey|hi|hello)( (que tal|como estas|como andas|como va))?)$' THEN
    RETURN bot_journey_menu(ctx);
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION bot_journey_step(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_t UUID := (ctx->>'tenant_id')::uuid; v_from TEXT := ctx->>'from'; v_raw TEXT := trim(ctx->>'raw');
  v_state TEXT := ctx->>'state'; v_data JSONB := coalesce(ctx->'data', '{}'); v_pick TEXT; v_cust UUID; v_order UUID; sv RECORD;
BEGIN
  IF v_state = 'j_service' THEN
    v_pick := bot_pick(ctx, v_data->'options');
    IF v_pick IS NULL THEN
      RETURN bot_reply('journey_flow', jsonb_build_array(bot_msg_text('Elegí un servicio de la lista o escribí su número:' || chr(10) || bot_options_text(v_data->'options'))));
    END IF;
    RETURN bot_journey_pick_service(ctx, substr(v_pick, 4)::uuid);

  ELSIF v_state = 'j_name' THEN
    IF length(v_raw) < 3 THEN
      RETURN bot_reply('journey_flow', jsonb_build_array(bot_msg_text('¿Me pasás el nombre completo, por favor?')));
    END IF;
    PERFORM bot_conv_set(v_t, v_from, 'j_email', v_data || jsonb_build_object('name', left(v_raw, 150)));
    RETURN bot_reply('journey_flow', jsonb_build_array(bot_msg_text('Gracias. ¿A qué email te mando el comprobante?')));

  ELSIF v_state = 'j_email' THEN
    IF NOT lower(v_raw) ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' THEN
      RETURN bot_reply('journey_flow', jsonb_build_array(bot_msg_text('Ese email no parece válido. Escribilo de nuevo, por ejemplo nombre@gmail.com')));
    END IF;
    RETURN bot_journey_confirm(ctx, v_data || jsonb_build_object('email', lower(v_raw)));

  ELSIF v_state = 'j_confirm' THEN
    IF ctx->>'reply_id' = 'j:cancel' OR (ctx->>'reply_id' IS NULL AND bot_is_no(v_raw)) THEN
      PERFORM bot_conv_clear(v_t, v_from);
      RETURN bot_reply('journey_flow', jsonb_build_array(bot_msg_text('Listo, no generé nada. Si querés retomarlo, escribí "menú".')));
    ELSIF ctx->>'reply_id' = 'j:pay' OR (ctx->>'reply_id' IS NULL AND bot_is_yes(v_raw)) THEN
      SELECT * INTO sv FROM services WHERE id = (v_data->>'service_id')::uuid;
      INSERT INTO customers (tenant_id, phone, name, email) VALUES (v_t, v_from, v_data->>'name', v_data->>'email')
      ON CONFLICT (tenant_id, phone) DO UPDATE SET name = EXCLUDED.name, email = EXCLUDED.email
      RETURNING id INTO v_cust;
      INSERT INTO service_orders (tenant_id, service_id, customer_id, phone, amount, currency, provider)
      VALUES (v_t, sv.id, v_cust, v_from, sv.price, coalesce(sv.currency, 'ARS'),
              (SELECT provider FROM payment_integrations WHERE tenant_id = v_t AND is_active))
      RETURNING id INTO v_order;
      PERFORM bot_conv_clear(v_t, v_from);
      RETURN bot_reply('journey_checkout',
        jsonb_build_array(bot_msg_text('Perfecto, estoy generando tu link de pago. Te llega en unos segundos.')),
        jsonb_build_array(jsonb_build_object('type', 'service_checkout', 'order_id', v_order)));
    END IF;
    RETURN bot_reply('journey_flow', jsonb_build_array(bot_msg_buttons('¿Te genero el link de pago?',
      '[{"id":"j:pay","title":"Sí, pagar"},{"id":"j:cancel","title":"Cancelar"}]'::jsonb)));

  ELSIF v_state = 'j_orders' THEN
    v_pick := bot_pick(ctx, v_data->'options');
    IF v_pick IS NULL THEN RETURN NULL; END IF;
    IF v_pick = 'j:help' THEN RETURN bot_rf11_ask_support(ctx, '{}'); END IF;
    RETURN bot_journey_show_order(ctx, substr(v_pick, 4)::uuid);

  ELSIF v_state = 'j_feedback' THEN
    UPDATE service_orders SET feedback = left(v_raw, 2000) WHERE id = (v_data->>'order_id')::uuid;
    PERFORM bot_conv_clear(v_t, v_from);
    RETURN bot_reply('journey_survey', jsonb_build_array(bot_msg_text('¡Gracias! Se lo paso al equipo para mejorar.')),
      jsonb_build_array(jsonb_build_object('type', 'survey_alert',
        'text', '💬 Comentario de encuesta (' || (ctx->>'tenant_name') || ')' || chr(10) || 'Compra #' || (v_data->>'number') || chr(10) ||
                'Cliente: +' || v_from || chr(10) || left(v_raw, 400))));
  END IF;
  RETURN NULL;
END $$;

-- ---------- funciones para los workflows ----------
-- Todo lo que JOURNEY-CHECKOUT necesita para crear el link de pago único
CREATE OR REPLACE FUNCTION bot_journey_checkout_context(p_order UUID) RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'order_id', o.id, 'number', o.number, 'tenant_id', o.tenant_id, 'tenant_name', t.name, 'status', o.status,
    'service', jsonb_build_object('name', sv.name, 'price', o.amount, 'currency', o.currency, 'description', sv.description),
    'customer', jsonb_build_object('name', c.name, 'email', c.email, 'phone', c.phone),
    'provider', coalesce(pi.provider, 'none'), 'provider_token', pi.access_token, 'provider_config', coalesce(pi.config, '{}'),
    'notification_url', bot_public_url() || '/webhook/servicio-' || coalesce(pi.provider, 'none') || '?tenant=' || o.tenant_id,
    'mock_url', bot_public_url() || '/webhook/servicio-mock?tenant=' || o.tenant_id || '&ref=' || o.id,
    'phone_number_id', w.phone_number_id, 'access_token', w.access_token, 'graph_version', w.graph_version, 'to', o.phone)
  FROM service_orders o
  JOIN tenants t ON t.id = o.tenant_id
  JOIN services sv ON sv.id = o.service_id
  JOIN customers c ON c.id = o.customer_id
  LEFT JOIN payment_integrations pi ON pi.tenant_id = o.tenant_id AND pi.is_active
  LEFT JOIN LATERAL (SELECT * FROM whatsapp_integrations wi WHERE wi.tenant_id = o.tenant_id AND wi.is_active LIMIT 1) w ON true
  WHERE o.id = p_order
$$;

CREATE OR REPLACE FUNCTION bot_journey_checkout_created(p_order UUID, p_url TEXT, p_ref TEXT) RETURNS VOID LANGUAGE sql AS $$
  UPDATE service_orders SET checkout_url = p_url, provider_ref = coalesce(nullif(p_ref, ''), provider_ref) WHERE id = p_order
$$;

-- Pago verificado. Idempotente. Devuelve los mensajes de WhatsApp a enviar, encola el comprobante y arma el aviso a ventas.
CREATE OR REPLACE FUNCTION bot_journey_paid(p_tenant UUID, p_provider TEXT, p_event_id TEXT, p_order UUID, p_ref TEXT, p_payload JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE o RECORD; c JSONB; v_msgs JSONB; v_rows JSONB; v_can_book BOOLEAN;
BEGIN
  INSERT INTO payment_events (tenant_id, provider, event_id, service_order_id, payload)
  VALUES (p_tenant, p_provider, p_event_id, p_order, p_payload) ON CONFLICT (provider, event_id) DO NOTHING;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', true, 'duplicate', true); END IF;
  SELECT so.*, sv.name AS service_name, sv.bookable INTO o FROM service_orders so JOIN services sv ON sv.id = so.service_id
   WHERE so.id = p_order AND so.tenant_id = p_tenant FOR UPDATE OF so;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'order not found for tenant'); END IF;
  IF o.status <> 'pending_payment' THEN RETURN jsonb_build_object('ok', true, 'duplicate', true, 'status', o.status); END IF;
  UPDATE service_orders SET status = 'paid', paid_at = NOW(), provider = p_provider, provider_ref = coalesce(nullif(p_ref, ''), provider_ref) WHERE id = o.id;
  c := bot_journey_checkout_context(o.id);
  v_can_book := o.bookable AND EXISTS (SELECT 1 FROM availability_rules WHERE tenant_id = p_tenant);
  v_msgs := jsonb_build_array(CASE WHEN v_can_book THEN
    bot_msg_buttons('✅ ¡Pago recibido, ' || (c #>> '{customer,name}') || '! Compra #' || o.number || ': ' || o.service_name || '.' || chr(10) ||
                    'Te mandé el comprobante por email. ¿Elegimos ahora el día y horario?',
      jsonb_build_array(jsonb_build_object('id', 'j:book:' || o.id, 'title', 'Elegir turno'), jsonb_build_object('id', 'j:ok', 'title', 'Más tarde')))
    ELSE bot_msg_text('✅ ¡Pago recibido, ' || (c #>> '{customer,name}') || '! Compra #' || o.number || ': ' || o.service_name || '.' || chr(10) ||
                      'Te mandé el comprobante por email. En breve te contactamos para coordinar.') END);
  v_rows := jsonb_build_array(jsonb_build_array('Compra', '#' || o.number), jsonb_build_array('Servicio', o.service_name),
                              jsonb_build_array('Importe', bot_money(o.amount, o.currency)),
                              jsonb_build_array('Fecha', bot_fmt_date(NOW(), bot_tenant_tz(p_tenant))));
  PERFORM bot_email_enqueue(p_tenant, 'journey_receipt', o.id::text, c #>> '{customer,email}', c #>> '{customer,name}',
    'Recibimos tu pago: ' || o.service_name,
    bot_email_html(c->>'tenant_name', '¡Gracias por tu compra!',
      ARRAY['Hola ' || (c #>> '{customer,name}') || ', recibimos tu pago. Este es el comprobante.',
            CASE WHEN v_can_book THEN 'Podés elegir el turno desde WhatsApp cuando quieras: escribí "mis compras".'
                 ELSE 'En breve te contactamos para coordinar.' END], v_rows),
    bot_email_text('¡Gracias por tu compra!', ARRAY['Recibimos tu pago.'], v_rows));
  RETURN jsonb_build_object('ok', true, 'duplicate', false, 'first_payment', true, 'order_id', o.id,
    'wa', (SELECT coalesce(jsonb_agg(bot_wa_target(p_tenant, o.phone, m)), '[]'::jsonb) FROM jsonb_array_elements(v_msgs) m),
    'notify', bot_notify_payload(p_tenant, jsonb_build_object('type', 'service_paid',
      'text', '💰 Servicio pagado (' || (c->>'tenant_name') || ')' || chr(10) || 'Compra #' || o.number || ' · ' || o.service_name || ' · ' ||
              bot_money(o.amount, o.currency) || chr(10) || 'Cliente: ' || (c #>> '{customer,name}') || ' · +' || o.phone)));
END $$;

-- Encuestas a enviar: N horas después del turno (o del pago si el servicio no lleva turno). Marca cada compra una vez.
CREATE OR REPLACE FUNCTION bot_journey_survey_due() RETURNS SETOF JSONB LANGUAGE plpgsql AS $$
DECLARE o RECORD; v_msg JSONB; v_tpl TEXT; v_t JSONB;
BEGIN
  -- Pagos que nunca llegaron: a los 3 días la compra vence
  UPDATE service_orders SET status = 'expired' WHERE status = 'pending_payment' AND created_at < NOW() - INTERVAL '3 days';
  FOR o IN
    SELECT so.*, sv.name AS service_name, cu.name AS customer_name, t.settings
      FROM service_orders so JOIN services sv ON sv.id = so.service_id JOIN customers cu ON cu.id = so.customer_id
      JOIN tenants t ON t.id = so.tenant_id LEFT JOIN bookings b ON b.id = so.booking_id
     WHERE so.status = 'paid' AND so.survey_sent_at IS NULL AND t.is_active
       AND coalesce((t.settings #>> '{features,journey}')::boolean, false)
       AND ((b.id IS NOT NULL AND b.status IN ('confirmed', 'attended')
             AND b.ends_at < NOW() - make_interval(hours => coalesce((t.settings #>> '{journey,survey_after_hours}')::int, 2)))
         OR (b.id IS NULL AND NOT sv.bookable
             AND so.paid_at < NOW() - make_interval(hours => coalesce((t.settings #>> '{journey,survey_after_hours}')::int, 24))))
     ORDER BY so.paid_at FOR UPDATE OF so SKIP LOCKED
  LOOP
    v_tpl := nullif(o.settings #>> '{journey,survey_template}', '');
    IF v_tpl IS NOT NULL THEN
      v_msg := jsonb_build_object('type', 'template', 'template', jsonb_build_object(
        'name', v_tpl, 'language', jsonb_build_object('code', coalesce(o.settings #>> '{journey,survey_lang}', 'es_AR')),
        'components', jsonb_build_array(
          jsonb_build_object('type', 'body', 'parameters', jsonb_build_array(
            jsonb_build_object('type', 'text', 'text', o.customer_name), jsonb_build_object('type', 'text', 'text', o.service_name))),
          jsonb_build_object('type', 'button', 'sub_type', 'quick_reply', 'index', '0',
            'parameters', jsonb_build_array(jsonb_build_object('type', 'payload', 'payload', 'jr:5:' || o.id))),
          jsonb_build_object('type', 'button', 'sub_type', 'quick_reply', 'index', '1',
            'parameters', jsonb_build_array(jsonb_build_object('type', 'payload', 'payload', 'jr:3:' || o.id))),
          jsonb_build_object('type', 'button', 'sub_type', 'quick_reply', 'index', '2',
            'parameters', jsonb_build_array(jsonb_build_object('type', 'payload', 'payload', 'jr:1:' || o.id))))));
    ELSE
      v_msg := bot_msg_buttons('Hola ' || o.customer_name || ', ¿cómo te fue con ' || o.service_name || '? Tu opinión nos ayuda a mejorar.',
        jsonb_build_array(jsonb_build_object('id', 'jr:5:' || o.id, 'title', '😀 Muy bien'),
                          jsonb_build_object('id', 'jr:3:' || o.id, 'title', '😐 Regular'),
                          jsonb_build_object('id', 'jr:1:' || o.id, 'title', '😞 Mal')));
    END IF;
    UPDATE service_orders SET survey_sent_at = NOW() WHERE id = o.id;
    v_t := bot_wa_target(o.tenant_id, o.phone, v_msg);
    IF v_t IS NOT NULL THEN RETURN NEXT v_t || jsonb_build_object('order_id', o.id); END IF;
  END LOOP;
END $$;
