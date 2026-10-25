"""h1-home: home ad hero config (o2 flags reused, refresh >= AdMob minimum,
Free only), one-AdMob-ad-on-home Discover guard, and image in chat — Profit
Guard funding (pool / ads via the ps1 SSV ledger / credits), key-gated vision
providers, safety (face identification refused before cost, medicine doses
only from the label + "consult a doctor"), and "the image is never stored"."""
import base64
from datetime import timedelta
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone

from core import billing
from core import chat_vision_service as CVS
from core import vision_providers as VP
from core.logic import ads as A
from core.logic import chat_vision as CV
from core.logic import discover as D
from core.logic import pricing as P
from core.models import PhotoAdTicket, PhotoStudioJob
from core.tests_ps1_photo import _Base, _png

URL = "/api/v1/chat-vision"


# =========================================================================== pure
class HeroConfigTests(SimpleTestCase):
    def _cfg(self, **kw):
        base = dict(plan="free", paid=False, admob_cfg={}, admob_working=False,
                    flag_rewarded=True, flag_app_open=True, ad_caps={})
        base.update(kw)
        return A.client_config(**base)

    def test_hero_off_by_default_and_muted(self):
        c = self._cfg()
        self.assertFalse(c["hero_enabled"])
        self.assertTrue(c["hero_start_muted"])
        self.assertGreaterEqual(c["hero_refresh_sec"], 60)
        self.assertIn("native", c["test_units"])
        self.assertIn("native", c["units"])

    def test_hero_free_only(self):
        caps = {"hero_enabled": True, "hero_start_muted": False}
        self.assertTrue(self._cfg(ad_caps=caps)["hero_enabled"])
        self.assertFalse(self._cfg(ad_caps=caps)["hero_start_muted"])
        for plan in ("premium", "business"):
            self.assertFalse(self._cfg(plan=plan, paid=True, ad_caps=caps)["hero_enabled"])

    def test_refresh_never_faster_than_admob(self):
        for v, want in ((5, 60), (60, 60), (90, 90), ("x", 90), (None, 90), (99999, 3600)):
            self.assertEqual(A.hero_refresh_sec(v), want)
        self.assertEqual(CV.normalize_hero({"refresh_sec": 10})["refresh_sec"], 60)

    def test_pricing_ad_rewards_hero_flags(self):
        d = P.DEFAULTS()
        self.assertTrue(d["ad_rewards"]["hero_enabled"])          # admob: owner 25 Oct
        self.assertTrue(d["ad_rewards"]["hero_start_muted"])
        n = P.normalize({"ad_rewards": {"hero_enabled": True}})
        self.assertTrue(n["ad_rewards"]["hero_enabled"])
        self.assertTrue(n["ad_rewards"]["hero_start_muted"])
        self.assertEqual(n["home_hero"]["refresh_sec"], 90)
        self.assertIn("chat_vision_image", d["action_costs"])


class DiscoverOneAdTests(SimpleTestCase):
    def _cards(self):
        return [{"id": 1, "type": D.ADMOB, "audience": "all", "enabled": True, "order": 1},
                {"id": 2, "type": D.FEATURE, "audience": "all", "enabled": True, "order": 2}]

    def test_admob_card_dropped_while_hero_ad_shows(self):
        now = timezone.now()
        with_slot = D.visible_cards(self._cards(), "free", 999, now)
        no_slot = D.visible_cards(self._cards(), "free", 999, now, hero_ad=True)
        self.assertIn(D.ADMOB, [c.get("type") for c in with_slot])
        self.assertNotIn(D.ADMOB, [c.get("type") for c in no_slot])
        self.assertIn(D.FEATURE, [c.get("type") for c in no_slot])


