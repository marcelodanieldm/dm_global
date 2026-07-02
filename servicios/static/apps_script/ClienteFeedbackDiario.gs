/**
 * @fileoverview Script Diario del Cliente — Servicio de Feedback · DM Global
 *
 * Corre dentro de la planilla de CADA CLIENTE en modo autónomo.
 * No depende de ningún otro archivo .gs del proyecto.
 *
 * Trigger recomendado:
 *   Editor → Triggers → procesarEncuestasDiarias
 *   Basado en tiempo → Día → 08:00 – 09:00 hs
 *
 * Layout esperado — pestaña CONFIG (inyectada por OnboardingCliente.gs):
 *   B1: ID de Licencia    (ej: HOTEL-TERRAZAS-01)
 *   B2: Enlace Google Reviews
 *   B3: Correo del Gerente
 *
 * Layout esperado — pestaña OPERACIONES (el cliente carga las filas):
 *   A: Nombre Turista
 *   B: Email
 *   C: Idioma            → 'es' | 'en'
 *   D: Fecha de Registro → Date  (cuándo se cargó la fila)
 *   E: Estado            → 'PENDIENTE' | 'ENVIADO' | 'ERROR'
 *
 * Flujo de ejecución:
 *  procesarEncuestasDiarias()
 *  ├─ leerConfiguracion_()         leer CONFIG
 *  ├─ validarLicencia_()           GET al CRM → corte si 403/401
 *  └─ procesarOperaciones_()
 *      └─ por cada fila elegible:
 *          ├─ enviarEncuesta_()    GmailApp.sendEmail con HTML
 *          └─ actualizarEstado_()  celda E → ENVIADO o ERROR
 */

'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 1 — CONFIGURACIÓN (único lugar que el cliente nunca toca)
// ─────────────────────────────────────────────────────────────────────────────

/** URL del CRM DM Global. Actualizar con el dominio real en producción. */
const URL_VALIDACION = 'https://tucrm.com/api/v1/licencias/validar/';

/** Pestaña y celdas de configuración. */
const CFG_HOJA    = 'CONFIG';
const CFG_LICENCIA = 'B1';
const CFG_REVIEWS  = 'B2';
const CFG_EMAIL    = 'B3';

/** Pestaña de operaciones diarias. */
const OPS_HOJA = 'OPERACIONES';

/** Índices de columna en OPERACIONES (1-based para getRange). */
const COL = Object.freeze({
  NOMBRE:   1,   // A — Nombre Turista
  EMAIL:    2,   // B — Email de contacto
  IDIOMA:   3,   // C — 'es' | 'en'
  FECHA:    4,   // D — Fecha de Registro (Date)
  ESTADO:   5,   // E — PENDIENTE | ENVIADO | ERROR
});

const ESTADOS = Object.freeze({
  PENDIENTE: 'PENDIENTE',
  ENVIADO:   'ENVIADO',
  ERROR:     'ERROR',
});

/** Horas mínimas desde el registro para habilitar el envío. */
const HORAS_ESPERA        = 24;
const MS_ESPERA           = HORAS_ESPERA * 60 * 60 * 1000;

/** Pausa entre envíos de email para no saturar la cuota de GmailApp (ms). */
const DELAY_ENTRE_ENVIOS  = 1000;

const MARCA               = 'Servicio de Feedback · DM Global';

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 2 — PUNTO DE ENTRADA (trigger diario)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Orquesta el proceso diario de envío de encuestas.
 * Configurar como trigger de tiempo: diariamente a las 08:00–09:00 hs.
 */
