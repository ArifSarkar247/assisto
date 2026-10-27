"""agent-proactive (WP-PROACTIVE): every trigger true/false over seeded rows,
dedupe + cooldown, the daily cap, quiet hours (+ family exception), consent,
flag off, brief/recap content bn/en (+ voice text), cron idempotency, the API,
and a 7-day simulated week over a seeded household + shop.

No AI is ever called (asserted); pushes are counted at the module's seam."""
from datetime import date, datetime, timedelta
from io import StringIO
from unittest import mock

from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import remittance_service as RS
from core.agentcore import proactive as P
from core.models import (Account, AgentNudge, AgentNudgePrefs, CircleMember, CirclePrivacy,
                         FeatureFlag, Journey, JourneyRoutine, Loan, Order, PaCollectionItem,
                         Product, RemittanceProfile, Reminder, ShopEvent, ShopSite, Transaction,
                         User)


def at(day, hh=10, mm=0, month=11):
    """Asia/Dhaka local time on 2026-<month>-<day> (11/10 is a Tuesday)."""
    return timezone.make_aware(datetime(2026, month, day, hh, mm))


def mkuser(n, lang="bn"):
    return User.objects.create(name="U%d" % n, phone="+8801700%06d" % n,
                               username="+8801700%06d" % n, language=lang)


def flags(**over):
    vals = {"agent_core": True, "budget_remittance": True, "home_watchman": True}
    vals.update(over)
    for k, on in vals.items():
        FeatureFlag.objects.update_or_create(key=k, defaults={"enabled_all": on, "enabled_play": on})
    FF.invalidate()


class _Base(TestCase):
    def setUp(self):
        cache.clear()
        flags()
        self.u = mkuser(1)
        self.sent = []
        p = mock.patch.object(P, "_push", side_effect=self._fake_push)
        p.start()
        self.addCleanup(p.stop)
        ai = mock.patch("core.ai.generate", side_effect=AssertionError("no AI in proactive"))
        ai.start()
        self.addCleanup(ai.stop)
        self.addCleanup(FF.invalidate)

    def _fake_push(self, user, nudge):
        self.sent.append((user.pk, nudge.trigger, nudge.dedupe_key))
        return 1

    def stats(self):
        from collections import Counter
        return Counter(users=0, pushed=0, batched=0, card=0, dedupe=0, deferred=0, briefs=0,
                       briefs_pushed=0, skipped_flag=0)

    def keys(self, user=None):
        return set(AgentNudge.objects.filter(user=user or self.u).values_list("trigger", flat=True))

    # ---- seeders (real rows in the existing modules)
    def remit(self, user=None, expected="20000", day=5, bills=(), alerted=""):
        user = user or self.u
        p = RS.profile(user)
        RS.save_profile(p, {"expected_taka": expected, "expected_day": day,
                            "expected_sender": "Karim", "bills": list(bills)})
        if alerted:
            p.missing_alert_month = alerted
            p.save()
        return p

    def bill(self, name, due_day, amount="1500", paid=(), rem=""):
        b = RS.clean_bill({"name": name, "amount": amount, "due_day": due_day, "category": "other"})
        b["paid_months"] = list(paid)
        if rem:
            b["reminder_local_id"] = rem
        return b

    def family(self, parent, child, accepted=True):
        m = CircleMember.objects.create(user=child, peer_user=parent, name="Ma", relation="parent",
                                        state="accepted" if accepted else "pending")
        r = JourneyRoutine.objects.create(user=child, days=["sun", "mon", "tue", "wed", "thu", "fri", "sat"],
                                          time="21:00", destination={"name": "Home"},
                                          watcher_ids=[m.id], minutes=30)
        return m, r


