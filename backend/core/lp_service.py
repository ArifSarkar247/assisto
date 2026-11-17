"""
lp_service.py — Language Partner V2 backbone (lpcore, owner order 9 Nov 21:45).

Content (part G): versioned LpItem rows. An import or an edit makes a NEW
version (status draft); the automatic checks (logic/lp_checks.py) move it to
ai_checked or keep it in draft with the failures; the owner / reviewers make
it human_approved or rejected in Owner Admin -> Language content. The app
sees the newest LIVE version (ai_checked or human_approved) of a key; a live
item that is not human-approved carries `beta: true`.

Scoring (part A): Listening/Reading marked here with the public tables;
Writing/Speaking scored by Claude — Haiku for Normal, Sonnet (AI level
"best") only for Best. Credits are taken BEFORE the call (exact worst-case
price, >= 40 % profit) and given back when the model fails, cuts the answer
or returns unreadable JSON: a failed or cut score is never charged.

Gates (part I): Free = daily lesson + life English + vocabulary + ONE mock
section per rolling 7 days; Premium = full mocks, AI scoring, tracks, levels.

Cambridge companion (part B): only the user's own typed answers and own
typed key are stored (40 short cells each) — never a question, passage, key
from us or audio.
"""
import datetime
import json
import logging
import os

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from .logic import lp_bands as B
from .logic import lp_checks as CK
from .logic import lp_score as SC

log = logging.getLogger(__name__)

FLAG = "language_packs"
PREMIUM_PLANS = ("premium", "premium_pro", "founder", "business")
FREE_SECTIONS_PER_WEEK = 1
SCORES_PER_DAY = 40          # abuse cap on paid AI scores per user per 24 h
WEEK = datetime.timedelta(days=7)
TRACKS = {"academic": "ielts_ac", "general": "ielts_gt",
          **{t: t for t in CK.STAGE2_TRACKS}}        # stage 2 going-abroad tracks
OBJECTIVE = ("listening", "reading")
SECTIONS = CK.SECTIONS
COMPANION_BOOKS = tuple(range(10, 21))       # Cambridge IELTS 10 .. 20 (bump when a new book is out)
COMPANION_TESTS = (1, 2, 3, 4)
CELL_MAX_CHARS = 40
CELL_MAX_WORDS = 5
NO_CONTENT_LINE = {
    "en": "Questions, audio and answers are not kept in the app. Use your own book.",
    "bn": "প্রশ্ন, অডিও ও উত্তর অ্যাপে রাখা হয় না। নিজের বই ব্যবহার করুন।",
}
WEAK_TITLES = {
    "spelling": ("Spelling", "বানান"), "plural": ("Singular / plural", "এক বচন / বহুবচন"),
    "word_limit": ("Word limit", "শব্দসীমা"), "tfng": ("True / False / Not Given", "সত্য / মিথ্যা / উল্লেখ নেই"),
    "map": ("Maps and plans", "ম্যাপ ও নকশা"), "matching": ("Matching", "মিলানো"),
}
_FP_FILE = os.path.join(os.path.dirname(__file__), "data", "lp_known_fingerprints.json")


# ------------------------------------------------------------------ gates
def flag_on(user):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(FLAG, user))
    except Exception:
        return False


def is_premium(user):
    try:
        from . import plans
        return plans.effective_plan(user) in PREMIUM_PLANS
    except Exception:
        return False


def owner_in_test(user):
    """Owner rule: tests and E2E never use the owner account or its quota.
    Under the CI E2E settings the owner (superuser) is refused outright."""
    if "ci_e2e" not in getattr(settings, "INSTALLED_APPS", ()):
        return False
    return bool(getattr(user, "is_superuser", False))


def _opens(user, now=None):
    now = now or timezone.now()
    from .models import LpAttempt
    return LpAttempt.objects.filter(user=user, kind="open", created_at__gte=now - WEEK)


def free_left(user, now=None):
    """Free sections left in the rolling 7 days: 1 + one per Google-verified
    rewarded ad (lp_sec) - sections already opened."""
    if is_premium(user):
        return None
    since = (now or timezone.now()) - WEEK
    extra = _verified_ads(user, "section", since)
    return max(0, FREE_SECTIONS_PER_WEEK + extra - _opens(user, now).count())


def next_free_at(user, now=None):
    first = _opens(user, now).order_by("created_at").first()
    return (first.created_at + WEEK).isoformat() if first else None


def use_section_slot(user, mock_key, section, now=None):
    """(ok, reason). Re-opening a section already opened this week is free."""
    if is_premium(user):
        return True, ""
    from .models import LpAttempt
    if _opens(user, now).filter(item_key=mock_key, section=section).exists() or \
            _paid_opens(user, now).filter(item_key=mock_key, section=section).exists():
        return True, ""
    if free_left(user, now) <= 0:
        return False, "week_used"
    LpAttempt.objects.create(user=user, kind="open", item_key=mock_key, section=section)
    return True, ""


def _paid_opens(user, now=None):
    from .models import LpAttempt
    return LpAttempt.objects.filter(user=user, kind="open_paid",
                                    created_at__gte=(now or timezone.now()) - WEEK)


# A section opened with credits (lpapp: the rewarded ad earns them through the
# existing RewardedAdSheet + SSV credits flow). Serving a section has no AI
# cost, so one credit (৳2.80 floor) keeps far above the 40 % rule.
SECTION_UNLOCK_CREDITS = 1