function procesarEncuestasDiarias() {
  const inicio = Date.now();
  log_('INFO', '═══════════════════════════════════');
  log_('INFO', 'Inicio procesarEncuestasDiarias');

  // ── Paso 1: leer configuración de la planilla ─────────────────────
  let config;
  try {
    config = leerConfiguracion_();
  } catch (err) {
    log_('ERROR', `No se pudo leer CONFIG: ${err.message}`);
    return;   // sin config no hay nada que hacer
  }

  // ── Paso 2: validar licencia con el CRM ───────────────────────────
  let licenciaOk;
  try {
    licenciaOk = validarLicencia_(config.idLicencia);
  } catch (err) {
    // Error de red o inesperado — detener por precaución
    log_('ERROR', `Error de red al validar licencia: ${err.message}`);
    log_('WARN', 'Encuestas DETENIDAS por fallo en la validación.');
    return;
  }

  if (!licenciaOk.autorizado) {
    log_('WARN', `Licencia NO autorizada | motivo: "${licenciaOk.error}"`);
    log_('WARN', 'Encuestas DETENIDAS. Contactá a DM Global para regularizar.');
    return;   // ← corte por falta de pago / licencia suspendida
  }

  log_('INFO', `Licencia válida | id=${config.idLicencia}`);

  // ── Paso 3: procesar filas pendientes de OPERACIONES ─────────────
  try {
    procesarOperaciones_(config);
  } catch (err) {
    log_('ERROR', `Error procesando OPERACIONES: ${err.message}`);
  }

  const seg = ((Date.now() - inicio) / 1000).toFixed(1);
  log_('INFO', `Fin procesarEncuestasDiarias | tiempo=${seg}s`);
  log_('INFO', '═══════════════════════════════════');
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 3 — LECTURA DE CONFIGURACIÓN
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Lee la pestaña CONFIG y devuelve las credenciales del comercio.
 *
 * @returns {{ idLicencia: string, reviewLink: string, emailGerente: string, nombreNegocio: string }}
 * @throws {Error}  Si la pestaña no existe o el ID de licencia está vacío.
 */
function leerConfiguracion_() {
  const ss          = SpreadsheetApp.getActiveSpreadsheet();
  const hojaConfig  = ss.getSheetByName(CFG_HOJA);

  if (!hojaConfig) {
    throw new Error(`Pestaña "${CFG_HOJA}" no encontrada. Verificá la planilla.`);
  }

  const idLicencia  = String(hojaConfig.getRange(CFG_LICENCIA).getValue() || '').trim();
  const reviewLink  = String(hojaConfig.getRange(CFG_REVIEWS).getValue()  || '').trim();
  const emailGerente = String(hojaConfig.getRange(CFG_EMAIL).getValue()   || '').trim();

  if (!idLicencia) {
    throw new Error(`Celda ${CFG_LICENCIA} de CONFIG vacía. Revisá la configuración.`);
  }

  // Derivar el nombre del negocio desde el nombre de la planilla
  // (formato: "Servicio de feedback - Nombre del Negocio")
  const nombreRaw     = ss.getName();
  const prefijo       = 'Servicio de feedback - ';
  const nombreNegocio = nombreRaw.startsWith(prefijo)
    ? nombreRaw.slice(prefijo.length)
    : nombreRaw;

  return { idLicencia, reviewLink, emailGerente, nombreNegocio };
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 4 — VALIDACIÓN DE LICENCIA CONTRA EL CRM
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Hace una petición GET al CRM de DM Global para verificar que la licencia
 * está activa y dentro del período de vigencia.
 *
 * El servidor puede responder:
 *   HTTP 200 → { "autorizado": true }
 *   HTTP 403 → { "autorizado": false, "error": "Suscripcion vencida el..." }
 *   HTTP 401 → { "autorizado": false, "error": "Licencia inexistente." }
 *
 * @param {string} idLicencia  Valor de CONFIG!B1 (ej: 'HOTEL-TERRAZAS-01').
 * @returns {{ autorizado: boolean, error?: string }}
 * @throws {Error}  Si falla la conexión de red (UrlFetchApp lanza excepción).
 */
function validarLicencia_(idLicencia) {
  const url = `${URL_VALIDACION}?id_comercio=${encodeURIComponent(idLicencia)}`;

  log_('INFO', `Validando licencia | url=${url}`);

  const respuesta = UrlFetchApp.fetch(url, {
    method:             'GET',
    muteHttpExceptions: true,   // evita que 403/401 lancen excepción
    headers:            { Accept: 'application/json' },
    followRedirects:    true,
  });

  const httpStatus = respuesta.getResponseCode();
  log_('INFO', `Respuesta del CRM | HTTP ${httpStatus}`);

  // Parsear cuerpo JSON
  let cuerpo;
  try {
    cuerpo = JSON.parse(respuesta.getContentText());
  } catch (_) {
    // El servidor no devolvió JSON válido
    return {
      autorizado: false,
      error: `Respuesta inesperada del servidor (HTTP ${httpStatus}).`,
    };
  }

  if (httpStatus === 200 && cuerpo.autorizado === true) {
    return { autorizado: true };
  }

  return {
    autorizado: false,
    error: cuerpo.error || `HTTP ${httpStatus} sin detalle.`,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 5 — PROCESAMIENTO DE OPERACIONES
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Recorre la pestaña OPERACIONES, filtra las filas elegibles y despacha emails.
 * @param {{ idLicencia, reviewLink, emailGerente, nombreNegocio }} config
 */
function procesarOperaciones_(config) {
  const ss       = SpreadsheetApp.getActiveSpreadsheet();
  const hoja     = ss.getSheetByName(OPS_HOJA);

  if (!hoja) {
    log_('ERROR', `Pestaña "${OPS_HOJA}" no encontrada.`);
    return;
  }

  const filasPendientes = leerFilasPendientes_(hoja);

  if (filasPendientes.length === 0) {
    log_('INFO', 'Sin filas pendientes para procesar hoy.');
    return;
  }

  log_('INFO', `Filas elegibles: ${filasPendientes.length}`);
  let enviados = 0, errores = 0;

  filasPendientes.forEach(({ numFila, datos }) => {
    const exito = procesarFila_(hoja, numFila, datos, config);
    exito ? enviados++ : errores++;
    Utilities.sleep(DELAY_ENTRE_ENVIOS);   // throttle anti-cuota
  });

  log_('INFO', `Resultado | enviados=${enviados} | errores=${errores}`);
}

/**
 * Lee todas las filas de OPERACIONES y retorna las elegibles:
 *   • ESTADO === 'PENDIENTE'
 *   • Fecha de registro >= HORAS_ESPERA horas atrás
 *   • Email no vacío
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @returns {Array<{ numFila: number, datos: Array }>}
 */
function leerFilasPendientes_(hoja) {
  const ultimaFila = hoja.getLastRow();
  if (ultimaFila < 2) return [];   // solo encabezado o vacía

  const valores    = hoja
    .getRange(2, 1, ultimaFila - 1, Object.keys(COL).length)
    .getValues();

  const ahora      = Date.now();
  const pendientes = [];

  valores.forEach((fila, idx) => {
    const numFila       = idx + 2;   // fila real en la hoja (1-based, +1 por encabezado)
    const estado        = String(fila[COL.ESTADO - 1] || '').trim().toUpperCase();
    const email         = String(fila[COL.EMAIL  - 1] || '').trim();
    const fechaRegistro = fila[COL.FECHA - 1];

    // Filtro 1: estado correcto
    if (estado !== ESTADOS.PENDIENTE) return;

    // Filtro 2: email presente
    if (!email || !email.includes('@')) {
      log_('WARN', `Fila ${numFila}: email inválido ("${email}"). Se omite.`);
      return;
    }

    // Filtro 3: fecha de registro válida
    if (!(fechaRegistro instanceof Date) || isNaN(fechaRegistro.getTime())) {
      log_('WARN', `Fila ${numFila}: Fecha de Registro inválida. Se omite.`);
      return;
    }

    // Filtro 4: han pasado las HORAS_ESPERA desde el registro
    const transcurrido = ahora - fechaRegistro.getTime();
    if (transcurrido < MS_ESPERA) return;

    pendientes.push({ numFila, datos: fila });
  });

  return pendientes;
}

/**
 * Procesa una sola fila: envía el email y actualiza el estado.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @param {number} numFila
 * @param {Array}  datos
 * @param {Object} config
 * @returns {boolean}  true si el envío fue exitoso.
 */
function procesarFila_(hoja, numFila, datos, config) {
  const nombre = String(datos[COL.NOMBRE - 1] || '').trim() || 'Estimado/a cliente';
  const email  = String(datos[COL.EMAIL  - 1] || '').trim();
  const idioma = String(datos[COL.IDIOMA - 1] || 'es').trim().toLowerCase();
  const IDIOMAS_VALIDOS = ['es', 'en', 'pt', 'fr', 'de'];
  const lang   = IDIOMAS_VALIDOS.includes(idioma) ? idioma : 'es';

  try {
    enviarEncuesta_({ nombre, email, lang }, config);
    actualizarEstado_(hoja, numFila, ESTADOS.ENVIADO);
    log_('INFO', `Fila ${numFila}: ENVIADO → ${email} | idioma=${lang}`);
    return true;
  } catch (err) {
    actualizarEstado_(hoja, numFila, ESTADOS.ERROR);
    log_('ERROR', `Fila ${numFila}: ERROR | ${err.message}`);
    return false;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 6 — ENVÍO DE ENCUESTA POR EMAIL
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Construye y envía el email de solicitud de reseña al turista.
 *
 * @param {{ nombre: string, email: string, lang: string }} turista
 * @param {{ reviewLink: string, nombreNegocio: string, idLicencia: string }} config
 */
function enviarEncuesta_(turista, config) {
  const textos = obtenerTextos_(turista.lang, _tipoDeId_(config.idLicencia));

  GmailApp.sendEmail(
    turista.email,
    textos.asunto(config.nombreNegocio),
    textos.cuerpoPlano(turista.nombre, config.nombreNegocio, config.reviewLink),
    {
      name:     `${config.nombreNegocio} · ${MARCA}`,
      htmlBody: construirHtmlEncuesta_(turista, config, textos),
      noReply:  false,
    }
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 7 — TEMPLATE HTML DEL EMAIL
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Genera el HTML completo del email de solicitud de reseña.
 *
 * @param {{ nombre: string, lang: string }} turista
 * @param {{ nombreNegocio: string, reviewLink: string, idLicencia: string }} config
 * @param {Object} textos  Resultado de obtenerTextos_()
 * @returns {string}
 */
function construirHtmlEncuesta_(turista, config, textos) {
  const { nombre, lang } = turista;
  const { nombreNegocio, reviewLink } = config;
  const color = _colorDeTipo_(_tipoDeId_(config.idLicencia));

  return /* html */`
<!DOCTYPE html>
<html lang="${lang}">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1.0"/>
  <style>
    body      { margin:0; padding:0; background:#f3f4f6; font-family:Arial,Helvetica,sans-serif; }
    .wrap     { max-width:560px; margin:24px auto; }
    .header   { background:${color}; padding:28px 28px 22px; border-radius:14px 14px 0 0;
                text-align:center; }
    .header small { display:block; color:rgba(255,255,255,.65); font-size:10px;
                    letter-spacing:.1em; text-transform:uppercase; margin-bottom:8px; }
    .header .emoji { font-size:32px; display:block; margin-bottom:6px; }
    .header h1 { margin:0; color:#fff; font-size:22px; font-weight:800; line-height:1.2; }
    .body     { background:#fff; padding:28px 32px; }
    .body p   { color:#374151; font-size:15px; line-height:1.7; margin:0 0 14px; }
    .stars    { text-align:center; font-size:28px; margin:4px 0 20px; letter-spacing:4px; }
    .cta-wrap { text-align:center; margin:24px 0; }
    .cta      { display:inline-block; background:#f59e0b; color:#fff !important;
                font-size:15px; font-weight:700; padding:14px 32px; border-radius:10px;
                text-decoration:none; box-shadow:0 4px 12px rgba(245,158,11,.3); }
    .divider  { border:none; border-top:1px solid #f3f4f6; margin:20px 0; }
    .link-txt { font-size:12px; color:#9ca3af; text-align:center; }
    .link-txt a { color:#6b7280; }
    .footer   { background:#f9fafb; border-radius:0 0 14px 14px; padding:16px 28px;
                text-align:center; border-top:1px solid #e5e7eb; }
    .footer p { color:#9ca3af; font-size:11px; margin:0; line-height:1.6; }
  </style>
</head>
<body>
<div class="wrap">

  <div class="header">
    <small>${MARCA}</small>
    <span class="emoji">${textos.emoji}</span>
    <h1>${nombreNegocio}</h1>
  </div>

  <div class="body">
    <p>${textos.saludo(nombre)}</p>
    <p>${textos.cuerpo}</p>
    <div class="stars">⭐⭐⭐⭐⭐</div>
    <div class="cta-wrap">
      <a href="${reviewLink}" class="cta">${textos.boton}</a>
    </div>
    <hr class="divider"/>
    <p class="link-txt">
      ${textos.linkAlt}<br/>
      <a href="${reviewLink}">${reviewLink}</a>
    </p>
  </div>

  <div class="footer">
    <p>
      ${textos.pie}<br/>
      ${nombreNegocio} · <a href="mailto:soporte@dmglobal.com" style="color:#9ca3af;">soporte@dmglobal.com</a>
    </p>
  </div>

</div>
</body>
</html>`.trim();
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 8 — CONTENIDO POR TIPO DE NEGOCIO E IDIOMA (i18n)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Devuelve el mapa de textos para la combinación idioma + tipo de negocio.
 *
 * El tipo se deriva del prefijo del id_licencia:
 *   'HOTEL-TERRAZAS-01' → 'HOTEL'
 *   'TOUR-AVENTURAS-02' → 'TOUR'
 *   'TRANSFER-NORTE-03' → 'TRANSFER'
 *   'ALQUILER-SUR-04'   → 'ALQUILER'
 *   'RESTO-PLAYA-05'    → 'RESTO'
 *
 * @param {'es'|'en'|'pt'|'fr'|'de'} lang
 * @param {'HOTEL'|'TOUR'|'TRANSFER'|'ALQUILER'|'RESTO'} tipo
 * @returns {Object}
 */
function obtenerTextos_(lang, tipo) {
  const MAPA = {

    // Alojamiento / Hotel
    HOTEL: {
      es: { emoji:'🏨', asunto:(c)=>`¿Cómo estuvo tu estadía en ${c}? 🏨`, saludo:(n)=>`Hola <strong>${n}</strong>,`, cuerpo:'Gracias por hospedarte con nosotros. Tu experiencia como huésped es lo más importante. ¿Podés dejarnos una reseña? Solo un minuto.', boton:'🏨 Dejar mi reseña en Google', linkAlt:'Si el botón no funciona, copiá este enlace:', pie:'¡Esperamos verte pronto!', cuerpoPlano:(n,c,u)=>`Hola ${n},\nGracias por hospedarte en ${c}.\nReseña: ${u}\nHasta pronto!\n${c}` },
      en: { emoji:'🏨', asunto:(c)=>`How was your stay at ${c}? 🏨`, saludo:(n)=>`Hi <strong>${n}</strong>,`, cuerpo:'Thank you for staying with us. Your guest experience is our top priority. Could you leave a quick review? It only takes a minute.', boton:'🏨 Leave my Google Review', linkAlt:"If the button doesn't work, copy this link:", pie:'Hope to see you again soon!', cuerpoPlano:(n,c,u)=>`Hi ${n},\nThank you for staying at ${c}.\nReview: ${u}\nSee you soon!\n${c}` },
      pt: { emoji:'🏨', asunto:(c)=>`Como foi sua estadia em ${c}? 🏨`, saludo:(n)=>`Olá <strong>${n}</strong>,`, cuerpo:'Obrigado por se hospedar conosco. Sua experiência como hóspede é o que mais importa. Poderia nos deixar uma avaliação? Leva só um minuto.', boton:'🏨 Deixar minha avaliação no Google', linkAlt:'Se o botão não funcionar, copie este link:', pie:'Esperamos vê-lo em breve!', cuerpoPlano:(n,c,u)=>`Olá ${n},\nObrigado por se hospedar em ${c}.\nAvaliação: ${u}\nAté logo!\n${c}` },
      fr: { emoji:'🏨', asunto:(c)=>`Comment s'est passé votre séjour à ${c} ? 🏨`, saludo:(n)=>`Bonjour <strong>${n}</strong>,`, cuerpo:"Merci d'avoir séjourné chez nous. Votre expérience en tant qu'hôte est notre priorité absolue. Pourriez-vous laisser un avis ? Une minute suffit.", boton:"🏨 Laisser mon avis sur Google", linkAlt:'Si le bouton ne fonctionne pas, copiez ce lien :', pie:'Nous espérons vous revoir bientôt !', cuerpoPlano:(n,c,u)=>`Bonjour ${n},\nMerci pour votre séjour à ${c}.\nAvis : ${u}\nÀ bientôt !\n${c}` },
      de: { emoji:'🏨', asunto:(c)=>`Wie war Ihr Aufenthalt bei ${c}? 🏨`, saludo:(n)=>`Hallo <strong>${n}</strong>,`, cuerpo:'Vielen Dank für Ihren Aufenthalt bei uns. Ihre Erfahrung als Gast liegt uns am Herzen. Könnten Sie uns eine Bewertung hinterlassen? Nur eine Minute.', boton:'🏨 Meine Google-Bewertung hinterlassen', linkAlt:'Wenn der Button nicht funktioniert, kopieren Sie diesen Link:', pie:'Wir hoffen, Sie bald wiederzusehen!', cuerpoPlano:(n,c,u)=>`Hallo ${n},\nVielen Dank für Ihren Aufenthalt bei ${c}.\nBewertung: ${u}\nBis bald!\n${c}` },
    },

    // Excursiones / Tour Operador
    TOUR: {
      es: { emoji:'🌿', asunto:(c)=>`¿Cómo fue tu excursión con ${c}? 🌿`, saludo:(n)=>`¡Hola <strong>${n}</strong>!`, cuerpo:'Esperamos que tu aventura haya sido increíble. Tu opinión nos ayuda a seguir ofreciendo experiencias únicas. ¿Podés contarnos? Solo un minuto.', boton:'🌿 Calificar mi excursión', linkAlt:'Si el botón no funciona, copiá este enlace:', pie:'¡Hasta la próxima aventura!', cuerpoPlano:(n,c,u)=>`Hola ${n},\nExcursión con ${c}: ${u}\nHasta pronto!\n${c}` },
      en: { emoji:'🌿', asunto:(c)=>`How was your tour with ${c}? 🌿`, saludo:(n)=>`Hi <strong>${n}</strong>!`, cuerpo:'We hope your adventure was amazing! Your feedback helps us keep delivering unique experiences. Could you share how it went? Just one minute.', boton:'🌿 Rate my tour', linkAlt:"If the button doesn't work, copy this link:", pie:'Until the next adventure!', cuerpoPlano:(n,c,u)=>`Hi ${n},\nTour with ${c}: ${u}\nUntil next time!\n${c}` },
      pt: { emoji:'🌿', asunto:(c)=>`Como foi seu passeio com ${c}? 🌿`, saludo:(n)=>`Olá <strong>${n}</strong>!`, cuerpo:'Esperamos que sua aventura tenha sido incrível! Seu feedback nos ajuda a oferecer experiências únicas. Pode nos contar como foi? Só um minutinho.', boton:'🌿 Avaliar meu passeio', linkAlt:'Se o botão não funcionar, copie este link:', pie:'Até a próxima aventura!', cuerpoPlano:(n,c,u)=>`Olá ${n},\nPasseio com ${c}: ${u}\nAté logo!\n${c}` },
      fr: { emoji:'🌿', asunto:(c)=>`Comment s'est passée votre excursion avec ${c} ? 🌿`, saludo:(n)=>`Bonjour <strong>${n}</strong> !`, cuerpo:'Nous espérons que votre aventure a été incroyable ! Vos retours nous aident à proposer des expériences meilleures. Pourriez-vous partager votre avis ? Une minute suffit.', boton:'🌿 Évaluer mon excursion', linkAlt:'Si le bouton ne fonctionne pas, copiez ce lien :', pie:'À la prochaine aventure !', cuerpoPlano:(n,c,u)=>`Bonjour ${n},\nExcursion avec ${c} : ${u}\nÀ bientôt !\n${c}` },
      de: { emoji:'🌿', asunto:(c)=>`Wie war Ihr Ausflug mit ${c}? 🌿`, saludo:(n)=>`Hallo <strong>${n}</strong>!`, cuerpo:'Wir hoffen, dass Ihr Abenteuer unvergesslich war! Ihr Feedback hilft uns, einzigartige Erlebnisse zu bieten. Könnten Sie uns Ihre Meinung mitteilen? Nur eine Minute.', boton:'🌿 Meinen Ausflug bewerten', linkAlt:'Wenn der Button nicht funktioniert, kopieren Sie diesen Link:', pie:'Bis zum nächsten Abenteuer!', cuerpoPlano:(n,c,u)=>`Hallo ${n},\nAusflug mit ${c}: ${u}\nBis bald!\n${c}` },
    },

    // Traslados / Transfer
    TRANSFER: {
      es: { emoji:'🚐', asunto:(c)=>`¿Cómo fue tu traslado con ${c}? 🚐`, saludo:(n)=>`Hola <strong>${n}</strong>,`, cuerpo:'Tu tiempo es valioso y queremos que cada viaje sea perfecto. ¿Llegaste bien? Contanos en Google Maps, solo 30 segundos.', boton:'🚐 Calificar mi traslado', linkAlt:'Si el botón no funciona, copiá este enlace:', pie:'¡Buen viaje siempre!', cuerpoPlano:(n,c,u)=>`Hola ${n},\nTraslado con ${c}: ${u}\nBuen viaje!\n${c}` },
      en: { emoji:'🚐', asunto:(c)=>`How was your transfer with ${c}? 🚐`, saludo:(n)=>`Hi <strong>${n}</strong>,`, cuerpo:'Your time is precious and we want every journey to be perfect. Did everything go smoothly? Tell us on Google Maps — just 30 seconds.', boton:'🚐 Rate my transfer', linkAlt:"If the button doesn't work, copy this link:", pie:'Safe travels, always!', cuerpoPlano:(n,c,u)=>`Hi ${n},\nTransfer with ${c}: ${u}\nSafe travels!\n${c}` },
      pt: { emoji:'🚐', asunto:(c)=>`Como foi seu traslado com ${c}? 🚐`, saludo:(n)=>`Olá <strong>${n}</strong>,`, cuerpo:'Seu tempo é valioso e queremos que cada viagem seja perfeita. Chegou bem? Nos conte no Google Maps, leva só 30 segundos.', boton:'🚐 Avaliar meu traslado', linkAlt:'Se o botão não funcionar, copie este link:', pie:'Boa viagem sempre!', cuerpoPlano:(n,c,u)=>`Olá ${n},\nTraslado com ${c}: ${u}\nBoa viagem!\n${c}` },
      fr: { emoji:'🚐', asunto:(c)=>`Comment s'est passé votre transfert avec ${c} ? 🚐`, saludo:(n)=>`Bonjour <strong>${n}</strong>,`, cuerpo:"Votre temps est précieux et nous voulons que chaque trajet soit parfait. Tout s'est bien passé ? Dites-nous sur Google Maps, 30 secondes suffisent.", boton:'🚐 Évaluer mon transfert', linkAlt:'Si le bouton ne fonctionne pas, copiez ce lien :', pie:'Bon voyage !', cuerpoPlano:(n,c,u)=>`Bonjour ${n},\nTransfert avec ${c} : ${u}\nBon voyage !\n${c}` },
      de: { emoji:'🚐', asunto:(c)=>`Wie war Ihr Transfer mit ${c}? 🚐`, saludo:(n)=>`Hallo <strong>${n}</strong>,`, cuerpo:'Ihre Zeit ist wertvoll und wir möchten, dass jede Fahrt perfekt ist. Alles gut angekommen? Sagen Sie es uns auf Google Maps — nur 30 Sekunden.', boton:'🚐 Meinen Transfer bewerten', linkAlt:'Wenn der Button nicht funktioniert, kopieren Sie diesen Link:', pie:'Immer gute Reise!', cuerpoPlano:(n,c,u)=>`Hallo ${n},\nTransfer mit ${c}: ${u}\nGute Reise!\n${c}` },
    },

    // Alquiler de Vehículos
    ALQUILER: {
      es: { emoji:'🚗', asunto:(c)=>`¿Cómo estuvo tu alquiler en ${c}? 🚗`, saludo:(n)=>`Hola <strong>${n}</strong>,`, cuerpo:'Gracias por elegir nuestros vehículos. Tu experiencia al volante nos importa para seguir mejorando. ¿Cómo anduvo todo? Solo un minuto.', boton:'🚗 Calificar mi alquiler', linkAlt:'Si el botón no funciona, copiá este enlace:', pie:'¡Hasta el próximo viaje!', cuerpoPlano:(n,c,u)=>`Hola ${n},\nAlquiler en ${c}: ${u}\nHasta pronto!\n${c}` },
      en: { emoji:'🚗', asunto:(c)=>`How was your rental at ${c}? 🚗`, saludo:(n)=>`Hi <strong>${n}</strong>,`, cuerpo:'Thank you for choosing our vehicles. Your experience on the road matters to us. How did everything go? Just one minute of your time.', boton:'🚗 Rate my rental', linkAlt:"If the button doesn't work, copy this link:", pie:'See you on the road again!', cuerpoPlano:(n,c,u)=>`Hi ${n},\nRental at ${c}: ${u}\nSee you next time!\n${c}` },
      pt: { emoji:'🚗', asunto:(c)=>`Como foi sua locação em ${c}? 🚗`, saludo:(n)=>`Olá <strong>${n}</strong>,`, cuerpo:'Obrigado por escolher nossos veículos. Sua experiência ao volante é muito importante. Como foi tudo? Só um minutinho.', boton:'🚗 Avaliar minha locação', linkAlt:'Se o botão não funcionar, copie este link:', pie:'Até a próxima viagem!', cuerpoPlano:(n,c,u)=>`Olá ${n},\nLocação em ${c}: ${u}\nAté logo!\n${c}` },
      fr: { emoji:'🚗', asunto:(c)=>`Comment s'est passée votre location chez ${c} ? 🚗`, saludo:(n)=>`Bonjour <strong>${n}</strong>,`, cuerpo:"Merci d'avoir choisi nos véhicules. Votre expérience de conduite nous tient à coeur. Comment s'est passé tout ? Juste une minute.", boton:'🚗 Évaluer ma location', linkAlt:'Si le bouton ne fonctionne pas, copiez ce lien :', pie:'À la prochaine !', cuerpoPlano:(n,c,u)=>`Bonjour ${n},\nLocation chez ${c} : ${u}\nÀ bientôt !\n${c}` },
      de: { emoji:'🚗', asunto:(c)=>`Wie war Ihre Fahrzeuganmietung bei ${c}? 🚗`, saludo:(n)=>`Hallo <strong>${n}</strong>,`, cuerpo:'Danke, dass Sie unsere Fahrzeuge gewählt haben. Ihre Fahrerfahrung liegt uns am Herzen. Wie war alles? Nur eine Minute.', boton:'🚗 Meine Anmietung bewerten', linkAlt:'Wenn der Button nicht funktioniert, kopieren Sie diesen Link:', pie:'Bis zur nächsten Fahrt!', cuerpoPlano:(n,c,u)=>`Hallo ${n},\nAnmietung bei ${c}: ${u}\nBis bald!\n${c}` },
    },

    // Restaurante / Gastronomía
    RESTO: {
      es: { emoji:'🍽️', asunto:(c)=>`¿Cómo estuvo tu visita a ${c}? 🍽️`, saludo:(n)=>`Hola <strong>${n}</strong>,`, cuerpo:'Gracias por visitarnos. Tu opinión mejora cada plato y cada servicio. ¿Nos contás tu experiencia en Google? Solo un minuto.', boton:'🍽️ Dejar mi reseña', linkAlt:'Si el botón no funciona, copiá este enlace:', pie:'¡Hasta la próxima mesa!', cuerpoPlano:(n,c,u)=>`Hola ${n},\nVisita a ${c}: ${u}\nHasta pronto!\n${c}` },
      en: { emoji:'🍽️', asunto:(c)=>`How was your visit to ${c}? 🍽️`, saludo:(n)=>`Hi <strong>${n}</strong>,`, cuerpo:"Thank you for visiting us. Your feedback makes every dish and every service better. Could you share your experience on Google? Just one minute.", boton:'🍽️ Leave my review', linkAlt:"If the button doesn't work, copy this link:", pie:'See you at the table again!', cuerpoPlano:(n,c,u)=>`Hi ${n},\nVisit to ${c}: ${u}\nSee you soon!\n${c}` },
      pt: { emoji:'🍽️', asunto:(c)=>`Como foi sua visita a ${c}? 🍽️`, saludo:(n)=>`Olá <strong>${n}</strong>,`, cuerpo:'Obrigado pela sua visita. Sua opinião melhora cada prato e cada atendimento. Pode nos contar no Google? Só um minutinho.', boton:'🍽️ Deixar minha avaliação', linkAlt:'Se o botão não funcionar, copie este link:', pie:'Até a próxima!', cuerpoPlano:(n,c,u)=>`Olá ${n},\nVisita a ${c}: ${u}\nAté logo!\n${c}` },
      fr: { emoji:'🍽️', asunto:(c)=>`Comment s'est passée votre visite chez ${c} ? 🍽️`, saludo:(n)=>`Bonjour <strong>${n}</strong>,`, cuerpo:'Merci pour votre visite. Votre avis améliore chaque plat et chaque service. Pourriez-vous partager votre expérience sur Google ? Juste une minute.', boton:'🍽️ Laisser mon avis', linkAlt:'Si le bouton ne fonctionne pas, copiez ce lien :', pie:'À bientôt !', cuerpoPlano:(n,c,u)=>`Bonjour ${n},\nVisite chez ${c} : ${u}\nÀ bientôt !\n${c}` },
      de: { emoji:'🍽️', asunto:(c)=>`Wie war Ihr Besuch bei ${c}? 🍽️`, saludo:(n)=>`Hallo <strong>${n}</strong>,`, cuerpo:'Danke für Ihren Besuch. Ihr Feedback verbessert jedes Gericht und jeden Service. Könnten Sie Ihre Erfahrung auf Google teilen? Nur eine Minute.', boton:'🍽️ Meine Bewertung hinterlassen', linkAlt:'Wenn der Button nicht funktioniert, kopieren Sie diesen Link:', pie:'Bis zum nächsten Mal!', cuerpoPlano:(n,c,u)=>`Hallo ${n},\nBesuch bei ${c}: ${u}\nBis bald!\n${c}` },
    },

  };

  const bloqueTipo = MAPA[tipo] || MAPA['HOTEL'];   // fallback a HOTEL
  return bloqueTipo[lang]        || bloqueTipo['es']; // fallback a español
}

/**
 * Extrae el tipo de negocio del prefijo del id_licencia.
 * 'HOTEL-TERRAZAS-01' → 'HOTEL'
 * 'TOUR-AVENTURAS-05' → 'TOUR'
 *
 * @param {string} idLicencia
 * @returns {'HOTEL'|'TOUR'|'TRANSFER'|'ALQUILER'|'RESTO'}
 */
function _tipoDeId_(idLicencia) {
  const upper = String(idLicencia).toUpperCase();
  const tipos = ['TRANSFER', 'ALQUILER', 'HOTEL', 'TOUR', 'RESTO'];
  // TRANSFER antes de HOTEL para evitar falsos positivos (sin prefijo igual)
  return tipos.find((t) => upper.startsWith(t)) || 'HOTEL';
}

/**
 * Color del header del email según el tipo de negocio.
 * @param {string} tipo
 * @returns {string}  Valor CSS de color.
 */
function _colorDeTipo_(tipo) {
  const COLORES = {
    HOTEL:    '#4f46e5',
    TOUR:     '#059669',
    TRANSFER: '#0284c7',
    ALQUILER: '#7c3aed',
    RESTO:    '#ea580c',
  };
  return COLORES[tipo] || COLORES['HOTEL'];
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 9 — UTILIDADES
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Actualiza la celda de estado de una fila en OPERACIONES.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @param {number} numFila  Número de fila 1-based.
 * @param {string} nuevoEstado  'ENVIADO' | 'ERROR'
 */
function actualizarEstado_(hoja, numFila, nuevoEstado) {
  hoja.getRange(numFila, COL.ESTADO).setValue(nuevoEstado);
  SpreadsheetApp.flush();   // escritura inmediata
}

/**
 * Logging unificado: escribe en Logger (log clásico) y console (Cloud Logging).
 * @param {'INFO'|'WARN'|'ERROR'} nivel
 * @param {string} mensaje
 */
function log_(nivel, mensaje) {
  const ts  = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'HH:mm:ss');
  const txt = `[${ts}] [${nivel}] ${mensaje}`;
  Logger.log(txt);
  console.log(txt);
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 10 — PRUEBA MANUAL (ejecutar desde el editor para verificar)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Ejecutá esta función desde el editor para probar el flujo completo
 * sin necesidad de esperar al trigger diario.
 * Requiere que CONFIG esté correctamente configurado en la planilla activa.
 */
function testManual() {
  Logger.log('=== TEST MANUAL ClienteFeedbackDiario.gs ===');
  procesarEncuestasDiarias();
  Logger.log('=== FIN TEST MANUAL ===');
}
