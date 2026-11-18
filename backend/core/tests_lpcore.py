"""lpcore — Language Partner V2 backbone tests: public band tables + mistake
types, automatic content checks (incl. NO Cambridge text), bundle import +
versioning + signed media, the review pipeline, plan gates, Writing/Speaking
scoring with a MOCKED Claude (charge only on success, refund on fail / cut /
unreadable), the >= 40 % worst-case profit proof, prompts < 90K tokens, the
Cambridge companion (user's own answers + key only), the practice
certificate, and the owner-account guard. Sample data only."""
import json
import os
import re
import shutil
import tempfile
from pathlib import Path
from unittest import mock

from django.test import SimpleTestCase, TestCase, override_settings
from rest_framework.test import APIClient

from core import ai, billing
from core import lp_service as LS
from core.logic import lp_bands as B
from core.logic import lp_checks as CK
from core.logic import lp_score as SC
from core.logic import plan_book as PB
from core.models import LpAttempt, LpItem, LpReviewLog, User

V = "/api/v1"
_MEDIA = tempfile.mkdtemp(prefix="lpcore-media-")


# ------------------------------------------------------------ sample content
def _q(n, qtype="gap", answer=("river",), max_words=2, tag="detail"):
    q = {"n": n, "type": qtype, "prompt": "Sample question %d" % n, "answer": list(answer),
         "explain_en": "Because the text says so.", "explain_bn": "কারণ লেখায় তাই আছে।", "tag": tag}
    if qtype in ("gap", "short"):
        q["max_words"] = max_words
    if qtype in ("mcq",):
        q["options"] = ["A", "B", "C", "D"]
    return q


def _passage(n, start, key):
    words = key + " " + " ".join("w%dx%d" % (n, i) for i in range(700))
    qs = [_q(start + i, "tfng", ("NOT GIVEN",), tag="tfng") if i % 3 == 0 else
          _q(start + i, "mcq", ("B",), tag="main_idea") if i % 3 == 1 else
          _q(start + i) for i in range(13 if n < 3 else 14)]
    return {"n": n, "title": "Passage %d" % n, "text": words, "questions": qs}


def sample_mock(key="ielts-ac-t01", title="Sample Mock 1"):
    lparts = [{"n": p, "audio": "audio/p%d.mp3" % p, "accent": ("uk", "au", "us", "uk")[p - 1],
               "speakers": 2, "transcript": "Sample transcript part %d %s" % (p, key),
               "questions": [_q((p - 1) * 10 + i + 1, tag="map" if p == 2 else "detail")
                             for i in range(10)]} for p in range(1, 5)]
    return {"kind": "mock", "key": key, "track": "ielts_ac", "level": "band6", "data": {
        "title_en": title, "title_bn": "নমুনা মক",
        "listening": {"duration_sec": 1800, "parts": lparts},
        "reading": {"duration_sec": 3600, "passages": [_passage(1, 1, key), _passage(2, 14, key),
                                                        _passage(3, 27, key)]},
        "writing": {"duration_sec": 3600, "tasks": [
            {"n": 1, "prompt": "The chart shows sample data about %s." % key, "min_words": 150},
            {"n": 2, "prompt": "Some people think cities should ban cars. Discuss.", "min_words": 250}]},
        "speaking": {"duration_sec": 780, "parts": [
            {"n": 1, "questions": ["Where do you live?", "Do you work?", "Do you like rain?",
                                   "What food do you like?"]},
            {"n": 2, "cue_card": "Describe a river you visited (%s)." % key, "prep_sec": 60, "talk_sec": 120},
            {"n": 3, "questions": ["Why do cities grow?", "Is travel useful?", "What will change?"]}]},
    }}


def _bundle(items, audio=True):
    d = tempfile.mkdtemp(prefix="lpcore-bundle-")
    os.makedirs(os.path.join(d, "audio"))
    if audio:
        for p in range(1, 5):
            with open(os.path.join(d, "audio", "p%d.mp3" % p), "wb") as fh:
                fh.write(b"ID3fake-audio-%d" % p)
    with open(os.path.join(d, "bundle.json"), "w", encoding="utf-8") as fh:
        json.dump({"schema": 1, "bundle": "ci-sample", "source": "ai", "items": items}, fh)
    return d


def _user(n, **kw):
    return User.objects.create_user(name="Learner %d" % n, phone="+88017110090%02d" % n,
                                    password="pw12345!", **kw)


def _client(u):
    c = APIClient()
    c.force_authenticate(u)
    return c


