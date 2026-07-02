/**
 * @fileoverview Onboarding Automático de Clientes — Servicio de Feedback · DM Global
 *
 * Se ejecuta como trigger "Al enviar el formulario" (onFormSubmit) adjunto
 * al Google Form de alta de nuevos clientes.
 *
 * Árbol de funciones:
 *  onFormSubmit(e)                ← trigger entry point
 *  ├─ extraerDatosFormulario_(e) ← parsea y valida el evento del Form
 *  ├─ aprovisionarPlanilla_(datos)
 *  │   ├─ copiarPlantillaMaestra_(datos)  ← DriveApp
 *  │   └─ inyectarConfig_(sheetId, datos) ← SpreadsheetApp
 *  ├─ enviarBienvenida_(datos, url)
 *  │   └─ construirHtmlBienvenida_(datos, url) ← template HTML
 *  └─ notificarError_(error, contexto)    ← alert al admin si algo falla
 *
 * ─────────────────────────────────────────────────────────────────────
 * CONFIGURACIÓN INICIAL (ejecutar UNA sola vez desde el editor GAS)
 * ─────────────────────────────────────────────────────────────────────
 *  1. Abrí el editor → ejecutá configurarPropiedades()
 *  2. Completá los valores al ser solicitados por el InputBox.
 *  3. Verificá que las propiedades se guardaron: ejecutá mostrarPropiedades()
 *
 *  O pegá los valores directamente en configurarPropiedades() y ejecutala.
 * ─────────────────────────────────────────────────────────────────────
 */

'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 1 — CONSTANTES GLOBALES
// ─────────────────────────────────────────────────────────────────────────────

/** Claves de PropertiesService (Script Properties). Nunca hardcodear IDs acá. */
const PROP = Object.freeze({
  ID_PLANTILLA:  'DM_ID_PLANTILLA_MAESTRA',  // ID del Sheet template de DM Global
  ID_CARPETA:    'DM_ID_CARPETA_CLIENTES',    // ID de la carpeta Drive destino
  EMAIL_ADMIN:   'DM_EMAIL_ADMIN',            // email que recibe alertas de error
});

/**
 * Títulos de pregunta en el Google Form.
 * Si el Form cambia una pregunta, solo hay que actualizar este objeto.
 */
const CAMPOS = Object.freeze({
  NOMBRE_NEGOCIO: 'Nombre del Negocio',
  EMAIL_GERENTE:  'Correo del Gerente',
  REVIEW_LINK:    'Enlace de Google Reviews',
  ID_LICENCIA:    'ID de Licencia / Cliente',
});

/**
 * Mapa de celdas en la pestaña CONFIG de cada planilla aprovisionada.
 * Debe coincidir con lo que lee el script de validación del cliente
 * (validar_licencia_externa en el CRM de DM Global).
 */
const CONFIG = Object.freeze({
  PESTAÑA:       'CONFIG',
  CELDA_LICENCIA: 'B1',   // ← id_comercio que valida el CRM
  CELDA_REVIEW:   'B2',   // ← enlace de Google Reviews
  CELDA_EMAIL:    'B3',   // ← correo del gerente (para informes semanales)
});

const MARCA = 'Servicio de Feedback · DM Global';

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 2 — PUNTO DE ENTRADA (trigger onFormSubmit)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Punto de entrada del trigger "Al enviar el formulario".
 *
 * Configurar en: Editor → Triggers → onFormSubmit → Al enviar el formulario.
 *
 * @param {GoogleAppsScript.Events.SheetsOnFormSubmit} e  Evento del trigger.
 */
