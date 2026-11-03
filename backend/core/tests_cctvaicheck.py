"""cctvaicheck (owner CCTV order B: AI check of the alert snapshot with a
monthly AI cost cap per account; audit W4 B3/B4).

Pure rules (logic/cctv_ai_check.py) first, then the glue with a MOCKED
vision provider (person, none, timeout, key missing, over cap, switch off,
provider too dear) — the first real call happens when the owner adds a key.
Policy proven here: the alert is never hidden or held back; the AI only adds
a label; only the shrunk still is sent; every call lands in the AIUsage
ledger; the allowance is shared with the visitor descriptions.
"""
import io
from datetime import timedelta
from unittest import mock

from django.core.files.base import ContentFile
from django.test import SimpleTestCase
from django.utils import timezone

from core import tests_e2e_cctv as E2E
from core.logic import cctv_ai_check as AC
from core.logic import cctv_plan as CP

KEY = ("vision_gemini", {"api_key": "x"}, 0.0)


def _has_ascii_digit(s):
    return any(ch.isascii() and ch.isdigit() for ch in s)


# ================================================================== pure
class AiCheckRuleTests(SimpleTestCase):
    def test_parse_reply(self):
        self.assertEqual(AC.parse_reply('{"object": "person", "confidence": 92}'),
                         {"cls": "person", "conf": 0.92})
        self.assertEqual(AC.parse_reply('Sure: {"object":"Vehicle","confidence":0.7}'),
                         {"cls": "vehicle", "conf": 0.7})
        self.assertEqual(AC.parse_reply('{"object": "none", "confidence": 140}')["conf"], 1.0)
        for bad in (None, "", "a person", '{"object": "ghost", "confidence": 50}',
                    '{"object": "person"}', '{"object": "person", "confidence": "x"}',
                    '{"object": "person", "confidence": 90, "note": "a thief"}',
                    '{"object": "person", "confidence": 90} সন্দেহজনক'):
            self.assertIsNone(AC.parse_reply(bad), bad)

    def test_bangla_labels(self):
        t = AC.label(AC.result_of({"cls": "person", "conf": 0.92}), "bn")["text"]
        self.assertEqual(t, "AI: মানুষ দেখা গেছে ৯২%")
        self.assertEqual(AC.label(AC.result_of({"cls": "person", "conf": 0.92}), "en")["text"],
                         "AI: Person seen 92%")
        lf = AC.label(AC.result_of({"cls": "none", "conf": 0.85}), "bn")
        self.assertTrue(lf["likely_false"])
        self.assertTrue(lf["text"].startswith("সম্ভবত ভুল সতর্কতা"))
        unsure = AC.label(AC.result_of({"cls": "none", "conf": 0.3}), "bn")
        self.assertFalse(unsure["likely_false"])
        self.assertIn("নিশ্চিত নয়", unsure["text"])
        for st in AC.NOT_CHECKED:
            x = AC.label({"state": st}, "bn")
            self.assertEqual(x["state"], st)
            self.assertTrue(x["text"])
        self.assertEqual(AC.label({"state": "weird"}, "bn")["state"], "failed")
        for st, conf in (("person", 0.92), ("none", 0.85), ("animal", 0.61)):
            self.assertFalse(_has_ascii_digit(
                AC.label(AC.result_of({"cls": st, "conf": conf}), "bn")["text"]
                .replace("AI", "")))

    def test_prompt_is_strict(self):
        for w in ("Do NOT describe or identify", "faces", "never say thief", "JSON"):
            self.assertIn(w, AC.SYSTEM)
        self.assertNotIn("video", AC.QUESTION.lower())

    def test_switch_default_on_only_with_key(self):
        self.assertTrue(AC.camera_switch({}, True))
        self.assertFalse(AC.camera_switch({}, False))
        self.assertFalse(AC.camera_switch({"ai_check": False}, True))
        self.assertFalse(AC.camera_switch({"ai_check": True}, False))   # no key -> never on

    def test_zone_save_keeps_the_switch(self):
        from core.logic import watchman as WM
        out = WM.normalize_zone_config(WM.default_zone_config("home"),
                                       legacy={"ai_check": False})
        self.assertIs(out["ai_check"], False)

    def test_per_check_cost_in_the_profit_table(self):
        c = CP.defaults()
        # the cost a check books when the provider has no price set = the plan's
        self.assertEqual(AC.check_cost_usd(0, c["ai_check_usd"]), (c["ai_check_usd"], True))
        # 50 checks / camera / month at that cost are inside every tier's 40 %
        t = CP.profit_table()
        self.assertTrue(t["ok"], t["min_pct"])
        for v in t["per_vendor"]:
            self.assertGreaterEqual(v["snapshots_server_ai"],
                                    round(c["ai_checks_per_camera"] * c["ai_check_usd"]
                                          * c["usd_bdt"], 2))
        # a provider dearer than the plan would break the 40 % rule -> refused
        dear = 0.005
        self.assertFalse(CP.profit_table({"ai_check_usd": dear})["ok"])
        self.assertEqual(AC.check_cost_usd(dear, c["ai_check_usd"]), (dear, False))
        self.assertTrue(AC.check_cost_usd(0.001, c["ai_check_usd"])[1])


