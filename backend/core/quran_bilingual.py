"""quranview (owner order 9 Nov 21:55, lane 14): bilingual ayah view sources.

Spec + licence table: owner_actions/QURAN_BILINGUAL_SPEC_BN.md.

HARD RULES (never break):
  * Translation / tafsir / footnote text is the publisher's text VERBATIM.
    Nothing here generates, summarises, paraphrases or translates Quran
    meaning — no AI is called anywhere in this module.
  * Shane nuzul = a WHOLE footnote / tafsir unit of a licensed source that
    itself states the reason of revelation (keyword rule `keyword_v1`), shown
    verbatim; otherwise the app shows "this source has no shane nuzul".
  * Quran Foundation (QF) content is cached at most QF_MAX_AGE (6 days < the
    7-day limit in QF's developer terms), never bundled, never used for
    training or embeddings. The QF client secret lives only in the encrypted
    Owner Admin integration `quran_foundation`.
  * No quranicaudio.com / EveryAyah files, ever.

Sources (verified 9 Nov 2026 on each publisher's own page):
  * QuranEnc.com — bengali_zakaria, english_saheeh, bengali_mokhtasar: may be
    re-published unmodified, naming publisher + source + version, kept at the
    latest version, no inappropriate ads.
  * Quran Foundation Content API v4 — word-by-word (bn + en), transliteration
    (resource 57 + per word), per-ayah audio + reciter list.
"""
import re
import time

from django.core.cache import cache

QE_BASE = "https://quranenc.com/api/v1"
QE_SOURCE = "QuranEnc.com"
QE_SOURCE_URL = "https://quranenc.com"

# key -> what we show. title/publisher strings are the publisher's own names.
QE_BOOKS = {
    "bengali_zakaria": {
        "lang": "bn", "role": "meaning",
        "title_bn": "বাংলা অনুবাদ — আবু বকর মুহাম্মাদ যাকারিয়া",
        "title_en": "Bengali Translation — Abu Bakr Zakaria",
        "publisher": "Encyclopedia of the Noble Quran",
    },
    "english_saheeh": {
        "lang": "en", "role": "meaning",
        "title_bn": "ইংরেজি অনুবাদ — Saheeh International",
        "title_en": "English Translation — Saheeh International",
        "publisher": "Noor International Center",
    },
    "bengali_mokhtasar": {
        "lang": "bn", "role": "tafsir",
        "title_bn": "আল-মুখতাসার ফী তাফসীরিল কুরআন (বাংলা)",
        "title_en": "Al-Mukhtasar in Interpreting the Noble Quran (Bengali)",
        "publisher": "Tafsir Center for Quranic Studies",
    },
}

QE_TTL = 24 * 3600          # re-check the publisher's version daily
QF_MAX_AGE = 6 * 24 * 3600  # < 7 days (QF developer terms, section 3)

QF_SLUG = "quran_foundation"
QF_API = {"production": "https://apis.quran.foundation/content/api/v4",
          "prelive": "https://apis-prelive.quran.foundation/content/api/v4"}
QF_OAUTH = {"production": "https://oauth2.quran.foundation/oauth2/token",
            "prelive": "https://prelive-oauth2.quran.foundation/oauth2/token"}
QF_SCOPE = "content.quran.read content.audio.read content.translations.read"
QF_AUDIO_BASE = "https://verses.quran.foundation/"
QF_TRANSLIT_ID = 57
QF_DEFAULT_RECITER = 7  # Mishari Rashid al-Afasy (QF ayah-by-ayah recitation id)

# Never use these hosts for audio (no commercial licence).
BANNED_AUDIO_HOSTS = ("quranicaudio.com", "everyayah.com")

# Ayah counts (Tanzil metadata) — validates surah:ayah without a DB.
AYAH_COUNTS = (
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128,
    111, 110, 98, 135, 112, 78, 118, 64, 77, 227, 93, 88, 69, 60, 34, 30, 73,
    54, 45, 83, 182, 88, 75, 85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60,
    49, 62, 55, 78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30, 52, 52,
    44, 28, 28, 20, 56, 40, 31, 50, 40, 46, 42, 29, 19, 36, 25, 22, 17, 19,
    26, 30, 20, 15, 21, 11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3,
    6, 3, 5, 4, 5, 6)


class SourceError(Exception):
    pass


def valid_ref(surah, ayah=1):
    return 1 <= surah <= 114 and 1 <= ayah <= AYAH_COUNTS[surah - 1]


def _http():
    import requests
    return requests


