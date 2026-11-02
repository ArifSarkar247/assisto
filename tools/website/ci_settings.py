# website.yml only: a file-backed SQLite copy of the test settings so the dev
# server (several threads) shares one database. Never used in production.
from .settings_test import *  # noqa: F401,F403
import os

DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3",
                         "NAME": os.environ.get("WEBCI_DB", "/tmp/webci.sqlite3")}}
DEBUG = False
ALLOWED_HOSTS = ["127.0.0.1", "localhost"]
WEB_PUBLIC_SITE = os.environ.get("WEBCI_SITE", "http://127.0.0.1:8000")