# ================================================================== glue
class AiCheckGlueTests(E2E._Base):
    def setUp(self):
        super().setUp()
        from core.models import ShopSite, ShopCamera
        cam = self.add_camera("hikvision", "Gate")
        self.s = ShopSite.objects.get(pk=self.site["id"])
        self.c1 = ShopCamera.objects.get(pk=cam["id"])
        self.list_url = "/api/v1/shop/events?site=%d" % self.s.id
        self.types_url = "/api/v1/shop/cameras/%d/alert-types" % self.c1.id

    def event(self, etype="person_detected", mins=1, photo=True):
        from core.models import ShopEvent
        when = timezone.now() - timedelta(minutes=mins)
        ev = ShopEvent.objects.create(site=self.s, camera=self.c1, type=etype,
                                      signals={"inputs": {"kind": "person"}}, last_at=when,
                                      confidence=0.7)
        ShopEvent.objects.filter(pk=ev.pk).update(created=when)
        ev.refresh_from_db()
        if photo:
            ev.snapshot.save("a%d.jpg" % ev.pk, ContentFile(E2E._jpeg(1280, 720)), save=True)
        return ev

    def row(self, ev, lang="bn"):
        r = self.client.get(self.list_url, HTTP_ACCEPT_LANGUAGE=lang)
        self.assertEqual(r.status_code, 200, r.data)
        rows = r.data["events"] if isinstance(r.data, dict) else r.data
        return next(x for x in rows if x["id"] == ev.id)

    def run_check(self, reply=None, side_effect=None, key=KEY):
        from core import cctv_ai_check as CAI
        seen = {}

        def ask(slug, conf, **kw):
            seen.update(kw, slug=slug)
            if isinstance(kw.get("usage"), dict):
                kw["usage"].update(input_tokens=310, output_tokens=12)
            if side_effect:
                raise side_effect
            return reply
        with mock.patch("core.chat_vision_service._active", return_value=key), \
                mock.patch("core.vision_providers.ask", side_effect=ask) as m:
            out = CAI.check_due()
        return out, seen, m

    def ledger(self):
        from core.models import AIUsage
        return list(AIUsage.objects.filter(feature="cctv_ai_check"))

    def used(self):
        from core.logic import cctv_ai_budget as BUD
        return BUD.ai_check_status(self.c1)["used"]

    def test_person_label_ledger_and_only_the_small_still(self):
        ev = self.event()
        before = len(self.pushes)
        out, seen, _m = self.run_check('{"object": "person", "confidence": 92}')
        self.assertEqual(out["checked"], 1)
        # only the still, shrunk to <= 512 px; strict prompt; short timeout
        from PIL import Image
        im = Image.open(io.BytesIO(seen["image_bytes"]))
        self.assertLessEqual(max(im.size), 512)
        self.assertEqual(seen["mime"], "image/jpeg")
        self.assertIn("Do NOT describe or identify", seen["system"])
        self.assertEqual(seen["timeout"], AC.TIMEOUT_S)
        self.assertNotIn("video", seen)
        self.assertNotIn("audio", seen)
        row = self.row(ev)
        self.assertEqual(row["ai_check"]["text"], "AI: মানুষ দেখা গেছে ৯২%")
        self.assertEqual(row["ai_check"]["cls"], "person")
        self.assertEqual(self.row(ev, "en")["ai_check"]["text"], "AI: Person seen 92%")
        # ledger with the provider's token counts + Profit Guard cost
        led = self.ledger()
        self.assertEqual(len(led), 1)
        self.assertEqual((led[0].input_tokens, led[0].output_tokens, led[0].ok),
                         (310, 12, True))
        self.assertAlmostEqual(led[0].cost_usd, CP.defaults()["ai_check_usd"])
        self.assertEqual(led[0].user_id, self.owner.id)
        self.assertEqual(self.used(), 1)
        self.assertEqual(len(self.pushes), before)                  # no extra push
        # never checked twice
        out, _s, m = self.run_check('{"object": "person", "confidence": 92}')
        self.assertEqual(out["checked"], 0)
        m.assert_not_called()

    def test_none_marks_probable_false_alarm_but_alert_stays(self):
        ev = self.event("motion")
        self.run_check('{"object": "none", "confidence": 85}')
        row = self.row(ev)
        self.assertTrue(row["ai_check"]["likely_false"])
        self.assertTrue(row["ai_check"]["text"].startswith("সম্ভবত ভুল সতর্কতা"))
        self.assertEqual(row["status"], "open")                      # not hidden, not closed

    def test_timeout_is_honest(self):
        from core import vision_providers as VP
        ev = self.event()
        out, _s, _m = self.run_check(side_effect=VP.VisionError("Timeout"))
        self.assertEqual(out["checked"], 0)
        row = self.row(ev)
        self.assertEqual(row["ai_check"]["state"], "failed")
        self.assertEqual(row["ai_check"]["text"], "AI যাচাই হয়নি — AI সময়মতো উত্তর দেয়নি")
        led = self.ledger()
        self.assertEqual((len(led), led[0].ok, led[0].cost_usd), (1, False, 0.0))
        self.assertEqual(self.used(), 1)                 # the allowance was taken before the call

    def test_key_missing_no_call_honest_label(self):
        ev = self.event()
        out, _s, m = self.run_check('{"object": "person", "confidence": 92}',
                                    key=("", {}, 0.0))
        m.assert_not_called()
        self.assertEqual(out, {"checked": 0, "skipped": 0})
        row = self.row(ev)
        self.assertEqual(row["ai_check"]["state"], "no_key")
        self.assertIn("AI যাচাই হয়নি", row["ai_check"]["text"])
        r = self.client.get(self.types_url, HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual((r.data["ai_check"]["ready"], r.data["ai_check"]["on"]), (False, False))
        self.assertEqual(self.ledger(), [])

    def test_over_cap_no_call_and_shared_with_descriptions(self):
        ev = self.event()
        with mock.patch("core.cctv_activity.ai_per_camera", return_value=0), \
                mock.patch("core.cctv_cap.ai_per_camera", return_value=0):
            out, _s, m = self.run_check('{"object": "person", "confidence": 92}')
        m.assert_not_called()
        row = self.row(ev)
        self.assertEqual(row["ai_check"]["state"], "cap")
        self.assertEqual(row["ai_check"]["text"], "AI যাচাই হয়নি — এই মাসের AI সীমা শেষ")
        # one camera x 50: the visitor descriptions' use counts too
        from core import cctv_activity as CACT
        from core.logic import cctv_brief as CB
        from core.logic import cctv_ai_budget as BUD
        month = timezone.localtime(timezone.now()).strftime("%Y-%m")
        CACT.act_update(self.s, lambda a: a.update(ai={"month": month, "used": 49}))
        self.assertTrue(BUD.ai_check_allowed(self.c1))
        BUD.ai_check_used(self.c1)
        self.assertFalse(BUD.ai_check_allowed(self.c1))
        self.assertEqual(BUD.ai_check_status(self.c1)["cap"], CB.AI_CHECKS_PER_CAMERA)

    def test_owner_switch_per_camera(self):
        with mock.patch("core.chat_vision_service._active", return_value=KEY):
            r = self.client.get(self.types_url, HTTP_ACCEPT_LANGUAGE="bn")
            self.assertEqual(r.data["ai_check"]["on"], True)            # default ON with a key
            self.assertEqual(r.data["ai_check"]["title"], "AI দিয়ে যাচাই")
            self.assertFalse(_has_ascii_digit(r.data["ai_check"]["note"].replace("AI", "")))
            r = self.client.post(self.types_url, {"types": {"person": True, "ai_check": False}},
                                 format="json", HTTP_ACCEPT_LANGUAGE="bn")
            self.assertEqual(r.status_code, 200, r.data)
            self.assertEqual(r.data["ai_check"]["on"], False)
        ev = self.event()
        out, _s, m = self.run_check('{"object": "person", "confidence": 92}')
        m.assert_not_called()
        self.assertEqual(self.row(ev)["ai_check"]["state"], "off")
        # a viewer cannot change it
        self.client.force_authenticate(self.family)
        r = self.client.post(self.types_url, {"types": {"ai_check": True}}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_provider_dearer_than_plan_is_refused(self):
        ev = self.event()
        out, _s, m = self.run_check('{"object": "person", "confidence": 92}',
                                    key=("vision_claude", {"api_key": "x"}, 0.01))
        m.assert_not_called()
        self.assertEqual(self.row(ev)["ai_check"]["state"], "cost")

    def test_health_alerts_and_old_alerts_not_checked(self):
        ev_h = self.event("camera_health")
        ev_old = self.event(mins=AC.MAX_AGE_MIN + 5)
        out, _s, m = self.run_check('{"object": "person", "confidence": 92}')
        m.assert_not_called()
        self.assertIsNone(self.row(ev_h)["ai_check"])
        ev_old.refresh_from_db()
        self.assertNotIn("ai_check", ev_old.signals)
        with mock.patch("core.chat_vision_service._active", return_value=KEY):
            self.assertEqual(self.row(ev_old)["ai_check"]["state"], "failed")   # never "pending" forever
