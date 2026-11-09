"""seed_camflows — the CCTV brand-cloud E2E seed (camflows.yml), AFTER seed_e2e.

    python manage.py seed_camflows --settings=assisto_backend.settings_e2eproof --out camflows_seed.json

1. demo user A gets an active Business plan (4 cameras included) — the
   camera import must never stop on "plan full" in the middle of a proof;
2. saves the FAKE vendor keys of the simulator (core.logic.cctv_connect.mocks
   VendorSims.cfg — not real keys) for Imou (+ OAuth project), EZVIZ and
   Dahua DoLynk, status "working" = what the owner's Save -> Test does; the
   owner's switch "devbind_customers" is on so a normal customer may bind;
3. creates A's place "Camflows Shop" through the REAL endpoint and checks
   through the real providers endpoint that the three brands are offered
   with the right ways to link, and switches the place to owner-away mode
   (every camera armed at any hour). Any red check fails the job before
   the emulator boots.
Only the throw-away CI database (ci_e2e.apps refuses anything else).
"""
import json
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.test import Client
from django.utils import timezone

SITE_NAME = "Camflows Shop"
WANT = {"imou": {"device_code", "oauth"}, "ezviz": {"device_code"}, "dolynk": {"device_code"}}


class Command(BaseCommand):
    help = "Seed the CCTV brand-cloud E2E (CI only)."

    def add_arguments(self, parser):
        parser.add_argument("--out", default="camflows_seed.json")

    def handle(self, *args, **opts):
        from core import integrations
        from core.logic import cctv_connect as CC
        from core.logic.cctv_connect.mocks import VendorSims
        from core.models import Integration
        from core.phone import find_user
        from rest_framework.authtoken.models import Token

        a = find_user("01700000001")
        a.plan = "business"
        a.plan_until = timezone.now() + timedelta(days=365)
        a.save(update_fields=["plan", "plan_until"])

        sims = VendorSims()
        for slug in ("imou", "ezviz", "dolynk"):
            cfg = dict(sims.cfg(slug), devbind_customers="on")
            integrations.save(slug, cfg)
            detail = "CI fake vendor cloud (ci_e2e.vendor_sim)"
            if slug == "dolynk":
                detail = CC.DOLYNK_OK + " — " + detail     # what the owner's signed Test writes
            Integration.objects.filter(slug=slug).update(status="working", detail=detail)

        tok = Token.objects.get_or_create(user=a)[0].key
        c = Client(HTTP_AUTHORIZATION="Token " + tok, HTTP_ACCEPT_LANGUAGE="en")
        checks = []

        def check(name, ok, detail):
            checks.append({"check": name, "ok": bool(ok), "detail": detail})

        sites = c.get("/api/v1/shop/sites").json()
        rows = sites.get("sites") or sites.get("results") or []
        site = next((s for s in rows if s.get("name") == SITE_NAME), None)
        if site is None:
            r = c.post("/api/v1/shop/sites", {"name": SITE_NAME, "snapshot_retention_days": 7},
                       content_type="application/json")
            site = r.json() if r.status_code in (200, 201) else None
            check("site_created", site and site.get("id"), {"status": r.status_code,
                                                             "body": r.content[:300].decode("utf-8", "replace")})
        sid = (site or {}).get("id")
        if sid:
            # owner-away mode (a normal owner switch): every camera armed
            # whatever the runner's clock says, as in the server's own tests
            from core.models import ShopSite
            ShopSite.objects.filter(pk=sid).update(
                away={"until": (timezone.now() + timedelta(days=1)).isoformat()})
            r = c.get("/api/v1/cctv/connect/providers?site=%s" % sid)
            prov = {p["id"]: set(p.get("modes") or []) for p in (r.json().get("providers") or [])} \
                if r.status_code == 200 else {}
            for pid, modes in WANT.items():
                check("provider_" + pid, modes <= prov.get(pid, set()),
                      {"status": r.status_code, "modes": sorted(prov.get(pid, set()))})
        out = {"site": sid, "checks": checks,
               "failed_critical": [x["check"] for x in checks if not x["ok"]]}
        with open(opts["out"], "w", encoding="utf-8") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1, default=str)
        for x in checks:
            self.stdout.write("%s %s %s" % ("OK " if x["ok"] else "BAD", x["check"],
                                            json.dumps(x["detail"], default=str)[:300]))
