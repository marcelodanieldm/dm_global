"""
Servicio de IA — Copiloto de Respuestas para el Servicio de Feedback.

Responsabilidad única: dado el comentario crudo de un turista insatisfecho,
generar un borrador de respuesta empática actuando como gerente del comercio.

Tecnología: Google Gemini Pro vía API REST (generativelanguage.googleapis.com).
API Key: settings.GEMINI_API_KEY (variable de entorno GEMINI_API_KEY en .env).

Diseño defensivo:
    Si la API Key está ausente, si la red falla o si Gemini devuelve una
    respuesta inesperada, la función retorna ``""`` sin lanzar excepción.
    Esto garantiza que el flujo de la vista nunca se rompa por el Copiloto.
"""
import logging

import requests
from django.conf import settings

logger = logging.getLogger(__name__)

# ─────────────────────────────────────────────────────────────────────────────
# Constantes
# ─────────────────────────────────────────────────────────────────────────────

_GEMINI_ENDPOINT = (
    "https://generativelanguage.googleapis.com"
    "/v1beta/models/gemini-pro:generateContent?key={key}"
)

_TIMEOUT_SEGUNDOS = 12   # Gemini suele responder en 2-4s; 12s es holgado

# Prompts del sistema por idioma.
# Cada plantilla recibe {nombre_comercio} y {comentario} como sustituciones.
_PROMPTS: dict[str, str] = {
    "es": (
        "Eres el gerente de {nombre_comercio}. "
        "Un cliente dejó la siguiente opinión negativa: \"{comentario}\". "
        "Redacta una respuesta breve, humana y empática que:\n"
        "1. Se dirija al cliente en segunda persona.\n"
        "2. Pida disculpas específicamente por el problema mencionado.\n"
        "3. Muestre voluntad real de mejora sin excusas genéricas.\n"
        "Máximo 3 líneas. No incluyas saludos formales ni firma."
    ),
    "en": (
        "You are the manager of {nombre_comercio}. "
        "A customer left the following negative feedback: \"{comentario}\". "
        "Write a brief, human and empathetic reply that:\n"
        "1. Addresses the customer directly.\n"
        "2. Apologizes specifically for the issue mentioned.\n"
        "3. Shows genuine willingness to improve without generic excuses.\n"
        "Maximum 3 lines. No formal greetings or signatures."
    ),
    "pt": (
        "Você é o gerente de {nombre_comercio}. "
        "Um cliente deixou a seguinte opinião negativa: \"{comentario}\". "
        "Escreva uma resposta breve, humana e empática que:\n"
        "1. Se dirija ao cliente diretamente.\n"
        "2. Peça desculpas especificamente pelo problema mencionado.\n"
        "3. Demonstre vontade real de melhorar sem desculpas genéricas.\n"
        "Máximo 3 linhas. Sem saudações formais ou assinatura."
    ),
    "fr": (
        "Vous êtes le directeur de {nombre_comercio}. "
        "Un client a laissé l'avis négatif suivant : \"{comentario}\". "
        "Rédigez une réponse brève, humaine et empathique qui :\n"
        "1. S'adresse directement au client.\n"
        "2. S'excuse spécifiquement pour le problème mentionné.\n"
        "3. Montre une vraie volonté de s'améliorer sans excuses génériques.\n"
        "Maximum 3 lignes. Sans formules de politesse ni signature."
    ),
    "de": (
        "Sie sind der Geschäftsführer von {nombre_comercio}. "
        "Ein Kunde hat folgende negative Bewertung hinterlassen: \"{comentario}\". "
        "Verfassen Sie eine kurze, menschliche und einfühlsame Antwort, die:\n"
        "1. Den Kunden direkt anspricht.\n"
        "2. Sich ausdrücklich für das genannte Problem entschuldigt.\n"
        "3. Echte Verbesserungsbereitschaft zeigt ohne generische Ausreden.\n"
        "Maximal 3 Zeilen. Keine formellen Grüße oder Unterschrift."
    ),
}

