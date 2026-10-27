"""
world_service.py — the STATEFUL side of Unseen World (p4-world).

Pure logic lives in core/logic/world_feeds.py (feeds/cards), world_search.py
(web answers), world_content.py (hubs) and world_mcq.py (BCS practice). This
module does the HTTP calls, the shared server-side cache (WorldFeed rows),
credits / Profit Guard, the per-user prefs and the job alerts.

Every external call goes through `_fetch` (tests replace it with recorded
responses). Nothing here fabricates data: a source with no data is simply
absent from the response, and a key-gated source is hidden until its
Integrations entry is connected.
"""
import json
import logging
import urllib.error
import urllib.request
from datetime import timedelta

from django.utils import timezone

from .logic import world_content as WC
from .logic import world_feeds as WF
from .logic import world_mcq as MCQ
from .logic import world_search as WS

log = logging.getLogger(__name__)

TIMEOUT_S = 12
MAX_BYTES = 3 * 1024 * 1024


# ------------------------------------------------------------------ http seam
def _fetch(method, url, headers=None, body=None, timeout=TIMEOUT_S):
    """-> (status, bytes). Never follows to non-https. Raises on network error."""
    h = {"User-Agent": WF.USER_AGENT, "Accept-Encoding": "identity"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:   # noqa: S310 (fixed https hosts)
            return r.status, r.read(MAX_BYTES)
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read(65536)
        except Exception:
            return e.code, b""


def _json(raw):
    try:
        return json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
    except (ValueError, UnicodeDecodeError):
        return None


def _cfg():
    from . import billing
    from .logic import pricing
    return pricing.normalize(billing.cfg())


def world_cfg():
    return _cfg()["world"]


# ------------------------------------------------------------------ feed rows
def _feed(slug, kind, enabled_default=True):
    from .models import WorldFeed
    row, _ = WorldFeed.objects.get_or_create(
        slug=slug, defaults={"kind": kind, "enabled": enabled_default})
    return row


def _count_call(row, cost_usd=0.0, now=None):
    now = now or timezone.now()
    day = timezone.localdate(now)
    if row.calls_day != day:
        row.calls_day, row.calls_today, row.cost_usd_today = day, 0, 0.0
    row.calls_today += 1
    row.cost_usd_today = round(row.cost_usd_today + float(cost_usd or 0), 6)


def _calls_today(row, now=None):
    day = timezone.localdate(now or timezone.now())
    return row.calls_today if row.calls_day == day else 0


def _ok(row, payload, now=None):
    now = now or timezone.now()
    row.payload = payload
    row.fetched_at = row.last_ok_at = now
    row.ok_count += 1
    row.save()


def _err(row, msg, now=None):
    now = now or timezone.now()
    row.fetched_at = now          # back off: do not hammer a failing source
    row.last_error = str(msg)[:300]
    row.last_error_at = now
    row.error_count += 1
    row.save()


def _due(row, minutes, now=None):
    now = now or timezone.now()
    return row.fetched_at is None or now - row.fetched_at >= timedelta(minutes=minutes)


# ------------------------------------------------------------------ news
def refresh_news(force=False, now=None):
    """Fetch every enabled official RSS feed that is due. Returns {slug: ok}."""
    now = now or timezone.now()
    interval = world_cfg()["news_interval_min"]
    out = {}
    for meta in WF.NEWS_FEEDS:
        row = _feed(meta["slug"], "news", meta["on"])
        if not row.enabled or (not force and not _due(row, interval, now)):
            continue
        _count_call(row, 0.0, now)
        try:
            st, raw = _fetch("GET", meta["url"], {"Accept": "application/rss+xml, application/xml"})
            if st != 200:
                raise WF.FeedError("HTTP %s" % st)
            items = WF.parse_rss(raw, source_name=meta["name_en"])
            _ok(row, {"items": items}, now)
            out[meta["slug"]] = True
        except Exception as e:  # noqa: BLE001 — record, never crash the cron
            _err(row, e, now)
            out[meta["slug"]] = False
    return out


def _news_card(group, lang, now):
    from .models import WorldFeed
    rows = WorldFeed.objects.filter(kind="news", enabled=True)
    pairs = []
    for r in rows:
        meta = WF.NEWS_BY_SLUG.get(r.slug)
        if not meta:
            continue
        name = meta["name_bn"] if lang == "bn" else meta["name_en"]
        items = [dict(it, source=name) for it in (r.payload or {}).get("items") or []]
        pairs.append((r.slug, items))
    items = WF.news_card(pairs, group, now)
    return {"items": items} if items else None


# ------------------------------------------------------------------ currency
FX_URL = "https://open.er-api.com/v6/latest/USD"


def refresh_fx(force=False, now=None):
    now = now or timezone.now()
    row = _feed("fx_usd", "fx")
    if not row.enabled or (not force and not _due(row, 360, now)):
        return None
    _count_call(row, 0.0, now)
    try:
        st, raw = _fetch("GET", FX_URL, {"Accept": "application/json"})
        if st != 200:
            raise WF.FeedError("HTTP %s" % st)
        _ok(row, WF.parse_fx(_json(raw)), now)
        return True
    except Exception as e:  # noqa: BLE001
        _err(row, e, now)
        return False


# ------------------------------------------------------------------ weather
def _met_url(c):
    return ("https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=%.4f&lon=%.4f"
            % (c[3], c[4]))


def refresh_weather(city_slug, force=False, now=None):
    now = now or timezone.now()
    c = WF.city(city_slug)
    row = _feed("weather_" + c[0], "weather")
    if not row.enabled or (not force and not _due(row, 60, now)):
        return None
    _count_call(row, 0.0, now)
    try:
        st, raw = _fetch("GET", _met_url(c), {"Accept": "application/json"})
        if st != 200:
            raise WF.FeedError("HTTP %s" % st)
        _ok(row, WF.parse_met(_json(raw)), now)
        return True
    except Exception as e:  # noqa: BLE001
        _err(row, e, now)
        return False


# ------------------------------------------------------------------ sports
SPORTS = {
    "football": {"slug": "sports_football", "integration": "sports_football",
                 "url": "https://v3.football.api-sports.io/fixtures?live=all",
                 "headers": lambda k: {"x-apisports-key": k}, "parse": WF.parse_football},
    "cricket": {"slug": "sports_cricket", "integration": "sports_cricket",
                "url": "https://api.cricapi.com/v1/currentMatches?offset=0&apikey=%s",
                "headers": lambda k: {}, "parse": WF.parse_cricket},
}


def sports_ready(kind):
    from . import integrations as I
    meta = SPORTS[kind]
    return I.is_enabled(meta["integration"]) and bool(I.get(meta["integration"]).get("api_key"))


def _cost_per_call(cfg):
    try:
        return max(0.0, float(cfg.get("cost_per_call_usd") or 0))
    except (TypeError, ValueError):
        return 0.0


def refresh_sports(kind, force=False, now=None):
    """One shared call per interval, capped per day (admin-editable)."""
    from . import integrations as I
    now = now or timezone.now()
    meta = SPORTS[kind]
    if not sports_ready(kind):
        return None
    w = world_cfg()
    row = _feed(meta["slug"], "sports")
    if not row.enabled or (not force and not _due(row, w["sports_interval_min"], now)):
        return None
    if _calls_today(row, now) >= w["sports_max_calls_day"]:
        return None
    cfg = I.get(meta["integration"])
    key = cfg.get("api_key", "")
    url = meta["url"] % key if "%s" in meta["url"] else meta["url"]
    _count_call(row, _cost_per_call(cfg), now)
    try:
        st, raw = _fetch("GET", url, dict(meta["headers"](key), Accept="application/json"))
        if st != 200:
            raise WF.FeedError("HTTP %s" % st)
        _ok(row, {"matches": meta["parse"](_json(raw))}, now)
        if _cost_per_call(cfg):
            from . import billing
            billing.record_cost("ai", _cost_per_call(cfg) * float(_cfg()["usd_bdt"]))
        return True
    except Exception as e:  # noqa: BLE001
        _err(row, e, now)
        return False


def test_sports(kind, cfg):
    meta = SPORTS[kind]
    key = (cfg or {}).get("api_key", "")
    if not key:
        return (False, "API key missing")
    url = meta["url"] % key if "%s" in meta["url"] else meta["url"]
    try:
        st, raw = _fetch("GET", url, dict(meta["headers"](key), Accept="application/json"))
        if st != 200:
            return (False, "HTTP %s" % st)
        n = len(meta["parse"](_json(raw)))
        return (True, "✓ কাজ করছে / working — %d live" % n)
    except Exception as e:  # noqa: BLE001
        return (False, str(e)[:200])


# ------------------------------------------------------------------ admin values
def admin_rows():
    from .models import WorldAdminValue
    rows = {r.key: r for r in WorldAdminValue.objects.all()}
    out = []
    for key in WF.ADMIN_VALUES:
        r = rows.get(key)
        out.append({"key": key, "value": (float(r.value) if r and r.value is not None else None),
                    "effective_date": (r.effective_date.isoformat() if r and r.effective_date else ""),
                    "updated_at": (timezone.localtime(r.updated_at).date().isoformat() if r else ""),
                    "note": r.note if r else ""})
    return out


def set_admin_value(owner, key, value, effective_date=None, note=""):
    """Owner edit (the web view writes the OwnerAudit row). value None clears."""
    from .models import WorldAdminValue
    if key not in WF.ADMIN_VALUES:
        raise ValueError("unknown key")
    row, _ = WorldAdminValue.objects.get_or_create(key=key)
    before = {"value": float(row.value) if row.value is not None else None,
              "effective_date": row.effective_date.isoformat() if row.effective_date else ""}
    row.value = value
    row.effective_date = effective_date
    row.note = (note or "")[:200]
    row.updated_by = owner
    row.save()
    after = {"value": float(value) if value is not None else None,
             "effective_date": effective_date.isoformat() if effective_date else ""}
    return before, after


# ------------------------------------------------------------------ prefs
def prefs(user):
    from .models import WorldPrefs
    p, _ = WorldPrefs.objects.get_or_create(user=user)
    return p


def prefs_public(p):
    return {"cards": WF.merge_cards(p.cards), "city": WF.city(p.city)[0],
            "job_types": [t for t in (p.job_types or []) if t in WC.JOB_TYPE_IDS],
            "job_alerts": bool(p.job_alerts)}


def update_prefs(user, data):
    p = prefs(user)
    if isinstance(data.get("cards"), dict):
        merged = WF.merge_cards(p.cards)
        for k, v in data["cards"].items():
            if k in merged and isinstance(v, bool):
                merged[k] = v
        p.cards = merged
    if "city" in data:
        p.city = WF.city(str(data.get("city") or ""))[0]
    if isinstance(data.get("job_types"), list):
        p.job_types = [t for t in dict.fromkeys(str(x) for x in data["job_types"])
                       if t in WC.JOB_TYPE_IDS][:5]
    if "job_alerts" in data:
        p.job_alerts = bool(data.get("job_alerts"))
    p.save()
    return prefs_public(p)


# ------------------------------------------------------------------ readiness
def search_ready():
    from . import ai
    from . import integrations as I
    try:
        cfg = I.get("web_search")
        return I.is_enabled("web_search") and bool(WS.provider_of(cfg)) and ai.key_present()
    except Exception:
        return False


def careerjet_ready():
    from . import integrations as I
    return I.is_enabled("jobs_careerjet") and bool(I.get("jobs_careerjet").get("api_key"))


def config(user, lang):
    from . import billing
    from .logic import pricing
    p = prefs(user)
    cfg = billing.cfg()
    return {"search_ready": search_ready(),
            "web_answer_credits": pricing.credit_cost("web_answer", cfg),
            "sports": {k: sports_ready(k) for k in SPORTS},
            "job_alerts_ready": careerjet_ready(),
            "prefs": prefs_public(p),
            "cards": list(WF.CARDS),
            "cities": WF.cities_public(lang)}


# ------------------------------------------------------------------ Today
def today(user, lang, now=None):
    """Assemble every ON card that has real data. Absent data = absent card
    (with `hidden` listing why, so the app can say 'not available yet')."""
    from .logic import ramadan
    now = now or timezone.now()
    p = prefs(user)
    on = WF.merge_cards(p.cards)
    c = WF.city(p.city)
    cards, hidden = {}, {}

    if on["prayer"]:
        local = timezone.localtime(now)
        times = ramadan.prayer_times(local.date(), c[3], c[4], tz_offset_hours=6.0,
                                     asr=ramadan.ASR_HANAFI)
        cards["prayer"] = WF.prayer_card(times, local.strftime("%H:%M"))
        cards["prayer"]["method"] = "Karachi angles, Hanafi Asr"
    if on["weather"]:
        refresh_weather(c[0], now=now)
        row = _feed("weather_" + c[0], "weather")
        w = WF.weather_public(row.payload, lang) if row.enabled else None
        if w:
            cards["weather"] = w
        else:
            hidden["weather"] = "unavailable"
    if on["currency"]:
        refresh_fx(now=now)
        row = _feed("fx_usd", "fx")
        fx = WF.fx_public(row.payload, lang) if row.enabled else None
        if fx:
            nb, ne = fx.pop("note_bn"), fx.pop("note_en")
            fx["note"] = nb if lang == "bn" else ne
            cards["currency"] = fx
        else:
            hidden["currency"] = "unavailable"
    rows = admin_rows()
    for g in ("gold", "fuel"):
        if on[g]:
            card = WF.admin_card(g, rows, lang)
            if card:
                cards[g] = card
            else:
                hidden[g] = "not_entered"
    for grp, cid in (("bd", "news_bd"), ("world", "news_world")):
        if on[cid]:
            card = _news_card(grp, lang, now)
            if card:
                cards[cid] = card
            else:
                hidden[cid] = "unavailable"
    for kind in ("cricket", "football"):
        if not on[kind]:
            continue
        if not sports_ready(kind):
            hidden[kind] = "needs_key"
            continue
        refresh_sports(kind, now=now)
        row = _feed(SPORTS[kind]["slug"], "sports")
        m = (row.payload or {}).get("matches")
        if m is not None and row.enabled:
            cards[kind] = {"matches": m, "updated": row.last_ok_at.isoformat() if row.last_ok_at else "",
                           "source": "API-Football" if kind == "football" else "CricketData.org"}
        else:
            hidden[kind] = "unavailable"
    if "prayer" in cards:
        note = cards["prayer"].pop("note_bn"), cards["prayer"].pop("note_en")
        cards["prayer"]["note"] = note[0] if lang == "bn" else note[1]
    return {"city": {"id": c[0], "name": c[1] if lang == "bn" else c[2]},
            "cards": cards, "hidden": hidden, "on": on,
            "generated_at": now.isoformat()}


def refresh_all(now=None):
    """Cron entry (world_refresh): news, currency, weather for every city
    a user picked, live sports. Returns a short summary dict."""
    from .models import WorldPrefs
    now = now or timezone.now()
    out = {"news": refresh_news(now=now), "fx": refresh_fx(now=now)}
    cities = set(WorldPrefs.objects.values_list("city", flat=True)) | {"dhaka"}
    out["weather"] = {cy: refresh_weather(cy, now=now) for cy in sorted(cities) if cy}
    out["sports"] = {k: refresh_sports(k, now=now) for k in SPORTS}
    return out


# ------------------------------------------------------------------ web answer
def _search(cfg, question, lang):
    provider = WS.provider_of(cfg)
    method, url, headers, body = WS.build_request(provider, cfg, question, lang)
    st, raw = _fetch(method, url, headers, body)
    if st != 200:
        raise WS.SearchError("search HTTP %s" % st)
    doc = _json(raw)
    if doc is None:
        raise WS.SearchError("search returned no JSON")
    return provider, WS.parse(provider, doc)


def test_search(cfg):
    if not WS.provider_of(cfg):
        return (False, "provider + matching key needed (brave or tavily)")
    try:
        provider, rows = _search(cfg, "Bangladesh", "en")
        return (True, "✓ %s: %d results" % (provider, len(rows)))
    except Exception as e:  # noqa: BLE001
        return (False, str(e)[:200])


def _answers_today(user, now):
    from .models import WorldAnswer
    since = now - timedelta(hours=24)
    return WorldAnswer.objects.filter(user=user, created_at__gte=since).count()


def _msg(lang, bn, en):
    return bn if lang == "bn" else en


def web_answer(user, question, lang, now=None):
    """-> (http_status, body). Charges `web_answer` credits only when a new
    answer is generated; a recent identical question is served from cache."""
    from . import ai, billing
    from . import integrations as I
    from .models import WorldAnswer
    now = now or timezone.now()
    lang = "en" if lang == "en" else "bn"
    q = WS.normalize_question(question)
    if len(q) < 3:
        return 400, {"ok": False, "reason": "question_required",
                     "message": _msg(lang, "প্রশ্নটি লিখুন।", "Please type a question.")}
    if not search_ready():
        return 409, {"ok": False, "reason": "not_connected",
                     "message": _msg(lang, "লাইভ ওয়েব সার্চ এখনো চালু হয়নি।", "Live web search is not connected yet.")}
    w = world_cfg()
    h = WS.qhash(q, lang)
    if w["answer_cache_hours"]:
        hit = (WorldAnswer.objects.filter(qhash=h, lang=lang, cached=False,
                                          created_at__gte=now - timedelta(hours=w["answer_cache_hours"]))
               .order_by("-created_at").first())
        if hit:
            WorldAnswer.objects.create(user=user, qhash=h, lang=lang, question=q, answer=hit.answer,
                                       sources=hit.sources, provider=hit.provider, cached=True)
            return 200, {"ok": True, "answer": hit.answer, "sources": hit.sources,
                         "caution": WS.caution_notes(WS.caution_of(q), lang),
                         "cited": bool(hit.sources), "cached": True, "charged": 0,
                         "balance": int(user.ai_credits or 0)}
    if _answers_today(user, now) >= w["web_answers_per_day"]:
        return 429, {"ok": False, "reason": "daily_cap",
                     "message": _msg(lang, "আজকের ওয়েব-উত্তরের সীমা শেষ — কাল আবার চেষ্টা করুন।",
                                     "Today's web-answer limit is reached — try again tomorrow.")}
    allowed, reason = billing.guard_can(user, "web_answer")
    if not allowed:
        return 402, {"ok": False, "reason": reason,
                     "message": _msg(lang, "যথেষ্ট ক্রেডিট নেই — ক্রেডিট নিন বা প্রিমিয়ামে যান।",
                                     "Not enough credits — top up or go Premium.")
                     if reason == "insufficient" else
                     _msg(lang, "আজ এই সেবা সাময়িক বন্ধ — কাল আবার চেষ্টা করুন।",
                          "This service is paused for today — try again tomorrow.")}
    cfg = I.get("web_search")
    try:
        provider, results = _search(cfg, q, lang)
    except Exception as e:  # noqa: BLE001
        log.warning("world: search failed %s", type(e).__name__)
        return 502, {"ok": False, "reason": "search_failed",
                     "message": _msg(lang, "সার্চ সার্ভার এখন সাড়া দিচ্ছে না — একটু পরে চেষ্টা করুন। কোনো ক্রেডিট কাটা হয়নি।",
                                     "The search server isn't responding — try again shortly. No credits were used.")}
    search_cost = WS.cost_per_search(cfg, provider)
    billing.record_cost("ai", search_cost * float(_cfg()["usd_bdt"]))
    if not results:
        return 200, {"ok": True, "answer": WS.NO_RESULTS[lang], "sources": [], "cited": False,
                     "caution": [], "cached": False, "charged": 0,
                     "balance": int(user.ai_credits or 0)}
    task, data, extra = WS.build_prompt(q, results, lang, timezone.localdate(now).isoformat())
    try:
        text, llm_cost = ai.generate(task, data=data, tier="cheap", max_tokens=700,
                                     feature="world_web_answer", user=user,
                                     extra_system=extra, charge_action="web_answer")
    except ai.AIUnavailable as e:
        msg = {"credits": _msg(lang, "যথেষ্ট ক্রেডিট নেই।", "Not enough credits."),
               "user_limit": _msg(lang, "আজকের AI সীমা শেষ।", "Today's AI limit is reached."),
               "budget": _msg(lang, "আজ AI সাময়িক বন্ধ — কাল আবার চেষ্টা করুন।", "AI is paused for today — try tomorrow.")}
        return (402 if e.reason == "credits" else 503), {
            "ok": False, "reason": e.reason,
            "message": msg.get(e.reason, _msg(lang, "উত্তর তৈরি করা যায়নি — কোনো ক্রেডিট কাটা হয়নি।",
                                              "Couldn't make an answer — no credits were used."))}
    out = WS.finalize(text, results, q, lang)
    if not out["cited"]:
        # show the links we searched so the user can verify; say so honestly
        out["sources"] = [{"n": i, "title": r["title"], "url": r["url"], "site": r["site"]}
                          for i, r in enumerate(results[:3], 1)]
        out["caution"] = out["caution"] + [WS.UNCITED_NOTE[lang]]
    from .logic import pricing
    charged = pricing.credit_cost("web_answer", billing.cfg())   # generate() charged it
    WorldAnswer.objects.create(user=user, qhash=h, lang=lang, question=q, answer=out["answer"],
                               sources=out["sources"], provider=provider, cached=False,
                               credits=charged, cost_usd=round(search_cost + float(llm_cost or 0), 6))
    return 200, {"ok": True, "answer": out["answer"], "sources": out["sources"],
                 "caution": out["caution"], "cited": out["cited"], "cached": False,
                 "charged": charged, "balance": int(user.ai_credits or 0)}


# ------------------------------------------------------------------ hub AI help
def hub_ai(user, hub_id, question, lang):
    from . import ai
    lang = "en" if lang == "en" else "bn"
    task = WC.AI_TASK.get(hub_id)
    if not task:
        return 404, {"ok": False, "reason": "unknown_hub"}
    q = str(question or "").strip()[:800]
    if len(q) < 3:
        return 400, {"ok": False, "reason": "question_required",
                     "message": _msg(lang, "প্রশ্নটি লিখুন।", "Please type a question.")}
    if not ai.available():
        return 409, {"ok": False, "reason": "ai_off",
                     "message": _msg(lang, "AI সহায়তা এখনো চালু হয়নি।", "AI help is not switched on yet.")}
    full = task + " Reply in %s, short and practical." % ("Bangla" if lang == "bn" else "English")
    try:
        text, _cost = ai.generate(full, data=q, tier="cheap", max_tokens=700,
                                  feature="world_" + hub_id, user=user)
    except ai.AIUnavailable as e:
        return (402 if e.reason == "credits" else 503), {
            "ok": False, "reason": e.reason,
            "message": _msg(lang, "যথেষ্ট ক্রেডিট নেই।", "Not enough credits.") if e.reason == "credits"
            else _msg(lang, "এখন উত্তর দেওয়া যাচ্ছে না — কোনো ক্রেডিট কাটা হয়নি।", "Can't answer right now — no credits were used.")}
    note = WC.AI_TASK_NOTE[hub_id][0 if lang == "bn" else 1]
    from . import ai_guard     # aieval: no action claims, no cure / dose promises
    text, _flags = ai_guard.clean_assistant_answer(text, lang)
    return 200, {"ok": True, "answer": text.strip(), "note": note,
                 "balance": int(user.ai_credits or 0), "ai_generated": True}


# ------------------------------------------------------------------ MCQ
def mcq_history(user, limit=10):
    from .models import WorldMcqAttempt
    return [{"topic": a.topic, "total": a.total, "correct": a.correct,
             "at": a.created_at.isoformat()}
            for a in WorldMcqAttempt.objects.filter(user=user)[:limit]]


def mcq_submit(user, topic, answers, lang):
    from .models import WorldMcqAttempt
    res = MCQ.score(answers, lang)
    if res["total"]:
        t = topic if topic in MCQ.TOPICS or topic == "mixed" else "mixed"
        WorldMcqAttempt.objects.create(user=user, topic=t, total=res["total"], correct=res["correct"])
    res["history"] = mcq_history(user)
    return res


# ------------------------------------------------------------------ job alerts
CAREERJET_URL = "https://search.api.careerjet.net/v4/query"


def _careerjet_query(api_key, keywords, now=None):
    """One query per job type per day, cached in WorldFeed 'jobs_<type>'."""
    import base64
    from urllib.parse import urlencode
    params = {"locale_code": "en_BD", "keywords": keywords, "location": "Bangladesh",
              "sort": "date", "page_size": 10, "user_ip": "127.0.0.1",
              "user_agent": WF.USER_AGENT}
    auth = base64.b64encode(("%s:" % api_key).encode()).decode()
    st, raw = _fetch("GET", CAREERJET_URL + "?" + urlencode(params),
                     {"Authorization": "Basic " + auth, "Accept": "application/json"})
    if st != 200:
        raise WF.FeedError("HTTP %s" % st)
    return parse_careerjet(_json(raw))


def parse_careerjet(doc):
    """Careerjet JSON -> [{id, title, company, url}]. Title + link only."""
    if not isinstance(doc, dict) or doc.get("type") == "ERROR":
        raise WF.FeedError("careerjet error: %s" % (doc.get("error") if isinstance(doc, dict) else "bad payload"))
    out = []
    for j in doc.get("jobs") or []:
        url = str(j.get("url") or "")
        title = WF.clean_text(j.get("title") or "")[:160]
        if not title or not url.startswith("https://"):
            continue
        out.append({"id": url[-64:], "title": title,
                    "company": WF.clean_text(j.get("company") or "")[:80], "url": url})
    return out


def test_careerjet(cfg):
    key = (cfg or {}).get("api_key", "")
    if not key:
        return (False, "API key missing")
    try:
        rows = _careerjet_query(key, "officer")
        return (True, "✓ কাজ করছে / working — %d jobs" % len(rows))
    except Exception as e:  # noqa: BLE001
        return (False, str(e)[:200])


def _jobs_for(type_id, now):
    from . import integrations as I
    row = _feed("jobs_" + type_id, "jobs")
    if _due(row, 12 * 60, now):
        kw = next((j[3] for j in WC.JOB_TYPES if j[0] == type_id), type_id)
        _count_call(row, 0.0, now)
        try:
            _ok(row, {"jobs": _careerjet_query(I.get("jobs_careerjet").get("api_key", ""), kw)}, now)
        except Exception as e:  # noqa: BLE001
            _err(row, e, now)
    return (row.payload or {}).get("jobs") or []


def run_job_alerts(now=None, send=None):
    """Daily cron: at most `job_alerts_per_day` push per user, only for users
    who switched alerts on, only new jobs (title + link). Returns sent count."""
    from .models import WorldPrefs
    from . import push
    now = now or timezone.now()
    if not careerjet_ready():
        return 0
    cap = world_cfg()["job_alerts_per_day"]
    if cap <= 0:
        return 0
    send = send or push.push_to_user
    gap = timedelta(hours=24 / cap)
    sent = 0
    for p in WorldPrefs.objects.filter(job_alerts=True).select_related("user"):
        if p.last_job_alert_at and now - p.last_job_alert_at < gap:
            continue
        seen = set(p.seen_job_ids or [])
        job = None
        for t in p.job_types or []:
            if t not in WC.JOB_TYPE_IDS:
                continue
            job = next((j for j in _jobs_for(t, now) if j["id"] not in seen), None)
            if job:
                break
        if not job:
            continue
        send(p.user, "reminder", "নতুন চাকরি: " + job["title"], "New job: " + job["title"],
             job.get("company", ""), job.get("company", ""),
             data={"world": "jobs", "url": job["url"]})
        p.last_job_alert_at = now
        p.seen_job_ids = (list(seen) + [job["id"]])[-200:]
        p.save(update_fields=["last_job_alert_at", "seen_job_ids", "updated_at"])
        sent += 1
    return sent


# ------------------------------------------------------------------ owner status
def status_rows(now=None):
    """Owner Admin data-source table."""
    from .models import WorldFeed
    from . import integrations as I
    now = now or timezone.now()
    for meta in WF.NEWS_FEEDS:
        _feed(meta["slug"], "news", meta["on"])
    _feed("fx_usd", "fx")
    _feed("weather_dhaka", "weather")
    names = {m["slug"]: m["name_en"] for m in WF.NEWS_FEEDS}
    names.update({"fx_usd": "ExchangeRate-API (currency)", "sports_football": "API-Football",
                  "sports_cricket": "CricketData.org"})
    out = []
    for r in WorldFeed.objects.all():
        name = names.get(r.slug) or (("MET Norway — " + r.slug[8:]) if r.slug.startswith("weather_")
                                     else ("Careerjet — " + r.slug[5:]) if r.slug.startswith("jobs_") else r.slug)
        out.append({"slug": r.slug, "kind": r.kind, "name": name, "enabled": r.enabled,
                    "fetched_at": r.fetched_at, "last_ok_at": r.last_ok_at,
                    "last_error": r.last_error, "last_error_at": r.last_error_at,
                    "ok_count": r.ok_count, "error_count": r.error_count,
                    "calls_today": _calls_today(r, now),
                    "cost_usd_today": r.cost_usd_today if r.calls_day == timezone.localdate(now) else 0.0,
                    "items": len((r.payload or {}).get("items") or (r.payload or {}).get("matches")
                                 or (r.payload or {}).get("jobs") or (r.payload or {}).get("rates") or [])})
    keys = {s: I.is_enabled(s) for s in ("web_search", "sports_football", "sports_cricket", "jobs_careerjet")}
    from .models import WorldAnswer
    since = now - timedelta(hours=24)
    ans = WorldAnswer.objects.filter(created_at__gte=since)
    web = {"answers_24h": ans.filter(cached=False).count(),
           "cached_24h": ans.filter(cached=True).count(),
           "cost_usd_24h": round(sum(a.cost_usd for a in ans.filter(cached=False)), 4),
           "credits_24h": sum(a.credits for a in ans)}
    return {"feeds": out, "keys": keys, "web": web}


def set_feed_enabled(slug, on):
    from .models import WorldFeed
    row = WorldFeed.objects.filter(slug=slug).first()
    if not row:
        raise ValueError("unknown feed")
    before = row.enabled
    row.enabled = bool(on)
    row.save(update_fields=["enabled", "updated_at"])
    return before, row.enabled
