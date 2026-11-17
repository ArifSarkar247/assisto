"""quranpron — deterministic, rule-based Arabic (Uthmani, Hafs) -> Bangla
script pronunciation with tajweed. NO AI anywhere: the same input always
gives the same output, and every rule is a plain, documented function.

Input: one ayah of the Tanzil Quran Text (Uthmani 1.1, CC BY 3.0, stored
verbatim at app/assets/quran/quran-uthmani.txt.gzip — licence in SOURCES.txt and
owner_actions/QURAN_BILINGUAL_SPEC_BN.md). The Arabic text is never changed;
this module only *reads* it.

Bangla convention (also in owner_actions/FEATURE_CARD_QURAN_PRONUNCIATION_BN.md):
  * consonants: ب ব, ت ত, ث ছ, ج জ, ح হ, خ খ, د দ, ذ য, ر র, ز য, س স, ش শ,
    ص ছ, ض দ্ব, ط ত্ব, ظ য্ব, ع ‘ (before a vowel letter), غ গ, ف ফ, ق ক্ব,
    ك ক, ل ল, م ম, ن ন, ه হ, و ওয়, ي ইয়/য়, ء ’ (inside a word), ة ত (হ at a stop).
  * vowels: fatha া, kasra ি, damma ু. After a heavy letter (خ ص ض غ ط ق ظ, a
    heavy ر) a SHORT fatha is the inherent Bangla vowel (no sign: "ক্বুল", "রব্বি").
  * long vowels: া/ী/ূ followed by dashes — one dash per 2 counts (harakah):
      "-" = 2 (madd tabii, badal, silah), "--" = 4 (muttasil, munfasil,
      silah kubra, arid lil-sukun at a stop), "---" = 6 (madd lazim).
  * a vowel-less consonant always shows a visible hasant (্ + ZWNJ): "আল্‌হাম্‌দু".
  * ghunnah (2 counts, nasal): "ঁ" on the vowel before it ("ইঁন্না", "মাঁই ইয়াক্বূলু").
  * ikhfa (hidden noon with ghunnah): "ং" ("মিং শার্‌রি").
  * iqlab: noon becomes "ম্‌" with ghunnah ("মিঁম্‌ বা‘দি").
  * pause marks: ۘ / ۗ -> " ।" (we stop there), ۖ / ۚ -> "," (we continue),
    ۛ -> " ∴", ۜ (sakt) -> " —" (short stop, no breath), ۩ -> " (সিজদা)",
    ۙ and ۞ are not read (nothing shown).
Every rendered piece also carries tajweed rule tags; `transliterate()` returns
them as spans so the app can colour them.
"""
import gzip
import hashlib
import os
import re
import unicodedata
from functools import lru_cache

ENGINE_VERSION = "1.0.0"
SOURCE_LABEL = "Tanzil Quran Text (Uthmani 1.1), Tanzil Project, CC BY 3.0 — tanzil.net"
SOURCE_SHA256 = "7f30c647331a61100ebf24a80507dc0fcdd9f2df97f1312b5b2dfcb982a7f326"

# ---------------------------------------------------------------- characters
FATHA, DAMMA, KASRA = "\u064E", "\u064F", "\u0650"
FATHATAN, DAMMATAN, KASRATAN = "\u064B", "\u064C", "\u064D"
SHADDA, SUKUN, MADDAH, HAMZA_ABOVE = "\u0651", "\u0652", "\u0653", "\u0654"
DAGGER, WASLA, TATWEEL = "\u0670", "ٱ", "\u0640"
SMALL_WAW, SMALL_YEH, SMALL_HIGH_YEH = "\u06E5", "\u06E6", "\u06E7"
SILENT, SILENT_WASL = "\u06DF", "\u06E0"          # rounded zero / rectangular zero
IQLAB_HI, IQLAB_LO, SMALL_NOON = "\u06E2", "\u06ED", "\u06E8"
IMALA, ISHMAM, TASHIL = "\u06EA", "\u06EB", "\u06EC"
LOW_SEEN, HIGH_SEEN = "\u06E3", "\u06DC"

MARKS = {FATHA, DAMMA, KASRA, FATHATAN, DAMMATAN, KASRATAN, SHADDA, SUKUN, MADDAH,
         HAMZA_ABOVE, DAGGER, SMALL_WAW, SMALL_YEH, SMALL_HIGH_YEH, SILENT, SILENT_WASL,
         IQLAB_HI, IQLAB_LO, SMALL_NOON, IMALA, ISHMAM, TASHIL, LOW_SEEN, HIGH_SEEN}
HAMZAS = set("ءأإؤئ")
LETTERS = set("ءآأؤإئابةتثجحخدذرزسشصضطظعغفقكلمنهوىي") | {WASLA, TATWEEL}

