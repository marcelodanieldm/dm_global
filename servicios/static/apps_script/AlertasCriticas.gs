/**
 * @fileoverview Alertas Críticas SMS/WhatsApp — Servicio de Feedback · DM Global
 *
 * Detecta calificaciones de 1-2 estrellas y notifica al comercio en el acto.
 *
 * Arquitectura de dos capas:
 *   1. Django (inmediato): en el momento que el turista da 1-2 estrellas,
 *      el servidor envía un email urgente al dueño del comercio.
 *   2. Este script (cada 30 min): complementa con WhatsApp/SMS usando los
 *      datos del turista que solo existen en la planilla de Google Sheets.
 *
 * Configurar el trigger:
 *   Editor de Apps Script → Reloj → Agregar trigger
 *   Función: verificarAlertasCriticas
 *   Tipo:    Basado en tiempo → Por minuto → Cada 30 minutos
 *
 * Dependencias en el mismo proyecto Apps Script:
 *   - FeedbackService.gs  (CFG, COL, leerCredenciales_, log_)
 *   - AprobacionBorrador.gs (OCOL, BCOL para búsqueda en planilla)
 */

'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIGURACIÓN
// ─────────────────────────────────────────────────────────────────────────────

/** @const {Object} ALERTA_CFG */
const ALERTA_CFG = Object.freeze({
  // Endpoints del CRM (actualizar con el dominio real)
  ENDPOINT_ALERTAS:    'https://TU-DOMINIO.com/api/v1/servicio-feedback/alertas-criticas/',
  ENDPOINT_ACK:        'https://TU-DOMINIO.com/api/v1/servicio-feedback/alertas-criticas/ack/',

  // Calificaciones que disparan la alerta (≤ este valor)
  UMBRAL_CRITICO:      2,

  // Asunto del email urgente que envía GmailApp (con datos del turista)
  ASUNTO_ALERTA:       '🚨 Cliente insatisfecho ahora mismo — ',
});

// ─────────────────────────────────────────────────────────────────────────────
// PUNTO DE ENTRADA — trigger cada 30 minutos
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Consulta el CRM por alertas críticas pendientes (calificacion <= 2 que
 * Django aún no notificó por WhatsApp), despacha el mensaje y confirma al CRM.
 *
 * Si la lista está vacía, termina en <100ms sin hacer nada.
 */
