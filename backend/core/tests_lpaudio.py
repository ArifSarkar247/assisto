"""lpaudio: recorded IELTS listening audio (CI-rendered, release lp-audio).

Proves: plans are deterministic and multi-voice; `manage.py lp_audio` attaches
only sha256-checked files whose plan hash is the CURRENT script; the phone gets
audio_url + timings and NEVER the script, turns, transcript or answers; a
stale or tampered file is refused; lp_seed keeps the audio on later runs.
Tests use a made-up learner account (never the owner) and fake audio bytes.
"""
import hashlib
import io
import json
import os
import shutil
import tempfile
from unittest import mock

from django.core.management import CommandError, call_command
from django.test import SimpleTestCase, TestCase, override_settings
from rest_framework.test import APIClient

from core import lp_service as LS
from core.logic import lp_audio as AU
from core.logic import lp_seed as SD
from core.management.commands import lp_audio as CMD
from core.management.commands.lp_seed import repo_root
from core.models import LpItem, User

V = "/api/v1"
CONTENT = os.path.join(repo_root(), "tools", "lp", "content")
BUNDLE = "ielts-ac-001"


def _bundle(bid=BUNDLE):
    with open(os.path.join(CONTENT, "ielts", bid + ".json"), encoding="utf-8") as fh:
        return json.load(fh)


def _track(bid="fr-a1-001", lang="fr"):
    with open(os.path.join(CONTENT, lang, bid + ".json"), encoding="utf-8") as fh:
        return json.load(fh)