# pause marks (stand-alone tokens): kind, do we stop (waqf) there, rendering
PAUSES = {
    "\u06D8": ("waqf_lazim", True, " \u0964"),
    "\u06D7": ("waqf_qala", True, " \u0964"),
    "\u06DC": ("sakt", True, " —"),
    "\u06D6": ("waqf_sila", False, ","),
    "\u06DA": ("waqf_jaiz", False, ","),
    "\u06DB": ("waqf_muanaqa", False, " ∴"),
    "\u06D9": ("waqf_la", False, ""),
    "\u06DE": ("hizb", False, ""),
    "\u06E9": ("sajda", False, " (সিজদা)"),
}

PAUSE_KINDS = {v[0] for v in PAUSES.values()}
H = "\u09CD"             # Bangla hasant
ZWNJ = "\u200C"
CODA = H + ZWNJ          # visible hasant

CONS = {
    "ب": "ব", "ت": "ত", "ة": "ত", "ث": "ছ", "ج": "জ", "ح": "হ", "خ": "খ", "د": "দ",
    "ذ": "য", "ر": "র", "ز": "য", "س": "স", "ش": "শ", "ص": "ছ", "ض": "দ্ব",
    "ط": "ত্ব", "ظ": "য্ব", "غ": "গ", "ف": "ফ", "ق": "ক্ব", "ك": "ক", "ل": "ল",
    "م": "ম", "ن": "ন", "ه": "হ",
}
HEAVY = set("خصضغطقظ")
QALQALA = set("قطبجد")
THROAT = set("ءهعحغخ")
IDGHAM_GHUNNA = set("ينمو")
IDGHAM_NO_GHUNNA = set("لر")
ISTILA = set("خصضغطقظ")
VOWEL_LETTER = {("a", 1): "আ", ("i", 1): "ই", ("u", 1): "উ", ("e", 1): "এ",
                ("a", 2): "আ", ("i", 2): "ঈ", ("u", 2): "ঊ", ("e", 2): "এ"}
VOWEL_SIGN = {("a", 1): "া", ("i", 1): "ি", ("u", 1): "ু", ("e", 1): "ে",
              ("a", 2): "া", ("i", 2): "ী", ("u", 2): "ূ", ("e", 2): "ে"}

# Disconnected letters (al-huruf al-muqatta'at): spelled letter names, Hafs.
# madd lazim = 6 counts ("---"); idgham of meem into meem keeps the ghunnah.
MUQATTAAT = {
    "الٓمٓ": "আলিফ" + CODA + " লাঁ---ম" + H + "মী---ম" + CODA,
    "الٓمٓصٓ": "আলিফ" + CODA + " লাঁ---ম" + H + "মী---ম" + CODA + " ছা---দ" + CODA,
    "الٓر": "আলিফ" + CODA + " লা---ম" + CODA + " রা-",
    "الٓمٓر": "আলিফ" + CODA + " লাঁ---ম" + H + "মী---ম" + CODA + " রা-",
    "كٓهيعٓصٓ": "কা---ফ" + CODA + " হা- ইয়া- ‘আই---ং ছা---দ" + CODA,
    "طه": "ত্বা- হা-",
    "طسٓمٓ": "ত্বা- সীঁ---ম" + H + "মী---ম" + CODA,
    "طسٓ": "ত্বা- সী---ন" + CODA,
    "يسٓ": "ইয়া- সী---ন" + CODA,
    "صٓ": "ছা---দ" + CODA,
    "حمٓ": "হা- মী---ম" + CODA,
    "عٓسٓقٓ": "‘আই---ং সী---ং ক্বা---ফ" + CODA,
    "قٓ": "ক্বা---ফ" + CODA,
    "نٓ": "নূ---ন" + CODA,
}



def canon(word):
    """Order-independent form of an Arabic word: each letter followed by its
    marks in code-point order (the input is never Unicode-normalised: NFC
    would merge alif + maddah into U+0622 and change the letters)."""
    out, cur = [], ""
    for ch in word:
        if ch in MARKS and cur:
            cur += ch
        else:
            if cur:
                out.append(cur[0] + "".join(sorted(cur[1:])))
            cur = ch
    if cur:
        out.append(cur[0] + "".join(sorted(cur[1:])))
    return "".join(out)


MUQATTAAT = {canon(k): v for k, v in MUQATTAAT.items()}
# exactly as Tanzil writes it (1:1)
BISMILLAH = ("\u0628\u0650\u0633\u0652\u0645\u0650 \u0671\u0644\u0644\u0651\u064e\u0647\u0650 "
             "\u0671\u0644\u0631\u0651\u064e\u062d\u0652\u0645\u064e\u0640\u0670\u0646\u0650 "
             "\u0671\u0644\u0631\u0651\u064e\u062d\u0650\u064a\u0645\u0650")
