# Genera los JSON de los workflows de n8n del chatbot. Uso: python3 chatbot/n8n/gen_workflows.py
import json, uuid, os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "workflows")
PG = {"postgres": {"id": "pgChatbotCred01", "name": "Postgres chatbot"}}
IDS = {"core01": "core01Whatsapp01", "core02": "core02Enviar0001", "core03": "core03Router0001",
       "sync": "rf01Sync00000001", "notify": "rf02Notify000001",
       "checkout": "rf04Checkout0001", "pagos": "rf04Pagos0000001"}
def u(seed): return str(uuid.uuid5(uuid.NAMESPACE_URL, "dmglobal-chatbot/" + seed))
def node(name, typ, ver, params, pos, **kw):
    n = {"parameters": params, "id": u(name), "name": name, "type": typ, "typeVersion": ver, "position": pos}
    n.update(kw); return n
def pg(name, query, repl, pos):
    p = {"operation": "executeQuery", "query": query, "options": {}}
    if repl: p["options"]["queryReplacement"] = repl
    return node(name, "n8n-nodes-base.postgres", 2.5, p, pos, credentials=PG)
def code(name, js, pos, mode=None):
    p = {"jsCode": js}
    if mode: p["mode"] = mode
    return node(name, "n8n-nodes-base.code", 2, p, pos)
def trig(pos): return node("Llamado desde otro workflow", "n8n-nodes-base.executeWorkflowTrigger", 1, {}, pos)
def call(name, wid, pos):
    return node(name, "n8n-nodes-base.executeWorkflow", 1.1, {"source": "database", "workflowId": {"__rl": True, "value": wid, "mode": "id"}, "options": {}}, pos)
def iff(name, left, op, pos, right=None):
    c = {"id": u(name + "c"), "leftValue": left, "operator": op}
    if right is not None: c["rightValue"] = right
    return node(name, "n8n-nodes-base.if", 2, {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
            "conditions": [c], "combinator": "and"}, "options": {}}, pos)
def conn(*pairs):
    c = {}
    for a, b, *rest in pairs:
        out = rest[0] if rest else 0
        c.setdefault(a, {"main": []})
        while len(c[a]["main"]) <= out: c[a]["main"].append([])
        c[a]["main"][out].append({"node": b, "type": "main", "index": 0})
    return c
def wf(key, name, nodes, connections, tags):
    d = {"id": IDS[key], "name": name, "nodes": nodes, "connections": connections, "active": False,
         "settings": {"executionOrder": "v1", "timezone": "America/Argentina/Buenos_Aires", "saveDataSuccessExecution": "all"},
         "pinData": {}, "meta": {"templateCredsSetupCompleted": True}, "tags": []}
    json.dump(d, open(os.path.join(OUT, IDS[key] + ".json"), "w"), ensure_ascii=False, indent=1)

BOOL_TRUE = {"type": "boolean", "operation": "true", "singleValue": True}
STR_EQ = {"type": "string", "operation": "equals"}
NOT_EMPTY = {"type": "string", "operation": "notEmpty", "singleValue": True}

