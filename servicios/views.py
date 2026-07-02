"""
Vistas del Add-on "Servicio de Feedback" — CRM DM Global.

Tres vistas:

``validar_comercio``
    Gatekeeper API (GET) público, consumido por Google Apps Script.
    Requiere ``comercio_id`` + ``token`` en los query params.

``dashboard_servicios_cliente``
    Panel privado del CRM, protegido con ``@login_required``.
    Muestra al usuario autenticado el estado de su suscripción al
    Servicio de Feedback y sus credenciales de integración.

``dashboard_cliente``
    Panel web de acceso directo por UUID (sin login). Pensado para
    compartir con el dueño del comercio cuando no usa el CRM.

--------------------------------------------------------------------------------
Modelo de amenazas para ``validar_comercio``
--------------------------------------------------------------------------------
Amenaza                    Mitigación implementada
─────────────────────────  ────────────────────────────────────────────────────
Enumeración de UUIDs       Respuesta 401 idéntica para formato inválido,
                           comercio inexistente y token incorrecto.
Timing attack              ``secrets.compare_digest`` siempre se ejecuta,
                           incluso cuando el comercio no existe, comparando
                           contra ``_TOKEN_DUMMY`` de longitud uniforme.
Revelación de estructura   Ningún mensaje de error distingue el motivo real
                           del rechazo.
CSRF / Cookie hijacking    ``@csrf_exempt``: Google Apps Script no envía
                           cookies de sesión.
Métodos HTTP no permitidos ``@require_GET``: POST/PUT/DELETE devuelven 405
                           automáticamente, antes de llegar a la lógica.
Inyección SQL              ORM de Django parametriza todas las queries.
"""
import logging
import secrets
import uuid

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.core.mail import EmailMultiAlternatives
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.template.loader import render_to_string
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET

from .ai_service import generar_borrador_respuesta
from .forms import ActivarServicioFeedbackForm
from .models import EstadoCopiloto, EstadoSuscripcion, LicenciaFeedback, Organizacion, RespuestaFeedback, ServicioFeedbackConfig
from .sheets_provisioning import provisionar_planilla

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constantes del módulo
# ---------------------------------------------------------------------------

_TOKEN_DUMMY: str = str(uuid.uuid4())
_PAYLOAD_401: dict = {"autorizado": False, "error": "Credenciales inválidas."}
_JSON_OPTS: dict = {"json_dumps_params": {"ensure_ascii": False}}


def _json_401() -> JsonResponse:
    return JsonResponse(_PAYLOAD_401, status=401, **_JSON_OPTS)


# ---------------------------------------------------------------------------
# Vista 1: Panel privado del CRM (login requerido)
# ---------------------------------------------------------------------------


@login_required
def dashboard_servicios_cliente(request):
    """Panel de control del Servicio de Feedback dentro del CRM.

    Protegida con ``@login_required``: redirige a ``settings.LOGIN_URL``
    (``/accounts/login/`` por defecto) si el usuario no está autenticado.

    Flujo de contexto:
        1. Obtiene la ``Organizacion`` del usuario autenticado mediante
           ``request.user.organizacion`` (OneToOne con ``related_name``).
        2. Busca el ``ServicioFeedbackConfig`` de esa org con
           ``.filter().first()`` para que devuelva ``None`` en lugar de
           lanzar ``DoesNotExist`` cuando el servicio no está contratado.
        3. Pasa ``config_feedback`` (puede ser ``None``) y ``organizacion``
           al template ``servicios/dashboard_feedback.html``.

    Precondición del modelo:
        ``Organizacion.usuario_principal`` debe estar asignado al usuario
        que intenta acceder; de lo contrario se muestra la pantalla de
        "sin organización".
    """
    # ------------------------------------------------------------------
    # Paso 1: obtener la organización del usuario autenticado
    # ------------------------------------------------------------------
    try:
        organizacion: Organizacion = request.user.organizacion
    except Organizacion.DoesNotExist:
        # El usuario existe en el sistema pero aún no tiene una org asignada.
        # El admin debe configurarlo en el panel de superusuario.
        logger.warning(
            "Usuario sin organización intentó acceder al panel | user=%s",
            request.user.username,
        )
        return render(
            request,
            "servicios/dashboard_feedback.html",
            {"organizacion": None, "config_feedback": None},
        )

    # ------------------------------------------------------------------
    # Paso 2: buscar la config del servicio (None si no está contratado)
    # ------------------------------------------------------------------
    config_feedback: ServicioFeedbackConfig | None = (
        ServicioFeedbackConfig.objects
        .filter(organizacion=organizacion)
        .first()
    )

    # ------------------------------------------------------------------
    # Paso 3: construir el contexto y renderizar
    # ------------------------------------------------------------------
    context = {
        "organizacion": organizacion,
        "config_feedback": config_feedback,
        # Constantes de estado expuestas al template para comparaciones
        # con {% if config_feedback.estado_suscripcion == estados.ACTIVO %}
        # sin depender de strings literales en el HTML.
        "estados": EstadoSuscripcion,
    }
    return render(request, "servicios/dashboard_feedback.html", context)


# ---------------------------------------------------------------------------
# Vista 2: Alta / Activación del servicio (cliente autenticado)
# ---------------------------------------------------------------------------


