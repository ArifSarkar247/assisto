"""famcare (owner review 28 Oct) — Family Care server rules.

Safety is never paywalled (5 members + SOS + alerts on every plan, no credit
charge); members picked from My Circle in one tap (idempotent, own accepted
edges only, a hand-typed twin is linked not duplicated); shared reminders
land in the member's account (+push unless quiet hours, capped, done
notifies back); family shopping list (household read/tick, strangers
refused); shared vault documents (revocable, audited, unreadable once
revoked or once the recipient leaves the Circle)."""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.core.files.base import ContentFile
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import famcare as FC
from core import plans as P
from core.models import (CircleMember, Document, FamilyDocShare,
                         FamilyListItem, FamilyMember, Reminder, User)

V = "/api/v1"


def mk(phone, name, lang="en"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language=lang)


def cl(u, lang="en"):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE=lang)
    return c


def pair(a, b, relation="mother", **kw):
    ab = CircleMember.objects.create(user=a, peer_user=b, name=b.name, phone=b.phone,
                                     relation=relation, state="accepted", **kw)
    ba = CircleMember.objects.create(user=b, peer_user=a, name=a.name,
                                     state="accepted", direction="incoming")
    return ab, ba


class Spy:
    def __init__(self):
        self.calls = []

    def safe_push(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "ten": ten, "ben": ben,
                           "data": dict(data or {})})
        return True

    def to(self, u):
        return [c for c in self.calls if c["user"] == u.pk]


class Base(TestCase):
    def setUp(self):
        cache.clear()
        self.a = mk("01711200001", "Rina")
        self.b = mk("01711200002", "Mother", lang="bn")
        self.c = mk("01711200003", "Brother")
        self.x = mk("01711200004", "Stranger")
        self.ab, self.ba = pair(self.a, self.b)
        self.ac, self.ca_ = pair(self.a, self.c, relation="brother")
        self.ca, self.cb, self.cc, self.cx = cl(self.a), cl(self.b, "bn"), cl(self.c), cl(self.x)
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy.safe_push)
        p.start()
        self.addCleanup(p.stop)

    def link(self, edge):
        r = self.ca.post(f"{V}/family/from-circle", {"circle_member_id": edge.id},
                         format="json")
        self.assertIn(r.status_code, (200, 201), r.content)
        return r.json()["member"]["id"]


class SafetyNeverPaywalledTests(Base):
    PLANS = ("free", "plus", "premium", "premium_pro", "business", "probashi")

    def _on(self, u, plan):
        if plan == "free":
            u.plan, u.plan_until = "free", None
        else:
            u.plan, u.plan_until = plan, timezone.now() + timedelta(days=30)
        u.save()

    def test_every_plan_keeps_at_least_five_members(self):
        for plan in self.PLANS:
            self._on(self.a, plan)
            ent = P.entitlements(self.a, "en")
            self.assertGreaterEqual(ent["max_family"], 5, plan)
            self.assertTrue(ent["family_safety_free"], plan)
            self.assertGreaterEqual(FC.family_cap(self.a), 5, plan)

    def test_free_user_adds_five_then_an_honest_refusal(self):
        self._on(self.a, "free")
        for i in range(5):
            r = self.ca.post(f"{V}/family/", {"name": f"M{i}", "relation": "x"},
                             format="json")
            self.assertEqual(r.status_code, 201, r.content)
        r = self.ca.post(f"{V}/family/", {"name": "M6"}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "family_limit")
        self.assertEqual(r.json()["limit"], 5)
        lim = self.ca.get(f"{V}/family/limits").json()
        self.assertEqual((lim["limit"], lim["used"], lim["left"]), (5, 5, 0))
        # one-tap pick is held to the same cap
        r = self.ca.post(f"{V}/family/from-circle", {"circle_member_id": self.ab.id},
                         format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "family_limit")

    def test_sos_and_family_alerts_cost_no_credit_on_any_plan(self):
        for plan in self.PLANS:
            self._on(self.a, plan)
            self.a.ai_credits = 0
            self.a.save()
            cache.clear()
            r = self.ca.post(f"{V}/family/sos", {"source": "emergency",
                                                "client_id": plan}, format="json")
            self.assertEqual(r.status_code, 200, (plan, r.content))
            self.assertEqual(User.objects.get(pk=self.a.pk).ai_credits, 0, plan)
            self.assertEqual(self.cb.get(f"{V}/family/alerts").status_code, 200)
            self.ca.post(f"{V}/family/sos/resolve", {}, format="json")

    def test_free_plan_text_says_family_safety_is_free(self):
        from core.logic import pricing
        en = pricing.plan_benefits("free", "en", pricing.DEFAULTS())
        bn = pricing.plan_benefits("free", "bn", pricing.DEFAULTS())
        self.assertTrue(any("Family safety always free" in x for x in en))
        self.assertTrue(any("পরিবারের নিরাপত্তা সবসময় ফ্রি" in x for x in bn))