# ------------------------------------------------------------- pure engine
class BandTableTests(SimpleTestCase):
    def test_public_tables(self):
        self.assertEqual(B.raw_to_band(40, "listening"), 9.0)
        self.assertEqual(B.raw_to_band(30, "listening"), 7.0)
        self.assertEqual(B.raw_to_band(23, "listening"), 6.0)
        self.assertEqual(B.raw_to_band(30, "reading", "academic"), 7.0)
        self.assertEqual(B.raw_to_band(30, "reading", "general"), 6.0)
        self.assertEqual(B.raw_to_band(0, "reading"), 0.0)
        self.assertEqual(B.raw_to_band(5, "reading", total=10), B.raw_to_band(20, "reading"))

    def test_overall_rounding(self):
        self.assertEqual(B.overall({"l": 6.5, "r": 6.5, "w": 5.0, "s": 7.0}), 6.5)   # 6.25
        self.assertEqual(B.overall({"l": 6.5, "r": 6.5, "w": 6.5, "s": 7.0}), 6.5)   # 6.625
        self.assertEqual(B.overall({"l": 7.0, "r": 6.5, "w": 6.5, "s": 7.0}), 7.0)   # 6.75
        self.assertEqual(B.round_band(6.125), 6.0)
        self.assertEqual(B.round_band(6.75), 7.0)
        self.assertEqual(B.writing_band(6.0, 6.5), 6.5)

    def test_mistake_types(self):
        self.assertEqual(B.classify("gap", "museums", "(the) museum", 2), (False, "plural"))
        self.assertEqual(B.classify("gap", "the musuem", "(the) museum", 2), (False, "spelling"))
        self.assertEqual(B.classify("gap", "the old museum", "museum", 2), (False, "word_limit"))
        self.assertEqual(B.classify("gap", "The Museum.", "(the) museum", 2), (True, None))
        self.assertEqual(B.classify("tfng", "ng", "FALSE"), (False, "tfng"))
        self.assertEqual(B.classify("tfng", "not given", ["NOT GIVEN"]), (True, None))
        self.assertEqual(B.classify("map", "C", "D"), (False, "map"))
        self.assertEqual(B.classify("matching", "iv", "ii"), (False, "matching"))
        self.assertEqual(B.classify("mcq_multi", "C, A", ["A", "C"]), (True, None))
        self.assertEqual(B.classify("matching", "iv)", "iv"), (True, None))     # app sends "iv)"
        self.assertEqual(B.classify("mcq", "B.", "B"), (True, None))
        self.assertEqual(B.classify("mcq_multi", "A,C", ["A", "C"]), (True, None))
        self.assertEqual(B.classify("gap", "fifteen", "15/fifteen", 1), (True, None))

    def test_mark_collects_weak_tags(self):
        qs = [_q(1, tag="spell"), _q(2, "tfng", ("TRUE",), tag="tfng")]
        res = B.mark(qs, {"1": "rivr", "2": "TRUE"}, "reading")
        self.assertEqual(res["raw"], 1)
        self.assertEqual(res["weak"], ["spell"])
        self.assertEqual(res["mistake_counts"], {"spelling": 1})
        self.assertIn("not an official", res["practice_label"]["en"])


class ContentCheckTests(SimpleTestCase):
    def _section(self, name):
        raw = sample_mock()
        return CK.section_failures(name, raw["data"][name], "band6")

    def test_sample_mock_sections_pass(self):
        for s in CK.SECTIONS:
            self.assertEqual(self._section(s), [], s)

    def test_failures_are_caught(self):
        raw = sample_mock()
        r = raw["data"]["reading"]
        r["duration_sec"] = 2400                                # timing
        r["passages"][0]["questions"][1]["answer"] = ["B", "C"]  # two keys on a single mcq
        r["passages"][0]["questions"][2]["answer"] = ["the long river bank"]  # word limit 2
        r["passages"][0]["questions"][0]["answer"] = ["MAYBE"]  # invalid tfng
        r["passages"][2]["questions"].pop()                     # 39 questions
        codes = {c for c, _ in CK.section_failures("reading", r, "band6")}
        self.assertTrue({"timing", "uniqueness", "word_limit", "format"} <= codes)

    def test_never_cambridge(self):
        res = CK.check_item("question", {"section": "reading", "q": dict(
            _q(1), prompt="From Cambridge IELTS 18 Test 2, passage 1")})
        self.assertFalse(res["ok"])
        self.assertIn("copyright_marker", {f["code"] for f in res["failures"]})
        for marker in ("cambridge", "ucles"):
            self.assertTrue(any(marker in b for b in CK.BANNED))

    def test_known_text_fingerprint(self):
        known_text = ("the quick brown fox jumps over the lazy dog while the farmer sleeps "
                      "under an old oak tree near the quiet river bank at noon")
        known = frozenset(CK.fingerprints(known_text))
        res = CK.check_item("scenario", {"id": "s1", "text": "Intro. " + known_text}, "", known)
        self.assertIn("copyright_known_text", {f["code"] for f in res["failures"]})
        res = CK.check_item("scenario", {"id": "s1", "text": "an original sentence about rickshaws"},
                            "", known)
        self.assertTrue(res["ok"])