@login_required
def activar_feedback(request):
    """Flujo de alta del Servicio de Feedback desde el CRM del cliente.

    GET  → Muestra el formulario de activación (solo si el servicio no
           está activo aún). Si ya existe configuración, redirige al panel.

    POST → Crea ``ServicioFeedbackConfig`` con ``api_token`` autogenerado,
           dispara el aprovisionamiento de la Planilla Maestra de Google
           Sheets y redirige al panel con mensaje de éxito.

    Estados tras el alta:
        ``DEMO`` — el CRM cambia a ``ACTIVO`` al confirmar el pago.
                   El cliente puede usar el sistema en modo demo desde
                   el primer día.
    """
    try:
        organizacion = request.user.organizacion
    except Organizacion.DoesNotExist:
        messages.error(request, "Tu cuenta no tiene una organización asignada. Contactá al soporte.")
        return redirect("admin:index")

    # Redirigir si el servicio ya está activo (evitar doble alta)
    config_existente = ServicioFeedbackConfig.objects.filter(organizacion=organizacion).first()
    if config_existente:
        messages.info(request, "El Servicio de Feedback ya está activado en tu cuenta.")
        return redirect("servicios:mi-panel")

    if request.method == "POST":
        form = ActivarServicioFeedbackForm(request.POST)
        if form.is_valid():
            config = form.save(commit=False)
            config.organizacion       = organizacion
            config.estado_suscripcion = EstadoSuscripcion.DEMO
            config.save()
            logger.info(
                "Servicio de Feedback activado | org=%s | id=%s",
                organizacion.nombre,
                config.id,
            )

            # Aprovisionar Planilla Maestra (falla silenciosamente si no
            # está configurada la integración con Google Drive)
            url_planilla = provisionar_planilla(config)
            if url_planilla:
                config.google_sheet_url = url_planilla
                config.save(update_fields=["google_sheet_url"])
                messages.success(
                    request,
                    "¡Servicio activado! Tu planilla de Google Sheets ya está lista.",
                )
            else:
                messages.success(
                    request,
                    "¡Servicio activado! En breve recibirás el enlace a tu planilla.",
                )

            return redirect("servicios:mi-panel")
    else:
        form = ActivarServicioFeedbackForm()

    return render(
        request,
        "servicios/activar_feedback.html",
        {"organizacion": organizacion, "form": form},
    )


# ---------------------------------------------------------------------------
# Vista 3: Gatekeeper API (pública, consumida por Google Apps Script)
# ---------------------------------------------------------------------------


@csrf_exempt
@require_GET
def validar_comercio(request) -> JsonResponse:
    """Valida las credenciales de un comercio y devuelve su configuración.

    Consumido por Google Apps Script mediante:

    .. code-block:: text

        GET /api/v1/servicio-feedback/validar/
            ?comercio_id=<UUID>
            &token=<UUID>

    Returns:
        200  Credenciales válidas y suscripción activa.
        401  Formato de UUID inválido, comercio inexistente o token incorrecto.
        403  Credenciales válidas pero suscripción suspendida (INACTIVO).
        405  Método HTTP distinto de GET (gestionado por ``@require_GET``).
    """
    comercio_id_raw: str = request.GET.get("comercio_id", "")
    token_raw: str = request.GET.get("token", "")
    ip_origen: str = request.META.get("REMOTE_ADDR", "desconocida")

    # Fase 1 — Validación de formato UUID
    try:
        comercio_uuid = uuid.UUID(comercio_id_raw)
    except (ValueError, AttributeError):
        logger.warning(
            "Validación rechazada: UUID inválido | ip=%s | raw=%r",
            ip_origen,
            comercio_id_raw,
        )
        return _json_401()

    # Fase 2 — Lookup en BD + comparación en tiempo constante
    config: ServicioFeedbackConfig | None = None
    token_real: str = _TOKEN_DUMMY

    try:
        config = (
            ServicioFeedbackConfig.objects
            .select_related("organizacion")
            .get(id=comercio_uuid)
        )
        token_real = str(config.api_token)
    except ServicioFeedbackConfig.DoesNotExist:
        logger.warning(
            "Validación rechazada: comercio_id inexistente | ip=%s | id=%s",
            ip_origen,
            comercio_uuid,
        )

    credenciales_validas: bool = (
        secrets.compare_digest(token_real, token_raw) and config is not None
    )

    if not credenciales_validas:
        if config is not None:
            logger.warning(
                "Validación rechazada: token incorrecto | ip=%s | id=%s",
                ip_origen,
                comercio_uuid,
            )
        return _json_401()

    # Fase 3 — Validación comercial: estado de suscripción
    if config.estado_suscripcion == EstadoSuscripcion.INACTIVO:
        logger.info(
            "Validación denegada: suscripción inactiva | id=%s | org=%s",
            comercio_uuid,
            config.organizacion.nombre,
        )
        return JsonResponse(
            {
                "autorizado": False,
                "error": (
                    "Suscripción suspendida en el CRM DM Global "
                    "por falta de pago."
                ),
            },
            status=403,
            **_JSON_OPTS,
        )

    logger.info(
        "Validación exitosa | id=%s | org=%s | estado=%s",
        comercio_uuid,
        config.organizacion.nombre,
        config.estado_suscripcion,
    )
    return JsonResponse(
        {
            "autorizado": True,
            "nombre_comercio": config.organizacion.nombre,
            "tipo_negocio": config.tipo_negocio,
            "google_review_link": config.google_review_link,
        },
        status=200,
        **_JSON_OPTS,
    )


