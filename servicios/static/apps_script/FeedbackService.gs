/**
 * @fileoverview Servicio de Feedback — CRM DM Global
 *
 * Script adjunto a la hoja de Google Sheets del comercio.
 * Se ejecuta diariamente mediante un trigger de tiempo de Apps Script.
 *
 * Estructura modular:
 *  procesarEncuestasDiarias()  ← punto de entrada (trigger)
 *  ├─ leerCredenciales_()      ← lee pestaña CONFIG
 *  ├─ validarSuscripcion_()    ← fetch al endpoint CRM
 *  ├─ obtenerFilasPendientes_()← filtra pestaña OPERACIONES
 *  └─ procesarFila_()
 *      ├─ obtenerTextos_()     ← i18n: 'es' | 'en'
 *      └─ despacharMensaje_()
 *          ├─ enviarEmail_()   ← GmailApp
 *          └─ prepararWhatsApp_() ← stub (Twilio / provider)
 *
 * Layout esperado — pestaña CONFIG:
 *   A2: "comercio_id"   B2: <UUID>
 *   A3: "api_token"     B3: <UUID>
 *
 * Layout esperado — pestaña OPERACIONES (fila 1 = encabezados):
 *   A: ID          B: Nombre Turista   C: Email         D: Teléfono
 *   E: Idioma      F: Canal            G: Fecha Fin     H: Estado
 *   I: Tipo Svc    J: Notas            K: Token Feedback
 */

'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 1 — CONFIGURACIÓN GLOBAL (único lugar a editar para adaptar el script)
// ─────────────────────────────────────────────────────────────────────────────

/** @const {Object} CFG  Parámetros de la integración con DM Global. */
const CFG = Object.freeze({
  // Hojas de cálculo
  HOJA_CONFIG:        'CONFIG',
  HOJA_OPERACIONES:   'OPERACIONES',

  // Celdas del panel CONFIG donde el operador pega las credenciales
  CELDA_COMERCIO_ID:  'B2',
  CELDA_API_TOKEN:    'B3',

  // Endpoints del CRM DM Global (actualizar con el dominio real en producción)
  ENDPOINT_VALIDAR:   'https://TU-DOMINIO.com/api/v1/servicio-feedback/validar/',
  ENDPOINT_PORTAL:    'https://TU-DOMINIO.com/feedback/',   // {comercio_id}/{token}/?lang={idioma}

  // Horas mínimas que deben haber transcurrido desde la fecha de finalización
  // para que una fila sea elegible para el envío de la encuesta.
  HORAS_UMBRAL:       24,

  // Pausa entre envíos para no saturar la API de Gmail (ms)
  DELAY_ENTRE_ENVIOS: 1200,

  // Remitente visible en los correos salientes
  EMAIL_NOMBRE_REMITENTE: 'DM Global · Servicio de Feedback',
});

/**
 * @const {Object} COL  Índices de columna en OPERACIONES (1-based).
 * Modificar aquí si se reordena la hoja; el resto del código no cambia.
 */
const COL = Object.freeze({
  ID:                  1,   // A
  NOMBRE_TURISTA:      2,   // B
  EMAIL:               3,   // C
  TELEFONO:            4,   // D
  IDIOMA:              5,   // E → 'es' | 'en'
  CANAL:               6,   // F → 'email' | 'whatsapp'
  FECHA_FINALIZACION:  7,   // G → Date
  ESTADO:              8,   // H → 'PENDIENTE' | 'ENVIADO' | 'ERROR'
  TIPO_SERVICIO:       9,   // I → rellenado desde la respuesta API
  NOTAS:               10,  // J
  TOKEN_FEEDBACK:      11,  // K → UUID generado por AprobacionBorrador.gs
});

/** @enum {string} */
const ESTADO = Object.freeze({
  PENDIENTE: 'PENDIENTE',
  ENVIADO:   'ENVIADO',
  ERROR:     'ERROR',
});

