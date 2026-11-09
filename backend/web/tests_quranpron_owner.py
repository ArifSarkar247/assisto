"""quranpron: Owner Admin -> Quran pronunciation review queue (per surah /
ayah: approve / reject with note / rule fix request; audit; bn/en; owner only)."""
from core import quran_pron as QP
from core.models import OwnerAudit, PaCollectionItem
from web.tests_o2_owner_admin import OwnerBase, SClient


class QuranPronOwnerTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def test_queue_shows_arabic_bangla_and_rules(self):
        r = self.c.get("/owner/quran-pron?surah=112&lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, QP.transliterate(QP.corpus()[(112, 2)])["bn"])
        self.assertContains(r, "qalqalah_kubra")
        self.assertContains(r, "Under review")
        self.assertContains(r, QP.bismillah_bn())
        r = self.c.get("/owner/quran-pron?surah=999&status=bogus&lang=bn")
        self.assertContains(r, "কুরআন উচ্চারণ")

    def test_approve_reject_rule_request_audited(self):
        r = self.post("/owner/quran-pron/act", {"surah": 112, "ayah": 1, "action": "approve"})
        self.assertEqual(r.status_code, 302)
        self.assertIn("m=saved", r["Location"])
        self.assertTrue(OwnerAudit.objects.filter(action="quran_pron.approve", target="quran:112:1").exists())
        r = self.post("/owner/quran-pron/act", {"surah": 112, "ayah": 2, "action": "reject"})
        self.assertIn("m=invalid", r["Location"])                    # a note is required
        self.post("/owner/quran-pron/act", {"surah": 112, "ayah": 2, "action": "reject",
                                            "note": "ছামাদ — ص heavy"})
        self.post("/owner/quran-pron/act", {"surah": 112, "ayah": 3, "action": "rule_request",
                                            "note": "qalqalah", "suggestion": "লাম্ ইয়ালিদ্"})
        self.assertEqual(PaCollectionItem.objects.filter(collection="quran_pron").count(), 3)
        r = self.c.get("/owner/quran-pron?surah=112&status=approved&lang=en")
        self.assertContains(r, 'id="a1"')
        self.assertNotContains(r, 'id="a2"')
        r = self.c.get("/owner/quran-pron?surah=112&status=needs_fix&lang=en")
        self.assertContains(r, 'id="a3"')
        self.assertContains(r, "লাম্ ইয়ালিদ্")
        r = self.post("/owner/quran-pron/act", {"surah": 112, "ayah": 99, "action": "approve"})
        self.assertIn("m=invalid", r["Location"])
        self.assertTrue(OwnerAudit.objects.filter(action="quran_pron.approve", ok=False).exists())

    def test_requires_owner(self):
        r = SClient().get("/owner/quran-pron")
        self.assertEqual((r.status_code, r["Location"]), (302, "/owner/login"))
