-- RF-04 Alta y compra de suscripciones por WhatsApp (fase 2).
-- El motor muestra los planes, pide datos de facturación y crea la suscripción en 'pending_payment'.
-- El workflow RF04-CHECKOUT genera el link de pago; RF04-PAGOS confirma el pago y la activa.
-- Se activa por cliente con tenants.settings.features.rf04 = true.

CREATE TABLE IF NOT EXISTS subscription_plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  code VARCHAR(50) NOT NULL,
  name VARCHAR(60) NOT NULL,
  price NUMERIC(12, 2) NOT NULL CHECK (price > 0),
  currency VARCHAR(3) NOT NULL DEFAULT 'ARS',
  billing_interval VARCHAR(10) NOT NULL DEFAULT 'month' CHECK (billing_interval IN ('month', 'year')),
  description VARCHAR(300),
  provider_price_id TEXT,           -- Stripe: price_xxx; Mercado Pago: id de preapproval_plan (opcional)
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order INTEGER NOT NULL DEFAULT 0,
  UNIQUE (tenant_id, code)
);

CREATE TABLE IF NOT EXISTS customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone VARCHAR(50) NOT NULL,
  name VARCHAR(150) NOT NULL,
  email VARCHAR(200),
  tax_id VARCHAR(20),               -- DNI o CUIT
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, phone)
);

CREATE TABLE IF NOT EXISTS subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  customer_id UUID NOT NULL REFERENCES customers(id),
  plan_id UUID NOT NULL REFERENCES subscription_plans(id),
  status VARCHAR(20) NOT NULL DEFAULT 'pending_payment'
         CHECK (status IN ('pending_payment', 'active', 'past_due', 'cancelled', 'expired')),
  provider VARCHAR(20),
  provider_ref TEXT,                -- id de preapproval (MP) o de subscription/checkout session (Stripe)
  checkout_url TEXT,
  current_period_end TIMESTAMPTZ,   -- lo usan RF-06 y RF-07
  activated_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS subscriptions_tenant_status_idx ON subscriptions (tenant_id, status);

-- Pasarela de pago de cada cliente (mock = simulada, para pruebas)
CREATE TABLE IF NOT EXISTS payment_integrations (
  tenant_id UUID PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
  provider VARCHAR(20) NOT NULL CHECK (provider IN ('mercadopago', 'stripe', 'mock')),
  access_token TEXT,                -- MP: access token de producción; Stripe: secret key
  config JSONB NOT NULL DEFAULT '{}'::jsonb,   -- {back_url, success_url}
  is_active BOOLEAN NOT NULL DEFAULT TRUE
);

-- Idempotencia de webhooks de pago
CREATE TABLE IF NOT EXISTS payment_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  provider VARCHAR(20) NOT NULL,
  event_id TEXT NOT NULL,
  subscription_id UUID REFERENCES subscriptions(id),
  payload JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (provider, event_id)
);