class PickFromCircleTests(Base):
    def test_candidates_are_my_accepted_circle_only(self):
        CircleMember.objects.create(user=self.a, peer_user=self.x, name="Pending",
                                    state="pending")
        rows = self.ca.get(f"{V}/family/circle-pick").json()["results"]
        self.assertEqual({r["circle_id"] for r in rows}, {self.ab.id, self.ac.id})
        self.assertTrue(all(r["family_id"] is None for r in rows))

    def test_one_tap_is_idempotent_and_copies_circle_fields(self):
        r = self.ca.post(f"{V}/family/from-circle", {"circle_member_id": self.ab.id},
                         format="json")
        self.assertEqual(r.status_code, 201)
        m = r.json()["member"]
        self.assertEqual((m["name"], m["relation"], m["phone"]),
                         ("Mother", "mother", self.b.phone))
        self.assertTrue(m["in_circle"])
        r2 = self.ca.post(f"{V}/family/from-circle", {"circle_member_id": self.ab.id},
                          format="json")
        self.assertEqual(r2.status_code, 200)
        self.assertFalse(r2.json()["created"])
        self.assertEqual(FamilyMember.objects.filter(user=self.a).count(), 1)
        rows = self.ca.get(f"{V}/family/circle-pick").json()["results"]
        self.assertEqual([r["family_id"] for r in rows if r["circle_id"] == self.ab.id],
                         [m["id"]])
        lst = self.ca.get(f"{V}/family/").json()
        lst = lst.get("results", lst) if isinstance(lst, dict) else lst
        self.assertEqual(lst[0]["circle_member"], self.ab.id)

    def test_hand_typed_twin_is_linked_not_duplicated(self):
        fm = FamilyMember.objects.create(user=self.a, name="Ammu", phone="+8801711200002")
        r = self.ca.post(f"{V}/family/from-circle", {"circle_member_id": self.ab.id},
                         format="json")
        self.assertEqual(r.json()["member"]["id"], fm.id)
        self.assertEqual(FamilyMember.objects.filter(user=self.a).count(), 1)

    def test_cannot_pick_someone_elses_circle_edge(self):
        r = self.cx.post(f"{V}/family/from-circle", {"circle_member_id": self.ab.id},
                         format="json")
        self.assertEqual(r.status_code, 404)
        self.assertEqual(r.json()["reason"], "not_in_circle")