# ---------------------------------------------------------------------------
# Vista 3: Panel de acceso directo por UUID (sin login)
# ---------------------------------------------------------------------------


def dashboard_cliente(request, comercio_id: uuid.UUID):
    """Panel web de acceso directo con UUID (sin login requerido).

    La URL contiene el UUID de la configuración como credencial de baja
    fricción, pensada para compartir con el dueño del comercio. Devuelve
    404 si el UUID no existe o si la organización está desactivada.
    """
    config_feedback = get_object_or_404(
        ServicioFeedbackConfig.objects.select_related("organizacion"),
        id=comercio_id,
        organizacion__activa=True,
    )
    return render(
        request,
        "servicios/dashboard_feedback.html",
        {
            "organizacion": config_feedback.organizacion,
            "config_feedback": config_feedback,
            "estados": EstadoSuscripcion,
        },
    )


# ---------------------------------------------------------------------------
# Vista 4–6: Portal de valoración del turista (público, sin login)
# ---------------------------------------------------------------------------

_IDIOMAS_VALIDOS = {"es", "en", "pt", "fr", "de"}

_TEXTOS_PORTAL_BASE = {
    "es": {
        "cta_google":      "Dejar reseña en Google ↗",
        "ya_respondido":   "¡Gracias! Ya registramos tu opinión.",
        "queja_titulo":    "Lamentamos que tu experiencia no fue perfecta.",
        "queja_label":     "Contanos qué podemos mejorar (privado, no se publica):",
        "queja_placeholder": "Escribí aquí tu comentario...",
        "queja_cta":       "Enviar comentario",
        "gracias_pos":     "¡Gracias por compartir tu reseña en Google!",
        "gracias_neg":     "Gracias por contarnos. Lo revisaremos de forma privada.",
        "cerrar":          "Podés cerrar esta ventana.",
        "btn_enviar":      "Enviar calificación",
        "extremo_min":     "Muy mal",
        "extremo_max":     "Excelente",
        "aviso_privacidad": "Tu respuesta es confidencial y nos ayuda a mejorar.",
        "max_chars":       "Máximo 1000 caracteres",
        "skip_text":       "Si preferís no comentar, podés cerrar esta ventana.",
        "error_rating":    "Por favor, seleccioná una calificación.",
    },
    "en": {
        "cta_google":      "Leave a Google Review ↗",
        "ya_respondido":   "Thank you! We already recorded your feedback.",
        "queja_titulo":    "We're sorry your experience wasn't perfect.",
        "queja_label":     "Tell us what we can improve (private, not published):",
        "queja_placeholder": "Write your comment here...",
        "queja_cta":       "Send feedback",
        "gracias_pos":     "Thank you for sharing your Google review!",
        "gracias_neg":     "Thank you for letting us know. We'll review it privately.",
        "cerrar":          "You can close this window.",
        "btn_enviar":      "Submit rating",
        "extremo_min":     "Very poor",
        "extremo_max":     "Excellent",
        "aviso_privacidad": "Your response is confidential and helps us improve.",
        "max_chars":       "Max 1000 characters",
        "skip_text":       "If you prefer not to comment, you can close this window.",
        "error_rating":    "Please select a rating.",
    },
    "pt": {
        "cta_google":      "Deixar avaliação no Google ↗",
        "ya_respondido":   "Obrigado! Já registramos sua opinião.",
        "queja_titulo":    "Lamentamos que sua experiência não foi perfeita.",
        "queja_label":     "Conte-nos o que podemos melhorar (privado, não publicado):",
        "queja_placeholder": "Escreva seu comentário aqui...",
        "queja_cta":       "Enviar comentário",
        "gracias_pos":     "Obrigado por compartilhar sua avaliação no Google!",
        "gracias_neg":     "Obrigado por nos contar. Analisaremos de forma privada.",
        "cerrar":          "Você pode fechar esta janela.",
        "btn_enviar":      "Enviar avaliação",
        "extremo_min":     "Muito ruim",
        "extremo_max":     "Excelente",
        "aviso_privacidad": "Sua resposta é confidencial e nos ajuda a melhorar.",
        "max_chars":       "Máximo 1000 caracteres",
        "skip_text":       "Se preferir não comentar, pode fechar esta janela.",
        "error_rating":    "Por favor, selecione uma avaliação.",
    },
    "fr": {
        "cta_google":      "Laisser un avis sur Google ↗",
        "ya_respondido":   "Merci ! Nous avons bien enregistré votre avis.",
        "queja_titulo":    "Nous sommes désolés que votre expérience n'ait pas été parfaite.",
        "queja_label":     "Dites-nous ce que nous pouvons améliorer (privé, non publié) :",
        "queja_placeholder": "Écrivez votre commentaire ici...",
        "queja_cta":       "Envoyer mon commentaire",
        "gracias_pos":     "Merci d'avoir partagé votre avis sur Google !",
        "gracias_neg":     "Merci de nous avoir informés. Nous examinerons cela en privé.",
        "cerrar":          "Vous pouvez fermer cette fenêtre.",
        "btn_enviar":      "Envoyer ma note",
        "extremo_min":     "Très mauvais",
        "extremo_max":     "Excellent",
        "aviso_privacidad": "Votre réponse est confidentielle et nous aide à progresser.",
        "max_chars":       "Maximum 1000 caractères",
        "skip_text":       "Si vous préférez ne pas commenter, vous pouvez fermer cette fenêtre.",
        "error_rating":    "Veuillez sélectionner une note.",
    },
    "de": {
        "cta_google":      "Bewertung auf Google abgeben ↗",
        "ya_respondido":   "Danke! Wir haben Ihre Meinung bereits erfasst.",
        "queja_titulo":    "Es tut uns leid, dass Ihre Erfahrung nicht perfekt war.",
        "queja_label":     "Sagen Sie uns, was wir verbessern können (privat, wird nicht veröffentlicht):",
        "queja_placeholder": "Schreiben Sie Ihren Kommentar hier...",
        "queja_cta":       "Kommentar senden",
        "gracias_pos":     "Vielen Dank, dass Sie Ihre Google-Bewertung geteilt haben!",
        "gracias_neg":     "Vielen Dank für Ihr Feedback. Wir werden es vertraulich prüfen.",
        "cerrar":          "Sie können dieses Fenster schließen.",
        "btn_enviar":      "Bewertung abschicken",
        "extremo_min":     "Sehr schlecht",
        "extremo_max":     "Ausgezeichnet",
        "aviso_privacidad": "Ihre Antwort ist vertraulich und hilft uns, uns zu verbessern.",
        "max_chars":       "Maximal 1000 Zeichen",
        "skip_text":       "Wenn Sie keinen Kommentar abgeben möchten, können Sie dieses Fenster schließen.",
        "error_rating":    "Bitte wählen Sie eine Bewertung aus.",
    },
}

