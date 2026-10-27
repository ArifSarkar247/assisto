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
# Self-hosted CI runner (user ghrunner) cannot read the server's secrets file
# -> skip it instead of crashing; CI uses settings_test / settings_ci anyway.
_secrets = "/home/ubuntu/.assisto_secrets.env"
if os.access(_secrets, os.R_OK):
    load_dotenv(_secrets, override=False)


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
# change — no new APK. It defaults to turn.lifeassisto.com (coturn runs on the same
# box). coturn's own `external-ip` (the raw IP for ICE candidates) lives in
# /etc/turnserver.conf and is regenerated per-server by provision.sh.
# Leave TURN_STATIC_SECRET empty to disable (the /rtc/turn endpoint then reports
# configured=false and the app shows an honest "call server not reachable").
TURN_STATIC_SECRET = os.getenv("TURN_STATIC_SECRET", "")
TURN_HOST = os.getenv("TURN_HOST", "turn.lifeassisto.com")
TURN_PORT = int(os.getenv("TURN_PORT", "3478"))
# x1-calls: TURN over TLS port — coturn tls-listening-port=5349 with the
# Let's Encrypt cert of turn.lifeassisto.com (live since 22 Oct). Offered to
# phones as the LAST TURN URL (udp/tcp 3478 stay first). 0 = not offered.
TURN_TLS_PORT = int(os.getenv("TURN_TLS_PORT", "5349"))

# ---- t9-turnscale: TURN server LIST as config (core/turn_pool.py) ----
# Empty (default) = the single TURN_HOST above, output byte-identical to before.
# Set it to hand the app several TURN boxes — adding a box = DNS name + one
# entry here (or in Owner Admin → Call relay), never an app update. Either JSON
#   [{"host":"turn.lifeassisto.com","weight":1,"tls_port":5349},
#    {"host":"turn2.lifeassisto.com","weight":2,"secret_env":"TURN2_SECRET"}]
# or a comma list:  turn.lifeassisto.com, turn2.lifeassisto.com:3478|w=2|tls=5349
# Secrets are NEVER in this list — only the NAME of an env var (secret_env);
# entries without one share TURN_STATIC_SECRET.
TURN_SERVERS = os.getenv("TURN_SERVERS", "")
TURN_MAX_ICE_HOSTS = int(os.getenv("TURN_MAX_ICE_HOSTS", "3"))
# Mirrors of /etc/turnserver.conf limits (the monitor alerts BEFORE these):
TURN_TOTAL_QUOTA = int(os.getenv("TURN_TOTAL_QUOTA", "600"))           # allocations
TURN_BPS_CAPACITY = int(os.getenv("TURN_BPS_CAPACITY", "31250000"))    # bytes/s, 0 = off
TURN_MAX_BPS = int(os.getenv("TURN_MAX_BPS", "250000"))                # bytes/s per allocation

# Vehicle tracking map tiles (app flutter_map). XYZ template, e.g. MapTiler:
#   https://api.maptiler.com/maps/streets-v2/256/{z}/{x}/{y}.png?key=<KEY>
# Empty = the app shows its tile-free route canvas. NEVER tile.openstreetmap.org
# (OSMF usage policy forbids app traffic; the API also refuses it).
MAP_TILE_URL = os.getenv("MAP_TILE_URL", "")
MAP_TILE_ATTRIBUTION = os.getenv("MAP_TILE_ATTRIBUTION",
                                 "© MapTiler © OpenStreetMap contributors")
MAP_TILE_MAX_ZOOM = int(os.getenv("MAP_TILE_MAX_ZOOM", "19"))