class SharedReminderTests(Base):
    def test_assign_lands_in_members_list_with_push(self):
        mid = self.link(self.ab)
        due = (timezone.now() + timedelta(hours=3)).isoformat()
        r = self.ca.post(f"{V}/family/reminders", {"member_id": mid, "title": "Buy medicine",
                                                   "due_at": due}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        rem = Reminder.objects.get(user=self.b)
        self.assertEqual(rem.title, "Buy medicine")
        self.assertEqual(rem.link["type"], "family_task")
        self.assertEqual(rem.link["from_user"], self.a.pk)
        self.assertEqual(len(self.spy.to(self.b)), 1)
        # it is in the member's own reminder list (their sync)
        mine = self.cb.get(f"{V}/reminders/").json()
        mine = mine.get("results", mine) if isinstance(mine, dict) else mine
        self.assertEqual([x["title"] for x in mine], ["Buy medicine"])
        # done syncs back + the assigner hears it once
        self.cb.patch(f"{V}/reminders/{rem.id}/", {"done": True}, format="json")
        t = self.ca.get(f"{V}/family/reminders").json()["assigned_by_me"]
        self.assertTrue(t[0]["done"])
        self.assertEqual(len(self.spy.to(self.a)), 1)
        self.cb.patch(f"{V}/reminders/{rem.id}/", {"title": "Buy medicine!"}, format="json")
        self.assertEqual(len(self.spy.to(self.a)), 1)
        self.assertEqual(len(self.cb.get(f"{V}/family/reminders").json()["assigned_to_me"]), 1)

    def test_quiet_hours_hold_the_push_not_the_task(self):
        mid = self.link(self.ab)
        with mock.patch("core.family_alerts.in_quiet_hours", return_value=True):
            r = self.ca.post(f"{V}/family/reminders", {"member_id": mid, "title": "Call"},
                             format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(Reminder.objects.filter(user=self.b).count(), 1)
        self.assertEqual(self.spy.to(self.b), [])

    def test_hand_typed_member_cannot_get_tasks_and_cap_holds(self):
        fm = FamilyMember.objects.create(user=self.a, name="Typed")
        r = self.ca.post(f"{V}/family/reminders", {"member_id": fm.id, "title": "x"},
                         format="json")
        self.assertEqual(r.json()["reason"], "not_linked")
        mid = self.link(self.ab)
        for i in range(FC.TASKS_PER_PAIR_PER_DAY):
            self.ca.post(f"{V}/family/reminders", {"member_id": mid, "title": f"t{i}"},
                         format="json")
        r = self.ca.post(f"{V}/family/reminders", {"member_id": mid, "title": "late"},
                         format="json")
        self.assertEqual(r.status_code, 429)

    def test_left_circle_means_no_more_tasks_and_cancel(self):
        mid = self.link(self.ab)
        r = self.ca.post(f"{V}/family/reminders", {"member_id": mid, "title": "x"},
                         format="json")
        tid = r.json()["task"]["id"]
        self.assertEqual(self.cx.post(f"{V}/family/reminders/{tid}/cancel").status_code, 404)
        self.assertEqual(self.ca.post(f"{V}/family/reminders/{tid}/cancel").status_code, 200)
        self.ba.blocked = True
        self.ba.save()
        r = self.ca.post(f"{V}/family/reminders", {"member_id": mid, "title": "y"},
                         format="json")
        self.assertEqual(r.json()["reason"], "not_linked")


class ShoppingListTests(Base):
    def test_household_reads_and_ticks_strangers_refused(self):
        self.link(self.ab)
        r = self.ca.post(f"{V}/family/shopping", {"text": "Rice", "qty": "5 kg"},
                         format="json")
        self.assertEqual(r.status_code, 201)
        iid = r.json()["item"]["id"]
        lists = self.cb.get(f"{V}/family/shopping").json()["lists"]
        theirs = [x for x in lists if x["owner_id"] == self.a.pk][0]
        self.assertEqual([i["text"] for i in theirs["items"]], ["Rice"])
        r = self.cb.post(f"{V}/family/shopping/{iid}/toggle", {}, format="json")
        self.assertTrue(r.json()["item"]["done"])
        self.assertEqual(r.json()["item"]["done_by"], "Mother")
        self.cb.post(f"{V}/family/shopping", {"text": "Oil", "owner_id": self.a.pk},
                     format="json")
        self.assertEqual(FamilyListItem.objects.filter(owner=self.a).count(), 2)
        # brother is in the Circle but NOT linked as family -> no access
        self.assertEqual(self.cc.post(f"{V}/family/shopping/{iid}/toggle").status_code, 404)
        self.assertEqual(self.cx.post(f"{V}/family/shopping",
                                      {"text": "x", "owner_id": self.a.pk},
                                      format="json").status_code, 403)
        self.assertEqual([x["owner_id"] for x in self.cx.get(f"{V}/family/shopping")
                          .json()["lists"]], [self.x.pk])
        r = self.ca.post(f"{V}/family/shopping/clear-done", {}, format="json")
        self.assertEqual(r.json()["removed"], 1)


class SharedDocsTests(Base):
    def setUp(self):
        super().setUp()
        self.doc = Document.objects.create(user=self.a, title="Passport", doc_type="passport",
                                           details={"number": "A123"})
        self.doc.file.save("p.txt", ContentFile(b"scan"), save=True)

    def test_share_open_audit_revoke(self):
        mid = self.link(self.ab)
        r = self.ca.post(f"{V}/family/docs", {"document_id": self.doc.id,
                                              "member_ids": [mid]}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        sid = r.json()["shares"][0]["id"]
        # the push never carries the title
        self.assertTrue(all("Passport" not in (c["ten"] + c["ben"]) for c in self.spy.to(self.b)))
        w = self.cb.get(f"{V}/family/docs").json()["shared_with_me"]
        self.assertEqual([x["title"] for x in w], ["Passport"])
        o = self.cb.get(f"{V}/family/docs/{sid}/open").json()
        self.assertEqual(o["details"], {"number": "A123"})
        self.assertEqual(self.cb.get(f"{V}/family/docs/{sid}/file").status_code, 200)
        self.assertEqual(FamilyDocShare.objects.get(pk=sid).opens, 2)
        # strangers and the owner's other circle members can't read it
        self.assertEqual(self.cc.get(f"{V}/family/docs/{sid}/open").status_code, 404)
        # sharing again does not duplicate
        self.ca.post(f"{V}/family/docs", {"document_id": self.doc.id, "member_ids": [mid]},
                     format="json")
        self.assertEqual(FamilyDocShare.objects.filter(revoked_at__isnull=True).count(), 1)
        self.assertEqual(self.cx.post(f"{V}/family/docs/{sid}/revoke").status_code, 404)
        self.assertEqual(self.ca.post(f"{V}/family/docs/{sid}/revoke").status_code, 200)
        self.assertEqual(self.cb.get(f"{V}/family/docs/{sid}/open").status_code, 404)
        mine = self.ca.get(f"{V}/family/docs").json()["shared_by_me"]
        self.assertFalse(mine[0]["active"])
        self.assertEqual(mine[0]["opens"], 2)

    def test_leaving_the_circle_closes_the_share(self):
        mid = self.link(self.ab)
        sid = self.ca.post(f"{V}/family/docs", {"document_id": self.doc.id,
                                                "member_ids": [mid]},
                           format="json").json()["shares"][0]["id"]
        self.ab.state = "declined"
        self.ab.save()
        self.assertEqual(self.cb.get(f"{V}/family/docs/{sid}/open").status_code, 404)
        self.assertEqual(self.cb.get(f"{V}/family/docs").json()["shared_with_me"], [])

    def test_cannot_share_someone_elses_document(self):
        mid = self.link(self.ab)
        other = Document.objects.create(user=self.x, title="X")
        r = self.ca.post(f"{V}/family/docs", {"document_id": other.id, "member_ids": [mid]},
                         format="json")
        self.assertEqual(r.status_code, 404)