def _fake_release(folder, bid=BUNDLE, tamper=None, stale=None, extra=()):
    """manifest.json + fake .m4a bytes for every part of one bundle (+ extra plans)."""
    parts = []
    for pl in list(AU.bundle_plans(_bundle(bid))) + list(extra):
        blob = ("fake-aac-%s" % pl["file"]).encode()
        with open(os.path.join(folder, pl["file"]), "wb") as fh:
            fh.write(blob)
        parts.append({"bundle": pl["bundle"], "part": pl["part"], "file": pl["file"],
                      "plan_hash": "0" * 64 if stale == pl["part"] else pl["hash"],
                      "sha256": "f" * 64 if tamper == pl["part"] else hashlib.sha256(blob).hexdigest(),
                      "bytes": len(blob), "duration_sec": 300.5, "accents": pl["accents"],
                      "preview_sec": pl["preview_sec"], "check_sec": pl["check_sec"], "voices": pl["voices"]})
    with open(os.path.join(folder, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump({"format": AU.FORMAT, "parts": parts}, fh)
    return parts


class PlanTests(SimpleTestCase):
    def test_plans_deterministic_multi_voice_honest_accents(self):
        a, b = AU.bundle_plans(_bundle()), AU.bundle_plans(_bundle())
        self.assertEqual([p["hash"] for p in a], [p["hash"] for p in b])
        self.assertEqual(len(a), 4)
        conv = a[0]
        self.assertGreaterEqual(len(conv["voices"]), 2)
        self.assertEqual(len({v["voice"] for v in conv["voices"]}), len(conv["voices"]))
        for p in a:
            self.assertTrue(set(p["accents"]) <= {"en-GB", "en-US"})
            self.assertNotIn(AU.NARRATOR, [v["voice"] for v in p["voices"]])
        self.assertEqual(a[-1]["check_sec"], AU.FINAL_CHECK_SEC)
        self.assertEqual(a[0]["check_sec"], AU.CHECK_SEC)

    def test_attach_skips_an_edited_script(self):
        d = _bundle()
        plans = AU.bundle_plans(d)
        idx = {BUNDLE: {str(p["part"]): {"audio": "lp/x%d.m4a" % p["part"], "plan_hash": p["hash"],
                                         "duration_sec": 10} for p in plans}}
        d["listening"]["parts"][1]["turns"][0]["text"] += " (edited)"
        lis = AU.attach(json.loads(json.dumps(d["listening"])), d, idx)
        self.assertEqual(lis["parts"][0]["audio"], "lp/x1.m4a")
        self.assertNotIn("audio", lis["parts"][1])           # stale -> no audio

    def test_speakable(self):
        self.assertEqual(AU.speakable("P-E-L-H-A-M, Pelham"), "P, E, L, H, A, M, Pelham")
        self.assertEqual(AU.speakable("the early 1700s"), "the early seventeen hundreds")
        self.assertEqual(AU.num_words(31), "thirty-one")


@mock.patch("core.lp_service.flag_on", return_value=True)
class AttachTests(TestCase):
    @classmethod
    def setUpClass(cls):
        cls._media = tempfile.mkdtemp(prefix="lpaudio-media-")
        cls._ov = override_settings(MEDIA_ROOT=cls._media)
        cls._ov.enable()
        super().setUpClass()

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        cls._ov.disable()
        shutil.rmtree(cls._media, ignore_errors=True)

    @classmethod
    def setUpTestData(cls):
        call_command("lp_seed", stdout=io.StringIO())

    def setUp(self):
        from django.core.files.storage import default_storage
        if default_storage.exists(CMD.INDEX):          # files outlive the per-test DB rollback
            default_storage.delete(CMD.INDEX)
        self.rel = tempfile.mkdtemp(prefix="lpaudio-rel-")
        self.addCleanup(shutil.rmtree, self.rel, True)
        self.u = User.objects.create_user(name="Listener Test", phone="+8801711009977", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def _listening(self):
        r = self.c.get(V + "/lp/mocks/%s?section=listening" % BUNDLE)
        self.assertEqual(r.status_code, 200, r.content[:200])
        return r

    def test_attach_then_phone_gets_audio_and_never_the_script(self, _f):
        _fake_release(self.rel)
        out = io.StringIO()
        call_command("lp_audio", dir=self.rel, stdout=out)
        rep = json.loads(out.getvalue())
        self.assertEqual(rep["attached"], 4, rep)
        r = self._listening()
        body = r.json()["listening"]
        self.assertTrue(body["audio_ready"])
        for i, p in enumerate(body["parts"]):
            self.assertTrue(p["audio_url"], p)
            self.assertEqual(p["duration_sec"], 300.5)
            self.assertEqual(p["preview_sec"], 30)
            self.assertEqual(p["check_sec"], 120 if i == 3 else 30)
            self.assertTrue(set(p["accents"]) <= {"en-GB", "en-US"})
            self.assertNotIn("tts", p)
        raw = r.content.decode()
        for hidden in ('"answer"', '"explain_bn"', '"explain_en"', '"transcript"', '"turns"',
                       '"lines"', '"intro"', '"script"', '"plan_hash"', '"tag"'):
            self.assertNotIn(hidden, raw)
        d = _bundle()
        for p in d["listening"]["parts"]:            # no sentence of any script reaches the phone
            for t in p["turns"][:3]:
                self.assertNotIn(t["text"][:60], raw)
            for q in p["questions"]:
                for a in (q["answer"] if isinstance(q["answer"], list) else [q["answer"]]):
                    if len(str(a)) > 3:
                        self.assertNotIn('"%s"' % a, raw)
        # the full mock (offline download) carries the same audio links, still no script
        full = self.c.get(V + "/lp/mocks/%s" % BUNDLE)
        if full.status_code == 200:
            self.assertNotIn('"turns"', full.content.decode())
        # marking still works server-side
        m = self.c.post(V + "/lp/mocks/%s/mark" % BUNDLE, {"section": "listening", "answers": {"1": "Brennick"}},
                        format="json").json()
        self.assertEqual(m["total"], 40)
        self.assertGreaterEqual(m["raw"], 1)

    def test_rerun_and_reseed_keep_audio(self, _f):
        _fake_release(self.rel)
        call_command("lp_audio", dir=self.rel, stdout=io.StringIO())
        n = LpItem.objects.count()
        out = io.StringIO()
        call_command("lp_audio", dir=self.rel, stdout=out)
        self.assertEqual(json.loads(out.getvalue())["reused"], 4)
        call_command("lp_seed", stdout=io.StringIO())
        self.assertEqual(LpItem.objects.count(), n)           # no new versions, audio kept
        self.assertTrue(self._listening().json()["listening"]["audio_ready"])

    def test_tampered_file_refused_stale_skipped(self, _f):
        _fake_release(self.rel, tamper=2, stale=3)
        out = io.StringIO()
        with self.assertRaises(CommandError):
            call_command("lp_audio", dir=self.rel, stdout=out)
        rep = json.loads(out.getvalue())
        self.assertEqual(rep["attached"], 2)
        self.assertEqual(len(rep["bad"]), 1)
        self.assertEqual(rep["stale"], ["%s p3" % BUNDLE])
        parts = self._listening().json()["listening"]["parts"]
        self.assertTrue(parts[0]["audio_url"])
        self.assertIsNone(parts[1]["audio_url"])
        self.assertIsNone(parts[2]["audio_url"])
        self.assertNotIn("tts", parts[1])                     # still no script to the phone

    def test_index_is_private_media_and_seed_is_pure(self, _f):
        _fake_release(self.rel)
        call_command("lp_audio", dir=self.rel, stdout=io.StringIO())
        idx = CMD.load_index()
        self.assertEqual(sorted(idx[BUNDLE]), ["1", "2", "3", "4"])
        for e in idx[BUNDLE].values():
            self.assertTrue(e["audio"].startswith("lp/") and e["audio"].endswith(".m4a"))
        it = SD.ielts_item(_bundle(), idx)
        self.assertTrue(all(p.get("audio") for p in it["data"]["listening"]["parts"]))
        self.assertTrue(all(p.get("turns") for p in it["data"]["listening"]["parts"]))  # server keeps the script
        sec = LS.live_item(BUNDLE + "-listening", "section")
        self.assertIn(sec.status, ("ai_checked", "human_approved"))


@mock.patch("core.lp_service.flag_on", return_value=True)
class TrackAudioTests(TestCase):
    """French A1 test: recorded questions stream audio and send NO script lines."""
    @classmethod
    def setUpClass(cls):
        cls._media = tempfile.mkdtemp(prefix="lpaudio-media2-")
        cls._ov = override_settings(MEDIA_ROOT=cls._media)
        cls._ov.enable()
        super().setUpClass()

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        cls._ov.disable()
        shutil.rmtree(cls._media, ignore_errors=True)

    @classmethod
    def setUpTestData(cls):
        call_command("lp_seed", stdout=io.StringIO())

    def test_track_question_gets_audio_not_lines(self, _f):
        d = _track()
        plans = AU.track_plans(d, "fr")
        self.assertTrue(plans)
        self.assertTrue(all(p["plays"] == 2 for p in plans))       # "vous l'entendrez deux fois"
        rel = tempfile.mkdtemp(prefix="lpaudio-rel2-")
        self.addCleanup(shutil.rmtree, rel, True)
        _fake_release(rel, extra=plans)
        out = io.StringIO()
        call_command("lp_audio", dir=rel, stdout=out)
        self.assertEqual(json.loads(out.getvalue())["attached"], 4 + len(plans))
        u = User.objects.create_user(name="Track Listener", phone="+8801711009978", password="pw12345!")
        c = APIClient()
        c.force_authenticate(u)
        sec = next(s["id"] for s in d["sections"]
                   if any(q.get("script") for p in s.get("parts") or [] for q in p.get("questions") or []))
        with mock.patch.object(LS, "is_premium", return_value=True):
            r = c.get(V + "/lp/mocks/fr-a1-001?section=%s" % sec)
        self.assertEqual(r.status_code, 200, r.content[:200])
        raw = r.content.decode()
        self.assertNotIn('"lines"', raw)
        self.assertNotIn('"script"', raw)
        self.assertNotIn('"audio_meta"', raw)
        qs = [q for s in r.json()["sections"] for p in s.get("parts") or [] for q in p["questions"] if q.get("tts")]
        self.assertTrue(qs)
        for q in qs:
            self.assertTrue(q["tts"]["audio_url"])
            self.assertEqual(q["tts"]["repeat"], 1)

    def test_no_voice_language_keeps_phone_voice(self, _f):
        # Korean has no licence-clean voice yet: no plan, the phone voice stays (honest gap)
        with open(os.path.join(CONTENT, "ko", sorted(f for f in os.listdir(os.path.join(CONTENT, "ko"))
                                                     if f.startswith("eps"))[0]), encoding="utf-8") as fh:
            self.assertEqual(AU.track_plans(json.load(fh), "ko"), [])