function onFormSubmit(e) {
  const inicio = Date.now();
  log_('INFO', '═══ Inicio onFormSubmit ═══');

  // ── Paso 1: extraer y validar datos del formulario ───────────────────
  let datos;
  try {
    datos = extraerDatosFormulario_(e);
  } catch (err) {
    log_('ERROR', `Error extrayendo datos del formulario: ${err.message}`);
    notificarError_(err, { origen: 'extraerDatosFormulario_', evento: JSON.stringify(e) });
    return;
  }

  log_('INFO', `Datos del formulario OK | negocio="${datos.nombreNegocio}" | licencia="${datos.idLicencia}"`);

  // ── Paso 2: copiar Planilla Maestra e inyectar configuración ─────────
  let urlPlanilla;
  try {
    urlPlanilla = aprovisionarPlanilla_(datos);
  } catch (err) {
    log_('ERROR', `Error aprovisionando planilla: ${err.message}`);
    notificarError_(err, datos);
    return;
  }

  log_('INFO', `Planilla aprovisionada | url=${urlPlanilla}`);

  // ── Paso 3: enviar email de bienvenida ───────────────────────────────
  try {
    enviarBienvenida_(datos, urlPlanilla);
  } catch (err) {
    // El aprovisionamiento ya fue exitoso; no abortar por un error de email.
    log_('ERROR', `Error enviando bienvenida: ${err.message}`);
    notificarError_(err, { ...datos, urlPlanilla });
  }

  const duracion = ((Date.now() - inicio) / 1000).toFixed(1);
  log_('INFO', `═══ Alta completada | tiempo=${duracion}s ═══`);
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 3 — EXTRACCIÓN Y VALIDACIÓN DE DATOS DEL FORMULARIO
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Parsea el evento onFormSubmit y devuelve un objeto con los datos limpios.
 * Lanza Error si algún campo requerido está ausente o no pasa validación básica.
 *
 * @param {GoogleAppsScript.Events.SheetsOnFormSubmit} e
 * @returns {{ nombreNegocio, emailGerente, reviewLink, idLicencia }}
 * @throws {Error}  Si faltan campos o los valores son inválidos.
 */
function extraerDatosFormulario_(e) {
  // e.response existe cuando el trigger está adjunto a un Form directamente.
  // Si el trigger está en una hoja vinculada, usar e.namedValues en su lugar.
  const itemResponses = e.response
    ? e.response.getItemResponses()
    : _itemResponsesDeNamedValues(e.namedValues);

  const mapa = {};
  itemResponses.forEach((ir) => {
    const titulo = ir.getItem().getTitle().trim();
    const valor  = String(ir.getResponse() || '').trim();
    mapa[titulo] = valor;
  });

  const nombreNegocio = mapa[CAMPOS.NOMBRE_NEGOCIO] || '';
  const emailGerente  = mapa[CAMPOS.EMAIL_GERENTE]  || '';
  const reviewLink    = mapa[CAMPOS.REVIEW_LINK]    || '';
  const idLicencia    = mapa[CAMPOS.ID_LICENCIA]    || '';

  // ── Validaciones ─────────────────────────────────────────────────────
  const errores = [];

  if (!nombreNegocio) errores.push(`Campo "${CAMPOS.NOMBRE_NEGOCIO}" vacío.`);
  if (!idLicencia)    errores.push(`Campo "${CAMPOS.ID_LICENCIA}" vacío.`);
  if (!emailGerente || !emailGerente.includes('@'))
    errores.push(`Campo "${CAMPOS.EMAIL_GERENTE}" inválido: "${emailGerente}".`);
  if (!reviewLink || !reviewLink.startsWith('http'))
    errores.push(`Campo "${CAMPOS.REVIEW_LINK}" inválido: "${reviewLink}".`);
  if (idLicencia && !/^[A-Z0-9\-]{3,50}$/.test(idLicencia))
    errores.push(`"${CAMPOS.ID_LICENCIA}" debe ser alfanumérico con guiones (ej: HOTEL-TERRAZAS-01).`);

  if (errores.length > 0) {
    throw new Error(`Formulario inválido:\n• ${errores.join('\n• ')}`);
  }

  return { nombreNegocio, emailGerente, reviewLink, idLicencia };
}

/**
 * Fallback para triggers adjuntos a hojas vinculadas (namedValues en vez de response).
 * @param {Object} namedValues
 * @returns {Array<{ getItem: Function, getResponse: Function }>}
 */
function _itemResponsesDeNamedValues(namedValues = {}) {
  return Object.entries(namedValues).map(([titulo, valores]) => ({
    getItem:     () => ({ getTitle: () => titulo }),
    getResponse: () => (Array.isArray(valores) ? valores[0] : valores) || '',
  }));
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 4 — APROVISIONAMIENTO DE PLANILLA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Copia la Planilla Maestra, la renombra y la configura para el nuevo cliente.
 *
 * @param {{ nombreNegocio, emailGerente, reviewLink, idLicencia }} datos
 * @returns {string}  URL de edición de la nueva planilla.
 * @throws {Error}  Si falla la copia o la inyección de datos.
 */
function aprovisionarPlanilla_(datos) {
  const sheetId  = copiarPlantillaMaestra_(datos);
  inyectarConfig_(sheetId, datos);
  return `https://docs.google.com/spreadsheets/d/${sheetId}/edit`;
}

/**
 * Toma una copia de la Planilla Maestra y la guarda en la carpeta corporativa.
 *
 * @param {{ nombreNegocio }} datos
 * @returns {string}  ID del nuevo archivo en Drive.
 */
function copiarPlantillaMaestra_({ nombreNegocio }) {
  const props = PropertiesService.getScriptProperties();
  const idPlantilla = props.getProperty(PROP.ID_PLANTILLA);
  const idCarpeta   = props.getProperty(PROP.ID_CARPETA);

  if (!idPlantilla) throw new Error(`Propiedad "${PROP.ID_PLANTILLA}" no configurada. Ejecutá configurarPropiedades().`);
  if (!idCarpeta)   throw new Error(`Propiedad "${PROP.ID_CARPETA}" no configurada. Ejecutá configurarPropiedades().`);

  const nombreArchivo = `Servicio de feedback - ${nombreNegocio}`;
  const carpeta       = DriveApp.getFolderById(idCarpeta);
  const plantilla     = DriveApp.getFileById(idPlantilla);

  const copia = plantilla.makeCopy(nombreArchivo, carpeta);
  log_('INFO', `Planilla copiada | nombre="${nombreArchivo}" | id=${copia.getId()}`);

  return copia.getId();
}

/**
 * Abre la nueva planilla e inyecta los datos de configuración en CONFIG.
 *
 * @param {string} sheetId  ID de la nueva planilla de Google Sheets.
 * @param {{ idLicencia, reviewLink, emailGerente }} datos
 */
function inyectarConfig_(sheetId, { idLicencia, reviewLink, emailGerente }) {
  const ss         = SpreadsheetApp.openById(sheetId);
  const hojaConfig = ss.getSheetByName(CONFIG.PESTAÑA);

  if (!hojaConfig) {
    throw new Error(
      `La pestaña "${CONFIG.PESTAÑA}" no existe en la Planilla Maestra. ` +
      'Verificá que la plantilla tenga esa hoja.'
    );
  }

  // Escritura en batch: una sola operación de red por celda
  const escrituras = [
    [CONFIG.CELDA_LICENCIA, idLicencia],
    [CONFIG.CELDA_REVIEW,   reviewLink],
    [CONFIG.CELDA_EMAIL,    emailGerente],
  ];

  escrituras.forEach(([celda, valor]) => {
    hojaConfig.getRange(celda).setValue(valor);
  });

  // Forzar persistencia antes de cerrar (evita pérdida en escrituras rápidas)
  SpreadsheetApp.flush();

  log_('INFO', `CONFIG inyectada | licencia=${idLicencia} | celda_base=${CONFIG.CELDA_LICENCIA}`);
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 5 — EMAIL DE BIENVENIDA
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Envía el correo de bienvenida al gerente del comercio recién dado de alta.
 *
 * @param {{ nombreNegocio, emailGerente, idLicencia }} datos
 * @param {string} urlPlanilla  URL de edición de la planilla aprovisionada.
 */
function enviarBienvenida_({ nombreNegocio, emailGerente, idLicencia }, urlPlanilla) {
  const asunto = `¡Bienvenido al Servicio de Feedback, ${nombreNegocio}! 🌟`;

  GmailApp.sendEmail(
    emailGerente,
    asunto,
    // Cuerpo en texto plano (fallback para clientes sin soporte HTML)
    [
      `¡Hola!`,
      ``,
      `Tu cuenta del Servicio de Feedback de DM Global ya está activa.`,
      `ID de Licencia: ${idLicencia}`,
      ``,
      `Accedé a tu planilla de trabajo aquí: ${urlPlanilla}`,
      ``,
      `Para cualquier consulta: soporte@dmglobal.com`,
    ].join('\n'),
    {
      name:     MARCA,
      htmlBody: construirHtmlBienvenida_({ nombreNegocio, emailGerente, idLicencia }, urlPlanilla),
      noReply:  false,
    }
  );

  log_('INFO', `Email de bienvenida enviado a ${emailGerente}`);
}

/**
 * Construye el cuerpo HTML del email de bienvenida.
 *
 * @param {{ nombreNegocio, idLicencia }} datos
 * @param {string} urlPlanilla
 * @returns {string}  HTML completo listo para GmailApp.
 */
function construirHtmlBienvenida_({ nombreNegocio, idLicencia }, urlPlanilla) {
  return /* html */`
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1.0"/>
  <style>
    /* Reset */
    body, table, td { margin:0; padding:0; border:0; }
    body            { background:#f0f4f8; font-family:Arial,Helvetica,sans-serif; -webkit-text-size-adjust:100%; }

    /* Wrapper */
    .email-wrap   { max-width:580px; margin:28px auto; }

    /* Header */
    .header       { background:linear-gradient(135deg,#1e40af 0%,#3b82f6 100%);
                    padding:36px 32px 28px; border-radius:14px 14px 0 0; text-align:center; }
    .header .logo { color:#bfdbfe; font-size:11px; letter-spacing:.12em;
                    text-transform:uppercase; margin:0 0 10px; }
    .header h1    { color:#ffffff; font-size:26px; font-weight:800;
                    margin:0 0 6px; line-height:1.2; }
    .header .sub  { color:#bfdbfe; font-size:14px; margin:0; }

    /* Body card */
    .card         { background:#ffffff; padding:32px; }
    .card p       { color:#374151; font-size:15px; line-height:1.7; margin:0 0 16px; }
    .card .hi     { font-size:18px; font-weight:700; color:#111827; margin:0 0 20px; }

    /* Divider */
    .divider      { border:none; border-top:1px solid #e5e7eb; margin:24px 0; }

    /* CTA button */
    .cta-wrap     { text-align:center; margin:28px 0; }
    .cta          { display:inline-block; background:#1d4ed8; color:#ffffff !important;
                    font-size:16px; font-weight:700; padding:16px 36px;
                    border-radius:10px; text-decoration:none; letter-spacing:.01em;
                    box-shadow:0 4px 14px rgba(29,78,216,.35); }
    .cta:hover    { background:#1e40af; }

    /* Info box */
    .info-box     { background:#eff6ff; border:1px solid #bfdbfe; border-radius:10px;
                    padding:16px 20px; margin:20px 0; }
    .info-box p   { margin:0; color:#1e40af; font-size:13px; }
    .info-row     { display:flex; justify-content:space-between; align-items:center;
                    padding:7px 0; border-bottom:1px solid #dbeafe; font-size:14px; }
    .info-row:last-child { border:none; }
    .info-lbl     { color:#6b7280; }
    .info-val     { font-weight:700; color:#1e3a8a; font-family:monospace;
                    word-break:break-all; }

    /* Steps */
    .steps        { margin:20px 0; }
    .step         { display:flex; align-items:flex-start; gap:14px; margin:0 0 14px; }
    .step-num     { flex-shrink:0; width:28px; height:28px; border-radius:50%;
                    background:#1d4ed8; color:#fff; font-size:12px; font-weight:700;
                    display:flex; align-items:center; justify-content:center; }
    .step-txt     { color:#374151; font-size:14px; line-height:1.5; padding-top:4px; }

    /* Footer */
    .footer       { background:#f9fafb; border-radius:0 0 14px 14px;
                    padding:20px 28px; text-align:center;
                    border-top:1px solid #e5e7eb; }
    .footer p     { color:#9ca3af; font-size:11px; margin:0 0 4px; line-height:1.5; }
    .footer a     { color:#3b82f6; text-decoration:none; }
  </style>
</head>
<body>
<div class="email-wrap">

  <!-- ── Header ─────────────────────────────────────────────────────── -->
  <div class="header">
    <p class="logo">Servicio de Feedback · DM Global</p>
    <h1>¡Tu servicio ya está activo! 🎉</h1>
    <p class="sub">Comenzá a recibir reseñas automáticas de tus clientes</p>
  </div>

  <!-- ── Cuerpo principal ───────────────────────────────────────────── -->
  <div class="card">
    <p class="hi">¡Hola, equipo de <strong>${nombreNegocio}</strong>!</p>

    <p>
      Nos alegra darte la bienvenida al <strong>Servicio de Feedback de DM Global</strong>.
      Tu cuenta fue configurada exitosamente y tu planilla de trabajo personalizada
      ya se encuentra en tu Google Drive, lista para usar.
    </p>

    <!-- Botón CTA azul -->
    <div class="cta-wrap">
      <a href="${urlPlanilla}" class="cta">
        📊 &nbsp; Abrir mi planilla de trabajo
      </a>
    </div>

    <hr class="divider"/>

    <!-- Datos de la licencia -->
    <p style="font-weight:700;color:#111827;margin-bottom:12px;">
      Tus datos de licencia
    </p>
    <div class="info-box">
      <div class="info-row">
        <span class="info-lbl">ID de Licencia</span>
        <span class="info-val">${idLicencia}</span>
      </div>
      <div class="info-row">
        <span class="info-lbl">Comercio</span>
        <span class="info-val" style="font-family:inherit">${nombreNegocio}</span>
      </div>
      <div class="info-row">
        <span class="info-lbl">Estado</span>
        <span class="info-val" style="color:#16a34a">✓ Activa</span>
      </div>
    </div>

    <p style="font-size:13px;color:#6b7280;margin-top:0;">
      El <strong>ID de Licencia</strong> ya está precargado en la pestaña
      <code style="background:#f3f4f6;padding:1px 6px;border-radius:4px">CONFIG</code>
      de tu planilla. No necesitás copiarlo manualmente.
    </p>

    <hr class="divider"/>

    <!-- Pasos de inicio rápido -->
    <p style="font-weight:700;color:#111827;margin-bottom:16px;">
      Primeros pasos (3 minutos)
    </p>
    <div class="steps">
      <div class="step">
        <div class="step-num">1</div>
        <div class="step-txt">
          <strong>Abrí tu planilla</strong> usando el botón de arriba.
          La pestaña CONFIG ya tiene tus credenciales precargadas.
        </div>
      </div>
      <div class="step">
        <div class="step-num">2</div>
        <div class="step-txt">
          <strong>Cargá los datos de tus clientes</strong> en la pestaña
          <code style="background:#f3f4f6;padding:1px 5px;border-radius:4px">BORRADOR</code>
          (nombre, email, idioma y canal de contacto).
        </div>
      </div>
      <div class="step">
        <div class="step-num">3</div>
        <div class="step-txt">
          <strong>Presioná "🚀 APROBAR Y CARGAR DATOS"</strong> al final del día.
          El sistema enviará las encuestas automáticamente en las próximas 24&nbsp;hs.
        </div>
      </div>
    </div>
  </div>

  <!-- ── Footer ─────────────────────────────────────────────────────── -->
  <div class="footer">
    <p>¿Tenés dudas? Escribinos a
      <a href="mailto:soporte@dmglobal.com">soporte@dmglobal.com</a>
    </p>
    <p>
      © DM Global · Servicio de Feedback<br/>
      Este correo fue generado automáticamente al completar el formulario de alta.
    </p>
  </div>

</div>
</body>
</html>`.trim();
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 6 — NOTIFICACIÓN DE ERRORES AL ADMIN
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Envía un email de alerta al administrador de DM Global cuando el
 * proceso de onboarding falla en cualquier paso.
 *
 * @param {Error}  error    Error capturado.
 * @param {Object} contexto Datos disponibles hasta el punto del error.
 */
function notificarError_(error, contexto = {}) {
  const props      = PropertiesService.getScriptProperties();
  const emailAdmin = props.getProperty(PROP.EMAIL_ADMIN);

  if (!emailAdmin) {
    log_('WARN', `Sin email admin configurado (${PROP.EMAIL_ADMIN}). Error no notificado.`);
    return;
  }

  const detalles = [
    `Error: ${error.message}`,
    `Stack: ${error.stack || 'no disponible'}`,
    `Contexto: ${JSON.stringify(contexto, null, 2)}`,
    `Timestamp: ${new Date().toISOString()}`,
  ].join('\n\n');

  try {
    GmailApp.sendEmail(
      emailAdmin,
      `[ERROR] Onboarding fallido — ${contexto.nombreNegocio || 'desconocido'}`,
      detalles,
      { name: `${MARCA} · Sistema` }
    );
    log_('INFO', `Alerta de error enviada a ${emailAdmin}`);
  } catch (e) {
    log_('ERROR', `No se pudo enviar la alerta de error: ${e.message}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BLOQUE 7 — UTILIDADES
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Logging unificado. Escribe en Logger (log clásico) y console (Cloud Logging).
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
// BLOQUE 8 — SETUP INICIAL (ejecutar una sola vez)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Guarda los IDs de configuración en Script Properties.
 * Ejecutar manualmente desde el editor UNA SOLA VEZ al desplegar el script.
 *
 * Valores a reemplazar antes de correr:
 *   ID_PLANTILLA → ID del Google Sheet que sirve de plantilla maestra.
 *   ID_CARPETA   → ID de la carpeta de Drive donde se guardan las copias.
 *   EMAIL_ADMIN  → Email del responsable técnico de DM Global.
 */
function configurarPropiedades() {
  const CONFIG_SETUP = {
    [PROP.ID_PLANTILLA]: '1A2B3C4D_REEMPLAZAR_CON_ID_REAL_DE_LA_PLANTILLA',
    [PROP.ID_CARPETA]:   '1X2Y3Z4W_REEMPLAZAR_CON_ID_REAL_DE_LA_CARPETA',
    [PROP.EMAIL_ADMIN]:  'admin@dmglobal.com',
  };

  PropertiesService.getScriptProperties().setProperties(CONFIG_SETUP);
  Logger.log('Propiedades guardadas:');
  Object.entries(CONFIG_SETUP).forEach(([k, v]) => Logger.log(`  ${k} = ${v}`));
  Logger.log('Listo. Podés verificar con mostrarPropiedades().');
}

/**
 * Imprime las propiedades actuales en el log (sin exponer valores sensibles).
 * Útil para verificar la configuración sin editar el código.
 */
function mostrarPropiedades() {
  const props = PropertiesService.getScriptProperties().getProperties();
  Logger.log('── Script Properties actuales ──');
  Object.entries(props).forEach(([k, v]) => {
    const enmascarado = v.length > 8 ? `${v.slice(0, 4)}...${v.slice(-4)}` : '***';
    Logger.log(`  ${k}: ${enmascarado}`);
  });
}

/**
 * Función de prueba para el flujo completo sin necesidad de enviar un Form.
 * Ejecutar desde el editor para verificar que todo funciona antes del deploy.
 */
function testOnboarding() {
  const eventoSimulado = {
    response: null,
    namedValues: {
      [CAMPOS.NOMBRE_NEGOCIO]: ['Hotel Las Terrazas'],
      [CAMPOS.EMAIL_GERENTE]:  ['gerente@lasterrazas.com'],
      [CAMPOS.REVIEW_LINK]:    ['https://g.page/r/lasterrazas/review'],
      [CAMPOS.ID_LICENCIA]:    ['HOTEL-TERRAZAS-01'],
    },
  };

  onFormSubmit(eventoSimulado);
}
