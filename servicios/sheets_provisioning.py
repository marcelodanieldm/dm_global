"""
Aprovisionamiento automático de Google Sheets — Servicio de Feedback.

Cuando un cliente activa el servicio, este módulo:
  1. Copia la Planilla Maestra (template) a la cuenta del comercio.
  2. Pre-carga en la pestaña CONFIG el ``comercio_id`` y ``api_token``
     generados por el CRM.
  3. Devuelve la URL de la nueva planilla para guardarla en
     ``ServicioFeedbackConfig.google_sheet_url``.

Configuración requerida en settings.py o .env:
    GOOGLE_SERVICE_ACCOUNT_FILE  Ruta al JSON de la cuenta de servicio.
    GOOGLE_SHEETS_TEMPLATE_ID    ID de la Planilla Maestra en Google Drive.

Dependencias:
    pip install google-api-python-client google-auth

Si no está configurado, ``provisionar_planilla()`` devuelve ``None``
sin romper el flujo de alta del cliente (el operador asigna la URL
manualmente desde el Django Admin en ese caso).
"""
import logging
import os

logger = logging.getLogger(__name__)

# Celdas en las que el script escribe las credenciales (coincide con
# lo que espera FeedbackService.gs en la pestaña CONFIG).
_CELDA_COMERCIO_ID = "B2"
_CELDA_API_TOKEN   = "B3"
_PESTAÑA_CONFIG    = "CONFIG"


def provisionar_planilla(config) -> str | None:
    """Crea una copia de la Planilla Maestra y pre-carga las credenciales.

    Args:
        config: Instancia de ``ServicioFeedbackConfig`` ya guardada en BD,
                con ``id`` y ``api_token`` generados.

    Returns:
        URL de la nueva planilla, o ``None`` si la integración con
        Google Sheets no está configurada.
    """
    service_account_file = os.environ.get("GOOGLE_SERVICE_ACCOUNT_FILE")
    template_id          = os.environ.get("GOOGLE_SHEETS_TEMPLATE_ID")

    if not service_account_file or not template_id:
        logger.warning(
            "Aprovisionamiento de Sheets omitido: "
            "GOOGLE_SERVICE_ACCOUNT_FILE o GOOGLE_SHEETS_TEMPLATE_ID no configurados. "
            "Asignar google_sheet_url manualmente en el Admin."
        )
        return None

    try:
        return _crear_y_configurar_planilla(config, service_account_file, template_id)
    except Exception as exc:
        logger.error(
            "Error al aprovisionar planilla para org=%s: %s",
            config.organizacion.nombre,
            exc,
        )
        return None


def _crear_y_configurar_planilla(config, service_account_file: str, template_id: str) -> str:
    """Implementación interna del aprovisionamiento.

    1. Copia la Planilla Maestra en Google Drive.
    2. Renombra la copia con el nombre del comercio.
    3. Escribe las credenciales en la pestaña CONFIG.
    4. Comparte la planilla con el email del usuario (si disponible).
    5. Retorna la URL de edición de la nueva planilla.
    """
    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    SCOPES = [
        "https://www.googleapis.com/auth/drive",
        "https://www.googleapis.com/auth/spreadsheets",
    ]

    credenciales = service_account.Credentials.from_service_account_file(
        service_account_file, scopes=SCOPES
    )

    drive_service  = build("drive",  "v3", credentials=credenciales, cache_discovery=False)
    sheets_service = build("sheets", "v4", credentials=credenciales, cache_discovery=False)

    nombre_planilla = f"Feedback — {config.organizacion.nombre}"

    # ── Paso 1: copiar la Planilla Maestra ─────────────────────────────
    copia = drive_service.files().copy(
        fileId=template_id,
        body={"name": nombre_planilla},
    ).execute()
    nueva_id = copia["id"]
    logger.info("Planilla copiada | nombre='%s' | id=%s", nombre_planilla, nueva_id)

    # ── Paso 2: escribir credenciales en CONFIG ─────────────────────────
    sheets_service.spreadsheets().values().batchUpdate(
        spreadsheetId=nueva_id,
        body={
            "valueInputOption": "RAW",
            "data": [
                {
                    "range":  f"{_PESTAÑA_CONFIG}!{_CELDA_COMERCIO_ID}",
                    "values": [[str(config.id)]],
                },
                {
                    "range":  f"{_PESTAÑA_CONFIG}!{_CELDA_API_TOKEN}",
                    "values": [[str(config.api_token)]],
                },
            ],
        },
    ).execute()
    logger.info("Credenciales escritas en pestaña CONFIG | id_config=%s", config.id)

    # ── Paso 3: compartir con el usuario del comercio (si tiene email) ──
    email_usuario = getattr(config.organizacion.usuario_principal, "email", None)
    if email_usuario:
        drive_service.permissions().create(
            fileId=nueva_id,
            body={"type": "user", "role": "writer", "emailAddress": email_usuario},
            sendNotificationEmail=False,
        ).execute()
        logger.info("Planilla compartida con %s", email_usuario)

    url_planilla = f"https://docs.google.com/spreadsheets/d/{nueva_id}/edit"
    return url_planilla
