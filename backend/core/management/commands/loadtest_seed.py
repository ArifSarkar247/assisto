"""manage.py loadtest_seed --users N --out tokens.json

CI-ONLY (.github/workflows/loadtest.yml): fills a THROW-AWAY database with
realistic synthetic users, circles, chats, groups, reminders and ledger rows
(core/perf_seed.py) and writes each user's token + chat ids for Locust.

Refuses to run unless LOADTEST_ALLOW_SEED=1 AND the database name starts with
"loadtest" — it can never write into the live Assisto database.
"""
import json
import os
import time

from django.core.management.base import BaseCommand, CommandError
from django.db import connection


class Command(BaseCommand):
    help = "CI load test only: seed a throw-away DB with synthetic users."

    def add_arguments(self, p):
        p.add_argument("--users", type=int, default=1000)
        p.add_argument("--peers", type=int, default=8)
        p.add_argument("--msgs", type=int, default=12)
        p.add_argument("--groups", type=int, default=2)
        p.add_argument("--group-size", type=int, default=6)
        p.add_argument("--group-msgs", type=int, default=20)
        p.add_argument("--out", required=True)

    def handle(self, *a, **o):
        name = str(connection.settings_dict.get("NAME") or "")
        if os.getenv("LOADTEST_ALLOW_SEED") != "1" or not name.startswith("loadtest"):
            raise CommandError("refusing: only for a throw-away 'loadtest*' DB "
                               "with LOADTEST_ALLOW_SEED=1")
        from core import perf_seed as S
        from core.models import CircleGroupMember, CircleMember
        t0 = time.time()
        pairs = S.make_users(o["users"])
        users = [u for u, _ in pairs]
        counts = S.seed_world(users, peers=o["peers"], msgs=o["msgs"],
                              groups=o["groups"], group_size=o["group_size"],
                              group_msgs=o["group_msgs"])
        edges, groups = {}, {}
        for eid, uid in CircleMember.objects.filter(
                user__in=users, state="accepted").values_list("id", "user_id"):
            edges.setdefault(uid, []).append(eid)
        for gid, uid in CircleGroupMember.objects.filter(
                member__in=users).values_list("group_id", "member_id"):
            groups.setdefault(uid, []).append(gid)
        rows = [{"token": tok, "edges": edges.get(u.id, [])[:10],
                 "groups": groups.get(u.id, [])[:5]} for u, tok in pairs]
        with open(o["out"], "w") as fh:
            json.dump(rows, fh)
        with connection.cursor() as c:
            c.execute("ANALYZE")
        counts["seconds"] = round(time.time() - t0, 1)
        self.stdout.write(json.dumps(counts))
