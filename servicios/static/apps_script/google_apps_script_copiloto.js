/**
 * @fileoverview Copiloto de Respuestas con IA — Despacho desde Google Sheets
 *               DM Global · Servicio de Feedback
 *
 * Este archivo es la plantilla maestra de Google Apps Script para el flujo
 * de revisión y despacho del borrador de respuesta generado por la IA.
 *
 * NO corre en Django. Debe copiarse en el editor de Apps Script de la
 * planilla del cliente (Extensiones → Apps Script).
 *
 * ────────────────────────────────────────────────────────────────────────────
 * CÓMO CONECTAR EL BOTÓN
 * ────────────────────────────────────────────────────────────────────────────
 *  1. En la planilla, ir a Insertar → Dibujo → crear un botón con el texto
 *     "🚀 Despachar Respuesta".
 *  2. Clic derecho sobre el dibujo → "Asignar script" → despacharRespuestaCopiloto
 *  3. El gerente posiciona el cursor en cualquier celda de la fila que quiere
 *     despachar y hace clic en el botón.
 *
 * ────────────────────────────────────────────────────────────────────────────
 * LAYOUT ESPERADO — pestaña OPERACIONES
 * (extiende el layout de ClienteFeedbackDiario.gs con columnas F-J)
 * ────────────────────────────────────────────────────────────────────────────
 *  A  Nombre Turista
 *  B  Email / Contacto
 *  C  Idioma              → 'es' | 'en' | 'pt' | 'fr' | 'de'
 *  D  Fecha de Registro   → Date
 *  E  Estado Envío        → 'PENDIENTE' | 'ENVIADO' | 'ERROR'
 *  ── Columnas del Copiloto IA (completadas por el backend de DM Global) ──
 *  F  Canal               → 'email' | 'whatsapp'
 *  G  Calificación        → 1 | 2 | 3 (solo para quejas)
 *  H  Comentario Turista  → texto crudo del turista
 *  I  Borrador IA         → draft generado por Gemini; el gerente PUEDE editarlo
 *  J  Estado Copiloto     → 'PENDIENTE_REVISION' | 'RESPUESTA_ENVIADA'
 *
 * ────────────────────────────────────────────────────────────────────────────
 * FLUJO DE EJECUCIÓN
 * ────────────────────────────────────────────────────────────────────────────
 *  despacharRespuestaCopiloto()
 *  ├─ leerFilaActiva_()         → leer columnas A-J de la fila del cursor
 *  ├─ validarDespachable_()     → guards: cabecera, ya enviada, sin borrador
 *  ├─ despacharMensaje_()
 *  │   ├─ enviarEmailRespuesta_()   → GmailApp (canal 'email')
 *  │   └─ prepararWhatsApp_()       → stub Twilio (canal 'whatsapp')
 *  └─ marcarFilaComoEnviada_()  → estado + color verde
 */

'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 1 — CONFIGURACIÓN
// ─────────────────────────────────────────────────────────────────────────────

/** Nombre de la pestaña donde viven las operaciones y el Copiloto. */
const COPILOTO_HOJA = 'OPERACIONES';

/**
 * Índices de columna (1-based para getRange / 0-based para getValues[][col-1]).
 * Cambiar aquí si se reordena la hoja — el resto del código no cambia.
 */
const C = Object.freeze({
  NOMBRE:            1,   // A — Nombre del turista
  EMAIL:             2,   // B — Email o número WhatsApp del turista
  IDIOMA:            3,   // C — Código de idioma ('es', 'en', 'pt', 'fr', 'de')
  FECHA_REGISTRO:    4,   // D — Fecha en que fue cargada la fila
  ESTADO_ENVIO:      5,   // E — Estado del envío nocturno
  CANAL:             6,   // F — 'email' | 'whatsapp'
  CALIFICACION:      7,   // G — Calificación 1-3 estrellas
  COMENTARIO:        8,   // H — Texto del turista (comentario_turista en Django)
  BORRADOR_IA:       9,   // I — Borrador generado por Gemini (editable por el gerente)
  ESTADO_COPILOTO:   10,  // J — Estado del ciclo Copiloto
});

/** Estados del ciclo Copiloto (columna J). */
const ESTADO_COPILOTO = Object.freeze({
  PENDIENTE:  'PENDIENTE_REVISION',
  DESPACHADO: 'RESPUESTA_ENVIADA',
});

