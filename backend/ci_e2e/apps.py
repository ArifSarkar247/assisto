"""CI-only app for the e2e proof run (settings_e2e). See fakes.py."""
import os

from django.apps import AppConfig
from django.conf import settings
from django.core.exceptions import ImproperlyConfigured


def _safe_db():
    db = settings.DATABASES["default"]
    if "sqlite" in db["ENGINE"]:
        return True
    return (os.environ.get("ASSISTO_CI_PG_NAME")
            and db.get("NAME") == os.environ["ASSISTO_CI_PG_NAME"]
            and db.get("HOST") in ("127.0.0.1", "localhost"))


class CiE2EConfig(AppConfig):
    name = "ci_e2e"
    label = "ci_e2e"
    verbose_name = "CI e2e fakes"

    def ready(self):
        if not (os.environ.get("GITHUB_ACTIONS") == "true"
                or os.environ.get("ASSISTO_E2E_LOCAL") == "1"):
            raise ImproperlyConfigured("ci_e2e runs only inside CI (GitHub Actions).")
        if not _safe_db():
            raise ImproperlyConfigured("ci_e2e refuses any database but the throw-away CI one.")
        from . import fakes
        fakes.install()
