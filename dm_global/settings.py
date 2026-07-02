"""
Configuración de DM Global — Servicio de Feedback.

Variables de entorno requeridas (definir en .env):
    DJANGO_SECRET_KEY   Clave secreta (min. 50 chars en producción).
    DB_NAME             Nombre de la base de datos PostgreSQL.
    DB_USER             Usuario de la base de datos.
    DB_PASSWORD         Contraseña de la base de datos.

Variables opcionales:
    DEBUG               'true' en desarrollo. Default: false.
    ALLOWED_HOSTS       Hosts separados por coma. Default: localhost,127.0.0.1.
    DB_HOST             Default: localhost.
    DB_PORT             Default: 5432.

Variables del Copiloto IA:
    GEMINI_API_KEY      API Key de Google AI Studio para el modelo Gemini Pro.
                        Obtener en: https://aistudio.google.com/app/apikey
                        Vacía en dev → el copiloto se deshabilita silenciosamente.
"""
import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]

DEBUG = os.environ.get("DEBUG", "false").lower() == "true"

ALLOWED_HOSTS = os.environ.get("ALLOWED_HOSTS", "localhost,127.0.0.1").split(",")

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "servicios",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "dm_global.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "dm_global.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.environ.get("DB_NAME", "dm_feedback"),
        "USER": os.environ.get("DB_USER", "postgres"),
        "PASSWORD": os.environ.get("DB_PASSWORD", ""),
        "HOST": os.environ.get("DB_HOST", "localhost"),
        "PORT": os.environ.get("DB_PORT", "5432"),
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "es-ar"
TIME_ZONE = "America/Argentina/Buenos_Aires"
USE_I18N = True
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# ── Copiloto de Respuestas con IA ────────────────────────────────────────────
# Si la variable está vacía, el copiloto se deshabilita silenciosamente:
# el comentario del turista se guarda igual, pero borrador_respuesta_ia
# queda en blanco para que el operador lo redacte a mano.
GEMINI_API_KEY: str = os.environ.get("GEMINI_API_KEY", "")
