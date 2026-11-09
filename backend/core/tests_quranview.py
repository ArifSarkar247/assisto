"""quranview (lane 14, owner 9 Nov 21:55): bilingual ayah view sources.

Spec + licence table: owner_actions/QURAN_BILINGUAL_SPEC_BN.md. Network is
faked (no live QuranEnc / Quran Foundation calls in CI). Texts used below are
real QuranEnc texts (verbatim) or clearly marked test strings.
"""
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from core import integrations as I
from core import quran_bilingual as QB
from core.models import Integration, User

ZAK_80_1_NOTE = (
    "<b> সূরা সম্পর্কিত তথ্য: </b>\n\nকিন্তু আল্লাহ্ তা'আলা নবীর এ বিরক্তি প্রকাশ "
    "পছন্দ করলেন না। তিনি আয়াত নাযিল করে তার প্রতিকার করেন। [দেখুন, তিরমিয়ী ৩৩২৮]\n\n"
    "___________________\n\n[১] عبس শব্দের অর্থ রুষ্টতা অবলম্বন করা।")
ZAK_1_1_NOTE = (
    "<b> সূরার নাম ও কিছু বৈশিষ্ট্য: </b> \n\nসূরা আল-ফাতিহা-ই সর্বপ্রথম কুরআন মাজীদের "
    "একটি পূর্ণাঙ্গ সূরা হিসাবে রাসূলের প্রতি নাযিল হয়েছে। সৰ্বপ্রথম অহীর মাধ্যমে "
    "মুহাম্মদ সাল্লাল্লাহু ‘আলাইহি ওয়াসাল্লামের প্রতি যে আয়াত বা সূরার অংশ নাযিল হয় তা "
    "হচ্ছে সূরা ‘আল-‘আলাক’-এর প্রাথমিক আয়াত কয়টি।\n[১] রহমান ও রহীম আল্লাহর নাম।")


class _R:
    def __init__(self, status, data):
        self.status_code = status
        self._d = data

    def json(self):
        return self._d


class FakeHttp:
    """Answers QuranEnc + QF URLs; records every call."""

    def __init__(self, qf_ok=True):
        self.calls = []
        self.qf_ok = qf_ok

    def get(self, url, params=None, timeout=None, headers=None):
        self.calls.append(("GET", url, dict(params or {}), dict(headers or {})))
        if url.endswith("/translations/updates"):
            v = {"bengali_zakaria": "1.1.1", "english_saheeh": "1.1.2",
                 "bengali_mokhtasar": "1.0.0"}[params["key"]]
            return _R(200, {"key": params["key"], "version": v, "last_update": 1})
        if "/translation/sura/" in url:
            key, sura = url.rsplit("/", 2)[-2:]
            rows = [{"aya": "1", "translation": "%s %s:1" % (key, sura),
                     "footnotes": ZAK_80_1_NOTE if (key == "bengali_zakaria" and sura == "80")
                     else ZAK_1_1_NOTE if key == "bengali_zakaria" else ""}]
            return _R(200, {"result": rows})
        if "/verses/by_key/" in url:
            lang = params.get("language")
            return _R(200, {"verse": {
                "translations": [{"text": "Bismi <i>Allahi</i>"}],
                "words": [
                    {"position": 1, "char_type_name": "word", "text_uthmani": "بِسْمِ",
                     "translation": {"text": "নামে" if lang == "bn" else "In (the) name"},
                     "transliteration": {"text": "bis'mi"}},
                    {"position": 2, "char_type_name": "end", "text_uthmani": "١"},
                ]}})
        if "/recitations/" in url and "/by_ayah/" in url:
            return _R(200, {"audio_files": [{"verse_key": "1:1",
                                             "url": "Alafasy/mp3/001001.mp3"}]})
        if url.endswith("/resources/recitations"):
            return _R(200, {"recitations": [
                {"id": 7, "reciter_name": "Mishari Rashid al-`Afasy", "style": None,
                 "translated_name": {"name": "Mishari Rashid al-`Afasy"}}]})
        return _R(404, {})

    def post(self, url, data=None, auth=None, timeout=None):
        self.calls.append(("POST", url, dict(data or {}), {}))
        if not self.qf_ok:
            return _R(401, {"error": "invalid_client"})
        return _R(200, {"access_token": "tok-test", "expires_in": 3600})


class _RecCache:
    """Records every cache.set (key, ttl); never returns a hit."""

    def __init__(self):
        self.sets = []

    def get(self, key, default=None):
        return default

    def set(self, key, value, ttl=None):
        self.sets.append((key, ttl))


