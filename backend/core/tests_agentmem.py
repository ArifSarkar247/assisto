"""WP-MEMORY: life-graph memory (sealing, own-data only, API, export, delete
all, consent / suggestions, planner scope + masking, weekly learning cron,
retention, pause) and the server-side health answer filter. No AI call: the
planner is a scripted override (no key, no spend)."""
import json
from datetime import date, timedelta
from decimal import Decimal
from io import StringIO
from unittest import mock

from django.core import mail
from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import credits as CR
from core import feature_flags as FF
from core.agentcore import health_guard as HG
from core.agentcore import memory as MEM
from core.agentcore import planner as PL
from core.agentcore import runner as RN
from core.agentcore import tools as TL
from core.agentcore import trust as T
from core.models import (Account, AgentMemoryPrefs, AuditLog, CircleMember, FeatureFlag, Journey,
                         MemoryItem, Transaction, User)

API = "/api/v1/agent-core/memory"


def _user(n, credits=100, lang="bn"):
    u = User.objects.create(name="M%d" % n, phone="+8801700%06d" % n, username="+8801700%06d" % n,
                            language=lang)
    if credits:
        CR.grant(u, CR.FREE, credits, note="t")
    u.refresh_from_db()
    return u


class _Scripted:
    def __init__(self, *raws):
        self.raws = list(raws)
        self.reqs = []

    def plan(self, req):
        self.reqs.append(req)
        raw = self.raws.pop(0) if self.raws else {"v": 1, "steps": [], "answer": "ok"}
        return PL.PlanResult(raw=json.dumps(raw, ensure_ascii=False), credits=0)


class _Base(TestCase):
    def setUp(self):
        cache.clear()
        FF.invalidate()
        FeatureFlag.objects.update_or_create(key="agent_core", defaults={"enabled_all": True,
                                                                        "enabled_play": True})
        FF.invalidate()
        self.u = _user(1)
        self.other = _user(2)
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def tearDown(self):
        PL.set_planner(None)
        FF.invalidate()

    def fact(self, user=None, **kw):
        d = {"type": "person", "label": "আম্মু", "relation": "মা", "value": "জন্মদিন ১২ মার্চ"}
        d.update(kw)
        return MEM.create_fact(user or self.u, d)

    def ctx(self, user=None, key="ac:1:2"):
        return RN.Ctx(user=user or self.u, now=timezone.now(), lang="bn", idem_key=key)


# ------------------------------------------------------------------ storage
class SealingTests(_Base):
    def test_fact_is_sealed_at_rest_and_round_trips(self):
        f = self.fact(value="চট্টগ্রামে থাকে, ফোন 01711234567")
        row = MemoryItem.all_rows.get(pk=f["id"])
        for clear in ("আম্মু", "চট্টগ্রাম", "01711234567", "মা"):
            self.assertNotIn(clear, row.detail)
            self.assertNotIn(clear, row.title)
        self.assertTrue(row.detail.startswith("gAAAA"))          # Fernet token
        self.assertEqual(row.category, "graph")
        self.assertEqual(MEM.unseal_node(row)["label"], "আম্মু")
        self.assertEqual(row.fingerprint and len(row.fingerprint), 64)
        self.assertNotIn("আম্মু", row.fingerprint)

    def test_legacy_paths_never_see_graph_rows(self):
        MemoryItem.objects.create(user=self.u, title="legacy note")
        self.fact()
        self.assertEqual(MemoryItem.objects.filter(user=self.u).count(), 1)
        self.assertEqual(self.u.memories.count(), 1)
        self.assertEqual(MemoryItem.graph.filter(user=self.u).count(), 1)
        r = self.c.get("/api/v1/memory/")
        body = r.json()
        rows = body["results"] if isinstance(body, dict) else body
        self.assertEqual([m["title"] for m in rows], ["legacy note"])
        # the account export carries the graph decrypted, not the sealed blob
        r = self.c.get("/api/v1/export")
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertEqual(len(d["memories"]), 1)
        self.assertEqual(d["life_graph"]["facts"][0]["label"], "আম্মু")

    def test_user_delete_cascades_graph_and_prefs(self):
        self.fact()
        MEM.set_prefs(self.u, {"learning_paused": True})
        uid = self.u.id
        self.u.delete()
        self.assertFalse(MemoryItem.all_rows.filter(user_id=uid).exists())
        self.assertFalse(AgentMemoryPrefs.objects.filter(user_id=uid).exists())