class FundingTests(SimpleTestCase):
    def _q(self, **kw):
        base = dict(plan="free", cost_usd=0.01, usd_bdt=120, table_credits=3,
                    net_floor=0.60, credit_bdt=1.0, cfg={}, ad_value=1.0)
        base.update(kw)
        return CV.funding_options(**base)

    def test_paid_plans_pool_never_ads(self):
        for plan in ("premium", "business"):
            q = self._q(plan=plan)
            self.assertTrue(q["ok"])
            self.assertEqual([o["via"] for o in q["options"]], ["pool"])
            self.assertGreaterEqual(q["options"][0]["credits"], 3)

    def test_free_ads_when_profit_guard_allows(self):
        q = self._q()     # 1.2 ৳ cost / (0.7 × 1.0) -> 2 ads
        self.assertEqual(q["reason"], "ok")
        self.assertEqual(q["options"][0], {"via": "ads", "ads": 2})
        self.assertEqual(q["options"][1]["via"], "credits")
        # every offered route covers the cost
        self.assertGreaterEqual(2 * 1.0 * 0.70 + 1e-9, q["cost_bdt"])

    def test_min_ads_is_owner_floor(self):
        q = self._q(ad_value=100.0)          # 1 ad would do; owner says 2-3
        self.assertEqual(q["options"][0]["ads"], 2)

    def test_too_many_ads_closes_ads_route(self):
        q = self._q(ad_value=0.03)           # real BD eCPM floor: ads can't pay
        self.assertEqual(q["reason"], "too_many_ads")
        self.assertEqual([o["via"] for o in q["options"]], ["credits"])

    def test_daily_limit(self):
        q = self._q(used_today=1)
        self.assertEqual(q["reason"], "daily_used")
        self.assertEqual(q["free_left"], 0)
        self.assertEqual([o["via"] for o in q["options"]], ["credits"])

    def test_honest_closed_states(self):
        self.assertEqual(self._q(provider_ready=False)["reason"], "provider_missing")
        self.assertEqual(self._q(cost_usd=0)["reason"], "unpriced")
        self.assertEqual(self._q(guard_over=True)["reason"], "guard_over")
        self.assertEqual(self._q(cfg={"enabled": False})["reason"], "disabled")
        for r in ("provider_missing", "unpriced", "guard_over", "disabled"):
            q = {"provider_missing": self._q(provider_ready=False),
                 "unpriced": self._q(cost_usd=0), "guard_over": self._q(guard_over=True),
                 "disabled": self._q(cfg={"enabled": False})}[r]
            self.assertFalse(q["ok"])
            self.assertEqual(q["options"], [])

    def test_cfg_clamped(self):
        c = CV.normalize_cfg({"min_ads": 9, "max_ads": 0, "max_image_kb": 99999,
                              "provider": "evil"})
        self.assertEqual(c["min_ads"], 3)
        self.assertEqual(c["max_ads"], 3)
        self.assertEqual(c["max_image_kb"], 5120)
        self.assertEqual(c["provider"], "")
        self.assertIn("chat_vision_bad", P.validate_edit({"chat_vision": {"min_ads": -1}}))


class SafetyTests(SimpleTestCase):
    def test_face_identification_questions(self):
        for q in ("Who is this?", "who is she", "Identify this person please",
                  "এটা কে?", "এই লোক কে", "eta ke"):
            self.assertTrue(CV.asks_identification(q), q)
        for q in ("What medicine is this?", "how much is this bill", "এই গাছের নাম কী",
                  "what is this plant"):
            self.assertFalse(CV.asks_identification(q), q)

    def test_dose_only_from_label_plus_doctor_note(self):
        parsed = {"kind": "medicine", "label_text": "Napa 500 mg tablet",
                  "answer": "This is Napa 500 mg. Take 2 tablets every 4 hours."}
        out = CV.postprocess(parsed, lang="en")
        self.assertTrue(out["medicine"])
        self.assertIn("500 mg", out["answer"])
        self.assertNotIn("2 tablets", out["answer"])
        self.assertEqual(out["doses_removed"], 1)
        self.assertIn(CV.DOCTOR_NOTE["en"], out["answer"])

    def test_dose_from_device_ocr_is_kept(self):
        parsed = {"kind": "medicine", "label_text": "",
                  "answer": "The label says 1+0+1 after meals."}
        out = CV.postprocess(parsed, device_text="Seclo 20 mg  1+0+1", lang="bn")
        self.assertIn("1+0+1", out["answer"])
        self.assertIn(CV.DOCTOR_NOTE["bn"], out["answer"])

    def test_face_naming_reply_replaced(self):
        out = CV.postprocess({"kind": "person", "answer": "This is Shakib Al Hasan at a match."},
                             lang="en")
        self.assertTrue(out["face_refused"])
        self.assertEqual(out["answer"], CV.FACE_REFUSAL["en"])

    def test_product_name_on_non_person_photo_is_not_face_refusal(self):
        out = CV.postprocess({"kind": "medicine", "label_text": "Napa Extra 500 mg",
                              "answer": "This is Napa Extra, 500 mg."}, lang="en")
        self.assertFalse(out["face_refused"])
        self.assertIn("Napa Extra", out["answer"])

    def test_parse_reply(self):
        j = CV.parse_reply('```json\n{"kind":"bill","label_text":"DESCO","answer":"৳ 850 due"}\n```')
        self.assertEqual(j["kind"], "bill")
        self.assertEqual(j["answer"], "৳ 850 due")
        self.assertEqual(CV.parse_reply("plain text")["answer"], "plain text")

    def test_system_prompt_rules(self):
        s = CV.system_prompt("bn")
        self.assertIn("never identify", s)
        self.assertIn("consult a doctor", s)
        self.assertIn("Bangla", s)