# Relay bandwidth budget the bandwidth alert compares against (bytes/s;
# 31250000 = 250 Mbit/s = half the t3.large 512 Mbit/s network baseline).
TURN_RELAY_BUDGET_BYTES_S = int(os.getenv("TURN_RELAY_BUDGET_BYTES_S", "31250000"))
# dl1: "Free calls (testing)" default when the owner has never flipped the
# switch (core/calls_free.py). ON -> My Circle calls are free for every plan.
CALLS_FREE_TESTING_DEFAULT = os.getenv("CALLS_FREE_TESTING_DEFAULT", "1") == "1"
TURN_RELAY_PORT_MIN = int(os.getenv("TURN_RELAY_PORT_MIN", "49152"))
TURN_RELAY_PORT_MAX = int(os.getenv("TURN_RELAY_PORT_MAX", "65535"))
TURN_RELAY_IP = os.getenv("TURN_RELAY_IP", "")              # e.g. 172.31.2.185; "" = any
TURN_LOG_PATH = os.getenv("TURN_LOG_PATH", "/var/log/turnserver/turn*.log")  # glob: newest wins
TURN_CLI_HOST = os.getenv("TURN_CLI_HOST", "127.0.0.1")
TURN_CLI_PORT = int(os.getenv("TURN_CLI_PORT", "5766"))
TURN_CLI_PASSWORD = os.getenv("TURN_CLI_PASSWORD", "")      # "" = CLI source off
TURN_NET_IFACE = os.getenv("TURN_NET_IFACE", "")            # "" = first non-lo iface
TURN_SAMPLE_KEEP_DAYS = int(os.getenv("TURN_SAMPLE_KEEP_DAYS", "14"))
# Relay egress price (Profit Guard). AWS EC2 "Data Transfer OUT from Amazon EC2
# to Internet", Asia Pacific (Mumbai) ap-south-1, first 10 TB/month tier:
# USD 0.1093 per GB (https://aws.amazon.com/ec2/pricing/on-demand/ → Data
# Transfer; the first 100 GB/month across the account is free and is NOT
# deducted here, so the number is conservative). Inbound transfer is free.
# Re-check the page when AWS changes prices; override with the env var.
TURN_EGRESS_USD_PER_GB = float(os.getenv("TURN_EGRESS_USD_PER_GB", "0.1093"))
# Bitrate ESTIMATES (kbit/s per direction, incl. RTP/UDP/IP + TURN overhead)
# used only until measured relay bytes exist: Opus voice ~32 kbit/s payload
# + ~20 kbit/s headers at 50 pkt/s; mobile WebRTC video ~0.6-1.2 Mbit/s.
TURN_EST_VOICE_KBPS = float(os.getenv("TURN_EST_VOICE_KBPS", "52"))
TURN_EST_VIDEO_KBPS = float(os.getenv("TURN_EST_VIDEO_KBPS", "1000"))

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
        # o2-admin: TokenAuthentication that also refuses blocked accounts
        "core.account_block.BlockAwareTokenAuthentication",
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
# md1: My Circle E2E media ciphertext lives OUTSIDE MEDIA_ROOT (never under
# /media/); served only via 10-min signed links (core/circle_blobs.py). In
# production nginx streams it: internal location /protected-circle-blobs/
# aliasing this dir, then CIRCLE_BLOB_X_ACCEL=1 (see .phaseB/proposals/md1.md).
CIRCLE_BLOB_ROOT = os.getenv("CIRCLE_BLOB_ROOT", str(BASE_DIR / "private" / "circle_blobs"))
CIRCLE_BLOB_X_ACCEL = env_bool("CIRCLE_BLOB_X_ACCEL", False)
# chat-actions: "Delete for everyone" window in minutes (WhatsApp ~2 days).
# Enforced on the SERVER (1:1 + groups); the app reads it from the chat GET.
CIRCLE_DELETE_EVERYONE_WINDOW_MIN = int(os.getenv("CIRCLE_DELETE_EVERYONE_WINDOW_MIN", "2880"))
DATA_UPLOAD_MAX_MEMORY_SIZE = 15 * 1024 * 1024  # 15MB uploads (screenshots/photos)
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# CORS: the app may run from localhost during dev; lock down in prod.
CORS_ALLOW_ALL_ORIGINS = env_bool("CORS_ALLOW_ALL", DEBUG)
CORS_ALLOWED_ORIGINS = env_list("CORS_ALLOWED_ORIGINS", "")

# Behind Caddy (TLS terminated there)
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True

# o2-admin: web owner panel (/owner/). HTTPS-only by default (set to false only
# for a local http dev server); idle sign-out in minutes.
OWNER_ADMIN_REQUIRE_HTTPS = env_bool("OWNER_ADMIN_REQUIRE_HTTPS", True)
OWNER_ADMIN_IDLE_MIN = int(os.getenv("OWNER_ADMIN_IDLE_MIN", "30"))

# d1-photo v2: Photo Studio worker (deploy/photo_worker/). With PHOTO_WORKER=1 the
# API only ENQUEUES heavy photo jobs; the assisto-photo-worker service runs them.
PHOTO_WORKER = env_bool("PHOTO_WORKER", False)
PHOTO_WORKER_INLINE = False   # tests only: run a queued item right away

# play-vitals: daily Google Play Vitals pull (manage.py play_vitals_pull). The
# service-account key lives ONLY on the server (owner_private); missing/unreadable
# key = the command logs and exits 0. Never commit the key.
PLAY_SERVICE_ACCOUNT_JSON = os.getenv(
    "PLAY_SERVICE_ACCOUNT_JSON", "/home/ubuntu/owner_private/play_service_account.json")
PLAY_PACKAGE_NAME = os.getenv("PLAY_PACKAGE_NAME", "com.assisto.assisto")
