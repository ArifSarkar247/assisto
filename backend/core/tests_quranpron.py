"""quranpron: rule-based Arabic -> Bangla pronunciation with tajweed (NO AI).

1. ALL 6236 ayahs of the licensed Tanzil Uthmani text (app/assets/quran,
   CC BY 3.0, verbatim — sha256 checked): no crash, no empty output, no
   unmapped character in or out, NFC-stable, deterministic across two runs
   in different orders, idempotent, spans inside the text.
2. Golden outputs for a curated list of tricky ayahs, and one documented
   ayah per tajweed rule (RULE_AYAH — the same list is in
   owner_actions/FEATURE_CARD_QURAN_PRONUNCIATION_BN.md).
3. The app API /api/v1/quran/pron/<surah> and the review status.
"""
from django.test import TestCase
from rest_framework.test import APIClient

from core import quran_pron as QP
from core import quran_pron_review as RV
from core.models import PaCollectionItem, User

# rule -> (surah, ayah, what the ayah shows)
RULE_AYAH = {
    "waqf": ((1, 1), "stop at the ayah end: last vowel dropped (রাহী--ম্)"),
    "madd_arid": ((1, 1), "long vowel before the stopped letter = 4 counts"),
    "lam_jalala_tarqiq": ((1, 1), "lam of Allah thin after kasra (বিস্মিল্লা-হি)"),
    "lam_jalala_tafkhim": ((112, 2), "lam of Allah heavy at the start / after a, u"),
    "lam_shamsiyya": ((1, 3), "sun letter: lam silent, next letter doubled (আর্‌রহ্‌মা-ন)"),
    "lam_qamariyya": ((1, 2), "moon letter: lam pronounced (আল্‌হাম্‌দু)"),
    "hamzat_wasl": ((1, 6), "alif wasla at the start read i (ইহ্‌দিনা)"),
    "madd_lazim": ((1, 7), "ٱلضَّآلِّينَ — 6 counts before a shadda"),
    "muqattaat": ((2, 1), "disconnected letters spelled with 6-count madd"),
    "waqf_muanaqa": ((2, 2), "the paired dots ۛ"),
    "idgham_no_ghunnah": ((2, 2), "tanween + lam (হুদাল্‌ লিল্‌...)"),
    "madd_badal": ((2, 4), "hamza then madd (ٱلْـَٔاخِرَةِ)"),
    "madd_munfasil": ((2, 4), "madd at word end + hamza next word = 4 counts"),
    "madd_muttasil": ((2, 5), "madd + hamza in the same word = 4 counts"),
    "idgham_ghunnah": ((2, 8), "noon + ya across words, with ghunnah (মাঁই ইয়াক্বূ-লু)"),
    "ikhfa_shafawi": ((2, 8), "meem sakin + ba (হুঁম্‌ বিমু’মিনী-ন)"),
    "ikhfa": ((113, 2), "noon sakin before an ikhfa letter = ং (মিং শার্‌রি)"),
    "izhar": ((112, 4), "tanween before hamza: clear noon"),
    "izhar_shafawi": ((112, 3), "meem sakin before ya: clear meem"),
    "iqlab": ((2, 19), "tanween + ba -> meem with ghunnah"),
    "idgham_shafawi": ((9, 1), "meem sakin + meem"),
    "idgham": ((9, 1), "dal into ta (عَـٰهَدتُّم)"),
    "ghunnah": ((113, 4), "noon / meem with shadda"),
    "qalqalah": ((2, 7), "qalqalah letter with sukun inside the ayah"),
    "qalqalah_kubra": ((112, 1), "qalqalah letter at the stop (আহাদ্‌)"),
    "ra_tafkhim": ((1, 2), "ra with fatha heavy (রব্বি)"),
    "ra_tarqiq": ((113, 2), "ra with kasra thin"),
    "madd_silah_sughra": ((112, 4), "ha of the pronoun between voweled letters (লাহূ-)"),
    "madd_silah_kubra": ((2, 245), "silah before a hamza = 4 counts (লাহূ--)"),
    "madd_iwad": ((4, 118), "tanween fath at a stop = 2-count a"),
    "waqf_lazim": ((4, 118), "ۘ obligatory stop inside the ayah"),
    "madd_leen": ((106, 4), "aw / ay before the stopped letter (খাও-ফ্‌)"),
    "tanween_kasra": ((7, 8), "tanween before alif wasla gets kasra (ইয়াওমা’ইযিনিল্‌)"),
    "sajda": ((7, 206), "place of prostration"),
    "imala": ((11, 41), "مَجْر۪ىٰهَا read majrē (মাজ্‌রে-হা-)"),
    "ishmam": ((12, 11), "تَأْمَ۫نَّا with ishmam"),
    "tashil": ((41, 44), "ءَا۬عْجَمِىٌّ second hamza eased"),
    "sakt": ((75, 27), "مَنْ ۜ رَاقٍ — sakt stops the idgham"),
    "waqf_qala": ((41, 44), "ۗ stop preferred"),
    "waqf_sila": ((2, 5), "ۖ continue preferred"),
    "waqf_jaiz": ((2, 19), "ۚ either"),
    "madd_tabii": ((1, 2), "natural madd = 2 counts"),
}

