"""
Configuración de URLs de la app ``servicios``.

Incluido desde ``dm_global/urls.py`` con:

    path("", include("servicios.urls", namespace="servicios"))

Rutas expuestas:

    GET  /panel/                                → dashboard_servicios_cliente (login requerido)
    GET  /panel/<uuid:comercio_id>/             → dashboard_cliente (acceso directo por UUID)
    GET  /api/v1/servicio-feedback/validar/     → validar_comercio (API pública)

Uso en templates:
    {% url 'servicios:mi-panel' %}
    {% url 'servicios:dashboard' comercio_id=config_feedback.id %}
    {% url 'servicios:validar' %}

Uso en Python:
    from django.urls import reverse
    reverse("servicios:mi-panel")
"""
from django.urls import path

from . import views

app_name = "servicios"

urlpatterns = [
    # ------------------------------------------------------------------
    # Alta / activación del servicio — el cliente completa el formulario
    # con su Google Review link y el CRM genera las credenciales.
    # ------------------------------------------------------------------
    path(
        "feedback/activar/",
        views.activar_feedback,
        name="activar-feedback",
    ),

    # ------------------------------------------------------------------
    # Panel CRM privado — requiere usuario autenticado (@login_required).
    # Redirige a settings.LOGIN_URL si no hay sesión activa.
    # ------------------------------------------------------------------
    path(
        "panel/",
        views.dashboard_servicios_cliente,
        name="mi-panel",
    ),

    # ------------------------------------------------------------------
    # Panel de acceso directo por UUID (sin login).
    # El convertidor <uuid:...> valida el formato antes de invocar la vista.
    # ------------------------------------------------------------------
    path(
        "panel/<uuid:comercio_id>/",
        views.dashboard_cliente,
        name="dashboard",
    ),

    # ------------------------------------------------------------------
    # Gatekeeper API — consumido por Google Apps Script.
    # Solo acepta GET; @require_GET devuelve 405 para otros métodos.
    # ------------------------------------------------------------------
    path(
        "api/v1/servicio-feedback/validar/",
        views.validar_comercio,
        name="validar",
    ),

    # ------------------------------------------------------------------
    # Stats API — consumida por InformeSemanal.gs (misma autenticación).
    # ------------------------------------------------------------------
    path(
        "api/v1/servicio-feedback/stats/",
        views.stats_feedback,
        name="stats-feedback",
    ),

    # ------------------------------------------------------------------
    # Billing gate de licencias — consumido por Google Apps Script /
    # Google Forms antes de ejecutar cualquier automatización.
    # Sin autenticación adicional: id_comercio es un identificador
    # semipúblico (no un secreto UUID). Ver LicenciaFeedback.docstring.
    # ------------------------------------------------------------------
    path(
        "api/v1/licencias/validar/",
        views.validar_licencia_externa,
        name="validar-licencia",
    ),

    # ------------------------------------------------------------------
    # API de Alertas Críticas — consumida por AlertasCriticas.gs (30 min).
    # Misma autenticación que validar_comercio (comercio_id + token en QS).
    # ------------------------------------------------------------------
    path(
        "api/v1/servicio-feedback/alertas-criticas/",
        views.alertas_criticas_api,
        name="alertas-criticas",
    ),
    path(
        "api/v1/servicio-feedback/alertas-criticas/ack/",
        views.ack_alertas_whatsapp,
        name="ack-alertas-whatsapp",
    ),

    # ------------------------------------------------------------------
    # Portal de valoración del turista (público, sin login).
    # El token_feedback proviene de la columna TOKEN_FEEDBACK de la hoja.
    # ------------------------------------------------------------------
    path(
        "feedback/<uuid:comercio_id>/<uuid:token_feedback>/",
        views.portal_feedback,
        name="portal-feedback",
    ),
    path(
        "feedback/<uuid:comercio_id>/<uuid:token_feedback>/queja/",
        views.queja_feedback,
        name="queja-feedback",
    ),
]