# Contenido específico por tipo de negocio (titulo, subtitulo, pregunta, color Tailwind, emoji)
_TEXTOS_POR_TIPO = {
    "HOTEL": {
        "es": {"titulo": "¿Cómo estuvo tu estadía?",          "subtitulo": "Tu experiencia como huésped nos importa.",    "pregunta": "¿Cómo calificarías tu estadía?",     "emoji": "🏨"},
        "en": {"titulo": "How was your stay?",                 "subtitulo": "Your guest experience matters to us.",        "pregunta": "How would you rate your stay?",      "emoji": "🏨"},
        "pt": {"titulo": "Como foi sua estadia?",              "subtitulo": "Sua experiência como hóspede importa muito.", "pregunta": "Como você avaliaria sua estadia?",    "emoji": "🏨"},
        "fr": {"titulo": "Comment était votre séjour ?",       "subtitulo": "Votre expérience d'hôte nous importe.",      "pregunta": "Comment évalueriez-vous votre séjour ?", "emoji": "🏨"},
        "de": {"titulo": "Wie war Ihr Aufenthalt?",            "subtitulo": "Ihre Erfahrung als Gast ist uns wichtig.",   "pregunta": "Wie würden Sie Ihren Aufenthalt bewerten?", "emoji": "🏨"},
        "color": "indigo",
    },
    "TOUR": {
        "es": {"titulo": "¿Cómo fue tu excursión?",            "subtitulo": "Tu aventura, tu opinión.",                   "pregunta": "¿Cómo calificarías tu excursión?",   "emoji": "🌿"},
        "en": {"titulo": "How was your tour?",                 "subtitulo": "Your adventure, your review.",               "pregunta": "How would you rate your tour?",      "emoji": "🌿"},
        "pt": {"titulo": "Como foi seu passeio?",              "subtitulo": "Sua aventura, sua opinião.",                 "pregunta": "Como você avaliaria seu passeio?",    "emoji": "🌿"},
        "fr": {"titulo": "Comment était votre excursion ?",    "subtitulo": "Votre aventure, votre avis.",                "pregunta": "Comment évalueriez-vous votre excursion ?", "emoji": "🌿"},
        "de": {"titulo": "Wie war Ihr Ausflug?",               "subtitulo": "Ihr Abenteuer, Ihre Meinung.",               "pregunta": "Wie würden Sie Ihren Ausflug bewerten?", "emoji": "🌿"},
        "color": "emerald",
    },
    "TRANSFER": {
        "es": {"titulo": "¿Cómo fue tu traslado?",             "subtitulo": "Puntualidad y comodidad, siempre.",          "pregunta": "¿Cómo calificarías tu traslado?",    "emoji": "🚐"},
        "en": {"titulo": "How was your transfer?",             "subtitulo": "Punctuality and comfort, always.",           "pregunta": "How would you rate your transfer?",  "emoji": "🚐"},
        "pt": {"titulo": "Como foi seu traslado?",             "subtitulo": "Pontualidade e conforto, sempre.",           "pregunta": "Como você avaliaria seu traslado?",   "emoji": "🚐"},
        "fr": {"titulo": "Comment était votre transfert ?",    "subtitulo": "Ponctualité et confort, toujours.",          "pregunta": "Comment évalueriez-vous votre transfert ?", "emoji": "🚐"},
        "de": {"titulo": "Wie war Ihr Transfer?",              "subtitulo": "Pünktlichkeit und Komfort, immer.",          "pregunta": "Wie würden Sie Ihren Transfer bewerten?", "emoji": "🚐"},
        "color": "sky",
    },
    "ALQUILER": {
        "es": {"titulo": "¿Cómo estuvo tu alquiler?",          "subtitulo": "Tu experiencia al volante nos importa.",    "pregunta": "¿Cómo calificarías tu experiencia?", "emoji": "🚗"},
        "en": {"titulo": "How was your rental?",               "subtitulo": "Your experience on the road matters.",      "pregunta": "How would you rate your experience?", "emoji": "🚗"},
        "pt": {"titulo": "Como foi sua locação?",              "subtitulo": "Sua experiência ao volante importa.",       "pregunta": "Como você avaliaria sua locação?",    "emoji": "🚗"},
        "fr": {"titulo": "Comment était votre location ?",     "subtitulo": "Votre expérience de conduite nous importe.", "pregunta": "Comment évalueriez-vous votre location ?", "emoji": "🚗"},
        "de": {"titulo": "Wie war Ihre Fahrzeuganmietung?",    "subtitulo": "Ihre Fahrerfahrung ist uns wichtig.",       "pregunta": "Wie würden Sie Ihre Anmietung bewerten?", "emoji": "🚗"},
        "color": "violet",
    },
    "RESTO": {
        "es": {"titulo": "¿Cómo estuvo tu visita?",            "subtitulo": "Tu paladar es nuestra guía.",               "pregunta": "¿Cómo calificarías tu experiencia?", "emoji": "🍽️"},
        "en": {"titulo": "How was your visit?",                "subtitulo": "Your taste is our guide.",                  "pregunta": "How would you rate your experience?", "emoji": "🍽️"},
        "pt": {"titulo": "Como foi sua visita?",               "subtitulo": "Seu paladar é nosso guia.",                 "pregunta": "Como você avaliaria sua visita?",      "emoji": "🍽️"},
        "fr": {"titulo": "Comment était votre visite ?",       "subtitulo": "Votre palais est notre guide.",             "pregunta": "Comment évalueriez-vous votre visite ?", "emoji": "🍽️"},
        "de": {"titulo": "Wie war Ihr Besuch?",                "subtitulo": "Ihr Geschmack ist unser Leitfaden.",        "pregunta": "Wie würden Sie Ihren Besuch bewerten?", "emoji": "🍽️"},
        "color": "orange",
    },
}