# --------------------------------------------------------- import + review
@override_settings(MEDIA_ROOT=_MEDIA)
class ImportReviewTests(TestCase):
    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        shutil.rmtree(_MEDIA, ignore_errors=True)

    def test_import_splits_sections_checks_and_versions(self):
        d = _bundle([sample_mock()])
        out = LS.import_bundle(d)
        self.assertEqual(out["errors"], [])
        self.assertEqual(out["new"], 5)                       # mock + 4 sections
        mock_item = LpItem.objects.get(key="ielts-ac-t01")
        self.assertEqual(mock_item.status, "ai_checked", mock_item.checks)
        sec = LpItem.objects.get(key="ielts-ac-t01-listening")
        self.assertEqual(sec.status, "ai_checked", sec.checks)
        audio = sec.data["body"]["parts"][0]["audio"]
        self.assertTrue(audio.startswith("lp/") and audio.endswith(".mp3"))
        self.assertTrue(LpReviewLog.objects.filter(item=sec, action="import").exists())
        self.assertEqual(LS.import_bundle(d)["same"], 5)        # unchanged -> no new version
        raw = sample_mock()
        raw["data"]["title_en"] = "Sample Mock 1 (fixed)"
        self.assertEqual(LS.import_bundle(_bundle([raw]))["new"], 1)
        self.assertEqual(LpItem.objects.filter(key="ielts-ac-t01").count(), 2)
        self.assertEqual(LS.live_item("ielts-ac-t01").version, 2)

    def test_cambridge_bundle_is_rejected_and_hidden(self):
        raw = sample_mock("ielts-ac-bad", "Bad")
        raw["data"]["reading"]["passages"][0]["text"] += " © UCLES 2020 Cambridge University Press"
        LS.import_bundle(_bundle([raw]))
        sec = LpItem.objects.get(key="ielts-ac-bad-reading")
        self.assertEqual(sec.status, "rejected")
        self.assertIsNone(LS.live_item("ielts-ac-bad-reading"))

    def test_duplicate_detected(self):
        LS.import_bundle(_bundle([{"kind": "question", "key": "q-a", "data": {
            "section": "reading", "q": _q(1)}}]))
        LS.import_bundle(_bundle([{"kind": "question", "key": "q-b", "data": {
            "section": "reading", "q": _q(1)}}]))
        b = LpItem.objects.get(key="q-b")
        self.assertEqual(b.status, "draft")
        self.assertIn("duplicate", {f["code"] for f in b.checks["failures"]})

    def test_review_pipeline(self):
        LS.import_bundle(_bundle([sample_mock()]))
        reviewer = _user(90)
        m = LpItem.objects.get(key="ielts-ac-t01")
        self.assertTrue(LS.is_beta(m))
        for it in LpItem.objects.filter(key__startswith="ielts-ac-t01"):
            _, err = LS.review(it, "approve", reviewer)
            self.assertIsNone(err)
        m.refresh_from_db()
        self.assertEqual(m.status, "human_approved")
        self.assertFalse(LS.is_beta(m))
        # a failing item cannot be approved
        LS.import_bundle(_bundle([{"kind": "question", "key": "q-bad", "data": {
            "section": "reading", "q": dict(_q(1, tag="x"), answer=[])}}]))
        bad = LpItem.objects.get(key="q-bad")
        self.assertEqual(LS.review(bad, "approve", reviewer)[1], "checks_failed")
        # edit -> new version, approved when the checks pass
        fixed = dict(bad.data, q=dict(bad.data["q"], answer=["delta"]))
        new, err = LS.review(bad, "edit", reviewer, data=fixed)
        self.assertIsNone(err)
        self.assertEqual((new.version, new.status), (2, "human_approved"))
        self.assertTrue(LpReviewLog.objects.filter(item=new, action="approve", actor=reviewer).exists())
        LS.review(new, "reject", reviewer, "wrong level")
        self.assertIsNone(LS.live_item("q-bad"))


# ----------------------------------------------------------------- the API
@override_settings(MEDIA_ROOT=_MEDIA)
@mock.patch("core.lp_service.flag_on", return_value=True)
class ApiTests(TestCase):
    def setUp(self):
        LS.import_bundle(_bundle([sample_mock(), sample_mock("ielts-gt-t01", "GT 1") | {
            "track": "ielts_gt"}]))
        self.u = _user(1)
        self.c = _client(self.u)

    def test_list_and_free_weekly_section(self, _f):
        r = self.c.get(V + "/lp/mocks?kind=academic").json()
        self.assertEqual([m["id"] for m in r["mocks"]], ["ielts-ac-t01"])
        self.assertTrue(r["mocks"][0]["beta"])
        self.assertEqual(r["free_sections_left_week"], 1)
        self.assertEqual(self.c.get(V + "/lp/mocks/ielts-ac-t01").status_code, 402)  # full = premium
        r = self.c.get(V + "/lp/mocks/ielts-ac-t01?section=reading")
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertIn("reading", body)
        self.assertNotIn("listening", body)
        flat = json.dumps(body)
        self.assertNotIn('"answer"', flat)                  # keys never leave the server
        self.assertNotIn("explain_bn", flat)
        self.assertEqual(self.c.get(V + "/lp/mocks/ielts-ac-t01?section=reading").status_code, 200)
        r = self.c.get(V + "/lp/mocks/ielts-ac-t01?section=listening")
        self.assertEqual((r.status_code, r.json()["reason"]), (402, "week_used"))
        self.assertTrue(r.json()["next_free_at"])

    def test_premium_full_mock_signed_audio(self, _f):
        with mock.patch.object(LS, "is_premium", return_value=True):
            body = self.c.get(V + "/lp/mocks/ielts-ac-t01").json()
        self.assertEqual(set(CK.SECTIONS) <= set(body), True)
        url = body["listening"]["parts"][0]["audio_url"]
        self.assertIn("s=", url)                          # signed, expiring link
        self.assertNotIn("transcript", json.dumps(body))

    def test_mark_reading_band_and_mistakes(self, _f):
        answers = {}
        for p in sample_mock()["data"]["reading"]["passages"]:
            for q in p["questions"]:
                answers[str(q["n"])] = q["answer"][0]
        answers["3"] = "rivers"                            # plural
        answers["1"] = "FALSE"                             # tfng confusion
        r = self.c.post(V + "/lp/mocks/ielts-ac-t01/mark", {"section": "reading", "answers": answers},
                        format="json").json()
        self.assertEqual((r["raw"], r["total"]), (38, 40))
        self.assertEqual(r["band"], 8.5)
        kinds = {i["n"]: i["mistake"] for i in r["items"] if not i["correct"]}
        self.assertEqual(kinds, {1: "tfng", 3: "plural"})
        self.assertTrue(LpAttempt.objects.filter(user=self.u, kind="mark", band=8.5).exists())

    def test_finish_and_certificate(self, _f):
        # gap-lp: the bands come from the server's own marks / scores
        for kind, sec, band, extra in (("mark", "listening", 7, {}), ("mark", "reading", 6.5, {}),
                                       ("writing", "writing", 6, {"task": 2}),
                                       ("speaking", "speaking", 6.5, {"part": 1})):
            LpAttempt.objects.create(user=self.u, kind=kind, item_key="ielts-ac-t01", section=sec,
                                     band=band, data=extra)
        r = self.c.post(V + "/lp/mocks/ielts-ac-t01/finish", {
            "bands": {"listening": 7, "reading": 6.5, "writing": 6, "speaking": 6.5},
            "weak": ["tfng"]}, format="json").json()
        self.assertEqual(r["overall"], 6.5)
        self.assertEqual(r["weak_areas"][0]["tag"], "tfng")
        pdf = self.c.get(V + "/lp/certificate/%d" % r["result_id"])
        self.assertEqual(pdf["Content-Type"], "application/pdf")
        self.assertIn(b"Practice score", pdf.content)
        self.assertIn(b"not an official IELTS or JLPT result", pdf.content)
        self.assertNotIn(b"Official IELTS", pdf.content)
        other = _client(_user(2))
        self.assertEqual(other.get(V + "/lp/certificate/%d" % r["result_id"]).status_code, 404)

    def test_weak_practice_round_trip(self, _f):
        LS.import_bundle(_bundle([{"kind": "question", "key": "wq-1", "data": {
            "section": "reading", "q": _q(1, "tfng", ("FALSE",), tag="tfng")}}]))
        items = self.c.post(V + "/lp/weak/practice", {"tags": ["tfng"]}, format="json").json()["items"]
        self.assertEqual([i["qid"] for i in items], ["wq-1"])
        self.assertNotIn("answer", items[0])
        r = self.c.post(V + "/lp/practice/mark", {"answers": {"wq-1": "NG"}}, format="json").json()
        self.assertEqual(r["items"][0]["mistake"], "tfng")

    def test_gates_and_flag_off(self, flag):
        g = self.c.get(V + "/lp/gates").json()
        self.assertEqual((g["premium"], g["full_mocks"], g["life_english"]), (False, False, True))
        flag.return_value = False
        self.assertEqual(self.c.get(V + "/lp/gates").status_code, 403)
        self.assertIn(APIClient().get(V + "/lp/gates").status_code, (401, 403))