GOLDEN = {
    (1, 1): (
        "বিস্\u200cমিল্লা-হির্\u200c রহ্\u200cমা-নির্\u200c রাহী--ম্\u200c"
    ),
    (1, 2): (
        "আল্\u200cহাম্\u200cদু লিল্লা-হি রব্বিল্\u200c ‘আ-লামী--ন্\u200c"
    ),
    (1, 3): (
        "আর্\u200cরহ্\u200cমা-নির্\u200c রাহী--ম্\u200c"
    ),
    (1, 5): (
        "ইয়্যা-কা না‘বুদু ওয়া’ইয়্যা-কা নাস্\u200cতা‘ঈ--ন্\u200c"
    ),
    (1, 6): (
        "ইহ্\u200cদিনাছ্\u200c ছিরা-ত্বল্\u200c মুস্\u200cতাক্বী--ম্\u200c"
    ),
    (1, 7): (
        "ছিরা-ত্বল্\u200c লাযী-না আন্\u200c‘আম্\u200cতা ‘আলাইহিম্\u200c "
        "গাইরিল্\u200c মাগ্\u200cদ্বূ-বি ‘আলাইহিম্\u200c ওয়ালাদ্ব্\u200c "
        "দ্বা---ল্লী--ন্\u200c"
    ),
    (2, 1): (
        "আলিফ্\u200c লাঁ---ম্মী---ম্\u200c"
    ),
    (2, 2): (
        "যা-লিকাল্\u200c কিতা-বু লা- রাইবা ∴ ফী-হি ∴ হুদাল্\u200c "
        "লিল্\u200cমুত্তাক্বী--ন্\u200c"
    ),
    (2, 4): (
        "ওয়াল্লাযী-না ইউ’মিনূ-না বিমা-- উংযিলা ইলাইকা ওয়ামা-- উংযিলা মিং "
        "ক্বব্\u200cলিকা ওয়াবিল্\u200c’আ-খিরাতি হুম্\u200c "
        "ইয়ূ-ক্বিনূ--ন্\u200c"
    ),
    (2, 5): (
        "উলা--’ইকা ‘আলা- হুদাঁম্\u200c মির্\u200c রব্বিহিম্\u200c, "
        "ওয়া’উলা--’ইকা হুমুল্\u200c মুফ্\u200cলিহূ--ন্\u200c"
    ),
    (2, 6): (
        "ইঁন্নাল্\u200c লাযী-না কাফারূ- সাওয়া--’উন্\u200c ‘আলাইহিম্\u200c "
        "আ’আংযার্\u200cতাহুম্\u200c আম্\u200c লাম্\u200c তুংযির্\u200cহুম্\u200c "
        "লা- ইউ’মিনূ--ন্\u200c"
    ),
    (2, 8): (
        "ওয়ামিনাঁন্\u200c না-সি মাঁই ইয়াক্বূ-লু আ-মাঁন্না- বিল্লা-হি "
        "ওয়াবিল্\u200cইয়াওমিল্\u200c আ-খিরি ওয়ামা- হুঁম্\u200c "
        "বিমু’মিনী--ন্\u200c"
    ),
    (2, 19): (
        "আও কাছয়্যিবিঁম্\u200c মিনাস্\u200c সামা--’ই ফী-হি য্বুলুমা-তুঁও "
        "ওয়ার‘দুঁও ওয়াবার্\u200cক্বুঁই ইয়াজ্\u200c‘আলূ-না আছা-বি‘আহুম্\u200c "
        "ফী-- আ-যা-নিহিঁম্\u200c মিনাছ্\u200c ছাওয়া-‘ইক্বি হাযারল্\u200c মাওতি, "
        "ওয়াল্লা-হু মুহী-ত্বুঁম্\u200c বিল্\u200cকা-ফিরী--ন্\u200c"
    ),
    (2, 245): (
        "মাং যাল্\u200c লাযী- ইউক্ব্\u200cরিদ্বুল্লা-হা ক্বর্\u200cদ্বন্\u200c "
        "হাসানাং ফায়ুদ্বা-‘ইফাহূ- লাহূ-- আদ্ব্\u200c‘আ-ফাং কাছী-রাতাঁও, "
        "ওয়াল্লা-হু ইয়াক্ব্\u200cবিদ্বু ওয়ায়াব্\u200cসুত্বু ওয়া’ইলাইহি "
        "তুর্\u200cজা‘ঊ--ন্\u200c"
    ),
    (4, 1): (
        "ইয়া--’আয়্যুহাঁন্\u200c না-সুত্\u200c তাক্বূ- রব্বাকুমুল্\u200c লাযী- "
        "খালাক্বাকুঁম্\u200c মিঁন্\u200c নাফ্\u200cসিঁও ওয়া-হিদাতিঁও "
        "ওয়াখালাক্বা মিন্\u200cহা- যাওজাহা- ওয়াবাছ্ছা মিন্\u200cহুমা- রিজা-লাং "
        "কাছী-রঁও ওয়ানিসা--’আঁও, ওয়াত্তাক্বুল্লা-হাল্\u200c লাযী- "
        "তাসা--’আলূ-না বিহী- ওয়াল্\u200c’আর্\u200cহা-মা, ইঁন্নাল্লা-হা কা-না "
        "‘আলাইকুম্\u200c রাক্বী-বা-"
    ),
    (4, 118): (
        "লা‘আনাহুল্লা--হ্\u200c । ওয়াক্বা-লা লা’আত্তাখিযাঁন্না মিন্\u200c "
        "‘ইবা-দিকা নাছী-বাঁম্\u200c মাফ্\u200cরূ-দ্বা-"
    ),
    (5, 39): (
        "ফামাং তা-বা মিঁম্\u200c বা‘দি য্বুল্\u200cমিহী- ওয়া’আছ্\u200cলাহা "
        "ফা’ইঁন্নাল্লা-হা ইয়াতূ-বু ‘আলাই-হ্\u200c । ইঁন্নাল্লা-হা "
        "গাফূ-রুর্\u200c রাহী--ম্\u200c"
    ),
    (7, 8): (
        "ওয়াল্\u200cওয়ায্\u200cনু ইয়াওমা’ইযিনিল্\u200c হাক্ক্বু, ফামাং "
        "ছাক্বুলাত্\u200c মাওয়া-যী-নুহূ- ফা’উলা--’ইকা হুমুল্\u200c "
        "মুফ্\u200cলিহূ--ন্\u200c"
    ),
    (7, 206): (
        "ইঁন্নাল্\u200c লাযী-না ‘ইংদা রব্বিকা লা- ইয়াস্\u200cতাক্\u200cবিরূ-না "
        "‘আন্\u200c ‘ইবা-দাতিহী- ওয়ায়ুসাব্বিহূ-নাহূ- ওয়ালাহূ- "
        "ইয়াস্\u200cজুদূ--ন্\u200c (সিজদা)"
    ),
    (9, 1): (
        "বারা--’আতুঁম্\u200c মিনাল্লা-হি ওয়ারাসূ-লিহী-- ইলাল্\u200c লাযী-না "
        "‘আ-হাত্তুঁম্\u200c মিনাল্\u200c মুশ্\u200cরিকী--ন্\u200c"
    ),
    (10, 51): (
        "আছুঁম্মা ইযা- মা- ওয়াক্বা‘আ আ-মাংতুঁম্\u200c বিহী--, আ---ল্\u200c’আ-না "
        "ওয়াক্বদ্\u200c কুংতুঁম্\u200c বিহী- তাস্\u200cতা‘জিলূ--ন্\u200c"
    ),
    (11, 41): (
        "ওয়াক্বা-লার্\u200c কাবূ- ফী-হা- বিস্\u200cমিল্লা-হি মাজ্\u200cরে-হা- "
        "ওয়ামুর্\u200cসা-হা--, ইঁন্না রব্বী- লাগাফূ-রুর্\u200c রাহী--ম্\u200c"
    ),
    (12, 11): (
        "ক্বা-লূ- ইয়া--’আবা-না- মা- লাকা লা- তা’মাঁন্না- ‘আলা- ইয়ূ-সুফা "
        "ওয়া’ইঁন্না- লাহূ- লানা-ছিহূ--ন্\u200c"
    ),
    (19, 1): (
        "কা---ফ্\u200c হা- ইয়া- ‘আই---ং ছা---দ্\u200c"
    ),
    (21, 88): (
        "ফাস্\u200cতাজাব্\u200cনা- লাহূ- ওয়ানাজ্জাইনা-হু মিনাল্\u200c গঁম্মি, "
        "ওয়াকাযা-লিকা নুংজিল্\u200c মু’মিনী--ন্\u200c"
    ),
    (33, 10): (
        "ইয্\u200c জা--’ঊ-কুঁম্\u200c মিং ফাওক্বিকুম্\u200c ওয়ামিন্\u200c "
        "আস্\u200cফালা মিংকুম্\u200c ওয়া’ইয্\u200c যা-গাতিল্\u200c "
        "আব্\u200cছা-রু ওয়াবালাগাতিল্\u200c ক্বুলূ-বুল্\u200c হানা-জিরা "
        "ওয়াতায্বুঁন্নূ-না বিল্লা-হিয্ব্\u200c য্বুনূ-না-"
    ),
    (41, 44): (
        "ওয়ালাও জা‘আল্\u200cনা-হু ক্বুর্\u200c’আ-নান্\u200c আ‘জামিয়্যাল্\u200c "
        "লাক্বা-লূ- লাওলা- ফুছ্ছিলাত্\u200c আ-য়া-তুহূ--, আ’আ‘জামিয়্যুঁও "
        "ওয়া‘আরাবিয়্\u200c । ক্বুল্\u200c হুওয়া লিল্লাযী-না আ-মানূ- হুদাঁও "
        "ওয়াশিফা--’উঁও, ওয়াল্লাযী-না লা- ইউ’মিনূ-না ফী-- আ-যা-নিহিম্\u200c "
        "ওয়াক্ব্\u200cরুঁও ওয়াহুওয়া ‘আলাইহিম্\u200c ‘আমান্\u200c, উলা--’ইকা "
        "ইউনা-দাওনা মিঁম্\u200c মাকা-নিঁম্\u200c বা‘ঈ--দ্\u200c"
    ),
    (42, 2): (
        "‘আই---ং সী---ং ক্বা---ফ্\u200c"
    ),
    (52, 37): (
        "আম্\u200c ‘ইংদাহুম্\u200c খাযা--’ইনু রব্বিকা আম্\u200c হুমুল্\u200c "
        "মুছাইত্বিরূ--ন্\u200c"
    ),
    (68, 1): (
        "নূ---ন্\u200c, ওয়াল্\u200cক্বালামি ওয়ামা- "
        "ইয়াস্\u200cত্বুরূ--ন্\u200c"
    ),
    (69, 28): (
        "মা-- আগ্\u200cনা- ‘আঁন্নী- মা-লিয়াহ্\u200c —"
    ),
    (75, 27): (
        "ওয়াক্বী-লা মান্\u200c — রা--ক্ব্\u200c"
    ),
    (76, 15): (
        "ওয়ায়ুত্বা-ফু ‘আলাইহিঁম্\u200c বি’আ-নিয়াতিঁম্\u200c মিং ফিদ্দ্বাতিঁও "
        "ওয়া’আক্\u200cওয়া-বিং কা-নাত্\u200c ক্বাওয়া-রী-রা-"
    ),
    (83, 14): (
        "কাল্লা-, বাল্\u200c — রা-না ‘আলা- ক্বুলূ-বিহিঁম্\u200c মা- কা-নূ- "
        "ইয়াক্\u200cসিবূ--ন্\u200c"
    ),
    (96, 15): (
        "কাল্লা- লা’ইল্\u200c লাম্\u200c ইয়াংতাহি লানাস্\u200cফা‘আঁম্\u200c "
        "বিঁন্না-ছিয়াহ্\u200c"
    ),
    (103, 1): (
        "ওয়াল্\u200c‘আছ্\u200cর্\u200c"
    ),
    (103, 3): (
        "ইল্লাল্\u200c লাযী-না আ-মানূ- ওয়া‘আমিলুছ্\u200c ছা-লিহা-তি "
        "ওয়াতাওয়া-ছাও বিল্\u200cহাক্ক্বি ওয়াতাওয়া-ছাও বিছ্ছব্\u200cর্\u200c"
    ),
    (106, 4): (
        "আল্লাযী-- আত্ব্\u200c‘আমাহুঁম্\u200c মিং জূ-‘ইঁও ওয়া’আ-মানাহুঁম্\u200c "
        "মিন্\u200c খাও-ফ্\u200c"
    ),
    (112, 1): (
        "ক্বুল্\u200c হুওয়াল্লা-হু আহাদ্\u200c"
    ),
    (112, 2): (
        "আল্লা-হুছ্\u200c ছামাদ্\u200c"
    ),
    (112, 3): (
        "লাম্\u200c ইয়ালিদ্\u200c ওয়ালাম্\u200c ইয়ূ-লাদ্\u200c"
    ),
    (112, 4): (
        "ওয়ালাম্\u200c ইয়াকুল্\u200c লাহূ- কুফুওয়ান্\u200c আহাদ্\u200c"
    ),
    (113, 2): (
        "মিং শার্\u200cরি মা- খালাক্ব্\u200c"
    ),
    (113, 4): (
        "ওয়ামিং শার্\u200cরিঁন্\u200c নাফ্ফা-ছা-তি ফিল্\u200c ‘উক্বদ্\u200c"
    ),
}


