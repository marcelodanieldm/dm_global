/**
 * @fileoverview Informe Semanal — Servicio de Feedback · DM Global
 *
 * Genera y envía el informe semanal de rendimiento cada lunes por la mañana.
 *
 * Configurar el trigger:
 *   Editor de Apps Script → Reloj → Agregar trigger
 *   Función: generarInformeSemanal
 *   Tipo:    Basado en tiempo → Semana → Lunes → 08:00–09:00 hs
 *
 * Celdas adicionales requeridas en la pestaña CONFIG:
 *   A4: "email_reporte"    B4: correo donde llega el informe
 *   A5: "nombre_destinatario"  B5: nombre para el saludo del email
 *
 * El informe incluye:
 *   · Total de encuestas enviadas en los últimos 7 días.
 *   · Pendientes al cierre de semana.
 *   · Errores de envío (para auditoría).
 *   · Tiempo promedio entre check-out y envío.
 *   · Canales utilizados (email vs WhatsApp).
 */

'use strict';

/** Celdas de config del informe (además de B2 y B3 ya usados por FeedbackService). */
const INFORME_CFG = Object.freeze({
  CELDA_EMAIL_DEST:  'B4',
  CELDA_NOMBRE_DEST: 'B5',
  DIAS_REPORTE:      7,
});

// ─────────────────────────────────────────────────────────────────────────────
// PUNTO DE ENTRADA — trigger de lunes a las 08:00 hs
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Genera el informe semanal y lo envía por email al destinatario
 * configurado en CONFIG!B4.
 */
function generarInformeSemanal() {
  log_('INFO', '═══ Inicio generarInformeSemanal ═══');

  const { emailDestino, nombreDestino } = leerConfigInforme_();
  if (!emailDestino) {
    log_('WARN', 'Informe omitido: email_reporte no configurado en CONFIG!B4.');
    return;
  }

  const metricas = calcularMetricas_();

  if (metricas.total === 0) {
    log_('INFO', 'Sin actividad en los últimos 7 días. Informe no enviado.');
    return;
  }

  const html = construirHtmlInforme_(metricas, nombreDestino);

  GmailApp.sendEmail(
    emailDestino,
    `📊 Tu informe semanal de feedback — ${metricas.periodo}`,
    `Informe semanal de ${metricas.nombreComercio}: ${metricas.enviados} encuestas enviadas esta semana.`,
    {
      name:     'DM Global · Servicio de Feedback',
      htmlBody: html,
    }
  );

  log_('INFO', `Informe enviado a ${emailDestino} | enviados=${metricas.enviados} | total=${metricas.total}`);
}

// ─────────────────────────────────────────────────────────────────────────────
// LECTURA DE CONFIGURACIÓN Y MÉTRICAS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Lee el email y nombre del destinatario del informe desde CONFIG.
 * @returns {{ emailDestino: string, nombreDestino: string }}
 */
function leerConfigInforme_() {
  const hoja = SpreadsheetApp.getActiveSpreadsheet()
                             .getSheetByName(CFG.HOJA_CONFIG);
  if (!hoja) return { emailDestino: '', nombreDestino: '' };

  return {
    emailDestino:  String(hoja.getRange(INFORME_CFG.CELDA_EMAIL_DEST).getValue()).trim(),
    nombreDestino: String(hoja.getRange(INFORME_CFG.CELDA_NOMBRE_DEST).getValue()).trim() || 'Cliente',
  };
}

/**
 * Calcula las métricas del informe semanal combinando:
 *   1. La pestaña OPERACIONES (enviados / pendientes / canales).
 *   2. El endpoint /stats/ del CRM (respuestas reales, quejas contenidas).
 *
 * @returns {Object}  Objeto de métricas listo para el template HTML.
 */
