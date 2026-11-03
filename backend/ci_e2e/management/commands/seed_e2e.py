"""seed_e2e — the reality seed + the CI fakes switched on, then a self-check.

    python manage.py seed_e2e --settings=assisto_backend.settings_e2e --out seed_e2e.json

1. runs seed_reality (demo users A/B/C, accepted My Circle edge, data);
2. saves FAKE "anthropic" and "google_places" integrations (status working)
   — the server then takes its normal "key present" paths; every network
   call lands in ci_e2e.fakes;
3. switches the maps proxy flag on (and Care Call when that module exists);
4. self-checks through the real endpoints (django test Client): OTP status,
   one Bangla AI answer, Places "Chandra", photo-answer config. Each check's
   result goes to --out; the workflow fails early (before the emulator) when
   a critical one is red.
Only the throw-away CI database (ci_e2e.apps refuses anything else).
"""
import json
import re

from django.core.management import call_command
from django.core.management.base import BaseCommand
from django.test import Client

BN = re.compile(r"[ঀ-৿]")


class Command(BaseCommand):
    help = "Seed the e2e proof run (CI only)."

    def add_arguments(self, parser):
        parser.add_argument("--out", default="seed_e2e.json")
        parser.add_argument("--reality-out", default="seed.json")

    def handle(self, *args, **opts):
        call_command("seed_reality", out=opts["reality_out"])
        from core import integrations
        from core.models import AdminFlagState, Integration, User
        from core.phone import find_user
        for slug, cfg in (("anthropic", {"api_key": "ci-fake-anthropic-not-a-key"}),
                          ("google_places", {"api_key": "ci-fake-places-not-a-key"})):
            integrations.save(slug, cfg)
            Integration.objects.filter(slug=slug).update(status="working", detail="CI fake (ci_e2e)")
        row, _ = AdminFlagState.objects.get_or_create(key="global", defaults={"state": {}})
        st = dict(row.state or {})
        st.update(maps_geocoding=True)
        row.state = st
        row.save()
        flags = {"maps_geocoding": True}
        # every launch module ON for the e2e run (Care Call when it exists)
        from core import feature_flags as FF
        from core.models import FeatureFlag
        FF.ensure_seeded()
        for key in ("care_call",):
            n = FeatureFlag.objects.filter(key=key).update(enabled_all=True, enabled_play=True,
                                                           rollout_pct=100)
            flags[key] = bool(n)
        FF.invalidate()

        a = find_user("01700000001")
        from rest_framework.authtoken.models import Token
        tok = Token.objects.get_or_create(user=a)[0].key
        c = Client(HTTP_AUTHORIZATION="Token " + tok, HTTP_ACCEPT_LANGUAGE="bn")
        checks = []

        def check(name, fn, critical=True):
            try:
                ok, detail = fn()
            except Exception as e:  # noqa: BLE001
                ok, detail = False, repr(e)[:300]
            checks.append({"check": name, "ok": bool(ok), "critical": critical, "detail": detail})

        def otp_status():
            r = Client().get("/api/v1/auth/otp/status")
            d = r.json()
            return d.get("sms_enabled") is True, d

        def ai_bn():
            r = c.post("/api/v1/agent", data=json.dumps({"text": "বাংলাদেশের রাজধানী কোথায়?"}),
                       content_type="application/json")
            d = r.json()
            rep = str(d.get("reply") or "")
            return (r.status_code == 200 and d.get("ai_used") and BN.search(rep) is not None,
                    {"status": r.status_code, "ai_used": d.get("ai_used"), "reply": rep[:200]})

        def places():
            r = c.get("/api/v1/maps/autocomplete?q=Chandra&session=cie2esession01")
            d = r.json()
            return d.get("state") == "ok" and bool(d.get("results")), d

        def vision():
            r = c.get("/api/v1/chat-vision/config")
            d = r.json() if r.status_code == 200 else {"status": r.status_code}
            return r.status_code == 200, d

        check("otp_sms_enabled", otp_status)
        check("ai_bangla_answer", ai_bn)
        check("places_chandra", places)
        check("chat_vision_config", vision, critical=False)
        out = {"flags": flags, "checks": checks,
               "users": User.objects.count(),
               "failed_critical": [x["check"] for x in checks if x["critical"] and not x["ok"]]}
        with open(opts["out"], "w", encoding="utf-8") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1, default=str)
        for x in checks:
            self.stdout.write("%s %s %s" % ("OK " if x["ok"] else "BAD", x["check"],
                                            json.dumps(x["detail"], ensure_ascii=False, default=str)[:300]))
