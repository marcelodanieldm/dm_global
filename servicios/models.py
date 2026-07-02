"""
Modelos del Add-on "Servicio de Feedback" para el CRM DM Global.

Cada ``Organizacion`` (Tenant) puede tener como máximo una
``ServicioFeedbackConfig``, gestionada con una relación OneToOne.
Google Apps Script se autentica contra el endpoint de validación
usando ``comercio_id`` (PK de la config) + ``api_token``.
"""
import datetime
import uuid

from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models


# ---------------------------------------------------------------------------
# Enumeraciones
# ---------------------------------------------------------------------------


class EstadoSuscripcion(models.TextChoices):
    """Ciclo de vida de la suscripción al servicio."""

    ACTIVO = "ACTIVO", "Activo"
    INACTIVO = "INACTIVO", "Inactivo"
    DEMO = "DEMO", "Demo"


class TipoNegocio(models.TextChoices):
    """Sector al que pertenece el comercio suscripto."""

    HOTEL    = "HOTEL",    "Alojamiento / Hotel"
    TOUR     = "TOUR",     "Excursiones / Tour Operador"
    TRANSFER = "TRANSFER", "Traslados / Transfer"
    ALQUILER = "ALQUILER", "Alquiler de Vehículos"
    RESTO    = "RESTO",    "Restaurante / Gastronomía"


# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------


class Organizacion(models.Model):
    """
    Tenant base de la plataforma.

    Cada organización agrupa todos los servicios y configuraciones
    que DM Global provee a un cliente comercial.

    Relación con usuarios:
        ``usuario_principal`` es la cuenta del CRM que administra esta
        organización.  La FK usa ``related_name="organizacion"`` para que
        ``request.user.organizacion`` devuelva directamente el objeto
        ``Organizacion`` en las vistas protegidas con ``@login_required``.

        Si en el futuro una org necesita múltiples usuarios, reemplazá este
        campo por una tabla intermedia ``OrganizacionUsuario(ManyToMany)``.
    """

    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name="ID",
        help_text="Identificador único generado automáticamente.",
    )
    usuario_principal = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="organizacion",
        verbose_name="Usuario principal",
        help_text=(
            "Cuenta del CRM con acceso al panel de esta organización. "
            "Genera el acceso mediante request.user.organizacion."
        ),
    )
    nombre = models.CharField(
        max_length=255,
        verbose_name="Nombre",
    )
    activa = models.BooleanField(
        default=True,
        verbose_name="Activa",
        help_text="Desactivar en vez de eliminar para preservar el historial.",
    )
    created_at = models.DateTimeField(
        auto_now_add=True,
        verbose_name="Fecha de creación",
    )

    class Meta:
        verbose_name = "Organización"
        verbose_name_plural = "Organizaciones"
        ordering = ["nombre"]

    def __str__(self) -> str:
        return self.nombre