def pay_section(user, mock_key, section):
    """(ok, reason): open one extra section for SECTION_UNLOCK_CREDITS credits."""
    from . import billing
    from .models import LpAttempt
    res = billing.charge(user, "lp_section", qty=1, note="lp.section", exact=SECTION_UNLOCK_CREDITS)
    if not res.get("ok"):
        return False, "credits"
    LpAttempt.objects.create(user=user, kind="open_paid", item_key=mock_key, section=section,
                             credits=int(res.get("charged") or 0))
    return True, ""


def free_day_economics(ad_value=None, banners_per_day=20, interstitials_per_day=1,
                       interstitial_value=None):
    """Owner Part B (10 Nov): one free learner's worst AI day vs. CONSERVATIVE ad
    income (eCPM floor for banners; an interstitial counted at the rewarded value).
    Returns {cost_bdt, income_bdt, profit_pct} — reported, see the test."""
    from . import ai_config as C
    from .logic import langpacks as LP
    from .logic import plan_book as PB
    try:
        from . import billing
        floor = float(billing.cfg()["ad_rewards"]["ecpm_bdt"]) / 1000.0
    except Exception:  # noqa: BLE001
        floor = 0.03
    val = ad_value_bdt() if ad_value is None else ad_value
    inter = val if interstitial_value is None else interstitial_value
    prices = C.DEFAULT_PRICES
    # free Life English role-play turns (cheap class: the dearest reachable model)
    turn = max(SC.worst_cost_usd([m], 5000, 400 + 1024, prices)
               for m in ("claude-haiku-5-5", "gemini-3.5-flash-lite", "gpt-4o-mini"))
    cost = LP.FREE_AI_PER_DAY * turn * PB.SAFETY_USD_BDT
    income = banners_per_day * floor + interstitials_per_day * inter
    profit = income * (1 - PB.OVERHEAD_PCT) - cost
    return {"cost_bdt": round(cost, 4), "income_bdt": round(income, 4),
            "profit_pct": round(profit / income, 4) if income else None}


def gates(user):
    p = is_premium(user)
    return {"premium": p, "free_sections_left_week": free_left(user),
            "next_free_at": None if p else next_free_at(user),
            "full_mocks": p, "ai_scoring": p, "tracks": p, "all_levels": p,
            "daily_lesson": True, "life_english": True, "vocabulary": True,
            "ads": ad_policy(user)}


# ------------------------------------------------- free tier ads (owner 10 Nov)
# Free learners may watch a REWARDED ad (Google-verified by SSV only) to unlock
# one extra mock section, or enough ads to pay for one Normal AI score.
# Interstitials at natural breaks + banners on home/lists are app-side.
# Never inside a timed mock, audio, speaking or a certificate; Premium: no ads.
AD_PLACEMENT = {"section": "lp_sec", "score": "lp_score"}
NO_ADS_IN = ("timed_mock", "listening_audio", "speaking", "certificate", "exam_result_pdf")
# Share of one ad's income that may pay for the unlock: 1 - overhead (10 %)
# - the owner's 40 % profit = 50 %. Ad income has no VAT / Play fee.
AD_COST_SHARE = 0.50
MAX_ADS_PER_UNLOCK = 5            # more than this is not worth showing: no offer
AD_UNLOCKS_PER_DAY = {"section": 3, "score": 3}


def ad_value_bdt():
    """BDT one verified rewarded ad earns — the app's existing assumption
    (owner override in pricing, else the conservative eCPM floor / 1000)."""
    try:
        from . import billing
        from .logic import photo_studio as PS
        c = billing.cfg()
        return float(PS.ad_value_bdt(c.get("photo_studio"), c["ad_rewards"]))
    except Exception:  # noqa: BLE001 — no value known: no ad unlock offered
        return 0.0


def score_cost_bdt(plan=None):
    """Worst-case BDT of one Normal score (dearest reachable model, caps, >= 125/USD)."""
    from . import ai_config as C
    from .logic import plan_book as PB
    plan = plan or score_plan("normal")
    usd = SC.worst_cost_usd(plan["models"], plan["in_tokens"], plan["out_tokens"],
                            C.DEFAULT_PRICES | (_router_prices() or {}))
    return usd * PB.SAFETY_USD_BDT if usd else 0.0


def _router_prices():
    try:
        from . import ai_router as R
        return R.cfg().get("prices") or {}
    except Exception:  # noqa: BLE001
        return {}


def ads_needed(unlock):
    """Rewarded ads per unlock (None = not offered: ads cannot pay for it)."""
    if unlock == "section":
        return 1              # serving a section costs ~nothing; one ad pays it
    from .logic import photo_studio as PS
    n = PS.ads_needed(score_cost_bdt(), ad_value_bdt(), AD_COST_SHARE)
    return n if n is not None and n <= MAX_ADS_PER_UNLOCK else None


def ad_policy(user):
    if is_premium(user):
        return {"show": False}
    return {"show": True, "rewarded": {"section": ads_needed("section"),
                                       "score": ads_needed("score")},
            "interstitial": "natural_breaks", "banner": ["home", "lists"],
            "never_in": list(NO_ADS_IN), "score_unlocks_left": ad_scores_left(user)}


def _verified_ads(user, unlock, since):
    from .models import PhotoAdTicket
    return PhotoAdTicket.objects.filter(user=user, placement=AD_PLACEMENT[unlock],
                                        status="verified", verified_at__gte=since).count()