# ------------------------------------------------------------- AI scoring
_W2 = json.dumps({"criteria": {"TR": 6.5, "CC": 6, "LR": 6, "GRA": 5.5},
                  "notes": {"TR": {"en": "Clear view.", "bn": "মত পরিষ্কার।"}},
                  "corrected": "Cities should limit cars.",
                  "mistakes": [{"wrong": "peoples", "right": "people", "type": "grammar",
                                "en": "People is already plural.", "bn": "people নিজেই বহুবচন।"}],
                  "summary_en": "Good.", "summary_bn": "ভালো।"})
_ESSAY = " ".join(["Many cities are crowded and peoples want cleaner air."] * 6)


@mock.patch("core.lp_service.flag_on", return_value=True)
class ScoringTests(TestCase):
    def setUp(self):
        self.u = _user(3)
        billing.credit(self.u, "topup", 50, note="test pack")
        self.u.refresh_from_db()
        self.c = _client(self.u)
        self.body = {"task": 2, "prompt": "Should cities ban cars?", "text": _ESSAY}

    def _bal(self):
        self.u.refresh_from_db()
        return int(self.u.ai_credits or 0)

    def _post(self, gen, level="normal", premium=True):
        with mock.patch.object(LS, "is_premium", return_value=premium), \
                mock.patch.object(ai, "available", return_value=True), \
                mock.patch.object(ai, "generate", side_effect=gen) as g:
            r = self.c.post(V + "/lp/score/writing", dict(self.body, level=level), format="json")
        return r.json(), g

    def test_used_charges_exact_credits(self, _f):
        start = self._bal()
        price = LS.score_plan("normal")["credits"]

        def gen(**kw):
            self.assertEqual(kw["feature"], "lp.score")
            self.assertIsNone(kw["user"])                     # billed by lp_service, not twice
            kw["out_meta"]["truncated"] = False
            return _W2, 0.001
        r, _ = self._post(gen)
        self.assertEqual(r["ai_state"], "used")
        self.assertEqual(r["criteria"], {"TR": 6.5, "CC": 6.0, "LR": 6.0, "GRA": 5.5})
        self.assertEqual(r["band"], 6.0)
        self.assertEqual(r["mistakes"][0]["bn"], "people নিজেই বহুবচন।")
        self.assertEqual(r["credits_used"], price)
        self.assertEqual(self._bal(), start - price)
        a = LpAttempt.objects.get(user=self.u, kind="writing")
        self.assertNotIn("prompt", a.data)                    # a typed (book) prompt is never stored

    def test_cut_unreadable_and_failure_are_refunded(self, _f):
        start = self._bal()

        def cut(**kw):
            kw["out_meta"]["truncated"] = True
            return _W2[:80], 0.001
        for gen, state in ((cut, "cut"),
                           (lambda **kw: ("Sorry, no JSON here", 0.0), "unreadable"),
                           (ai.AIUnavailable("queued"), "busy")):
            r, _ = self._post(gen)
            self.assertEqual(r["ai_state"], state)
            self.assertEqual(r["credits_used"], 0)
            self.assertEqual(self._bal(), start, state)
        self.assertFalse(LpAttempt.objects.filter(kind="writing").exists())

    def test_free_plan_and_no_key_never_call(self, _f):
        r, g = self._post(lambda **kw: (_W2, 0), premium=False)
        self.assertEqual(r["ai_state"], "premium")
        g.assert_not_called()
        with mock.patch.object(LS, "is_premium", return_value=True), \
                mock.patch.object(ai, "available", return_value=False):
            r = self.c.post(V + "/lp/score/writing", self.body, format="json").json()
        self.assertEqual(r["ai_state"], "no_key")

    def test_not_enough_credits(self, _f):
        billing.charge(self.u, "test_drain", exact=self._bal())
        r, g = self._post(lambda **kw: (_W2, 0))
        self.assertEqual(r["ai_state"], "credits")
        g.assert_not_called()

    def test_speaking_scores_four_criteria(self, _f):
        sp = json.dumps({"criteria": {"FC": 6, "LR": 6, "GRA": 5.5, "P": 6},
                         "corrected": "I live in Dhaka.", "mistakes": []})

        def gen(**kw):
            self.assertIn("confidence: 82%", kw["task"])
            return sp, 0.0
        with mock.patch.object(LS, "is_premium", return_value=True), \
                mock.patch.object(ai, "available", return_value=True), \
                mock.patch.object(ai, "generate", side_effect=gen):
            r = self.c.post(V + "/lp/score/speaking", {
                "part": 1, "prompt": "Where do you live?", "seconds": 30, "confidence": 0.82,
                "transcript": "i live in dhaka it is a very busy city with many people"},
                format="json").json()
        self.assertEqual((r["ai_state"], r["band"]), ("used", 6.0))
        self.assertEqual(set(r["criteria"]), {"FC", "LR", "GRA", "P"})