# ---------- CORE-01 ----------
EXTRACT = r"""// Convierte el payload de Meta en un ítem por mensaje entrante (ignora estados de entrega)
const out = [];
for (const item of $input.all()) {
  const body = item.json.body || {};
  for (const entry of body.entry || []) for (const ch of entry.changes || []) {
    const v = ch.value || {};
    const pnid = v.metadata && v.metadata.phone_number_id;
    const names = {};
    for (const c of v.contacts || []) names[c.wa_id] = c.profile && c.profile.name;
    for (const m of v.messages || []) {
      let text = '', reply_id = null;
      if (m.type === 'text') text = (m.text && m.text.body) || '';
      else if (m.type === 'interactive') { const r = m.interactive.button_reply || m.interactive.list_reply || {}; text = r.title || ''; reply_id = r.id || null; }
      else if (m.type === 'button') { text = (m.button && m.button.text) || ''; reply_id = (m.button && m.button.payload) || null; }
      else text = '[' + m.type + ']';
      out.push({ json: { phone_number_id: pnid, from: m.from, text, reply_id, message_id: m.id,
                         contact_name: names[m.from] || null, channel: 'whatsapp' } });
    }
  }
}
return out;"""
MSGS = r"""// Un ítem por mensaje a enviar, con las credenciales del tenant que devolvió el motor
const out = [];
for (const item of $input.all()) {
  const r = item.json.r;
  for (const m of r.messages || []) {
    out.push({ json: { tenant_id: r.tenant_id, phone_number_id: r.phone_number_id, access_token: r.access_token,
                       graph_version: r.graph_version, to: r.to, message: m } });
  }
}
return out;"""
EVENTS = r"""// Un ítem por evento (lead nuevo, derivación...) para el router
const out = [];
for (const item of $input.all()) {
  const r = item.json.r;
  for (const e of r.notify || []) {
    out.push({ json: { ...e, tenant_id: r.tenant_id, tenant_name: r.tenant_name, phone_number_id: r.phone_number_id,
                       access_token: r.access_token, graph_version: r.graph_version, contact: r.to } });
  }
}
return out;"""
n = [
 node("GET verificación Meta", "n8n-nodes-base.webhook", 2, {"httpMethod": "GET", "path": "whatsapp", "responseMode": "responseNode", "options": {}}, [0, 0], webhookId=u("wh-get")),
 pg("Validar token", "SELECT bot_verify_token($1) AS ok, $2::text AS challenge;",
    "={{ [ $json.query['hub.verify_token'] || '', $json.query['hub.challenge'] || '' ] }}", [220, 0]),
 iff("¿Token válido?", "={{ $json.ok }}", BOOL_TRUE, [440, 0]),
 node("Responder challenge", "n8n-nodes-base.respondToWebhook", 1.1, {"respondWith": "text", "responseBody": "={{ $json.challenge }}", "options": {}}, [660, -80]),
 node("Rechazar", "n8n-nodes-base.respondToWebhook", 1.1, {"respondWith": "text", "responseBody": "forbidden", "options": {"responseCode": 403}}, [660, 80]),
 node("POST mensajes Meta", "n8n-nodes-base.webhook", 2, {"httpMethod": "POST", "path": "whatsapp", "options": {}}, [0, 300], webhookId=u("wh-post")),
 code("Extraer mensajes", EXTRACT, [220, 300]),
 pg("Motor bot_handle_message", "SELECT bot_handle_message($1::jsonb) AS r;", "={{ [ JSON.stringify($json) ] }}", [440, 300]),
 iff("¿Hay respuesta?", "={{ $json.r.action }}", STR_EQ, [660, 300], right="reply"),
 code("Mensajes a enviar", MSGS, [880, 220]),
 call("CORE-02 Enviar WhatsApp", IDS["core02"], [1100, 220]),
 code("Eventos", EVENTS, [880, 400]),
 call("CORE-03 Router de eventos", IDS["core03"], [1100, 400]),
]
wf("core01", "CORE-01 Webhook WhatsApp", n, conn(
  ("GET verificación Meta", "Validar token"), ("Validar token", "¿Token válido?"),
  ("¿Token válido?", "Responder challenge", 0), ("¿Token válido?", "Rechazar", 1),
  ("POST mensajes Meta", "Extraer mensajes"), ("Extraer mensajes", "Motor bot_handle_message"),
  ("Motor bot_handle_message", "¿Hay respuesta?"), ("¿Hay respuesta?", "Mensajes a enviar", 0), ("¿Hay respuesta?", "Eventos", 0),
  ("Mensajes a enviar", "CORE-02 Enviar WhatsApp"), ("Eventos", "CORE-03 Router de eventos")), [])

# ---------- CORE-02 ----------
BUILD = r"""// Traduce el mensaje interno al formato de la WhatsApp Cloud API
const m = $json.message || {};
const body = { messaging_product: 'whatsapp', recipient_type: 'individual', to: $json.to };
if (m.type === 'text') { body.type = 'text'; body.text = { body: m.text, preview_url: true }; }
else if (m.type === 'image') { body.type = 'image'; body.image = { link: m.link, caption: m.caption }; }
else if (m.type === 'document') { body.type = 'document'; body.document = { link: m.link, filename: m.filename || m.link.split('/').pop() }; }
else if (m.type === 'template') { body.type = 'template'; body.template = m.template; }
else if (m.type === 'interactive') { body.type = 'interactive'; body.interactive = m.interactive; }
return { json: { ...$json, body } };"""
RESULT = r"""// Resume el resultado del envío (el token no se guarda en la ejecución)
const req = $('Armar mensaje Meta').item.json;
const ok = $json.statusCode >= 200 && $json.statusCode < 300;
return { json: { ok, statusCode: $json.statusCode, to: req.to, type: req.message.type,
                 wa_id: ok ? ($json.body.messages || [{}])[0].id : null,
                 error: ok ? null : ($json.body && $json.body.error) || $json.body } };"""