def _textos_portal(idioma: str, tipo_negocio: str) -> dict:
    """Construye el diccionario de textos del portal fusionando base + tipo."""
    base       = _TEXTOS_PORTAL_BASE.get(idioma, _TEXTOS_PORTAL_BASE["es"]).copy()
    tipo_map   = _TEXTOS_POR_TIPO.get(tipo_negocio, _TEXTOS_POR_TIPO["HOTEL"])
    tipo_lang  = tipo_map.get(idioma, tipo_map.get("es", {}))
    color      = tipo_map.get("color", "indigo")
    return {**base, **tipo_lang, "color": color}


def _get_idioma(request) -> str:
    lang = request.GET.get("lang", "es")[:2].lower()
    return lang if lang in _IDIOMAS_VALIDOS else "es"


def portal_feedback(request, comercio_id: uuid.UUID, token_feedback: uuid.UUID):
    """Página de valoración 1–5 estrellas que recibe el turista por email.

    GET  → Muestra la grilla de estrellas.
    POST → Guarda la calificación y redirige:
             calificacion >= 4 → Google Reviews (reseña pública).
             calificacion <= 3 → formulario privado de queja.

    Si el token ya fue respondido muestra un mensaje de confirmación y no
    permite doble envío.
    """
    from django.utils import timezone

    config = get_object_or_404(
        ServicioFeedbackConfig.objects.select_related("organizacion"),
        id=comercio_id,
        estado_suscripcion__in=[EstadoSuscripcion.ACTIVO, EstadoSuscripcion.DEMO],
    )
    idioma  = _get_idioma(request)
    textos  = _textos_portal(idioma, config.tipo_negocio)

    respuesta, _ = RespuestaFeedback.objects.get_or_create(
        config=config,
        token_feedback=token_feedback,
    )

    # ── Ya respondido: mostrar confirmación sin permitir re-envío ──────
    if respuesta.calificacion is not None:
        return render(request, "servicios/feedback/gracias.html", {
            "config": config, "respuesta": respuesta,
            "idioma": idioma,  "textos": textos,
        })

    # ── POST: registrar calificación ────────────────────────────────────
    if request.method == "POST":
        try:
            calificacion = int(request.POST["calificacion"])
            if not 1 <= calificacion <= 5:
                raise ValueError
        except (KeyError, ValueError, TypeError):
            return render(request, "servicios/feedback/portal.html", {
                "config": config, "idioma": idioma, "textos": textos, "error": True,
            })

        respuesta.calificacion  = calificacion
        respuesta.respondido_at = timezone.now()

        if calificacion >= 4:
            respuesta.redirigido_a_google = True
            respuesta.save()
            logger.info(
                "Feedback positivo | config=%s | stars=%s → Google Reviews",
                config.id, calificacion,
            )
            return redirect(config.google_review_link)

        respuesta.save()
        logger.info(
            "Feedback negativo contenido | config=%s | stars=%s",
            config.id, calificacion,
        )

        # Alerta crítica: solo 1 y 2 estrellas → notificación inmediata
        if calificacion <= _UMBRAL_ALERTA_CRITICA:
            _disparar_alerta_critica_(respuesta, config)

        from django.urls import reverse as _reverse
        queja_url = _reverse(
            "servicios:queja-feedback",
            kwargs={"comercio_id": comercio_id, "token_feedback": token_feedback},
        ) + f"?lang={idioma}"
        return redirect(queja_url)

    return render(request, "servicios/feedback/portal.html", {
        "config": config, "idioma": idioma, "textos": textos,
    })