# ---------------------------------------------------------------- QuranEnc
def qe_version(key, http=None):
    """Publisher's current version of a translation (cached 24 h)."""
    ck = "qv:ver:%s" % key
    v = cache.get(ck)
    if v:
        return v
    try:
        r = (http or _http()).get("%s/translations/updates" % QE_BASE,
                                  params={"key": key}, timeout=10)
        d = r.json() if r.status_code == 200 else {}
    except Exception as e:  # noqa: BLE001
        raise SourceError("quranenc_unreachable") from e
    v = {"version": str(d.get("version") or ""), "last_update": d.get("last_update")}
    if not v["version"]:
        raise SourceError("quranenc_no_version")
    cache.set(ck, v, QE_TTL)
    return v


def qe_sura(key, surah, http=None):
    """All ayat of a surah for one QuranEnc book, verbatim.
    Returns {key, version, last_update, items:[{ayah, text, footnotes}]}."""
    if key not in QE_BOOKS or not valid_ref(surah):
        raise SourceError("bad_ref")
    ver = qe_version(key, http=http)
    ck = "qv:qe:%s:%s:%s" % (key, ver["version"], surah)
    hit = cache.get(ck)
    if hit:
        return hit
    try:
        r = (http or _http()).get("%s/translation/sura/%s/%d" % (QE_BASE, key, surah),
                                  timeout=15)
        rows = r.json().get("result") if r.status_code == 200 else None
    except Exception as e:  # noqa: BLE001
        raise SourceError("quranenc_unreachable") from e
    if not isinstance(rows, list) or not rows:
        raise SourceError("quranenc_empty")
    items = [{"ayah": int(x.get("aya")),
              "text": x.get("translation") or "",
              "footnotes": x.get("footnotes") or ""} for x in rows]
    out = {"key": key, "version": ver["version"], "last_update": ver["last_update"],
           "items": items}
    cache.set(ck, out, QE_TTL)
    return out


def book_meta(key, version):
    b = QE_BOOKS[key]
    return {"key": key, "lang": b["lang"], "title_bn": b["title_bn"],
            "title_en": b["title_en"], "publisher": b["publisher"],
            "version": version, "source": QE_SOURCE, "source_url": QE_SOURCE_URL}


def meaning(surah, http=None):
    """Bangla + English meaning for a whole surah (both, always)."""
    bn = qe_sura("bengali_zakaria", surah, http=http)
    en = qe_sura("english_saheeh", surah, http=http)
    return {"ok": True, "surah": surah,
            "bn": {**book_meta("bengali_zakaria", bn["version"]), "items": bn["items"]},
            "en": {**book_meta("english_saheeh", en["version"]), "items": en["items"]}}


# ---------------------------------------------------------------- shane nuzul
def _norm_bn(s):
    # য় can be one code point (U+09DF) or য + nukta (U+09AF U+09BC).
    return (s or "").replace("য়", "য়")


def _bn_re(pat):
    return re.compile(_norm_bn(pat))


_FN_MARK = re.compile(r"(?m)^\s*(?=\[[0-9০-৯]+\])")
_BN_SENT = re.compile(r"[^।!?\n]+[।!?]?")
_EN_SENT = re.compile(r"[^.!?\n]+[.!?]?")
_BN_EXPLICIT = _bn_re(
    r"শানে\s*নু[যজ][ূু]ল|না[যজ]িলের\s*(কারণ|প্রেক্ষাপট|প্রেক্ষিত)|"
    r"না[যজ]িল\s*হওয়ার\s*(কারণ|প্রেক্ষাপট)|অবতীর্ণ\s*হওয়ার\s*(কারণ|প্রেক্ষাপট)|"
    r"অবতরণের\s*(কারণ|প্রেক্ষাপট)")
_BN_REVEAL = _bn_re(r"না[যজ]িল|অবতীর্ণ")
_BN_AYAH = _bn_re(r"আয়াত")
_BN_CONTEXT = _bn_re(
    r"(^|\s)(এ|এই|উক্ত|তখন)\s|প্রেক্ষিতে|প্রেক্ষাপটে|প্রসঙ্গে|সম্পর্কে|ব্যাপারে|"
    r"কারণে|প্রতিকার|ঘটনায়")
_EN_RULES = re.compile(
    r"occasion of revelation|reason for (its|the) revelation|"
    r"(this|these|the) (verse|verses|āyah|ayah|āyāt)[^.]{0,120}\b(was|were) revealed|"
    r"\brevealed (concerning|regarding|in reference to|about|when|after)\b",
    re.IGNORECASE)