class ProfitAndPromptTests(TestCase):
    """Owner rule: every paid part keeps >= 40 % worst-case profit; prompts < 90K tokens;
    Haiku marks, Sonnet only for Best."""

    def _assert_plan(self, plan):
        from core import ai_config as C
        prices = C.DEFAULT_PRICES
        cost = SC.worst_cost_usd(plan["models"], plan["in_tokens"], plan["out_tokens"], prices)
        self.assertGreaterEqual(SC.profit_pct(plan["credits"], cost), PB.PROFIT_PCT - 1e-9, plan)

    def test_profit_levels_off(self):
        p = LS.score_plan("normal")
        self.assertEqual(p["models"], ["claude-haiku-5-5"])
        self._assert_plan(p)
        self.assertEqual(LS.score_plan("best")["level"], "normal")   # never Opus

    def test_profit_levels_on_v2(self):
        from core import ai_levels_service as ALS
        from core.logic import ai_levels as AL
        lv = dict(AL.defaults(), enabled=True)
        lv["levels"] = dict(lv["levels"], **{k: dict(lv["levels"].get(k, {}), **v)
                                            for k, v in PB.V2_LEVELS.items()})
        with mock.patch.object(ALS, "cfg", side_effect=lambda c=None: (AL.normalize(lv),
                                                                         billing.cfg())):
            best = LS.score_plan("best")
        self.assertEqual(best["models"][0], "claude-sonnet-5-5")
        self._assert_plan(best)
        self.assertGreaterEqual(best["credits"], 11)
        self._assert_plan(LS.score_plan("normal"))

    def test_worst_case_counts_dearest_model(self):
        cheap = SC.credits_for(["claude-haiku-5-5"], 10000, 3000, {"claude-haiku-5-5": {
            "in": 0.1, "out": 0.5}, "claude-opus-5-5": {"in": 4, "out": 20}})
        dear = SC.credits_for(["claude-haiku-5-5", "unknown-model"], 10000, 3000, {
            "claude-haiku-5-5": {"in": 0.1, "out": 0.5}, "claude-opus-5-5": {"in": 4, "out": 20}})
        self.assertLess(cheap, dear)

    def test_prompts_under_90k_tokens(self):
        from core import ai_prompt as P
        from core.logic import pricing_40 as P40
        big = "word " * 5000
        for sys_, (task, data) in (
                (SC.writing_system(2, "academic"), SC.writing_task(big, big)),
                (SC.writing_system(1, "general"), SC.writing_task(big, big)),
                (SC.speaking_system(2), SC.speaking_task(big, big, 120, 0.9))):
            total = P40.est_tokens(P.system_prompt(sys_)) + P40.est_tokens(task + data)
            self.assertLess(total, SC.PROMPT_TOKEN_LIMIT)
            self.assertLess(total, SC.CAPS["normal"]["in"])      # fits the priced input cap

    def test_descriptor_keys(self):
        self.assertEqual(SC.WRITING_KEYS[1], ("TA", "CC", "LR", "GRA"))
        self.assertEqual(SC.WRITING_KEYS[2], ("TR", "CC", "LR", "GRA"))
        self.assertEqual(SC.SPEAKING_KEYS, ("FC", "LR", "GRA", "P"))
        self.assertIsNone(SC.parse('{"criteria":{"TR":6}}', SC.WRITING_KEYS[2]))
        self.assertIsNone(SC.parse("no json", SC.WRITING_KEYS[2]))


