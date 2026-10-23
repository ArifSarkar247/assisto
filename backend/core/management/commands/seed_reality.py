"""seed_reality — deterministic demo data for the Reality-Audit CI run.

    python manage.py seed_reality --settings=assisto_backend.settings_ci [--out f.json]

Creates three demo accounts (A = the phone-under-test, B = the "other phone",
C = a second "other phone" registered as 01865052200, NOT connected to A),
an accepted My-Circle edge between them, family members + emergency card,
money accounts/transactions/budget, notes/todos/reminders and a business
(profile, products, khata party). Wherever a REAL API endpoint exists the data
is written THROUGH that endpoint (django test Client, token auth) — so the seed
is itself a backend round-trip check; each step's HTTP status is reported.

REFUSES to run unless the active DB is sqlite (the CI / throw-away file DB) —
it can never seed the live Postgres. Idempotent: re-running reuses the users.

Writes a JSON summary (credentials of the FAKE demo users, ids, per-step
statuses) to --out (default: ci_reality_seed.json next to manage.py). The
passwords are fixed, obviously-fake CI values, not secrets.
"""
import json
import os
from datetime import date, timedelta
from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.test import Client
from django.utils import timezone

DEMO_PASSWORD = "Reality#2026"  # fake CI-only demo password
USERS = {
    "a": {"name": "Reality Rahim", "phone": "01700000001",
          "email": "rahim@reality.test"},
    "b": {"name": "Reality Karim", "phone": "01700000002",
          "email": "karim@reality.test"},
    # m3-circle: the "second phone" for the WhatsApp-style add flow,
    # registered as 01865052200 (owner order). NOT connected to A: every seed
    # run removes any A<->C edge so the flow always starts from "not added".
    "c": {"name": "Reality Nadia", "phone": "01865052200",
          "email": "nadia@reality.test"},
}