_BISMILLAH_WORDS = [canon(w) for w in BISMILLAH.split()]
_ALLAH_RE = re.compile("^[وفبتأءا]*" + WASLA + "?لله(?:م)?$")
# nouns whose hamzat al-wasl starts with kasra even before a damma
_WASL_I_NOUNS = ("ٱبن", "ٱمر", "ٱثن", "ٱسم")

# every Bangla character the engine may output (tests check against this)
ALLOWED_OUTPUT = set("অআইঈউঊএওকখগঙচছজঝটঠডঢণতথদধনপফবভমযরলশষসহড়ঢ়য়ৎংঃঁ"
                     "ািীুূেৈোৌ্\u09BC") | {ZWNJ, " ", "-", "’", "‘", ",", "।", "∴", "—", "(", ")"}


class PronError(ValueError):
    """Unknown character or malformed input — never silently ignored."""


# ------------------------------------------------------------------ parsing
class _Lt:
    __slots__ = ("b", "m")

    def __init__(self, b):
        self.b, self.m = b, set()


def _letters(word):
    out = []
    for ch in word:
        if ch in LETTERS:
            out.append(_Lt(ch))
        elif ch in MARKS:
            if not out:
                raise PronError("mark without a letter: U+%04X" % ord(ch))
            out[-1].m.add(ch)
        else:
            raise PronError("unmapped character U+%04X in %r" % (ord(ch), word))
    # tatweel: carrier of a hamza / small noon, or of marks that belong to the
    # letter before it (dagger alif, maddah, small yeh)
    res = []
    for lt in out:
        if lt.b == TATWEEL:
            if HAMZA_ABOVE in lt.m:
                lt.b = "ء"
                lt.m.discard(HAMZA_ABOVE)
                res.append(lt)
            elif SMALL_NOON in lt.m:
                lt.b = "ن"
                lt.m.discard(SMALL_NOON)
                res.append(lt)
            elif lt.m:
                if not res:
                    raise PronError("tatweel marks without a letter in %r" % word)
                res[-1].m |= lt.m
            continue
        if HAMZA_ABOVE in lt.m:          # hamza written above a seat
            lt.m.discard(HAMZA_ABOVE)
            lt.b = "ء"
        res.append(lt)
    return res


def _P(_k, **kw):
    d = {"k": _k, "tags": set(), "silent": False}
    d.update(kw)
    return d


def _vowel_of(m):
    for mk, q, tan in ((FATHA, "a", False), (KASRA, "i", False), (DAMMA, "u", False),
                       (FATHATAN, "a", True), (KASRATAN, "i", True), (DAMMATAN, "u", True)):
        if mk in m:
            return q, tan
    return None, False