# ------------------------------------------------- Cambridge companion (B)
@mock.patch("core.lp_service.flag_on", return_value=True)
class CompanionTests(TestCase):
    def setUp(self):
        self.u = _user(4)
        self.c = _client(self.u)

    def test_marks_users_own_key(self, _f):
        key = {"1": "TRUE", "2": "museum", "3": "B", "4": "15/fifteen", "5": "harbour"}
        ans = {"1": "NOT GIVEN", "2": "musuem", "3": "B", "4": "fifteen", "5": "harbours"}
        r = self.c.post(V + "/lp/companion/mark", {"book": 18, "test": 2, "section": "reading",
                                                  "answers": ans, "key": key}, format="json").json()
        self.assertEqual(r["raw"], 2)
        self.assertEqual(r["mistake_counts"], {"tfng": 1, "spelling": 1, "plural": 1})
        self.assertIn("not kept", r["no_content_line"]["en"])
        sheets = self.c.get(V + "/lp/companion/sheets").json()["sheets"]
        self.assertNotIn("key", sheets[0])          # gap-lp: the typed key is never kept
        self.assertNotIn("key", LpAttempt.objects.get(kind="companion").data)
        self.assertEqual(sheets[0]["right"], [3, 4])

    def test_never_stores_book_content(self, _f):
        long_cell = "The passage says the industrial revolution started in Britain because"
        for body, reason in (
                ({"answers": {"1": long_cell}, "key": {"1": "x"}}, "bad_cell"),
                ({"answers": {"1": "a"}, "key": {"1": "a"}, "question_text": "Q1 ..."}, "bad_field"),
                ({"answers": {"1": "a"}, "key": {"1": "a"}, "passage": "..."}, "bad_field"),
                ({"answers": {"41": "a"}, "key": {"41": "a"}}, "bad_cell"),
                ({"answers": {"1": "a"}, "key": {}}, "no_key")):
            r = self.c.post(V + "/lp/companion/mark", dict(
                {"book": 17, "test": 1, "section": "listening"}, **body), format="json")
            self.assertEqual((r.status_code, r.json()["reason"]), (400, reason))
        self.assertFalse(LpAttempt.objects.filter(kind="companion").exists())
        self.assertEqual(self.c.post(V + "/lp/companion/mark", {
            "book": 9, "test": 1, "section": "reading", "answers": {}, "key": {"1": "a"}},
            format="json").json()["reason"], "bad_book")

    def test_no_cambridge_content_in_repo_data(self, _f):
        root = Path(__file__).resolve().parents[2]
        dirs = [root / "backend" / "core" / "data", root / "app" / "assets" / "lp"]
        for d in dirs:
            for p in (d.rglob("*.json") if d.is_dir() else []):
                if p.name == "lp_known_fingerprints.json":
                    continue
                low = p.read_text(encoding="utf-8", errors="ignore").lower()
                for marker in ("cambridge ielts", "ucles", "cambridge university press"):
                    self.assertNotIn(marker, low, str(p))


# ------------------------------------------- free-tier ads (owner 10 Nov B)
def _verified_ticket(user, placement, n=1):
    import secrets
    from django.utils import timezone
    from core.models import PhotoAdTicket
    for _ in range(n):
        PhotoAdTicket.objects.create(user=user, kind="rewarded", placement=placement,
                                     nonce=secrets.token_urlsafe(24), status="verified",
                                     transaction_id=secrets.token_hex(8), value_bdt=1.0,
                                     source="ssv", verified_at=timezone.now())


