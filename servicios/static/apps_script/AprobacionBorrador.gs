/**
 * @fileoverview Aprobación del Borrador — Servicio de Feedback · DM Global
 *
 * Adjuntar un botón dibujado en la pestaña BORRADOR que llame a
 * ``aprobarYCargarDatos()``.  En el editor de Apps Script:
 *   Insertar → Dibujo → Botón → "🚀 APROBAR Y CARGAR DATOS"
 *   Clic derecho en el dibujo → Asignar script → aprobarYCargarDatos
 *
 * Layout esperado — pestaña BORRADOR (fila 1 = encabezados):
 *   A: Nombre Turista
 *   B: Email
 *   C: Teléfono (con código de país para WhatsApp, ej: +5491112345678)
 *   D: Idioma    → 'es' | 'en'
 *   E: Canal     → 'email' | 'whatsapp'
 *   F: Fecha Check-out  (Date — cuando termina el servicio)
 *   G: Notas     (opcional)
 *
 * Al aprobar, los registros se mueven a OPERACIONES (fila cabecera libre)
 * con estado PENDIENTE, y la fecha check-out se conserva para que el
 * script nocturno calcule las 24 hs de espera antes del envío.
 */

'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIGURACIÓN — ajustar si cambia el layout de la hoja
// ─────────────────────────────────────────────────────────────────────────────

const BORRADOR = Object.freeze({
  HOJA:               'BORRADOR',
  FILA_INICIO_DATOS:  2,        // la fila 1 es el encabezado
});

/** Columnas en BORRADOR (1-based). */
const BCOL = Object.freeze({
  NOMBRE:   1,   // A
  EMAIL:    2,   // B
  TELEFONO: 3,   // C
  IDIOMA:   4,   // D
  CANAL:    5,   // E
  FECHA:    6,   // F  ← fecha check-out / finalización del servicio
  NOTAS:    7,   // G
});

/** Columnas en OPERACIONES (1-based) — deben coincidir con FeedbackService.gs */
const OCOL = Object.freeze({
  ID:                  1,
  NOMBRE_TURISTA:      2,
  EMAIL:               3,
  TELEFONO:            4,
  IDIOMA:              5,
  CANAL:               6,
  FECHA_FINALIZACION:  7,
  ESTADO:              8,
  TIPO_SERVICIO:       9,
  NOTAS:               10,
  TOKEN_FEEDBACK:      11,  // ← UUID único por turista para el portal de valoración
});

const ESTADO_PENDIENTE = 'PENDIENTE';

// ─────────────────────────────────────────────────────────────────────────────
// FUNCIÓN PRINCIPAL — asignada al botón en BORRADOR
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Lee la pestaña BORRADOR, valida cada fila, las mueve a OPERACIONES
 * con estado PENDIENTE y limpia el borrador.
 *
 * Muestra un diálogo de confirmación antes de proceder para evitar
 * envíos accidentales.
 */