class ServicioFeedbackConfig(models.Model):
    """
    Configuración 1:1 del Add-on de Feedback para una Organización.

    Almacena las credenciales de integración (``api_token``, links de
    Google) y el estado de suscripción vigente.  Google Apps Script
    accede al endpoint de validación con ``id`` + ``api_token``;
    ambos campos son de solo lectura en el admin para que el operador
    pueda copiarlos sin modificarlos accidentalmente.

    Nota sobre ``ultima_sincronizacion``:
        Se define con ``auto_now=True``, lo que significa que Django la
        actualiza en **cada** ``save()``, ya sea desde el admin o desde
        la API.  Si en el futuro se necesita registrar únicamente las
        llamadas exitosas de Apps Script, reemplazá ``auto_now=True``
        por ``null=True, blank=True`` y actualizá el campo manualmente
        en la vista de validación con::

            from django.utils import timezone
            config.ultima_sincronizacion = timezone.now()
            config.save(update_fields=["ultima_sincronizacion"])
    """

    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name="ID de la configuración",
        help_text=(
            "UUID autogenerado que identifica esta config. "
            "Se entrega al cliente como 'comercio_id' para el Google Sheet."
        ),
    )
    organizacion = models.OneToOneField(
        Organizacion,
        on_delete=models.CASCADE,
        related_name="feedback_config",
        verbose_name="Organización",
    )
    estado_suscripcion = models.CharField(
        max_length=10,
        choices=EstadoSuscripcion.choices,
        default=EstadoSuscripcion.INACTIVO,
        verbose_name="Estado de suscripción",
    )
    tipo_negocio = models.CharField(
        max_length=10,
        choices=TipoNegocio.choices,
        verbose_name="Tipo de negocio",
    )
    google_sheet_url = models.URLField(
        blank=True,
        null=True,
        verbose_name="URL de Google Sheet",
        help_text=(
            "Enlace a la planilla del cliente donde se procesan las reseñas. "
            "Debe ser un enlace de Google Sheets (docs.google.com/spreadsheets)."
        ),
    )
    google_review_link = models.URLField(
        verbose_name="Link de reseña Google",
        help_text="URL directa a la página de reseñas en Google Maps del comercio.",
    )
    api_token = models.UUIDField(
        default=uuid.uuid4,
        unique=True,
        editable=False,
        verbose_name="API Token",
        help_text=(
            "Token secreto autogenerado. Se entrega al cliente junto con 'id' "
            "para configurar la autenticación en el Google Apps Script."
        ),
    )
    ultima_sincronizacion = models.DateTimeField(
        # auto_now=True: se actualiza en cada save(), incluyendo ediciones
        # del admin. Ver docstring de la clase para la alternativa manual.
        auto_now=True,
        verbose_name="Última sincronización",
    )
    created_at = models.DateTimeField(
        auto_now_add=True,
        verbose_name="Fecha de creación",
    )

    class Meta:
        verbose_name = "Configuración de Feedback"
        verbose_name_plural = "Configuraciones de Feedback"
        ordering = ["organizacion__nombre"]

    def __str__(self) -> str:
        return (
            f"{self.organizacion.nombre} "
            f"[{self.get_tipo_negocio_display()} · "
            f"{self.get_estado_suscripcion_display()}]"
        )

    @property
    def total_respuestas(self) -> int:
        return self.respuestas.filter(calificacion__isnull=False).count()

    @property
    def total_positivas(self) -> int:
        return self.respuestas.filter(calificacion__gte=4).count()

    @property
    def total_contenidas(self) -> int:
        return self.respuestas.filter(calificacion__lte=3).count()

    def clean(self) -> None:
        """
        Validaciones de negocio de ``ServicioFeedbackConfig``.

        Se ejecuta automáticamente desde el admin de Django y desde
        cualquier ``ModelForm``.  Para dispararla en código propio usá::

            config.full_clean()

        Reglas:
        1. ``google_sheet_url``, si se completa, debe ser un enlace
           de Google Sheets válido.
        2. ``google_review_link`` es obligatorio cuando el estado es
           ``ACTIVO`` o ``DEMO``; sin él el widget de feedback no
           puede redirigir al cliente.
        """
        errores: dict[str, str] = {}

        # Regla 1: Google Sheet URL debe apuntar a Sheets si se provee.
        if (
            self.google_sheet_url
            and "docs.google.com/spreadsheets" not in self.google_sheet_url
        ):
            errores["google_sheet_url"] = (
                "Ingresá un enlace válido de Google Sheets. "
                "Debe contener 'docs.google.com/spreadsheets'."
            )

        # Regla 2: activar el servicio sin link de reseña es incoherente.
        estados_activos = {EstadoSuscripcion.ACTIVO, EstadoSuscripcion.DEMO}
        if self.estado_suscripcion in estados_activos and not self.google_review_link:
            errores["google_review_link"] = (
                "El link de reseña de Google es obligatorio "
                "para activar o poner en DEMO el servicio."
            )

        if errores:
            raise ValidationError(errores)


# ---------------------------------------------------------------------------
# Portal de valoración del turista
# ---------------------------------------------------------------------------


class EstadoCopiloto(models.TextChoices):
    """Estado del flujo de Copiloto de Respuestas con IA."""

    PENDIENTE = "PENDIENTE", "Pendiente de Revisión"
    APROBADO  = "APROBADO",  "Aprobado y Enviado"