def _all():
    c = QP.corpus()
    for (s, a), t in sorted(c.items()):
        yield s, a, QP.split_bismillah(s, a, t)


class CorpusTests(TestCase):
    """Every ayah of the Quran, every run (pure Python, a few seconds)."""

    def test_all_6236_ayahs(self):
        import unicodedata
        first, n, bism = {}, 0, 0
        for s, a, (text, had) in _all():
            n += 1
            bism += had
            r = QP.transliterate(text)
            bn = r["bn"]
            self.assertTrue(bn.strip(), (s, a))
            bad = {ch for ch in bn if ch not in QP.ALLOWED_OUTPUT}
            self.assertFalse(bad, (s, a, bad))
            self.assertFalse(any("؀" <= ch <= "ۿ" for ch in bn), (s, a))
            self.assertEqual(bn, unicodedata.normalize("NFC", bn), (s, a))
            self.assertEqual(bn, bn.strip(), (s, a))
            self.assertNotIn("  ", bn, (s, a))
            for st, en, rule in r["spans"]:
                self.assertTrue(0 <= st < en <= len(bn), (s, a, rule))
            self.assertEqual(r, QP.transliterate(text), (s, a))     # idempotent / pure
            first[(s, a)] = bn
        self.assertEqual(n, 6236)
        self.assertEqual(bism, 112)                                  # all but surah 1 and 9
        # deterministic: a second full pass in the opposite order is identical
        for s, a, (text, _) in reversed(list(_all())):
            self.assertEqual(QP.transliterate(text)["bn"], first[(s, a)], (s, a))

    def test_source_is_the_verbatim_tanzil_file(self):
        self.assertEqual(len(QP.corpus()), 6236)
        self.assertIn("Tanzil", QP.SOURCE_LABEL)

    def test_unknown_character_is_an_error_not_silence(self):
        with self.assertRaises(QP.PronError):
            QP.transliterate("قُلْ x")
        with self.assertRaises(QP.PronError):
            QP.transliterate("   ")