def queja_feedback(request, comercio_id: uuid.UUID, token_feedback: uuid.UUID):
    """Formulario privado para calificaciones 1–3.  Nunca llega a Google.

    POST: guarda ``comentario_turista``, llama al Copiloto IA para generar
    ``borrador_respuesta_ia`` y marca ``estado_copiloto = PENDIENTE``.
    Si la IA falla, el comentario se guarda igual y el borrador queda vacío.
    """
    config = get_object_or_404(
        ServicioFeedbackConfig.objects.select_related("organizacion"),
        id=comercio_id,
    )
    respuesta = get_object_or_404(
        RespuestaFeedback,
        config=config,
        token_feedback=token_feedback,
        calificacion__lte=3,
    )
    idioma = _get_idioma(request)
    textos = _textos_portal(idioma, config.tipo_negocio)

    # Considera el comentario enviado si ya se guardó en cualquiera de los
    # dos campos (retrocompatibilidad con registros previos a esta versión).
    ya_enviado = bool(respuesta.comentario_turista or respuesta.comentario)

    if request.method == "POST" and not ya_enviado:
        comentario = request.POST.get("comentario", "").strip()
        if comentario:

            # ── Copiloto IA: generar borrador de respuesta ───────────────
            # Llamada al servicio de IA. Si falla por cualquier motivo
            # devuelve "" — el flujo continúa sin error visible al turista.
            borrador = generar_borrador_respuesta(
                comentario=comentario,
                nombre_comercio=config.organizacion.nombre,
                idioma=idioma,
            )

            # ── Persistencia (un único save con todos los campos) ────────
            respuesta.comentario           = comentario   # retrocompatibilidad
            respuesta.comentario_turista   = comentario   # Copiloto IA: input
            respuesta.borrador_respuesta_ia = borrador    # Copiloto IA: output
            respuesta.estado_copiloto      = EstadoCopiloto.PENDIENTE
            respuesta.save(update_fields=[
                "comentario",
                "comentario_turista",
                "borrador_respuesta_ia",
                "estado_copiloto",
            ])

            ya_enviado = True
            logger.info(
                "Queja + Copiloto IA | config=%s | stars=%s | chars=%s | borrador_ok=%s",
                config.id,
                respuesta.calificacion,
                len(comentario),
                bool(borrador),
            )

    return render(request, "servicios/feedback/queja.html", {
        "config": config, "respuesta": respuesta,
        "idioma": idioma,  "textos": textos, "ya_enviado": ya_enviado,
    })


# ---------------------------------------------------------------------------
# Vista 7: Stats API para el Informe Semanal de Google Apps Script
# ---------------------------------------------------------------------------


@csrf_exempt
@require_GET
def stats_feedback(request) -> JsonResponse:
    """Devuelve métricas de respuestas para el informe semanal.

    Misma autenticación que ``validar_comercio`` (comercio_id + token).
    Query params adicionales:
        dias  Ventana de tiempo en días (default 7, max 90).

    Returns:
        200  ``{ total_respuestas, positivas, contenidas, redirigidas_a_google }``
        401  Credenciales inválidas.
    """
    from django.utils import timezone

    comercio_id_raw = request.GET.get("comercio_id", "")
    token_raw       = request.GET.get("token", "")
    dias            = min(abs(int(request.GET.get("dias", 7))), 90)

    try:
        comercio_uuid = uuid.UUID(comercio_id_raw)
    except (ValueError, AttributeError):
        return _json_401()

    config_s: ServicioFeedbackConfig | None = None
    token_real = _TOKEN_DUMMY
    try:
        config_s   = ServicioFeedbackConfig.objects.get(id=comercio_uuid)
        token_real = str(config_s.api_token)
    except ServicioFeedbackConfig.DoesNotExist:
        pass

    if not secrets.compare_digest(token_real, token_raw) or config_s is None:
        return _json_401()

    desde = timezone.now() - timezone.timedelta(days=dias)
    qs    = RespuestaFeedback.objects.filter(config=config_s, created_at__gte=desde)

    return JsonResponse({
        "total_respuestas":    qs.filter(calificacion__isnull=False).count(),
        "positivas":           qs.filter(calificacion__gte=4).count(),
        "contenidas":          qs.filter(calificacion__lte=3).count(),
        "redirigidas_a_google": qs.filter(redirigido_a_google=True).count(),
    }, **_JSON_OPTS)


# ---------------------------------------------------------------------------
# Vista 8–9: Alertas Críticas (calificacion <= 2)
# ---------------------------------------------------------------------------

