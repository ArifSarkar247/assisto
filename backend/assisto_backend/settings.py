"""
Assisto backend settings — fully env-driven so the server can move with zero
change for users. Nothing here is specific to this machine; all host/URL/secret
values come from the environment (.env in dev).
"""
from pathlib import Path
import os
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")
# Canonical secrets file (chmod 600, never in git). Added keys (e.g.
# ANTHROPIC_API_KEY) turn features on with just a service restart.
load_dotenv("/home/ubuntu/.assisto_secrets.env", override=False)


def env_bool(key, default=False):
    return os.getenv(key, str(default)).lower() in ("1", "true", "yes", "on")


def env_list(key, default=""):
    raw = os.getenv(key, default)
    return [x.strip() for x in raw.split(",") if x.strip()]


SECRET_KEY = os.getenv("DJANGO_SECRET_KEY", "dev-insecure-change-me")
DEBUG = env_bool("DJANGO_DEBUG", False)

# The one setting everything derives from. Example: https://assisto.asalify.com
ASSISTO_BASE_URL = os.getenv("ASSISTO_BASE_URL", "http://127.0.0.1:8700")

ALLOWED_HOSTS = env_list("DJANGO_ALLOWED_HOSTS", "127.0.0.1,localhost")
CSRF_TRUSTED_ORIGINS = env_list("DJANGO_CSRF_TRUSTED_ORIGINS", ASSISTO_BASE_URL)

# Feature flags
# Latest-APK metadata file (written by publish-apk.sh); powers /api/v1/app/latest
APP_LATEST_FILE = os.getenv("APP_LATEST_FILE", str(BASE_DIR.parent / "app_latest.json"))

SMS_ENABLED = env_bool("SMS_ENABLED", False)            # OTP designed, off until a provider exists
# AI is ON automatically when a key is present (ANTHROPIC_API_KEY preferred).
AI_API_KEY = os.getenv("ANTHROPIC_API_KEY", "") or os.getenv("AI_API_KEY", "")
AI_ENABLED = bool(AI_API_KEY)
AI_PROVIDER = os.getenv("AI_PROVIDER", "anthropic")
AI_DAILY_BUDGET_USD = float(os.getenv("AI_DAILY_BUDGET_USD", "5"))   # kill-switch
AI_USER_DAILY_LIMIT = int(os.getenv("AI_USER_DAILY_LIMIT", "40"))    # per-user/day calls

# Self-hosted WebRTC (Step 6 M3): coturn TURN/STUN. Credentials are minted
# server-side from TURN_STATIC_SECRET (shared with /etc/turnserver.conf).
# TURN_HOST is a DOMAIN NAME (never a raw IP) so a server move is only a DNS
# change — no new APK. It defaults to the API domain (coturn runs on the same
# box). coturn's own `external-ip` (the raw IP for ICE candidates) lives in
# /etc/turnserver.conf and is regenerated per-server by provision.sh.
# Leave TURN_STATIC_SECRET empty to disable (the /rtc/turn endpoint then reports
# configured=false and the app shows an honest "call server not reachable").
TURN_STATIC_SECRET = os.getenv("TURN_STATIC_SECRET", "")
TURN_HOST = os.getenv("TURN_HOST", "assisto.asalify.com")
TURN_PORT = int(os.getenv("TURN_PORT", "3478"))

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "rest_framework",
    "rest_framework.authtoken",
    "corsheaders",
    "core",
    "web",
    "crm",
]

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "assisto_backend.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
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

WSGI_APPLICATION = "assisto_backend.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.getenv("DB_NAME", "assisto"),
        "USER": os.getenv("DB_USER", "assisto"),
        "PASSWORD": os.getenv("DB_PASSWORD", ""),
        "HOST": os.getenv("DB_HOST", "127.0.0.1"),
        "PORT": os.getenv("DB_PORT", "5432"),
    }
}

AUTH_USER_MODEL = "core.User"

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator",
     "OPTIONS": {"min_length": 6}},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
]

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework.authentication.TokenAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
    "DEFAULT_THROTTLE_CLASSES": [
        "rest_framework.throttling.AnonRateThrottle",
        "rest_framework.throttling.UserRateThrottle",
    ],
    "DEFAULT_THROTTLE_RATES": {
        "anon": "30/min",
        "user": "240/min",
        # Password-reset request/confirm: tight scope to blunt brute/enum/email-bomb.
        "reset": "6/min",
    },
}

# Password-reset emails. No real SMTP wired yet → print to the console so dev/
# tests never error; the reset endpoints always return a neutral response and
# never block on the send succeeding.
EMAIL_BACKEND = os.getenv(
    "DJANGO_EMAIL_BACKEND", "django.core.mail.backends.console.EmailBackend")
DEFAULT_FROM_EMAIL = os.getenv("DJANGO_FROM_EMAIL", "no-reply@asalify.com")
# Analytics uid_hash HMAC key (falls back to SECRET_KEY; analytics fails closed
# if neither is a real secret — see core/analytics.py).
ANALYTICS_HMAC_KEY = os.getenv("ANALYTICS_HMAC_KEY", "")

LANGUAGE_CODE = "en-us"
TIME_ZONE = "Asia/Dhaka"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
MEDIA_URL = "media/"
MEDIA_ROOT = BASE_DIR / "media"
# Private uploads: every FileField .url is a short-lived signed link served via
# /api/v1/m/ (core/media_sign.py); nginx keeps /media/ closed.
STORAGES = {
    "default": {"BACKEND": "core.media_sign.SignedMediaStorage"},
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
}
# nginx streams the bytes (X-Accel-Redirect → internal /protected-media/).
MEDIA_X_ACCEL = env_bool("MEDIA_X_ACCEL", False)
DATA_UPLOAD_MAX_MEMORY_SIZE = 15 * 1024 * 1024  # 15MB uploads (screenshots/photos)
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# CORS: the app may run from localhost during dev; lock down in prod.
CORS_ALLOW_ALL_ORIGINS = env_bool("CORS_ALLOW_ALL", DEBUG)
CORS_ALLOWED_ORIGINS = env_list("CORS_ALLOWED_ORIGINS", "")

# Behind Caddy (TLS terminated there)
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True