def _word_phonemes(word, w):
    """One orthographic word -> list of phonemes (C consonant, V vowel,
    W hamzat-al-wasl placeholder, X 'pronounced only at a stop' alif)."""
    lts = _letters(word)
    ph = []
    skel = "".join(lt.b for lt in lts)

    def last_v():
        return ph[-1] if ph and ph[-1]["k"] == "V" else None

    def last_is_tanween():
        return bool(ph) and ph[-1]["k"] == "C" and ph[-1].get("tanween")

    for i, lt in enumerate(lts):
        b, m = lt.b, lt.m
        if SILENT in m:
            continue
        if b == WASLA:
            ph.append(_P("W", w=w))
            continue
        q, tan = _vowel_of(m)
        if IMALA in m and not q:
            q = "a"
        if b == "ا":
            if TASHIL in m:
                ph.append(_P("C", ch="ء", w=w, gem=False, tags={"tashil"}))
                ph.append(_P("V", q="a", n=1, w=w))
                continue
            if SILENT_WASL in m:
                ph.append(_P("X", w=w))
                continue
            v = last_v()
            if q:                                    # alif carrying a vowel = hamza
                ph.append(_P("C", ch="ء", w=w, gem=False))
                ph.append(_P("V", q=q, n=1, w=w))
                continue
            if v is not None and v["q"] in ("a", "e") and not last_is_tanween():
                v["n"] = 2
                if MADDAH in m:
                    v["maddah"] = True
            elif i == 0 and MADDAH in m:             # word-initial "آ"-style
                ph.append(_P("C", ch="ء", w=w, gem=False))
                ph.append(_P("V", q="a", n=2, w=w, maddah=True))
            continue                                  # otherwise a silent alif
        if b in "ىوي" and not q and SHADDA not in m and SUKUN not in m:
            v = last_v()
            if last_is_tanween():                     # هُدًى : seat of the tanween
                continue
            if DAGGER in m:
                if v is not None:
                    v["n"] = 2
                    v["maddah"] = v.get("maddah") or MADDAH in m
                else:
                    ph.append(_P("V", q="a", n=2, w=w, maddah=MADDAH in m))
                continue
            if v is not None and ((b in "ىي" and v["q"] == "i") or (b == "و" and v["q"] == "u")
                                  or (b == "ى" and v["q"] in ("a", "e"))):
                v["n"] = 2
                if MADDAH in m:
                    v["maddah"] = True
                continue
            ch = "ي" if b in "ىي" else "و"
            ph.append(_P("C", ch=ch, w=w, gem=False, sakin=True))
            continue
        # ------------------------------------------------- a real consonant
        if b in HAMZAS:
            ch = "ء"
        elif b == "ى":
            ch = "ي"
        elif b == "ص" and HIGH_SEEN in m:
            ch = "س"                                  # يَبْصُۜطُ / بَصْۜطَةً read with seen
        else:
            ch = b
        c = _P("C", ch=ch, w=w, gem=SHADDA in m, sukun=SUKUN in m, src=i)
        if ch == "ة":
            c["tm"] = True
        if ISHMAM in m:
            c["tags"].add("ishmam")
        if IQLAB_HI in m or IQLAB_LO in m:
            c["iqlab_mark"] = True
        if ch == "ل" and i > 0 and lts[i - 1].b == WASLA:
            c["article"] = True
        if (ch == "ل" and i == 1 and lts[0].b == "ل" and KASRA in lts[0].m
                and not _ALLAH_RE.match(skel)):
            c["article"] = True                       # لِلْ = li + al-
        ph.append(c)
        if q:
            v = _P("V", q=q, n=1, w=w)
            if IMALA in m:
                v["q"] = "e"
                v["tags"].add("imala")
            ph.append(v)
            if tan:
                ph.append(_P("C", ch="ن", w=w, gem=False, tanween=True, sakin=True))
        else:
            c["sakin"] = True
            if not c["sukun"] and not c["gem"]:
                c["unmarked"] = True
        if DAGGER in m:
            v = last_v()
            if v is not None:
                v["n"] = 2
            else:
                ph.append(_P("V", q="a", n=2, w=w))
            if MADDAH in m:
                ph[-1]["maddah"] = True
        if SMALL_WAW in m or SMALL_YEH in m or SMALL_HIGH_YEH in m:
            v = last_v()
            if v is not None:
                v["n"] = 2
                if ch == "ه":
                    v["silah"] = True
                if MADDAH in m:
                    v["maddah"] = True
    if _ALLAH_RE.match(skel):                         # lafz al-jalala: implied long ā
        for j, p in enumerate(ph):
            if p["k"] == "C" and p["ch"] == "ل" and p["gem"]:
                p["jalala"] = True
                if j + 1 < len(ph) and ph[j + 1]["k"] == "V" and ph[j + 1]["q"] == "a":
                    ph[j + 1]["n"] = 2
                break
    return ph, skel


# ------------------------------------------------------------- the pipeline
def _tokens(text):
    toks = []
    for tok in text.split():
        if tok in PAUSES:
            kind, stop, out = PAUSES[tok]
            toks.append(("P", kind, stop, out))
        elif canon(tok) in MUQATTAAT:
            toks.append(("M", canon(tok)))
        else:
            toks.append(("W", tok))
    return toks


def _is_sound(p):
    return p["k"] in ("C", "V") and not p["silent"]


def _next(seq, i):
    """Index of the next pronounced phoneme after i, or None at a stop."""
    j = i + 1
    while j < len(seq):
        p = seq[j]
        if p["k"] == "P":
            if p["stop"]:
                return None
        elif p["k"] == "M":
            return None
        elif _is_sound(p):
            return j
        j += 1
    return None


def _prev(seq, i):
    j = i - 1
    while j >= 0:
        p = seq[j]
        if p["k"] == "P":
            if p["stop"]:
                return None
        elif p["k"] == "M":
            return None
        elif _is_sound(p):
            return j
        j -= 1
    return None


def _apply_waqf(seq, end, tag="waqf"):
    """Stop (waqf) on the word that ends at seq[end] (inclusive)."""
    idx = [k for k in range(end + 1) if seq[k]["k"] in ("C", "V", "X") and not seq[k]["silent"]]
    if not idx:
        return
    w = seq[idx[-1]]["w"]
    idx = [k for k in idx if seq[k]["w"] == w]
    last = idx[-1]
    p = seq[last]
    if p["k"] == "X":                                 # أَنَا۠ : alif read at a stop
        p["silent"] = True
        pv = _prev(seq, last)
        if pv is not None and seq[pv]["k"] == "V":
            seq[pv]["n"] = 2
            seq[pv]["tags"].add("waqf")
        return
    if p["k"] == "C" and p.get("tanween"):
        v = seq[last - 1]
        cons = seq[last - 2] if last >= 2 else None
        p["silent"] = True
        if v["q"] == "a" and not (cons and cons.get("tm")):
            v["n"] = 2
            v["tags"].add("madd_iwad")
            return
        v["silent"] = True
        last = last - 2
    elif p["k"] == "V":
        if p["n"] >= 2 and not p.get("silah"):
            p["tags"].add(tag)
            return                                    # a long vowel stays
        p["silent"] = True
        last = last - 1
    c = seq[last]
    if c["k"] != "C":
        return
    c["sakin"] = True
    c["waqf"] = True
    c["tags"].add(tag)
    pv = _prev(seq, last)
    if pv is None:
        return
    before = seq[pv]
    if before["k"] == "V" and before["n"] >= 2 and not before.get("maddah"):
        before["n"] = 4
        before["tags"].add("madd_arid")
    elif (before["k"] == "C" and before["ch"] in "يو" and before.get("sakin")):
        b2 = _prev(seq, pv)
        if b2 is not None and seq[b2]["k"] == "V" and seq[b2]["q"] == "a":
            before["tags"].add("madd_leen")
            before["leen"] = True