# ====================================================================== triggers
class TriggerTests(_Base):
    def test_bill_due_remittance_bills(self):
        now = at(10)
        self.remit(bills=[self.bill("DESCO", 11), self.bill("WASA", 11, paid=["2026-11"]),
                          self.bill("Gas", 12, rem="r1"), self.bill("Net", 25)])
        c = {x.data["kind"] + x.title_en: x for x in P.eval_bill_due(self.u, now, "bn")}
        self.assertEqual(set(c), {"remitBill due: DESCO", "remitBill due: Gas"})
        self.assertEqual(c["remitBill due: DESCO"].priority, 2)      # tomorrow -> push
        self.assertEqual(c["remitBill due: Gas"].priority, 3)        # phone alarm owns it
        self.assertIn("১৫০০", c["remitBill due: DESCO"].body_bn.replace(",", ""))
        self.assertIn("পরিশোধিত", c["remitBill due: DESCO"].why_bn)
        flags(budget_remittance=False)
        self.assertEqual(P.eval_bill_due(self.u, now, "bn"), [])

    def test_bill_due_loans(self):
        now = at(10)
        Loan.objects.create(user=self.u, kind="taken", person="Rahim", amount=5000,
                            due_date=date(2026, 11, 10))
        Loan.objects.create(user=self.u, kind="taken", person="Settled", amount=5000,
                            due_date=date(2026, 11, 10), settled=True)
        Loan.objects.create(user=self.u, kind="given", person="Given", amount=5000,
                            due_date=date(2026, 11, 10))
        Loan.objects.create(user=self.u, kind="taken", person="Paid", amount=100,
                            due_date=date(2026, 11, 10), repayments=[{"amount": 100}])
        Loan.objects.create(user=self.u, kind="taken", person="Far", amount=100,
                            due_date=date(2026, 11, 20))
        c = P.eval_bill_due(self.u, now, "bn")
        self.assertEqual([x.title_en for x in c], ["Loan repayment due: Rahim"])
        self.assertEqual(c[0].priority, 1)

    def test_remit_missing(self):
        now = at(10)
        self.remit(day=5)
        c = P.eval_remit_missing(self.u, now, "bn")
        self.assertEqual(len(c), 1)
        self.assertEqual(c[0].key, "remit:2026-11")
        self.assertIn("Karim", c[0].body_en)
        # not yet due
        self.assertEqual(P.eval_remit_missing(self.u, at(4), "bn"), [])
        # already shown by the in-app card this month
        self.remit(day=5, alerted="2026-11")
        self.assertEqual(P.eval_remit_missing(self.u, now, "bn"), [])
        # arrived
        self.remit(day=5)
        RS.create_entry(self.u, {"client_id": "abcdefgh01", "amount": "20000", "currency": "BDT",
                                 "received_on": "2026-11-03", "channel": "bkash"})
        self.assertEqual(P.eval_remit_missing(self.u, now, "bn"), [])

    def test_child_not_home_consent_and_journey_rules(self):
        child = mkuser(2)
        _m, r = self.family(self.u, child)
        stranger = mkuser(3)
        self.assertEqual(len(P.eval_child_not_home(self.u, at(10, 21, 25), "bn")), 1)
        self.assertEqual(P.eval_child_not_home(self.u, at(10, 21, 10), "bn"), [])   # grace
        self.assertEqual(P.eval_child_not_home(self.u, at(11, 0, 30), "bn"), [])    # stale
        self.assertEqual(P.eval_child_not_home(stranger, at(10, 21, 25), "bn"), [])  # no consent
        j = Journey.objects.create(traveller=child, status="active")
        self.assertEqual(P.eval_child_not_home(self.u, at(10, 21, 25), "bn"), [])   # sweep owns it
        Journey.objects.filter(pk=j.pk).update(status="arrived", created_at=at(10, 20, 30))
        self.assertEqual(P.eval_child_not_home(self.u, at(10, 21, 25), "bn"), [])   # home
        CircleMember.objects.all().update(state="pending")
        Journey.objects.all().delete()
        self.assertEqual(P.eval_child_not_home(self.u, at(10, 21, 25), "bn"), [])   # consent gone

    def test_stock_low(self):
        now = at(10)
        self.assertEqual(P.eval_stock_low(self.u, now, "bn"), [])
        Product.objects.create(user=self.u, name="Rice", stock=2, low_stock_at=3)
        Product.objects.create(user=self.u, name="Oil", stock=50, low_stock_at=3)
        c = P.eval_stock_low(self.u, now, "bn")
        self.assertEqual((len(c), c[0].priority), (1, 3))
        Product.objects.create(user=self.u, name="Salt", stock=0, low_stock_at=3)
        c = P.eval_stock_low(self.u, now, "bn")
        self.assertEqual(c[0].priority, 2)
        self.assertIn("১টি পণ্য শেষ", c[0].title_bn)

    def test_order_unpaid(self):
        now = at(10, 12)
        o = Order.objects.create(user=self.u, total=900, payment_status="pending_verification")
        Order.objects.filter(pk=o.pk).update(created_at=now - timedelta(hours=1))
        self.assertEqual(P.eval_order_unpaid(self.u, now, "bn"), [])
        Order.objects.filter(pk=o.pk).update(created_at=now - timedelta(hours=3))
        c = P.eval_order_unpaid(self.u, now, "bn")
        self.assertEqual(c[0].data, {"verify": 1, "new": 0, "cod": 0})
        Order.objects.filter(pk=o.pk).update(status="delivered")
        self.assertEqual(P.eval_order_unpaid(self.u, now, "bn"), [])
        o2 = Order.objects.create(user=self.u, total=500, status="shipped", payment="cod")
        Order.objects.filter(pk=o2.pk).update(created_at=now - timedelta(days=5))
        self.assertEqual(P.eval_order_unpaid(self.u, now, "bn")[0].data["cod"], 1)

    def test_meter_low_is_brief_only(self):
        now = at(10)
        m = PaCollectionItem.objects.create(user=self.u, collection="meter/meters",
                                            data={"name": "DESCO", "kind": "electricity",
                                                  "balance": "100", "balance_date": "2026-11-10"})
        for d in ("2026-10-01", "2026-10-21"):
            PaCollectionItem.objects.create(user=self.u, collection="meter/recharges",
                                            data={"meter": m.id, "date": d, "amount": "500"})
        c = P.eval_meter_low(self.u, now, "bn")
        self.assertEqual(len(c), 1)
        self.assertIn("দূর থেকে পড়া হয় না", c[0].why_bn)
        self.assertEqual(P.decide(self.u, P.prefs_for(self.u), c[0], now, (False, True)),
                         ("brief", "batch"))
        PaCollectionItem.objects.filter(pk=m.pk).update(data={**m.data, "balance": "5000"})
        self.assertEqual(P.eval_meter_low(self.u, now, "bn"), [])

    def test_camera_alert_summary(self):
        now = at(10)
        site = ShopSite.objects.create(owner=self.u, name="Shop")
        self.assertEqual(P.eval_camera_alert(self.u, now, "bn"), [])
        e = ShopEvent.objects.create(site=site, type="motion")
        ShopEvent.objects.filter(pk=e.pk).update(created=now - timedelta(hours=3))
        c = P.eval_camera_alert(self.u, now, "bn")
        self.assertEqual((len(c), c[0].trigger), (1, "camera_alert"))
        self.assertEqual(P.decide(self.u, P.prefs_for(self.u), c[0], now, (False, True))[0], "brief")
        ShopEvent.objects.all().update(status="checked")
        self.assertEqual(P.eval_camera_alert(self.u, now, "bn"), [])
        flags(home_watchman=False)
        ShopEvent.objects.all().update(status="open")
        self.assertEqual(P.eval_camera_alert(self.u, now, "bn"), [])

    def test_opt_out_per_trigger(self):
        Product.objects.create(user=self.u, name="Salt", stock=0, low_stock_at=3)
        self.assertTrue(any(c.trigger == "stock_low" for c in P.candidates(self.u, at(10))))
        P.mute_trigger(self.u, "stock_low")
        self.assertFalse(any(c.trigger == "stock_low" for c in P.candidates(self.u, at(10))))