class Command(BaseCommand):
    help = "Seed deterministic demo data for the reality-audit CI run (sqlite only)."

    def add_arguments(self, parser):
        parser.add_argument("--out", default=str(Path(settings.BASE_DIR) / "ci_reality_seed.json"))

    # ------------------------------------------------------------ helpers
    def _client(self, token):
        return Client(HTTP_AUTHORIZATION=f"Token {token}", HTTP_ACCEPT_LANGUAGE="en")

    def _call(self, label, c, method, path, body=None):
        fn = getattr(c, method)
        kw = {"content_type": "application/json"}
        if body is not None:
            kw["data"] = json.dumps(body)
        try:
            r = fn("/api/v1" + path, **kw)
            code = r.status_code
            try:
                data = r.json()
            except Exception:
                data = None
        except Exception as e:  # a crashing view is itself a finding
            code, data = 599, {"exception": repr(e)[:300]}
        self.steps.append({"step": label, "method": method.upper(), "path": path,
                           "status": code, "ok": 200 <= code < 300})
        return code, data

    # ------------------------------------------------------------ main
    def handle(self, *args, **opts):
        engine = settings.DATABASES["default"]["ENGINE"]
        # rt1: reality.yml's throw-away Postgres service container is also
        # allowed — ONLY inside GitHub Actions, only the CI database that
        # settings_ci built from ASSISTO_CI_PG_NAME, only on localhost.
        ci_pg = (
            "postgresql" in engine
            and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("ASSISTO_CI_PG_NAME")
            and settings.DATABASES["default"].get("NAME") == os.environ["ASSISTO_CI_PG_NAME"]
            and settings.DATABASES["default"].get("HOST") in ("127.0.0.1", "localhost")
        )
        if "sqlite" not in engine and not ci_pg:
            raise CommandError("seed_reality only runs against the CI sqlite DB "
                               f"(got {engine}); refusing to touch a real database.")
        from rest_framework.authtoken.models import Token
        from core.models import User, CircleMember

        self.steps = []
        now = timezone.now()
        users, tokens = {}, {}
        for key, u in USERS.items():
            # stored phones are canonical E.164 since c1 (0050): find by any
            # spelling so a re-run reuses the user instead of failing.
            from core.phone import find_user
            user = find_user(u["phone"]) or User.objects.filter(phone=u["phone"]).first()
            if user is None:
                user = User.objects.create_user(name=u["name"], phone=u["phone"],
                                                email=u["email"], password=DEMO_PASSWORD)
            # full trial so premium-gated screens show real behaviour, not paywalls
            user.trial_until = now + timedelta(days=30)
            user.language = "en"
            user.ai_credits = max(user.ai_credits, 500)
            user.save()
            users[key] = user
            tokens[key] = Token.objects.get_or_create(user=user)[0].key

        A, B = self._client(tokens["a"]), self._client(tokens["b"])

        # --- login through the real endpoint (proves the credentials work)
        lc = Client()
        r = lc.post("/api/v1/auth/login", data=json.dumps(
            {"identifier": USERS["a"]["phone"], "password": DEMO_PASSWORD}),
            content_type="application/json")
        self.steps.append({"step": "login A", "method": "POST", "path": "/auth/login",
                           "status": r.status_code, "ok": r.status_code == 200})

        # --- My Circle: A requests B by phone, B accepts (real endpoints)
        circle = {}
        edge = CircleMember.objects.filter(user=users["a"], peer_user=users["b"]).first()
        if edge is None:
            self._call("circle request A->B", A, "post", "/circle/request",
                       {"phone": USERS["b"]["phone"], "name": USERS["b"]["name"],
                        "relation": "friend"})
        inc = CircleMember.objects.filter(user=users["b"], peer_user=users["a"],
                                          direction="incoming").first()
        if inc is not None and inc.state == "pending":
            self._call("circle accept by B", B, "post", f"/circle/request/{inc.id}/act",
                       {"event": "accept"})
        ea = CircleMember.objects.filter(user=users["a"], peer_user=users["b"]).first()
        eb = CircleMember.objects.filter(user=users["b"], peer_user=users["a"]).first()
        circle = {"a_member_id": ea.id if ea else None, "a_state": ea.state if ea else None,
                  "b_member_id": eb.id if eb else None, "b_state": eb.state if eb else None}

        # --- m3-circle: A and C start NOT connected (the flow adds C)
        CircleMember.objects.filter(user=users["a"], peer_user=users["c"]).delete()
        CircleMember.objects.filter(user=users["c"], peer_user=users["a"]).delete()
        self.steps.append({"step": "reset A<->C (m3 add flow)", "method": "DB",
                           "path": "circle", "status": 200, "ok": True})

        # --- family + emergency card
        fam = []
        for name, rel, phone in (("Ammu", "mother", "01700000011"),
                                 ("Abbu", "father", "01700000012")):
            code, d = self._call(f"family {name}", A, "post", "/family/",
                                 {"name": name, "relation": rel, "phone": phone})
            if d and isinstance(d, dict) and d.get("id"):
                fam.append(d["id"])
        self._call("emergency card", A, "put", "/emergency",
                   {"blood_group": "B+", "allergies": "None (demo)",
                    "contacts": [{"name": "Ammu", "phone": "01700000011"}]})

        # --- personal: notes / todos / reminders
        self._call("note", A, "post", "/notes/", {"title": "Seeded note", "body": "From seed_reality"})
        self._call("todo", A, "post", "/todos/", {"title": "Seeded todo"})
        self._call("reminder", A, "post", "/reminders/",
                   {"title": "Seeded reminder", "due_at": (now + timedelta(days=1)).isoformat()})

        # --- money
        acc_id = None
        code, d = self._call("money account", A, "post", "/accounts/",
                             {"name": "Cash wallet", "acc_type": "cash", "opening_balance": "5000"})
        if d and isinstance(d, dict):
            acc_id = d.get("id")
        if acc_id:
            for amt, cat, note in (("250", "food", "Lunch"), ("120", "transport", "Rickshaw")):
                self._call(f"txn {note}", A, "post", "/transactions/",
                           {"account": acc_id, "kind": "expense", "amount": amt,
                            "category": cat, "note": note, "date": date.today().isoformat()})
        self._call("budget", A, "post", "/budgets/", {"category": "food", "monthly_limit": "6000"})

        # --- business (POS): profile, products, khata party
        biz = {}
        code, d = self._call("business profile", A, "post", "/business/profiles",
                             {"name": "Rahim Store", "type": "small_shop"})
        if d and isinstance(d, dict):
            biz["business_id"] = d.get("id")
        prods = []
        for name, sell, cost, stock in (("Rice 1kg", 80, 70, 50), ("Tea 200g", 120, 95, 30),
                                        ("Soap", 45, 35, 40)):
            code, d = self._call(f"product {name}", A, "post", "/business/products",
                                 {"name": name, "price": sell, "cost": cost, "stock": stock,
                                  "category": "grocery"})
            if d and isinstance(d, dict):
                pid = d.get("id") or (d.get("product") or {}).get("id")
                if pid:
                    prods.append(pid)
        biz["product_ids"] = prods
        code, d = self._call("khata party", A, "post", "/business/khata/parties",
                             {"name": "Selim (khata)", "phone": "01700000021", "book": "customer"})
        if d and isinstance(d, dict):
            biz["khata_party_id"] = d.get("id")

        # --- read-backs: the data must come back through the GET side too
        for label, path in (("notes list", "/notes/"), ("family list", "/family/"),
                            ("circle members", "/circle/members"),
                            ("business products", "/business/products"),
                            ("money summary", "/money/summary"), ("me", "/me")):
            self._call(label, A, "get", path)

        out = {
            "password": DEMO_PASSWORD,
            "users": {k: {**USERS[k], "id": users[k].id, "token": tokens[k]} for k in USERS},
            "circle": circle, "family_ids": fam, "money_account_id": acc_id,
            "business": biz, "steps": self.steps,
            "failed_steps": [s for s in self.steps if not s["ok"]],
        }
        Path(opts["out"]).write_text(json.dumps(out, indent=2))
        bad = len(out["failed_steps"])
        self.stdout.write(f"seed_reality: {len(self.steps)} steps, {bad} failed -> {opts['out']}")
        for s in out["failed_steps"]:
            self.stdout.write(f"  FAILED {s['method']} {s['path']} -> {s['status']}  ({s['step']})")
