"""seed_train_e2e — the Train Tracker E2E seed (train-e2e.yml), AFTER seed_e2e.

    python manage.py seed_train_e2e --settings=assisto_backend.settings_e2eproof --out train_seed.json

1. loads the data lane's OFFICIAL trains into the throw-away DB
   (load_bd_trains: RailTrain / RailStation — learned delays need them);
2. the `train_tracker` switch stays OFF for everyone (enabled_all false):
   demo users A and B and three made-up riders are PREVIEW testers
   (allow_user_ids) — exactly how the owner sees it before he says "OK";
3. self-checks through the real API: Rangpur Express 771/772 are found
   (number, English name, Bangla digits) with the official times and off
   days, the switch really is OFF for a normal user (403), and the live
   store answers from Redis when TRAIN_LIVE_REDIS_URL is set.
Only the throw-away CI database (ci_e2e.apps refuses anything else).
"""
import json
import os

from django.core.management.base import BaseCommand
from django.test import Client

RIDERS = ("01999000101", "01999000102", "01999000103")
RIDER_PASSWORD = "ci-train-rider-sample"   # made-up CI-only sample accounts
WANT = {"771": ("09:10", "19:00", [0]), "772": ("20:00", "06:00", [6])}


class Command(BaseCommand):
    help = "Seed the Train Tracker E2E (CI only)."

    def add_arguments(self, parser):
        parser.add_argument("--out", default="train_seed.json")

    def handle(self, *args, **opts):
        from rest_framework.authtoken.models import Token

        from core import feature_flags as FF
        from core import train_data
        from core import train_engine as TE
        from core.models import FeatureFlag, User
        from core.phone import find_user

        checks = []

        def check(name, ok, detail=None):
            checks.append({"check": name, "ok": bool(ok), "detail": detail})

        train_data.load()
        problems = train_data.check()
        check("official_trains_loaded", not problems, problems[:5])

        a, b = find_user("01700000001"), find_user("01700000002")
        riders = []
        for i, phone in enumerate(RIDERS):
            u = find_user(phone) or User.objects.create_user(
                name="Sample rider %d" % (i + 1), phone=phone, password=RIDER_PASSWORD)
            riders.append(u)
        FF.ensure_seeded()
        ids = sorted({u.pk for u in [a, b] + riders if u is not None})
        n = FeatureFlag.objects.filter(key="train_tracker").update(
            enabled_all=False, enabled_play=False, allow_user_ids=ids)
        FF.invalidate()
        check("flag_preview_only", n == 1, {"allow": ids})

        def client(u):
            return Client(HTTP_AUTHORIZATION="Token " + Token.objects.get_or_create(user=u)[0].key,
                          HTTP_ACCEPT_LANGUAGE="en")

        ca = client(a)
        for q in ("771", "Rangpur Express", "৭৭১"):
            r = ca.get("/api/v1/train/search", {"q": q})
            rows = r.json().get("trains", []) if r.status_code == 200 else []
            check("search_%s" % q.replace(" ", "_"), any(x["no"] == "771" for x in rows),
                  {"status": r.status_code, "n": len(rows)})
        r = ca.get("/api/v1/train/search", {"q": "Rangpur Express"})
        rows = {x["no"]: x for x in (r.json().get("trains") or [])} if r.status_code == 200 else {}
        for no, (dep, arr, off) in WANT.items():
            x = rows.get(no) or {}
            check("times_%s" % no, (x.get("dep"), x.get("arr"), x.get("off_days")) == (dep, arr, off),
                  {k: x.get(k) for k in ("name_bn", "name_en", "dep", "arr", "off_days")})

        # the switch is OFF for everyone else
        plain = find_user("01999000199") or User.objects.create_user(
            name="Sample non-tester", phone="01999000199", password=RIDER_PASSWORD)
        r = client(plain).get("/api/v1/train/search", {"q": "771"})
        check("flag_off_for_normal_user", r.status_code == 403, {"status": r.status_code})

        want_redis = bool(os.environ.get("TRAIN_LIVE_REDIS_URL"))
        rc = TE.STORE._redis()
        ok_redis = False
        if rc is not None:
            try:
                ok_redis = bool(rc.ping())
            except Exception as e:   # noqa: BLE001
                check("redis_ping", False, str(e)[:200])
        check("redis_live_store", ok_redis or not want_redis, {"url_set": want_redis})

        out = {"riders": list(RIDERS), "checks": checks,
               "failed_critical": [x["check"] for x in checks if not x["ok"]]}
        with open(opts["out"], "w", encoding="utf-8") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1, default=str)
        for x in checks:
            self.stdout.write("%s %s %s" % ("OK " if x["ok"] else "BAD", x["check"],
                                            json.dumps(x["detail"], default=str)[:300]))