_UMBRAL_ALERTA_CRITICA = 2   # solo 1 y 2 estrellas disparan alerta urgente
_HORAS_VENTANA_ALERTAS = 48  # GAS puede estar hasta 48h sin correr (fallback)


def _disparar_alerta_critica_(respuesta: RespuestaFeedback, config: ServicioFeedbackConfig) -> None:
    """Envía email urgente al dueño del comercio cuando un turista da 1-2 estrellas.

    Se llama de forma SÍNCRONA desde ``portal_feedback`` justo después de
    guardar la calificación.  Si el envío falla (ej. EMAIL_BACKEND no
    configurado), loggea el error sin interrumpir el flujo del turista.

    Configuración requerida en settings / .env:
        EMAIL_HOST, EMAIL_PORT, EMAIL_HOST_USER, EMAIL_HOST_PASSWORD,
        DEFAULT_FROM_EMAIL   (o EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend' en dev)
    """
    email_destino = getattr(config.organizacion.usuario_principal, "email", None)
    if not email_destino:
        logger.warning(
            "Alerta crítica sin destinatario: usuario_principal sin email | config=%s",
            config.id,
        )
        return

    stars_display = "★" * respuesta.calificacion + "☆" * (5 - respuesta.calificacion)
    ctx = {
        "config":         config,
        "respuesta":      respuesta,
        "stars_display":  stars_display,
        "token_feedback": str(respuesta.token_feedback),
    }
    html_body  = render_to_string("servicios/email/alerta_critica.html", ctx)
    texto_plano = (
        f"ALERTA CRÍTICA — {config.organizacion.nombre}\n\n"
        f"Calificación: {stars_display} ({respuesta.calificacion}/5)\n"
        f"Comentario:   {respuesta.comentario or 'Sin comentario'}\n\n"
        f"Revisá tu Google Sheet buscando el Token: {respuesta.token_feedback}\n"
    )

    try:
        msg = EmailMultiAlternatives(
            subject=f"🚨 Alerta crítica — {respuesta.calificacion}★ en {config.organizacion.nombre}",
            body=texto_plano,
            from_email=None,         # usa settings.DEFAULT_FROM_EMAIL
            to=[email_destino],
        )
        msg.attach_alternative(html_body, "text/html")
        msg.send(fail_silently=False)

        respuesta.alerta_email_at = timezone.now()
        respuesta.save(update_fields=["alerta_email_at"])
        logger.info(
            "Alerta crítica email enviada | config=%s | stars=%s → %s",
            config.id, respuesta.calificacion, email_destino,
        )
    except Exception as exc:
        logger.error(
            "Error enviando alerta crítica email | config=%s | %s",
            config.id, exc,
        )


@csrf_exempt
@require_GET
def alertas_criticas_api(request) -> JsonResponse:
    """Lista las alertas críticas pendientes de despacho por WhatsApp.

    Consumido por ``AlertasCriticas.gs`` cada 30 minutos.
    Misma autenticación que ``validar_comercio``.

    Devuelve respuestas con calificacion <= 2 de las últimas 48 horas
    cuyo ``alerta_whatsapp_at`` todavía sea NULL.

    Returns:
        200  ``{ "alertas": [...] }``
        401  Credenciales inválidas.
    """
    comercio_id_raw = request.GET.get("comercio_id", "")
    token_raw       = request.GET.get("token", "")

    try:
        comercio_uuid = uuid.UUID(comercio_id_raw)
    except (ValueError, AttributeError):
        return _json_401()

    config_a: ServicioFeedbackConfig | None = None
    token_real = _TOKEN_DUMMY
    try:
        config_a   = ServicioFeedbackConfig.objects.get(id=comercio_uuid)
        token_real = str(config_a.api_token)
    except ServicioFeedbackConfig.DoesNotExist:
        pass

    if not secrets.compare_digest(token_real, token_raw) or config_a is None:
        return _json_401()

    ventana  = timezone.now() - timezone.timedelta(hours=_HORAS_VENTANA_ALERTAS)
    alertas  = (
        RespuestaFeedback.objects
        .filter(
            config=config_a,
            calificacion__lte=_UMBRAL_ALERTA_CRITICA,
            respondido_at__gte=ventana,
            alerta_whatsapp_at__isnull=True,
        )
        .order_by("respondido_at")
    )

    return JsonResponse({
        "alertas": [
            {
                "id":              str(a.id),
                "token_feedback":  str(a.token_feedback),
                "calificacion":    a.calificacion,
                "comentario":      a.comentario,
                "respondido_at":   a.respondido_at.isoformat() if a.respondido_at else None,
                "email_ya_enviado": bool(a.alerta_email_at),
            }
            for a in alertas
        ]
    }, **_JSON_OPTS)