class ProviderAdapterTests(SimpleTestCase):
    def test_claude_sdk_missing_is_honest(self):
        with mock.patch.dict("sys.modules", {"anthropic": None}):
            with self.assertRaises(VP.VisionError) as e:
                VP.ask("vision_claude", {"api_key": "k"}, image_bytes=b"x", question="q")
        self.assertEqual(str(e.exception), "sdk_missing")

    def test_claude_request_shape(self):
        fake = mock.MagicMock()
        block = mock.MagicMock(type="text", text='{"kind":"plant","answer":"A money plant."}')
        fake.Anthropic.return_value.beta.messages.create.return_value = mock.MagicMock(
            stop_reason="end_turn", content=[block])
        with mock.patch.dict("sys.modules", {"anthropic": fake}):
            out = VP.ask("vision_claude", {"api_key": "k"}, image_bytes=b"\xff\xd8\xffdata",
                         mime="image/jpeg", system="SYS", question="what plant?")
        self.assertIn("money plant", out)
        kw = fake.Anthropic.return_value.beta.messages.create.call_args.kwargs
        self.assertEqual(kw["model"], "claude-sonnet-5-5")
        img = kw["messages"][0]["content"][0]
        self.assertEqual(img["type"], "image")
        self.assertEqual(img["source"]["type"], "base64")
        self.assertEqual(img["source"]["media_type"], "image/jpeg")
        self.assertEqual(kw["system"], "SYS")

    def test_claude_refusal_is_failure(self):
        fake = mock.MagicMock()
        fake.Anthropic.return_value.beta.messages.create.return_value = mock.MagicMock(
            stop_reason="refusal", content=[])
        with mock.patch.dict("sys.modules", {"anthropic": fake}):
            with self.assertRaises(VP.VisionError):
                VP.ask("vision_claude", {"api_key": "k"}, image_bytes=b"x", question="q")

    def test_openai_and_gemini_http(self):
        r = mock.MagicMock(status_code=200)
        r.json.return_value = {"choices": [{"message": {"content": "ok-openai"}}]}
        with mock.patch.object(VP, "_http") as h:
            h.return_value.post.return_value = r
            self.assertEqual(VP.ask("vision_openai", {"api_key": "k"}, image_bytes=b"x",
                                    question="q"), "ok-openai")
            body = h.return_value.post.call_args.kwargs["json"]
            self.assertTrue(body["messages"][1]["content"][1]["image_url"]["url"]
                            .startswith("data:image/jpeg;base64,"))
        g = mock.MagicMock(status_code=200)
        g.json.return_value = {"candidates": [{"content": {"parts": [{"text": "ok-gemini"}]}}]}
        with mock.patch.object(VP, "_http") as h:
            h.return_value.post.return_value = g
            self.assertEqual(VP.ask("vision_gemini", {"api_key": "k"}, image_bytes=b"x",
                                    question="q"), "ok-gemini")
        bad = mock.MagicMock(status_code=401)
        with mock.patch.object(VP, "_http") as h:
            h.return_value.post.return_value = bad
            with self.assertRaises(VP.VisionError):
                VP.ask("vision_openai", {"api_key": "k"}, image_bytes=b"x", question="q")