def _build(text):
    seq = []
    toks = _tokens(text)
    w = 0
    for t in toks:
        if t[0] == "P":
            seq.append(_P("P", kind=t[1], stop=t[2], out=t[3], w=None))
        elif t[0] == "M":
            seq.append(_P("M", text=t[1], w=w))
            w += 1
        else:
            ph, skel = _word_phonemes(t[1], w)
            for p in ph:
                p["skel"] = skel
            seq.extend(ph)
            w += 1
    # stops inside the ayah (lazim / qala / sakt) and at its end
    for i, p in enumerate(seq):
        if p["k"] == "P" and p["stop"]:
            _apply_waqf(seq, i - 1, "sakt" if p["kind"] == "sakt" else "waqf")
    last = max((i for i, p in enumerate(seq) if p["k"] in ("C", "V", "X")), default=None)
    if last is not None and not seq[-1]["k"] == "M":
        _apply_waqf(seq, last)
    for i, p in enumerate(seq):
        if p["k"] == "X" and not p["silent"]:
            p["silent"] = True                        # alif not read in wasl
    _resolve_wasl(seq)
    seq = [p for p in seq if p["k"] in ("P", "M") or not p["silent"]]
    _tajweed(seq)
    return seq


def _resolve_wasl(seq):
    i = 0
    while i < len(seq):
        p = seq[i]
        if p["k"] != "W":
            i += 1
            continue
        pv = _prev(seq, i)
        if pv is None:                                # start / after a stop: ibtida
            skel = p["skel"]
            rest = [x for x in seq[i + 1:] if x["k"] in ("C", "V") and x["w"] == p["w"]]
            if len(rest) > 0 and rest[0]["k"] == "C" and rest[0]["ch"] == "ل" and rest[0].get("article"):
                q = "a"
            elif any(skel.lstrip("وفبتأ").startswith(n) for n in _WASL_I_NOUNS):
                q = "i"
            else:
                q = "i"
                cons = [k for k, x in enumerate(rest) if x["k"] == "C"]
                if len(cons) >= 2 and cons[1] + 1 < len(rest) and rest[cons[1] + 1]["k"] == "V" \
                        and rest[cons[1] + 1]["q"] == "u":
                    q = "u"
            seq[i] = _P("V", q=q, n=1, w=p["w"], wasl_start=True, skel=p["skel"],
                        tags={"hamzat_wasl"})
        else:
            p["silent"] = True
            prev = seq[pv]
            if prev["k"] == "V" and prev["n"] >= 2:
                prev["n"] = 1                         # long vowel meets a sakin
                prev["shortened"] = True
            elif prev["k"] == "C" and prev.get("sakin"):
                seq.insert(pv + 1, _P("V", q="i", n=1, w=prev["w"], tags={"tanween_kasra"}
                                      if prev.get("tanween") else set()))
                prev["sakin"] = False
                i += 1
        i += 1


def _consonant_is_sakin(seq, i):
    j = i + 1
    return not (j < len(seq) and seq[j]["k"] == "V")