def split_units(text):
    """Footnote text -> whole units (a preamble + one unit per [n] marker).
    Units are returned verbatim (only outer whitespace trimmed)."""
    parts = [p.strip() for p in _FN_MARK.split(text or "")]
    return [p for p in parts if p and not set(p) <= set("_- \n")]


def states_reason(unit, lang):
    """keyword_v1: does this unit itself say why/when an ayah was revealed?"""
    if lang == "en":
        return bool(_EN_RULES.search(unit or ""))
    t = _norm_bn(unit)
    if _BN_EXPLICIT.search(t):
        return True
    for s in _BN_SENT.findall(t):
        if _BN_REVEAL.search(s) and _BN_AYAH.search(s) and _BN_CONTEXT.search(s):
            return True
    return False


def shan_nuzul(sources):
    """[{source_id, text}] — whole verbatim units that state the reason."""
    out = []
    for s in sources:
        units = split_units(s.get("footnotes") or "") if s.get("footnotes") is not None \
            else []
        if s.get("role") == "tafsir":
            units = [s.get("text") or ""] + units
        for u in units:
            if states_reason(u, s["lang"]):
                out.append({"source_id": s["id"], "text": u})
    return out


def _at(sura, ayah):
    for x in sura["items"]:
        if x["ayah"] == ayah:
            return x
    return None


def tafsir(surah, ayah, http=None):
    """Tafsir sheet: licensed sources only (QUL Bengali tafsirs have no
    copyright information on QUL -> not shown; owner action in the spec)."""
    if not valid_ref(surah, ayah):
        raise SourceError("bad_ref")
    srcs = []
    for key, sid in (("bengali_mokhtasar", "mukhtasar_bn"),
                     ("bengali_zakaria", "zakaria_notes_bn"),
                     ("english_saheeh", "saheeh_notes_en")):
        try:
            s = qe_sura(key, surah, http=http)
        except SourceError:
            continue
        row = _at(s, ayah)
        if not row:
            continue
        role = QE_BOOKS[key]["role"]
        text = row["text"] if role == "tafsir" else row["footnotes"]
        if not (text or "").strip():
            continue
        srcs.append({"id": sid, "role": role, "lang": QE_BOOKS[key]["lang"],
                     **{k: v for k, v in book_meta(key, s["version"]).items() if k != "key"},
                     "text": text,
                     "footnotes": row["footnotes"] if role == "meaning" else None})
    if not srcs:
        raise SourceError("quranenc_unreachable")
    sn = shan_nuzul([{"id": s["id"], "lang": s["lang"], "role": s["role"],
                      "text": s["text"] if s["role"] == "tafsir" else "",
                      "footnotes": s["footnotes"] if s["role"] == "meaning" else None}
                     for s in srcs])
    for s in srcs:
        s.pop("footnotes", None)
        s.pop("role", None)
    return {"ok": True, "surah": surah, "ayah": ayah, "sources": srcs,
            "shan_nuzul": sn, "shan_nuzul_rule": "keyword_v1",
            "shan_nuzul_review": "under_review"}


# ---------------------------------------------------------------- Quran Foundation
def qf_config():
    """(cfg, env) when the owner connected QF and the test is green, else None."""
    from . import integrations as I
    if not I.is_enabled(QF_SLUG):
        return None
    cfg = I.get(QF_SLUG)
    if not (cfg.get("client_id") and cfg.get("client_secret")):
        return None
    env = (cfg.get("env") or "production").strip().lower()
    return cfg, (env if env in QF_API else "production")


def qf_token(cfg, env, http=None, force=False):
    ck = "qv:qf:tok:%s:%s" % (env, cfg.get("client_id"))
    tok = None if force else cache.get(ck)
    if tok:
        return tok
    try:
        r = (http or _http()).post(
            QF_OAUTH[env], data={"grant_type": "client_credentials", "scope": QF_SCOPE},
            auth=(cfg["client_id"], cfg["client_secret"]), timeout=10)
        d = r.json() if r.status_code == 200 else {}
    except Exception as e:  # noqa: BLE001
        raise SourceError("qf_unreachable") from e
    tok = d.get("access_token")
    if not tok:
        raise SourceError("qf_auth_failed")
    cache.set(ck, tok, max(60, int(d.get("expires_in") or 3600) - 60))
    return tok