class Base(TestCase):
    def setUp(self):
        cache.clear()
        self.http = FakeHttp()
        p = mock.patch.object(QB, "_http", lambda: self.http)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(cache.clear)

    def qf_on(self):
        Integration.objects.update_or_create(slug=QB.QF_SLUG, defaults={"status": "working"})
        p = mock.patch.object(I, "get", lambda slug: {"client_id": "cid-test",
                                                      "client_secret": "sec-test"}
                              if slug == QB.QF_SLUG else {})
        p.start()
        self.addCleanup(p.stop)


class SourceRules(Base):
    def test_ayah_counts_match_tanzil(self):
        self.assertEqual(len(QB.AYAH_COUNTS), 114)
        self.assertEqual(sum(QB.AYAH_COUNTS), 6236)
        self.assertTrue(QB.valid_ref(2, 286))
        self.assertFalse(QB.valid_ref(2, 287))
        self.assertFalse(QB.valid_ref(115, 1))

    def test_meaning_is_verbatim_with_publisher_and_version(self):
        m = QB.meaning(1)
        self.assertEqual(m["bn"]["version"], "1.1.1")
        self.assertEqual(m["en"]["version"], "1.1.2")
        self.assertEqual(m["bn"]["source"], "QuranEnc.com")
        self.assertEqual(m["bn"]["items"][0]["text"], "bengali_zakaria 1:1")
        self.assertEqual(m["en"]["items"][0]["text"], "english_saheeh 1:1")

    def test_new_publisher_version_replaces_the_cache(self):
        QB.meaning(1)
        n = len([c for c in self.http.calls if "/translation/sura/" in c[1]])
        QB.meaning(1)
        self.assertEqual(len([c for c in self.http.calls if "/translation/sura/" in c[1]]), n)
        cache.delete("qv:ver:bengali_zakaria")
        cache.set("qv:ver:bengali_zakaria", {"version": "1.1.2", "last_update": 2}, 60)
        m = QB.meaning(1)
        self.assertEqual(m["bn"]["version"], "1.1.2")
        self.assertEqual(len([c for c in self.http.calls if "/translation/sura/" in c[1]]), n + 1)

    def test_no_ai_imports(self):
        src = open(QB.__file__, encoding="utf-8").read()
        for bad in ("anthropic", "openai", "gemini", "core.ai", "from .ai", "ai_prompt"):
            self.assertNotIn(bad, src)


class ShanNuzul(Base):
    def test_unit_that_states_the_reason_is_returned_whole_and_verbatim(self):
        t = QB.tafsir(80, 1)
        sn = [x for x in t["shan_nuzul"] if x["source_id"] == "zakaria_notes_bn"]
        self.assertEqual(len(sn), 1)
        self.assertIn(sn[0]["text"], ZAK_80_1_NOTE)  # exact substring, nothing changed
        self.assertTrue(sn[0]["text"].startswith("<b> সূরা সম্পর্কিত তথ্য"))
        self.assertNotIn("[১]", sn[0]["text"])  # only that unit
        self.assertEqual(t["shan_nuzul_rule"], "keyword_v1")

    def test_order_of_revelation_is_not_a_reason(self):
        # "Al-Fatiha was the first complete surah revealed" is not shane nuzul
        t = QB.tafsir(1, 1)
        self.assertEqual([x for x in t["shan_nuzul"] if x["source_id"] == "zakaria_notes_bn"], [])

    def test_rules(self):
        self.assertTrue(QB.states_reason("এ প্রসঙ্গে এই আয়াত নাযিল হয়।", "bn"))
        self.assertTrue(QB.states_reason("এ আয়াতের শানে নুযূল সম্পর্কে বর্ণিত আছে।", "bn"))
        # য় written as য + nukta still matches
        self.assertTrue(QB.states_reason("এ আয়াত নাযিল হয়।", "bn"))
        self.assertFalse(QB.states_reason("কুরআন রমযান মাসে নাযিল হয়েছে।", "bn"))
        self.assertTrue(QB.states_reason("This verse was revealed concerning the hypocrites.", "en"))
        self.assertTrue(QB.states_reason("It was revealed when the Prophet was asked.", "en"))
        self.assertFalse(QB.states_reason("Allah is a proper name.", "en"))

    def test_split_units_keeps_text(self):
        u = QB.split_units(ZAK_80_1_NOTE)
        self.assertEqual(len(u), 2)
        self.assertTrue(u[1].startswith("[১] عبس"))

    def test_only_licensed_sources(self):
        ids = {s["id"] for s in QB.tafsir(80, 1)["sources"]}
        self.assertTrue(ids <= {"mukhtasar_bn", "zakaria_notes_bn", "saheeh_notes_en"})
        self.assertFalse(any("qul" in u or "tarteel" in u for _, u, _, _ in self.http.calls))