function aprobarYCargarDatos() {
  const ss         = SpreadsheetApp.getActiveSpreadsheet();
  const hojaBorr   = ss.getSheetByName(BORRADOR.HOJA);
  const hojaOps    = ss.getSheetByName('OPERACIONES');

  if (!hojaBorr || !hojaOps) {
    SpreadsheetApp.getUi().alert(
      '⚠️ Error de configuración',
      `No se encontraron las pestañas "${BORRADOR.HOJA}" u "OPERACIONES".`,
      SpreadsheetApp.getUi().ButtonSet.OK
    );
    return;
  }

  // ── 1. Leer filas del borrador ────────────────────────────────────────
  const filas      = leerBorrador_(hojaBorr);
  const { validas, invalidas } = clasificarFilas_(filas);

  if (validas.length === 0) {
    SpreadsheetApp.getUi().alert(
      'Sin registros',
      'El borrador no tiene filas válidas para cargar.',
      SpreadsheetApp.getUi().ButtonSet.OK
    );
    return;
  }

  // ── 2. Confirmar con el operador ──────────────────────────────────────
  const resumen = invalidas.length > 0
    ? `\n⚠️ ${invalidas.length} fila(s) con errores serán ignoradas:\n${invalidas.map(e => `  · ${e}`).join('\n')}`
    : '';

  const ui      = SpreadsheetApp.getUi();
  const botones = ui.ButtonSet.YES_NO;
  const resp    = ui.alert(
    '🚀 Confirmar carga',
    `¿Cargar ${validas.length} registro(s) a OPERACIONES?${resumen}`,
    botones
  );

  if (resp !== ui.Button.YES) {
    log_('INFO', 'Carga cancelada por el operador.');
    return;
  }

  // ── 3. Escribir en OPERACIONES y limpiar borrador ─────────────────────
  const cargadas = escribirEnOperaciones_(hojaOps, validas);
  limpiarBorrador_(hojaBorr, filas.length);

  log_('INFO', `Borrador aprobado | cargados=${cargadas} | omitidos=${invalidas.length}`);

  ss.toast(
    `${cargadas} registro(s) en cola. El sistema los enviará esta noche. ✅`,
    '¡Listo!',
    6
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Lee todas las filas de BORRADOR (sin encabezado) y devuelve un array
 * de objetos con los valores y el número de fila original.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @returns {Array<{ rowNum: number, v: Array }>}
 */
function leerBorrador_(hoja) {
  const lastRow = hoja.getLastRow();
  if (lastRow < BORRADOR.FILA_INICIO_DATOS) return [];

  const rango = hoja.getRange(
    BORRADOR.FILA_INICIO_DATOS,
    1,
    lastRow - BORRADOR.FILA_INICIO_DATOS + 1,
    Object.keys(BCOL).length
  );

  return rango.getValues().map((v, i) => ({
    rowNum: i + BORRADOR.FILA_INICIO_DATOS,
    v,
  }));
}

/**
 * Separa las filas en válidas (listas para OPERACIONES) e inválidas.
 * Una fila es válida si tiene nombre + al menos email o teléfono + fecha.
 *
 * @param {Array} filas
 * @returns {{ validas: Array, invalidas: Array<string> }}
 */
function clasificarFilas_(filas) {
  const validas   = [];
  const invalidas = [];

  filas.forEach(({ rowNum, v }) => {
    const nombre = String(v[BCOL.NOMBRE - 1] || '').trim();
    const email  = String(v[BCOL.EMAIL  - 1] || '').trim();
    const tel    = String(v[BCOL.TELEFONO - 1] || '').trim();
    const fecha  = v[BCOL.FECHA - 1];
    const canal  = String(v[BCOL.CANAL - 1] || '').trim().toLowerCase();

    // Fila vacía → ignorar silenciosamente
    if (!nombre && !email && !tel) return;

    const errores = [];
    if (!nombre)                         errores.push('falta Nombre Turista');
    if (canal === 'email' && !email)     errores.push('falta Email (canal email)');
    if (canal === 'whatsapp' && !tel)    errores.push('falta Teléfono (canal whatsapp)');
    if (!canal)                          errores.push('falta Canal (email | whatsapp)');
    if (!(fecha instanceof Date) || isNaN(fecha.getTime()))
                                         errores.push('Fecha Check-out inválida o vacía');

    if (errores.length > 0) {
      invalidas.push(`Fila ${rowNum}: ${errores.join(', ')}`);
    } else {
      validas.push({ rowNum, v });
    }
  });

  return { validas, invalidas };
}

/**
 * Escribe las filas válidas en la siguiente fila libre de OPERACIONES.
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hojaOps
 * @param {Array} validas
 * @returns {number}  Cantidad de filas escritas.
 */
function escribirEnOperaciones_(hojaOps, validas) {
  if (validas.length === 0) return 0;

  const primeraLibre = hojaOps.getLastRow() + 1;
  const numCols      = Object.keys(OCOL).length;

  // Construir matriz de datos para escritura bulk (una sola llamada a la API)
  const matriz = validas.map(({ v }) => {
    const fila = new Array(numCols).fill('');

    fila[OCOL.ID - 1]                 = Utilities.getUuid();
    fila[OCOL.NOMBRE_TURISTA - 1]     = String(v[BCOL.NOMBRE   - 1]).trim();
    fila[OCOL.EMAIL - 1]              = String(v[BCOL.EMAIL    - 1]).trim();
    fila[OCOL.TELEFONO - 1]           = String(v[BCOL.TELEFONO - 1]).trim();
    fila[OCOL.IDIOMA - 1]             = String(v[BCOL.IDIOMA   - 1]).trim().toLowerCase() || 'es';
    fila[OCOL.CANAL - 1]              = String(v[BCOL.CANAL    - 1]).trim().toLowerCase();
    fila[OCOL.FECHA_FINALIZACION - 1] = v[BCOL.FECHA - 1];   // Date object → Sheets lo formatea
    fila[OCOL.ESTADO - 1]             = ESTADO_PENDIENTE;
    fila[OCOL.NOTAS - 1]              = String(v[BCOL.NOTAS    - 1] || '').trim();
    // UUID único por turista: el email lo incluirá en la URL del portal de
    // valoración de DM Global, permitiendo identificar la respuesta en el CRM.
    fila[OCOL.TOKEN_FEEDBACK - 1]     = Utilities.getUuid();

    return fila;
  });

  hojaOps
    .getRange(primeraLibre, 1, matriz.length, numCols)
    .setValues(matriz);

  return matriz.length;
}

/**
 * Borra las filas de datos del borrador (respeta la fila de encabezado).
 *
 * @param {GoogleAppsScript.Spreadsheet.Sheet} hoja
 * @param {number} cantFilas  Cantidad de filas de datos a borrar.
 */
function limpiarBorrador_(hoja, cantFilas) {
  if (cantFilas <= 0) return;
  hoja
    .getRange(BORRADOR.FILA_INICIO_DATOS, 1, cantFilas, Object.keys(BCOL).length)
    .clearContent();
}