n = [
 trig([0, 0]),
 code("Armar mensaje Meta", BUILD, [220, 0], mode="runOnceForEachItem"),
 node("Enviar a Graph API", "n8n-nodes-base.httpRequest", 4.2, {
   "method": "POST", "url": "=https://graph.facebook.com/{{ $json.graph_version }}/{{ $json.phone_number_id }}/messages",
   "sendHeaders": True, "headerParameters": {"parameters": [{"name": "Authorization", "value": "=Bearer {{ $json.access_token }}"}]},
   "sendBody": True, "specifyBody": "json", "jsonBody": "={{ JSON.stringify($json.body) }}",
   "options": {"response": {"response": {"fullResponse": True, "neverError": True}}, "timeout": 15000}}, [440, 0]),
 code("Resultado del envío", RESULT, [660, 0], mode="runOnceForEachItem"),
]
wf("core02", "CORE-02 Enviar WhatsApp", n, conn(("Llamado desde otro workflow", "Armar mensaje Meta"),
   ("Armar mensaje Meta", "Enviar a Graph API"), ("Enviar a Graph API", "Resultado del envío")), [])

# ---------- CORE-03 ----------
def rule(key): return {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
    "conditions": [{"id": u("r" + key), "leftValue": "={{ $json.type }}", "rightValue": key, "operator": STR_EQ}], "combinator": "and"},
    "renameOutput": True, "outputKey": key}
n = [
 trig([0, 0]),
 node("Según tipo de evento", "n8n-nodes-base.switch", 3.2, {"rules": {"values": [rule("new_lead"), rule("handover"), rule("booking_created"), rule("checkout_requested")]},
      "options": {"fallbackOutput": "extra", "renameFallbackOutput": "otro"}}, [220, 0]),
 call("RF02-NOTIFY (lead)", IDS["notify"], [480, -160]),
 call("RF02-NOTIFY (derivación)", IDS["notify"], [480, -40]),
 call("RF02-NOTIFY (reserva)", IDS["notify"], [480, 80]),
 call("RF04-CHECKOUT Link de pago", IDS["checkout"], [480, 200]),
 node("Evento sin flujo asignado", "n8n-nodes-base.noOp", 1, {}, [480, 320]),
]
wf("core03", "CORE-03 Router de eventos", n, conn(("Llamado desde otro workflow", "Según tipo de evento"),
   ("Según tipo de evento", "RF02-NOTIFY (lead)", 0), ("Según tipo de evento", "RF02-NOTIFY (derivación)", 1),
   ("Según tipo de evento", "RF02-NOTIFY (reserva)", 2), ("Según tipo de evento", "RF04-CHECKOUT Link de pago", 3),
   ("Según tipo de evento", "Evento sin flujo asignado", 4)), [])

# ---------- RF02-NOTIFY ----------
NOTIF = r"""// Mensaje al número de ventas del tenant. Si hay plantilla aprobada se usa (necesaria fuera de la ventana de 24 h)
const e = $json;
let message;
if (e.template) {
  message = { type: 'template', template: { name: e.template, language: { code: e.template_lang || 'es_AR' },
    components: [{ type: 'body', parameters: [{ type: 'text', text: String(e.text).replace(/\s*\n\s*/g, ' · ').slice(0, 1000) }] }] } };
} else {
  message = { type: 'text', text: e.text };
}
return { json: { tenant_id: e.tenant_id, lead_id: e.lead_id || null, phone_number_id: e.phone_number_id,
                 access_token: e.access_token, graph_version: e.graph_version, to: String(e.to).replace(/\D/g, ''), message } };"""