CREATE OR REPLACE FUNCTION bot_money(p NUMERIC, c TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  -- Formato argentino: $ 19.900 o $ 19.900,50
  SELECT CASE WHEN c = 'USD' THEN 'US$ ' ELSE '$ ' END ||
         CASE WHEN p = trunc(p) THEN replace(to_char(p, 'FM999,999,999,990'), ',', '.')
              ELSE translate(to_char(p, 'FM999,999,999,990.00'), ',.', '.,') END
$$;

CREATE OR REPLACE FUNCTION bot_rf04_start(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_t UUID := (ctx->>'tenant_id')::uuid; v_rows JSONB; v_cmp TEXT;
BEGIN
  IF NOT (ctx->>'msg') ~ '(^| )(plan|planes|suscripcion|suscripciones|suscribirme|suscribir|membresia|abono|abonarme|contratar)( |$)' THEN
    RETURN NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM subscription_plans WHERE tenant_id = v_t AND is_active) THEN RETURN NULL; END IF;
  SELECT string_agg('*' || name || '* · ' || bot_money(price, currency) || CASE billing_interval WHEN 'year' THEN ' por año' ELSE ' por mes' END ||
                    coalesce(chr(10) || description, ''), chr(10) || chr(10) ORDER BY sort_order, price),
         jsonb_agg(jsonb_build_object('id', 'p:' || code, 'title', name,
                   'description', bot_money(price, currency) || CASE billing_interval WHEN 'year' THEN '/año' ELSE '/mes' END) ORDER BY sort_order, price)
    INTO v_cmp, v_rows
    FROM (SELECT * FROM subscription_plans WHERE tenant_id = v_t AND is_active ORDER BY sort_order, price LIMIT 10) p;
  PERFORM bot_conv_set(v_t, ctx->>'from', 'sub_plan', jsonb_build_object('options', v_rows));
  RETURN bot_reply('subscription_flow', jsonb_build_array(
    bot_msg_text('Estos son nuestros planes:' || chr(10) || chr(10) || v_cmp),
    bot_msg_list('¿Cuál querés contratar?', 'Elegir plan', v_rows)));
END $$;

CREATE OR REPLACE FUNCTION bot_rf04_step(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_t UUID := (ctx->>'tenant_id')::uuid; v_from TEXT := ctx->>'from'; v_raw TEXT := trim(ctx->>'raw');
  v_state TEXT := ctx->>'state'; v_data JSONB := coalesce(ctx->'data', '{}'); v_pick TEXT;
  pl RECORD; v_cust UUID; v_sub UUID; v_doc TEXT;
BEGIN
  IF v_state = 'sub_plan' THEN
    v_pick := bot_pick(ctx, v_data->'options');
    IF v_pick IS NULL THEN
      RETURN bot_reply('subscription_flow', jsonb_build_array(bot_msg_text('Elegí un plan de la lista o escribí su número:' || chr(10) || bot_options_text(v_data->'options'))));
    END IF;
    SELECT * INTO pl FROM subscription_plans WHERE tenant_id = v_t AND code = substr(v_pick, 3);
    PERFORM bot_conv_set(v_t, v_from, 'sub_name', jsonb_build_object('plan_id', pl.id, 'plan_name', pl.name,
              'price', bot_money(pl.price, pl.currency) || CASE pl.billing_interval WHEN 'year' THEN ' por año' ELSE ' por mes' END));
    RETURN bot_reply('subscription_flow', jsonb_build_array(bot_msg_text(
      'Elegiste *' || pl.name || '*. Para la factura necesito tres datos. Primero: ¿nombre y apellido o razón social?')));

  ELSIF v_state = 'sub_name' THEN
    IF length(v_raw) < 3 THEN
      RETURN bot_reply('subscription_flow', jsonb_build_array(bot_msg_text('¿Me pasás el nombre completo, por favor?')));
    END IF;
    PERFORM bot_conv_set(v_t, v_from, 'sub_email', v_data || jsonb_build_object('name', left(v_raw, 150)));
    RETURN bot_reply('subscription_flow', jsonb_build_array(bot_msg_text('Gracias. ¿A qué email te mando la factura y la bienvenida?')));

  ELSIF v_state = 'sub_email' THEN
    IF NOT lower(v_raw) ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' THEN
      RETURN bot_reply('subscription_flow', jsonb_build_array(bot_msg_text('Ese email no parece válido. Escribilo de nuevo, por ejemplo nombre@gmail.com')));
    END IF;
    PERFORM bot_conv_set(v_t, v_from, 'sub_taxid', v_data || jsonb_build_object('email', lower(v_raw)));
    RETURN bot_reply('subscription_flow', jsonb_build_array(bot_msg_text('Por último, ¿tu DNI o CUIT? (solo números)')));

  ELSIF v_state = 'sub_taxid' THEN
    v_doc := regexp_replace(v_raw, '\D', '', 'g');
    IF length(v_doc) NOT BETWEEN 7 AND 11 THEN
      RETURN bot_reply('subscription_flow', jsonb_build_array(bot_msg_text('El DNI tiene 7 u 8 números y el CUIT 11. ¿Me lo pasás de nuevo?')));
    END IF;
    v_data := v_data || jsonb_build_object('tax_id', v_doc);
    PERFORM bot_conv_set(v_t, v_from, 'sub_confirm', v_data);
    RETURN bot_reply('subscription_flow', jsonb_build_array(bot_msg_buttons(
      'Reviso tu alta:' || chr(10) || '• Plan: ' || (v_data->>'plan_name') || ' (' || (v_data->>'price') || ')' || chr(10) ||
      '• Titular: ' || (v_data->>'name') || chr(10) || '• Email: ' || (v_data->>'email') || chr(10) || '• DNI/CUIT: ' || v_doc || chr(10) ||
      '¿Genero el link de pago?',
      '[{"id":"sub:confirm","title":"Sí, generar link"},{"id":"sub:cancel","title":"Cancelar"}]'::jsonb)));

  ELSIF v_state = 'sub_confirm' THEN
    IF ctx->>'reply_id' = 'sub:cancel' OR (ctx->>'reply_id' IS NULL AND bot_is_no(v_raw)) THEN
      PERFORM bot_conv_clear(v_t, v_from);
      RETURN bot_reply('subscription_flow', jsonb_build_array(bot_msg_text('Listo, no generé nada. Si querés retomarlo, escribí "planes".')));
    ELSIF ctx->>'reply_id' = 'sub:confirm' OR bot_is_yes(v_raw) THEN
      INSERT INTO customers (tenant_id, phone, name, email, tax_id)
      VALUES (v_t, v_from, v_data->>'name', v_data->>'email', v_data->>'tax_id')
      ON CONFLICT (tenant_id, phone) DO UPDATE SET name = EXCLUDED.name, email = EXCLUDED.email, tax_id = EXCLUDED.tax_id
      RETURNING id INTO v_cust;
      INSERT INTO subscriptions (tenant_id, customer_id, plan_id, provider)
      VALUES (v_t, v_cust, (v_data->>'plan_id')::uuid, (SELECT provider FROM payment_integrations WHERE tenant_id = v_t AND is_active))
      RETURNING id INTO v_sub;
      PERFORM bot_conv_clear(v_t, v_from);
      RETURN bot_reply('subscription_pending',
        jsonb_build_array(bot_msg_text('Perfecto, estoy generando tu link de pago. Te llega en unos segundos.')),
        jsonb_build_array(jsonb_build_object('type', 'checkout_requested', 'subscription_id', v_sub)));
    END IF;
    RETURN bot_reply('subscription_flow', jsonb_build_array(bot_msg_buttons('¿Genero el link de pago?',
      '[{"id":"sub:confirm","title":"Sí, generar link"},{"id":"sub:cancel","title":"Cancelar"}]'::jsonb)));
  END IF;
  RETURN NULL;
END $$;

-- Todo lo que RF04-CHECKOUT necesita para crear el link de pago
CREATE OR REPLACE FUNCTION bot_rf04_checkout_context(p_sub UUID) RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'subscription_id', s.id, 'tenant_id', s.tenant_id, 'tenant_name', t.name, 'status', s.status,
    'plan', jsonb_build_object('code', p.code, 'name', p.name, 'price', p.price, 'currency', p.currency,
                               'interval', p.billing_interval, 'provider_price_id', p.provider_price_id),
    'customer', jsonb_build_object('name', c.name, 'email', c.email, 'tax_id', c.tax_id, 'phone', c.phone),
    'provider', coalesce(pi.provider, 'none'), 'provider_token', pi.access_token, 'provider_config', coalesce(pi.config, '{}'),
    'notification_url', 'https://n8n.dmglobal.tech/webhook/pagos-' || coalesce(pi.provider, 'none') || '?tenant=' || s.tenant_id,
    'phone_number_id', w.phone_number_id, 'access_token', w.access_token, 'graph_version', w.graph_version, 'to', c.phone)
  FROM subscriptions s
  JOIN tenants t ON t.id = s.tenant_id
  JOIN subscription_plans p ON p.id = s.plan_id
  JOIN customers c ON c.id = s.customer_id
  LEFT JOIN payment_integrations pi ON pi.tenant_id = s.tenant_id AND pi.is_active
  LEFT JOIN LATERAL (SELECT * FROM whatsapp_integrations wi WHERE wi.tenant_id = s.tenant_id AND wi.is_active LIMIT 1) w ON true
  WHERE s.id = p_sub
$$;

CREATE OR REPLACE FUNCTION bot_rf04_checkout_created(p_sub UUID, p_url TEXT, p_ref TEXT) RETURNS VOID LANGUAGE sql AS $$
  UPDATE subscriptions SET checkout_url = p_url, provider_ref = coalesce(p_ref, provider_ref) WHERE id = p_sub
$$;

-- Activa una suscripción tras un pago verificado. Idempotente: un mismo evento no activa dos veces.
CREATE OR REPLACE FUNCTION bot_rf04_activate(p_tenant UUID, p_provider TEXT, p_event_id TEXT, p_sub UUID,
                                             p_provider_ref TEXT, p_period_end TIMESTAMPTZ, p_payload JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE s RECORD; v_first BOOLEAN := false;
BEGIN
  INSERT INTO payment_events (tenant_id, provider, event_id, subscription_id, payload)
  VALUES (p_tenant, p_provider, p_event_id, p_sub, p_payload)
  ON CONFLICT (provider, event_id) DO NOTHING;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', true, 'duplicate', true); END IF;

  SELECT * INTO s FROM subscriptions WHERE id = p_sub AND tenant_id = p_tenant FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'subscription not found for tenant'); END IF;
  IF s.status <> 'active' THEN
    v_first := s.activated_at IS NULL;
    UPDATE subscriptions SET status = 'active', activated_at = coalesce(activated_at, NOW()),
           provider = p_provider, provider_ref = coalesce(p_provider_ref, provider_ref),
           current_period_end = coalesce(p_period_end, NOW() + CASE (SELECT billing_interval FROM subscription_plans WHERE id = s.plan_id)
                                                                 WHEN 'year' THEN INTERVAL '1 year' ELSE INTERVAL '1 month' END)
     WHERE id = p_sub;
  END IF;
  RETURN jsonb_build_object('ok', true, 'duplicate', false, 'first_activation', v_first) || bot_rf04_checkout_context(p_sub);
END $$;