# ====================================================================== rules
class RuleTests(_Base):
    def test_dedupe_and_cooldown(self):
        Product.objects.create(user=self.u, name="Salt", stock=0, low_stock_at=3)
        P.tick(now=at(10, 12), users=[self.u])
        P.tick(now=at(10, 12, 15), users=[self.u])
        self.assertEqual([s[1] for s in self.sent], ["stock_low"])
        self.assertEqual(AgentNudge.objects.filter(trigger="stock_low").count(), 1)
        # next day: new key, but inside the 72 h cooldown -> held for the brief
        P.tick(now=at(11, 12), users=[self.u])
        n = AgentNudge.objects.filter(trigger="stock_low").order_by("-id").first()
        self.assertEqual((n.delivery, n.reason), ("brief", "cooldown"))
        self.assertEqual(len([s for s in self.sent if s[1] == "stock_low"]), 1)

    def test_daily_cap_and_safety_not_counted(self):
        AgentNudgePrefs.objects.create(user=self.u, daily_cap=2, morning_brief=False, evening_recap=False)
        prefs = P.prefs_for(self.u)
        st = self.stats()
        now = at(10, 21, 25)
        for i in range(3):
            c = P.Candidate("order_unpaid", "k%d" % i, 2, "t", "t", "b", "b", "w", "w")
            # distinct triggers would hit cooldown; patch the cooldown away
            with mock.patch.dict(P.TRIGGERS, {"order_unpaid": ("x", "x", 0, True, "business", "orders")}):
                P.deliver(self.u, prefs, c, now, st, (False, True))
        rows = list(AgentNudge.objects.filter(user=self.u).order_by("id"))
        self.assertEqual([(r.delivery, r.reason) for r in rows],
                         [("push", ""), ("push", ""), ("brief", "cap")])
        child = mkuser(2)
        self.family(self.u, child)
        P.tick(now=now, users=[self.u])
        n = AgentNudge.objects.get(trigger="child_not_home")
        self.assertEqual((n.delivery, n.counted), ("push", False))
        self.assertIsNotNone(n.pushed_at)
        self.assertEqual(P.pushed_today(self.u, now.date()), 2)

    def test_quiet_hours_and_family_exception(self):
        AgentNudgePrefs.objects.create(user=self.u, morning_brief=False, evening_recap=False)
        child = mkuser(2)
        self.family(self.u, child)
        Product.objects.create(user=self.u, name="Salt", stock=0, low_stock_at=3)
        now = at(10, 23, 0)                      # default quiet 22:00-07:00
        P.tick(now=now, users=[self.u])
        st = {n.trigger: (n.delivery, n.reason) for n in AgentNudge.objects.filter(user=self.u)}
        self.assertNotIn("stock_low", st)                       # deferred, not stored
        self.assertEqual(st["child_not_home"], ("push", ""))   # family may still reach me
        P.tick(now=at(11, 7, 0), users=[self.u])               # quiet over -> pushed now
        self.assertEqual(AgentNudge.objects.get(trigger="stock_low").delivery, "push")
        AgentNudge.objects.filter(trigger="stock_low").delete()
        # the call DND without the family exception holds even family nudges
        AgentNudge.objects.all().delete()
        CirclePrivacy.objects.create(user=self.u, dnd_enabled=True, dnd_start="22:30",
                                     dnd_end="06:00", dnd_family_exception=False)
        P.tick(now=now, users=[self.u])
        self.assertEqual(AgentNudge.objects.get(trigger="child_not_home").delivery, "brief")
        # outside the DND window (22:10 < 22:30) the DND wins over the agent's own window
        self.assertEqual(P.quiet_state(self.u, P.prefs_for(self.u), timezone.localtime(at(10, 22, 10)))[0],
                         False)

    def test_flag_off_nothing_runs(self):
        flags(agent_core=False)
        Product.objects.create(user=self.u, name="Salt", stock=0, low_stock_at=3)
        st = P.tick(now=at(10, 12), users=[self.u])
        self.assertEqual((st["users"], st["skipped_flag"]), (0, 1))
        self.assertFalse(AgentNudge.objects.exists())
        self.assertEqual(list(P.candidate_users(at(10))), [])
        c = APIClient()
        c.force_authenticate(self.u)
        self.assertEqual(c.get("/api/v1/agent-core/nudges").status_code, 403)
        self.assertEqual(c.get("/api/v1/agent-core/brief").status_code, 403)

    def test_play_hidden_flag_is_off_for_cron(self):
        FeatureFlag.objects.filter(key="agent_core").update(enabled_play=False)
        FF.invalidate()
        self.assertFalse(P.flag_on(self.u))
        FeatureFlag.objects.filter(key="agent_core").update(allow_user_ids=[self.u.pk])
        FF.invalidate()
        self.assertTrue(P.flag_on(self.u))
        self.assertEqual(list(P.candidate_users(at(10))), [self.u])

    def test_cron_idempotent(self):
        Product.objects.create(user=self.u, name="Salt", stock=0, low_stock_at=3)
        Reminder.objects.create(user=self.u, title="Doctor", due_at=at(10, 11))
        with mock.patch("django.utils.timezone.now", return_value=at(10, 8)):
            for _ in range(3):
                out = StringIO()
                call_command("agent_nudges", "--user", str(self.u.pk), stdout=out)
                self.assertIn("agent_nudges", out.getvalue())
        self.assertEqual(AgentNudge.objects.filter(trigger="brief_morning").count(), 1)
        self.assertEqual(AgentNudge.objects.filter(trigger="stock_low").count(), 1)
        self.assertEqual(len(self.sent), 2)