def ad_scores_left(user, now=None):
    n = ads_needed("score")
    if not n:
        return 0
    from .models import LpAttempt
    since = (now or timezone.now()) - WEEK
    used = LpAttempt.objects.filter(user=user, kind__in=("writing", "speaking"),
                                    created_at__gte=since, data__ad_unlock=True).count()
    return max(0, _verified_ads(user, "score", since) // n - used)


def issue_ad_ticket(user, unlock):
    """(status, body): a rewarded-ad ticket whose nonce the app passes to
    AdMob as SSV custom_data. Only Google's signed callback verifies it."""
    import secrets
    from .models import PhotoAdTicket
    if unlock not in AD_PLACEMENT:
        return 400, {"ok": False, "reason": "bad_unlock"}
    if is_premium(user):
        return 409, {"ok": False, "reason": "premium_no_ads"}
    if ads_needed(unlock) is None:
        return 409, {"ok": False, "reason": "not_offered"}
    from .admob_service import placement_on
    if not placement_on("lp_unlock"):
        # adcontrol: the owner switched this placement off (Ad control)
        return 409, {"ok": False, "reason": "not_offered"}
    from .photo_studio_service import _ad_units
    units = _ad_units(user)
    if not units.get("_configured"):
        return 409, {"ok": False, "reason": "ads_not_live"}
    day = timezone.now() - datetime.timedelta(days=1)
    cap = AD_UNLOCKS_PER_DAY[unlock] * (ads_needed(unlock) or 1)
    if _verified_ads(user, unlock, day) >= cap:
        return 429, {"ok": False, "reason": "daily_cap"}
    t = PhotoAdTicket.objects.create(user=user, kind="rewarded", placement=AD_PLACEMENT[unlock],
                                     nonce=secrets.token_urlsafe(24))
    return 201, {"ok": True, "nonce": t.nonce, "custom_data": t.nonce, "user_id": str(user.pk),
                 "rewarded_unit": units.get("rewarded", ""), "ads_needed": ads_needed(unlock)}


# ---------------------------------------------------------------- content
def known_fingerprints():
    try:
        with open(_FP_FILE, encoding="utf-8") as fh:
            return frozenset(json.load(fh).get("hashes") or [])
    except (OSError, ValueError):
        return frozenset()


def live_qs(kind=None):
    from .models import LpItem
    qs = LpItem.objects.filter(status__in=LpItem.LIVE)
    return qs.filter(kind=kind) if kind else qs


def live_item(key, kind=None):
    return live_qs(kind).filter(key=key).order_by("-version").first()


def live_latest(kind, track=None):
    """Newest live version per key."""
    qs = live_qs(kind)
    if track:
        qs = qs.filter(track=track)
    out = {}
    for it in qs.order_by("key", "-version"):
        out.setdefault(it.key, it)
    return list(out.values())


def is_beta(item):
    if item.status != "human_approved":
        return True
    if item.kind == "mock" and not is_track(item):
        for k in (item.data.get("sections") or {}).values():
            s = live_item(k, "section")
            if s is None or s.status != "human_approved":
                return True
    return False


def content_version(kind):
    from django.db.models import Max
    v = live_qs(kind).aggregate(m=Max("updated_at"))["m"]
    return int(v.timestamp()) if v else 0


def media_url(name):
    if not name:
        return None
    try:
        from django.core.files.storage import default_storage
        return default_storage.url(name)
    except Exception:  # noqa: BLE001
        return None


def public_question(q):
    out = {k: q[k] for k in ("n", "type", "prompt", "options", "max_words", "group") if k in q}
    if q.get("image"):
        out["image_url"] = media_url(q["image"])
    return out


def section_questions(name, body):
    """Flat question list of a listening/reading section body."""
    if name == "listening":
        return [q for p in body.get("parts") or [] for q in p.get("questions") or []]
    if name == "reading":
        return [q for p in body.get("passages") or [] for q in p.get("questions") or []]
    return []


def public_section(name, body):
    if name == "listening":
        parts = [p for p in body.get("parts") or [] if isinstance(p, dict)]
        return {"duration_sec": body.get("duration_sec"),
                "audio_ready": bool(parts) and all(p.get("audio") for p in parts),
                "parts": [_listening_part(p, i == len(parts) - 1) for i, p in enumerate(parts)]}
    if name == "reading":
        return {"duration_sec": body.get("duration_sec"),
                "passages": [{"n": p.get("n"), "title": p.get("title"), "text": p.get("text"),
                              "questions": [public_question(q) for q in p.get("questions") or []]}
                             for p in body.get("passages") or []]}
    if name == "writing":
        return {"duration_sec": body.get("duration_sec"),
                "tasks": [dict({k: t[k] for k in ("n", "prompt", "min_words") if k in t},
                               **({"image_url": media_url(t["image"])} if t.get("image") else {}))
                          for t in body.get("tasks") or []]}
    if name == "speaking":
        return {"duration_sec": body.get("duration_sec"),
                "parts": [{k: p[k] for k in ("n", "questions", "cue_card", "prep_sec", "talk_sec")
                           if k in p} for p in body.get("parts") or []]}
    return {}


def _listening_part(p, last):
    """lpaudio: a listening part as the phone sees it — the recorded audio (signed
    link) + timings for the exam flow (question time -> audio -> check time ->
    next part). NEVER the script, turns, transcript or answers; a part without
    audio says so (audio_url null) and the phone does not read it aloud."""
    meta = p.get("audio_meta") or {}
    out = {"n": p.get("n"), "audio_url": media_url(p.get("audio")),
           "preview_sec": int(meta.get("preview_sec") or 30),
           "check_sec": int(meta.get("check_sec") or (120 if last else 30)),
           "questions": [public_question(q) for q in p.get("questions") or []]}
    if p.get("audio"):
        out["duration_sec"] = round(float(meta.get("duration_sec") or 0), 1)
        out["accents"] = list(meta.get("accents") or [])
        out["bytes"] = int(meta.get("bytes") or 0)
    return out


def mock_sections(mock):
    """{name: live section item} for an IELTS mock item."""
    out = {}
    if is_track(mock):
        return out
    for name, key in (mock.data.get("sections") or {}).items():
        it = live_item(key, "section")
        if it is not None:
            out[name] = it
    return out


def is_track(mock):
    return isinstance((mock.data or {}).get("sections"), list)


_HIDDEN = ("answer", "explain_bn", "explain_en", "script", "skill", "audio_meta")


def _public_tts(t):
    """lpaudio: a recorded question -> only its signed audio link (no lines)."""
    if isinstance(t, dict) and t.get("audio"):
        return {"audio_url": media_url(t["audio"]), "lang": t.get("lang"), "repeat": 1,
                "duration_sec": (t.get("audio_meta") or {}).get("duration_sec")}
    return _strip(t)


def _strip(obj):
    """A stage-2 test without keys, explanations and TTS scripts."""
    if isinstance(obj, dict):
        return {k: (_public_tts(v) if k == "tts" else _strip(v)) for k, v in obj.items() if k not in _HIDDEN}
    if isinstance(obj, list):
        return [_strip(x) for x in obj]
    return obj


def track_payload(mock, section=None):
    d = mock.data or {}
    secs = [s for s in d.get("sections") or [] if not section or s.get("id") == section]
    return {"id": mock.key, "kind": mock.track, "beta": is_beta(mock), "version": mock.version,
            "title_en": d.get("title_en", ""), "title_bn": d.get("title_bn", ""),
            "exam": d.get("exam", ""), "lang": d.get("lang", ""),
            "scoring": _strip(d.get("scoring") or {}), "sections": _strip(secs),
            "practice_label": B.PRACTICE_LABEL}


def mark_track(user, mock, section, answers):
    """Letter compare for a stage-2 test section; score = raw x per_question."""
    from .models import LpAttempt
    d = mock.data or {}
    sec = next((s for s in d.get("sections") or [] if s.get("id") == section), None)
    if sec is None:
        return None
    qs = [dict(q, type="mcq", tag=q.get("skill") or "") for p in sec.get("parts") or []
          for q in p.get("questions") or []]
    res = B.mark(qs, answers, "track")
    per = int((d.get("scoring") or {}).get("per_question") or 1)
    res.update({"score": res["raw"] * per, "max": res["total"] * per, "band": None})
    att = LpAttempt.objects.create(user=user, kind="mark", item_key=mock.key, section=section[:12],
                                   data={"raw": res["raw"], "total": res["total"], "score": res["score"],
                                         "weak": res["weak"], "version": mock.version})
    res["attempt_id"] = att.id
    return res


def section_ids(mock):
    if is_track(mock):
        return [s.get("id") for s in mock.data.get("sections") or [] if isinstance(s, dict)]
    return list(SECTIONS)


def mock_summary(mock):
    if is_track(mock):
        d = mock.data or {}
        return {"id": mock.key, "title_en": d.get("title_en", ""), "title_bn": d.get("title_bn", ""),
                "kind": mock.track, "exam": d.get("exam", ""), "beta": is_beta(mock),
                "version": mock.version, "sections": section_ids(mock)}
    secs = mock_sections(mock)
    return {"id": mock.key, "title_en": mock.data.get("title_en", ""),
            "title_bn": mock.data.get("title_bn", ""),
            "kind": "general" if mock.track == "ielts_gt" else "academic",
            "beta": is_beta(mock), "version": mock.version,
            "sections": [s for s in SECTIONS if s in secs]}


def mock_payload(mock, section=None):
    if is_track(mock):
        return track_payload(mock, section)
    out = {"id": mock.key, "kind": "general" if mock.track == "ielts_gt" else "academic",
           "beta": is_beta(mock), "version": mock.version,
           "title_en": mock.data.get("title_en", ""), "title_bn": mock.data.get("title_bn", ""),
           "practice_label": B.PRACTICE_LABEL}
    for name, it in mock_sections(mock).items():
        if section and name != section:
            continue
        out[name] = public_section(name, it.data.get("body") or {})
    return out


def variant_of(mock):
    return "general" if mock is not None and mock.track == "ielts_gt" else "academic"


# ----------------------------------------------------------- import + checks
def _log(item, action, actor=None, note="", before="", after=""):
    from .models import LpReviewLog
    LpReviewLog.objects.create(item=item, action=action, actor=actor, note=str(note)[:500],
                               before=before, after=after or item.status)


def run_checks(item, known=None):
    """Run the automatic checks + the duplicate check; draft <-> ai_checked."""
    from .models import LpItem
    res = CK.check_item(item.kind, item.data, item.level,
                        known if known is not None else known_fingerprints(), item.track)
    dup = (LpItem.objects.filter(content_hash=item.content_hash, kind=item.kind)
           .exclude(key=item.key).exclude(status="rejected").values_list("key", flat=True).first())
    if dup:
        res["failures"].append({"code": "duplicate", "hint": "same content as %s" % dup})
        res["ok"] = False
    res["ran_at"] = timezone.now().isoformat()
    before = item.status
    item.checks = res
    hard = any(f["code"].startswith("copyright") for f in res["failures"])
    if hard:
        item.status = "rejected"
    elif item.status in ("draft", "ai_checked"):
        item.status = "ai_checked" if res["ok"] else "draft"
    item.updated_at = timezone.now()
    item.save(update_fields=["checks", "status", "updated_at"])
    _log(item, "check", note="ok" if res["ok"] else "; ".join(
        f["hint"] for f in res["failures"][:5]), before=before)
    return res


def upsert(kind, key, data, track="", level="", tag="", source="ai", bundle="", actor=None,
           known=None):
    """New version when the content changed; returns (item, created)."""
    from .models import LpItem
    if kind not in LpItem.KINDS:
        raise ValueError("bad kind")
    key = str(key or "").strip()[:80]
    if not key:
        raise ValueError("no key")
    h = CK.content_hash(kind, data)
    last = LpItem.objects.filter(key=key).order_by("-version").first()
    if last is not None and last.content_hash == h and last.kind == kind:
        return last, False
    with transaction.atomic():
        item = LpItem.objects.create(
            kind=kind, key=key, version=(last.version + 1) if last else 1, track=track[:16],
            level=str(level or "")[:12], tag=str(tag or "")[:40], status="draft", data=data,
            content_hash=h, source=source[:12], bundle=bundle[:80])
        _log(item, "import" if actor is None else "edit", actor=actor, note=bundle, before="")
    run_checks(item, known)
    return item, True


def import_item(raw, source="ai", bundle="", known=None):
    """One bundle ITEM -> [(item, created)]; a mock's inline sections are
    split into section items "<mock>-<section>"."""
    kind, key = raw.get("kind"), raw.get("key")
    data = dict(raw.get("data") or {})
    track, level = str(raw.get("track") or ""), str(raw.get("level") or "")
    out = []
    if kind == "mock" and not isinstance(data.get("sections"), list):
        refs = dict(data.get("sections") or {})
        for name in SECTIONS:
            if isinstance(data.get(name), dict):
                skey = "%s-%s" % (key, name)
                out.append(upsert("section", skey, {"section": name, "mock": key,
                                                    "body": data.pop(name)},
                                  track, level, "", source, bundle, known=known))
                refs[name] = skey
        data["sections"] = refs
    tag = raw.get("tag") or ((data.get("q") or {}).get("tag") if kind == "question" else "")
    out.append(upsert(kind, key, data, track, level, tag or "", source, bundle, known=known))
    return out


def store_media(path, root):
    """Copy one bundle file into private media lp/<sha256>.<ext>; returns the
    storage name (served only through signed links)."""
    import hashlib
    from django.core.files.base import ContentFile
    from django.core.files.storage import default_storage
    full = os.path.realpath(os.path.join(root, path))
    if not full.startswith(os.path.realpath(root) + os.sep):
        raise ValueError("media path escapes the bundle")
    ext = os.path.splitext(full)[1].lower()
    if ext not in (".mp3", ".ogg", ".m4a", ".opus", ".wav", ".png", ".webp", ".jpg", ".jpeg"):
        raise ValueError("media type %s not allowed" % ext)
    with open(full, "rb") as fh:
        blob = fh.read()
    name = "lp/%s%s" % (hashlib.sha256(blob).hexdigest()[:40], ext)
    if not default_storage.exists(name):
        default_storage.save(name, ContentFile(blob))
    return name


def _swap_media(obj, root):
    if isinstance(obj, dict):
        for k, v in list(obj.items()):
            if k in ("audio", "image") and isinstance(v, str) and v and not v.startswith("lp/"):
                obj[k] = store_media(v, root)
            else:
                _swap_media(v, root)
    elif isinstance(obj, list):
        for x in obj:
            _swap_media(x, root)


def import_bundle(root):
    """<root>/bundle.json (+ audio/, img/) -> counts. Never raises on one bad item."""
    with open(os.path.join(root, "bundle.json"), encoding="utf-8") as fh:
        b = json.load(fh)
    if int(b.get("schema") or 0) != 1:
        raise ValueError("unknown bundle schema")
    bundle = str(b.get("bundle") or os.path.basename(root.rstrip("/")))[:80]
    source = str(b.get("source") or "ai")[:12]
    known = known_fingerprints()
    counts = {"new": 0, "same": 0, "ai_checked": 0, "draft": 0, "rejected": 0, "errors": []}
    for raw in b.get("items") or []:
        try:
            _swap_media(raw.get("data"), root)
            for item, created in import_item(raw, source, bundle, known):
                counts["new" if created else "same"] += 1
                if created:
                    counts[item.status if item.status in counts else "draft"] += 1
        except Exception as e:  # noqa: BLE001 — report, keep importing
            counts["errors"].append("%s: %s" % (raw.get("key"), str(e)[:120]))
    return counts


def import_app_assets(folder):
    """Seed scenario / vocab items from the app's bundled app/assets/lp/*.json
    (lpapp's files are the source until reviewed DB content exists)."""
    counts = {"new": 0, "same": 0}
    known = known_fingerprints()
    for fn in sorted(os.listdir(folder)):
        if not fn.endswith(".json"):
            continue
        kind = "vocab" if "vocab" in fn else "scenario" if ("life" in fn or "scen" in fn) else None
        if kind is None:
            continue
        with open(os.path.join(folder, fn), encoding="utf-8") as fh:
            j = json.load(fh)
        rows = j if isinstance(j, list) else (j.get("items") or j.get("scenarios")
                                              or j.get("topics") or j.get("lists") or [])
        for r in rows:
            if isinstance(r, dict) and r.get("id"):
                _, created = upsert(kind, "%s-%s" % (kind, r["id"]), r,
                                    "life" if kind == "scenario" else "vocab",
                                    str(r.get("level") or ""), "", "app", fn, known=known)
                counts["new" if created else "same"] += 1
    return counts


# ------------------------------------------------------------- review queue
REVIEW_ACTIONS = ("approve", "reject", "recheck", "edit")


def review(item, action, actor, note="", data=None):
    """Owner Admin action -> (item, error). Edit = a new version (the old one
    stays for the audit trail); approving needs the automatic checks green."""
    if action not in REVIEW_ACTIONS:
        return item, "bad_action"
    before = item.status
    if action == "approve":
        if not (item.checks or {}).get("ok"):
            return item, "checks_failed"
        item.status = "human_approved"
    elif action == "reject":
        item.status = "rejected"
    elif action == "recheck":
        run_checks(item)
        return item, None
    elif action == "edit":
        if not isinstance(data, dict) or not data:
            return item, "bad_json"
        new, created = upsert(item.kind, item.key, data, item.track, item.level, item.tag,
                              "human", "edit", actor=actor)
        if created and (new.checks or {}).get("ok"):
            new.status = "human_approved"
            new.reviewed_by, new.reviewed_at = actor, timezone.now()
            new.save(update_fields=["status", "reviewed_by", "reviewed_at"])
            _log(new, "approve", actor, "approved with the edit", before="ai_checked")
        return new, None if created else "unchanged"
    item.reviewed_by, item.reviewed_at = actor, timezone.now()
    item.updated_at = timezone.now()
    item.save(update_fields=["status", "reviewed_by", "reviewed_at", "updated_at"])
    _log(item, action, actor, note, before=before)
    return item, None


# ---------------------------------------------------------------- marking
def mark_section(user, mock, section, answers):
    if is_track(mock):
        return mark_track(user, mock, section, answers)
    it = mock_sections(mock).get(section)
    if it is None:
        return None
    qs = section_questions(section, it.data.get("body") or {})
    res = B.mark(qs, answers, section, variant_of(mock))
    from .models import LpAttempt
    att = LpAttempt.objects.create(user=user, kind="mark", item_key=mock.key, section=section,
                                   band=res["band"], data={"raw": res["raw"], "total": res["total"],
                                                           "weak": res["weak"],
                                                           "version": it.version,
                                                           "answers": {str(k): str(v)[:120] for k, v in
                                                                       (answers or {}).items()}})
    res["attempt_id"] = att.id
    return res


def weak_items(tags, n=10):
    out = []
    for it in live_qs("question").filter(tag__in=[str(t)[:40] for t in tags][:10]).order_by("?")[:n]:
        q = public_question((it.data or {}).get("q") or {})
        q.update({"id": it.key, "qid": it.key, "tag": it.tag, "section": (it.data or {}).get("section"),
                  "beta": it.status != "human_approved", "answer_hidden": True})
        if (it.data or {}).get("passage"):
            q["passage"] = it.data["passage"]
        if (it.data or {}).get("audio"):
            q["audio_url"] = media_url(it.data["audio"])
        out.append(q)
    return out


def mark_practice(user, answers):
    items = []
    raw = 0
    for qid, your in list((answers or {}).items())[:50]:
        it = live_item(str(qid), "question")
        if it is None:
            continue
        q = (it.data or {}).get("q") or {}
        ok, mistake = B.classify(q.get("type"), str(your or "")[:120], q.get("answer"),
                                 q.get("max_words"))
        raw += 1 if ok else 0
        items.append({"qid": it.key, "your": str(your or "")[:120], "key": B.key_text(q.get("answer")),
                      "correct": ok, "mistake": mistake, "explain_en": q.get("explain_en", ""),
                      "explain_bn": q.get("explain_bn", "")})
    return {"raw": raw, "total": len(items), "items": items}


def weak_areas(tags):
    out = []
    for t in tags or []:
        en, bn = WEAK_TITLES.get(t, (str(t).replace("_", " ").capitalize(), str(t).replace("_", " ")))
        out.append({"tag": t, "title_en": en, "title_bn": bn})
    return out[:8]


def rule_comment(bands, overall):
    """The free, deterministic mock comment (no AI)."""
    named = {k: v for k, v in (bands or {}).items() if isinstance(v, (int, float))}
    if not named:
        return "", ""
    lo = min(named, key=named.get)
    hi = max(named, key=named.get)
    en = ("Overall practice band %s. Your strongest section is %s (%s); %s (%s) gives the "
          "quickest gain — practise it next." % (overall, hi, named[hi], lo, named[lo]))
    bn_names = {"listening": "লিসেনিং", "reading": "রিডিং", "writing": "রাইটিং", "speaking": "স্পিকিং"}
    bn = ("মোট অনুশীলন ব্যান্ড %s। সবচেয়ে ভালো %s (%s); %s (%s) অনুশীলন করলে সবচেয়ে দ্রুত বাড়বে।" % (
        overall, bn_names.get(hi, hi), named[hi], bn_names.get(lo, lo), named[lo]))
    return en, bn


def finish_mock(user, mock, bands, weak):
    clean = {k: B.round_band(float(v)) for k, v in (bands or {}).items()
             if k in SECTIONS and isinstance(v, (int, float)) and 0 <= v <= 9}
    ov = B.overall(clean)
    en, bn = rule_comment(clean, ov)
    tags = [str(t)[:40] for t in (weak or [])][:10]
    from .models import LpAttempt
    att = LpAttempt.objects.create(user=user, kind="result", item_key=mock.key, band=ov,
                                   data={"bands": clean, "weak": tags, "variant": variant_of(mock),
                                         "title_en": mock.data.get("title_en", ""),
                                         "full": len(clean) == 4})
    return {"ai_state": "rules", "overall": ov, "bands": clean, "comment_en": en, "comment_bn": bn,
            "weak_areas": weak_areas(tags), "result_id": att.id,
            "certificate_url": "/api/v1/lp/certificate/%d" % att.id,
            "practice_label": B.PRACTICE_LABEL}


# ------------------------------------------------------------- companion
def clean_cells(cells):
    """{n: text} for n in 1..40 — short cells only (no pasted book text)."""
    out = {}
    for k, v in (cells or {}).items():
        try:
            n = int(k)
        except (TypeError, ValueError):
            return None
        if not 1 <= n <= 40:
            return None
        s = str(v or "").strip()
        if len(s) > CELL_MAX_CHARS or len(s.split()) > CELL_MAX_WORDS:
            return None
        if s:
            out[str(n)] = s
    return out


def _guess_type(key):
    k = B.norm(key)
    if k in ("true", "false", "not given", "t", "f", "ng"):
        return "tfng"
    if k in ("yes", "no", "y", "n"):
        return "ynng"
    if len(k) == 1 and k.isalpha():
        return "mcq"
    if k in ("i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"):
        return "matching"
    return "gap"


def companion_mark(user, book, test, section, variant, answers, key):
    qs = [{"n": int(n), "type": _guess_type(k.split("/")[0]), "answer": k.split("/")}
          for n, k in sorted(key.items(), key=lambda x: int(x[0]))]
    res = B.mark(qs, answers, section, variant)
    from .models import LpAttempt
    att = LpAttempt.objects.create(
        user=user, kind="companion", item_key="book%d-test%d" % (book, test), section=section,
        band=res["band"], data={"book": book, "test": test, "variant": variant,
                                "answers": answers, "key": key, "raw": res["raw"],
                                "total": res["total"], "mistake_counts": res["mistake_counts"]})
    for i in res["items"]:
        i.pop("explain_en", None)
        i.pop("explain_bn", None)
    res["sheet_id"] = att.id
    res["no_content_line"] = NO_CONTENT_LINE
    return res


# ------------------------------------------------------------------ scoring
def score_plan(level):
    """How a score call runs + what it costs:
    {level, ai_level, tier, task_class, max_tokens, models, in_tokens, out_tokens, credits}.
    Normal: Claude Haiku (the router's cheap Anthropic slot, Anthropic only).
    Best: the AI level 'best' (Sonnet) when the levels block is on; otherwise
    Best falls back to Normal (never Opus)."""
    from . import ai_config as C
    from . import ai_router as R
    conf = R.cfg()
    prices = conf.get("prices") or C.DEFAULT_PRICES
    try:
        from . import billing
        usd = float(billing.cfg().get("usd_bdt") or 0) or None
    except Exception:  # noqa: BLE001 — the 125 BDT/USD safety floor applies
        usd = None
    if level == "best":
        try:
            from . import ai_levels_service as ALS
            if ALS.enabled():
                sp = ALS.spec("best")
                models = [sp["model"]] + [m for _, m in sp.get("fallbacks") or []]
                in_t, out_t = int(sp["in_cap"]), int(sp["out_cap"])
                return {"level": "best", "ai_level": "best", "tier": "strong", "task_class": None,
                        "max_tokens": out_t, "models": models, "in_tokens": in_t,
                        "out_tokens": out_t,
                        "credits": SC.credits_for(models, in_t, out_t, prices, usd,
                                                  floor=int(sp.get("credits") or 1))}
        except Exception:  # noqa: BLE001 — fall back to Normal
            pass
    caps = SC.CAPS["normal"]
    from . import ai as A
    model = C.model_for(conf, "anthropic", "cheap", "cheap")
    eff = C.effort_for(conf, "cheap", "cheap")
    out_t = caps["out"] + A._THINK_HEADROOM.get(eff, 4096)
    return {"level": "normal", "ai_level": "", "tier": "cheap", "task_class": "cheap",
            "max_tokens": caps["out"], "models": [model], "in_tokens": caps["in"],
            "out_tokens": out_t,
            "credits": SC.credits_for([model], caps["in"], out_t, prices, usd)}


def score_price():
    return {lv: score_plan(lv)["credits"] for lv in SC.LEVELS}


def run_score(user, kind, system, task, data, keys, level, attempt_meta):
    """Charge -> call -> parse; refund on any failure. Returns the response dict."""
    from . import ai, billing
    from .models import LpAttempt
    base = {"ai_state": "", "credits_used": 0, "practice_label": B.PRACTICE_LABEL}
    ad_unlock = False
    if not is_premium(user):
        # free learner: only with a rewarded-ad unlock (Normal level, no credits)
        if ad_scores_left(user) <= 0:
            return dict(base, ai_state="premium", ads_needed=ads_needed("score"))
        ad_unlock, level = True, "normal"
    if not ai.available():
        return dict(base, ai_state="no_key")
    since = timezone.now() - datetime.timedelta(days=1)
    if LpAttempt.objects.filter(user=user, kind__in=("writing", "speaking"),
                                created_at__gte=since).count() >= SCORES_PER_DAY:
        return dict(base, ai_state="user_limit")
    plan = score_plan(level if level in SC.LEVELS else "normal")
    res = {"ok": True, "charged": 0} if ad_unlock else billing.charge(
        user, "lp_score_" + plan["level"], qty=1, note="lp." + kind,
        exact=plan["credits"], paid_only=plan["level"] == "best")
    if not res.get("ok"):
        return dict(base, ai_state="busy" if res.get("reason") == "guard_over" else "credits",
                    credits_needed=plan["credits"])
    charged = int(res.get("charged") or 0)
    meta = {}
    state, parsed = "used", None
    try:
        if plan["ai_level"]:
            text, _ = ai.generate(task=task, data=data, tier=plan["tier"], feature="lp.score",
                                  max_tokens=plan["max_tokens"], user=None, extra_system=system,
                                  out_meta=meta, pii=True, level=plan["ai_level"])
        else:
            with ai.only_provider("anthropic"):
                text, _ = ai.generate(task=task, data=data, tier=plan["tier"], feature="lp.score",
                                      max_tokens=plan["max_tokens"], user=None,
                                      extra_system=system, out_meta=meta, pii=True,
                                      task_class=plan["task_class"])
        if meta.get("truncated"):
            state = "cut"
        else:
            parsed = SC.parse(text, keys)
            if parsed is None:
                state = "unreadable"
    except ai.AIUnavailable as e:
        state = "no_key" if e.reason == "no_key" else "busy"
    except Exception:  # noqa: BLE001 — never a 500, never a charge for nothing
        log.warning("lp: score call failed", exc_info=True)
        state = "busy"
    if state != "used":
        if charged:
            billing.credit(user, "adjust", charged, note="ai_refund lp." + kind,
                           spend_ref=res.get("spend_ref") or None)
        return dict(base, ai_state=state, refunded=charged, level=plan["level"])
    att = LpAttempt.objects.create(user=user, kind=kind, item_key=attempt_meta.get("mock_id", ""),
                                   section=attempt_meta.get("section", ""), band=parsed["band"],
                                   credits=charged, data=dict(attempt_meta, result=parsed,
                                                              ad_unlock=ad_unlock))
    return dict(base, ai_state="used", credits_used=charged, level=plan["level"],
                attempt_id=att.id, **parsed)


# -------------------------------------------------------------- certificate
CERT_FOOTER = {
    "en": "Practice score — not an official IELTS or JLPT result.",
    "bn": "অনুশীলনের স্কোর — অফিসিয়াল IELTS বা JLPT ফল নয়।",
}


def certificate_pdf(att, name):
    """A one-page 'Assisto Practice Certificate' (reportlab + core.pdf_bn, so
    a Bangla learner name is shaped right)."""
    import io
    from reportlab.lib.pagesizes import A4, landscape
    from reportlab.pdfgen import canvas
    from . import pdf_bn
    page = landscape(A4)
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=page, pageCompression=0)
    c.setTitle("Assisto Practice Certificate")
    c.setAuthor("Assisto")
    c.setSubject(CERT_FOOTER["en"])
    w, h = page
    for i, col in enumerate(((0.0, 0.74, 0.83), (0.15, 0.39, 0.92), (0.49, 0.23, 0.93))):
        c.setStrokeColorRGB(*col)
        c.setLineWidth(4)
        c.rect(24 + i * 6, 24 + i * 6, w - 48 - i * 12, h - 48 - i * 12)
    c.setFillColorRGB(0.07, 0.09, 0.15)
    d = att.data or {}
    y = h - 110
    for size, text in ((30, "Assisto Practice Certificate"), (14, "This practice result belongs to"),
                       (26, (name or "Assisto learner")[:60]),
                       (16, "IELTS-style practice mock (%s)" % (
                           "General Training" if d.get("variant") == "general" else "Academic")),
                       (20, "Overall practice band: %s" % (att.band if att.band is not None else "-"))):
        pdf_bn.draw(c, w / 2, y, text, size, bold=size >= 20, align="center")
        y -= size + 22
    bands = d.get("bands") or {}
    line = "   ".join("%s %s" % (k.capitalize(), bands[k]) for k in SECTIONS if k in bands)
    pdf_bn.draw(c, w / 2, y, line, 14, align="center")
    y -= 30
    pdf_bn.draw(c, w / 2, y, "Date: %s" % timezone.localtime(att.created_at).date().isoformat(),
                14, align="center")
    c.setFillColorRGB(0.55, 0.11, 0.07)
    pdf_bn.draw(c, 60, 60, CERT_FOOTER["en"], 13, bold=True)
    c.showPage()
    c.save()
    return buf.getvalue()