/** @enum {string} */
const CANAL = Object.freeze({
  EMAIL:     'email',
  WHATSAPP:  'whatsapp',
});

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 2 — PUNTO DE ENTRADA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Orquesta el proceso diario de envío de encuestas de feedback.
 * Configurar como trigger: Tiempo → Día → Hora elegida (ej. 10:00–11:00 hs).
 */
function procesarEncuestasDiarias() {
  const inicio = Date.now();
  log_('INFO', '═══ Inicio procesarEncuestasDiarias ═══');

  // ── Paso 1: Leer credenciales desde CONFIG ──────────────────────────────
  const credenciales = leerCredenciales_();
  if (!credenciales.comercioId || !credenciales.apiToken) {
    log_('ERROR', 'Credenciales vacías en la pestaña CONFIG. Ejecución abortada.');
    return;
  }

  // ── Paso 2: Validar suscripción con el CRM DM Global ───────────────────
  const suscripcion = validarSuscripcion_(credenciales);
  if (!suscripcion.autorizado) {
    log_('WARN', `Ejecución detenida. Respuesta del CRM: "${suscripcion.error}"`);
    return;
  }
  log_('INFO', `Suscripción activa | comercio="${suscripcion.nombreComercio}" | tipo="${suscripcion.tipoNegocio}"`);

  // ── Paso 3: Obtener filas pendientes de OPERACIONES ────────────────────
  const ss          = SpreadsheetApp.getActiveSpreadsheet();
  const hojaOps     = ss.getSheetByName(CFG.HOJA_OPERACIONES);
  const umbralMs    = CFG.HORAS_UMBRAL * 60 * 60 * 1000;
  const pendientes  = obtenerFilasPendientes_(hojaOps, umbralMs);

  if (pendientes.length === 0) {
    log_('INFO', 'No hay filas pendientes para procesar hoy.');
    return;
  }
  log_('INFO', `Filas elegibles: ${pendientes.length}`);

  // ── Paso 4: Procesar cada fila ──────────────────────────────────────────
  let enviados = 0, errores = 0;

  pendientes.forEach(({ fila, datos }) => {
    const exito = procesarFila_(hojaOps, fila, datos, suscripcion);
    exito ? enviados++ : errores++;
    Utilities.sleep(CFG.DELAY_ENTRE_ENVIOS); // throttle para no saturar Gmail
  });

  const duracionSeg = ((Date.now() - inicio) / 1000).toFixed(1);
  log_('INFO', `═══ Fin | enviados=${enviados} | errores=${errores} | tiempo=${duracionSeg}s ═══`);
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 3 — CREDENCIALES Y VALIDACIÓN
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Lee las credenciales desde la pestaña CONFIG.
 * @returns {{ comercioId: string, apiToken: string }}
 */
function leerCredenciales_() {
  const ss     = SpreadsheetApp.getActiveSpreadsheet();
  const hoja   = ss.getSheetByName(CFG.HOJA_CONFIG);

  if (!hoja) {
    log_('ERROR', `No se encontró la pestaña "${CFG.HOJA_CONFIG}".`);
    return { comercioId: '', apiToken: '' };
  }

  const comercioId = String(hoja.getRange(CFG.CELDA_COMERCIO_ID).getValue()).trim();
  const apiToken   = String(hoja.getRange(CFG.CELDA_API_TOKEN).getValue()).trim();

  return { comercioId, apiToken };
}

/**
 * Hace el fetch de validación al endpoint del CRM DM Global.
 * Detiene la ejecución (retorna autorizado=false) ante cualquier error HTTP.
 *
 * @param {{ comercioId: string, apiToken: string }} credenciales
 * @returns {{ autorizado: boolean, nombreComercio?: string,
 *             tipoNegocio?: string, googleReviewLink?: string,
 *             error?: string }}
 */
function validarSuscripcion_({ comercioId, apiToken }) {
  const url = `${CFG.ENDPOINT_VALIDAR}?comercio_id=${encodeURIComponent(comercioId)}&token=${encodeURIComponent(apiToken)}`;

  let respuesta;
  try {
    const response = UrlFetchApp.fetch(url, {
      method:               'GET',
      muteHttpExceptions:   true,          // evita que un 401/403 tire excepción
      followRedirects:      true,
      headers: { 'Accept': 'application/json' },
    });

    const statusCode = response.getResponseCode();
    const cuerpo     = JSON.parse(response.getContentText());

    if (statusCode === 200 && cuerpo.autorizado === true) {
      return {
        autorizado:       true,
        comercioId,                          // propagado para armar URL del portal
        nombreComercio:   cuerpo.nombre_comercio,
        tipoNegocio:      cuerpo.tipo_negocio,
        googleReviewLink: cuerpo.google_review_link,
      };
    }

    // 401 (credenciales inválidas) o 403 (suscripción suspendida)
    log_('WARN', `HTTP ${statusCode} desde el CRM | error="${cuerpo.error}"`);
    return { autorizado: false, error: cuerpo.error || `HTTP ${statusCode}` };

  } catch (e) {
    // Error de red, timeout, DNS, etc.
    log_('ERROR', `Error de red al contactar el CRM: ${e.message}`);
    return { autorizado: false, error: e.message };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 4 — RECORRIDO DE FILAS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Devuelve las filas de OPERACIONES que cumplen ambas condiciones:
 *   • ESTADO === 'PENDIENTE'
 *   • (ahora − fecha_finalización) ≥ umbralMs
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @param {number} umbralMs  Milisegundos mínimos transcurridos desde fecha fin.
 * @returns {Array<{ fila: number, datos: Array }>}
 */
function obtenerFilasPendientes_(hoja, umbralMs) {
  const valores   = hoja.getDataRange().getValues(); // 2D array (índice 0 = encabezados)
  const ahora     = Date.now();
  const pendientes = [];

  // Fila 0 = encabezados; datos empiezan en índice 1 → fila 2 en la hoja
  for (let i = 1; i < valores.length; i++) {
    const fila  = i + 1;   // número de fila real en la hoja (1-based)
    const datos = valores[i];

    const estado           = String(datos[COL.ESTADO - 1]).trim().toUpperCase();
    const fechaFinalizacion = datos[COL.FECHA_FINALIZACION - 1];

    if (estado !== ESTADO.PENDIENTE) continue;
    if (!(fechaFinalizacion instanceof Date) || isNaN(fechaFinalizacion.getTime())) {
      log_('WARN', `Fila ${fila}: fecha de finalización inválida o vacía. Se omite.`);
      continue;
    }

    const tiempoTranscurrido = ahora - fechaFinalizacion.getTime();
    if (tiempoTranscurrido < umbralMs) continue;

    pendientes.push({ fila, datos });
  }

  return pendientes;
}

/**
 * Procesa una fila individual: construye los datos, despacha el mensaje
 * y actualiza el estado en la hoja.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @param {number} numFila
 * @param {Array}  datos          Valores de la fila (0-based).
 * @param {Object} suscripcion    Datos del comercio devueltos por el CRM.
 * @returns {boolean}  true si el envío fue exitoso.
 */
function procesarFila_(hoja, numFila, datos, suscripcion) {
  const canal          = String(datos[COL.CANAL - 1]).trim().toLowerCase();
  const idioma         = String(datos[COL.IDIOMA - 1]).trim().toLowerCase();
  const email          = String(datos[COL.EMAIL - 1]).trim();
  const tel            = String(datos[COL.TELEFONO - 1]).trim();
  const nombre         = String(datos[COL.NOMBRE_TURISTA - 1]).trim();
  const tokenFeedback  = String(datos[COL.TOKEN_FEEDBACK - 1]).trim();

  // URL del portal de valoración: el turista elige 1-5 estrellas antes de
  // llegar a Google Reviews. Sin token válido se degrada al link directo.
  const urlPortal = tokenFeedback
    ? `${CFG.ENDPOINT_PORTAL}${suscripcion.comercioId}/${tokenFeedback}/?lang=${idioma}`
    : suscripcion.googleReviewLink;

  const payload = {
    nombre,
    email,
    telefono:         tel,
    idioma:           ['es', 'en'].includes(idioma) ? idioma : 'es',
    canal,
    nombreComercio:   suscripcion.nombreComercio,
    tipoNegocio:      suscripcion.tipoNegocio,
    googleReviewLink: suscripcion.googleReviewLink,
    urlPortal,          // ← el email enlaza al portal, no a Google directamente
  };

  try {
    despacharMensaje_(payload);
    actualizarEstado_(hoja, numFila, ESTADO.ENVIADO);
    log_('INFO', `Fila ${numFila}: enviado OK | canal=${canal} | destino=${canal === CANAL.EMAIL ? email : tel}`);
    return true;
  } catch (e) {
    actualizarEstado_(hoja, numFila, ESTADO.ERROR);
    log_('ERROR', `Fila ${numFila}: fallo al enviar | ${e.message}`);
    return false;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 5 — DESPACHO DE MENSAJES
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Enruta el mensaje al canal correcto (email / whatsapp).
 * @param {Object} payload
 */
function despacharMensaje_(payload) {
  switch (payload.canal) {
    case CANAL.EMAIL:
      enviarEmail_(payload);
      break;
    case CANAL.WHATSAPP:
      prepararWhatsApp_(payload);
      break;
    default:
      throw new Error(`Canal desconocido: "${payload.canal}"`);
  }
}

/**
 * Envía el correo de encuesta mediante GmailApp.
 * @param {Object} payload
 */
function enviarEmail_(payload) {
  const textos = obtenerTextos_(payload.idioma, payload.tipoNegocio);

  GmailApp.sendEmail(
    payload.email,
    textos.asunto(payload.nombreComercio),
    textos.cuerpoPlano(payload),
    {
      name:     CFG.EMAIL_NOMBRE_REMITENTE,
      htmlBody: construirHtmlEmail_(payload, textos),
      noReply:  false,
    }
  );
}

/**
 * Despacha el mensaje de WhatsApp (requiere Twilio en producción).
 *
 * Activación:
 *   PropertiesService.getScriptProperties().setProperties({
 *     TWILIO_SID:   'ACxxx', TWILIO_TOKEN: 'xxx',
 *     TWILIO_FROM:  'whatsapp:+14155238886',
 *   });
 *   Descomentar el bloque UrlFetchApp.fetch() abajo.
 *
 * @param {Object} payload
 */
function prepararWhatsApp_(payload) {
  const textos  = obtenerTextos_(payload.idioma, payload.tipoNegocio);
  const mensaje = textos.cuerpoWhatsApp(payload);

  log_('INFO', `[WhatsApp ${payload.tipoNegocio} — SIMULADO] ${payload.telefono} | "${mensaje.slice(0, 80)}..."`);

  /*
  const props = PropertiesService.getScriptProperties();
  UrlFetchApp.fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${props.getProperty('TWILIO_SID')}/Messages.json`,
    {
      method:  'post',
      headers: { Authorization: `Basic ${Utilities.base64Encode(
        `${props.getProperty('TWILIO_SID')}:${props.getProperty('TWILIO_TOKEN')}`)}` },
      payload: { From: props.getProperty('TWILIO_FROM'),
                 To: `whatsapp:${payload.telefono}`, Body: mensaje },
      muteHttpExceptions: true,
    }
  );
  */
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 6 — CONTENIDO POR TIPO DE NEGOCIO E IDIOMA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Devuelve el mapa de textos para el idioma Y tipo de negocio indicados.
 *
 * Estructura: TIPOS[tipoNegocio][idioma] → objeto de funciones/strings.
 * Agregar un nuevo tipo: copiar un bloque existente con la nueva clave.
 * Agregar un idioma:    añadir la clave dentro de cada tipo.
 *
 * @param {'es'|'en'} idioma
 * @param {'HOTEL'|'TOUR'|'TRANSFER'|'ALQUILER'|'RESTO'} tipoNegocio
 * @returns {Object}
 */
function obtenerTextos_(idioma, tipoNegocio = 'HOTEL') {
  const TIPOS = {

    // ── Alojamiento / Hotel ──────────────────────────────────────────────
    HOTEL: {
      es: {
        emoji: '🏨',
        asunto: (c) => `¿Cómo estuvo tu estadía en ${c}? 🏨`,
        intro:  (n) => `Gracias por hospedarte con nosotros, <strong>${n}</strong>. Tu comodidad es nuestra prioridad.`,
        pregunta:  '¿Cómo calificarías tu estadía?',
        subtitulo: 'Tu experiencia como huésped nos importa mucho.',
        cuerpoPlano: ({ nombre, nombreComercio, urlPortal }) =>
          `Hola ${nombre},\n\nGracias por hospedarte en ${nombreComercio}.\n` +
          `Contanos cómo estuvo tu estadía: ${urlPortal}\n\n¡Hasta pronto!\n${nombreComercio}`,
        cuerpoWhatsApp: ({ nombre, nombreComercio, urlPortal }) =>
          `¡Hola ${nombre}! 🏨\n` +
          `Gracias por hospedarte en *${nombreComercio}*.\n` +
          `¿Cómo estuvo tu estadía? Solo 30 segundos 🙏\n` +
          `👉 ${urlPortal}`,
        botonCTA: '🏨 Calificar mi estadía',
        saludo:   '¡Esperamos verte pronto!',
      },
      en: {
        emoji: '🏨',
        asunto: (c) => `How was your stay at ${c}? 🏨`,
        intro:  (n) => `Thank you for staying with us, <strong>${n}</strong>. Your comfort is our priority.`,
        pregunta:  'How would you rate your stay?',
        subtitulo: 'Your guest experience matters to us.',
        cuerpoPlano: ({ nombre, nombreComercio, urlPortal }) =>
          `Hi ${nombre},\n\nThank you for staying at ${nombreComercio}.\n` +
          `Tell us how it went: ${urlPortal}\n\nSee you soon!\n${nombreComercio}`,
        cuerpoWhatsApp: ({ nombre, nombreComercio, urlPortal }) =>
          `Hi ${nombre}! 🏨\n` +
          `Thank you for staying at *${nombreComercio}*.\n` +
          `How was your stay? Just 30 seconds 🙏\n` +
          `👉 ${urlPortal}`,
        botonCTA: '🏨 Rate my stay',
        saludo:   'Hope to see you again soon!',
      },
    },

    // ── Excursiones / Tour Operador ──────────────────────────────────────
    TOUR: {
      es: {
        emoji: '🌿',
        asunto: (c) => `¿Cómo fue tu excursión con ${c}? 🌿`,
        intro:  (n) => `¡Esperamos que tu aventura haya sido increíble, <strong>${n}</strong>!`,
        pregunta:  '¿Cómo calificarías tu excursión?',
        subtitulo: 'Tu aventura, tu opinión.',
        cuerpoPlano: ({ nombre, nombreComercio, urlPortal }) =>
          `¡Hola ${nombre}!\n\nEsperamos que hayas disfrutado tu excursión con ${nombreComercio}.\n` +
          `¿Cómo te fue? ${urlPortal}\n\n¡Hasta la próxima aventura!\n${nombreComercio}`,
        cuerpoWhatsApp: ({ nombre, nombreComercio, urlPortal }) =>
          `¡Hola ${nombre}! 🌿\n` +
          `¿Cómo estuvo tu excursión con *${nombreComercio}*?\n` +
          `Un momento de tu tiempo nos ayuda mucho 🙏\n` +
          `👉 ${urlPortal}`,
        botonCTA: '🌿 Calificar mi excursión',
        saludo:   '¡Hasta la próxima aventura!',
      },
      en: {
        emoji: '🌿',
        asunto: (c) => `How was your tour with ${c}? 🌿`,
        intro:  (n) => `We hope your adventure was amazing, <strong>${n}</strong>!`,
        pregunta:  'How would you rate your tour?',
        subtitulo: 'Your adventure, your review.',
        cuerpoPlano: ({ nombre, nombreComercio, urlPortal }) =>
          `Hi ${nombre}!\n\nWe hope you enjoyed your tour with ${nombreComercio}.\n` +
          `How was it? ${urlPortal}\n\nUntil the next adventure!\n${nombreComercio}`,
        cuerpoWhatsApp: ({ nombre, nombreComercio, urlPortal }) =>
          `Hi ${nombre}! 🌿\n` +
          `How was your tour with *${nombreComercio}*?\n` +
          `A moment of your time means a lot 🙏\n` +
          `👉 ${urlPortal}`,
        botonCTA: '🌿 Rate my tour',
        saludo:   'Until the next adventure!',
      },
    },

    // ── Traslados / Transfer ─────────────────────────────────────────────
    TRANSFER: {
      es: {
        emoji: '🚐',
        asunto: (c) => `¿Cómo fue tu traslado con ${c}? 🚐`,
        intro:  (n) => `Tu tiempo es valioso, <strong>${n}</strong>. ¿Llegaste cómodo y a tiempo?`,
        pregunta:  '¿Cómo calificarías tu traslado?',
        subtitulo: 'Puntualidad y comodidad, siempre.',
        cuerpoPlano: ({ nombre, nombreComercio, urlPortal }) =>
          `Hola ${nombre},\n\nGracias por viajar con ${nombreComercio}.\n` +
          `¿Cómo fue tu traslado? ${urlPortal}\n\n¡Hasta el próximo viaje!\n${nombreComercio}`,
        cuerpoWhatsApp: ({ nombre, nombreComercio, urlPortal }) =>
          `¡Hola ${nombre}! 🚐\n` +
          `Gracias por viajar con *${nombreComercio}*.\n` +
          `¿Cómo fue tu traslado? Solo un minuto 🙏\n` +
          `👉 ${urlPortal}`,
        botonCTA: '🚐 Calificar mi traslado',
        saludo:   '¡Buen viaje siempre!',
      },
      en: {
        emoji: '🚐',
        asunto: (c) => `How was your transfer with ${c}? 🚐`,
        intro:  (n) => `Your time is precious, <strong>${n}</strong>. Did everything go smoothly?`,
        pregunta:  'How would you rate your transfer?',
        subtitulo: 'Punctuality and comfort, always.',
        cuerpoPlano: ({ nombre, nombreComercio, urlPortal }) =>
          `Hi ${nombre},\n\nThank you for traveling with ${nombreComercio}.\n` +
          `How was your transfer? ${urlPortal}\n\nSafe travels!\n${nombreComercio}`,
        cuerpoWhatsApp: ({ nombre, nombreComercio, urlPortal }) =>
          `Hi ${nombre}! 🚐\n` +
          `Thank you for traveling with *${nombreComercio}*.\n` +
          `How was your transfer? Just one minute 🙏\n` +
          `👉 ${urlPortal}`,
        botonCTA: '🚐 Rate my transfer',
        saludo:   'Safe travels!',
      },
    },

    // ── Alquiler de Vehículos ────────────────────────────────────────────
    ALQUILER: {
      es: {
        emoji: '🚗',
        asunto: (c) => `¿Cómo estuvo tu alquiler en ${c}? 🚗`,
        intro:  (n) => `Gracias por elegir nuestros vehículos, <strong>${n}</strong>. ¿Cómo anduvo todo?`,
        pregunta:  '¿Cómo calificarías tu experiencia de alquiler?',
        subtitulo: 'Tu experiencia al volante nos importa.',
        cuerpoPlano: ({ nombre, nombreComercio, urlPortal }) =>
          `Hola ${nombre},\n\nGracias por alquilar en ${nombreComercio}.\n` +
          `¿Cómo fue tu experiencia? ${urlPortal}\n\n¡Hasta la próxima!\n${nombreComercio}`,
        cuerpoWhatsApp: ({ nombre, nombreComercio, urlPortal }) =>
          `¡Hola ${nombre}! 🚗\n` +
          `Gracias por alquilar en *${nombreComercio}*.\n` +
          `¿Cómo estuvo todo? Solo un minuto 🙏\n` +
          `👉 ${urlPortal}`,
        botonCTA: '🚗 Calificar mi alquiler',
        saludo:   '¡Hasta el próximo viaje!',
      },
      en: {
        emoji: '🚗',
        asunto: (c) => `How was your rental at ${c}? 🚗`,
        intro:  (n) => `Thank you for choosing our vehicles, <strong>${n}</strong>. How did everything go?`,
        pregunta:  'How would you rate your rental experience?',
        subtitulo: 'Your experience on the road matters to us.',
        cuerpoPlano: ({ nombre, nombreComercio, urlPortal }) =>
          `Hi ${nombre},\n\nThank you for renting with ${nombreComercio}.\n` +
          `How was your experience? ${urlPortal}\n\nSee you next time!\n${nombreComercio}`,
        cuerpoWhatsApp: ({ nombre, nombreComercio, urlPortal }) =>
          `Hi ${nombre}! 🚗\n` +
          `Thank you for renting with *${nombreComercio}*.\n` +
          `How was your experience? Just one minute 🙏\n` +
          `👉 ${urlPortal}`,
        botonCTA: '🚗 Rate my rental',
        saludo:   'See you on the road again!',
      },
    },

    // ── Restaurante / Gastronomía ────────────────────────────────────────
    RESTO: {
      es: {
        emoji: '🍽️',
        asunto: (c) => `¿Cómo estuvo tu visita a ${c}? 🍽️`,
        intro:  (n) => `Gracias por visitarnos, <strong>${n}</strong>. Tu opinión mejora cada plato.`,
        pregunta:  '¿Cómo calificarías tu experiencia gastronómica?',
        subtitulo: 'Tu paladar es nuestra guía.',
        cuerpoPlano: ({ nombre, nombreComercio, urlPortal }) =>
          `Hola ${nombre},\n\nGracias por tu visita a ${nombreComercio}.\n` +
          `¿Cómo estuvo? ${urlPortal}\n\n¡Hasta la próxima mesa!\n${nombreComercio}`,
        cuerpoWhatsApp: ({ nombre, nombreComercio, urlPortal }) =>
          `¡Hola ${nombre}! 🍽️\n` +
          `Gracias por visitarnos en *${nombreComercio}*.\n` +
          `¿Cómo estuvo tu experiencia? Un minuto nada más 🙏\n` +
          `👉 ${urlPortal}`,
        botonCTA: '🍽️ Calificar mi visita',
        saludo:   '¡Hasta la próxima mesa!',
      },
      en: {
        emoji: '🍽️',
        asunto: (c) => `How was your visit to ${c}? 🍽️`,
        intro:  (n) => `Thank you for dining with us, <strong>${n}</strong>. Your feedback improves every dish.`,
        pregunta:  'How would you rate your dining experience?',
        subtitulo: 'Your taste is our guide.',
        cuerpoPlano: ({ nombre, nombreComercio, urlPortal }) =>
          `Hi ${nombre},\n\nThank you for visiting ${nombreComercio}.\n` +
          `How was your experience? ${urlPortal}\n\nSee you soon!\n${nombreComercio}`,
        cuerpoWhatsApp: ({ nombre, nombreComercio, urlPortal }) =>
          `Hi ${nombre}! 🍽️\n` +
          `Thank you for dining at *${nombreComercio}*.\n` +
          `How was your experience? Just one minute 🙏\n` +
          `👉 ${urlPortal}`,
        botonCTA: '🍽️ Rate my visit',
        saludo:   'See you at the table again!',
      },
    },
  };

  const tipo = TIPOS[tipoNegocio] || TIPOS['HOTEL'];   // fallback a HOTEL
  return tipo[idioma]              || tipo['es'];        // fallback a español
}

/**
 * Devuelve el color hexadecimal del header del email según el tipo de negocio.
 * @param {string} tipoNegocio
 * @returns {string}
 */
function colorPorTipo_(tipoNegocio) {
  const COLORES = {
    HOTEL:     '#4f46e5',   // indigo
    TOUR:      '#059669',   // emerald
    TRANSFER:  '#0284c7',   // sky
    ALQUILER:  '#7c3aed',   // violet
    RESTO:     '#ea580c',   // orange
  };
  return COLORES[tipoNegocio] || COLORES['HOTEL'];
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 7 — TEMPLATE HTML DEL EMAIL
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Construye el cuerpo HTML del correo con branding DM Global.
 *
 * @param {Object} payload
 * @param {Object} textos    Resultado de obtenerTextos_()
 * @returns {string}  HTML listo para GmailApp.sendEmail({ htmlBody })
 */
function construirHtmlEmail_(payload, textos) {
  const { nombre, nombreComercio, tipoNegocio, urlPortal } = payload;
  const headerColor = colorPorTipo_(tipoNegocio);

  return /* html */`
<!DOCTYPE html>
<html lang="${payload.idioma}">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <style>
    body    { margin:0; padding:0; background:#f3f4f6; font-family:Arial,sans-serif; }
    .wrap   { max-width:560px; margin:28px auto; background:#fff; border-radius:14px;
              overflow:hidden; box-shadow:0 2px 8px rgba(0,0,0,.09); }
    .header { background:${headerColor}; padding:22px 28px 20px; }
    .header .tag { margin:0; color:rgba(255,255,255,.6); font-size:11px;
                   letter-spacing:.08em; text-transform:uppercase; }
    .header .emoji { font-size:28px; line-height:1; margin:8px 0 4px; display:block; }
    .header h1 { margin:0; color:#fff; font-size:22px; font-weight:800; line-height:1.2; }
    .body   { padding:28px 32px; }
    .body p { color:#374151; font-size:15px; line-height:1.65; margin:0 0 14px; }
    .cta    { display:block; text-align:center; background:#f59e0b; color:#fff !important;
              font-weight:700; font-size:16px; padding:15px 24px; border-radius:10px;
              text-decoration:none; margin:22px 0; letter-spacing:.01em; }
    .cta:hover { background:#d97706; }
    .fallback { font-size:12px; color:#9ca3af; text-align:center; margin-top:0; }
    .footer { padding:14px 28px 20px; text-align:center; color:#9ca3af;
              font-size:11px; border-top:1px solid #f3f4f6; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="header">
      <p class="tag">Servicio de Feedback · DM Global</p>
      <span class="emoji">${textos.emoji}</span>
      <h1>${nombreComercio}</h1>
    </div>
    <div class="body">
      <p>${textos.intro(nombre)}</p>
      <p>${textos.pregunta}</p>
      <p>
        Tu opinión es muy valiosa y nos ayuda a seguir mejorando el servicio.
        Solo te tomará un minuto.
      </p>
      <a href="${urlPortal}" class="cta">${textos.botonCTA}</a>
      <p style="font-size:13px;color:#6b7280;">
        Si el botón no funciona, copiá este enlace en tu navegador:<br/>
        <a href="${urlPortal}" style="color:#4f46e5;">${urlPortal}</a>
      </p>
    </div>
    <div class="footer">
      ${textos.saludo} · ${nombreComercio}<br/>
      <span style="color:#d1d5db;">Este correo fue enviado automáticamente por el Servicio de Feedback de DM Global.</span>
    </div>
  </div>
</body>
</html>`.trim();
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 8 — UTILIDADES
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Actualiza la celda de estado de una fila en la hoja OPERACIONES.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @param {number} numFila   Número de fila 1-based en la hoja.
 * @param {string} nuevoEstado
 */
function actualizarEstado_(hoja, numFila, nuevoEstado) {
  hoja.getRange(numFila, COL.ESTADO).setValue(nuevoEstado);
}

/**
 * Logging unificado. En Apps Script, console.log() vuelca a Cloud Logging
 * y Logger.log() vuelca al log de ejecución clásico (Ver → Registros).
 * Se usan ambos para máxima visibilidad en todos los entornos.
 *
 * @param {'INFO'|'WARN'|'ERROR'} nivel
 * @param {string} mensaje
 */
function log_(nivel, mensaje) {
  const ts  = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'HH:mm:ss');
  const txt = `[${ts}] [${nivel}] ${mensaje}`;
  Logger.log(txt);
  console.log(txt);
}