/** Color de fondo que indica tarea completada en la fila. */
const COLOR_ENVIADO   = '#d4edda';   // verde claro (Bootstrap success light)
const COLOR_ERROR     = '#f8d7da';   // rojo claro  (Bootstrap danger light)

/** Nombre visible del remitente en los emails de respuesta. */
const REMITENTE_NOMBRE = 'DM Global · Servicio de Feedback';

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 2 — PUNTO DE ENTRADA (asignado al botón visual)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Despacha el borrador de respuesta (editado o tal como lo generó la IA)
 * al turista de la fila donde el gerente tiene el cursor.
 *
 * Asignación del botón:
 *   Insertar → Dibujo → botón → clic derecho → "Asignar script"
 *   → despacharRespuestaCopiloto
 */
function despacharRespuestaCopiloto() {
  const ss    = SpreadsheetApp.getActiveSpreadsheet();
  const hoja  = ss.getActiveSheet();
  const filaActiva = hoja.getActiveCell().getRow();

  log_('INFO', `Copiloto activado | hoja="${hoja.getName()}" | fila=${filaActiva}`);

  // ── 1. Leer la fila activa ────────────────────────────────────────────
  let datos;
  try {
    datos = leerFilaActiva_(hoja, filaActiva);
  } catch (err) {
    mostrarError_(`Error leyendo la fila ${filaActiva}: ${err.message}`);
    return;
  }

  // ── 2. Validar que se puede despachar ─────────────────────────────────
  const validacion = validarDespachable_(datos, filaActiva);
  if (!validacion.ok) {
    mostrarError_(validacion.motivo);
    return;
  }

  // ── 3. Despachar por el canal elegido ────────────────────────────────
  let exito = false;
  try {
    exito = despacharMensaje_(datos, ss.getName());
  } catch (err) {
    log_('ERROR', `Error al despachar fila=${filaActiva}: ${err.message}`);
    marcarFilaComoError_(hoja, filaActiva, err.message);
    mostrarError_(`Error al enviar: ${err.message}`);
    return;
  }

  // ── 4. Marcar la fila como completada ────────────────────────────────
  if (exito) {
    marcarFilaComoEnviada_(hoja, filaActiva, Object.keys(C).length);
    log_('INFO', `Despacho exitoso | fila=${filaActiva} | canal=${datos.canal} | destino=${datos.contacto}`);
    ss.toast(
      `Respuesta enviada a ${datos.nombre} (${datos.contacto})`,
      '✅ Copiloto — Despacho completado',
      6
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 3 — LECTURA DE LA FILA ACTIVA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Lee las columnas A–J de la fila indicada y las devuelve como un objeto
 * tipado. Lee la CELDA DEL BORRADOR en tiempo real: si el gerente editó el
 * texto en la hoja, esta llamada captura la versión modificada (no la de
 * caché), porque se usa getValues() sobre el rango actual.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @param {number} numFila  Fila 1-based de la hoja.
 * @returns {{
 *   nombre: string, contacto: string, idioma: string,
 *   canal: string, calificacion: number|string,
 *   comentario: string, borrador: string, estadoCopiloto: string
 * }}
 */
function leerFilaActiva_(hoja, numFila) {
  const totalCols = Object.keys(C).length;   // = 10 columnas

  // getValues() siempre trae el valor ACTUAL de la celda, incluyendo
  // ediciones manuales que el gerente haya hecho en el borrador.
  const valores = hoja
    .getRange(numFila, 1, 1, totalCols)
    .getValues()[0];

  // Función helper para extraer y limpiar cada celda
  const cel = (col) => String(valores[col - 1] ?? '').trim();

  return {
    nombre:         cel(C.NOMBRE),
    contacto:       cel(C.EMAIL),
    idioma:         cel(C.IDIOMA).toLowerCase() || 'es',
    estadoEnvio:    cel(C.ESTADO_ENVIO).toUpperCase(),
    canal:          cel(C.CANAL).toLowerCase() || 'email',
    calificacion:   valores[C.CALIFICACION - 1],
    comentario:     cel(C.COMENTARIO),
    borrador:       cel(C.BORRADOR_IA),   // ← editable por el gerente
    estadoCopiloto: cel(C.ESTADO_COPILOTO).toUpperCase(),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 4 — VALIDACIONES PREVIAS AL DESPACHO
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Verifica las condiciones necesarias para despachar.
 * Devuelve { ok: boolean, motivo: string }.
 *
 * @param {Object} datos      Resultado de leerFilaActiva_()
 * @param {number} numFila
 * @returns {{ ok: boolean, motivo: string }}
 */
function validarDespachable_(datos, numFila) {
  // Guard: fila de encabezado
  if (numFila <= 1) {
    return { ok: false, motivo: 'Posicioná el cursor en una fila de datos, no en el encabezado.' };
  }

  // Guard: fila vacía
  if (!datos.nombre && !datos.contacto) {
    return { ok: false, motivo: `La fila ${numFila} está vacía. Elegí una fila con datos de turista.` };
  }

  // Guard: ya fue despachada
  if (datos.estadoCopiloto === ESTADO_COPILOTO.DESPACHADO) {
    return { ok: false, motivo: `La fila ${numFila} ya fue despachada (${ESTADO_COPILOTO.DESPACHADO}). No se enviará de nuevo.` };
  }

  // Guard: sin borrador
  if (!datos.borrador) {
    return {
      ok: false,
      motivo: `La celda "Borrador IA" (col. I) de la fila ${numFila} está vacía. ` +
              'Esperá a que el Copiloto genere el texto o escribilo manualmente.',
    };
  }

  // Guard: sin contacto
  if (!datos.contacto) {
    return { ok: false, motivo: `La fila ${numFila} no tiene email ni teléfono en la columna B.` };
  }

  // Guard: canal email sin @ en el contacto
  if (datos.canal === 'email' && !datos.contacto.includes('@')) {
    return {
      ok: false,
      motivo: `Canal "email" pero el contacto "${datos.contacto}" no parece un email válido.`,
    };
  }

  return { ok: true, motivo: '' };
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 5 — DESPACHO DE MENSAJES
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Enruta el borrador al canal correcto (email o WhatsApp).
 *
 * @param {Object} datos         Resultado de leerFilaActiva_()
 * @param {string} nombrePlanilla  Nombre de la planilla (usado como nombre comercio fallback)
 * @returns {boolean}  true si el despacho fue exitoso.
 */
function despacharMensaje_(datos, nombrePlanilla) {
  const nombreComercio = obtenerNombreComercio_(nombrePlanilla);

  switch (datos.canal) {
    case 'email':
      return enviarEmailRespuesta_(datos, nombreComercio);
    case 'whatsapp':
      return prepararWhatsApp_(datos, nombreComercio);
    default:
      log_('WARN', `Canal desconocido: "${datos.canal}". Se intentará por email.`);
      return enviarEmailRespuesta_(datos, nombreComercio);
  }
}

/**
 * Envía el borrador de respuesta por email al turista vía GmailApp.
 *
 * El asunto y el saludo se adaptan al idioma de la columna C.
 * El cuerpo es el borrador de la columna I (tal cual lo dejó el gerente).
 *
 * @param {Object} datos
 * @param {string} nombreComercio
 * @returns {boolean}
 */
function enviarEmailRespuesta_(datos, nombreComercio) {
  const { nombre, contacto, idioma, borrador } = datos;

  const textos = obtenerTextosEmail_(idioma);
  const asunto = textos.asunto(nombreComercio);

  GmailApp.sendEmail(
    contacto,
    asunto,
    textos.cuerpoPlano(nombre, borrador, nombreComercio),
    {
      name:     nombreComercio,
      htmlBody: construirHtmlRespuesta_(nombre, borrador, nombreComercio, textos),
      noReply:  false,
    }
  );

  log_('INFO', `Email de respuesta enviado | to=${contacto} | asunto="${asunto}"`);
  return true;
}

/**
 * Prepara el mensaje de WhatsApp (requiere Twilio en producción).
 *
 * Activación:
 *   PropertiesService.getScriptProperties().setProperties({
 *     TWILIO_SID:   'ACxxxxxxx',
 *     TWILIO_TOKEN: 'xxxxxxxx',
 *     TWILIO_FROM:  'whatsapp:+14155238886',
 *   });
 *   Luego descomentar el bloque UrlFetchApp.fetch() de abajo.
 *
 * @param {Object} datos
 * @param {string} nombreComercio
 * @returns {boolean}
 */
function prepararWhatsApp_(datos, nombreComercio) {
  const { contacto, nombre, borrador } = datos;
  const mensajeWA = `Hola ${nombre},\n${borrador}\n\n— ${nombreComercio}`;

  log_('INFO', `[WhatsApp — SIMULADO] Para: ${contacto} | "${mensajeWA.slice(0, 80)}..."`);

  /*
  // ── Activar con Twilio ──────────────────────────────────────────────────
  const props  = PropertiesService.getScriptProperties();
  const sid    = props.getProperty('TWILIO_SID');
  const token  = props.getProperty('TWILIO_TOKEN');
  const from   = props.getProperty('TWILIO_FROM');

  const resp = UrlFetchApp.fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`,
    {
      method:  'post',
      headers: { Authorization: `Basic ${Utilities.base64Encode(`${sid}:${token}`)}` },
      payload: { From: from, To: `whatsapp:${contacto}`, Body: mensajeWA },
      muteHttpExceptions: true,
    }
  );
  if (resp.getResponseCode() !== 201) {
    throw new Error(`Twilio error: HTTP ${resp.getResponseCode()} | ${resp.getContentText().slice(0,150)}`);
  }
  // ────────────────────────────────────────────────────────────────────────
  */

  return true;   // simulación siempre exitosa; en prod, reemplazar con bloque real
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 6 — ACTUALIZACIÓN VISUAL DE LA FILA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Marca la fila como despachada:
 *   · Columna J → 'RESPUESTA_ENVIADA'
 *   · Fondo de toda la fila → verde claro (#d4edda)
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @param {number} numFila
 * @param {number} totalCols  Cantidad de columnas a pintar.
 */
function marcarFilaComoEnviada_(hoja, numFila, totalCols) {
  // 1. Actualizar el estado en la columna J
  hoja.getRange(numFila, C.ESTADO_COPILOTO).setValue(ESTADO_COPILOTO.DESPACHADO);

  // 2. Pintar toda la fila de verde claro
  hoja.getRange(numFila, 1, 1, totalCols).setBackground(COLOR_ENVIADO);

  // Escritura inmediata (evita que un cierre accidental del navegador
  // deje la fila sin actualizar)
  SpreadsheetApp.flush();
}

/**
 * Pinta la fila de rojo claro y escribe el motivo del error en la columna J.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @param {number} numFila
 * @param {string} motivo
 */
function marcarFilaComoError_(hoja, numFila, motivo) {
  const totalCols = Object.keys(C).length;
  hoja.getRange(numFila, C.ESTADO_COPILOTO).setValue(`ERROR: ${motivo.slice(0, 100)}`);
  hoja.getRange(numFila, 1, 1, totalCols).setBackground(COLOR_ERROR);
  SpreadsheetApp.flush();
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 7 — TEMPLATE HTML DEL EMAIL DE RESPUESTA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Construye el HTML del email de respuesta del gerente al turista.
 * El diseño es deliberadamente simple y personal (no corporativo):
 * debe parecer una respuesta humana directa, no un boletín de marketing.
 *
 * @param {string} nombre         Nombre del turista (col A)
 * @param {string} borrador       Texto de la col I (versión del gerente)
 * @param {string} nombreComercio Nombre del hotel/resto/tour/etc.
 * @param {Object} textos         Resultado de obtenerTextosEmail_()
 * @returns {string}  HTML completo
 */
function construirHtmlRespuesta_(nombre, borrador, nombreComercio, textos) {
  // Convertir saltos de línea del borrador en párrafos HTML
  const parrafos = borrador
    .split(/\n+/)
    .filter(Boolean)
    .map((p) => `<p style="color:#374151;font-size:15px;line-height:1.7;margin:0 0 12px">${p}</p>`)
    .join('');

  return /* html */`
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1.0"/>
  <style>
    body   { margin:0; padding:0; background:#f9fafb; font-family:Arial,Helvetica,sans-serif; }
    .wrap  { max-width:540px; margin:24px auto; background:#fff; border-radius:12px;
             overflow:hidden; box-shadow:0 2px 8px rgba(0,0,0,.08); }
    .head  { background:#1e3a5f; padding:22px 28px; }
    .head p{ margin:0; color:#93c5fd; font-size:11px; letter-spacing:.1em; text-transform:uppercase; }
    .head h2{ margin:4px 0 0; color:#fff; font-size:18px; font-weight:700; }
    .body  { padding:26px 28px; }
    .saludo{ color:#111827; font-size:16px; font-weight:600; margin:0 0 16px; }
    .firma { margin-top:24px; padding-top:16px; border-top:1px solid #f3f4f6;
             color:#6b7280; font-size:13px; }
    .firma strong { color:#374151; }
    .badge { display:inline-block; background:#d1fae5; color:#065f46;
             font-size:11px; font-weight:700; padding:3px 10px; border-radius:20px;
             margin-bottom:16px; }
    .foot  { padding:14px 28px 18px; text-align:center; border-top:1px solid #f3f4f6; }
    .foot p{ color:#9ca3af; font-size:11px; margin:0; }
  </style>
</head>
<body>
<div class="wrap">

  <div class="head">
    <p>Respuesta de ${nombreComercio}</p>
    <h2>${textos.tituloEmail}</h2>
  </div>

  <div class="body">
    <span class="badge">✉️ ${textos.badgeRespuesta}</span>
    <p class="saludo">${textos.saludo(nombre)},</p>
    ${parrafos}
    <div class="firma">
      <strong>${nombreComercio}</strong><br/>
      ${textos.firmaAyuda}
    </div>
  </div>

  <div class="foot">
    <p>${textos.piePagina}</p>
  </div>

</div>
</body>
</html>`.trim();
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 8 — CONTENIDO MULTIIDIOMA DEL EMAIL
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Devuelve el mapa de strings del email según el idioma del turista.
 *
 * @param {'es'|'en'|'pt'|'fr'|'de'} idioma
 * @returns {Object}
 */
function obtenerTextosEmail_(idioma) {
  const TEXTOS = {
    es: {
      asunto:        (c) => `Respuesta de ${c} sobre tu experiencia`,
      tituloEmail:   'Gracias por compartir tu opinión',
      badgeRespuesta:'Respuesta del equipo',
      saludo:        (n) => `Estimado/a ${n}`,
      firmaAyuda:    'Si tenés más consultas, no dudes en contactarnos.',
      piePagina:     'Esta respuesta fue enviada a través del Servicio de Feedback de DM Global.',
      cuerpoPlano:   (n, txt, c) => `Estimado/a ${n},\n\n${txt}\n\nAtentamente,\n${c}`,
    },
    en: {
      asunto:        (c) => `Response from ${c} about your experience`,
      tituloEmail:   'Thank you for sharing your feedback',
      badgeRespuesta:'Reply from the team',
      saludo:        (n) => `Dear ${n}`,
      firmaAyuda:    'If you have any further questions, feel free to contact us.',
      piePagina:     'This reply was sent via the DM Global Feedback Service.',
      cuerpoPlano:   (n, txt, c) => `Dear ${n},\n\n${txt}\n\nBest regards,\n${c}`,
    },
    pt: {
      asunto:        (c) => `Resposta de ${c} sobre sua experiência`,
      tituloEmail:   'Obrigado por compartilhar sua opinião',
      badgeRespuesta:'Resposta da equipe',
      saludo:        (n) => `Prezado/a ${n}`,
      firmaAyuda:    'Se tiver mais dúvidas, não hesite em nos contatar.',
      piePagina:     'Esta resposta foi enviada pelo Serviço de Feedback da DM Global.',
      cuerpoPlano:   (n, txt, c) => `Prezado/a ${n},\n\n${txt}\n\nAtenciosamente,\n${c}`,
    },
    fr: {
      asunto:        (c) => `Réponse de ${c} concernant votre expérience`,
      tituloEmail:   'Merci pour votre retour',
      badgeRespuesta:"Réponse de l'équipe",
      saludo:        (n) => `Cher/Chère ${n}`,
      firmaAyuda:    "N'hésitez pas à nous contacter si vous avez d'autres questions.",
      piePagina:     'Cette réponse a été envoyée via le Service de Feedback de DM Global.',
      cuerpoPlano:   (n, txt, c) => `Cher/Chère ${n},\n\n${txt}\n\nCordialement,\n${c}`,
    },
    de: {
      asunto:        (c) => `Antwort von ${c} zu Ihrer Erfahrung`,
      tituloEmail:   'Vielen Dank für Ihr Feedback',
      badgeRespuesta:'Antwort des Teams',
      saludo:        (n) => `Sehr geehrte/r ${n}`,
      firmaAyuda:    'Wenn Sie weitere Fragen haben, kontaktieren Sie uns gerne.',
      piePagina:     'Diese Antwort wurde über den DM Global Feedback-Service gesendet.',
      cuerpoPlano:   (n, txt, c) => `Sehr geehrte/r ${n},\n\n${txt}\n\nMit freundlichen Grüßen,\n${c}`,
    },
  };

  return TEXTOS[idioma] ?? TEXTOS['es'];
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 9 — UTILIDADES
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Extrae el nombre del comercio del nombre de la planilla.
 * Formato esperado: "Servicio de feedback - Nombre del Comercio"
 *
 * @param {string} nombrePlanilla
 * @returns {string}
 */
function obtenerNombreComercio_(nombrePlanilla) {
  const prefijo = 'Servicio de feedback - ';
  return nombrePlanilla.startsWith(prefijo)
    ? nombrePlanilla.slice(prefijo.length)
    : nombrePlanilla;
}

/**
 * Muestra un alert de error en la UI del gerente.
 * @param {string} mensaje
 */
function mostrarError_(mensaje) {
  log_('WARN', `Despacho bloqueado: ${mensaje}`);
  SpreadsheetApp.getUi().alert(
    '⚠️ Copiloto — No se puede despachar',
    mensaje,
    SpreadsheetApp.getUi().ButtonSet.OK
  );
}

/**
 * Logging unificado: escribe en Logger (log clásico) y console (Cloud Logging).
 * @param {'INFO'|'WARN'|'ERROR'} nivel
 * @param {string} mensaje
 */
function log_(nivel, mensaje) {
  const ts  = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'HH:mm:ss');
  const txt = `[${ts}] [COPILOTO][${nivel}] ${mensaje}`;
  Logger.log(txt);
  console.log(txt);
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 10 — PRUEBA MANUAL (ejecutar desde el editor para verificar)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Función de prueba para correr desde el editor sin necesidad de un botón.
 * Simula datos de una fila de queja con borrador de IA y verifica la lógica
 * de validación y el template HTML sin enviar emails reales.
 *
 * Ejecutar: Editor → seleccionar testCopiloto → ▶ Ejecutar
 */
function testCopiloto() {
  Logger.log('═══ TEST COPILOTO ═══');

  // Simular los datos de una fila
  const datosFake = {
    nombre:         'Carlos Gómez',
    contacto:       'carlos@turista.com',
    idioma:         'es',
    estadoEnvio:    'ENVIADO',
    canal:          'email',
    calificacion:   2,
    comentario:     'El guía llegó tarde y no hablaba inglés.',
    borrador:       'Estimado Carlos, lamentamos profundamente los inconvenientes que tuvo durante su excursión. Estamos tomando medidas inmediatas con nuestro equipo de guías para evitar que esto se repita.',
    estadoCopiloto: 'PENDIENTE_REVISION',
  };

  // Test validaciones
  const v1 = validarDespachable_({ ...datosFake, estadoCopiloto: 'RESPUESTA_ENVIADA' }, 2);
  Logger.log(`Guard ya enviada: ok=${v1.ok} | motivo="${v1.motivo}"`);

  const v2 = validarDespachable_({ ...datosFake, borrador: '' }, 3);
  Logger.log(`Guard sin borrador: ok=${v2.ok} | motivo="${v2.motivo}"`);

  const v3 = validarDespachable_(datosFake, 4);
  Logger.log(`Fila válida: ok=${v3.ok} | motivo="${v3.motivo}"`);

  // Test template HTML
  const textos = obtenerTextosEmail_('es');
  const html   = construirHtmlRespuesta_(
    datosFake.nombre, datosFake.borrador, 'Tour Patagonia', textos
  );
  Logger.log(`HTML generado: ${html.length} chars`);
  Logger.log(`Asunto: "${textos.asunto('Tour Patagonia')}"`);

  // Test extracción de nombre de planilla
  Logger.log(`Nombre comercio: "${obtenerNombreComercio_('Servicio de feedback - Tour Patagonia')}"`);

  Logger.log('═══ FIN TEST ═══');
}