_PROMPT_FALLBACK = _PROMPTS["es"]


# ─────────────────────────────────────────────────────────────────────────────
# API pública del módulo
# ─────────────────────────────────────────────────────────────────────────────


def generar_borrador_respuesta(
    comentario: str,
    nombre_comercio: str,
    idioma: str = "es",
) -> str:
    """Genera un borrador de respuesta empática usando Gemini Pro.

    Args:
        comentario:       Texto crudo del turista (``RespuestaFeedback.comentario_turista``).
        nombre_comercio:  Nombre del negocio que responde (aparece en el prompt).
        idioma:           Código ISO 639-1 del idioma del comentario ('es','en','pt','fr','de').

    Returns:
        Texto generado por Gemini (3 líneas máx) o cadena vacía si falla o
        si la API key no está configurada.
    """
    api_key: str = getattr(settings, "GEMINI_API_KEY", "")

    if not api_key:
        logger.warning(
            "Copiloto IA deshabilitado: GEMINI_API_KEY no configurada en .env."
        )
        return ""

    if not comentario or not comentario.strip():
        return ""

    prompt = _construir_prompt(
        comentario=comentario.strip(),
        nombre_comercio=nombre_comercio,
        idioma=idioma,
    )

    try:
        return _llamar_gemini(api_key=api_key, prompt=prompt)
    except Exception as exc:
        logger.error(
            "Copiloto IA: error inesperado llamando a Gemini | %s: %s",
            type(exc).__name__, exc,
        )
        return ""


# ─────────────────────────────────────────────────────────────────────────────
# Helpers privados
# ─────────────────────────────────────────────────────────────────────────────


def _construir_prompt(
    comentario: str,
    nombre_comercio: str,
    idioma: str,
) -> str:
    """Selecciona la plantilla de idioma y sustituye las variables."""
    plantilla = _PROMPTS.get(idioma[:2].lower(), _PROMPT_FALLBACK)
    return plantilla.format(
        nombre_comercio=nombre_comercio,
        comentario=comentario,
    )


def _llamar_gemini(api_key: str, prompt: str) -> str:
    """Hace la llamada HTTP POST a la API de Gemini Pro y extrae el texto.

    El body sigue el formato del Content API v1beta:
        POST /v1beta/models/gemini-pro:generateContent
        {
          "contents": [{"parts": [{"text": "<prompt>"}]}]
        }

    Respuesta esperada (simplificada):
        {
          "candidates": [{
            "content": {"parts": [{"text": "<texto generado>"}]}
          }]
        }
    """
    url     = _GEMINI_ENDPOINT.format(key=api_key)
    payload = {"contents": [{"parts": [{"text": prompt}]}]}
    headers = {"Content-Type": "application/json"}

    try:
        response = requests.post(
            url,
            json=payload,
            headers=headers,
            timeout=_TIMEOUT_SEGUNDOS,
        )
    except requests.exceptions.Timeout:
        logger.warning("Copiloto IA: timeout al llamar a Gemini (%ss).", _TIMEOUT_SEGUNDOS)
        return ""
    except requests.exceptions.ConnectionError as exc:
        logger.warning("Copiloto IA: error de conexión con Gemini | %s", exc)
        return ""

    if not response.ok:
        logger.warning(
            "Copiloto IA: Gemini respondió HTTP %s | body: %s",
            response.status_code,
            response.text[:200],
        )
        return ""

    try:
        texto = (
            response.json()
            ["candidates"][0]
            ["content"]["parts"][0]
            ["text"]
        )
        return texto.strip()
    except (KeyError, IndexError, ValueError) as exc:
        logger.warning(
            "Copiloto IA: respuesta de Gemini con estructura inesperada | %s | body: %s",
            exc,
            response.text[:200],
        )
        return ""