class RespuestaFeedback(models.Model):
    """Calificación, comentario y ciclo de Copiloto IA de un turista.

    Ciclo de vida completo:
        1. Google Apps Script genera un ``token_feedback`` (UUID) al aprobar
           el borrador y lo almacena en la columna TOKEN_FEEDBACK de
           la pestaña OPERACIONES.
        2. El email enviado al turista incluye el enlace::

               https://tucrm.com/feedback/{config.id}/{token_feedback}/

        3. El turista elige 1–5 estrellas en el portal de DM Global.
        4. calificacion >= 4 → se redirige a Google Reviews (reseña pública).
        5. calificacion <= 3 → se muestra el formulario privado y el
           comentario se guarda aquí, nunca expuesto en Google.

    Ciclo del Copiloto de Respuestas con IA (campos nuevos):
        a. El turista deja su opinión cruda en ``comentario_turista``.
        b. La IA genera un borrador de respuesta en ``borrador_respuesta_ia``.
        c. El operador lo revisa y aprueba → ``estado_copiloto = APROBADO``.
    """

    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name="ID",
    )
    config = models.ForeignKey(
        ServicioFeedbackConfig,
        on_delete=models.CASCADE,
        related_name="respuestas",
        verbose_name="Configuración del comercio",
    )
    token_feedback = models.UUIDField(
        unique=True,
        verbose_name="Token de feedback",
        help_text="UUID generado por Google Apps Script. Identifica el envío.",
    )
    calificacion = models.IntegerField(
        null=True,
        blank=True,
        verbose_name="Calificacion (1–5)",
        help_text="Null hasta que el turista responde el portal.",
    )
    comentario = models.TextField(
        blank=True,
        verbose_name="Comentario privado",
        help_text="Solo para calificaciones de 1 a 3 estrellas (nunca llega a Google).",
    )
    redirigido_a_google = models.BooleanField(
        default=False,
        verbose_name="Redirigido a Google Reviews",
    )
    respondido_at = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name="Fecha de respuesta",
    )
    # ── Auditoría de alertas críticas ──────────────────────────────────
    # Se rellenan exclusivamente para calificacion <= 2.
    # Null = alerta aún no despachada por ese canal.
    alerta_email_at = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name="Alerta email enviada",
        help_text="Instante en que Django envió el correo urgente al comercio.",
    )
    alerta_whatsapp_at = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name="Alerta WhatsApp enviada",
        help_text="Instante en que Google Apps Script despachó el WhatsApp urgente.",
    )

    # ── Copiloto de Respuestas con IA ─────────────────────────────────────
    # Alimenta el flujo de revisión asistida: el turista comenta →
    # la IA genera un borrador → el operador aprueba y envía.
    # Los tres campos son opcionales (null/blank) para no romper el flujo
    # existente de calificaciones sin comentario.

    comentario_turista = models.TextField(
        blank=True,
        null=True,
        verbose_name="Comentario del turista",
        help_text=(
            "Opinión cruda del turista ingresada en el formulario web. "
            "Fuente de entrada para el Copiloto de Respuestas con IA."
        ),
    )
    borrador_respuesta_ia = models.TextField(
        blank=True,
        null=True,
        verbose_name="Borrador de respuesta (IA)",
        help_text=(
            "Propuesta de respuesta generada automáticamente por el modelo de IA "
            "a partir de ``comentario_turista``. "
            "El operador la revisa y puede editarla antes de aprobar."
        ),
    )
    estado_copiloto = models.CharField(
        max_length=20,
        choices=EstadoCopiloto.choices,
        default=EstadoCopiloto.PENDIENTE,
        verbose_name="Estado Copiloto",
        help_text=(
            "PENDIENTE: el borrador fue generado pero aún no revisado. "
            "APROBADO: el operador lo revisó y autorizó el envío al turista."
        ),
    )

    created_at = models.DateTimeField(
        auto_now_add=True,
        verbose_name="Fecha de creación",
    )

    class Meta:
        verbose_name = "Respuesta de Feedback"
        verbose_name_plural = "Respuestas de Feedback"
        ordering = ["-created_at"]

    def __str__(self) -> str:
        estrellas = "★" * (self.calificacion or 0) if self.calificacion else "sin responder"
        return f"{self.config.organizacion.nombre} · {estrellas}"

    @property
    def es_positiva(self) -> bool:
        """True si la calificación es 4 o 5 estrellas."""
        return self.calificacion is not None and self.calificacion >= 4

    @property
    def es_queja(self) -> bool:
        """True si la calificación es 1, 2 o 3 estrellas (contenida internamente)."""
        return self.calificacion is not None and self.calificacion <= 3


# ---------------------------------------------------------------------------
# Control de licencias — billing engine invisible
# ---------------------------------------------------------------------------