def _tajweed(seq):
    n = len(seq)
    for i in range(n):
        p = seq[i]
        if p["k"] != "C" or p["silent"]:
            continue
        if p["gem"] and _prev(seq, i) is None:
            p["gem"] = False                          # مَّن at the start: nothing to merge with
        sakin = _consonant_is_sakin(seq, i) and not p["gem"]
        nx = _next(seq, i)
        nxt = seq[nx] if nx is not None else None
        ch = p["ch"]
        # --- noon sakin & tanween
        if ch == "ن" and sakin and nxt is not None and nxt["k"] == "C":
            L = nxt["ch"]
            same_word = nxt["w"] == p["w"] and not p.get("tanween")
            if L in THROAT:
                p["tags"].add("izhar")
            elif L == "ب":
                p["iqlab"] = True
                p["tags"].add("iqlab")
                _nasal_before(seq, i)
            elif L in IDGHAM_GHUNNA:
                if same_word:
                    p["tags"].add("izhar")            # دُنْيَا, صِنْوَانٌ : izhar mutlaq
                else:
                    p["silent"] = True
                    nxt["gem"] = True
                    nxt["xgem"] = True
                    nxt["tags"].add("idgham_ghunnah")
                    _nasal_before(seq, i)
            elif L in IDGHAM_NO_GHUNNA:
                p["silent"] = True
                nxt["gem"] = True
                nxt["xgem"] = True
                nxt["tags"].add("idgham_no_ghunnah")
            else:
                p["ikhfa"] = True
                p["tags"].add("ikhfa")
            continue
        # --- meem sakin
        if ch == "م" and sakin and nxt is not None and nxt["k"] == "C" and not p.get("waqf"):
            if nxt["ch"] == "م":
                p["silent"] = True
                nxt["gem"] = True
                nxt["xgem"] = True
                nxt["tags"].add("idgham_shafawi")
            elif nxt["ch"] == "ب":
                p["tags"].add("ikhfa_shafawi")
                _nasal_before(seq, i)
            else:
                p["tags"].add("izhar_shafawi")
            continue
        # --- assimilation marked in the mushaf (letter without sukun before a shadda)
        if p.get("unmarked") and nxt is not None and nxt["k"] == "C" and nxt["gem"]:
            p["silent"] = True
            if p.get("article"):
                if not nxt.get("jalala"):
                    nxt["tags"].add("lam_shamsiyya")
            else:
                nxt["tags"].add("idgham")
            continue
        if p.get("article") and sakin:
            p["tags"].add("lam_qamariyya")
        if ch in QALQALA and sakin:
            p["tags"].add("qalqalah_kubra" if p.get("waqf") else "qalqalah")
    # second pass: ghunnah, ra, lam of Allah, heavy vowels, madd
    for i in range(n):
        p = seq[i]
        if p["silent"] or p["k"] != "C":
            continue
        if p["ch"] in "نم" and p["gem"]:
            p["tags"].add("ghunnah")
            _nasal_before(seq, i)
        if p["ch"] == "ر":
            heavy = _ra_heavy(seq, i)
            p["heavy"] = heavy
            p["tags"].add("ra_tafkhim" if heavy else "ra_tarqiq")
        elif p.get("jalala"):
            pv = _prev(seq, i)
            heavy = True
            if pv is not None and seq[pv]["k"] == "V":
                heavy = seq[pv]["q"] in ("a", "u")
            p["heavy"] = heavy
            p["tags"].add("lam_jalala_tafkhim" if heavy else "lam_jalala_tarqiq")
        elif p["ch"] in HEAVY:
            p["heavy"] = True
    for i in range(n):
        p = seq[i]
        if p["silent"] or p["k"] != "V" or p["n"] < 2 or "madd_arid" in p["tags"]:
            continue
        _classify_madd(seq, i)


def _nasal_before(seq, i):
    pv = _prev(seq, i)
    if pv is not None and seq[pv]["k"] == "V":
        seq[pv]["nasal"] = True


def _ra_heavy(seq, i):
    j = i + 1
    if j < len(seq) and seq[j]["k"] == "V" and not seq[j]["silent"]:
        return seq[j]["q"] in ("a", "u")
    # ra sakin: look back
    pv = _prev(seq, i)
    if pv is None:
        return True
    b = seq[pv]
    if b["k"] == "C":
        if b["ch"] == "ي" and b.get("sakin"):
            return False                              # خَيْرْ
        pv = _prev(seq, pv)
        if pv is None:
            return True
        b = seq[pv]
    if b["k"] == "V" and b["q"] in ("i", "e") and not b.get("wasl_start"):
        nx = _next(seq, i)
        if nx is not None and seq[nx]["k"] == "C" and seq[nx]["w"] == seq[i]["w"] \
                and seq[nx]["ch"] in ISTILA:
            return True                               # قِرْطَاسٍ, مِرْصَادًا
        return False
    return True


def _classify_madd(seq, i):
    v = seq[i]
    nx = _next(seq, i)
    nxt = seq[nx] if nx is not None else None
    pv = _prev(seq, i)
    after_hamza = pv is not None and seq[pv]["k"] == "C" and seq[pv]["ch"] == "ء"
    if nxt is not None and nxt["k"] == "C" and nxt["w"] == v["w"]:
        nsak = _consonant_is_sakin(seq, nx)
        if nxt["ch"] == "ء" and not nxt.get("xgem"):
            v["n"], tag = 4, "madd_muttasil"
        elif (nsak or nxt["gem"]) and not nxt.get("xgem"):
            v["n"], tag = 6, "madd_lazim"
        else:
            tag = "madd_badal" if after_hamza else "madd_tabii"
    elif nxt is not None and nxt["k"] == "C" and nxt["ch"] == "ء" and nxt["w"] != v["w"]:
        v["n"] = 4
        tag = "madd_silah_kubra" if v.get("silah") else "madd_munfasil"
    elif v.get("silah"):
        tag = "madd_silah_sughra"
    elif after_hamza:
        tag = "madd_badal"
    else:
        tag = "madd_tabii"
    v["tags"].add(tag)


