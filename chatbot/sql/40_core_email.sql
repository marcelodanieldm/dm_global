-- CORE-04: emails transaccionales (fases 3 y 4) y piezas compartidas.
-- Los flujos no mandan emails directo: los encolan en email_outbox con una clave que evita duplicados.
-- El workflow CORE-04 toma los pendientes y los manda por la cuenta de cada cliente (SendGrid) o simulado (mock).

-- URL pública de n8n (links de pago, baja, páginas)
CREATE OR REPLACE FUNCTION bot_public_url() RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$ SELECT 'https://n8n.dmglobal.tech' $$;

-- Clave para webhooks de sistemas del cliente (Tiendanube, WordPress): /webhook/rf05-carrito?key=...
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS hook_secret TEXT UNIQUE DEFAULT encode(gen_random_bytes(18), 'hex');
UPDATE tenants SET hook_secret = encode(gen_random_bytes(18), 'hex') WHERE hook_secret IS NULL;
CREATE OR REPLACE FUNCTION bot_tenant_by_hook(p_key TEXT) RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT id FROM tenants WHERE is_active AND hook_secret = p_key AND length(coalesce(p_key, '')) >= 20
$$;

CREATE TABLE IF NOT EXISTS email_integrations (
  tenant_id UUID PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
  provider VARCHAR(20) NOT NULL CHECK (provider IN ('sendgrid', 'mock')),
  api_key TEXT,                       -- SendGrid: API key con permiso Mail Send
  from_email VARCHAR(200) NOT NULL,   -- remitente verificado en SendGrid
  from_name VARCHAR(150),
  reply_to VARCHAR(200),
  is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS email_outbox (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  kind VARCHAR(40) NOT NULL,          -- rf04_welcome, rf05_cart, rf06_payment, rf07_renewal, rf08_cancelled...
  dedupe_key TEXT NOT NULL,           -- p. ej. id de suscripción + fin de período
  to_email VARCHAR(200) NOT NULL,
  to_name VARCHAR(150),
  subject VARCHAR(250) NOT NULL,
  html TEXT NOT NULL,
  text TEXT NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts INTEGER NOT NULL DEFAULT 0,
  provider_ref TEXT,
  error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sent_at TIMESTAMPTZ,
  UNIQUE (tenant_id, kind, dedupe_key)
);
CREATE INDEX IF NOT EXISTS email_outbox_pending_idx ON email_outbox (created_at) WHERE status IN ('pending', 'sending');

-- Plantilla HTML simple y compatible con clientes de correo (tablas, estilos en línea)
CREATE OR REPLACE FUNCTION bot_html_escape(t TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;
-- p_lines: párrafos en texto plano (se escapan). p_rows: filas de detalle [["Plan","Full"],...]
CREATE OR REPLACE FUNCTION bot_email_html(p_brand TEXT, p_title TEXT, p_lines TEXT[], p_rows JSONB DEFAULT '[]',
                                          p_button TEXT DEFAULT NULL, p_url TEXT DEFAULT NULL, p_footer TEXT DEFAULT NULL)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT '<!doctype html><html><body style="margin:0;background:#f4f4f5;font-family:Arial,Helvetica,sans-serif;color:#18181b">'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:8px">'
    || '<tr><td style="padding:20px 28px;border-bottom:1px solid #e4e4e7;font-size:14px;color:#52525b">' || bot_html_escape(p_brand) || '</td></tr>'
    || '<tr><td style="padding:28px"><h1 style="margin:0 0 16px;font-size:22px">' || bot_html_escape(p_title) || '</h1>'
    || coalesce((SELECT string_agg('<p style="margin:0 0 14px;font-size:15px;line-height:1.5">' || bot_html_escape(l) || '</p>', '') FROM unnest(p_lines) l), '')
    || CASE WHEN jsonb_array_length(coalesce(p_rows, '[]')) > 0 THEN
         '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:8px 0 18px;font-size:14px">'
         || (SELECT string_agg('<tr><td style="padding:8px 0;border-bottom:1px solid #f4f4f5;color:#71717a">' || bot_html_escape(r->>0)
                 || '</td><td align="right" style="padding:8px 0;border-bottom:1px solid #f4f4f5">' || bot_html_escape(r->>1) || '</td></tr>', '')
               FROM jsonb_array_elements(p_rows) r) || '</table>' ELSE '' END
    || CASE WHEN p_url IS NOT NULL THEN
         '<p style="margin:22px 0"><a href="' || bot_html_escape(p_url) || '" style="background:#2563eb;color:#ffffff;text-decoration:none;padding:12px 22px;border-radius:6px;font-size:15px;display:inline-block">'
         || bot_html_escape(coalesce(p_button, 'Abrir')) || '</a></p>' ELSE '' END
    || '</td></tr>'
    || CASE WHEN p_footer IS NOT NULL THEN '<tr><td style="padding:16px 28px;border-top:1px solid #e4e4e7;font-size:12px;color:#71717a">' || p_footer || '</td></tr>' ELSE '' END
    || '</table></td></tr></table></body></html>'
$$;
CREATE OR REPLACE FUNCTION bot_email_text(p_title TEXT, p_lines TEXT[], p_rows JSONB DEFAULT '[]', p_url TEXT DEFAULT NULL) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT p_title || chr(10) || chr(10) || array_to_string(p_lines, chr(10) || chr(10))
    || coalesce(chr(10) || chr(10) || (SELECT string_agg((r->>0) || ': ' || (r->>1), chr(10)) FROM jsonb_array_elements(coalesce(p_rows, '[]')) r), '')
    || coalesce(chr(10) || chr(10) || p_url, '')
$$;

-- Encola un email. Devuelve el id, o NULL si ya existía (misma clave) o no hay destinatario.
CREATE OR REPLACE FUNCTION bot_email_enqueue(p_tenant UUID, p_kind TEXT, p_key TEXT, p_to TEXT, p_name TEXT,
                                             p_subject TEXT, p_html TEXT, p_text TEXT) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  IF coalesce(p_to, '') !~* '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' THEN RETURN NULL; END IF;
  INSERT INTO email_outbox (tenant_id, kind, dedupe_key, to_email, to_name, subject, html, text)
  VALUES (p_tenant, p_kind, p_key, lower(p_to), p_name, left(p_subject, 250), p_html, p_text)
  ON CONFLICT (tenant_id, kind, dedupe_key) DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- CORE-04 toma hasta p_limit emails pendientes (cada fila con las credenciales de su cliente)
CREATE OR REPLACE FUNCTION bot_email_claim(p_limit INTEGER DEFAULT 50)
RETURNS TABLE (id UUID, tenant_id UUID, provider TEXT, api_key TEXT, from_email TEXT, from_name TEXT, reply_to TEXT,
               to_email TEXT, to_name TEXT, subject TEXT, html TEXT, text TEXT) LANGUAGE plpgsql AS $$
BEGIN
  -- Los que quedaron "enviando" por una ejecución cortada vuelven a la cola; tras 5 intentos fallan
  UPDATE email_outbox o SET status = 'pending' WHERE o.status = 'sending' AND o.created_at < NOW() - INTERVAL '15 minutes' AND o.attempts < 5;
  UPDATE email_outbox o SET status = 'failed', error = coalesce(o.error, 'demasiados intentos') WHERE o.status = 'sending' AND o.attempts >= 5;
  -- Sin proveedor configurado: se marca y no se reintenta
  UPDATE email_outbox o SET status = 'skipped', error = 'el cliente no tiene email_integrations activo'
   WHERE o.status = 'pending' AND NOT EXISTS (SELECT 1 FROM email_integrations ei WHERE ei.tenant_id = o.tenant_id AND ei.is_active);
  RETURN QUERY
  WITH c AS (
    SELECT o.id FROM email_outbox o WHERE o.status = 'pending' ORDER BY o.created_at LIMIT p_limit FOR UPDATE SKIP LOCKED
  ), u AS (
    UPDATE email_outbox o SET status = 'sending', attempts = o.attempts + 1 FROM c WHERE o.id = c.id RETURNING o.*
  )
  SELECT u.id, u.tenant_id, ei.provider::text, ei.api_key, ei.from_email::text, coalesce(ei.from_name, t.name)::text, ei.reply_to::text,
         u.to_email::text, u.to_name::text, u.subject::text, u.html, u.text
    FROM u JOIN email_integrations ei ON ei.tenant_id = u.tenant_id JOIN tenants t ON t.id = u.tenant_id;
END $$;

CREATE OR REPLACE FUNCTION bot_email_result(p_id UUID, p_ok BOOLEAN, p_ref TEXT, p_error TEXT) RETURNS VOID LANGUAGE sql AS $$
  UPDATE email_outbox SET status = CASE WHEN p_ok THEN 'sent' WHEN attempts >= 5 THEN 'failed' ELSE 'pending' END,
         sent_at = CASE WHEN p_ok THEN NOW() END, provider_ref = nullif(p_ref, ''), error = CASE WHEN p_ok THEN NULL ELSE left(p_error, 1000) END
   WHERE id = p_id
$$;

-- Datos del cliente para armar mensajes de WhatsApp desde tareas programadas
CREATE OR REPLACE FUNCTION bot_wa_target(p_tenant UUID, p_to TEXT, p_message JSONB) RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('tenant_id', p_tenant, 'phone_number_id', w.phone_number_id, 'access_token', w.access_token,
                            'graph_version', w.graph_version, 'to', p_to, 'message', p_message)
    FROM whatsapp_integrations w WHERE w.tenant_id = p_tenant AND w.is_active ORDER BY w.created_at LIMIT 1
$$;

-- Fecha legible en la zona del cliente
CREATE OR REPLACE FUNCTION bot_tenant_tz(p_tenant UUID) RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT coalesce(settings->>'timezone', 'America/Argentina/Buenos_Aires') FROM tenants WHERE id = p_tenant
$$;
CREATE OR REPLACE FUNCTION bot_fmt_date(p TIMESTAMPTZ, p_tz TEXT) RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT to_char(p AT TIME ZONE p_tz, 'DD/MM/YYYY')
$$;
CREATE OR REPLACE FUNCTION bot_tenant_feature(p_tenant UUID, f TEXT) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT coalesce((settings #>> ARRAY['features', f])::boolean, false) FROM tenants WHERE id = p_tenant AND is_active
$$;

-- RF-04 criterio 4: email de bienvenida al activarse la suscripción
CREATE OR REPLACE FUNCTION bot_rf04_welcome_email(p_sub UUID) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE c JSONB := bot_rf04_checkout_context(p_sub); v_tz TEXT; v_rows JSONB;
BEGIN
  IF c IS NULL THEN RETURN NULL; END IF;
  v_tz := bot_tenant_tz((c->>'tenant_id')::uuid);
  v_rows := jsonb_build_array(
    jsonb_build_array('Plan', c #>> '{plan,name}'),
    jsonb_build_array('Importe', bot_money((c #>> '{plan,price}')::numeric, c #>> '{plan,currency}') ||
                      CASE c #>> '{plan,interval}' WHEN 'year' THEN ' por año' ELSE ' por mes' END),
    jsonb_build_array('Próximo cobro', coalesce(bot_fmt_date((c->>'current_period_end')::timestamptz, v_tz), '-')),
    jsonb_build_array('Titular', c #>> '{customer,name}'));
  RETURN bot_email_enqueue((c->>'tenant_id')::uuid, 'rf04_welcome', p_sub::text, c #>> '{customer,email}', c #>> '{customer,name}',
    '¡Bienvenido/a a ' || (c->>'tenant_name') || '! Tu suscripción está activa',
    bot_email_html(c->>'tenant_name', '¡Tu suscripción está activa!',
      ARRAY['Hola ' || (c #>> '{customer,name}') || ', recibimos tu pago y ya tenés acceso al plan ' || (c #>> '{plan,name}') || '.',
            'Desde este link podés ver tu suscripción o darla de baja cuando quieras.'],
      v_rows, 'Gestionar mi suscripción', c->>'manage_url'),
    bot_email_text('¡Tu suscripción está activa!', ARRAY['Hola ' || (c #>> '{customer,name}') || ', recibimos tu pago.'], v_rows, c->>'manage_url'));
END $$;

-- Evento listo para RF02-NOTIFY desde un workflow que no pasa por el motor (baja por la web, etc.)
CREATE OR REPLACE FUNCTION bot_notify_payload(p_tenant UUID, p_event JSONB) RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT p_event || jsonb_build_object('tenant_id', t.id, 'tenant_name', t.name,
           'channel', coalesce(t.settings #>> '{notify,channel}', 'whatsapp'), 'to', t.settings #>> '{notify,to}',
           'template', t.settings #>> '{notify,template}', 'phone_number_id', w.phone_number_id,
           'access_token', w.access_token, 'graph_version', w.graph_version)
    FROM tenants t
    LEFT JOIN LATERAL (SELECT * FROM whatsapp_integrations wi WHERE wi.tenant_id = t.id AND wi.is_active ORDER BY created_at LIMIT 1) w ON true
   WHERE t.id = p_tenant
$$;
