"""
Test settings — in-memory SQLite so the suite never touches the shared
Postgres (no CREATEDB needed, no risk to the live server). All models use
only JSONField, which SQLite supports.
"""
from .settings import *  # noqa: F401,F403

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": ":memory:",
    }
}

# Fast, deterministic password hashing for tests.
PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]

# Neutralise DRF's global anon/user rate-throttling in tests. The throttle cache
# persists across the whole test process, so accumulated request counts across
# hundreds of tests (order-dependent) can spuriously 429 an unrelated test. We
# keep the SCOPE KEYS defined (a few views use the 'reset' ScopedRateThrottle and
# require a rate to exist) but raise every rate so high nothing throttles in a
# test run. Product throttling is unchanged in real settings; feature-specific
# rate limits enforced in-view (e.g. registry/check 20/hour) still run + tested.
REST_FRAMEWORK = {**REST_FRAMEWORK,  # noqa: F405
                  "DEFAULT_THROTTLE_RATES": {
                      "anon": "1000000/min",
                      "user": "1000000/min",
                      "reset": "1000000/min",
                  }}