@override_settings(MEDIA_ROOT=_MEDIA)
@mock.patch("core.lp_service.flag_on", return_value=True)
class AdUnlockTests(TestCase):
    """Rewarded ads (Google-verified only) unlock an extra section / a Normal
    score for free users; the unlock keeps >= 40 % worst-case profit."""

    def setUp(self):
        LS.import_bundle(_bundle([sample_mock()]))
        self.u = _user(7)
        self.c = _client(self.u)

    def test_profit_with_ad_income(self, _f):
        for val in (0.03, 0.25, 0.8, 1.5, 4.0):          # eCPM floor .. generous owner value
            with mock.patch.object(LS, "ad_value_bdt", return_value=val):
                n = LS.ads_needed("score")
                cost = LS.score_cost_bdt()
                if n is None:
                    continue                                 # ads cannot pay: not offered
                income = n * val
                profit = income * (1 - PB.OVERHEAD_PCT) - cost
                self.assertGreaterEqual(profit, PB.PROFIT_PCT * income - 1e-9, (val, n, cost))
        with mock.patch.object(LS, "ad_value_bdt", return_value=0.03):
            self.assertIsNone(LS.ads_needed("score"))       # 25+ ads: never offered
        self.assertEqual(LS.ads_needed("section"), 1)
        self.assertLessEqual(LS.AD_COST_SHARE, 1 - PB.OVERHEAD_PCT - PB.PROFIT_PCT + 1e-9)

    def test_verified_ad_unlocks_extra_section(self, _f):
        self.c.get(V + "/lp/mocks/ielts-ac-t01?section=reading")
        r = self.c.get(V + "/lp/mocks/ielts-ac-t01?section=listening")
        self.assertEqual(r.status_code, 402)
        _verified_ticket(self.u, "lp_sec")
        self.assertEqual(self.c.get(V + "/lp/mocks/ielts-ac-t01?section=listening").status_code, 200)
        _verified_ticket(_user(8), "lp_sec")                 # someone else's ad unlocks nothing
        self.assertEqual(self.c.get(V + "/lp/mocks/ielts-ac-t01?section=writing").status_code, 402)

    def test_ad_unlocked_score_is_free_once(self, _f):
        with mock.patch.object(LS, "ad_value_bdt", return_value=1.0):
            n = LS.ads_needed("score")
            _verified_ticket(self.u, "lp_score", n)
            with mock.patch.object(ai, "available", return_value=True), \
                    mock.patch.object(ai, "generate", return_value=(_W2, 0.0)) as g:
                body = {"task": 2, "prompt": "Should cities ban cars?", "text": _ESSAY, "level": "best"}
                r = self.c.post(V + "/lp/score/writing", body, format="json").json()
                self.assertEqual((r["ai_state"], r["credits_used"], r["level"]), ("used", 0, "normal"))
                r = self.c.post(V + "/lp/score/writing", body, format="json").json()
                self.assertEqual(r["ai_state"], "premium")
            self.assertEqual(g.call_count, 1)
        self.assertTrue(LpAttempt.objects.get(kind="writing").data["ad_unlock"])

    def test_pay_credits_for_extra_section(self, _f):
        self.c.get(V + "/lp/mocks/ielts-ac-t01?section=reading")
        r = self.c.get(V + "/lp/mocks/ielts-ac-t01?section=listening&pay=credits")
        self.assertEqual((r.status_code, r.json()["reason"], r.json()["unlock_credits"]),
                         (402, "credits", 1))
        billing.credit(self.u, "rewarded", 1, note="ad credits")
        r = self.c.get(V + "/lp/mocks/ielts-ac-t01?section=listening&pay=credits")
        self.assertEqual(r.status_code, 200)
        r = self.c.get(V + "/lp/mocks/ielts-ac-t01?section=listening")       # re-open: free
        self.assertEqual(r.status_code, 200)
        r = self.c.post(V + "/lp/mocks/ielts-ac-t01/mark", {"section": "listening", "answers": {}},
                        format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(LpAttempt.objects.filter(user=self.u, kind="open_paid").count(), 1)

    def test_free_day_economics_reported(self, _f):
        """Free Life English AI turns vs. conservative ad income. At the eCPM
        floor ads do NOT cover the 3 free role-play turns (reported to the
        owner); the paid unlocks above always keep >= 40 %."""
        floor = LS.free_day_economics(ad_value=0.03)
        self.assertGreater(floor["cost_bdt"], 0)
        self.assertLess(floor["profit_pct"], PB.PROFIT_PCT)                # honest: loss leader
        rich = LS.free_day_economics(ad_value=5.0, interstitial_value=5.0)
        self.assertGreaterEqual(rich["profit_pct"], PB.PROFIT_PCT)
        profit = (LS.SECTION_UNLOCK_CREDITS * PB.MIN_BDT_PER_CREDIT
                  * (PB.NET_PCT - PB.OVERHEAD_PCT))
        self.assertGreaterEqual(profit / (LS.SECTION_UNLOCK_CREDITS * PB.MIN_BDT_PER_CREDIT),
                                PB.PROFIT_PCT)

    def test_ticket_rules_and_no_ads_for_premium(self, _f):
        r = self.c.post(V + "/lp/ads/ticket", {"unlock": "section"}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "ads_not_live"))   # CI: no AdMob
        self.assertEqual(self.c.post(V + "/lp/ads/ticket", {"unlock": "x"},
                                     format="json").status_code, 400)
        g = self.c.get(V + "/lp/gates").json()["ads"]
        self.assertTrue(g["show"])
        self.assertIn("certificate", g["never_in"])
        self.assertIn("timed_mock", g["never_in"])
        with mock.patch.object(LS, "is_premium", return_value=True):
            self.assertEqual(self.c.get(V + "/lp/gates").json()["ads"], {"show": False})
            r = self.c.post(V + "/lp/ads/ticket", {"unlock": "section"}, format="json")
            self.assertEqual(r.json()["reason"], "premium_no_ads")


# ------------------------------------------------- stage 2 tracks (§10.6)
def _tq(n, answer="B", listening=False):
    q = {"n": n, "prompt": "Sample %d" % n, "options": ["ka", "ki", "ku", "ke"], "answer": answer,
         "explain_bn": "নমুনা ব্যাখ্যা।", "skill": "vocab"}
    if listening:
        q["script"] = {"speakers": {"A": {"gender": "F", "role": "clerk"}},
                       "turns": [{"spk": "A", "text": "sample %d" % n}], "repeat": 1}
    return q


def sample_track_items():
    test = {"kind": "mock", "key": "jlpt-n5-901", "track": "jlpt_n5", "level": "N5", "data": {
        "title_en": "JLPT N5 practice 901", "title_bn": "জেএলপিটি N5 অনুশীলন ৯০১", "exam": "JLPT",
        "lang": "ja", "scoring": {"max": 12, "per_question": 4},
        "sections": [
            {"id": "vocab", "kind": "reading", "minutes": 20, "parts": [
                {"part": "v1", "questions": [_tq(1), _tq(2, "C")]}]},
            {"id": "listening", "kind": "listening", "minutes": 30, "parts": [
                {"part": "l1", "questions": [_tq(3, "A", True)]}]}]}}
    lesson = {"kind": "lesson", "key": "ja-w901-l1", "track": "jlpt_n5", "level": "N5", "data": {
        "id": "ja-w901-l1", "lang": "ja", "week": 1, "tracks": ["jlpt_n5", "jft_basic"],
        "vocab": [{"target": "w%d" % i, "bn": "শব্দ"} for i in range(6)],
        "grammar": [{"pattern": "N wa N desu", "explain_bn": "পরিচয়"}],
        "practice": {"listening": [dict(_tq(1, "A", True), id="p1")],
                     "reading": [dict(_tq(1, "B"), id="p2")],
                     "writing": [{"id": "p3", "prompt_bn": "লিখুন"}],
                     "speaking": [{"id": "p4", "prompt_bn": "বলুন"}]}}}
    syl = {"kind": "syllabus", "key": "syl-jlpt_n5", "track": "jlpt_n5", "level": "N5", "data": {
        "title": {"en": "Japanese N5", "bn": "জাপানি N5"},
        "exam_format": {"sections": [{"id": "vocab", "minutes": 20, "questions": 21}]},
        "weeks": [{"week": 1, "lessons": ["ja-w901-l1"]}, {"week": 5, "planned": True}]}}
    return [test, lesson, syl]