# =========================================================================== API
class _VBase(_Base):
    def vision(self, cost="0.01", on=True, slug="vision_claude"):
        def is_enabled(s):
            return on and s == slug

        def get(s):
            if on and s == slug:
                return {"api_key": "test-not-a-real-key", "cost_per_image_usd": cost}
            return {}
        p1 = mock.patch("core.integrations.is_enabled", side_effect=is_enabled)
        p2 = mock.patch("core.integrations.get", side_effect=get)
        p1.start(); p2.start()
        self.addCleanup(p1.stop); self.addCleanup(p2.stop)

    def set_ad_value(self, v):
        row = billing.get_config()
        d = dict(row.data)
        ps = dict(d.get("photo_studio") or {})
        ps["ad_value_bdt"] = v
        d["photo_studio"] = ps
        row.data = d
        row.save()

    def create(self, via="", question="What is this?"):
        return self.client.post(URL + "/jobs", {"via": via, "question": question},
                                format="json", HTTP_ACCEPT_LANGUAGE="en")

    def answer(self, jid, img=None, question="What medicine is this?", **kw):
        img = _png() if img is None else img
        return self.client.post(URL + "/jobs/%d/answer" % jid,
                                {"image_b64": base64.b64encode(img).decode(),
                                 "question": question, **kw},
                                format="json", HTTP_ACCEPT_LANGUAGE="en")


class VisionConfigApiTests(_VBase):
    def test_needs_key_state(self):
        self.as_(self.free)
        j = self.client.get(URL + "/config", HTTP_ACCEPT_LANGUAGE="en").json()
        self.assertTrue(j["free"])
        self.assertFalse(j["providers"]["ready"])
        self.assertIn("key", j["providers"]["needs"])
        self.assertEqual(j["quote"]["reason"], "provider_missing")
        self.assertTrue(j["quote"]["message"])
        self.assertFalse(j["stores_images"])
        r = self.create("credits")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["reason"], "provider_missing")

    def test_unpriced_provider_never_used(self):
        self.vision(cost="0")
        row = billing.get_config()
        d = dict(row.data)
        ac = dict(d.get("action_costs") or P.DEFAULTS()["action_costs"])
        ac["chat_vision_image"] = {"provider_cost": 0, "credits": 3}
        d["action_costs"] = ac
        row.data = d
        row.save()
        self.as_(self.free)
        j = self.client.get(URL + "/config").json()
        self.assertFalse(j["providers"]["ready"])

    def test_ads_config_reuses_o2_flags(self):
        self.as_(self.free)
        j = self.client.get("/api/v1/ads/config").json()
        # admob (owner 25 Oct): the home native card is ON for Free users
        self.assertTrue(j["hero_enabled"])
        self.assertTrue(j["hero_start_muted"])
        self.as_(self.prem)
        self.assertFalse(self.client.get("/api/v1/ads/config").json()["hero_enabled"])
        self.as_(self.free)
        row = billing.get_config()
        d = dict(row.data)
        ar = dict(d.get("ad_rewards") or {})
        ar["hero_enabled"] = False
        d["ad_rewards"] = ar
        row.data = d
        row.save()
        self.assertFalse(self.client.get("/api/v1/ads/config").json()["hero_enabled"])


