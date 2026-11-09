"""
End-to-end harness settings (tools/e2e/*.sh). NEVER used in production.

settings_test + a FILE sqlite DB (so `runserver` on a scratch port and the
harness driver share one DB), a scratch MEDIA_ROOT, and FCM pointed at the
local mock FCM server (tools/e2e/mock_fcm.py) with a throw-away service
account the harness generates. Everything comes from E2E_* env vars set by the
harness script; nothing here can reach the live Postgres, real FCM or the
real media directory.
"""
import os

from .settings_test import *  # noqa: F401,F403

_E2E = os.environ.get("E2E_DIR") or "/tmp/assisto-e2e"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": os.environ.get("E2E_DB") or os.path.join(_E2E, "e2e.sqlite3"),
        # scratch data: no fsync per write (the migrate step alone is ~100
        # migrations); WAL lets runserver write while the driver reads
        "OPTIONS": {"timeout": 30,
                    "init_command": "PRAGMA journal_mode=WAL; PRAGMA synchronous=OFF;"},
    }
}
MEDIA_ROOT = os.environ.get("E2E_MEDIA") or os.path.join(_E2E, "media")
ASSISTO_BASE_URL = os.environ.get("E2E_BASE_URL", "http://127.0.0.1:18700")
ALLOWED_HOSTS = ["127.0.0.1", "localhost", "testserver"]
DEBUG = False

# FCM v1 through the real code path, but to the local mock (tools/e2e/mock_fcm.py)
FCM_SERVICE_ACCOUNT_FILE = os.environ.get("E2E_FCM_SA", "")
FCM_TOKEN_URI = os.environ.get("E2E_FCM_TOKEN_URI", "")
FCM_SEND_URL = os.environ.get("E2E_FCM_SEND_URL", "")
PUSH_SYNC = True