function verificarAlertasCriticas() {
  const creds = leerCredenciales_();
  if (!creds.comercioId || !creds.apiToken) {
    log_('WARN', '[Alertas] Sin credenciales en CONFIG. Trigger cancelado.');
    return;
  }

  // ── 1. Obtener alertas pendientes del CRM ─────────────────────────────
  const alertas = obtenerAlertasPendientes_(creds);
  if (alertas.length === 0) return;

  log_('INFO', `[Alertas] ${alertas.length} alerta(s) crítica(s) pendiente(s).`);

  const ss      = SpreadsheetApp.getActiveSpreadsheet();
  const hojaOps = ss.getSheetByName(CFG.HOJA_OPERACIONES);
  const hojaConf = ss.getSheetByName(CFG.HOJA_CONFIG);

  // Email del dueño del comercio (CONFIG!B4 = email_reporte, reutilizamos)
  const emailComercio = hojaConf
    ? String(hojaConf.getRange('B4').getValue()).trim()
    : '';

  const idsAck = [];

  // ── 2. Procesar cada alerta ────────────────────────────────────────────
  alertas.forEach((alerta) => {
    const turista = buscarTuristaEnPlanilla_(hojaOps, alerta.token_feedback);

    const exito = despacharAlertaCritica_({
      alerta,
      turista,
      emailComercio,
      nombreComercio: ss.getName(),
    });

    if (exito) idsAck.push(alerta.id);
  });

  // ── 3. Confirmar al CRM qué alertas fueron procesadas ─────────────────
  if (idsAck.length > 0) {
    confirmarAlertasWhatsApp_(creds, idsAck);
    log_('INFO', `[Alertas] ACK enviado al CRM para ${idsAck.length} alertas.`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FETCH AL CRM
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Consulta el endpoint de alertas críticas del CRM.
 * @param {{ comercioId: string, apiToken: string }} creds
 * @returns {Array<Object>}  Lista de alertas pendientes.
 */
function obtenerAlertasPendientes_({ comercioId, apiToken }) {
  const url = (
    `${ALERTA_CFG.ENDPOINT_ALERTAS}`
    + `?comercio_id=${encodeURIComponent(comercioId)}`
    + `&token=${encodeURIComponent(apiToken)}`
  );

  try {
    const resp = UrlFetchApp.fetch(url, {
      method:             'GET',
      muteHttpExceptions: true,
      headers:            { Accept: 'application/json' },
    });

    if (resp.getResponseCode() !== 200) {
      log_('WARN', `[Alertas] HTTP ${resp.getResponseCode()} al obtener alertas.`);
      return [];
    }
    return JSON.parse(resp.getContentText()).alertas || [];
  } catch (e) {
    log_('ERROR', `[Alertas] Error de red: ${e.message}`);
    return [];
  }
}

/**
 * Marca las alertas como notificadas por WhatsApp en el CRM.
 * @param {{ comercioId: string, apiToken: string }} creds
 * @param {string[]} ids  UUIDs de las RespuestaFeedback a marcar.
 */
function confirmarAlertasWhatsApp_({ comercioId, apiToken }, ids) {
  const url = (
    `${ALERTA_CFG.ENDPOINT_ACK}`
    + `?comercio_id=${encodeURIComponent(comercioId)}`
    + `&token=${encodeURIComponent(apiToken)}`
  );
  try {
    UrlFetchApp.fetch(url, {
      method:             'POST',
      muteHttpExceptions: true,
      contentType:        'application/json',
      payload:            JSON.stringify({ ids }),
    });
  } catch (e) {
    log_('ERROR', `[Alertas] Error en ACK: ${e.message}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BÚSQUEDA EN PLANILLA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Busca la fila de OPERACIONES que tiene el ``token_feedback`` en columna K
 * y retorna los datos del turista (nombre, email, teléfono, idioma).
 *
 * Usa ``TextFinder`` (una sola búsqueda, sin loop) para máxima eficiencia.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hojaOps
 * @param {string} tokenFeedback  UUID del token que identifica la fila.
 * @returns {{ nombre: string, email: string, telefono: string, idioma: string } | null}
 */
function buscarTuristaEnPlanilla_(hojaOps, tokenFeedback) {
  if (!hojaOps || !tokenFeedback) return null;

  const celda = hojaOps
    .createTextFinder(tokenFeedback)
    .matchEntireCell(true)
    .findNext();

  if (!celda) return null;

  const fila = celda.getRow();
  const data = hojaOps.getRange(fila, 1, 1, Object.keys(COL).length).getValues()[0];

  return {
    nombre:   String(data[COL.NOMBRE_TURISTA - 1] || '').trim(),
    email:    String(data[COL.EMAIL          - 1] || '').trim(),
    telefono: String(data[COL.TELEFONO       - 1] || '').trim(),
    idioma:   String(data[COL.IDIOMA         - 1] || 'es').trim().toLowerCase(),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// DESPACHO DE ALERTAS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Despacha la alerta por el canal disponible:
 *   • Si hay teléfono → WhatsApp (Twilio stub) como canal principal.
 *   • Si hay email del turista Y la alerta Django aún no se envió → email GmailApp.
 *   • Siempre loggea el resultado.
 *
 * @param {{ alerta, turista, emailComercio, nombreComercio }} ctx
 * @returns {boolean}  true si al menos un canal fue despachado.
 */
function despacharAlertaCritica_({ alerta, turista, emailComercio, nombreComercio }) {
  const { calificacion, comentario, token_feedback, email_ya_enviado } = alerta;
  const stars = '★'.repeat(calificacion) + '☆'.repeat(5 - calificacion);

  let enviado = false;

  // ── Canal WhatsApp (al dueño del comercio) ────────────────────────────
  if (emailComercio) {
    // En producción: reemplazar GmailApp.sendEmail por llamada a Twilio
    // con el teléfono del dueño del comercio (guardado en CONFIG!B6).
    const asunto = `${ALERTA_CFG.ASUNTO_ALERTA}${nombreComercio}`;
    const cuerpo = construirMensajeAlerta_({ stars, calificacion, comentario, turista, token_feedback });

    try {
      GmailApp.sendEmail(
        emailComercio,
        asunto,
        cuerpo.plano,
        { name: 'DM Global · Alertas Críticas', htmlBody: cuerpo.html }
      );
      log_('INFO', `[Alertas] Email urgente enviado a ${emailComercio} | stars=${calificacion}`);
      enviado = true;
    } catch (e) {
      log_('ERROR', `[Alertas] Error enviando email urgente: ${e.message}`);
    }
  }

  // ── WhatsApp vía Twilio (stub) ─────────────────────────────────────────
  if (turista && turista.telefono) {
    enviado = enviarWhatsAppAlerta_({ alerta, turista, nombreComercio }) || enviado;
  }

  if (!enviado) {
    log_('WARN', `[Alertas] Sin canal disponible para alerta | token=${token_feedback}`);
  }

  return enviado;
}

/**
 * Construye los cuerpos de texto y HTML del mensaje de alerta.
 */
function construirMensajeAlerta_({ stars, calificacion, comentario, turista, token_feedback }) {
  const nombreTurista = turista ? turista.nombre || 'Sin nombre' : 'desconocido (buscar en planilla)';
  const tel           = turista ? turista.telefono || '(no disponible)' : '(buscar en planilla)';
  const emailTurista  = turista ? turista.email    || '(no disponible)' : '(buscar en planilla)';

  const plano = [
    `🚨 ALERTA CRÍTICA — ${stars} (${calificacion}/5)`,
    ``,
    `Turista: ${nombreTurista}`,
    `Teléfono: ${tel}`,
    `Email: ${emailTurista}`,
    ``,
    `Comentario: ${comentario || 'Sin comentario'}`,
    ``,
    `Token en planilla (col. K): ${token_feedback}`,
    ``,
    `⏱ Contactalo/a en los próximos 60 minutos.`,
  ].join('\n');

  const html = /* html */`
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"/>
<style>
  body{margin:0;padding:0;background:#fef2f2;font-family:Arial,sans-serif;}
  .w{max-width:520px;margin:16px auto;background:#fff;border-radius:12px;
     border:2px solid #fca5a5;overflow:hidden;}
  .h{background:#dc2626;padding:20px 24px;}
  .h p{margin:0;color:#fca5a5;font-size:11px;text-transform:uppercase;}
  .h h1{margin:4px 0 0;color:#fff;font-size:20px;}
  .h .s{font-size:26px;margin-top:6px;}
  .b{padding:20px 24px;}
  .b p{color:#374151;font-size:14px;line-height:1.6;margin:0 0 12px;}
  .row{display:flex;justify-content:space-between;padding:6px 0;
       border-bottom:1px solid #fef2f2;font-size:14px;}
  .lbl{color:#6b7280;} .val{font-weight:700;color:#111827;}
  .q{background:#fef2f2;border-left:3px solid #dc2626;padding:10px 14px;
     font-style:italic;color:#7f1d1d;font-size:14px;margin:12px 0;border-radius:0 6px 6px 0;}
  .tok{background:#f3f4f6;border-radius:6px;padding:8px 12px;
       font-family:monospace;font-size:12px;color:#4b5563;word-break:break-all;}
  .f{padding:12px 24px 18px;text-align:center;color:#9ca3af;font-size:11px;
     border-top:1px solid #fee2e2;}
</style>
</head>
<body><div class="w">
  <div class="h">
    <p>🚨 Alerta crítica · DM Global</p>
    <h1>${nombreTurista}</h1>
    <div class="s">${stars}</div>
  </div>
  <div class="b">
    <div class="row"><span class="lbl">Calificación</span><span class="val">${calificacion}/5</span></div>
    <div class="row"><span class="lbl">Teléfono</span><span class="val">${tel}</span></div>
    <div class="row"><span class="lbl">Email</span><span class="val">${emailTurista}</span></div>
    ${comentario ? `<div class="q">"${comentario}"</div>` : '<p style="color:#9ca3af">Sin comentario escrito.</p>'}
    <p style="font-size:12px;color:#6b7280;margin-top:12px;">
      Token para búsqueda en planilla (col. K):
    </p>
    <div class="tok">${token_feedback}</div>
    <p style="text-align:center;font-size:13px;color:#dc2626;font-weight:700;margin-top:16px;">
      ⏱ Contactalo/a en los próximos 60 minutos.
    </p>
  </div>
  <div class="f">Servicio de Feedback · DM Global</div>
</div></body></html>`.trim();

  return { plano, html };
}

/**
 * Stub de WhatsApp via Twilio para alertas críticas al comercio.
 * Ver instrucciones de activación en FeedbackService.gs::prepararWhatsApp_
 *
 * @param {{ alerta, turista, nombreComercio }} ctx
 * @returns {boolean}
 */
function enviarWhatsAppAlerta_({ alerta, turista, nombreComercio }) {
  const msg = [
    `🚨 *ALERTA — ${nombreComercio}*`,
    ``,
    `Un turista dio *${alerta.calificacion} estrella(s)*.`,
    ``,
    `👤 ${turista.nombre || 'Sin nombre'}`,
    `📞 ${turista.telefono}`,
    turista.email ? `📧 ${turista.email}` : '',
    alerta.comentario ? `\n💬 "${alerta.comentario}"` : '',
    ``,
    `⏱ Contactalo en los próximos 60 min.`,
  ].filter(Boolean).join('\n');

  log_('INFO', `[Alertas WhatsApp — SIMULADO] Para: ${turista.telefono} | "${msg.slice(0,60)}..."`);

  /*
  // ── Activar con Twilio ─────────────────────────────────────────────────
  const props   = PropertiesService.getScriptProperties();
  const sid     = props.getProperty('TWILIO_SID');
  const token   = props.getProperty('TWILIO_TOKEN');
  const from    = props.getProperty('TWILIO_FROM');     // whatsapp:+14155238886
  const toNum   = `whatsapp:${turista.telefono}`;

  const resp = UrlFetchApp.fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`,
    {
      method:  'post',
      headers: { Authorization: `Basic ${Utilities.base64Encode(`${sid}:${token}`)}` },
      payload: { From: from, To: toNum, Body: msg },
      muteHttpExceptions: true,
    }
  );
  return resp.getResponseCode() === 201;
  // ────────────────────────────────────────────────────────────────────────
  */

  return true;   // simulación siempre exitosa
}