# ====================================================================== brief
class BriefTests(_Base):
    def seed(self):
        acc = Account.objects.create(user=self.u, name="Cash")
        Transaction.objects.create(user=self.u, account=acc, kind="income", amount=30000,
                                   date=date(2026, 11, 1), category="salary")
        Transaction.objects.create(user=self.u, account=acc, kind="expense", amount=1250,
                                   date=date(2026, 11, 10), category="bazar")
        Reminder.objects.create(user=self.u, title="Doctor", due_at=at(10, 17))
        Reminder.objects.create(user=self.u, title="School fee", due_at=at(11, 9))
        Product.objects.create(user=self.u, name="Rice", stock=1, low_stock_at=3)
        self.remit(day=5, bills=[self.bill("DESCO", 11)])

    def test_morning_brief_bn_en_and_voice(self):
        self.seed()
        b = P.build_brief(self.u, "brief_morning", at(10, 7, 45))
        keys = [s["key"] for s in b["sections"]]
        self.assertEqual(keys[:4], ["reminders", "bills", "money", "business"])
        bn, en = P.brief_out(b, "bn"), P.brief_out(b, "en")
        self.assertIn("আজ ১টি: Doctor", bn["text"])
        self.assertIn("DESCO — ৳১,৫০০ (১ দিন পরে)", bn["text"])
        self.assertIn("রেমিট্যান্স এখনো আসেনি", bn["text"])
        self.assertIn("Today 1: Doctor", en["text"])
        self.assertNotRegex(bn["text"].split("\n", 1)[1], r"[0-9]")   # strict Bangla digits
        self.assertNotRegex(en["text"], r"[ঀ-৿]")            # strict English
        self.assertNotIn("৳", bn["voice"]["text"])
        self.assertIn("১,৫০০ টাকা", bn["voice"]["text"])
        self.assertIn("1,500 taka", en["voice"]["text"])
        self.assertEqual((bn["ai_used"], bn["credits"], bn["voice"]["engine"]), (False, 0, "device_tts"))

    def test_evening_recap(self):
        self.seed()
        Reminder.objects.create(user=self.u, title="Gym", due_at=at(10, 8), done=True)
        b = P.brief_out(P.build_brief(self.u, "brief_evening", at(10, 21, 5)), "en")
        self.assertIn("Tomorrow 1: School fee", b["text"])
        self.assertIn("Done today: 1, still open: 1.", b["text"])
        self.assertIn("Spent today: ৳1,250.", b["text"])

    def test_empty_brief_is_honest_and_not_pushed(self):
        st = P.tick(now=at(10, 7, 45), users=[self.u])
        n = AgentNudge.objects.get(trigger="brief_morning")
        self.assertEqual((n.delivery, n.reason, st["briefs_pushed"]), ("card", "empty", 0))
        self.assertIn("আজ বিশেষ কিছু নেই", n.data["bn"]["text"])

    def test_brief_waits_for_quiet_end_and_collects_held(self):
        AgentNudgePrefs.objects.create(user=self.u, morning_at="06:00")
        Product.objects.create(user=self.u, name="Salt", stock=1, low_stock_at=3)
        site = ShopSite.objects.create(owner=self.u, name="Shop")
        ShopEvent.objects.create(site=site, type="motion")
        P.tick(now=at(10, 6, 30), users=[self.u])          # quiet until 07:00
        self.assertFalse(AgentNudge.objects.filter(trigger="brief_morning").exists())
        held = AgentNudge.objects.get(trigger="stock_low")
        self.assertEqual((held.delivery, held.reason), ("brief", "batch"))
        P.tick(now=at(10, 7, 0), users=[self.u])
        b = AgentNudge.objects.get(trigger="brief_morning")
        held.refresh_from_db()
        self.assertEqual((b.delivery, held.in_brief_id), ("push", b.id))
        self.assertIn("পণ্যের স্টক কম", b.data["bn"]["text"])
        self.assertIn("ক্যামেরা সতর্কতা", b.data["bn"]["text"])
        self.assertEqual(AgentNudge.objects.get(trigger="camera_alert").in_brief_id, b.id)


