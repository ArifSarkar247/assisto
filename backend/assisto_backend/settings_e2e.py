"""E2E-proof CI settings (e2eproof). Used ONLY by .github/workflows/e2e.yml.

settings_ci (throw-away DB, every paid key scrubbed, DEBUG off) PLUS the
CI-only app `ci_e2e`, which swaps every third-party network seam for a
deterministic fake so the 8 proof flows can run end to end on an emulator
without spending money or touching a real service:

  * AI chat + photo answers  -> core.ai._call_anthropic / core.vision_providers._claude
  * SMS OTP                   -> a fixed test code, "sent" to an outbox file
  * Google Places (Chandra)   -> core.maps_cost.HTTP
  * push (FCM)                -> recorded in the outbox (guardian notified, Care Call ring)
  * fake clock                -> POST /api/v1/ci-e2e/tick runs a server job at now+N min

The outbox + tick endpoints exist ONLY under this settings module.
ci_e2e refuses to load outside GitHub Actions (or ASSISTO_E2E_LOCAL=1) and
against any database that is not the throw-away CI one.
"""
import base64
import hashlib
import os

# Integrations are stored encrypted; settings_ci scrubs the real key. A
# deterministic THROW-AWAY key (derived, not a secret) lets the seed and the
# server process read the fake "anthropic" / "google_places" entries.
os.environ["INTEGRATIONS_FERNET_KEY"] = base64.urlsafe_b64encode(
    hashlib.sha256(b"assisto-ci-e2e-throwaway").digest()).decode()

from .settings_ci import *  # noqa: E402,F401,F403
from .settings_ci import INSTALLED_APPS, BASE_DIR  # noqa: E402

INSTALLED_APPS = list(INSTALLED_APPS) + ["ci_e2e.apps.CiE2EConfig"]
ROOT_URLCONF = "ci_e2e.urls"
E2E_OUTBOX = os.getenv("E2E_OUTBOX", str(BASE_DIR / "ci_e2e_outbox.jsonl"))
E2E_TEST_OTP = os.getenv("E2E_TEST_OTP", "135790")   # fake CI-only code

# Test Lab job only: the real phones reach this throw-away server through a
# temporary tunnel host (e2e.yml sets E2E_PUBLIC_HOST); never a real domain.
ALLOWED_HOSTS = list(ALLOWED_HOSTS) + [h for h in os.getenv("E2E_PUBLIC_HOST", "").split(",") if h]  # noqa: F405
