"""
Formularios de la app ``servicios``.
"""
from django import forms

from .models import ServicioFeedbackConfig, TipoNegocio


class ActivarServicioFeedbackForm(forms.ModelForm):
    """Formulario de alta del Servicio de Feedback.

    Solo expone los dos campos que el cliente debe completar al activar:
    ``tipo_negocio`` y ``google_review_link``.

    El backend genera ``api_token`` e ``id`` automáticamente; el admin
    establece ``estado_suscripcion`` de DEMO → ACTIVO una vez validado
    el pago.
    """

    google_review_link = forms.URLField(
        label="Enlace directo a tu perfil de Google Reviews",
        help_text=(
            "Abri tu negocio en Google Maps, hace clic en "
            "'Escribir una resena' y copia el enlace de la barra "
            "de direcciones. Empieza con https://g.page/r/... "
            "o https://maps.google.com/..."
        ),
        widget=forms.URLInput(attrs={
            "placeholder": "https://g.page/r/tu-negocio/review",
            "class": (
                "block w-full rounded-xl border border-gray-300 bg-white "
                "px-4 py-3 text-sm text-gray-900 shadow-sm "
                "placeholder:text-gray-400 focus:border-indigo-500 "
                "focus:outline-none focus:ring-2 focus:ring-indigo-200"
            ),
        }),
    )

    tipo_negocio = forms.ChoiceField(
        label="Tipo de negocio",
        choices=TipoNegocio.choices,
        widget=forms.Select(attrs={
            "class": (
                "block w-full rounded-xl border border-gray-300 bg-white "
                "px-4 py-3 text-sm text-gray-900 shadow-sm "
                "focus:border-indigo-500 focus:outline-none "
                "focus:ring-2 focus:ring-indigo-200"
            ),
        }),
    )

    class Meta:
        model  = ServicioFeedbackConfig
        fields = ["tipo_negocio", "google_review_link"]
