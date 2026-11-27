-- Fase 3: OPERACIONES. RF-05 carrito abandonado, RF-06 recordatorio de pago, RF-07 aviso de renovación,
-- RF-08 baja de suscripción. Todo se activa por cliente con tenants.settings.features.rfNN = true y se
-- configura con tenants.settings.rfNN (ver la guía). Los emails salen por CORE-04 (40_core_email.sql).

-- ---------- integraciones con tiendas / ERP (RF-05, RF-11) ----------
CREATE TABLE IF NOT EXISTS commerce_integrations (
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  provider VARCHAR(20) NOT NULL CHECK (provider IN ('tiendanube', 'woocommerce', 'odoo', 'generic')),
  store_id TEXT,                    -- Tiendanube: user_id de la tienda
  access_token TEXT,                -- Tiendanube: token de la app
  config JSONB NOT NULL DEFAULT '{}'::jsonb,   -- {user_agent, base_url}
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  last_polled_at TIMESTAMPTZ,
  PRIMARY KEY (tenant_id, provider)
);

-- ---------- RF-05: carritos abandonados ----------
CREATE TABLE IF NOT EXISTS carts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  source VARCHAR(20) NOT NULL DEFAULT 'generic',
  external_id TEXT NOT NULL,
  customer_name VARCHAR(150),
  email VARCHAR(200),
  phone VARCHAR(50),
  items JSONB NOT NULL DEFAULT '[]'::jsonb,    -- [{name, quantity, price}]
  total NUMERIC(12, 2),
  currency VARCHAR(3) DEFAULT 'ARS',
  checkout_url TEXT,
  last_activity_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  recovered_at TIMESTAMPTZ,         -- se completó la compra
  reminder_sent_at TIMESTAMPTZ,
  reminder_status TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, source, external_id)
);

-- Alta/actualización de un carrito normalizado:
-- {external_id, source, name, email, phone, items:[{name, quantity, price}], total, currency, checkout_url, updated_at, completed}
CREATE OR REPLACE FUNCTION bot_rf05_upsert_cart(p_tenant UUID, c JSONB) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  IF coalesce(c->>'external_id', '') = '' THEN RETURN NULL; END IF;
  INSERT INTO carts AS k (tenant_id, source, external_id, customer_name, email, phone, items, total, currency, checkout_url,
                          last_activity_at, recovered_at)
  VALUES (p_tenant, coalesce(nullif(c->>'source', ''), 'generic'), c->>'external_id', left(c->>'name', 150), lower(nullif(c->>'email', '')),
          nullif(regexp_replace(coalesce(c->>'phone', ''), '\D', '', 'g'), ''), CASE WHEN jsonb_typeof(c->'items') = 'array' THEN c->'items' ELSE '[]' END,
          nullif(c->>'total', '')::numeric, coalesce(nullif(c->>'currency', ''), 'ARS'), nullif(c->>'checkout_url', ''),
          coalesce(nullif(c->>'updated_at', '')::timestamptz, NOW()),
          CASE WHEN coalesce((c->>'completed')::boolean, false) THEN NOW() END)
  ON CONFLICT (tenant_id, source, external_id) DO UPDATE SET
    customer_name = coalesce(EXCLUDED.customer_name, k.customer_name), email = coalesce(EXCLUDED.email, k.email),
    phone = coalesce(EXCLUDED.phone, k.phone), items = EXCLUDED.items, total = EXCLUDED.total, currency = EXCLUDED.currency,
    checkout_url = coalesce(EXCLUDED.checkout_url, k.checkout_url),
    last_activity_at = greatest(EXCLUDED.last_activity_at, k.last_activity_at),
    recovered_at = coalesce(k.recovered_at, EXCLUDED.recovered_at)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION bot_rf05_upsert_carts(p_tenant UUID, p_carts JSONB) RETURNS INTEGER LANGUAGE sql AS $$
  SELECT count(bot_rf05_upsert_cart(p_tenant, c))::int FROM jsonb_array_elements(coalesce(p_carts, '[]')) c
