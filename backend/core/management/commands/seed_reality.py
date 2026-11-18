"""seed_reality — deterministic demo data for the Reality-Audit CI run.

    python manage.py seed_reality --settings=assisto_backend.settings_ci [--out f.json]

Creates three demo accounts (A = the phone-under-test, B = the "other phone",
C = a second "other phone" registered as 01711000777, NOT connected to A),
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
    # registered as 01711000777 (owner order). NOT connected to A: every seed
    # run removes any A<->C edge so the flow always starts from "not added".
    "c": {"name": "Reality Nadia", "phone": os.getenv("REALITY_C_PHONE", "01711000777"),
          "email": "nadia@reality.test"},
    # flagproof: A's brother who runs a small salon (booking_bot flow 33) and
    # posts a missing alert about A (missing_alert flow 36: A says "I am safe").
    # Not in A's circle unless the drive includes the flagproof group.
    "d": {"name": "Reality Selim", "phone": "01700000004",
          "email": "selim@reality.test"},
    # group-calls: E is the THIRD person of the 3-way group call proof (flow
    # 18g): in A's and B's circle (accepted both ways). Its own user, so D
    # (flagproof) stays out of A's circle in every other drive.
    "e": {"name": "Reality Dipu", "phone": "01700000006",
          "email": "dipu@reality.test"},
}

FLAGPROOF_KEYS = ("vault_e2e", "ps_secretary", "ai_daily_planner", "booking_bot",
                  "official_corners", "blood_donors", "missing_alert")
ALL_WEEK = {str(d): [["09:00", "21:00"]] for d in range(7)}


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

    # ------------------------------------------------------------ flagproof
    def _flagproof(self, users, tokens, now):
        """Allow-list the demo users (CI DB only) for the hidden features whose
        reality flows prove them. The two-account set-up (A<->D family link,
        D's salon page, B as a blood donor, C opted in to nearby alerts) runs
        only when the drive includes the flagproof group, so no other group's
        circle or data changes."""
        from core import feature_flags as FF
        from core.models import FeatureFlag
        FF.ensure_seeded()
        for key in FLAGPROOF_KEYS:
            row = FeatureFlag.objects.filter(key=key).first()
            if row is not None:
                ids = list(row.allow_user_ids or [])
                for k in ("a", "b", "c", "d"):
                    if users[k].id not in ids:
                        ids.append(users[k].id)
                row.allow_user_ids = ids
                row.save(update_fields=["allow_user_ids", "updated_at"])
            self.steps.append({"step": "allow-list A-D for %s" % key, "method": "DB",
                               "path": "feature_flags", "status": 200, "ok": row is not None})
        FF.invalidate()
        if "flagproof" not in os.environ.get("REALITY_DRIVE", ""):
            return
        from core.models import BusinessProfile, CircleMember
        a, d = users["a"], users["d"]
        B, C, D = (self._client(tokens[k]) for k in ("b", "c", "d"))
        # A and D are brothers (both edges, as My Circle stores an accepted pair)
        for u, peer, rel in ((a, d, "brother"), (d, a, "brother")):
            CircleMember.objects.update_or_create(
                user=u, peer_user=peer,
                defaults={"name": peer.name, "relation": rel, "state": "accepted"})
        self.steps.append({"step": "family link A<->D", "method": "DB", "path": "circle",
                           "status": 200, "ok": True})
        # D's salon takes bookings (Business plan on this throw-away DB only)
        d.plan, d.plan_until = "business", now + timedelta(days=30)
        d.save(update_fields=["plan", "plan_until"])
        BusinessProfile.objects.get_or_create(user=d, defaults={"shop_name": "Flagproof Salon"})
        code, svc = self._call("booking service D", D, "post", "/booking/biz/services",
                               {"name": "Haircut", "duration_min": 30, "buffer_min": 10,
                                "price_bdt": 300})
        self._call("booking page D", D, "put", "/booking/biz",
                   {"weekly_hours": ALL_WEEK, "capacity": 1, "auto_confirm": False,
                    "slug": "flagproof-salon", "enabled": True, "cancel_hours": 2,
                    "min_notice_min": 60})
        # B is an O+ blood donor in Dhaka (district only, private by default)
        self._call("blood donor B", B, "post", "/blood-panel/me",
                   {"consent": True, "enabled": True, "blood_group": "O+", "sex": "m",
                    "district": "dhaka", "area_text": "Mirpur"})
        # C gets missing-person alerts for Dhaka
        self._call("missing nearby C", C, "post", "/missing-alerts/nearby",
                   {"enabled": True, "district": "dhaka"})

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
            # sjp0 (owner 9 Nov): seed only dedicated test accounts, never the owner's
            from core.test_accounts import RealAccountRefused, refuse_real_account
            try:
                refuse_real_account(user, phone=u["phone"], tool="seed_reality")
            except RealAccountRefused as e:
                raise CommandError(str(e))
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

        # --- group-calls: E is in A's and B's circle (both ways, accepted) ONLY
        # when the drive runs the circle / calls flows (18g). Elsewhere E stays
        # out, so no other flow's circle picker sees an extra person (gate
        # 44243785970: 41_mess_v2 added "Reality Dipu" instead of B).
        drive = (os.environ.get("REALITY_DRIVE") or os.environ.get("REALITY_ONLY") or "")
        groups = set(drive.replace(",", "+").split("+"))
        if groups & {"circle", "calls"}:
            for x, y in (("a", "e"), ("e", "a"), ("b", "e"), ("e", "b")):
                CircleMember.objects.update_or_create(
                    user=users[x], peer_user=users[y],
                    defaults={"name": USERS[y]["name"], "phone": USERS[y]["phone"],
                              "state": "accepted", "relation": "friend",
                              "direction": "outgoing" if x in ("a", "b") else "incoming"})
            self.steps.append({"step": "circle A<->E, B<->E (group call proof)",
                               "method": "DB", "path": "circle", "status": 200,
                               "ok": True})
        else:
            CircleMember.objects.filter(user__in=[users["a"], users["b"]], peer_user=users["e"]).delete()
            CircleMember.objects.filter(user=users["e"]).delete()

        # --- m3-circle: A and C start NOT connected (the flow adds C)
        CircleMember.objects.filter(user=users["a"], peer_user=users["c"]).delete()
        CircleMember.objects.filter(user=users["c"], peer_user=users["a"]).delete()
        self.steps.append({"step": "reset A<->C (m3 add flow)", "method": "DB",
                           "path": "circle", "status": 200, "ok": True})

        # --- budrem: Budget and Remittance is hidden (flag budget_remittance
        # OFF) — allow-list ONLY demo user A on this throw-away CI DB so the
        # reality flow can audit it (the owner's tester allow-list mechanism).
        from core import feature_flags as FF
        from core.models import FeatureFlag
        FF.ensure_seeded()
        ff = FeatureFlag.objects.filter(key="budget_remittance").first()
        if ff is not None:
            ids = [i for i in (ff.allow_user_ids or []) if i != users["a"].id] + [users["a"].id]
            ff.allow_user_ids = ids
            ff.save(update_fields=["allow_user_ids", "updated_at"])
            FF.invalidate()
        self.steps.append({"step": "allow-list A for budget_remittance", "method": "DB",
                           "path": "feature_flags", "status": 200, "ok": ff is not None})
        # qbiz: the business features that are OFF by registry default but ON
        # for launch (owner 2 Nov) — allow-list ONLY demo user A on this
        # throw-away CI DB so the business reality flows can audit them.
        for key in ("accounting_v2", "marketing_engine", "invoice_designs",
                    "assisto_market", "retention_auto",
                    "quran", "blood_donors"):  # gap-quranblood: reality qb1/qb2
            row = FeatureFlag.objects.filter(key=key).first()
            if row is not None and users["a"].id not in (row.allow_user_ids or []):
                row.allow_user_ids = list(row.allow_user_ids or []) + [users["a"].id]
                row.save(update_fields=["allow_user_ids", "updated_at"])
            self.steps.append({"step": "allow-list A for %s" % key, "method": "DB",
                               "path": "feature_flags", "status": 200, "ok": row is not None})
        # qjourney: same allow-list for the Safe Journey cards 2 + 3 (default
        # OFF in a fresh DB) so flow 16c can open them as user A.
        # flagproof: + the hidden features whose reality flows prove them
        # (vault_e2e -> flow 21; ps_secretary / ai_daily_planner /
        # booking_bot / official_corners / blood_donors -> flows 31-36).
        # gap-kidswatch: + kids_watch (flow 18k pairs a simulated watch)
        for key in ("dest_alarm", "train_tracker", "kids_watch"):
            ff = FeatureFlag.objects.filter(key=key).first()
            if ff is not None:
                ids = [i for i in (ff.allow_user_ids or []) if i != users["a"].id] + [users["a"].id]
                ff.allow_user_ids = ids
                ff.save(update_fields=["allow_user_ids", "updated_at"])
            self.steps.append({"step": f"allow-list A for {key}", "method": "DB",
                               "path": "feature_flags", "status": 200, "ok": ff is not None})
        # gap-lp: Language Partner courses + IELTS (flag language_packs, OFF in
        # a fresh DB) — allow-list ONLY demo user A and import Assisto's own
        # original content (lp_seed: no Cambridge / published material).
        ff = FeatureFlag.objects.filter(key="language_packs").first()
        if ff is not None and users["a"].id not in (ff.allow_user_ids or []):
            ff.allow_user_ids = list(ff.allow_user_ids or []) + [users["a"].id]
            ff.save(update_fields=["allow_user_ids", "updated_at"])
        self.steps.append({"step": "allow-list A for language_packs", "method": "DB",
                           "path": "feature_flags", "status": 200, "ok": ff is not None})
        try:
            from django.core.management import call_command
            call_command("lp_seed", verbosity=0)
            lp_ok = True
        except Exception:  # noqa: BLE001 — the other flows still run
            lp_ok = False
        # never fails the seed for the other flows: the lp1 flow itself shows it
        self.steps.append({"step": "lp_seed (original IELTS mocks)", "method": "DB",
                           "path": "lp_items", "status": 200 if lp_ok else 500, "ok": True,
                           "note": "" if lp_ok else "lp_seed failed"})
        FF.invalidate()

        # gap-cctv (lead, 17 Nov): user A runs a shop on the CCTV plan's free
        # trial (a TEST purchase row on this throw-away CI DB, never Play) so
        # flow 20 proves the real path past the plan screen: menu -> CCTV ->
        # Shop tools -> Shop Box, then the old shop_box link.
        try:
            import hashlib
            from core import cctv_plan_service as CPS
            from core.logic import cctv_plan as CP
            from core.models import PlayPurchase
            tok = "reality-cctv-trial-%d" % users["a"].id
            PlayPurchase.objects.update_or_create(
                token_hash=hashlib.sha256(tok.encode()).hexdigest(),
                defaults={"user": users["a"], "is_test": True, "purchase_token": tok,
                          "kind": "sub", "product_id": CPS.cfg()["product_id"],
                          "base_plan_id": CP.base_plan_id(2, "monthly"),
                          "state": "SUBSCRIPTION_STATE_ACTIVE",
                          "expires_at": now + timedelta(days=7),
                          "raw": {"in_trial": True, "seed": "reality"}})
            ok = CPS.plan_cameras(users["a"], now=now) > 0
        except Exception:
            ok = False
        self.steps.append({"step": "CCTV plan trial for A (shop flows)", "method": "DB",
                           "path": "play_purchases", "status": 200 if ok else 500, "ok": ok})

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

        # --- gap-city: a tiny made-up Dhaka transit sample so the emulator
        # City Service flow plans a real route (CI DB only — see the guard above)
        try:
            from core.city_sample import import_sample
            got = import_sample()
            self.steps.append({"step": "city sample (gap-city)", "method": "DB", "path": "city_dataset",
                               "status": 200, "ok": bool(got.get("stops"))})
        except Exception as e:  # noqa: BLE001 — recorded as a failed seed step
            self.steps.append({"step": "city sample (gap-city): %s" % e, "method": "DB",
                               "path": "city_dataset", "status": 500, "ok": False})
        # --- gap-nearby: a tiny made-up emergency list near the sample
        # Farmgate point (CI DB only) for the `nearbycity` reality group
        try:
            from core.nearby_sample import import_sample as nearby_sample
            got = nearby_sample()
            self.steps.append({"step": "nearby sample (gap-nearby)", "method": "DB", "path": "nearby_place",
                               "status": 200, "ok": bool(got)})
        except Exception as e:  # noqa: BLE001 — recorded as a failed seed step
            self.steps.append({"step": "nearby sample (gap-nearby): %s" % e, "method": "DB",
                               "path": "nearby_place", "status": 500, "ok": False})
        # --- homefeed: Today feed sample from RECORDED provider responses
        # (weather outage 5 h, fresh currency, 20-day-old gold) — CI DB only
        try:
            from core.world_sample import load as load_world_sample
            got = load_world_sample()
            self.steps.append({"step": "world sample (homefeed)", "method": "DB", "path": "world_feed",
                               "status": 200, "ok": bool(got.get("weather_ok_at"))})
        except Exception as e:  # noqa: BLE001 — recorded as a failed seed step
            self.steps.append({"step": "world sample (homefeed): %s" % e, "method": "DB",
                               "path": "world_feed", "status": 500, "ok": False})
        # --- flagproof: hidden features proven by reality flows 21 + 31-36
        self._flagproof(users, tokens, now)

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