# ----------------------------------------------------------------- rendering
def _vowel_text(v, onset_heavy, independent):
    q, n = v["q"], v["n"]
    key = (q, 1 if n < 2 else 2)
    if independent:
        s = VOWEL_LETTER[key]
    elif q == "a" and n < 2 and onset_heavy:
        s = ""                                        # heavy short fatha: inherent vowel
    else:
        s = VOWEL_SIGN[key]
    if v.get("nasal"):
        s += "ঁ"
    if n >= 2:
        s += "-" * (n // 2)
    return s


def _coda_text(c, nxt_same_gem):
    ch = c["ch"]
    if c.get("ikhfa"):
        return "ং"
    if c.get("iqlab"):
        return "ম" + CODA
    if ch == "ي":
        if c.get("waqf") and c["gem"]:
            return "য়" + CODA                        # عَرَبِىٌّ at a stop
        return "ই" + ("-" if c.get("leen") else "")
    if ch == "و":
        return "ও" + ("-" if c.get("leen") else "")
    if ch == "ء":
        return "’"
    if ch == "ع":
        return "‘"
    if ch == "ة":
        return "হ" + CODA if c.get("waqf") else "ত" + CODA
    base = CONS[ch]
    if nxt_same_gem and len(base) == 1 and ch != "ر":
        return base + H                               # conjunct: ব্ব, ল্ল, ন্ন
    if nxt_same_gem and ch == "ر":
        return base + CODA                            # র্‌র, never a reph
    if nxt_same_gem:
        return base[0] + H
    return base + CODA


def _closed(seq, vi):
    """True when the syllable of the vowel at vi is closed by a consonant
    written right after it — only then can a heavy short fatha be the inherent
    Bangla vowel ("রব্বি"); at the end of a word it needs "া" ("হানা-জিরা")."""
    j = vi + 1
    while j < len(seq) and seq[j]["k"] in ("C", "V") and seq[j]["silent"]:
        j += 1
    if j >= len(seq) or seq[j]["k"] != "C":
        return False
    c = seq[j]
    if c["ch"] in "يو" and not c["gem"]:
        return False                                  # diphthong: خَوْفٍ -> "খাও-ফ্‌"
    return bool(c["gem"]) or not (j + 1 < len(seq) and seq[j + 1]["k"] == "V")


def _onset_text(c, v, ctx, closed=True):
    """ctx: 'start' (after a space / at the start), 'vowel', 'coda'."""
    ch = c["ch"]
    heavy = bool(c.get("heavy"))
    if ch == "ء":
        pre = "" if ctx == "start" else "’"
        return pre + _vowel_text(v, False, True)
    if ch == "ع":
        return "‘" + _vowel_text(v, False, True)
    if ch == "ي":
        if c.get("gem_in_word"):
            return "য়্য" + _vowel_text(v, False, False)
        if v["q"] == "u" and v["n"] < 2:
            core = "ইউ" if ctx != "vowel" else "য়ু"
            return core + ("ঁ" if v.get("nasal") else "")
        return ("য়" if ctx == "vowel" else "ইয়") + _vowel_text(v, False, False)
    if ch == "و":
        if c.get("gem_in_word"):
            return "ওয়" + CODA + "ওয়" + _vowel_text(v, False, False)
        return "ওয়" + _vowel_text(v, False, False)
    base = CONS[ch]
    return base + _vowel_text(v, heavy and closed, False)


def render(seq):
    """Phoneme sequence -> (bangla text, spans [[start, end, rule], ...])."""
    pieces = []                                       # (text, tags)
    cur_w = None
    ctx = "start"

    def put(text, tags=()):
        if text:
            pieces.append((text, set(tags)))

    def put_coda(text, tags=()):
        """A closing consonant belongs to the syllable before any pause mark:
        غِشَـٰوَةٌ ۖ وَلَهُمْ -> "গিশা-ওয়াতুঁও, ওয়ালাহুম্"."""
        if not text:
            return
        k = len(pieces)
        while k > 0 and pieces[k - 1][1] & PAUSE_KINDS and pieces[k - 1][0] != " ":
            k -= 1
        pieces.insert(k, (text, set(tags)))

    def space():
        nonlocal ctx
        if pieces and not pieces[-1][0].endswith(" "):
            pieces.append((" ", set()))
        ctx = "start"

    n = len(seq)
    i = 0
    while i < n:
        p = seq[i]
        if p["k"] == "P":
            if p["out"]:
                put(p["out"], {p["kind"]})
            ctx = "start" if p["out"] else ctx
            i += 1
            continue
        if p["k"] == "M":
            space()
            put(MUQATTAAT[p["text"]], {"muqattaat", "madd_lazim"})
            cur_w = p["w"]
            ctx = "coda"
            i += 1
            continue
        if p["k"] == "V":                             # vowel with no consonant (hamzat al-wasl)
            if p["w"] != cur_w:
                space()
                cur_w = p["w"]
            put(_vowel_text(p, False, True), p["tags"])
            ctx = "vowel"
            i += 1
            continue
        # consonant
        c = p
        if c["silent"]:
            i += 1
            continue
        has_v = i + 1 < n and seq[i + 1]["k"] == "V"
        if c["gem"] and has_v:
            # first half closes the previous syllable
            same_word = c.get("xgem") is None and cur_w == c["w"]
            if c["ch"] in "يو" and same_word and has_v:
                c["gem_in_word"] = True
            elif c["ch"] == "ل" and c.get("jalala") and has_v:
                put_coda(_coda_text(c, True), c["tags"])   # بِسْمِ ٱللَّهِ -> বিসমিল্লা-হি
                cur_w = c["w"]
                ctx = "coda"
            else:
                put_coda(_coda_text(c, same_word), c["tags"])
                ctx = "coda"
        if has_v:
            v = seq[i + 1]
            if c["w"] != cur_w:
                space()
                cur_w = c["w"]
            put(_onset_text(c, v, ctx, _closed(seq, i + 1)), c["tags"] | v["tags"])
            ctx = "vowel"
            i += 2
            continue
        put_coda(_coda_text(c, False), c["tags"])
        ctx = "coda"
        i += 1
    text = "".join(t for t, _ in pieces)
    spans = []
    pos = 0
    open_ = {}
    for t, tags in pieces:
        end = pos + len(t)
        for tag in list(open_):
            if tag not in tags:
                spans.append([open_.pop(tag), pos, tag])
        for tag in tags:
            if tag not in open_:
                open_[tag] = pos
        pos = end
    for tag, st in open_.items():
        spans.append([st, pos, tag])
    # trim surrounding spaces
    lead = len(text) - len(text.lstrip(" "))
    text = text.strip(" ")
    out = []
    for st, en, tag in spans:
        st, en = max(0, st - lead), min(len(text), en - lead)
        if en > st:
            out.append([st, en, tag])
    out.sort(key=lambda s: (s[0], s[1], s[2]))
    return text, out


# ----------------------------------------------------------------- public API
def split_bismillah(surah, ayah, text):
    """Tanzil prefixes the Bismillah to ayah 1 of every surah except 1 and 9;
    returns (text_without_it, had_it)."""
    if ayah == 1 and surah not in (1, 9):
        words = text.split()
        head = [canon(w) for w in words[:4]]
        head[:1] = [h.replace(SHADDA, "", 1) if i == 0 else h for i, h in enumerate(head[:1])]
        if head == _BISMILLAH_WORDS:                  # also "بِّسْمِ" (shadda on ba)
            return " ".join(words[4:]), True
    return text, False


def transliterate(text):
    """Arabic ayah (Uthmani) -> {"bn": str, "spans": [[s, e, rule]], "rules": [..]}.
    Pure and deterministic. Raises PronError on any unknown character."""
    text = text.strip().replace("\u0622", "\u0627" + MADDAH)
    if not text:
        raise PronError("empty ayah")
    seq = _build(text)
    bn, spans = render(seq)
    bn = unicodedata.normalize("NFC", bn)
    if not bn:
        raise PronError("empty output")
    return {"bn": bn, "spans": spans, "rules": sorted({s[2] for s in spans})}


def output_hash(bn):
    return hashlib.sha256(bn.encode("utf-8")).hexdigest()[:16]


def _text_path():
    from django.conf import settings
    p = getattr(settings, "QURAN_UTHMANI_PATH", "")
    if p:
        return p
    return os.path.join(os.path.dirname(str(settings.BASE_DIR)), "app", "assets", "quran",
                        "quran-uthmani.txt.gzip")


@lru_cache(maxsize=1)
def corpus():
    """{(surah, ayah): arabic} from the verbatim Tanzil file (sha256 checked)."""
    with gzip.open(_text_path(), "rb") as fh:
        raw = fh.read()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise PronError("Tanzil Uthmani file changed — refusing to read a modified Quran text")
    out = {}
    for line in raw.decode("utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        s, a, t = line.split("|", 2)
        out[(int(s), int(a))] = t
    return out


@lru_cache(maxsize=1)
def bismillah_bn():
    return transliterate(BISMILLAH)["bn"]


@lru_cache(maxsize=120)
def surah_items(surah):
    """[(ayah, arabic, result)] for one surah (cached per process)."""
    c = corpus()
    out = []
    a = 1
    while (surah, a) in c:
        ar, _ = split_bismillah(surah, a, c[(surah, a)])
        out.append((a, ar, transliterate(ar)))
        a += 1
    return tuple(out)


def has_bismillah(surah):
    return surah not in (1, 9)