class PasarelaPago(models.TextChoices):
    """Pasarela de pago que gestionó la última renovación de la licencia."""

    STRIPE      = "stripe",      "Stripe"
    MERCADOPAGO = "mp",          "Mercado Pago"
    MANUAL      = "manual",      "Manual (admin)"


class LicenciaFeedback(models.Model):
    """Licencia de suscripción para el Servicio de Feedback.

    Diseño deliberado de id_comercio como string legible:
        Los clientes operan 100% desde Google Sheets/Forms y pegan
        ``id_comercio`` en la pestaña CONFIG de su planilla
        (ej. ``'HOTEL-TERRAZAS-01'``).  Debe ser corto y reconocible,
        no un UUID.

    Integración con pasarelas de pago:
        Los webhooks de Stripe y Mercado Pago llaman a
        ``renovar_suscripcion()`` cuando procesan un cobro exitoso.
        El método extiende ``fecha_vencimiento`` y registra la pasarela.

        Stripe      → identifica al cliente con ``stripe_customer_id``
                      y la suscripción con ``stripe_subscription_id``.
        MercadoPago → identifica el débito automático con ``mp_preapproval_id``.

    Nota de migración:
        ``email_facturacion`` es NOT NULL en la BD.  Al correr
        ``makemigrations`` Django pedirá un valor por defecto para los
        registros existentes; ingresar el email del administrador o
        dejarlo en blanco (``''``) y actualizar los registros luego.
    """

    # ── Identificación ───────────────────────────────────────────────────────

    id_comercio = models.CharField(
        primary_key=True,
        max_length=50,
        verbose_name="ID de comercio",
        help_text=(
            "Identificador único legible por humanos (ej: HOTEL-TERRAZAS-01). "
            "El cliente lo pega en la pestaña CONFIG de su Google Sheet."
        ),
    )
    nombre_comercio = models.CharField(
        max_length=150,
        verbose_name="Nombre del comercio",
        help_text="Solo para uso interno del CRM. El cliente no lo ve.",
    )
    tipo_negocio = models.CharField(
        max_length=10,
        choices=TipoNegocio.choices,
        default=TipoNegocio.HOTEL,
        verbose_name="Tipo de negocio",
    )
    email_facturacion = models.EmailField(
        verbose_name="Email de facturación",
        help_text=(
            "Correo vinculado al pago en Stripe / Mercado Pago. "
            "Usado para auditoría, notificaciones de cobro y búsqueda rápida "
            "de licencias desde el panel de DM Global."
        ),
    )

    # ── Control de suscripción ───────────────────────────────────────────────

    esta_activa = models.BooleanField(
        default=True,
        verbose_name="Activa",
        help_text=(
            "Desactivar para pausar el servicio sin eliminar la licencia. "
            "El Apps Script recibirá HTTP 403 de inmediato. "
            "renovar_suscripcion() la reactiva automáticamente al cobrar."
        ),
    )
    fecha_vencimiento = models.DateField(
        verbose_name="Fecha de vencimiento",
        help_text=(
            "La licencia se bloquea desde este día (inclusive). "
            "Se extiende automáticamente +30 días cuando el webhook "
            "de Stripe o Mercado Pago procesa un cobro exitoso."
        ),
    )
    ultima_renovacion = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name="Última renovación",
        help_text=(
            "Fecha y hora del último cobro exitoso procesado por webhook. "
            "Null si la licencia fue creada manualmente y aún no cobró."
        ),
    )
    pasarela_activa = models.CharField(
        max_length=10,
        choices=PasarelaPago.choices,
        default=PasarelaPago.MANUAL,
        verbose_name="Pasarela activa",
        help_text="Pasarela que gestionó la última renovación exitosa.",
    )

    # ── IDs de Stripe ────────────────────────────────────────────────────────

    stripe_customer_id = models.CharField(
        max_length=100,
        blank=True,
        null=True,
        unique=True,
        verbose_name="Stripe Customer ID",
        help_text=(
            "ID del objeto Customer en Stripe (ej: cus_AbCdEfGhIjKl). "
            "Generado por Stripe al crear el cliente; guardado en el primer "
            "webhook de pago exitoso o al activar la suscripción. "
            "unique=True garantiza que no haya dos licencias con el mismo cliente."
        ),
    )
    stripe_subscription_id = models.CharField(
        max_length=100,
        blank=True,
        null=True,
        verbose_name="Stripe Subscription ID",
        help_text=(
            "ID de la suscripción activa en Stripe (ej: sub_XyZ123AbC). "
            "Se actualiza si el cliente cancela y crea una nueva suscripción. "
            "El webhook de Stripe lo incluye en cada evento de pago."
        ),
    )

    # ── IDs de Mercado Pago ──────────────────────────────────────────────────

    mp_preapproval_id = models.CharField(
        max_length=100,
        blank=True,
        null=True,
        verbose_name="MP Preapproval ID",
        help_text=(
            "ID del plan de débito automático en Mercado Pago "
            "(preapproval / suscripción recurrente). "
            "El webhook de authorized_payment incluye el preapproval_id "
            "que se usa para identificar a qué licencia aplicar la renovación."
        ),
    )

    # ── Auditoría ────────────────────────────────────────────────────────────

    created_at = models.DateTimeField(
        auto_now_add=True,
        verbose_name="Fecha de alta",
    )

    class Meta:
        verbose_name = "Licencia de Feedback"
        verbose_name_plural = "Licencias de Feedback"
        ordering = ["id_comercio"]
        indexes = [
            # Lookups frecuentes desde webhooks: buscar licencia por ID de pasarela
            models.Index(fields=["stripe_subscription_id"], name="idx_lic_stripe_sub"),
            models.Index(fields=["mp_preapproval_id"],      name="idx_lic_mp_pre"),
            models.Index(fields=["email_facturacion"],       name="idx_lic_email"),
        ]

    def __str__(self) -> str:
        estado = "Activa" if self.esta_activa else "Pausada"
        return f"{self.id_comercio} — {self.nombre_comercio} [{estado}]"

    # ── Propiedades computadas ───────────────────────────────────────────────

    @property
    def esta_vigente(self) -> bool:
        """True si la licencia está activa Y la fecha de vencimiento no pasó."""
        from django.utils import timezone
        return self.esta_activa and self.fecha_vencimiento >= timezone.now().date()

    @property
    def dias_restantes(self) -> int:
        """Días hasta el vencimiento (negativo si ya venció)."""
        from django.utils import timezone
        return (self.fecha_vencimiento - timezone.now().date()).days

    # ── Lógica de negocio ────────────────────────────────────────────────────

    def renovar_suscripcion(
        self,
        dias: int = 30,
        pasarela: str = PasarelaPago.MANUAL,
    ) -> None:
        """Extiende la vigencia de la licencia en ``dias`` días.

        Llamado automáticamente por los webhooks de Stripe y Mercado Pago
        cuando se procesa un cobro exitoso.

        Lógica de fecha base:
            ``max(hoy, fecha_vencimiento) + dias``

            Si el pago llega a tiempo: extiende desde el vencimiento actual
            (sin gap, la cobertura es continua).

            Si el pago llega tarde (licencia ya vencida): extiende desde hoy
            (no retrocede al período ya vencido).

        Efectos secundarios:
            · Reactiva la licencia si estaba pausada por mora (``esta_activa = True``).
            · Registra ``ultima_renovacion`` con el timestamp exacto del cobro.
            · Guarda con ``update_fields`` para evitar pisar cambios concurrentes.

        Args:
            dias:     Días a sumar (default 30 para planes mensuales).
            pasarela: Pasarela que procesó el cobro (``PasarelaPago.STRIPE``,
                      ``PasarelaPago.MERCADOPAGO``, ``PasarelaPago.MANUAL``).

        Example:
            # Desde el webhook de Stripe:
            licencia = LicenciaFeedback.objects.get(
                stripe_subscription_id=event.data.object.subscription
            )
            licencia.renovar_suscripcion(pasarela=PasarelaPago.STRIPE)

            # Desde el webhook de Mercado Pago:
            licencia = LicenciaFeedback.objects.get(
                mp_preapproval_id=preapproval_id
            )
            licencia.renovar_suscripcion(pasarela=PasarelaPago.MERCADOPAGO)
        """
        from django.utils import timezone

        hoy  = timezone.now().date()
        base = max(hoy, self.fecha_vencimiento)

        self.fecha_vencimiento  = base + datetime.timedelta(days=dias)
        self.ultima_renovacion  = timezone.now()
        self.pasarela_activa    = pasarela
        self.esta_activa        = True   # reactivar si estaba pausada por mora

        self.save(update_fields=[
            "fecha_vencimiento",
            "ultima_renovacion",
            "pasarela_activa",
            "esta_activa",
        ])