# ====================================================================== API
class ApiTests(_Base):
    def setUp(self):
        super().setUp()
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_cards_open_dismiss_mute_and_prefs(self):
        AgentNudgePrefs.objects.create(user=self.u, quiet_start="00:00", quiet_end="00:00")
        Product.objects.create(user=self.u, name="Salt", stock=0, low_stock_at=3)
        P.tick(now=timezone.now(), users=[self.u])
        r = self.c.get("/api/v1/agent-core/nudges?lang=en")
        self.assertEqual(r.status_code, 200)
        card = [x for x in r.json()["results"] if x["trigger"] == "stock_low"][0]
        self.assertTrue(card["why"])
        nid = card["id"]
        self.assertTrue(self.c.post("/api/v1/agent-core/nudges/%d/open" % nid).json()["nudge"]["opened"])
        r = self.c.post("/api/v1/agent-core/nudges/%d/mute" % nid)
        self.assertIn("stock_low", AgentNudgePrefs.objects.get(user=self.u).off)
        self.assertNotIn(nid, [x["id"] for x in self.c.get("/api/v1/agent-core/nudges").json()["results"]])
        other = mkuser(9)
        n2 = AgentNudge.objects.create(user=other, trigger="stock_low", dedupe_key="x",
                                       for_date=date(2026, 11, 10))
        self.assertEqual(self.c.post("/api/v1/agent-core/nudges/%d/open" % n2.pk).status_code, 404)
        r = self.c.put("/api/v1/agent-core/nudge-prefs",
                       {"daily_cap": 5, "morning_at": "6:15", "triggers": {"stock_low": True,
                                                                          "bill_due": False}},
                       format="json")
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertEqual((d["daily_cap"], d["morning_at"]), (5, "06:15"))
        on = {t["key"]: t["on"] for t in d["triggers"]}
        self.assertEqual((on["stock_low"], on["bill_due"]), (True, False))
        for bad in ({"daily_cap": 11}, {"quiet_start": "25:00"}, {"morning_brief": "yes"}):
            r = self.c.put("/api/v1/agent-core/nudge-prefs", bad, format="json")
            self.assertEqual(r.status_code, 400, bad)

    def test_brief_endpoint(self):
        Reminder.objects.create(user=self.u, title="Doctor", due_at=timezone.now() + timedelta(minutes=30))
        r = self.c.get("/api/v1/agent-core/brief?kind=evening&lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["voice"]["lang"], "en")
        self.assertEqual(self.c.get("/api/v1/agent-core/brief?kind=noon").status_code, 400)


# ====================================================================== 7-day week
class SimulatedWeekTests(_Base):
    """A household (mother = self.u, her son with a 21:00 routine, remittance
    from her husband abroad, a DESCO bill) + her shop (stock, online orders).
    The scheduler runs every 30 minutes for 7 days while life happens."""

    def test_week_timeline(self):
        ma, son = self.u, mkuser(2)
        AgentNudgePrefs.objects.create(user=ma)                   # defaults: cap 3
        self.family(ma, son)
        self.remit(user=ma, day=12, bills=[self.bill("DESCO", 14)])
        rice = Product.objects.create(user=ma, name="Rice", stock=10, low_stock_at=3)
        events = {}
        start = at(9, 0, 0)                                       # Mon 9 Nov 00:00
        t = start
        while t < start + timedelta(days=7):
            loc = timezone.localtime(t)
            day = loc.day
            # the son comes home by 20:50 every day except Thursday 12 Nov
            if loc.hour == 20 and loc.minute == 30 and day != 12:
                j = Journey.objects.create(traveller=son, status="arrived")
                Journey.objects.filter(pk=j.pk).update(created_at=t)
            # Wednesday noon the shop sells out of rice
            if day == 11 and loc.hour == 12 and loc.minute == 0:
                rice.stock = 0
                rice.save()
            # Friday 10:00 restocked
            if day == 13 and loc.hour == 10 and loc.minute == 0:
                rice.stock = 40
                rice.save()
            # Saturday 09:00 a customer sends a payment screenshot
            if day == 14 and loc.hour == 9 and loc.minute == 0:
                o = Order.objects.create(user=ma, total=1200, payment_status="pending_verification")
                events["order"] = o
            # Saturday 16:00 she verifies it
            if day == 14 and loc.hour == 16 and loc.minute == 0:
                Order.objects.filter(pk=events["order"].pk).update(payment_status="verified",
                                                                   status="confirmed")
            # the DESCO bill is paid on Saturday 18:00
            if day == 14 and loc.hour == 18 and loc.minute == 0:
                p = RemittanceProfile.objects.get(user=ma)
                d = RS.profile_data(p)
                d["bills"][0]["paid_months"] = ["2026-11"]
                RS.save_profile(p, d)
            P.tick(now=t, users=[ma, son])
            t += timedelta(minutes=30)

        rows = list(AgentNudge.objects.filter(user=ma).order_by("created_at", "id"))
        by = {}
        for n in rows:
            by.setdefault(n.trigger, []).append(n)
        # exactly one morning brief + one evening recap per day
        self.assertEqual(len(by["brief_morning"]), 7)
        self.assertEqual(len(by["brief_evening"]), 7)
        # the son was late exactly once -> exactly one family nudge, pushed, Thursday
        self.assertEqual([(n.for_date.day, n.delivery) for n in by["child_not_home"]], [(12, "push")])
        # remittance (expected day 12) missed -> once, on the 13th morning
        self.assertEqual([n.for_date.day for n in by["remit_missing"]], [13])
        # DESCO (due 14th): 12th in the brief (2 days), 13th pushed (tomorrow),
        # 14th pushed (due today) — after quiet hours; paid on the 14th -> stops
        bills = [(n.for_date.day, n.delivery) for n in by["bill_due"]]
        self.assertEqual(bills, [(12, "brief"), (13, "push"), (14, "push")])
        # rice out of stock -> one push on Wednesday; nothing after the restock
        stock = [(n.for_date.day, n.delivery) for n in by["stock_low"]]
        self.assertEqual(stock[0], (11, "push"))
        self.assertTrue(all(d in (11, 12, 13) for d, _ in stock))
        self.assertEqual(sum(1 for _, dv in stock if dv == "push"), 1)
        # payment screenshot waited > 2 h -> one nudge on Saturday, none after verified
        self.assertEqual([n.for_date.day for n in by["order_unpaid"]], [14])
        # no spam: per day, counted pushes <= cap; nothing pushed in quiet hours except family
        for d in range(9, 16):
            self.assertLessEqual(P.pushed_today(ma, date(2026, 11, d)), 3, d)
        for n in rows:
            if n.pushed_at and n.trigger not in P.SAFETY:
                h = timezone.localtime(n.pushed_at).hour
                self.assertFalse(h >= 22 or h < 7, (n.trigger, n.pushed_at))
        # the son (no data of his own) only got his briefs; nothing about his mother
        self.assertEqual(self.keys(son) - set(P.BRIEFS), set())
        # each pushed nudge went out once
        pushed = [s for s in self.sent if s[0] == ma.pk]
        self.assertEqual(len(pushed), len(set(pushed)))
