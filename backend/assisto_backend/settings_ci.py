"""
Reality-audit CI settings (m2-reality). Used ONLY by .github/workflows/reality.yml
(and local smoke checks on a throw-away port) to run a disposable Django INSIDE
the CI runner, which the Android emulator reaches at http://10.0.2.2:8700.

Based on settings_test, with:
  * a FILE sqlite DB (the server process and `seed_reality` must share it;
    settings_test's :memory: DB would vanish between commands),
  * DEBUG off (behave like production: real error handlers, no debug pages),
  * ALLOWED_HOSTS incl. 10.0.2.2 (the emulator's alias for the runner host),
  * every paid / external integration forced OFF — no AI key, no FCM service
    account, no TURN secret, no SMTP, no integrations Fernet key — so a CI flow
    can never spend money or reach a third party, even if a secrets file exists
    on the machine (settings.py loads /home/ubuntu/.assisto_secrets.env).

NEVER point this at the live DB: the DB path is a local sqlite file only.
"""
import os

from .settings_test import *  # noqa: F401,F403
from .settings_test import BASE_DIR, REST_FRAMEWORK  # noqa: F401

# Scrub secrets that settings.py's load_dotenv() may have pulled into the env
# (modules such as core/integrations.py and core/push.py read os.environ).
for _k in ("ANTHROPIC_API_KEY", "AI_API_KEY", "FCM_SERVICE_ACCOUNT_FILE",
           "TURN_STATIC_SECRET", "INTEGRATIONS_FERNET_KEY", "OWNER_ALERT_EMAIL",
           "DB_PASSWORD", "ANALYTICS_HMAC_KEY"):
    os.environ.pop(_k, None)

DEBUG = False

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": os.getenv("ASSISTO_CI_DB", str(BASE_DIR / "ci_reality.sqlite3")),
        # the dev server serves requests on threads while seed/asserts may
        # write; give sqlite room instead of "database is locked".
        "OPTIONS": {"timeout": 30},
    }
}

ALLOWED_HOSTS = ["10.0.2.2", "127.0.0.1", "localhost", "testserver"]
CSRF_TRUSTED_ORIGINS = ["http://10.0.2.2:8700", "http://127.0.0.1:8700"]
ASSISTO_BASE_URL = os.getenv("ASSISTO_CI_BASE_URL", "http://10.0.2.2:8700")

# Paid / external surfaces OFF (honest "needs key" states are what we audit).
AI_API_KEY = ""
AI_ENABLED = False
SMS_ENABLED = False
TURN_STATIC_SECRET = ""
TURN_HOST = "10.0.2.2"
FCM_SERVICE_ACCOUNT_FILE = ""
PUSH_SYNC = True
EMAIL_BACKEND = "django.core.mail.backends.console.EmailBackend"
SECRET_KEY = "ci-reality-not-a-secret"
ANALYTICS_HMAC_KEY = ""
MEDIA_ROOT = BASE_DIR / "ci_media"
MEDIA_X_ACCEL = False
APP_LATEST_FILE = str(BASE_DIR / "ci_app_latest.json")  # absent -> "no update"

# Plain HTTP inside the runner (no Caddy in front).
SECURE_PROXY_SSL_HEADER = None
SECURE_SSL_REDIRECT = False
SESSION_COOKIE_SECURE = False
CSRF_COOKIE_SECURE = False

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {"console": {"class": "logging.StreamHandler"}},
    "loggers": {
        "django.request": {"handlers": ["console"], "level": "WARNING"},
        "django.server": {"handlers": ["console"], "level": "INFO"},
    },
}