@override_settings(MEDIA_ROOT=_MEDIA)
@mock.patch("core.lp_service.flag_on", return_value=True)
class Stage2TrackTests(TestCase):
    def setUp(self):
        out = LS.import_bundle(_bundle(sample_track_items(), audio=False))
        self.assertEqual(out["errors"], [])
        self.c = _client(_user(6))

    def test_imported_and_checked(self, _f):
        for key in ("jlpt-n5-901", "ja-w901-l1", "syl-jlpt_n5"):
            it = LpItem.objects.get(key=key)
            self.assertEqual(it.status, "ai_checked", (key, it.checks))
        bad = sample_track_items()[0]
        bad["key"], bad["data"]["title_en"] = "jlpt-n5-902", "Bad"
        bad["data"]["sections"][0]["parts"][0]["questions"][1]["answer"] = "AB"
        bad["data"]["sections"][1]["parts"][0]["questions"][0].pop("script")
        LS.import_bundle(_bundle([bad], audio=False))
        codes = {f["code"] for f in LpItem.objects.get(key="jlpt-n5-902").checks["failures"]}
        self.assertEqual(codes, {"uniqueness", "format"})

    def test_payload_hides_keys_and_scripts_and_marks_letters(self, _f):
        mocks = self.c.get(V + "/lp/mocks?kind=jlpt_n5").json()["mocks"]
        self.assertEqual(mocks[0]["sections"], ["vocab", "listening"])
        body = self.c.get(V + "/lp/mocks/jlpt-n5-901?section=vocab").json()
        flat = json.dumps(body)
        self.assertNotIn('"answer"', flat)
        self.assertNotIn('"script"', flat)
        self.assertEqual([s["id"] for s in body["sections"]], ["vocab"])
        r = self.c.post(V + "/lp/mocks/jlpt-n5-901/mark", {"section": "vocab",
                                                          "answers": {"1": "B", "2": "A"}},
                        format="json").json()
        self.assertEqual((r["raw"], r["score"], r["max"], r["band"]), (1, 4, 8, None))

    def test_stage3_tracks_six_letters(self, _f):
        t = sample_track_items()[0]
        t["key"], t["track"], t["level"] = "hsk1-901", "hsk1", "HSK1"
        t["data"]["title_en"] = "HSK1 practice 901"
        q = t["data"]["sections"][0]["parts"][0]["questions"][0]
        q.update({"options": ["A1", "B1", "C1", "D1", "E1", "F1"], "answer": "F",
                  "prompt_roman": "nǐ hǎo", "options_roman": ["", "", "", "", "", ""]})
        LS.import_bundle(_bundle([t], audio=False))
        it = LpItem.objects.get(key="hsk1-901")
        self.assertEqual(it.status, "ai_checked", it.checks)
        body = self.c.get(V + "/lp/mocks/hsk1-901?section=vocab").json()
        self.assertEqual(body["sections"][0]["parts"][0]["questions"][0]["prompt_roman"], "nǐ hǎo")
        self.assertNotIn('"answer"', json.dumps(body))
        r = self.c.post(V + "/lp/mocks/hsk1-901/mark", {"section": "vocab", "answers": {"1": "F"}},
                        format="json").json()
        self.assertEqual(r["raw"], 1)
        self.assertEqual(LS.TRACKS["ar_work"], "ar_work")

    def test_lessons_by_track_and_syllabus(self, _f):
        items = self.c.get(V + "/lp/content/lesson?track=jft_basic").json()["items"]
        self.assertEqual([i["id"] for i in items], ["ja-w901-l1"])
        self.assertEqual(self.c.get(V + "/lp/content/lesson?track=eps_topik").json()["items"], [])
        syl = self.c.get(V + "/lp/content/syllabus?track=jlpt_n5").json()["items"]
        self.assertTrue(syl[0]["beta"])


# ------------------------------------------------------- owner-account guard
class OwnerAccountGuardTests(SimpleTestCase):
    def test_lp_tests_never_use_the_owner_account(self):
        """LP tests create only sample learners (+88017110090NN), never a superuser."""
        here = Path(__file__).resolve().parent
        files = list(here.glob("tests_lp*.py"))
        self.assertTrue(files)
        for p in files:
            src = p.read_text(encoding="utf-8")
            self.assertNotRegex(src, r"create_" + r"superuser\(", str(p))
            self.assertNotRegex(src, r"\.is_super" + r"user\s*=\s*True", str(p))
            for phone in re.findall(r"\+?8801\d{9}", src):
                self.assertIn("1711009", phone, str(p))

    def test_owner_refused_under_e2e_settings(self):
        from types import SimpleNamespace
        boss = mock.Mock(is_superuser=True)
        learner = mock.Mock(is_superuser=False)
        e2e = SimpleNamespace(INSTALLED_APPS=["core", "ci_e2e"])
        with mock.patch.object(LS, "settings", e2e):
            self.assertTrue(LS.owner_in_test(boss))
            self.assertFalse(LS.owner_in_test(learner))
        self.assertFalse(LS.owner_in_test(boss))           # production: the owner may learn too

    def test_views_apply_the_guard(self):
        from core import lp_views as LV
        self.assertIn("owner_in_test", Path(LV.__file__).read_text(encoding="utf-8"))
