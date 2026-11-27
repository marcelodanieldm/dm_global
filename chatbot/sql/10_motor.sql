-- Motor del chatbot: utilidades, despachador y flujos RF-01 (FAQs) y RF-02 (lead).
-- Cada flujo expone bot_<rf>_start(ctx) y/o bot_<rf>_step(ctx). Devuelven NULL si no aplican, o
-- {status, messages[], notify[], kid?, score?}. El despachador decide a cuál llamar.
-- ctx = {tenant_id, tenant_name, settings, from, raw, msg, reply_id, contact_name, channel, state, data}

-- ---------- utilidades ----------
CREATE OR REPLACE FUNCTION bot_norm(t TEXT) RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT trim(regexp_replace(regexp_replace(lower(unaccent(coalesce(t, ''))), '[^a-z0-9ñ ]', ' ', 'g'), '\s+', ' ', 'g'))
$$;
CREATE OR REPLACE FUNCTION bot_is_yes(t TEXT) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT bot_norm(t) ~ '^(si|s|dale|ok|okay|okey|claro|confirmo|confirmar|correcto|esta bien|de acuerdo|yes|perfecto)( |$)'
$$;
CREATE OR REPLACE FUNCTION bot_is_no(t TEXT) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT bot_norm(t) ~ '^(no|nop|nah|negativo|para nada|no gracias|cambiar|otro)( |$)'
$$;
CREATE OR REPLACE FUNCTION bot_verify_token(p_token TEXT) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM whatsapp_integrations WHERE is_active AND webhook_verify_token = p_token)
$$;
CREATE OR REPLACE FUNCTION bot_feature(ctx JSONB, f TEXT) RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce((ctx #>> ARRAY['settings', 'features', f])::boolean, false)
$$;

-- Mensajes en el formato interno que entiende CORE-02
CREATE OR REPLACE FUNCTION bot_msg_text(t TEXT) RETURNS JSONB LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('type', 'text', 'text', t)
$$;
-- Lista interactiva (hasta 10 filas; título <= 24, descripción <= 72 caracteres)
CREATE OR REPLACE FUNCTION bot_msg_list(body TEXT, button TEXT, rows JSONB) RETURNS JSONB LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('type', 'interactive', 'interactive', jsonb_build_object(
    'type', 'list', 'body', jsonb_build_object('text', body),
    'action', jsonb_build_object('button', left(button, 20), 'sections', jsonb_build_array(jsonb_build_object(
      'title', 'Opciones',
      'rows', (SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                 'id', r->>'id', 'title', left(r->>'title', 24), 'description', left(r->>'description', 72)))), '[]'::jsonb)
               FROM (SELECT r FROM jsonb_array_elements(rows) r LIMIT 10) x))))))
$$;
-- Botones (hasta 3; título <= 20 caracteres)
CREATE OR REPLACE FUNCTION bot_msg_buttons(body TEXT, buttons JSONB) RETURNS JSONB LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('type', 'interactive', 'interactive', jsonb_build_object(
    'type', 'button', 'body', jsonb_build_object('text', body),
    'action', jsonb_build_object('buttons', (SELECT jsonb_agg(jsonb_build_object('type', 'reply',
        'reply', jsonb_build_object('id', b->>'id', 'title', left(b->>'title', 20))))
      FROM (SELECT b FROM jsonb_array_elements(buttons) b LIMIT 3) x))))
$$;
-- Respuesta con texto plano + versión de opciones numeradas (para canales sin interactivos y para el log)
CREATE OR REPLACE FUNCTION bot_options_text(rows JSONB) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT string_agg(n || '. ' || (r->>'title'), chr(10) ORDER BY n)
  FROM jsonb_array_elements(rows) WITH ORDINALITY AS x(r, n)
$$;
-- Elige una opción: por id de respuesta interactiva, por número ("2") o por el texto del título
CREATE OR REPLACE FUNCTION bot_pick(ctx JSONB, options JSONB) RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT o->>'id' FROM jsonb_array_elements(options) o WHERE o->>'id' = ctx->>'reply_id' LIMIT 1),
    (SELECT o->>'id' FROM jsonb_array_elements(options) WITH ORDINALITY x(o, n)
      WHERE (ctx->>'msg') ~ '^[0-9]{1,2}$' AND n = (ctx->>'msg')::int),
    (SELECT o->>'id' FROM jsonb_array_elements(options) o WHERE bot_norm(o->>'title') = ctx->>'msg' LIMIT 1),
    (SELECT o->>'id' FROM jsonb_array_elements(options) o
      WHERE length(ctx->>'msg') >= 3 AND position(ctx->>'msg' IN bot_norm(o->>'title')) > 0 LIMIT 1))
