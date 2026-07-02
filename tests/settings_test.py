"""Settings de test — extiende dm_global.settings sobreescribiendo la BD."""
import os; os.environ.setdefault("DJANGO_SECRET_KEY", "test-key-for-pytest-only-do-not-use-in-prod")
os.environ.setdefault("GEMINI_API_KEY", "fake-gemini-key-pytest")
os.environ.setdefault("GOOGLE_SHEETS_ID", "test-sheets-id-pytest")
os.environ.setdefault("PRECHECKIN_FORM_URL", "https://test.crm.com/precheckin/")
os.environ.setdefault("DB_NAME", "x"); os.environ.setdefault("DB_USER", "x"); os.environ.setdefault("DB_PASSWORD", "x")

from dm_global.settings import *  # noqa: F401, F403

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": ":memory:",
    }
}
EMAIL_BACKEND = "django.core.mail.backends.locmem.EmailBackend"