n = [
 trig([0, 0]),
 iff("¿Canal WhatsApp con número?", "={{ $json.channel === 'whatsapp' && !!$json.to }}", BOOL_TRUE, [220, 0]),
 code("Armar aviso", NOTIF, [440, -80], mode="runOnceForEachItem"),
 call("CORE-02 Enviar WhatsApp", IDS["core02"], [660, -80]),
 pg("Marcar lead avisado", "SELECT bot_lead_notified($1::uuid) AS r WHERE $1 <> '';",
    "={{ [ $('Armar aviso').item.json.lead_id || '' ] }}", [880, -80]),
 node("Sin canal configurado", "n8n-nodes-base.noOp", 1, {}, [440, 100]),
]
wf("notify", "RF02-NOTIFY Aviso a ventas", n, conn(("Llamado desde otro workflow", "¿Canal WhatsApp con número?"),
   ("¿Canal WhatsApp con número?", "Armar aviso", 0), ("¿Canal WhatsApp con número?", "Sin canal configurado", 1),
   ("Armar aviso", "CORE-02 Enviar WhatsApp"), ("CORE-02 Enviar WhatsApp", "Marcar lead avisado")), [])

# ---------- RF01-SYNC ----------
PARSE = r"""// Parsea el CSV de la planilla (columnas: id, categoria, pregunta, palabras_clave, respuesta, media_url, media_tipo, activo)
const src = $('Fuentes a sincronizar').item.json;
if ($json.statusCode !== 200 || /^\s*</.test($json.body || '')) {
  return { json: { source_id: src.id, error: 'HTTP ' + $json.statusCode + ': la planilla no es pública o el nombre de la hoja no existe' } };
}
function parseCSV(t) {
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (q) { if (c === '"') { if (t[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && t[i + 1] === '\n') i++; row.push(f); rows.push(row); row = []; f = ''; }
    else f += c;
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  return rows;
}
const norm = s => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');
const rows = parseCSV($json.body || '');
const head = (rows.shift() || []).map(norm);
const col = (r, ...names) => { for (const n of names) { const i = head.indexOf(n); if (i >= 0) return (r[i] || '').trim(); } return ''; };
const items = rows.filter(r => r.some(x => String(x).trim() !== '')).map(r => ({
  external_key: col(r, 'id', 'clave'),
  category: col(r, 'categoria', 'category'),
  question: col(r, 'pregunta', 'question'),
  keywords: col(r, 'palabras_clave', 'keywords').split(/[,;]/).map(s => s.trim()).filter(Boolean),
  answer_text: col(r, 'respuesta', 'answer', 'answer_text'),
  media_url: col(r, 'media_url', 'archivo', 'url_archivo'),
  media_type: col(r, 'media_tipo', 'media_type', 'tipo_archivo'),
  is_active: !/^(no|false|0|inactivo)$/i.test(col(r, 'activo', 'active') || 'si'),
}));
return { json: { source_id: src.id, items, error: null } };"""
n = [
 node("Cada 30 minutos", "n8n-nodes-base.scheduleTrigger", 1.2, {"rule": {"interval": [{"field": "minutes", "minutesInterval": 30}]}}, [0, 0]),
 node("Sincronizar ahora", "n8n-nodes-base.manualTrigger", 1, {}, [0, 180]),
 pg("Fuentes a sincronizar",
    "SELECT id, tenant_id, config->>'spreadsheet_id' AS spreadsheet_id, coalesce(config->>'sheet', '') AS sheet\nFROM data_sources\nWHERE is_active AND source_type = 'google_sheets' AND coalesce(config->>'spreadsheet_id', '') <> ''\n  AND (last_synced_at IS NULL OR last_synced_at < NOW() - make_interval(mins => greatest(sync_interval_min - 1, 1)));",
    None, [220, 80]),
 node("Descargar planilla (CSV)", "n8n-nodes-base.httpRequest", 4.2, {
   "url": "=https://docs.google.com/spreadsheets/d/{{ $json.spreadsheet_id }}/gviz/tq?tqx=out:csv{{ $json.sheet ? '&sheet=' + encodeURIComponent($json.sheet) : '' }}",
   "options": {"response": {"response": {"fullResponse": True, "neverError": True, "responseFormat": "text"}}, "timeout": 20000}}, [440, 80]),
 code("Formatear FAQs", PARSE, [660, 80], mode="runOnceForEachItem"),
 iff("¿Error?", "={{ !!$json.error }}", BOOL_TRUE, [880, 80]),
 pg("Registrar error", "SELECT bot_sync_failed($1::uuid, $2) AS r;", "={{ [ $json.source_id, $json.error ] }}", [1100, 0]),
 pg("Actualizar caché", "SELECT bot_sync_knowledge($1::uuid, $2::jsonb) AS r;", "={{ [ $json.source_id, JSON.stringify($json.items) ] }}", [1100, 160]),
]
wf("sync", "RF01-SYNC Sincronizar FAQs", n, conn(("Cada 30 minutos", "Fuentes a sincronizar"), ("Sincronizar ahora", "Fuentes a sincronizar"),
   ("Fuentes a sincronizar", "Descargar planilla (CSV)"), ("Descargar planilla (CSV)", "Formatear FAQs"), ("Formatear FAQs", "¿Error?"),
   ("¿Error?", "Registrar error", 0), ("¿Error?", "Actualizar caché", 1)), [])