# ------------------------------------------------------------------ API
class ApiTests(_Base):
    def test_flag_off_is_403(self):
        FeatureFlag.objects.filter(key="agent_core").update(enabled_all=False, enabled_play=False)
        FF.invalidate()
        for path in (API, API + "/export", API + "/prefs"):
            self.assertEqual(self.c.get(path).status_code, 403, path)

    def test_crud_browse_by_type(self):
        r = self.c.post(API, {"type": "place", "label": "অফিস", "value": "বনানী"}, format="json")
        self.assertEqual(r.status_code, 201)
        fid = r.json()["id"]
        self.assertEqual(r.json()["origin"], "user")
        self.c.post(API, {"type": "person", "label": "আম্মু", "value": "x"}, format="json")
        d = self.c.get(API + "?type=place").json()
        self.assertEqual([f["label"] for f in d["facts"]], ["অফিস"])
        self.assertEqual(d["counts"]["place"], 1)
        self.assertEqual(d["counts"]["person"], 1)
        self.assertEqual(d["total"], 2)
        r = self.c.patch("%s/%d" % (API, fid), {"value": "গুলশান"}, format="json")
        self.assertEqual(r.json()["value"], "গুলশান")
        self.assertEqual(r.json()["history"][-1]["what"], "edited")
        self.assertEqual(self.c.get("%s/%d" % (API, fid)).json()["value"], "গুলশান")
        self.assertEqual(self.c.delete("%s/%d" % (API, fid)).status_code, 204)
        self.assertEqual(self.c.get("%s/%d" % (API, fid)).status_code, 404)

    def test_validation_and_secret_refusal(self):
        self.assertEqual(self.c.post(API, {"type": "x", "label": "a"}, format="json").json()["error"],
                         "bad_type")
        self.assertEqual(self.c.post(API, {"type": "place"}, format="json").json()["error"], "empty")
        for bad, code in (("my password is hunter2", "secret_refused"),
                          ("বিকাশ পিন ৪৩২১", "secret_refused"), ("OTP 123456", "secret_refused"),
                          ("NID 1234567890123", "id_refused"),
                          ("card 4111 1111 1111 1111", "id_refused")):
            r = self.c.post(API, {"type": "preference", "label": "x", "value": bad}, format="json")
            self.assertEqual(r.status_code, 400, bad)
            self.assertEqual(r.json()["error"], code, bad)
        # a phone number is the user's own data and allowed (masked before AI)
        r = self.c.post(API, {"type": "person", "label": "রহিম", "value": "01711234567"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(MemoryItem.graph.filter(user=self.u).count(), 1)

    def test_own_data_only(self):
        mine = self.fact()
        theirs = self.fact(user=self.other, label="OTHER-SECRET")
        d = self.c.get(API).json()
        self.assertEqual([f["id"] for f in d["facts"]], [mine["id"]])
        for m in ("get", "patch", "delete"):
            r = getattr(self.c, m)("%s/%d" % (API, theirs["id"]), {"value": "x"}, format="json")
            self.assertEqual(r.status_code, 404, m)
        r = self.c.post("%s/%d/approve" % (API, theirs["id"]))
        self.assertEqual(r.status_code, 404)
        self.assertNotIn(b"OTHER-SECRET", self.c.get(API + "/export").content)
        self.c.post(API + "/delete-all", {"confirm": "DELETE"}, format="json")
        self.assertTrue(MemoryItem.graph.filter(pk=theirs["id"]).exists())

    def test_export_contents_download_never_emailed(self):
        self.fact()
        MEM.suggest(self.u, "routine", "বাজার", "শুক্রবার", "learn", fp_key="t1")
        row, _ = MEM.suggest(self.u, "routine", "rejected-thing", "zzz", "learn", fp_key="t2")
        MEM.reject(self.u, row.pk)
        MEM.set_prefs(self.u, {"retention_months": 12})
        r = self.c.get(API + "/export")
        self.assertEqual(r.status_code, 200)
        self.assertIn("attachment", r["Content-Disposition"])
        self.assertIn("assisto-life-graph.json", r["Content-Disposition"])
        self.assertEqual(r["Cache-Control"], "no-store")
        d = json.loads(r.content.decode())
        self.assertEqual(d["format"], "assisto-life-graph")
        self.assertEqual(d["user_id"], self.u.id)
        self.assertEqual(d["facts"][0]["label"], "আম্মু")
        self.assertEqual(d["facts"][0]["provenance"]["by"], "user")
        self.assertIn("created_at", d["facts"][0])
        self.assertEqual([s["label"] for s in d["suggestions"]], ["বাজার"])
        self.assertEqual(d["settings"]["retention_months"], 12)
        self.assertNotIn("rejected-thing", r.content.decode())
        self.assertEqual(len(mail.outbox), 0)
        self.assertTrue(AuditLog.objects.filter(user=self.u, action="memory.graph.export").exists())

    def test_delete_all_really_deletes(self):
        for i in range(5):
            self.fact(label="f%d" % i)
        MEM.suggest(self.u, "routine", "s", "v", "learn", fp_key="a")
        row, _ = MEM.suggest(self.u, "routine", "s2", "v2", "learn", fp_key="b")
        MEM.reject(self.u, row.pk)
        self.fact(user=self.other)
        legacy = MemoryItem.objects.create(user=self.u, title="legacy")
        r = self.c.post(API + "/delete-all", {}, format="json")
        self.assertEqual(r.json()["error"], "confirm_needed")
        self.assertEqual(MemoryItem.graph.filter(user=self.u).count(), 7)
        r = self.c.post(API + "/delete-all", {"confirm": "DELETE"}, format="json")
        self.assertEqual(r.json()["deleted"], 7)
        self.assertEqual(MemoryItem.all_rows.filter(user=self.u).exclude(pk=legacy.pk).count(), 0)
        self.assertEqual(MemoryItem.graph.filter(user=self.other).count(), 1)
        self.assertTrue(MemoryItem.objects.filter(pk=legacy.pk).exists())
        # a rejected fingerprint is gone too, so nothing remembers it existed
        self.assertFalse(MemoryItem.all_rows.filter(user=self.u, status="rejected").exists())

    def test_prefs_pause_and_retention(self):
        self.assertFalse(self.c.get(API + "/prefs").json()["learning_paused"])
        r = self.c.post(API + "/prefs", {"learning_paused": True, "retention_months": 6}, format="json")
        self.assertTrue(r.json()["learning_paused"])
        self.assertEqual(r.json()["retention_months"], 6)
        self.assertEqual(self.c.post(API + "/prefs", {"retention_months": 7},
                                     format="json").status_code, 400)
        self.assertTrue(self.c.get(API).json()["prefs"]["learning_paused"])


# ------------------------------------------------------------------ consent
class SuggestionTests(_Base):
    def test_agent_remember_is_only_a_suggestion(self):
        out = TL.get("memory.remember").run(self.ctx(), {"type": "date", "label": "মেয়ের জন্মদিন",
                                                           "value": "৩ এপ্রিল"})
        self.assertTrue(out["suggested"])
        row = MemoryItem.graph.get(pk=out["id"])
        self.assertEqual((row.status, row.origin, row.needs_review), ("suggested", "run", True))
        self.assertEqual(MEM.unseal_node(row)["prov"]["run"], 1)
        self.assertFalse(MemoryItem.graph.filter(user=self.u, status="active").exists())
        # the planner never sees a suggestion
        self.assertEqual(MEM.for_goal(self.u, "family", "মেয়ের জন্মদিন কবে", T.Vault()), [])
        # idempotent re-run of the same step
        again = TL.get("memory.remember").run(self.ctx(), {"type": "date", "label": "মেয়ের জন্মদিন",
                                                             "value": "৩ এপ্রিল"})
        self.assertEqual(again["id"], out["id"])
        f = self.c.post("%s/%d/approve" % (API, out["id"])).json()
        self.assertEqual(f["status"], "active")
        self.assertEqual(len(MEM.for_goal(self.u, "family", "মেয়ের জন্মদিন কবে", T.Vault())), 1)
        self.assertEqual(self.c.post("%s/%d/approve" % (API, out["id"])).json()["status"], "active")

    def test_agent_refuses_secrets(self):
        for v in ("pin 1234", "পাসওয়ার্ড abc", "NID 1234567890", "4111 1111 1111 1111"):
            out = TL.get("memory.remember").run(self.ctx(key="ac:9:%d" % len(v)),
                                               {"type": "preference", "label": "x", "value": v})
            self.assertFalse(out["suggested"], v)
            self.assertIn(out["refused"], ("secret", "id_number"))
        self.assertFalse(MemoryItem.graph.filter(user=self.u).exists())

    def test_reject_wipes_content_and_never_reproposes(self):
        row, why = MEM.suggest(self.u, "routine", "বাসাভাড়া", "৫ তারিখে", "learn", fp_key="learn|x")
        self.assertEqual(why, "created")
        self.c.post("%s/%d/reject" % (API, row.pk))
        row.refresh_from_db()
        self.assertEqual((row.status, row.detail), ("rejected", ""))
        again, why = MEM.suggest(self.u, "routine", "বাসাভাড়া", "৫ তারিখে", "learn", fp_key="learn|x")
        self.assertIsNone(again)
        self.assertEqual(why, "exists")
        d = self.c.get(API + "?status=suggested").json()
        self.assertEqual(d["facts"], [])

    def test_update_suggestion_changes_fact_only_after_approval(self):
        f = self.fact(type="place", label="অফিস", relation="", value="বনানী")
        out = TL.get("memory.update").run(self.ctx(), {"id": f["id"], "value": "গুলশান"})
        self.assertTrue(out["suggested"])
        self.assertEqual(self.c.get("%s/%d" % (API, f["id"])).json()["value"], "বনানী")
        MEM.approve(self.u, out["id"])
        self.assertEqual(self.c.get("%s/%d" % (API, f["id"])).json()["value"], "গুলশান")
        self.assertFalse(MemoryItem.graph.filter(pk=out["id"]).exists())
        # another user's fact id can never be targeted
        theirs = self.fact(user=self.other)
        self.assertEqual(TL.get("memory.update").run(self.ctx(key="ac:1:9"),
                                                     {"id": theirs["id"], "value": "x"})["refused"],
                         "not_found")

    def test_forget_needs_approval_and_is_own_only(self):
        t = TL.get("memory.forget")
        self.assertTrue(t.needs_approval)
        theirs = self.fact(user=self.other)
        self.assertFalse(t.run(self.ctx(), {"id": theirs["id"]})["deleted"])
        self.assertTrue(MemoryItem.graph.filter(pk=theirs["id"]).exists())

    def test_sensitive_auto_flagged_hidden_from_recall_and_planner(self):
        f = self.fact(type="routine", label="ডায়াবেটিস", relation="", value="ডাক্তার করিম")
        self.assertTrue(f["sensitive"])
        self.assertFalse(f["use_in_ai"])
        out = TL.get("memory.recall").run(self.ctx(), {"query": "ডায়াবেটিস"})
        self.assertEqual((out["count"], out["hidden"]), (0, 1))
        self.assertEqual(MEM.for_goal(self.u, "health", "ডায়াবেটিস ডাক্তার", T.Vault()), [])
        # and the learner never proposes one
        _, why = MEM.suggest(self.u, "routine", "নামাজ", "প্রতিদিন ১টায়", "learn", fp_key="r")
        self.assertEqual(why, "sensitive")


# ------------------------------------------------------------------ planner scope
class PlannerScopeTests(_Base):
    def test_planner_gets_only_scoped_masked_capped_facts(self):
        self.fact(label="রহিম", relation="ভাই", value="চট্টগ্রামে থাকে, ফোন 01711234567")
        self.fact(type="business", label="ঢাকায় ডেলিভারি রহিম", value="চার্জ ৳৬০")
        self.fact(type="place", label="রহিমের বাসা", value="আগ্রাবাদ", use_in_ai=False)
        self.fact(type="routine", label="রহিম ডায়াবেটিস", value="ডাক্তার")       # sensitive
        MEM.suggest(self.u, "person", "রহিম", "SUGGESTION-ONLY", "learn", fp_key="s")
        self.fact(user=self.other, label="রহিম", value="OTHER-USER")
        for i in range(15):
            self.fact(type="date", label="রহিম %d" % i, value="তারিখ %d" % i)
        self.fact(label="আম্মু", value="অপ্রাসঙ্গিক")                         # no shared word
        sp = _Scripted({"v": 1, "steps": [], "answer": "ঠিক আছে"})
        PL.set_planner(sp)
        run = RN.start(self.u, "রহিম ভাইয়ের খবর কী?", topic="family")
        self.assertEqual(run.state, "done")
        mem = sp.reqs[0].memory
        self.assertEqual(len(mem), MEM.MAX_FACTS_PER_PLAN)
        self.assertLessEqual(sum(len(m["fact"]) for m in mem), MEM.MAX_PLAN_CHARS)
        rows = {r.pk: r for r in MemoryItem.graph.filter(pk__in=[m["id"] for m in mem])}
        self.assertEqual(len(rows), len(mem))
        for r in rows.values():
            self.assertEqual(r.user_id, self.u.id)
            self.assertIn(r.kind, MEM.TOPIC_TYPES["family"])
            self.assertEqual((r.status, r.sensitive), ("active", False))
        blob = json.dumps(mem, ensure_ascii=False)
        for never in ("ডেলিভারি", "আগ্রাবাদ", "ডায়াবেটিস", "SUGGESTION-ONLY", "OTHER-USER",
                      "অপ্রাসঙ্গিক", "01711234567"):
            self.assertNotIn(never, blob)
        self.assertIn("⟦PHONE_1⟧", blob)                     # masked, not dropped
        self.assertFalse(T.has_raw_pii(PL.build_data(sp.reqs[0])))
        self.assertIn('"memory"', PL.build_data(sp.reqs[0]))
        ev = run.audit.get(event="memory.used")
        self.assertEqual(ev.detail["count"], len(mem))
        self.assertNotIn("রহিম", json.dumps(ev.detail, ensure_ascii=False))
        self.assertTrue(MemoryItem.graph.filter(pk=mem[0]["id"], last_used_at__isnull=False).exists())

    def test_no_memory_key_when_nothing_relevant(self):
        sp = _Scripted({"v": 1, "steps": [], "answer": "ok"})
        PL.set_planner(sp)
        RN.start(self.u, "hello there", topic="family")
        self.assertNotIn('"memory"', PL.build_data(sp.reqs[0]))

    def test_secret_goal_never_reaches_the_planner(self):
        sp = _Scripted()
        PL.set_planner(sp)
        run = RN.start(self.u, "মনে রাখো আমার বিকাশ পিন ৪৩২১", topic="memory")
        self.assertEqual(sp.reqs, [])
        self.assertEqual((run.state, run.llm_calls, run.credits_spent), ("done", 0, 0))
        self.assertIn("কখনো মনে রাখি না", RN.answer_of(run))
        self.assertTrue(run.audit.filter(event="guard.secret").exists())
        self.assertFalse(MemoryItem.graph.filter(user=self.u).exists())


# ------------------------------------------------------------------ weekly learning
class LearningTests(_Base):
    def _seed(self, user):
        acc = Account.objects.create(user=user, name="Cash")
        t = timezone.localdate()
        for k in range(1, 4):
            m = date(t.year, t.month, 1)
            for _ in range(k):
                m = (m - timedelta(days=1)).replace(day=1)
            Transaction.objects.create(user=user, account=acc, kind="expense", amount=Decimal("12000"),
                                       category="বাসাভাড়া", date=m.replace(day=5))
            Transaction.objects.create(user=user, account=acc, kind="expense", amount=Decimal("800"),
                                       category="ওষুধ", date=m.replace(day=5))     # sensitive
        CircleMember.objects.create(user=user, name="আম্মু", relation="mother", state="accepted",
                                    phone="01711234567")
        CircleMember.objects.create(user=user, name="Friend", relation="friend", state="accepted")
        now = timezone.now()
        for d in (2, 5, 9):
            j = Journey.objects.create(traveller=user, destination={"name": "Office", "lat": 23.7},
                                       status="arrived")
            Journey.objects.filter(pk=j.pk).update(created_at=now - timedelta(days=d))

    def test_learns_suggestions_only_idempotent_and_pausable(self):
        self._seed(self.u)
        st = MEM.learn_for_user(self.u, force=True)
        rows = list(MemoryItem.graph.filter(user=self.u))
        self.assertEqual(st["suggested"], len(rows))
        self.assertTrue(rows)
        self.assertTrue(all(r.status == "suggested" and r.origin == "learn" for r in rows))
        labels = {MEM.unseal_node(r)["label"]: MEM.unseal_node(r) for r in rows}
        self.assertIn("বাসাভাড়া", labels)
        self.assertIn("১২,০০০", labels["বাসাভাড়া"]["value"])
        self.assertIn("আম্মু", labels)
        self.assertNotIn("01711234567", json.dumps(labels, ensure_ascii=False))
        self.assertNotIn("Friend", labels)
        self.assertNotIn("ওষুধ", labels)                      # health never by itself
        self.assertIn("Office", labels)
        self.assertNotIn("23.7", json.dumps(labels))          # never coordinates
        self.assertEqual(labels["Office"]["prov"]["rule"], "journey_routine")
        # idempotent: again (forced, and via the cron) proposes nothing new
        self.assertEqual(MEM.learn_for_user(self.u, force=True)["suggested"], 0)
        out = StringIO()
        call_command("agent_memory_learn", stdout=out)
        self.assertEqual(MemoryItem.graph.filter(user=self.u).count(), len(rows))
        # a rejected one is never proposed again
        rej = MemoryItem.graph.filter(user=self.u).first()
        MEM.reject(self.u, rej.pk)
        MEM.learn_for_user(self.u, force=True)
        self.assertEqual(MemoryItem.graph.filter(user=self.u, status="suggested").count(), len(rows) - 1)
        # a pass inside the week is skipped; pause stops learning entirely
        self.assertEqual(MEM.learn_for_user(self.u)["too_soon"], 1)
        MEM.set_prefs(self.u, {"learning_paused": True})
        MemoryItem.graph.filter(user=self.u).delete()
        self.assertEqual(MEM.learn_for_user(self.u, force=True)["paused"], 1)
        self.assertFalse(MemoryItem.graph.filter(user=self.u).exists())

    def test_cron_respects_flag(self):
        self._seed(self.other)
        FeatureFlag.objects.filter(key="agent_core").update(enabled_all=False, enabled_play=False)
        FF.invalidate()
        st = MEM.weekly_tick()
        self.assertEqual(st["users"], 0)
        self.assertFalse(MemoryItem.graph.exists())

    def test_retention_sweep(self):
        old = self.fact(label="old")
        stale = self.fact(label="stale")
        fresh = self.fact(label="fresh")
        now = timezone.now()
        MemoryItem.all_rows.filter(pk=old["id"]).update(updated_at=now - timedelta(days=30 * 19),
                                                        created_at=now - timedelta(days=30 * 19))
        MemoryItem.all_rows.filter(pk=stale["id"]).update(updated_at=now - timedelta(days=30 * 13),
                                                          created_at=now - timedelta(days=30 * 13))
        row, _ = MEM.suggest(self.u, "routine", "s", "v", "learn", fp_key="x")
        MemoryItem.all_rows.filter(pk=row.pk).update(created_at=now - timedelta(days=40))
        st = MEM.retention_sweep(self.u, now)
        self.assertEqual((st["deleted"], st["asked"], st["expired_suggestions"]), (1, 1, 1))
        self.assertFalse(MemoryItem.graph.filter(pk=old["id"]).exists())
        self.assertTrue(self.c.get("%s/%d" % (API, stale["id"])).json()["still_right"])
        self.assertFalse(self.c.get("%s/%d" % (API, fresh["id"])).json()["still_right"])
        r = self.c.post("%s/%d/confirm" % (API, stale["id"])).json()
        self.assertFalse(r["still_right"])
        # a shorter retention deletes sooner
        MEM.set_prefs(self.u, {"retention_months": 6})
        MemoryItem.all_rows.filter(pk=fresh["id"]).update(updated_at=now - timedelta(days=200),
                                                          created_at=now - timedelta(days=200))
        self.assertEqual(MEM.retention_sweep(self.u, now)["deleted"], 1)


# ------------------------------------------------------------------ health filter
class HealthFilterTests(_Base):
    BAD = (
        ("bn", "আপনার ডায়াবেটিস হয়েছে।"), ("bn", "নাপা ৫০০ খান।"), ("bn", "দিনে ৩ বার খাবেন।"),
        ("bn", "এটা সম্ভবত ভাইরাস জ্বর।"), ("bn", "ইনসুলিন নিন।"), ("bn", "ফিজিওথেরাপি শুরু করুন।"),
        ("bn", "মনে হচ্ছে আপনার প্রেশার বেশি।"), ("bn", "ওষুধ খান আর বিশ্রাম নিন।"),
        ("en", "You probably have dengue."), ("en", "Take paracetamol for the fever."),
        ("en", "Take 500 mg twice a day."), ("en", "It sounds like an infection."),
        ("en", "Start physiotherapy next week."), ("en", "Try ibuprofen."),
        ("en", "You may have diabetes."), ("en", "A course of antibiotics will help."),
        ("bl", "apnar gastric hoyeche"), ("bl", "seclo khan"), ("bl", "din e 3 bar khaben"),
        ("bl", "dengue hoyeche mone hocche"), ("bl", "napa 2 ta khan"),
        ("bl", "oshudh khan ar bisram nin"),
    )
    OK = ("প্রতিদিন ৩০ মিনিট হাঁটুন।", "এই মাসে খরচ ৳১২,০০০।", "আপনার রিমাইন্ডার সেট হয়েছে।",
          "রিমাইন্ডার সেট হয়েছে: “নাপা ৫০০ খাওয়া” — ২৮/১০ ২২:০০।", "You have 3 reminders.",
          "Your meter has 50 units left.", "Use Safe Journey to share your trip.",
          "Drink enough water and sleep 7 hours.")

    def test_removes_diagnosis_medicine_dose_therapy(self):
        for lang, s in self.BAD:
            self.assertTrue(HG.advice_hits(s), s)
            out, n = HG.filter_answer("ভালো থাকুন। " + s if lang != "en" else "Stay well. " + s,
                                      "health", lang if lang != "bl" else "bn")
            self.assertEqual(n, 1, s)
            self.assertNotIn(s.strip("।."), out)
            self.assertIn("৯৯৯" if lang != "en" else "999", out)
        for s in self.OK:
            self.assertEqual(HG.advice_hits(s), [], s)
            self.assertEqual(HG.filter_answer(s, "money", "bn"), (s, 0))

    def test_doctor_line_once_for_health_topic(self):
        out, n = HG.filter_answer("প্রতিদিন হাঁটুন।", "health", "bn")
        self.assertEqual(n, 0)
        self.assertEqual(out.count("৯৯৯"), 1)
        self.assertEqual(HG.filter_answer(out, "health", "bn")[0], out)       # idempotent
        out, _ = HG.filter_answer("Napa 500 খান দিনে ৩ বার।", "health", "bn")
        self.assertIn("ডোজ", out)
        self.assertIn("৯৯৯", out)

    def test_runner_filters_every_final_answer(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer":
                                  "আপনার ডেঙ্গু হয়েছে। নাপা ৫০০ খান দিনে ৩ বার। বেশি পানি পান করুন।"}))
        run = RN.start(self.u, "আমার জ্বর কী করব", topic="health")
        a = RN.answer_of(run)
        self.assertNotIn("নাপা", a)
        self.assertNotIn("ডেঙ্গু হয়েছে", a)
        self.assertIn("বেশি পানি পান করুন", a)
        self.assertIn("৯৯৯", a)
        self.assertTrue(run.audit.filter(event="guard.health").exists())
        done = run.audit.get(event="run.done")
        self.assertNotIn("নাপা", done.detail.get("answer", ""))
        # even outside the health topic a dose never gets through
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer": "Take paracetamol 500 mg. Budget is fine."}))
        run = RN.start(self.u, "how is my budget", topic="money", lang="en")
        self.assertNotIn("paracetamol", RN.answer_of(run))
        self.assertIn("Budget is fine", RN.answer_of(run))
        # a clean money answer is untouched by the health filter (its amount is
        # the user's own number — AF-1 rewrites an amount no source supports)
        PL.set_planner(_Scripted({"v": 1, "steps": [], "answer": "এই মাসে খরচ ৳১২,০০০।"}))
        run = RN.start(self.u, "এই মাসে খরচ ১২০০০ টাকা হয়েছে, ঠিক আছে?", topic="money")
        self.assertEqual(RN.answer_of(run), "এই মাসে খরচ ৳১২,০০০।")