class QuranFoundation(Base):
    def test_not_connected_is_honest(self):
        self.assertEqual(QB.qf_ayah(1, 1), {"ok": True, "enabled": False})
        self.assertEqual(QB.qf_reciters()["enabled"], False)
        self.assertFalse(any("quran.foundation" in c[1] for c in self.http.calls))

    def test_words_translit_audio(self):
        self.qf_on()
        d = QB.qf_ayah(1, 1)
        self.assertTrue(d["enabled"])
        self.assertEqual(d["translit"], "Bismi Allahi")  # markup dropped only
        self.assertEqual(d["words"], [{"pos": 1, "ar": "بِسْمِ", "tr": "bis'mi",
                                       "bn": "নামে", "en": "In (the) name"}])
        self.assertEqual(d["audio_url"], "https://verses.quran.foundation/Alafasy/mp3/001001.mp3")
        self.assertLessEqual(d["max_age_days"], 6)
        got = [c for c in self.http.calls if "/verses/by_key/1:1" in c[1]]
        self.assertEqual(got[0][3], {"x-auth-token": "tok-test", "x-client-id": "cid-test"})
        self.assertEqual({c[2]["language"] for c in got}, {"bn", "en"})

    def test_cache_ttl_below_seven_days(self):
        self.qf_on()
        rc = _RecCache()
        with mock.patch.object(QB, "cache", rc):
            QB.qf_ayah(1, 1)
            QB.qf_reciters()
        ttls = [t for k, t in rc.sets if k.startswith(("qv:qf:ayah", "qv:qf:reciters"))]
        self.assertTrue(ttls and all(t < 7 * 86400 for t in ttls))

    def test_banned_audio_hosts(self):
        self.assertIsNone(QB.audio_url("https://download.quranicaudio.com/qdc/x.mp3"))
        self.assertIsNone(QB.audio_url("https://everyayah.com/data/x.mp3"))
        self.assertEqual(QB.audio_url("//verses.quran.foundation/a.mp3"),
                         "https://verses.quran.foundation/a.mp3")

    def test_owner_admin_card_and_test(self):
        self.assertIn(QB.QF_SLUG, I.REGISTRY)
        meta = I.REGISTRY[QB.QF_SLUG]
        self.assertEqual(meta["test"], "test_quran_foundation")
        secret = {f["key"]: f["secret"] for f in meta["fields"]}
        self.assertTrue(secret["client_secret"])
        self.assertFalse(secret["client_id"])
        ok, _ = I.test_quran_foundation({"client_id": "a", "client_secret": "b"}, http=self.http)
        self.assertTrue(ok)
        ok, msg = I.test_quran_foundation({"client_id": "a"}, http=self.http)
        self.assertFalse(ok)
        bad = FakeHttp(qf_ok=False)
        ok, msg = I.test_quran_foundation({"client_id": "a", "client_secret": "b"}, http=bad)
        self.assertFalse(ok)
        self.assertIn("qf_auth_failed", msg)


class Api(Base):
    def setUp(self):
        super().setUp()
        self.u = User.objects.create_user(name="Test Reader", phone="01710009401", password="pw-123456")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_requires_login(self):
        self.assertIn(APIClient().get("/api/v1/quran/meaning/1").status_code, (401, 403))

    def test_endpoints(self):
        r = self.c.get("/api/v1/quran/meaning/1")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["bn"]["version"], "1.1.1")
        r = self.c.get("/api/v1/quran/tafsir/80/1")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["shan_nuzul"])
        self.assertEqual(self.c.get("/api/v1/quran/qf/1/1").json(), {"ok": True, "enabled": False})
        self.assertEqual(self.c.get("/api/v1/quran/reciters").json()["enabled"], False)

    def test_bad_refs(self):
        self.assertEqual(self.c.get("/api/v1/quran/meaning/115").status_code, 400)
        self.assertEqual(self.c.get("/api/v1/quran/tafsir/1/8").status_code, 400)
        self.assertEqual(self.c.get("/api/v1/quran/qf/1/1?reciter=x").status_code, 400)

    def test_source_down_is_503_not_invented(self):
        class Down(FakeHttp):
            def get(self, *a, **k):
                raise OSError("down")
        self.http = Down()
        r = self.c.get("/api/v1/quran/meaning/2")
        self.assertEqual(r.status_code, 503)
        self.assertFalse(r.json()["ok"])
