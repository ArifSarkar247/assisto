"""seed_recovery — the account-recovery E2E seed (e2e.yml group start+recovery),
AFTER seed_e2e. Needs E2E_FAKE_EMAIL=1 (ci_e2e.fakes captures company mail).

    python manage.py seed_recovery --settings=assisto_backend.settings_e2eproof --out seed_recovery.json

1. demo user A (seed_reality, made-up rahim@reality.test) gets that address
   VERIFIED — what A did once in Settings -> Account & security;
2. self-check: the email channel is on (captured), A's verified address is
   found by the email-code sign-in, and the A<->B My Circle edge exists.
Only the throw-away CI database (ci_e2e.apps refuses anything else).
"""
import json
import os

from django.core.management.base import BaseCommand

ADDR = "rahim@reality.test"


class Command(BaseCommand):
    help = "Seed the account-recovery E2E (CI only)."

    def add_arguments(self, parser):
        parser.add_argument("--out", default="seed_recovery.json")

    def handle(self, *args, **opts):
        from core import otp
        from core.models import CircleMember
        from core.phone import find_user

        a = find_user("01700000001")
        b = find_user("01700000002")
        otp.mark_email_verified(a, ADDR)
        checks = [
            ("fake email on (E2E_FAKE_EMAIL=1)", os.environ.get("E2E_FAKE_EMAIL") == "1"),
            ("email channel available", otp.email_available()),
            ("A found by verified email", getattr(otp.find_user_by_verified_email(ADDR), "pk", None) == a.pk),
            ("A<->B My Circle edge", CircleMember.objects.filter(
                user=a, peer_user=b, state="accepted").exists()),
        ]
        failed = [n for n, ok in checks if not ok]
        out = {"checks": [{"name": n, "ok": bool(ok)} for n, ok in checks],
               "failed_critical": failed}
        with open(opts["out"], "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=1)
        self.stdout.write(json.dumps(out))