class VisionJobApiTests(_VBase):
    REPLY = ('{"kind":"medicine","label_text":"Napa 500 mg",'
             '"answer":"This is Napa 500 mg (paracetamol). Take 3 tablets now."}')

    def test_premium_pool_answer_and_nothing_stored(self):
        self.vision()
        self.as_(self.prem)
        r = self.create()
        self.assertEqual(r.status_code, 201, r.content)
        job = r.json()["job"]
        self.assertEqual(job["funding"], "pool")
        self.assertEqual(job["status"], "funded")
        self.prem.refresh_from_db()
        self.assertEqual(self.prem.ai_credits, 90 - job["credits_charged"])
        with mock.patch.object(VP, "ask", return_value=self.REPLY) as ask:
            r = self.answer(job["id"], device_text="NAPA 500 mg")
        self.assertEqual(r.status_code, 200, r.content)
        a = r.json()["job"]
        self.assertEqual(a["status"], "done")
        self.assertIn("500 mg", a["answer"])
        self.assertNotIn("3 tablets", a["answer"])
        self.assertIn("consult a doctor", a["answer"])
        self.assertTrue(a["medicine"])
        self.assertEqual(ask.call_args.kwargs["mime"], "image/png")
        row = PhotoStudioJob.objects.get(pk=job["id"])
        self.assertEqual(row.result_name, "")
        self.assertEqual(row.preview_name, "")
        self.assertEqual(row.prompt, "")
        self.assertNotIn("NAPA", str(row.options))     # device text not stored
        self.assertEqual(set(row.options), {"answer", "kind", "medicine",
                                            "doses_removed", "face_refused"})
        self.assertGreater(row.cost_bdt, 0)
        # re-asking the done job never charges or calls again
        with mock.patch.object(VP, "ask") as ask2:
            self.assertEqual(self.answer(job["id"]).status_code, 200)
            ask2.assert_not_called()

    def test_face_identification_refused_before_any_cost(self):
        self.vision()
        self.as_(self.prem)
        r = self.create(question="Who is this person?")
        self.assertEqual(r.status_code, 422)
        self.assertTrue(r.json()["refused"])
        self.prem.refresh_from_db()
        self.assertEqual(self.prem.ai_credits, 90)
        self.assertFalse(PhotoStudioJob.objects.filter(feature="chat_vision").exists())

    def test_free_ads_via_ps1_ssv_ledger(self):
        self.vision()
        self.set_ad_value(1.0)
        self.as_(self.free)
        q = self.client.get(URL + "/config").json()["quote"]
        self.assertEqual(q["options"][0], {"via": "ads", "ads": 2})
        jid = self.create("ads").json()["job"]["id"]
        # not funded yet -> provider never runs
        with mock.patch.object(VP, "ask") as ask:
            self.assertEqual(self.answer(jid).status_code, 402)
            ask.assert_not_called()
        for i in range(2):
            t = self.client.post(URL + "/jobs/%d/ad-ticket" % jid, {}, format="json").json()
            self.assertEqual(self.ssv(t["nonce"], self.free, "cv-%d" % i).status_code, 200)
        self.assertEqual(PhotoStudioJob.objects.get(pk=jid).status, "funded")
        self.assertEqual(PhotoAdTicket.objects.filter(job_id=jid, status="verified").count(), 2)
        with mock.patch.object(VP, "ask", return_value='{"kind":"plant","answer":"Tulsi."}'):
            r = self.answer(jid, question="what plant")
        self.assertEqual(r.json()["job"]["answer"], "Tulsi.")
        # daily limit: second ads job refused, credits still offered
        q = self.client.get(URL + "/config").json()["quote"]
        self.assertEqual(q["reason"], "daily_used")
        self.assertEqual(self.create("ads").status_code, 409)

    def test_no_fill_switch_to_credits(self):
        self.vision()
        self.set_ad_value(1.0)
        self.free.ai_credits = 10
        self.free.save()
        self.as_(self.free)
        jid = self.create("ads").json()["job"]["id"]
        r = self.client.post(URL + "/jobs/%d/fund" % jid, {}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["job"]["status"], "funded")
        self.free.refresh_from_db()
        self.assertLess(self.free.ai_credits, 10)

    def test_free_no_credits_insufficient(self):
        self.vision()
        self.as_(self.free)
        r = self.create("credits")
        self.assertEqual(r.status_code, 402)

    def test_provider_failure_retry_then_refund(self):
        self.vision()
        self.as_(self.prem)
        job = self.create().json()["job"]
        with mock.patch.object(VP, "ask", side_effect=VP.VisionError("http_500")):
            for _ in range(3):
                r = self.answer(job["id"])
                self.assertEqual(r.status_code, 502)
        self.assertEqual(PhotoStudioJob.objects.get(pk=job["id"]).status, "failed")
        self.prem.refresh_from_db()
        self.assertEqual(self.prem.ai_credits, 90)

    def test_bad_and_oversized_images(self):
        self.vision()
        self.as_(self.prem)
        jid = self.create().json()["job"]["id"]
        self.assertEqual(self.answer(jid, img=b"not an image").status_code, 400)
        big = b"\xff\xd8\xff" + b"0" * (4097 * 1024)
        self.assertEqual(self.answer(jid, img=big).status_code, 413)

    def test_other_users_job_404(self):
        self.vision()
        self.as_(self.prem)
        jid = self.create().json()["job"]["id"]
        self.as_(self.biz)
        self.assertEqual(self.client.get(URL + "/jobs/%d" % jid).status_code, 404)
        self.assertEqual(self.answer(jid).status_code, 404)

    def test_owner_can_edit_chat_vision_block(self):
        self.as_(self.owner)
        r = self.client.post("/api/v1/admin/pricing",
                             {"config": {"chat_vision": {"free_detailed_per_day": 2},
                                         "home_hero": {"refresh_sec": 120}}},
                             format="json")
        self.assertEqual(r.status_code, 200, r.content)
        c = billing.cfg()
        self.assertEqual(c["chat_vision"]["free_detailed_per_day"], 2)
        self.assertEqual(c["home_hero"]["refresh_sec"], 120)
