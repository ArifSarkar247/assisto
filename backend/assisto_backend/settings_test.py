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