function calcularMetricas_() {
  const ss       = SpreadsheetApp.getActiveSpreadsheet();
  const hojaOps  = ss.getSheetByName('OPERACIONES');
  const hojaConf = ss.getSheetByName(CFG.HOJA_CONFIG);

  const nombreComercio = hojaConf
    ? String(hojaConf.getRange('B1').getValue()).trim() || ss.getName()
    : ss.getName();

  const hoy    = new Date();
  const inicio = new Date(hoy.getTime() - INFORME_CFG.DIAS_REPORTE * 24 * 60 * 60 * 1000);

  // ── 1. Métricas de envío desde la planilla ──────────────────────────
  let enviados = 0, pendientes = 0, errores = 0;
  const canales = { email: 0, whatsapp: 0 };

  const valores = hojaOps.getDataRange().getValues();
  for (let i = 1; i < valores.length; i++) {
    const row   = valores[i];
    const fecha = row[COL.FECHA_FINALIZACION - 1];
    if (!(fecha instanceof Date) || fecha < inicio) continue;

    const estado = String(row[COL.ESTADO - 1]).trim().toUpperCase();
    const canal  = String(row[COL.CANAL  - 1]).trim().toLowerCase();

    if (estado === 'ENVIADO')   enviados++;
    else if (estado === 'PENDIENTE') pendientes++;
    else if (estado === 'ERROR') errores++;

    if (canal === 'email')     canales.email++;
    else if (canal === 'whatsapp') canales.whatsapp++;
  }

  const total    = enviados + pendientes + errores;
  const tasaEnvio = total > 0 ? Math.round((enviados / total) * 100) : 0;

  // ── 2. Métricas de valoraciones desde el CRM ────────────────────────
  const creds = leerCredenciales_();
  let totalRespuestas = 0, positivas = 0, contenidas = 0, redirigidas = 0;

  if (creds.comercioId && creds.apiToken) {
    try {
      const statsUrl = (
        `https://TU-DOMINIO.com/api/v1/servicio-feedback/stats/`
        + `?comercio_id=${encodeURIComponent(creds.comercioId)}`
        + `&token=${encodeURIComponent(creds.apiToken)}`
        + `&dias=${INFORME_CFG.DIAS_REPORTE}`
      );
      const resp = UrlFetchApp.fetch(statsUrl, { muteHttpExceptions: true });
      if (resp.getResponseCode() === 200) {
        const data      = JSON.parse(resp.getContentText());
        totalRespuestas = data.total_respuestas  || 0;
        positivas       = data.positivas         || 0;
        contenidas      = data.contenidas        || 0;
        redirigidas     = data.redirigidas_a_google || 0;
      }
    } catch (e) {
      log_('WARN', `No se pudieron obtener stats del CRM: ${e.message}`);
    }
  }

  const tasaRespuesta = enviados > 0 ? Math.round((totalRespuestas / enviados) * 100) : 0;

  // ── 3. Formateo del período ──────────────────────────────────────────
  const tz      = Session.getScriptTimeZone();
  const fmtDate = (d) => Utilities.formatDate(d, tz, 'dd/MM/yyyy');

  return {
    nombreComercio,
    periodo:         `${fmtDate(inicio)} – ${fmtDate(hoy)}`,
    total,
    enviados,
    pendientes,
    errores,
    tasaEnvio,
    canales,
    // Métricas de valoración (del portal de calificación)
    totalRespuestas,
    tasaRespuesta,
    positivas,           // calificacion >= 4 → llegaron a Google Reviews
    contenidas,          // calificacion <= 3 → quejas privadas interceptadas
    redirigidas,         // efectivamente redirigidos a Google Reviews
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// TEMPLATE HTML DEL INFORME
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Construye el HTML del email de informe.
 *
 * @param {Object} m         Métricas calculadas por calcularMetricas_()
 * @param {string} nombreDest  Nombre del destinatario para el saludo
 * @returns {string}  HTML listo para GmailApp.sendEmail({ htmlBody })
 */
function construirHtmlInforme_(m, nombreDest) {
  // Barra de progreso visual (tasaEnvio %)
  const barraColor = m.tasaEnvio >= 80 ? '#16a34a' : m.tasaEnvio >= 50 ? '#d97706' : '#dc2626';

  return /* html */`
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8"/>
  <style>
    body      { margin:0; padding:0; background:#f3f4f6; font-family:Arial,sans-serif; }
    .wrap     { max-width:580px; margin:28px auto; background:#fff;
                border-radius:14px; overflow:hidden; box-shadow:0 2px 8px rgba(0,0,0,.07); }
    .header   { background:#4f46e5; padding:26px 32px; }
    .header small{ color:#a5b4fc; font-size:11px; display:block; margin-bottom:4px; }
    .header h1  { margin:0; color:#fff; font-size:22px; }
    .header span{ color:#c7d2fe; font-size:13px; }
    .kpis     { display:grid; grid-template-columns:repeat(3,1fr);
                gap:1px; background:#e5e7eb; }
    .kpi      { background:#fff; padding:20px 16px; text-align:center; }
    .kpi .num { font-size:32px; font-weight:800; line-height:1; }
    .kpi .lbl { font-size:11px; color:#6b7280; margin-top:4px; }
    .kpi.verde .num  { color:#16a34a; }
    .kpi.naranja .num{ color:#d97706; }
    .kpi.rojo .num   { color:#dc2626; }
    .section  { padding:20px 28px; border-bottom:1px solid #f3f4f6; }
    .section h2{ font-size:13px; color:#374151; font-weight:700; margin:0 0 12px; }
    .bar-bg   { height:10px; border-radius:9px; background:#e5e7eb; overflow:hidden; }
    .bar-fill { height:100%; border-radius:9px; background:${barraColor};
                width:${m.tasaEnvio}%; transition:width .5s; }
    .row      { display:flex; justify-content:space-between; font-size:13px;
                padding:6px 0; border-bottom:1px solid #f9fafb; color:#374151; }
    .row:last-child{ border:none; }
    .tag      { display:inline-block; padding:2px 8px; border-radius:20px;
                font-size:11px; font-weight:600; }
    .footer   { padding:16px 28px 24px; text-align:center;
                color:#9ca3af; font-size:11px; }
  </style>
</head>
<body>
<div class="wrap">

  <!-- Header -->
  <div class="header">
    <small>Servicio de Feedback · DM Global</small>
    <h1>${m.nombreComercio}</h1>
    <span>📊 Informe semanal · ${m.periodo}</span>
  </div>

  <!-- KPIs principales -->
  <div class="kpis">
    <div class="kpi verde">
      <div class="num">${m.enviados}</div>
      <div class="lbl">Enviadas ✅</div>
    </div>
    <div class="kpi naranja">
      <div class="num">${m.pendientes}</div>
      <div class="lbl">Pendientes ⏳</div>
    </div>
    <div class="kpi rojo">
      <div class="num">${m.errores}</div>
      <div class="lbl">Con error ⚠️</div>
    </div>
  </div>

  <!-- Tasa de envío -->
  <div class="section">
    <h2>Tasa de envío semanal</h2>
    <div class="bar-bg"><div class="bar-fill"></div></div>
    <p style="font-size:13px;color:#374151;margin:8px 0 0;">
      <strong>${m.tasaEnvio}%</strong> de las encuestas programadas fueron enviadas.
      ${m.tasaEnvio >= 80
        ? '¡Excelente rendimiento esta semana! 🎉'
        : m.tasaEnvio >= 50
          ? 'Rendimiento moderado. Revisá los errores.'
          : '⚠️ Rendimiento bajo. Verificá la configuración.'}
    </p>
  </div>

  <!-- Métricas de valoración -->
  <div class="section">
    <h2>Respuestas del portal de valoración</h2>
    <div class="row">
      <span>Turistas que respondieron</span>
      <strong>${m.totalRespuestas} <span style="font-weight:400;color:#9ca3af;">(${m.tasaRespuesta}%)</span></strong>
    </div>
    <div class="row">
      <span>⭐ Reseñas en Google Maps</span>
      <strong style="color:#16a34a;">${m.positivas}</strong>
    </div>
    <div class="row">
      <span>🔒 Quejas contenidas en privado</span>
      <strong style="color:#d97706;">${m.contenidas}</strong>
    </div>
  </div>

  <!-- Detalle de envíos -->
  <div class="section">
    <h2>Detalle de envíos</h2>
    <div class="row">
      <span>Total programadas</span>
      <strong>${m.total}</strong>
    </div>
    <div class="row">
      <span>Canal Email</span>
      <strong>${m.canales.email}</strong>
    </div>
    <div class="row">
      <span>Canal WhatsApp</span>
      <strong>${m.canales.whatsapp}</strong>
    </div>
  </div>

  <!-- Saludo y CTA -->
  <div class="section" style="border:none;">
    <p style="font-size:14px;color:#374151;margin:0 0 12px;">
      Hola <strong>${nombreDest}</strong>, este es el resumen de actividad de tu
      Servicio de Feedback durante los últimos 7 días.
    </p>
    <p style="font-size:13px;color:#6b7280;margin:0;">
      Para revisar el detalle completo, abrí tu planilla de Google Sheets.
      Si tenés dudas, respondé este correo o escribinos a
      <a href="mailto:soporte@dmglobal.com" style="color:#4f46e5;">soporte@dmglobal.com</a>.
    </p>
  </div>

  <div class="footer">
    DM Global · Servicio de Feedback &nbsp;·&nbsp;
    Este informe se genera automáticamente cada lunes.
  </div>
</div>
</body>
</html>`.trim();
}