$$;

-- Webhook genérico (WordPress/WooCommerce, otra tienda): POST /webhook/rf05-carrito?key=<hook_secret>
-- Cuerpo: un carrito normalizado o {"carts": [...]}
CREATE OR REPLACE FUNCTION bot_rf05_ingest(p_key TEXT, p_body JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_t UUID := bot_tenant_by_hook(p_key); v_n INTEGER;
BEGIN
  IF v_t IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'clave inválida'); END IF;
  v_n := bot_rf05_upsert_carts(v_t, CASE WHEN p_body ? 'carts' THEN p_body->'carts' ELSE jsonb_build_array(p_body) END);
  RETURN jsonb_build_object('ok', true, 'carts', v_n);
END $$;

-- Tiendas Tiendanube a consultar (RF05-REMIND las lee cada 30 min)
CREATE OR REPLACE FUNCTION bot_rf05_tiendanube_sources() RETURNS TABLE (tenant_id UUID, store_id TEXT, access_token TEXT, user_agent TEXT, since TEXT)
LANGUAGE sql AS $$
  UPDATE commerce_integrations ci SET last_polled_at = NOW()
   WHERE ci.provider = 'tiendanube' AND ci.is_active AND coalesce(ci.store_id, '') <> '' AND bot_tenant_feature(ci.tenant_id, 'rf05')
  RETURNING ci.tenant_id, ci.store_id, ci.access_token, coalesce(ci.config->>'user_agent', 'Chatbot DM Global'),
            to_char((NOW() - INTERVAL '3 days') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
$$;

-- Encola el email de cada carrito que lleva más de N horas sin actividad (settings.rf05.delay_hours, 4 por defecto)
CREATE OR REPLACE FUNCTION bot_rf05_due() RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE k RECORD; v_n INTEGER := 0; v_rows JSONB; v_items TEXT[]; v_id UUID; v_tname TEXT;
BEGIN
  FOR k IN
    SELECT c.*, t.name AS tenant_name, coalesce((t.settings #>> '{rf05,delay_hours}')::numeric, 4) AS delay_h
      FROM carts c JOIN tenants t ON t.id = c.tenant_id
     WHERE c.recovered_at IS NULL AND c.reminder_sent_at IS NULL AND c.email IS NOT NULL AND c.checkout_url IS NOT NULL
       AND coalesce((t.settings #>> '{features,rf05}')::boolean, false) AND t.is_active
       AND c.last_activity_at < NOW() - make_interval(secs => coalesce((t.settings #>> '{rf05,delay_hours}')::numeric, 4) * 3600)
       AND c.last_activity_at > NOW() - INTERVAL '7 days'
     ORDER BY c.last_activity_at LIMIT 200
  LOOP
    SELECT coalesce(jsonb_agg(jsonb_build_array(
             coalesce(i->>'quantity', '1') || ' × ' || coalesce(i->>'name', 'Producto'),
             CASE WHEN i ? 'price' THEN bot_money((i->>'price')::numeric, k.currency) ELSE '' END)), '[]')
      INTO v_rows FROM jsonb_array_elements(k.items) i;
    IF k.total IS NOT NULL THEN v_rows := v_rows || jsonb_build_array(jsonb_build_array('Total', bot_money(k.total, k.currency))); END IF;
    v_id := bot_email_enqueue(k.tenant_id, 'rf05_cart', k.id::text, k.email, k.customer_name,
      coalesce(k.customer_name, 'Hola') || ', tu carrito te está esperando',
      bot_email_html(k.tenant_name, 'Te guardamos el carrito',
        ARRAY['Hola' || coalesce(' ' || k.customer_name, '') || ', vimos que dejaste productos en tu carrito de ' || k.tenant_name || '.',
              'Están reservados por poco tiempo. Podés terminar la compra en un clic.'],
        v_rows, 'Completar mi compra', k.checkout_url,
        'Recibís este email porque iniciaste una compra en ' || bot_html_escape(k.tenant_name) || '.'),
      bot_email_text('Te guardamos el carrito', ARRAY['Dejaste productos en tu carrito de ' || k.tenant_name || '.'], v_rows, k.checkout_url));
    UPDATE carts SET reminder_sent_at = NOW(), reminder_status = CASE WHEN v_id IS NULL THEN 'duplicado' ELSE 'encolado' END WHERE id = k.id;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

-- ---------- RF-06 / RF-07: avisos de suscripción ----------
-- Detalle común de los emails de suscripción
CREATE OR REPLACE FUNCTION bot_sub_rows(c JSONB, p_tz TEXT) RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_array(
    jsonb_build_array('Plan', c #>> '{plan,name}'),
    jsonb_build_array('Importe', bot_money((c #>> '{plan,price}')::numeric, c #>> '{plan,currency}')),
    jsonb_build_array('Fecha', bot_fmt_date((c->>'current_period_end')::timestamptz, p_tz)))
$$;

-- RF-06: N días antes del vencimiento (settings.rf06.days_before, 3 por defecto) email con importe, fecha y link de pago
CREATE OR REPLACE FUNCTION bot_rf06_due() RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE s RECORD; c JSONB; v_tz TEXT; v_n INTEGER := 0; v_url TEXT;
BEGIN
  FOR s IN
    SELECT sb.id, sb.tenant_id, sb.current_period_end, sb.checkout_url FROM subscriptions sb JOIN tenants t ON t.id = sb.tenant_id
     WHERE sb.status IN ('active', 'past_due') AND t.is_active AND coalesce((t.settings #>> '{features,rf06}')::boolean, false)
       AND sb.current_period_end > NOW()
       AND sb.current_period_end <= NOW() + make_interval(days => coalesce((t.settings #>> '{rf06,days_before}')::int, 3))
  LOOP
    c := bot_rf04_checkout_context(s.id); v_tz := bot_tenant_tz(s.tenant_id);
    v_url := coalesce(s.checkout_url, c->>'manage_url');
    IF bot_email_enqueue(s.tenant_id, 'rf06_payment', s.id || ':' || s.current_period_end, c #>> '{customer,email}', c #>> '{customer,name}',
         'Tu próximo pago de ' || (c->>'tenant_name') || ' vence el ' || bot_fmt_date(s.current_period_end, v_tz),
         bot_email_html(c->>'tenant_name', 'Se acerca tu próximo pago',
           ARRAY['Hola ' || (c #>> '{customer,name}') || ', te recordamos que el ' || bot_fmt_date(s.current_period_end, v_tz) ||
                 ' vence el pago de tu plan ' || (c #>> '{plan,name}') || '.',
                 'Si tenés el débito automático activo no tenés que hacer nada. Si no, podés pagar desde el botón.'],
           bot_sub_rows(c, v_tz), 'Ver o pagar', v_url,
           '¿No querés seguir? <a href="' || bot_html_escape(c->>'manage_url') || '">Gestioná o cancelá tu suscripción</a>.'),
         bot_email_text('Se acerca tu próximo pago', ARRAY['Vence el ' || bot_fmt_date(s.current_period_end, v_tz) || '.'], bot_sub_rows(c, v_tz), v_url)) IS NOT NULL
    THEN v_n := v_n + 1; END IF;
  END LOOP;
  RETURN v_n;
END $$;

-- RF-07: N días antes de la renovación automática (settings.rf07.days_before, 7) aviso con link para gestionar o dar de baja
CREATE OR REPLACE FUNCTION bot_rf07_due() RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE s RECORD; c JSONB; v_tz TEXT; v_n INTEGER := 0;
BEGIN
  FOR s IN
    SELECT sb.id, sb.tenant_id, sb.current_period_end FROM subscriptions sb JOIN tenants t ON t.id = sb.tenant_id
     WHERE sb.status = 'active' AND t.is_active AND coalesce((t.settings #>> '{features,rf07}')::boolean, false)
       AND sb.current_period_end > NOW()
       AND sb.current_period_end <= NOW() + make_interval(days => coalesce((t.settings #>> '{rf07,days_before}')::int, 7))
  LOOP
    c := bot_rf04_checkout_context(s.id); v_tz := bot_tenant_tz(s.tenant_id);
    IF bot_email_enqueue(s.tenant_id, 'rf07_renewal', s.id || ':' || s.current_period_end, c #>> '{customer,email}', c #>> '{customer,name}',
         'Tu suscripción a ' || (c->>'tenant_name') || ' se renueva el ' || bot_fmt_date(s.current_period_end, v_tz),
         bot_email_html(c->>'tenant_name', 'Tu suscripción se renueva pronto',
           ARRAY['Hola ' || (c #>> '{customer,name}') || ', el ' || bot_fmt_date(s.current_period_end, v_tz) ||
                 ' se renueva automáticamente tu plan ' || (c #>> '{plan,name}') || '.',
                 'Si querés seguir, no tenés que hacer nada. Si preferís cambiar o dar de baja, hacelo antes de esa fecha.'],
           bot_sub_rows(c, v_tz), 'Gestionar o dar de baja', c->>'manage_url'),
         bot_email_text('Tu suscripción se renueva pronto', ARRAY['Se renueva el ' || bot_fmt_date(s.current_period_end, v_tz) || '.'],
           bot_sub_rows(c, v_tz), c->>'manage_url')) IS NOT NULL
    THEN v_n := v_n + 1; END IF;
  END LOOP;
  RETURN v_n;
END $$;

-- Vencimientos: sin pago a los 5 días pasa a past_due; a los 30, expired. Pendientes de pago de más de 7 días, expired.
CREATE OR REPLACE FUNCTION bot_subscriptions_expire() RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_due INTEGER; v_exp INTEGER; v_pend INTEGER;
BEGIN
  UPDATE subscriptions SET status = 'past_due' WHERE status = 'active' AND current_period_end < NOW() - INTERVAL '5 days';
  GET DIAGNOSTICS v_due = ROW_COUNT;
  UPDATE subscriptions SET status = 'expired' WHERE status = 'past_due' AND current_period_end < NOW() - INTERVAL '30 days';
  GET DIAGNOSTICS v_exp = ROW_COUNT;
  UPDATE subscriptions SET status = 'expired' WHERE status = 'pending_payment' AND created_at < NOW() - INTERVAL '7 days';
  GET DIAGNOSTICS v_pend = ROW_COUNT;
  RETURN jsonb_build_object('past_due', v_due, 'expired', v_exp, 'pending_expired', v_pend);
END $$;

-- ---------- RF-08: baja de suscripción ----------
-- Página de gestión: GET /webhook/suscripcion?t=<manage_token>
CREATE OR REPLACE FUNCTION bot_page(p_brand TEXT, p_title TEXT, p_body TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT '<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    || '<meta name="robots" content="noindex"><title>' || bot_html_escape(p_title) || '</title>'
    || '<style>body{margin:0;background:#f4f4f5;font-family:Arial,Helvetica,sans-serif;color:#18181b}main{max-width:480px;margin:40px auto;background:#fff;'
    || 'border-radius:8px;padding:28px}h1{font-size:22px;margin:0 0 16px}p{line-height:1.5}small{color:#71717a}table{width:100%;border-collapse:collapse;margin:12px 0}'
    || 'td{padding:8px 0;border-bottom:1px solid #f4f4f5}td+td{text-align:right}button{background:#dc2626;color:#fff;border:0;border-radius:6px;padding:12px 20px;'
    || 'font-size:15px;cursor:pointer}@media(prefers-color-scheme:dark){body{background:#18181b;color:#f4f4f5}main{background:#27272a}td{border-color:#3f3f46}}</style></head>'
    || '<body><main><small>' || bot_html_escape(p_brand) || '</small><h1>' || bot_html_escape(p_title) || '</h1>' || p_body || '</main></body></html>'
$$;

CREATE OR REPLACE FUNCTION bot_rf08_page(p_token TEXT) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE s RECORD; c JSONB; v_tz TEXT; v_rows TEXT;
BEGIN
  SELECT * INTO s FROM subscriptions WHERE manage_token = p_token AND length(coalesce(p_token, '')) >= 20;
  IF NOT FOUND THEN RETURN bot_page('Suscripción', 'Link inválido', '<p>Este link no es válido o venció. Escribinos por WhatsApp y te ayudamos.</p>'); END IF;
  c := bot_rf04_checkout_context(s.id); v_tz := bot_tenant_tz(s.tenant_id);
  v_rows := '<table><tr><td>Plan</td><td>' || bot_html_escape(c #>> '{plan,name}') || '</td></tr><tr><td>Titular</td><td>' ||
            bot_html_escape(c #>> '{customer,name}') || '</td></tr><tr><td>Estado</td><td>' ||
            CASE s.status WHEN 'active' THEN 'Activa' WHEN 'past_due' THEN 'Pago pendiente' WHEN 'cancelled' THEN 'Cancelada'
                          WHEN 'expired' THEN 'Vencida' ELSE 'Esperando el pago' END || '</td></tr>' ||
            CASE WHEN s.current_period_end IS NOT NULL THEN '<tr><td>' || CASE WHEN s.status = 'cancelled' THEN 'Acceso hasta' ELSE 'Próxima renovación' END ||
                 '</td><td>' || bot_fmt_date(s.current_period_end, v_tz) || '</td></tr>' ELSE '' END || '</table>';
  IF s.status IN ('cancelled', 'expired') THEN
    RETURN bot_page(c->>'tenant_name', 'Tu suscripción', v_rows || '<p>Esta suscripción ya no tiene cobros futuros.</p>');
  END IF;
  RETURN bot_page(c->>'tenant_name', 'Tu suscripción', v_rows ||
    '<p>Si la cancelás, no se te va a volver a cobrar' ||
    CASE WHEN s.current_period_end IS NOT NULL THEN ' y mantenés el acceso hasta el ' || bot_fmt_date(s.current_period_end, v_tz) ELSE '' END || '.</p>' ||
    '<form method="post" action="' || bot_public_url() || '/webhook/suscripcion-baja"><input type="hidden" name="t" value="' ||
    bot_html_escape(p_token) || '"><button type="submit">Cancelar mi suscripción</button></form>');
END $$;

-- Confirma la baja. Devuelve lo necesario para detener los cobros en la pasarela y la página de respuesta.
CREATE OR REPLACE FUNCTION bot_rf08_cancel(p_token TEXT, p_reason TEXT DEFAULT 'autoservicio') RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE s RECORD; c JSONB; v_tz TEXT; v_end TEXT;
BEGIN
  SELECT * INTO s FROM subscriptions WHERE manage_token = p_token AND length(coalesce(p_token, '')) >= 20 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'page', bot_page('Suscripción', 'Link inválido', '<p>Este link no es válido o venció.</p>'));
  END IF;
  c := bot_rf04_checkout_context(s.id); v_tz := bot_tenant_tz(s.tenant_id);
  IF s.status IN ('cancelled', 'expired') THEN
    RETURN jsonb_build_object('ok', true, 'already', true, 'provider', 'none',
      'page', bot_page(c->>'tenant_name', 'Suscripción cancelada', '<p>Tu suscripción ya estaba cancelada. No hay cobros futuros.</p>'));
  END IF;
  UPDATE subscriptions SET status = 'cancelled', cancelled_at = NOW(), cancel_reason = p_reason WHERE id = s.id;
  v_end := coalesce(bot_fmt_date(s.current_period_end, v_tz), '');
  PERFORM bot_email_enqueue(s.tenant_id, 'rf08_cancelled', s.id::text, c #>> '{customer,email}', c #>> '{customer,name}',
    'Cancelamos tu suscripción a ' || (c->>'tenant_name'),
    bot_email_html(c->>'tenant_name', 'Tu suscripción quedó cancelada',
      ARRAY['Hola ' || (c #>> '{customer,name}') || ', confirmamos la baja de tu plan ' || (c #>> '{plan,name}') || '. No se te va a volver a cobrar.',
            CASE WHEN v_end <> '' THEN 'Mantenés el acceso hasta el ' || v_end || '.' ELSE 'Gracias por haber sido parte.' END,
            'Si fue un error o querés volver, escribinos por WhatsApp.']),
    bot_email_text('Tu suscripción quedó cancelada', ARRAY['Confirmamos la baja de tu plan ' || (c #>> '{plan,name}') || '.']));
  RETURN jsonb_build_object('ok', true, 'already', false, 'subscription_id', s.id, 'tenant_id', s.tenant_id,
    'provider', CASE WHEN s.provider_ref IS NULL THEN 'none' ELSE coalesce(s.provider, 'none') END,
    'provider_ref', s.provider_ref, 'provider_token', c->>'provider_token',
    'notify_text', '🔴 Baja de suscripción (' || (c->>'tenant_name') || ')' || chr(10) || (c #>> '{customer,name}') || ' · ' ||
                   (c #>> '{plan,name}') || chr(10) || 'WhatsApp: +' || (c->>'to'),
    'page', bot_page(c->>'tenant_name', 'Suscripción cancelada',
      '<p>Listo, cancelamos tu suscripción. No se te va a volver a cobrar.</p>' ||
      CASE WHEN v_end <> '' THEN '<p>Mantenés el acceso hasta el ' || v_end || '.</p>' ELSE '' END ||
      '<p><small>Te mandamos la confirmación por email.</small></p>'));
END $$;

-- Resultado de cancelar en la pasarela (queda registrado para revisar a mano si falló)
CREATE OR REPLACE FUNCTION bot_rf08_provider_result(p_sub UUID, p_ok BOOLEAN, p_detail TEXT) RETURNS VOID LANGUAGE sql AS $$
  UPDATE subscriptions SET cancel_reason = coalesce(cancel_reason, '') ||
         CASE WHEN p_ok THEN ' · pasarela: cobros detenidos' ELSE ' · pasarela: ERROR ' || left(coalesce(p_detail, ''), 300) END
   WHERE id = p_sub
$$;

-- Por WhatsApp: "quiero dar de baja mi suscripción" → link seguro de gestión (la baja se confirma en la página)
CREATE OR REPLACE FUNCTION bot_rf08_start(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE s RECORD;
BEGIN
  IF NOT ((ctx->>'msg') ~ '(^| )(baja|desuscribir|desuscribirme|unsubscribe)( |$)'
          OR (ctx->>'msg') ~ '(cancelar|anular|terminar|dejar) (mi |la )?(suscripcion|membresia|abono|plan)') THEN
    RETURN NULL;
  END IF;
  SELECT sb.* INTO s FROM subscriptions sb JOIN customers cu ON cu.id = sb.customer_id
   WHERE sb.tenant_id = (ctx->>'tenant_id')::uuid AND cu.phone = ctx->>'from' AND sb.status IN ('active', 'past_due', 'pending_payment')
   ORDER BY sb.created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN bot_reply('rf08_none', jsonb_build_array(bot_msg_text('No encontré una suscripción activa con este número. Si la contrataste con otro, escribí "asesor".')));
  END IF;
  RETURN bot_reply('rf08_link', jsonb_build_array(jsonb_build_object('type', 'interactive', 'interactive', jsonb_build_object(
    'type', 'cta_url', 'body', jsonb_build_object('text', 'Desde este link seguro podés ver tu suscripción y confirmar la baja. No se te va a volver a cobrar.'),
    'action', jsonb_build_object('name', 'cta_url', 'parameters', jsonb_build_object(
      'display_text', 'Gestionar suscripción', 'url', bot_public_url() || '/webhook/suscripcion?t=' || s.manage_token))))));
END $$;