# ---------- RF04-CHECKOUT ----------
MP_BODY = r"""={{ JSON.stringify({
  reason: $json.c.plan.name + ' · ' + $json.c.tenant_name,
  external_reference: $json.c.subscription_id,
  payer_email: $json.c.customer.email,
  back_url: $json.c.provider_config.back_url || 'https://dmglobal.tech',
  status: 'pending',
  auto_recurring: {
    frequency: $json.c.plan.interval === 'year' ? 12 : 1, frequency_type: 'months',
    transaction_amount: Number($json.c.plan.price), currency_id: $json.c.plan.currency
  }
}) }}"""
MOCK = r"""// Pasarela simulada: el link activa la suscripción al abrirlo (solo para tenants con provider = mock)
const c = $json.c;
return { json: { url: 'https://n8n.dmglobal.tech/webhook/pagos-mock?tenant=' + c.tenant_id + '&ref=' + c.subscription_id, ref: 'mock-' + c.subscription_id } };"""
NONE = r"""return { json: { error: 'El cliente no tiene pasarela de pago configurada (payment_integrations)' } };"""
UNIFY = r"""// Normaliza la respuesta de la pasarela: {url, ref} o {error}
const c = $('Datos del checkout').item.json.c;
const j = $json; let url = null, ref = null, error = j.error || null;
if (!error && j.statusCode !== undefined) {
  const b = j.body || {};
  if (j.statusCode >= 200 && j.statusCode < 300) { url = b.init_point || b.url; ref = b.id; }
  else error = 'HTTP ' + j.statusCode + ': ' + JSON.stringify(b.message || b.error || b).slice(0, 300);
} else if (!error) { url = j.url; ref = j.ref; }
if (!url && !error) error = 'La pasarela no devolvió un link de pago';
return { json: { subscription_id: c.subscription_id, url, ref, error, provider: c.provider,
  phone_number_id: c.phone_number_id, access_token: c.access_token, graph_version: c.graph_version, to: c.to,
  plan: c.plan.name, name: c.customer.name } };"""
LINKMSG = r"""const j = $('Resultado pasarela').item.json;
return { json: { phone_number_id: j.phone_number_id, access_token: j.access_token, graph_version: j.graph_version, to: j.to,
  message: { type: 'interactive', interactive: { type: 'cta_url',
    body: { text: 'Listo, ' + j.name + '. Este es tu link para pagar el plan ' + j.plan + '. Cuando se acredite el pago te aviso por acá.' },
    action: { name: 'cta_url', parameters: { display_text: 'Pagar ahora', url: j.url } } } } } };"""
ERRMSG = r"""const j = $json;
return { json: { phone_number_id: j.phone_number_id, access_token: j.access_token, graph_version: j.graph_version, to: j.to,
  message: { type: 'text', text: 'Perdón, no pude generar el link de pago en este momento. Un asesor te va a escribir para completar el alta.' },
  error: j.error } };"""
def rule2(key, left="={{ $json.c.provider }}"):
    return {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
      "conditions": [{"id": u("p" + key), "leftValue": left, "rightValue": key, "operator": STR_EQ}], "combinator": "and"},
      "renameOutput": True, "outputKey": key}
