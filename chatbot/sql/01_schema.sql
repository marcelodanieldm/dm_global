-- Chatbot AI Low-cost · Fase 1 (RF-01 FAQs + RF-02 Leads) · esquema multi-tenant
-- Idempotente: se puede volver a correr sin perder datos.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE TABLE IF NOT EXISTS plans (
  tier VARCHAR(50) PRIMARY KEY,
  monthly_message_limit INTEGER            -- NULL = sin límite
);
INSERT INTO plans VALUES ('starter', 1000), ('pro', 5000), ('enterprise', NULL)
ON CONFLICT (tier) DO NOTHING;

CREATE TABLE IF NOT EXISTS tenants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(150) NOT NULL,
  plan_tier VARCHAR(50) NOT NULL DEFAULT 'starter' REFERENCES plans(tier),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  settings JSONB NOT NULL DEFAULT '{}'::jsonb,   -- textos del bot y canal de aviso a ventas
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS whatsapp_integrations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone_number_id VARCHAR(100) UNIQUE NOT NULL,
  waba_id VARCHAR(100) NOT NULL,
  access_token TEXT NOT NULL,
  webhook_verify_token VARCHAR(255) NOT NULL,
  graph_version VARCHAR(10) NOT NULL DEFAULT 'v21.0',
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS data_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  source_type VARCHAR(30) NOT NULL CHECK (source_type IN ('google_sheets', 'odoo')),
  config JSONB NOT NULL DEFAULT '{}'::jsonb,     -- sheets: {spreadsheet_id, sheet}; odoo: {url, db, user, model}
  sync_interval_min INTEGER NOT NULL DEFAULT 30,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  last_synced_at TIMESTAMPTZ,
  last_status TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS knowledge_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  source_id UUID REFERENCES data_sources(id) ON DELETE SET NULL,
  external_key TEXT NOT NULL,
  category VARCHAR(100),
  keywords TEXT[] NOT NULL DEFAULT '{}',
  question TEXT NOT NULL,
  answer_text TEXT NOT NULL,
  media_url TEXT,
  media_type VARCHAR(20) CHECK (media_type IN ('image', 'document') OR media_type IS NULL),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, external_key)
);
CREATE INDEX IF NOT EXISTS knowledge_items_tenant_idx ON knowledge_items (tenant_id) WHERE is_active;

CREATE TABLE IF NOT EXISTS interaction_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  channel VARCHAR(20) NOT NULL DEFAULT 'whatsapp',
  wa_message_id TEXT UNIQUE,
  sender_phone VARCHAR(50) NOT NULL,
  incoming_message TEXT NOT NULL,
  matched_knowledge_id UUID REFERENCES knowledge_items(id) ON DELETE SET NULL,
  match_score REAL,
  reply_text TEXT,
  status VARCHAR(50) NOT NULL,   -- resolved, escalated_rf02, unrecognized, lead_flow, lead_created, greeting, quota_exceeded
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS interaction_logs_tenant_month_idx ON interaction_logs (tenant_id, created_at);

CREATE TABLE IF NOT EXISTS conversations (
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone VARCHAR(50) NOT NULL,
  state VARCHAR(30) NOT NULL,     -- offer_lead, lead_name, lead_product, lead_confirm
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, phone)
);

CREATE TABLE IF NOT EXISTS leads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone VARCHAR(50) NOT NULL,
  name VARCHAR(150) NOT NULL,
  product_interest TEXT NOT NULL,
  tag VARCHAR(100) NOT NULL DEFAULT 'Lead Calificado - Chatbot',
  source VARCHAR(30) NOT NULL DEFAULT 'whatsapp',
  status VARCHAR(30) NOT NULL DEFAULT 'new',
  crm_sync_status VARCHAR(30) NOT NULL DEFAULT 'pending',   -- pending, synced, failed, not_configured
  crm_ref TEXT,
  notified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS human_handovers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone VARCHAR(50) NOT NULL,
  message TEXT NOT NULL,
  reason VARCHAR(50) NOT NULL,     -- unrecognized, asked_for_agent
  status VARCHAR(30) NOT NULL DEFAULT 'open',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Normaliza texto: minúsculas, sin acentos ni signos, espacios simples