@csrf_exempt
def ack_alertas_whatsapp(request) -> JsonResponse:
    """Marca alertas como notificadas por WhatsApp.

    POST body (JSON): ``{ "ids": ["uuid1", "uuid2", ...] }``
    Misma autenticación que ``validar_comercio`` (query params).

    Returns:
        200  ``{ "actualizadas": N }``
        400  Body malformado.
        401  Credenciales inválidas.
    """
    import json as _json

    if request.method != "POST":
        return JsonResponse({"detail": "Solo POST."}, status=405)

    comercio_id_raw = request.GET.get("comercio_id", "")
    token_raw       = request.GET.get("token", "")

    try:
        comercio_uuid = uuid.UUID(comercio_id_raw)
    except (ValueError, AttributeError):
        return _json_401()

    config_w: ServicioFeedbackConfig | None = None
    token_real = _TOKEN_DUMMY
    try:
        config_w   = ServicioFeedbackConfig.objects.get(id=comercio_uuid)
        token_real = str(config_w.api_token)
    except ServicioFeedbackConfig.DoesNotExist:
        pass

    if not secrets.compare_digest(token_real, token_raw) or config_w is None:
        return _json_401()

    try:
        body = _json.loads(request.body)
        ids  = [uuid.UUID(i) for i in body.get("ids", [])]
    except (ValueError, KeyError, TypeError):
        return JsonResponse({"detail": "Body inválido. Se espera {ids: [uuid,...]}."}, status=400)

    actualizadas = RespuestaFeedback.objects.filter(
        config=config_w, id__in=ids, alerta_whatsapp_at__isnull=True
    ).update(alerta_whatsapp_at=timezone.now())

    logger.info(
        "ACK WhatsApp alertas | config=%s | actualizadas=%s",
        config_w.id, actualizadas,
    )
    return JsonResponse({"actualizadas": actualizadas}, **_JSON_OPTS)


# ---------------------------------------------------------------------------
# Control de licencias — billing engine invisible
# ---------------------------------------------------------------------------

_FMT_FECHA = "%d/%m/%Y"


@csrf_exempt
@require_GET
def validar_licencia_externa(request) -> JsonResponse:
    """Valida si una licencia de Feedback está activa y dentro de vigencia.

    Consumido por Google Apps Script o Google Forms vía UrlFetchApp, como
    primera comprobación antes de ejecutar cualquier automatización.

    GET /api/v1/licencias/validar/?id_comercio=HOTEL-TERRAZAS-01

    Flujo de decisión:
        1. Parámetro ausente o vacío       → HTTP 400  (error de integración)
        2. ``id_comercio`` no existe       → HTTP 401  (licencia inexistente)
        3. ``esta_activa == False``        → HTTP 403  (suspendida por DM Global)
        4. ``fecha_vencimiento`` < hoy     → HTTP 403  (suscripción vencida)
        5. Todo en orden                   → HTTP 200  (autorizado)

    Nota:
        Los códigos 401 y 403 revelan distinta información (existe vs no existe).
        Esto es aceptable porque ``id_comercio`` es un identificador semipúblico,
        no un secreto criptográfico.  Ver docstring de ``LicenciaFeedback``.

    Returns:
        200  ``{"autorizado": true}``
        400  ``{"autorizado": false, "error": "..."}``
        401  ``{"autorizado": false, "error": "Licencia inexistente."}``
        403  ``{"autorizado": false, "error": "..."}``
        405  Método no permitido (gestionado por ``@require_GET``)
    """
    id_comercio: str = request.GET.get("id_comercio", "").strip()
    ip_origen: str   = request.META.get("REMOTE_ADDR", "desconocida")

    # ── Paso 1: parámetro requerido ────────────────────────────────────
    if not id_comercio:
        return JsonResponse(
            {"autorizado": False, "error": "Parámetro id_comercio requerido."},
            status=400,
            **_JSON_OPTS,
        )

    # ── Paso 2: existencia de la licencia ──────────────────────────────
    try:
        licencia = LicenciaFeedback.objects.get(pk=id_comercio)
    except LicenciaFeedback.DoesNotExist:
        logger.warning(
            "Licencia inexistente consultada | id=%r | ip=%s",
            id_comercio, ip_origen,
        )
        return JsonResponse(
            {"autorizado": False, "error": "Licencia inexistente."},
            status=401,
            **_JSON_OPTS,
        )

    # ── Paso 3: servicio activo ────────────────────────────────────────
    if not licencia.esta_activa:
        logger.info("Licencia pausada consultada | id=%s | ip=%s", id_comercio, ip_origen)
        return JsonResponse(
            {
                "autorizado": False,
                "error": "Servicio suspendido. Contacta a DM Global para reactivarlo.",
            },
            status=403,
            **_JSON_OPTS,
        )

    # ── Paso 4: vigencia de la suscripción ────────────────────────────
    hoy = timezone.now().date()
    if licencia.fecha_vencimiento < hoy:
        logger.info(
            "Licencia vencida consultada | id=%s | vencimiento=%s | ip=%s",
            id_comercio, licencia.fecha_vencimiento, ip_origen,
        )
        return JsonResponse(
            {
                "autorizado": False,
                "error": (
                    f"Suscripcion vencida el "
                    f"{licencia.fecha_vencimiento.strftime(_FMT_FECHA)}. "
                    "Renueva en DM Global."
                ),
            },
            status=403,
            **_JSON_OPTS,
        )

    # ── Paso 5: todo en orden ─────────────────────────────────────────
    logger.info("Licencia validada OK | id=%s | vence=%s", id_comercio, licencia.fecha_vencimiento)
    return JsonResponse({"autorizado": True}, status=200, **_JSON_OPTS)