n = [
 trig([0, 0]),
 pg("Datos del checkout", "SELECT bot_rf04_checkout_context($1::uuid) AS c;", "={{ [ $json.subscription_id ] }}", [220, 0]),
 node("Según pasarela", "n8n-nodes-base.switch", 3.2, {"rules": {"values": [rule2("mercadopago"), rule2("stripe"), rule2("mock")]},
      "options": {"fallbackOutput": "extra", "renameFallbackOutput": "sin_pasarela"}}, [440, 0]),
 node("Mercado Pago: crear preapproval", "n8n-nodes-base.httpRequest", 4.2, {
   "method": "POST", "url": "https://api.mercadopago.com/preapproval",
   "sendHeaders": True, "headerParameters": {"parameters": [{"name": "Authorization", "value": "=Bearer {{ $json.c.provider_token }}"}]},
   "sendBody": True, "specifyBody": "json", "jsonBody": MP_BODY,
   "options": {"response": {"response": {"fullResponse": True, "neverError": True}}, "timeout": 20000}}, [700, -180]),
 node("Stripe: crear checkout session", "n8n-nodes-base.httpRequest", 4.2, {
   "method": "POST", "url": "https://api.stripe.com/v1/checkout/sessions",
   "sendHeaders": True, "headerParameters": {"parameters": [{"name": "Authorization", "value": "=Bearer {{ $json.c.provider_token }}"}]},
   "sendBody": True, "contentType": "form-urlencoded", "bodyParameters": {"parameters": [
     {"name": "mode", "value": "subscription"},
     {"name": "line_items[0][price]", "value": "={{ $json.c.plan.provider_price_id }}"},
     {"name": "line_items[0][quantity]", "value": "1"},
     {"name": "client_reference_id", "value": "={{ $json.c.subscription_id }}"},
     {"name": "customer_email", "value": "={{ $json.c.customer.email }}"},
     {"name": "metadata[tenant_id]", "value": "={{ $json.c.tenant_id }}"},
     {"name": "subscription_data[metadata][subscription_id]", "value": "={{ $json.c.subscription_id }}"},
     {"name": "success_url", "value": "={{ $json.c.provider_config.success_url || 'https://dmglobal.tech' }}"},
     {"name": "cancel_url", "value": "={{ $json.c.provider_config.back_url || 'https://dmglobal.tech' }}"}]},
   "options": {"response": {"response": {"fullResponse": True, "neverError": True}}, "timeout": 20000}}, [700, -40]),
 code("Simulada: armar link", MOCK, [700, 100], mode="runOnceForEachItem"),
 code("Sin pasarela", NONE, [700, 240], mode="runOnceForEachItem"),
 code("Resultado pasarela", UNIFY, [960, 0], mode="runOnceForEachItem"),
 iff("¿Hay link?", "={{ !!$json.url }}", BOOL_TRUE, [1180, 0]),
 pg("Guardar link", "SELECT bot_rf04_checkout_created($1::uuid, $2, $3) AS r;", "={{ [ $json.subscription_id, $json.url, $json.ref || '' ] }}", [1400, -80]),
 code("Mensaje con link", LINKMSG, [1620, -80], mode="runOnceForEachItem"),
 code("Mensaje de error", ERRMSG, [1400, 100], mode="runOnceForEachItem"),
 call("CORE-02 Enviar WhatsApp", IDS["core02"], [1840, 0]),
]
wf("checkout", "RF04-CHECKOUT Link de pago", n, conn(("Llamado desde otro workflow", "Datos del checkout"), ("Datos del checkout", "Según pasarela"),
   ("Según pasarela", "Mercado Pago: crear preapproval", 0), ("Según pasarela", "Stripe: crear checkout session", 1),
   ("Según pasarela", "Simulada: armar link", 2), ("Según pasarela", "Sin pasarela", 3),
   ("Mercado Pago: crear preapproval", "Resultado pasarela"), ("Stripe: crear checkout session", "Resultado pasarela"),
   ("Simulada: armar link", "Resultado pasarela"), ("Sin pasarela", "Resultado pasarela"),
   ("Resultado pasarela", "¿Hay link?"), ("¿Hay link?", "Guardar link", 0), ("¿Hay link?", "Mensaje de error", 1),
   ("Guardar link", "Mensaje con link"), ("Mensaje con link", "CORE-02 Enviar WhatsApp"), ("Mensaje de error", "CORE-02 Enviar WhatsApp")), [])