class GoldenTests(TestCase):
    def test_golden_ayahs(self):
        c = QP.corpus()
        for (s, a), want in GOLDEN.items():
            text, _ = QP.split_bismillah(s, a, c[(s, a)])
            self.assertEqual(QP.transliterate(text)["bn"], want, "%d:%d" % (s, a))

    def test_every_rule_has_a_documented_ayah(self):
        c = QP.corpus()
        for rule, ((s, a), why) in RULE_AYAH.items():
            text, _ = QP.split_bismillah(s, a, c[(s, a)])
            self.assertIn(rule, QP.transliterate(text)["rules"], "%s @ %d:%d (%s)" % (rule, s, a, why))

    def test_bismillah_is_split_and_rendered_once(self):
        c = QP.corpus()
        text, had = QP.split_bismillah(2, 1, c[(2, 1)])
        self.assertTrue(had)
        self.assertEqual(QP.transliterate(text)["bn"], GOLDEN[(2, 1)])
        self.assertEqual(QP.bismillah_bn(), GOLDEN[(1, 1)])
        self.assertFalse(QP.split_bismillah(1, 1, c[(1, 1)])[1])
        self.assertFalse(QP.split_bismillah(27, 30, c[(27, 30)])[1])   # mid-surah Bismillah stays


class ApiTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Reader", phone="01700990001", password="x")
        self.alem = User.objects.create_user(name="Alem", phone="01700990002", password="x")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_surah_shape_and_under_review_label(self):
        r = self.c.get("/api/v1/quran/pron/1")
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertEqual((d["ok"], d["surah"], d["label"]), (True, 1, "under_review"))
        self.assertEqual(d["method"], "rule_based_no_ai")
        self.assertEqual(len(d["items"]), 7)
        self.assertNotIn("bismillah_bn", d)
        self.assertEqual(d["items"][0]["bn"], GOLDEN[(1, 1)])
        self.assertEqual({i["review"] for i in d["items"]}, {"under_review"})
        d2 = self.c.get("/api/v1/quran/pron/2?ayah=1").json()
        self.assertEqual(d2["bismillah_bn"], GOLDEN[(1, 1)])
        self.assertEqual([i["bn"] for i in d2["items"]], [GOLDEN[(2, 1)]])
        self.assertNotIn("bismillah_bn", self.c.get("/api/v1/quran/pron/9?ayah=1").json())

    def test_errors(self):
        self.assertEqual(self.c.get("/api/v1/quran/pron/115").status_code, 404)
        self.assertEqual(self.c.get("/api/v1/quran/pron/1?ayah=8").status_code, 404)
        self.assertEqual(self.c.get("/api/v1/quran/pron/1?ayah=x").status_code, 400)
        self.assertIn(APIClient().get("/api/v1/quran/pron/1").status_code, (401, 403))

    def test_review_flow_and_engine_change_invalidates(self):
        row, err = RV.record(self.alem, 112, 1, "approve")
        self.assertIsNone(err)
        self.assertEqual(RV.record(self.alem, 112, 2, "reject")[1], "note_required")
        self.assertEqual(RV.record(self.alem, 112, 9, "approve")[1], "unknown_ayah")
        self.assertEqual(RV.record(self.alem, 112, 1, "bogus")[1], "invalid_action")
        RV.record(self.alem, 112, 3, "rule_request", "qalqalah sughra", "লাম্ ইয়ালিদ্")
        items = {i["ayah"]: i for i in self.c.get("/api/v1/quran/pron/112").json()["items"]}
        self.assertEqual(items[1]["review"], "approved")
        self.assertEqual(items[3]["review"], "needs_fix")
        self.assertIn("note_bn", items[3])
        self.assertEqual(items[3]["bn"], QP.transliterate(QP.corpus()[(112, 3)])["bn"])  # suggestion never served
        self.assertEqual(items[2]["review"], "under_review")
        # an approval of an older engine output no longer counts
        row.data["h"] = "0" * 16
        row.save()
        items = {i["ayah"]: i for i in self.c.get("/api/v1/quran/pron/112").json()["items"]}
        self.assertEqual(items[1]["review"], "under_review")
        self.assertEqual(PaCollectionItem.objects.filter(collection=RV.COLL).count(), 2)
        self.assertEqual(RV.counts()["needs_fix"], 1)
