import datetime

from django.contrib import admin
from django.shortcuts import get_object_or_404, redirect
from django.urls import path
from django.utils.html import format_html

from .models import LicenciaFeedback, Organizacion, ServicioFeedbackConfig


@admin.register(Organizacion)
class OrganizacionAdmin(admin.ModelAdmin):
    list_display = ("nombre", "activa", "created_at")
    list_filter = ("activa",)
    search_fields = ("nombre",)
    readonly_fields = ("id", "created_at")


@admin.register(ServicioFeedbackConfig)
class ServicioFeedbackConfigAdmin(admin.ModelAdmin):
    # 1. Columnas del listado principal
    list_display = (
        "get_nombre_organizacion",
        "tipo_negocio",
        "get_estado_badge",
        "ultima_sincronizacion",
    )
    # 2. Filtros laterales
    list_filter = ("estado_suscripcion", "tipo_negocio")
    # 3. Búsqueda por nombre de la organización asociada
    search_fields = ("organizacion__nombre",)
    # 4. id y api_token visibles pero de solo lectura.
    # ultima_sincronizacion también es readonly porque usa auto_now=True.
    readonly_fields = ("id", "api_token", "ultima_sincronizacion", "created_at")

    fieldsets = (
        (
            "Identificación",
            {
                "fields": ("id", "organizacion", "api_token"),
                "description": (
                    "Compartí el <strong>UUID de la configuración</strong> (id) "
                    "y el <strong>api_token</strong> con el cliente para que los "
                    "pegue en su Google Sheet."
                ),
            },
        ),
        (
            "Suscripción",
            {"fields": ("estado_suscripcion", "tipo_negocio")},
        ),
        (
            "Integración Google",
            {"fields": ("google_review_link", "google_sheet_url")},
        ),
        (
            "Auditoría",
            {
                "fields": ("ultima_sincronizacion", "created_at"),
                "classes": ("collapse",),
            },
        ),
    )

    @admin.display(description="Organización", ordering="organizacion__nombre")
    def get_nombre_organizacion(self, obj: ServicioFeedbackConfig) -> str:
        return obj.organizacion.nombre

    @admin.display(description="Estado")
    def get_estado_badge(self, obj: ServicioFeedbackConfig) -> str:
        colores = {
            "ACTIVO": "#16a34a",
            "DEMO": "#2563eb",
            "INACTIVO": "#dc2626",
        }
        color = colores.get(obj.estado_suscripcion, "#6b7280")
        return format_html(
            '<span style="background:{};color:#fff;padding:2px 10px;'
            'border-radius:12px;font-size:11px;font-weight:600">{}</span>',
            color,
            obj.get_estado_suscripcion_display(),
        )


# ---------------------------------------------------------------------------
# Admin: Licencias de Feedback (billing engine)
# ---------------------------------------------------------------------------


@admin.register(LicenciaFeedback)
class LicenciaFeedbackAdmin(admin.ModelAdmin):
    """Panel de control de licencias — diseñado para gestión operativa rápida.

    Características clave:
    • Columna "Estado" con badge de color y badge de días restantes.
    • Botón de toggle (Activar / Pausar) en cada fila → un solo clic.
    • Acciones masivas para activar o pausar múltiples licencias.
    • Búsqueda por ID y nombre de comercio.
    """

    # ── Listado ───────────────────────────────────────────────────────
    list_display = (
        "id_comercio",
        "nombre_comercio",
        "tipo_negocio",
        "get_estado_badge",
        "fecha_vencimiento",
        "get_dias_restantes",
        "get_toggle_link",       # ← botón de un clic
    )
    list_filter  = ("esta_activa", "tipo_negocio")
    search_fields = ("id_comercio", "nombre_comercio")
    readonly_fields = ("created_at",)
    ordering     = ("id_comercio",)

    fieldsets = (
        (
            "Identificación",
            {"fields": ("id_comercio", "nombre_comercio", "tipo_negocio")},
        ),
        (
            "Control de suscripción",
            {
                "fields": ("esta_activa", "fecha_vencimiento"),
                "description": (
                    "Cambiar <strong>esta_activa</strong> a False bloquea "
                    "el servicio de inmediato (el Apps Script recibe HTTP 403). "
                    "Extender <strong>fecha_vencimiento</strong> renueva la licencia."
                ),
            },
        ),
        (
            "Auditoría",
            {"fields": ("created_at",), "classes": ("collapse",)},
        ),
    )

    # ── Acciones masivas ──────────────────────────────────────────────
    actions = ["accion_activar", "accion_pausar"]

    @admin.action(description="Activar licencias seleccionadas")
    def accion_activar(self, request, queryset):
        actualizadas = queryset.update(esta_activa=True)
        self.message_user(request, f"{actualizadas} licencia(s) activada(s).")

    @admin.action(description="Pausar licencias seleccionadas")
    def accion_pausar(self, request, queryset):
        actualizadas = queryset.update(esta_activa=False)
        self.message_user(request, f"{actualizadas} licencia(s) pausada(s).")

    # ── Toggle de un clic ─────────────────────────────────────────────
    def get_urls(self):
        custom = [
            path(
                "licencia/<pk>/toggle/",
                self.admin_site.admin_view(self._toggle_activa),
                name="licenciafeedback-toggle",
            ),
        ]
        return custom + super().get_urls()

    def _toggle_activa(self, request, pk):
        licencia = get_object_or_404(LicenciaFeedback, pk=pk)
        licencia.esta_activa = not licencia.esta_activa
        licencia.save(update_fields=["esta_activa"])
        estado = "activada" if licencia.esta_activa else "pausada"
        from django.contrib import messages as _msg
        _msg.success(request, f"Licencia '{pk}' {estado}.")
        return redirect("../../")   # vuelve al listado

    @admin.display(description="Toggle")
    def get_toggle_link(self, obj: LicenciaFeedback) -> str:
        if obj.esta_activa:
            color, texto = "#dc2626", "Pausar"
        else:
            color, texto = "#16a34a", "Activar"
        url = f"licencia/{obj.pk}/toggle/"
        return format_html(
            '<a href="{}" style="color:{};font-weight:700;white-space:nowrap">{}</a>',
            url, color, texto,
        )

    # ── Columnas calculadas ───────────────────────────────────────────
    @admin.display(description="Estado")
    def get_estado_badge(self, obj: LicenciaFeedback) -> str:
        hoy = datetime.date.today()
        if not obj.esta_activa:
            color, etiqueta = "#6b7280", "Pausada"
        elif obj.fecha_vencimiento < hoy:
            color, etiqueta = "#dc2626", "Vencida"
        elif (obj.fecha_vencimiento - hoy).days <= 7:
            color, etiqueta = "#d97706", "Por vencer"
        else:
            color, etiqueta = "#16a34a", "Activa"
        return format_html(
            '<span style="background:{};color:#fff;padding:2px 10px;'
            'border-radius:12px;font-size:11px;font-weight:600">{}</span>',
            color, etiqueta,
        )

    @admin.display(description="Días restantes", ordering="fecha_vencimiento")
    def get_dias_restantes(self, obj: LicenciaFeedback) -> str:
        dias = (obj.fecha_vencimiento - datetime.date.today()).days
        if dias < 0:
            return format_html('<span style="color:#dc2626;font-weight:700">Vencida hace {} día(s)</span>', abs(dias))
        if dias <= 7:
            return format_html('<span style="color:#d97706;font-weight:700">{} día(s)</span>', dias)
        return format_html('<span style="color:#374151">{} días</span>', dias)