# ---------- RF04-PAGOS ----------
MP_IN = r"""// Notificación de Mercado Pago: solo interesan las de suscripción (preapproval)
const q = $json.query || {}, b = $json.body || {};
const type = b.type || b.topic || q.type || q.topic || '';
const id = (b.data && b.data.id) || q['data.id'] || q.id || '';
return { json: { tenant_id: q.tenant || '', type, id: String(id), relevant: /preapproval/.test(type) && !!id && !!q.tenant } };"""
MP_OK = r"""// Solo una suscripción autorizada activa el alta
const b = $json.body || {}, src = $('MP: leer aviso').item.json;
const ok = $json.statusCode === 200 && b.status === 'authorized' && !!b.external_reference;
return { json: { ok, tenant_id: src.tenant_id, provider: 'mercadopago', event_id: 'mp-' + b.id + '-' + b.status,
  subscription_id: b.external_reference || '', ref: b.id || '', period_end: b.next_payment_date || '', payload: b } };"""
ST_IN = r"""// Evento de Stripe: solo checkout.session.completed. No se confía en el cuerpo: se vuelve a leer la sesión con la API
const q = $json.query || {}, b = $json.body || {};
const obj = (b.data && b.data.object) || {};
return { json: { tenant_id: q.tenant || '', type: b.type || '', id: obj.id || '',
  relevant: b.type === 'checkout.session.completed' && !!obj.id && !!q.tenant } };"""
ST_OK = r"""const b = $json.body || {}, src = $('Stripe: leer evento').item.json;
const ok = $json.statusCode === 200 && b.status === 'complete' && ['paid', 'no_payment_required'].includes(b.payment_status) && !!b.client_reference_id;
return { json: { ok, tenant_id: src.tenant_id, provider: 'stripe', event_id: 'st-' + b.id,
  subscription_id: b.client_reference_id || '', ref: b.subscription || b.id || '', period_end: '', payload: { id: b.id, subscription: b.subscription } } };"""
WELCOME = r"""const r = $json.r;
const fin = r.current_period_end || null;
return { json: { phone_number_id: r.phone_number_id, access_token: r.access_token, graph_version: r.graph_version, to: r.to,
  message: { type: 'text', text: '🎉 ¡Pago recibido, ' + r.customer.name + '! Tu suscripción al plan ' + r.plan.name + ' de ' + r.tenant_name +
    ' ya está activa. Te mandamos la bienvenida a ' + r.customer.email + '.' } } };"""