CREATE OR REPLACE FUNCTION bot_norm(t TEXT) RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT trim(regexp_replace(regexp_replace(lower(unaccent(coalesce(t, ''))), '[^a-z0-9ñ ]', ' ', 'g'), '\s+', ' ', 'g'))
$$;

CREATE OR REPLACE FUNCTION bot_is_yes(t TEXT) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT bot_norm(t) ~ '^(si|sí|s|dale|ok|okay|okey|claro|confirmo|correcto|esta bien|de acuerdo|yes|perfecto)( |$)'
$$;

CREATE OR REPLACE FUNCTION bot_is_no(t TEXT) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT bot_norm(t) ~ '^(no|nop|nah|negativo|para nada|no gracias)( |$)'
$$;

-- Verificación del webhook de Meta (GET hub.verify_token)
CREATE OR REPLACE FUNCTION bot_verify_token(p_token TEXT) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM whatsapp_integrations WHERE is_active AND webhook_verify_token = p_token)
$$;

-- Motor principal: recibe un mensaje y devuelve qué responder y a quién avisar.
-- p jsonb: {phone_number_id, from, text, message_id, contact_name, channel}
CREATE OR REPLACE FUNCTION bot_handle_message(p JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_pnid TEXT := p->>'phone_number_id';
  v_from TEXT := p->>'from';
  v_raw  TEXT := left(coalesce(p->>'text', ''), 2000);
  v_msg  TEXT := bot_norm(p->>'text');
  v_mid  TEXT := nullif(p->>'message_id', '');
  v_chan TEXT := coalesce(p->>'channel', 'whatsapp');
  t RECORD; c RECORD; k RECORD;
  v_limit INTEGER; v_used INTEGER;
  v_settings JSONB;
  v_reply TEXT; v_status TEXT; v_kid UUID; v_score REAL;
  v_media JSONB := NULL;
  v_notify JSONB := '[]'::jsonb;
  v_lead_id UUID;
BEGIN
  IF v_mid IS NOT NULL AND EXISTS (SELECT 1 FROM interaction_logs WHERE wa_message_id = v_mid) THEN
    RETURN jsonb_build_object('action', 'ignore', 'reason', 'duplicate');
  END IF;

  SELECT tn.id, tn.name, tn.plan_tier, tn.settings, w.access_token, w.phone_number_id, w.graph_version
    INTO t
    FROM whatsapp_integrations w JOIN tenants tn ON tn.id = w.tenant_id
   WHERE w.phone_number_id = v_pnid AND w.is_active AND tn.is_active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('action', 'ignore', 'reason', 'unknown_or_inactive_number');
  END IF;

  v_settings := jsonb_build_object(
      'welcome_text', '¡Hola! Soy el asistente virtual de ' || t.name || '. Contame tu consulta (precios, horarios, envíos…) y te respondo al instante.',
      'fallback_text', 'No encontré una respuesta para eso. ¿Querés que un asesor te contacte? Respondé SÍ o NO.',
      'ask_name_text', '¡Genial! Para que un asesor te contacte, ¿cómo te llamás?',
      'lead_done_text', '¡Listo, {name}! Registré tu interés en "{product}". Un asesor te va a escribir a la brevedad.',
      'no_lead_text', 'Perfecto. Si tenés otra consulta, escribime cuando quieras.'
    ) || coalesce(t.settings, '{}'::jsonb);

  -- TC-04 / plan: límite mensual de mensajes
  SELECT monthly_message_limit INTO v_limit FROM plans WHERE tier = t.plan_tier;
  IF v_limit IS NOT NULL THEN
    SELECT count(*) INTO v_used FROM interaction_logs
     WHERE tenant_id = t.id AND status <> 'quota_exceeded' AND created_at >= date_trunc('month', NOW());
    IF v_used >= v_limit THEN
      INSERT INTO interaction_logs (tenant_id, channel, wa_message_id, sender_phone, incoming_message, status)
      VALUES (t.id, v_chan, v_mid, v_from, v_raw, 'quota_exceeded');
      RETURN jsonb_build_object('action', 'ignore', 'reason', 'quota_exceeded', 'tenant_id', t.id);
    END IF;
  END IF;

  DELETE FROM conversations WHERE tenant_id = t.id AND phone = v_from AND updated_at < NOW() - INTERVAL '30 minutes';
  SELECT * INTO c FROM conversations WHERE tenant_id = t.id AND phone = v_from;

  IF FOUND AND v_msg ~ '^(cancelar|salir|menu|reiniciar)$' THEN
    DELETE FROM conversations WHERE tenant_id = t.id AND phone = v_from;
    v_reply := v_settings->>'no_lead_text'; v_status := 'lead_flow';
  ELSIF FOUND AND c.state = 'offer_lead' AND bot_is_yes(v_raw) THEN
    UPDATE conversations SET state = 'lead_name', updated_at = NOW() WHERE tenant_id = t.id AND phone = v_from;
    v_reply := v_settings->>'ask_name_text'; v_status := 'lead_flow';
  ELSIF FOUND AND c.state = 'offer_lead' AND bot_is_no(v_raw) THEN
    DELETE FROM conversations WHERE tenant_id = t.id AND phone = v_from;
    v_reply := v_settings->>'no_lead_text'; v_status := 'lead_flow';
  ELSIF FOUND AND c.state = 'lead_name' THEN
    UPDATE conversations SET state = 'lead_product', updated_at = NOW(),
           data = data || jsonb_build_object('name', left(trim(v_raw), 150))
     WHERE tenant_id = t.id AND phone = v_from;
    v_reply := 'Gracias, ' || left(trim(v_raw), 60) || '. ¿Qué producto o servicio te interesa?';
    v_status := 'lead_flow';
  ELSIF FOUND AND c.state = 'lead_product' THEN
    UPDATE conversations SET state = 'lead_confirm', updated_at = NOW(),
           data = data || jsonb_build_object('product', left(trim(v_raw), 500))
     WHERE tenant_id = t.id AND phone = v_from;
    v_reply := 'Confirmo tus datos:' || chr(10) || '• Nombre: ' || (c.data->>'name') || chr(10) ||
               '• Interés: ' || left(trim(v_raw), 200) || chr(10) || '¿Está bien? Respondé SÍ o NO.';
    v_status := 'lead_flow';
  ELSIF FOUND AND c.state = 'lead_confirm' AND bot_is_yes(v_raw) THEN
    INSERT INTO leads (tenant_id, phone, name, product_interest, source)
    VALUES (t.id, v_from, c.data->>'name', c.data->>'product', v_chan)
    RETURNING id INTO v_lead_id;
    DELETE FROM conversations WHERE tenant_id = t.id AND phone = v_from;
    v_reply := replace(replace(v_settings->>'lead_done_text', '{name}', c.data->>'name'), '{product}', c.data->>'product');
    v_status := 'lead_created';
    v_notify := v_notify || jsonb_build_object('type', 'new_lead', 'lead_id', v_lead_id,
      'text', '🟢 Nuevo lead (' || t.name || ')' || chr(10) || 'Nombre: ' || (c.data->>'name') || chr(10) ||
              'Interés: ' || (c.data->>'product') || chr(10) || 'WhatsApp: +' || v_from || chr(10) ||
              'Etiqueta: Lead Calificado - Chatbot');
  ELSIF FOUND AND c.state = 'lead_confirm' THEN
    UPDATE conversations SET state = 'lead_name', data = '{}'::jsonb, updated_at = NOW() WHERE tenant_id = t.id AND phone = v_from;
    v_reply := 'Sin problema, empecemos de nuevo. ¿Cómo te llamás?'; v_status := 'lead_flow';
  END IF;

  IF v_reply IS NULL THEN
    IF FOUND THEN  -- estaba en offer_lead y escribió otra cosa: lo tratamos como nueva consulta
      DELETE FROM conversations WHERE tenant_id = t.id AND phone = v_from;
    END IF;

    IF v_msg ~ '(^| )(asesor|agente|humano|persona|vendedor|vendedora|representante|contactenme|llamenme|hablar con alguien)( |$)' THEN
      INSERT INTO conversations (tenant_id, phone, state) VALUES (t.id, v_from, 'lead_name')
      ON CONFLICT (tenant_id, phone) DO UPDATE SET state = 'lead_name', data = '{}'::jsonb, updated_at = NOW();
      INSERT INTO human_handovers (tenant_id, phone, message, reason) VALUES (t.id, v_from, v_raw, 'asked_for_agent');
      v_reply := v_settings->>'ask_name_text'; v_status := 'escalated_rf02';
    ELSE
      SELECT ki.id, ki.answer_text, ki.media_url, ki.media_type,
             (SELECT count(*) FROM unnest(ki.keywords) kw
               WHERE length(bot_norm(kw)) >= 3 AND position(' ' || bot_norm(kw) IN ' ' || v_msg) > 0) AS hits,
             similarity(bot_norm(ki.question), v_msg) AS sim
        INTO k
        FROM knowledge_items ki
       WHERE ki.tenant_id = t.id AND ki.is_active
       ORDER BY hits DESC, sim DESC
       LIMIT 1;

      IF FOUND AND (k.hits >= 1 OR k.sim >= 0.45) THEN
        v_reply := k.answer_text; v_kid := k.id; v_status := 'resolved';
        v_score := CASE WHEN k.hits >= 1 THEN k.hits ELSE k.sim END;
        IF k.media_url IS NOT NULL AND k.media_type IS NOT NULL THEN
          v_media := jsonb_build_object('type', k.media_type, 'link', k.media_url);
        END IF;
      ELSIF v_msg ~ '^(hola|holi|buenas|buen dia|buenos dias|buenas tardes|buenas noches|hey|hi|hello)( |$)' AND length(v_msg) <= 40 THEN
        v_reply := v_settings->>'welcome_text'; v_status := 'greeting';
      ELSE
        INSERT INTO conversations (tenant_id, phone, state) VALUES (t.id, v_from, 'offer_lead')
        ON CONFLICT (tenant_id, phone) DO UPDATE SET state = 'offer_lead', data = '{}'::jsonb, updated_at = NOW();
        INSERT INTO human_handovers (tenant_id, phone, message, reason) VALUES (t.id, v_from, v_raw, 'unrecognized');
        v_reply := v_settings->>'fallback_text'; v_status := 'escalated_rf02';
        v_notify := v_notify || jsonb_build_object('type', 'handover',
          'text', '🟡 Consulta sin respuesta (' || t.name || ')' || chr(10) || 'De: +' || v_from || chr(10) ||
                  'Mensaje: ' || left(v_raw, 300));
      END IF;
    END IF;
  END IF;

  INSERT INTO interaction_logs (tenant_id, channel, wa_message_id, sender_phone, incoming_message,
                                matched_knowledge_id, match_score, reply_text, status)
  VALUES (t.id, v_chan, v_mid, v_from, v_raw, v_kid, v_score, v_reply, v_status);

  RETURN jsonb_build_object(
    'action', 'reply',
    'tenant_id', t.id,
    'tenant_name', t.name,
    'status', v_status,
    'to', v_from,
    'phone_number_id', t.phone_number_id,
    'access_token', t.access_token,
    'graph_version', t.graph_version,
    'messages', CASE WHEN v_media IS NULL
                     THEN jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_reply))
                     ELSE jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_reply), v_media) END,
    'notify', CASE WHEN jsonb_array_length(v_notify) = 0 THEN '[]'::jsonb
                   ELSE (SELECT jsonb_agg(n || jsonb_build_object(
                           'channel', coalesce(v_settings #>> '{notify,channel}', 'whatsapp'),
                           'to', v_settings #>> '{notify,to}',
                           'template', v_settings #>> '{notify,template}'))
                         FROM jsonb_array_elements(v_notify) n) END
  );
END $$;

-- Sincronización de la caché (TC-31..34): upsert de los ítems de una fuente y baja de los que ya no están
CREATE OR REPLACE FUNCTION bot_sync_knowledge(p_source_id UUID, p_items JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  s RECORD; v_upserted INTEGER := 0; v_disabled INTEGER := 0; it JSONB; v_key TEXT;
  v_keys TEXT[] := '{}';
BEGIN
  SELECT * INTO s FROM data_sources WHERE id = p_source_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'source not found'); END IF;

  FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) LOOP
    CONTINUE WHEN coalesce(trim(it->>'question'), '') = '' OR coalesce(trim(it->>'answer_text'), '') = '';
    v_key := coalesce(nullif(trim(it->>'external_key'), ''), md5(bot_norm(it->>'question')));
    v_keys := v_keys || v_key;
    INSERT INTO knowledge_items AS ki (tenant_id, source_id, external_key, category, keywords, question,
                                       answer_text, media_url, media_type, is_active, updated_at)
    VALUES (s.tenant_id, s.id, v_key, nullif(trim(it->>'category'), ''),
            coalesce((SELECT array_agg(trim(x)) FROM jsonb_array_elements_text(coalesce(it->'keywords', '[]'::jsonb)) x WHERE trim(x) <> ''), '{}'),
            trim(it->>'question'), trim(it->>'answer_text'),
            nullif(trim(it->>'media_url'), ''),
            CASE WHEN lower(trim(coalesce(it->>'media_type', ''))) IN ('image', 'document') THEN lower(trim(it->>'media_type'))
                 WHEN lower(trim(coalesce(it->>'media_type', ''))) IN ('imagen') THEN 'image'
                 WHEN lower(trim(coalesce(it->>'media_type', ''))) IN ('pdf', 'documento') THEN 'document' END,
            coalesce((it->>'is_active')::boolean, true), NOW())
    ON CONFLICT (tenant_id, external_key) DO UPDATE
      SET source_id = EXCLUDED.source_id, category = EXCLUDED.category, keywords = EXCLUDED.keywords,
          question = EXCLUDED.question, answer_text = EXCLUDED.answer_text, media_url = EXCLUDED.media_url,
          media_type = EXCLUDED.media_type, is_active = EXCLUDED.is_active, updated_at = NOW();
    v_upserted := v_upserted + 1;
  END LOOP;

  UPDATE knowledge_items SET is_active = false, updated_at = NOW()
   WHERE source_id = s.id AND is_active AND NOT (external_key = ANY (v_keys));
  GET DIAGNOSTICS v_disabled = ROW_COUNT;

  UPDATE data_sources SET last_synced_at = NOW(),
         last_status = 'ok: ' || v_upserted || ' ítems, ' || v_disabled || ' dados de baja'
   WHERE id = s.id;
  RETURN jsonb_build_object('ok', true, 'source_id', s.id, 'upserted', v_upserted, 'disabled', v_disabled);
END $$;

CREATE OR REPLACE FUNCTION bot_sync_failed(p_source_id UUID, p_error TEXT) RETURNS VOID LANGUAGE sql AS $$
  UPDATE data_sources SET last_status = 'error: ' || left(coalesce(p_error, '?'), 500) WHERE id = p_source_id
$$;

CREATE OR REPLACE FUNCTION bot_lead_notified(p_lead_id UUID) RETURNS VOID LANGUAGE sql AS $$
  UPDATE leads SET notified_at = NOW() WHERE id = p_lead_id
$$;