def _qf_get(path, params=None, http=None):
    c = qf_config()
    if not c:
        raise SourceError("qf_not_connected")
    cfg, env = c
    h = http or _http()
    for attempt in (0, 1):
        tok = qf_token(cfg, env, http=h, force=bool(attempt))
        try:
            r = h.get(QF_API[env] + path, params=params or {}, timeout=12,
                      headers={"x-auth-token": tok, "x-client-id": cfg["client_id"]})
        except Exception as e:  # noqa: BLE001
            raise SourceError("qf_unreachable") from e
        if r.status_code == 401 and not attempt:
            continue
        if r.status_code != 200:
            raise SourceError("qf_http_%s" % r.status_code)
        return r.json()
    raise SourceError("qf_auth_failed")


_TAG = re.compile(r"<[^>]+>")


def _plain(s):
    return _TAG.sub("", s or "").strip()


def audio_url(raw):
    u = (raw or "").strip()
    if not u:
        return None
    if u.startswith("//"):
        u = "https:" + u
    elif not u.startswith("http"):
        u = QF_AUDIO_BASE + u.lstrip("/")
    if any(b in u.lower() for b in BANNED_AUDIO_HOSTS):
        return None
    return u


def qf_ayah(surah, ayah, reciter=None, http=None):
    """Word-by-word (bn + en), transliteration and audio URL for one ayah."""
    if not valid_ref(surah, ayah):
        raise SourceError("bad_ref")
    if not qf_config():
        return {"ok": True, "enabled": False}
    rec = int(reciter or QF_DEFAULT_RECITER)
    key = "%d:%d" % (surah, ayah)
    ck = "qv:qf:ayah:%s:%s" % (key, rec)
    hit = cache.get(ck)
    if hit:
        return hit
    words = {}
    translit = ""
    for lang in ("bn", "en"):
        d = _qf_get("/verses/by_key/%s" % key, {
            "words": "true", "language": lang, "translations": QF_TRANSLIT_ID,
            "word_fields": "text_uthmani"}, http=http)
        v = d.get("verse") or {}
        if not translit:
            for tr in v.get("translations") or []:
                translit = _plain(tr.get("text"))
                break
        for w in v.get("words") or []:
            if w.get("char_type_name") not in (None, "word"):
                continue
            pos = w.get("position") or len(words) + 1
            cur = words.setdefault(pos, {"pos": pos, "ar": w.get("text_uthmani") or w.get("text") or "",
                                         "tr": _plain((w.get("transliteration") or {}).get("text"))})
            cur[lang] = _plain((w.get("translation") or {}).get("text"))
    url = None
    try:
        a = _qf_get("/recitations/%d/by_ayah/%s" % (rec, key), http=http)
        files = a.get("audio_files") or []
        url = audio_url(files[0].get("url")) if files else None
    except SourceError:
        url = None
    out = {"ok": True, "enabled": True, "surah": surah, "ayah": ayah,
           "translit": translit, "words": [words[k] for k in sorted(words)],
           "audio_url": url, "reciter_id": rec, "fetched_at": int(time.time()),
           "max_age_days": QF_MAX_AGE // 86400, "source": "Quran Foundation"}
    cache.set(ck, out, QF_MAX_AGE)
    return out


def qf_reciters(http=None):
    if not qf_config():
        return {"ok": True, "enabled": False, "items": []}
    hit = cache.get("qv:qf:reciters")
    if hit:
        return hit
    d = _qf_get("/resources/recitations", {"language": "en"}, http=http)
    items = []
    for r in d.get("recitations") or []:
        name = (r.get("translated_name") or {}).get("name") or r.get("reciter_name") or ""
        if r.get("id") and name:
            items.append({"id": int(r["id"]), "name": name, "style": r.get("style") or ""})
    out = {"ok": True, "enabled": True, "items": items,
           "default_id": QF_DEFAULT_RECITER, "source": "Quran Foundation"}
    cache.set("qv:qf:reciters", out, QF_MAX_AGE)
    return out


def test_connection(cfg, http=None):
    """Owner Admin 'Test': an OAuth2 client-credentials token proves the keys."""
    if not (cfg.get("client_id") or "").strip() or not (cfg.get("client_secret") or "").strip():
        return False, "Quran Foundation: Client ID and Client Secret are both needed"
    env = (cfg.get("env") or "production").strip().lower()
    env = env if env in QF_API else "production"
    try:
        qf_token(cfg, env, http=http, force=True)
    except SourceError as e:
        return False, "Quran Foundation: %s" % e
    return True, "Quran Foundation token OK (%s)" % env