ACT_Q = "SELECT bot_rf04_activate($1::uuid, $2, $3, $4::uuid, $5, NULLIF($6, '')::timestamptz, $7::jsonb) AS r;"
ACT_P = "={{ [ $json.tenant_id, $json.provider, $json.event_id, $json.subscription_id, $json.ref, $json.period_end, JSON.stringify($json.payload || {}) ] }}"
TOKEN_Q = "SELECT access_token, $2::text AS id, $1::text AS tenant_id FROM payment_integrations WHERE tenant_id = $1::uuid AND provider = $3 AND is_active;"
n = [
 node("Mock: link abierto", "n8n-nodes-base.webhook", 2, {"httpMethod": "GET", "path": "pagos-mock", "responseMode": "responseNode", "options": {}}, [0, -200], webhookId=u("wh-mock")),
 node("Activar (simulado)", "n8n-nodes-base.postgres", 2.5, {"operation": "executeQuery",
   "query": "SELECT bot_rf04_activate(pi.tenant_id, 'mock', 'mock-' || $2, $2::uuid, 'mock-' || $2, NULL, '{}') AS r\nFROM payment_integrations pi WHERE pi.tenant_id = $1::uuid AND pi.provider = 'mock' AND pi.is_active;",
   "options": {"queryReplacement": "={{ [ $json.query.tenant || '00000000-0000-0000-0000-000000000000', $json.query.ref || '00000000-0000-0000-0000-000000000000' ] }}"}},
   [220, -200], credentials=PG, alwaysOutputData=True),
 node("Responder (simulado)", "n8n-nodes-base.respondToWebhook", 1.1, {"respondWith": "text",
   "responseBody": "={{ $json.r && $json.r.ok ? 'Pago simulado: la suscripción quedó activa. Ya podés volver a WhatsApp.' : 'Link de pago simulado inválido.' }}", "options": {}}, [440, -200]),
 node("Mercado Pago: aviso", "n8n-nodes-base.webhook", 2, {"httpMethod": "POST", "path": "pagos-mercadopago", "options": {}}, [0, 20], webhookId=u("wh-mp")),
 code("MP: leer aviso", MP_IN, [220, 20], mode="runOnceForEachItem"),
 iff("¿Es de suscripción?", "={{ $json.relevant }}", BOOL_TRUE, [440, 20]),
 pg("MP: token del cliente", TOKEN_Q, "={{ [ $json.tenant_id, $json.id, 'mercadopago' ] }}", [660, 20]),
 node("MP: consultar preapproval", "n8n-nodes-base.httpRequest", 4.2, {
   "url": "=https://api.mercadopago.com/preapproval/{{ $json.id }}",
   "sendHeaders": True, "headerParameters": {"parameters": [{"name": "Authorization", "value": "=Bearer {{ $json.access_token }}"}]},
   "options": {"response": {"response": {"fullResponse": True, "neverError": True}}, "timeout": 20000}}, [880, 20]),
 code("MP: validar estado", MP_OK, [1100, 20], mode="runOnceForEachItem"),
 node("Stripe: evento", "n8n-nodes-base.webhook", 2, {"httpMethod": "POST", "path": "pagos-stripe", "options": {}}, [0, 240], webhookId=u("wh-stripe")),
 code("Stripe: leer evento", ST_IN, [220, 240], mode="runOnceForEachItem"),
 iff("¿Checkout completo?", "={{ $json.relevant }}", BOOL_TRUE, [440, 240]),
 pg("Stripe: clave del cliente", TOKEN_Q, "={{ [ $json.tenant_id, $json.id, 'stripe' ] }}", [660, 240]),
 node("Stripe: consultar sesión", "n8n-nodes-base.httpRequest", 4.2, {
   "url": "=https://api.stripe.com/v1/checkout/sessions/{{ $json.id }}",
   "sendHeaders": True, "headerParameters": {"parameters": [{"name": "Authorization", "value": "=Bearer {{ $json.access_token }}"}]},
   "options": {"response": {"response": {"fullResponse": True, "neverError": True}}, "timeout": 20000}}, [880, 240]),
 code("Stripe: validar pago", ST_OK, [1100, 240], mode="runOnceForEachItem"),
 iff("¿Pago válido?", "={{ $json.ok }}", BOOL_TRUE, [1320, 120]),
 pg("Activar suscripción", ACT_Q, ACT_P, [1540, 120]),
 iff("¿Primera activación?", "={{ !!($json.r && $json.r.first_activation) }}", BOOL_TRUE, [1760, 0]),
 code("Mensaje de bienvenida", WELCOME, [1980, 0], mode="runOnceForEachItem"),
 call("CORE-02 Enviar WhatsApp", IDS["core02"], [2200, 0]),
 node("Email de bienvenida (pendiente SMTP)", "n8n-nodes-base.noOp", 1, {}, [2200, 140]),
]
wf("pagos", "RF04-PAGOS Confirmación de pago", n, conn(
   ("Mock: link abierto", "Activar (simulado)"), ("Activar (simulado)", "Responder (simulado)"), ("Responder (simulado)", "¿Primera activación?"),
   ("Mercado Pago: aviso", "MP: leer aviso"), ("MP: leer aviso", "¿Es de suscripción?"), ("¿Es de suscripción?", "MP: token del cliente", 0),
   ("MP: token del cliente", "MP: consultar preapproval"), ("MP: consultar preapproval", "MP: validar estado"), ("MP: validar estado", "¿Pago válido?"),
   ("Stripe: evento", "Stripe: leer evento"), ("Stripe: leer evento", "¿Checkout completo?"), ("¿Checkout completo?", "Stripe: clave del cliente", 0),
   ("Stripe: clave del cliente", "Stripe: consultar sesión"), ("Stripe: consultar sesión", "Stripe: validar pago"), ("Stripe: validar pago", "¿Pago válido?"),
   ("¿Pago válido?", "Activar suscripción", 0), ("Activar suscripción", "¿Primera activación?"),
   ("¿Primera activación?", "Mensaje de bienvenida", 0), ("¿Primera activación?", "Email de bienvenida (pendiente SMTP)", 0),
   ("Mensaje de bienvenida", "CORE-02 Enviar WhatsApp")), [])

print(sorted(os.listdir(OUT)))