$$;

CREATE OR REPLACE FUNCTION bot_conv_set(p_tenant UUID, p_phone TEXT, p_state TEXT, p_data JSONB) RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO conversations (tenant_id, phone, state, data) VALUES (p_tenant, p_phone, p_state, coalesce(p_data, '{}'))
  ON CONFLICT (tenant_id, phone) DO UPDATE SET state = EXCLUDED.state, data = EXCLUDED.data, updated_at = NOW()
$$;
CREATE OR REPLACE FUNCTION bot_conv_clear(p_tenant UUID, p_phone TEXT) RETURNS VOID LANGUAGE sql AS $$
  DELETE FROM conversations WHERE tenant_id = p_tenant AND phone = p_phone
$$;
CREATE OR REPLACE FUNCTION bot_reply(p_status TEXT, p_messages JSONB, p_notify JSONB DEFAULT '[]') RETURNS JSONB LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('status', p_status, 'messages', p_messages, 'notify', coalesce(p_notify, '[]'::jsonb))
$$;

-- ---------- RF-01: FAQs ----------
CREATE OR REPLACE FUNCTION bot_rf01_faq(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql STABLE AS $$
DECLARE k RECORD; v_msgs JSONB;
BEGIN
  SELECT ki.id, ki.answer_text, ki.media_url, ki.media_type,
         (SELECT count(*) FROM unnest(ki.keywords) kw
           WHERE length(bot_norm(kw)) >= 3 AND position(' ' || bot_norm(kw) IN ' ' || (ctx->>'msg')) > 0) AS hits,
         similarity(bot_norm(ki.question), ctx->>'msg') AS sim
    INTO k
    FROM knowledge_items ki
   WHERE ki.tenant_id = (ctx->>'tenant_id')::uuid AND ki.is_active
   ORDER BY hits DESC, sim DESC
   LIMIT 1;
  IF NOT FOUND OR NOT (k.hits >= 1 OR k.sim >= 0.45) THEN RETURN NULL; END IF;
  v_msgs := jsonb_build_array(bot_msg_text(k.answer_text));
  IF k.media_url IS NOT NULL AND k.media_type IS NOT NULL THEN
    v_msgs := v_msgs || jsonb_build_object('type', k.media_type, 'link', k.media_url);
  END IF;
  RETURN bot_reply('resolved', v_msgs) || jsonb_build_object('kid', k.id,
           'score', CASE WHEN k.hits >= 1 THEN k.hits ELSE k.sim END);
END $$;

CREATE OR REPLACE FUNCTION bot_greeting(ctx JSONB) RETURNS JSONB LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN (ctx->>'msg') ~ '^(hola|holi|buenas|buen dia|buenos dias|buenas tardes|buenas noches|hey|hi|hello)( |$)'
                   AND length(ctx->>'msg') <= 40
         THEN bot_reply('greeting', jsonb_build_array(bot_msg_text(ctx #>> '{settings,welcome_text}'))) END
$$;

-- ---------- RF-02: captura de lead ----------
CREATE OR REPLACE FUNCTION bot_rf02_start_agent(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
  IF NOT (ctx->>'msg') ~ '(^| )(asesor|agente|humano|persona|vendedor|vendedora|representante|contactenme|llamenme|hablar con alguien)( |$)' THEN
    RETURN NULL;
  END IF;
  PERFORM bot_conv_set((ctx->>'tenant_id')::uuid, ctx->>'from', 'lead_name', '{}');
  INSERT INTO human_handovers (tenant_id, phone, message, reason) VALUES ((ctx->>'tenant_id')::uuid, ctx->>'from', ctx->>'raw', 'asked_for_agent');
  RETURN bot_reply('escalated_rf02', jsonb_build_array(bot_msg_text(ctx #>> '{settings,ask_name_text}')));
END $$;

CREATE OR REPLACE FUNCTION bot_rf02_fallback(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
  PERFORM bot_conv_set((ctx->>'tenant_id')::uuid, ctx->>'from', 'offer_lead', '{}');
  INSERT INTO human_handovers (tenant_id, phone, message, reason) VALUES ((ctx->>'tenant_id')::uuid, ctx->>'from', ctx->>'raw', 'unrecognized');
  RETURN bot_reply('escalated_rf02',
    jsonb_build_array(bot_msg_buttons(ctx #>> '{settings,fallback_text}',
      '[{"id":"lead:yes","title":"Sí, que me contacten"},{"id":"lead:no","title":"No, gracias"}]'::jsonb)),
    jsonb_build_array(jsonb_build_object('type', 'handover',
      'text', '🟡 Consulta sin respuesta (' || (ctx->>'tenant_name') || ')' || chr(10) || 'De: +' || (ctx->>'from') || chr(10) ||
              'Mensaje: ' || left(ctx->>'raw', 300))));
END $$;

CREATE OR REPLACE FUNCTION bot_rf02_step(ctx JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_t UUID := (ctx->>'tenant_id')::uuid; v_from TEXT := ctx->>'from'; v_raw TEXT := trim(ctx->>'raw');
  v_state TEXT := ctx->>'state'; v_data JSONB := coalesce(ctx->'data', '{}'); v_lead UUID;
BEGIN
  IF v_state = 'offer_lead' THEN
    IF ctx->>'reply_id' = 'lead:yes' OR bot_is_yes(v_raw) THEN
      PERFORM bot_conv_set(v_t, v_from, 'lead_name', '{}');
      RETURN bot_reply('lead_flow', jsonb_build_array(bot_msg_text(ctx #>> '{settings,ask_name_text}')));
    ELSIF ctx->>'reply_id' = 'lead:no' OR bot_is_no(v_raw) THEN
      PERFORM bot_conv_clear(v_t, v_from);
      RETURN bot_reply('lead_flow', jsonb_build_array(bot_msg_text(ctx #>> '{settings,no_lead_text}')));
    END IF;
    RETURN NULL;  -- escribió otra cosa: el despachador lo trata como consulta nueva
  ELSIF v_state = 'lead_name' THEN
    PERFORM bot_conv_set(v_t, v_from, 'lead_product', jsonb_build_object('name', left(v_raw, 150)));
    RETURN bot_reply('lead_flow', jsonb_build_array(bot_msg_text('Gracias, ' || left(v_raw, 60) || '. ¿Qué producto o servicio te interesa?')));
  ELSIF v_state = 'lead_product' THEN
    PERFORM bot_conv_set(v_t, v_from, 'lead_confirm', v_data || jsonb_build_object('product', left(v_raw, 500)));
    RETURN bot_reply('lead_flow', jsonb_build_array(bot_msg_buttons(
      'Confirmo tus datos:' || chr(10) || '• Nombre: ' || (v_data->>'name') || chr(10) || '• Interés: ' || left(v_raw, 200) || chr(10) || '¿Está bien?',
      '[{"id":"lead:confirm","title":"Sí, confirmar"},{"id":"lead:redo","title":"Corregir"}]'::jsonb)));
  ELSIF v_state = 'lead_confirm' THEN
    IF ctx->>'reply_id' = 'lead:confirm' OR (ctx->>'reply_id' IS NULL AND bot_is_yes(v_raw)) THEN
      INSERT INTO leads (tenant_id, phone, name, product_interest, source)
      VALUES (v_t, v_from, v_data->>'name', v_data->>'product', ctx->>'channel') RETURNING id INTO v_lead;
      PERFORM bot_conv_clear(v_t, v_from);
      RETURN bot_reply('lead_created',
        jsonb_build_array(bot_msg_text(replace(replace(ctx #>> '{settings,lead_done_text}', '{name}', v_data->>'name'), '{product}', v_data->>'product'))),
        jsonb_build_array(jsonb_build_object('type', 'new_lead', 'lead_id', v_lead,
          'text', '🟢 Nuevo lead (' || (ctx->>'tenant_name') || ')' || chr(10) || 'Nombre: ' || (v_data->>'name') || chr(10) ||
                  'Interés: ' || (v_data->>'product') || chr(10) || 'WhatsApp: +' || v_from || chr(10) || 'Etiqueta: Lead Calificado - Chatbot')));
    END IF;
    PERFORM bot_conv_set(v_t, v_from, 'lead_name', '{}');
    RETURN bot_reply('lead_flow', jsonb_build_array(bot_msg_text('Sin problema, empecemos de nuevo. ¿Cómo te llamás?')));
  END IF;
  RETURN NULL;
END $$;

-- Stubs: se reemplazan en 20_rf03_reservas.sql y 30_rf04_suscripciones.sql
DO $$ BEGIN
  IF to_regprocedure('bot_rf03_start(jsonb)') IS NULL THEN
    CREATE FUNCTION bot_rf03_start(ctx JSONB) RETURNS JSONB LANGUAGE sql AS 'SELECT NULL::jsonb';
    CREATE FUNCTION bot_rf03_step(ctx JSONB) RETURNS JSONB LANGUAGE sql AS 'SELECT NULL::jsonb';
  END IF;
  IF to_regprocedure('bot_rf04_start(jsonb)') IS NULL THEN
    CREATE FUNCTION bot_rf04_start(ctx JSONB) RETURNS JSONB LANGUAGE sql AS 'SELECT NULL::jsonb';
    CREATE FUNCTION bot_rf04_step(ctx JSONB) RETURNS JSONB LANGUAGE sql AS 'SELECT NULL::jsonb';
  END IF;
END $$;

-- ---------- despachador ----------
-- p jsonb: {phone_number_id, from, text, reply_id, message_id, contact_name, channel}
CREATE OR REPLACE FUNCTION bot_handle_message(p JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_pnid TEXT := p->>'phone_number_id';
  v_from TEXT := p->>'from';
  v_raw  TEXT := left(coalesce(p->>'text', ''), 2000);
  v_mid  TEXT := nullif(p->>'message_id', '');
  v_chan TEXT := coalesce(p->>'channel', 'whatsapp');
  t RECORD; c RECORD;
  v_limit INTEGER; v_used INTEGER;
  ctx JSONB; res JSONB; v_settings JSONB;
BEGIN
  IF v_mid IS NOT NULL AND EXISTS (SELECT 1 FROM interaction_logs WHERE wa_message_id = v_mid) THEN
    RETURN jsonb_build_object('action', 'ignore', 'reason', 'duplicate');
  END IF;

  SELECT tn.id, tn.name, tn.plan_tier, tn.settings, w.access_token, w.phone_number_id, w.graph_version INTO t
    FROM whatsapp_integrations w JOIN tenants tn ON tn.id = w.tenant_id
   WHERE w.phone_number_id = v_pnid AND w.is_active AND tn.is_active;
  IF NOT FOUND THEN RETURN jsonb_build_object('action', 'ignore', 'reason', 'unknown_or_inactive_number'); END IF;

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

  v_settings := jsonb_build_object(
      'timezone', 'America/Argentina/Buenos_Aires',
      'welcome_text', '¡Hola! Soy el asistente virtual de ' || t.name || '. Contame tu consulta y te respondo al instante.',
      'fallback_text', 'No encontré una respuesta para eso. ¿Querés que un asesor te contacte?',
      'ask_name_text', '¡Genial! Para que un asesor te contacte, ¿cómo te llamás?',
      'lead_done_text', '¡Listo, {name}! Registré tu interés en "{product}". Un asesor te va a escribir a la brevedad.',
      'no_lead_text', 'Perfecto. Si tenés otra consulta, escribime cuando quieras.',
      'features', '{}'::jsonb
    ) || coalesce(t.settings, '{}'::jsonb);

  DELETE FROM conversations WHERE tenant_id = t.id AND phone = v_from AND updated_at < NOW() - INTERVAL '30 minutes';
  SELECT * INTO c FROM conversations WHERE tenant_id = t.id AND phone = v_from;

  ctx := jsonb_build_object('tenant_id', t.id, 'tenant_name', t.name, 'settings', v_settings, 'from', v_from,
           'raw', v_raw, 'msg', bot_norm(v_raw), 'reply_id', nullif(p->>'reply_id', ''),
           'contact_name', nullif(p->>'contact_name', ''), 'channel', v_chan,
           'state', c.state, 'data', coalesce(c.data, '{}'::jsonb));

  IF c.state IS NOT NULL AND (ctx->>'msg') ~ '^(cancelar|salir|menu|reiniciar|basta)$' THEN
    PERFORM bot_conv_clear(t.id, v_from);
    res := bot_reply('cancelled', jsonb_build_array(bot_msg_text(v_settings->>'no_lead_text')));
  ELSIF c.state IS NOT NULL THEN
    res := CASE
             WHEN c.state = 'offer_lead' OR c.state LIKE 'lead\_%' THEN bot_rf02_step(ctx)
             WHEN c.state LIKE 'booking\_%' THEN bot_rf03_step(ctx)
             WHEN c.state LIKE 'sub\_%' THEN bot_rf04_step(ctx)
           END;
    IF res IS NULL THEN
      PERFORM bot_conv_clear(t.id, v_from);
      ctx := ctx || jsonb_build_object('state', NULL, 'data', '{}'::jsonb);
    END IF;
  END IF;

  -- Intenciones, en orden. Cada flujo devuelve NULL si no le corresponde.
  res := coalesce(res, bot_rf02_start_agent(ctx));
  IF res IS NULL AND bot_feature(ctx, 'rf03') THEN res := bot_rf03_start(ctx); END IF;
  IF res IS NULL AND bot_feature(ctx, 'rf04') THEN res := bot_rf04_start(ctx); END IF;
  res := coalesce(res, bot_rf01_faq(ctx), bot_greeting(ctx), bot_rf02_fallback(ctx));

  INSERT INTO interaction_logs (tenant_id, channel, wa_message_id, sender_phone, incoming_message,
                                matched_knowledge_id, match_score, reply_text, status)
  VALUES (t.id, v_chan, v_mid, v_from, v_raw, (res->>'kid')::uuid, (res->>'score')::real,
          (SELECT string_agg(coalesce(m->>'text', m #>> '{interactive,body,text}', m->>'type'), ' | ')
             FROM jsonb_array_elements(res->'messages') m),
          res->>'status');

  RETURN jsonb_build_object(
    'action', 'reply', 'tenant_id', t.id, 'tenant_name', t.name, 'status', res->>'status', 'to', v_from,
    'phone_number_id', t.phone_number_id, 'access_token', t.access_token, 'graph_version', t.graph_version,
    'messages', res->'messages',
    'notify', (SELECT coalesce(jsonb_agg(n || jsonb_build_object(
                  'channel', coalesce(v_settings #>> '{notify,channel}', 'whatsapp'),
                  'to', v_settings #>> '{notify,to}', 'template', v_settings #>> '{notify,template}')), '[]'::jsonb)
               FROM jsonb_array_elements(coalesce(res->'notify', '[]'::jsonb)) n));
END $$;

-- ---------- RF01-SYNC ----------
CREATE OR REPLACE FUNCTION bot_sync_knowledge(p_source_id UUID, p_items JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  s RECORD; v_upserted INTEGER := 0; v_disabled INTEGER := 0; it JSONB; v_key TEXT; v_keys TEXT[] := '{}';
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
            trim(it->>'question'), trim(it->>'answer_text'), nullif(trim(it->>'media_url'), ''),
            CASE WHEN lower(trim(coalesce(it->>'media_type', ''))) IN ('image', 'imagen') THEN 'image'
                 WHEN lower(trim(coalesce(it->>'media_type', ''))) IN ('document', 'pdf', 'documento') THEN 'document' END,
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
  UPDATE data_sources SET last_synced_at = NOW(), last_status = 'ok: ' || v_upserted || ' ítems, ' || v_disabled || ' dados de baja'
   WHERE id = s.id;
  RETURN jsonb_build_object('ok', true, 'source_id', s.id, 'upserted', v_upserted, 'disabled', v_disabled);
END $$;

CREATE OR REPLACE FUNCTION bot_sync_failed(p_source_id UUID, p_error TEXT) RETURNS VOID LANGUAGE sql AS $$
  UPDATE data_sources SET last_status = 'error: ' || left(coalesce(p_error, '?'), 500) WHERE id = p_source_id
$$;
CREATE OR REPLACE FUNCTION bot_lead_notified(p_lead_id UUID) RETURNS VOID LANGUAGE sql AS $$
  UPDATE leads SET notified_at = NOW() WHERE id = p_lead_id
$$;

-- Vista legible de una respuesta del motor (para pruebas y depuración)
CREATE OR REPLACE FUNCTION bot_preview(r JSONB) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT (r->>'status') || ' » ' || coalesce(string_agg(
           coalesce(m->>'text', (m #>> '{interactive,body,text}') || ' [' ||
             coalesce((SELECT string_agg(x->>'title', ' / ') FROM jsonb_array_elements(m #> '{interactive,action,sections,0,rows}') x),
                      (SELECT string_agg(x #>> '{reply,title}', ' / ') FROM jsonb_array_elements(m #> '{interactive,action,buttons}') x), '') || ']',
             m->>'type' || ' ' || coalesce(m->>'link', '')), ' ‖ '), '')
         || coalesce(' » eventos: ' || (SELECT string_agg(n->>'type', ',') FROM jsonb_array_elements(r->'notify') n), '')
  FROM jsonb_array_elements(r->'messages') m
$$;
