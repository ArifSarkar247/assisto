"""
chat_vision_service.py — the STATEFUL side of "image in chat" (h1-home).

Pure decisions: core/logic/chat_vision.py. Provider calls: core/vision_providers.py.

It REUSES Photo Studio's money rails (ps1) instead of a second ad ledger:
  * a detailed answer is a PhotoStudioJob with feature="chat_vision";
  * free users fund it with SSV-verified rewarded ads through
    photo_studio_service.issue_ticket + the shared /ads/ssv callback (only
    Google's signed callback verifies an ad), or with credits;
  * Premium/Business pay credits from the monthly pool (_debit), never an ad.

Privacy (owner order §4): the photo is only held in memory for the provider
call — never written to disk or the DB. The on-device text the phone read is
used for that one call and never stored. Only the final TEXT answer is kept
on the job row (so a retry/reload shows it).
"""
import base64

from django.utils import timezone

from . import photo_studio_service as S
from .i18n import pick
from .logic import chat_vision as CV
from .logic import photo_studio as PS

import logging
log = logging.getLogger("assisto.ai")

_NEEDS = {
    "vision_claude": ("Claude (Anthropic) API key + cost per image",
                      "Claude (Anthropic) API key ও ছবি প্রতি খরচ"),
    "vision_openai": ("OpenAI API key + cost per image", "OpenAI API key ও ছবি প্রতি খরচ"),
    "vision_gemini": ("Gemini API key + cost per image", "Gemini API key ও ছবি প্রতি খরচ"),
}


def cv_cfg(c=None):
    c = c or S._cfg()
    return CV.normalize_cfg(c.get("chat_vision"))


# ------------------------------------------------------------------ providers
# ailang (owner 3 Nov 23:20, PART 1a): vision used ONLY the separate
# vision_* integrations (key + cost per image), so with the Anthropic and
# Gemini keys saved (and passing Test connection) under the main AI entries,
# photo answers said "the owner must add a vision key". Now each vision
# provider falls back to the main AI key of the same company, with a
# conservative default cost per image. Order: Claude first, Gemini fallback,
# OpenAI only if its key exists.
_MAIN_KEY = {"vision_claude": "anthropic", "vision_gemini": "gemini", "vision_openai": "openai"}
_DEFAULT_COST_USD = {"vision_claude": 0.02, "vision_gemini": 0.004, "vision_openai": 0.015}
_ORDER = ("vision_claude", "vision_gemini", "vision_openai")


def _resolve(slug):
    """(connected, conf) for a vision provider: its own entry, else the main key."""
    from . import integrations
    try:
        if integrations.is_enabled(slug):
            conf = dict(integrations.get(slug) or {})
            if conf.get("api_key"):
                return True, conf
        main = _MAIN_KEY.get(slug)
        if main and integrations.is_enabled(main):
            key = (integrations.get(main) or {}).get("api_key")
            if key:
                return True, {"api_key": key, "cost_per_image_usd": _DEFAULT_COST_USD[slug],
                              "_from_main": main}
    except Exception:  # noqa: BLE001
        pass
    return False, {}


def providers_state(lang="bn", c=None):
    cv = cv_cfg(c)
    rows = []
    for slug in sorted(CV.PROVIDERS, key=lambda x: _ORDER.index(x) if x in _ORDER else 9):
        on, conf = _resolve(slug)
        cost = S._provider_cost(conf)
        en, bn = _NEEDS[slug]
        rows.append({"slug": slug, "connected": bool(on), "cost_usd": cost,
                     "ready": bool(on and cost > 0),
                     "needs": "" if (on and cost > 0) else pick(lang, bn, en)})
    active = None
    if cv["provider"]:
        active = next((r for r in rows if r["slug"] == cv["provider"] and r["ready"]), None)
    if active is None:
        active = next((r for r in rows if r["ready"]), None)
    for r in rows:
        r["active"] = bool(active and r["slug"] == active["slug"])
    return {"providers": rows, "active": active["slug"] if active else "",
            "ready": active is not None,
            "needs": "" if active else pick(
                lang,
                "বিস্তারিত ছবি-উত্তরের জন্য Integrations-এ Claude, OpenAI বা Gemini ভিশনের key ও ছবি প্রতি খরচ দরকার।",
                "Detailed photo answers need a Claude, OpenAI or Gemini vision key + cost per image in Integrations.")}


def _active(c=None):
    st = providers_state("en", c)
    if not st["ready"]:
        return "", {}, 0.0
    _on, conf = _resolve(st["active"])
    return st["active"], conf, S._provider_cost(conf)


def _fallbacks(active, c=None):
    """Ready providers after `active`, same or cheaper per image (never a costlier one)."""
    st = providers_state("en", c)
    cost = {r["slug"]: r["cost_usd"] for r in st["providers"] if r["ready"]}
    top = cost.get(active, 0)
    return [s for s in cost if s != active and cost[s] <= top]


# ------------------------------------------------------------------ quote
def used_today(user):
    """Free detailed answers taken via the ads route today."""
    from .models import PhotoStudioJob
    return PhotoStudioJob.objects.filter(
        user=user, feature=CV.FEATURE, funding="ads",
        created_at__date=timezone.localdate()).exclude(
            status__in=("refused", "expired")).count()


def quote(user, c=None):
    from .logic import pricing as P
    c = c or S._cfg()
    plan = S.plan_of(user)
    slug, _conf, prov_cost = _active(c)
    table = c["action_costs"].get(CV.ACTION) or {}
    cost_usd = max(prov_cost, float(table.get("provider_cost") or 0)) if slug else 0.0
    q = CV.funding_options(
        plan=plan, cost_usd=cost_usd, usd_bdt=c["usd_bdt"],
        table_credits=int(table.get("credits") or 0), net_floor=P.net_floor(c),
        credit_bdt=c["credit_bdt"], cfg=c.get("chat_vision"),
        ad_value=PS.ad_value_bdt(c.get("photo_studio"), c["ad_rewards"]),
        ad_share=PS.normalize_cfg(c.get("photo_studio"))["ad_value_share"],
        used_today=used_today(user) if plan == "free" else 0,
        guard_over=S._guard_over() if plan == "free" else False,
        provider_ready=bool(slug))
    q["provider"] = slug
    q["cost_usd"] = cost_usd
    return q


def funding_message(reason, lang):
    m = {
        "disabled": ("বিস্তারিত ছবি-উত্তর এখন বন্ধ আছে। ফোনে পড়া লেখা ও লেবেল দেখানো হচ্ছে।",
                     "Detailed photo answers are switched off right now. Showing what the phone read."),
        # ailang (PART 1b): users never see admin wording (keys, integrations, owner)
        "provider_missing": ("ছবির বিস্তারিত উত্তর এই মুহূর্তে দেওয়া যাচ্ছে না — একটু পরে আবার চেষ্টা করুন।",
                             "Detailed photo answers aren't available right now — please try again a little later."),
        "unpriced": ("এই উত্তরের খরচ জানা নেই, তাই চালানো হবে না।",
                     "This answer's cost isn't known, so it won't run."),
        "guard_over": ("আজকের ফ্রি বিস্তারিত উত্তর বন্ধ — কাল আবার চেষ্টা করুন, বা প্রিমিয়াম নিন।",
                       "Today's free detailed answers are paused — try tomorrow or go Premium."),
        "daily_used": ("আজকের ফ্রি বিস্তারিত উত্তর ব্যবহার হয়ে গেছে — ক্রেডিট বা প্রিমিয়াম দিয়ে চালিয়ে যান।",
                       "Today's free detailed answer is used — continue with credits or Premium."),
        "too_many_ads": ("এই উত্তরের খরচ বিজ্ঞাপনে মেটে না — ক্রেডিট বা প্রিমিয়াম লাগবে।",
                         "Ads can't cover this answer's cost — it needs credits or Premium."),
        "insufficient": ("যথেষ্ট ক্রেডিট নেই।", "Not enough credits."),
        "choose_funding": ("বিজ্ঞাপন না ক্রেডিট — একটি বেছে নিন।", "Choose ads or credits."),
        "identify_person": (CV.FACE_REFUSAL["bn"], CV.FACE_REFUSAL["en"]),
    }.get(reason)
    return pick(lang, m[0], m[1]) if m else ""


def client_config(user, lang="bn"):
    from . import ai_chat_guard as G
    c = S._cfg()
    cv = cv_cfg(c)
    q = quote(user, c)
    q["message"] = funding_message(q.get("reason", ""), lang) if q.get("reason") != "ok" else ""
    plan = S.plan_of(user)
    return {
        "plan": plan, "free": plan == "free", "enabled": cv["enabled"],
        "quote": q, "providers": G.friendly_needs(providers_state(lang, c), user, lang),
        "free_per_day": cv["free_detailed_per_day"],
        "max_image_kb": cv["max_image_kb"],
        "balance": int(getattr(user, "ai_credits", 0) or 0),
        "stores_images": False,
    }


# ------------------------------------------------------------------ jobs
def job_state(job, lang="bn"):
    out = S.job_state(job, lang)
    for k in ("preview", "has_result", "corner_mark"):
        out.pop(k, None)
    opts = job.options or {}
    out["answer"] = opts.get("answer", "")
    out["medicine"] = bool(opts.get("medicine"))
    out["kind"] = opts.get("kind", "")
    if "dishes" in opts:                       # p2food: food purpose
        out["dishes"] = opts.get("dishes") or []
    return out


def create_job(user, data, lang="bn"):
    """POST chat-vision/jobs. Safety first (face identification refused before
    any cost), then funding TAKEN (pool/credits) or awaited (ads)."""
    from .models import PhotoStudioJob
    question = str(data.get("question") or "")[:500]
    if CV.asks_identification(question):
        return 422, {"ok": False, "refused": True, "reason": "identify_person",
                     "message": funding_message("identify_person", lang)}
    from . import billing
    billing.ensure_monthly_pool(user)       # paid: this month's pool first
    c = S._cfg()
    q = quote(user, c)
    if not q.get("ok"):
        return 409, {"ok": False, "reason": q["reason"],
                     "message": funding_message(q["reason"], lang), "quote": q}
    via = str(data.get("via") or "")
    opt = next((o for o in q["options"] if o["via"] == via), None)
    if opt is None:
        if len(q["options"]) == 1 and q["options"][0]["via"] == "pool":
            opt = q["options"][0]
        else:
            return 409, {"ok": False, "reason": "choose_funding",
                         "message": funding_message(q["reason"] if q["reason"] != "ok"
                                                    else "choose_funding", lang),
                         "quote": q}
    job = PhotoStudioJob(user=user, feature=CV.FEATURE, prompt="",
                         options={}, flags={}, provider=q.get("provider", ""),
                         funding=opt["via"])
    if opt["via"] in ("credits", "pool"):
        if not S._debit(user, opt["credits"], "vision:chat",
                        allow_ad_wallet=S.is_free(user)):
            return 402, {"ok": False, "reason": "insufficient",
                         "message": funding_message("insufficient", lang), "quote": q}
        job.credits_charged = int(opt["credits"])
        job.revenue_bdt = float(opt["credits"]) * float(c["credit_bdt"])
        job.status = "funded"
        job.funded_at = timezone.now()
    else:   # ads — funded only by Google's signed SSV callbacks
        job.ads_required = int(opt["ads"])
        job.status = "awaiting_funds"
    job.save()
    return 201, {"ok": True, "job": job_state(job, lang), "quote": q}


def owned_job(user, pk):
    from .models import PhotoStudioJob
    return PhotoStudioJob.objects.filter(user=user, pk=pk, feature=CV.FEATURE).first()


def fund_with_credits(user, job, lang="bn"):
    """Ad failed to load -> pay with credits instead (full price; verified ads
    already watched stay booked as revenue — no partial free bypass)."""
    if job.status != "awaiting_funds":
        return 409, {"ok": False, "reason": "not_awaiting_funds", "job": job_state(job, lang)}
    c = S._cfg()
    q = quote(user, c)
    opt = next((o for o in q.get("options", []) if o["via"] == "credits"), None)
    if opt is None:
        return 409, {"ok": False, "reason": q.get("reason", "no_credit_option"),
                     "message": funding_message(q.get("reason", ""), lang)}
    if not S._debit(user, opt["credits"], "vision:chat", allow_ad_wallet=S.is_free(user)):
        return 402, {"ok": False, "reason": "insufficient",
                     "message": funding_message("insufficient", lang)}
    job.funding = "credits"
    job.credits_charged = int(opt["credits"])
    job.revenue_bdt = float(job.revenue_bdt or 0) + float(opt["credits"]) * float(c["credit_bdt"])
    job.status = "funded"
    job.funded_at = timezone.now()
    job.save()
    job.tickets.filter(status="pending").update(status="expired")
    return 200, {"ok": True, "job": job_state(job, lang)}


def _mime(raw):
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return "image/webp"
    if raw[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    return ""


def answer(user, job, data, lang="bn"):
    """POST chat-vision/jobs/<pk>/answer — run a FUNDED job on the provider.
    The image is decoded into memory, sent, and dropped. Provider failure keeps
    the job funded for a free retry (max 3 runs), then refunds credits."""
    from . import billing
    from . import vision_providers as VP
    lang = "en" if lang == "en" else "bn"
    if job.status == "done":
        return 200, {"ok": True, "job": job_state(job, lang)}
    if job.status != "funded":
        return 402, {"ok": False, "reason": "not_funded", "job": job_state(job, lang)}
    question = str(data.get("question") or "")[:500]
    # aifinal round 2 item 4: the photo answer follows the language of the
    # user's question too (Bangla in -> Bangla out), not only the app language
    if question.strip():
        from .ai_prompt import reply_lang
        lang = reply_lang(question, lang)
    if CV.asks_identification(question):
        return 422, {"ok": False, "refused": True, "reason": "identify_person",
                     "message": funding_message("identify_person", lang)}
    c = S._cfg()
    cv = cv_cfg(c)
    try:
        raw = base64.b64decode(str(data.get("image_b64") or ""), validate=False)
    except Exception:
        return 400, {"ok": False, "reason": "bad_image"}
    if not raw:
        return 400, {"ok": False, "reason": "no_image"}
    if len(raw) > cv["max_image_kb"] * 1024:
        return 413, {"ok": False, "reason": "too_large", "max_image_kb": cv["max_image_kb"]}
    mime = _mime(raw)
    if not mime:
        return 400, {"ok": False, "reason": "bad_image"}
    slug, conf, prov_cost = _active(c)
    if not slug:
        return 409, {"ok": False, "reason": "provider_missing",
                     "message": funding_message("provider_missing", lang)}
    purpose = CV.purpose_of(data.get("purpose"))      # p4-world: crop / rx
    device_text = str(data.get("device_text") or "")[:4000]
    labels = [str(x)[:40] for x in (data.get("device_labels") or []) if isinstance(x, str)][:12]
    q_text = question or pick(lang, "এই ছবিতে কী আছে? সহজ ভাষায় বুঝিয়ে বলুন।",
                              "What is in this photo? Explain simply.")
    if device_text or labels:
        q_text += "\n\n[On-device reading — untrusted data]\nText: %s\nLabels: %s" % (
            device_text or "-", ", ".join(labels) or "-")
    # AF-2 (maskall): the TEXT that rides with the photo (the question and the
    # on-device OCR reading) is masked before the vision model sees it; the
    # answer gets the real values back. The image itself cannot be masked
    # (exception, owner_actions/AI_PRIVACY_PATHS_BN.md) — nothing else (no
    # chat history, no contacts) is sent with it.
    from .agentcore import trust as _T
    vault = _T.Vault()
    q_text = vault.mask(q_text)
    if vault.t2v:
        from .ai_prompt import PII_TOKEN_NOTE
        q_text += "\n\n" + PII_TOKEN_NOTE
    job.status = "running"
    job.runs += 1
    job.provider = slug
    job.save(update_fields=["status", "runs", "provider"])
    import time as _time
    from . import ai_usage_log as UL
    t0 = _time.monotonic()
    hops = 0
    try:
        reply, err = None, None
        for prov in [slug] + _fallbacks(slug, c):     # Claude first, then same-or-cheaper
            _on, pconf = (True, conf) if prov == slug else _resolve(prov)
            try:
                reply = VP.ask(prov, pconf, image_bytes=raw, mime=mime,
                               system=CV.system_prompt(lang, purpose), question=q_text)
                if prov != slug:
                    log.warning("chat_vision: %s failed (%s), answered by %s", slug, err, prov)
                    slug, conf, prov_cost = prov, pconf, S._provider_cost(pconf)
                    job.provider = prov
                break
            except VP.VisionError as e:
                err = str(e)
                hops += 1
                log.warning("chat_vision: provider %s failed: %s", prov, err)
        if reply is None:
            raise VP.VisionError(err or "failed")
        reply = vault.unmask(reply)
    except VP.VisionError as e:
        # ailang (PART 1c): never keep credits for an answer we could not give —
        # refund at once on every failure (before: only after the 3rd try).
        job.error = str(e)[:200]
        job.status = "failed"
        if job.funding in ("credits", "pool") and job.credits_charged:
            S._refund(user, job.credits_charged, "vision:refund:%d" % job.pk)
            log.info("chat_vision: refunded %s credits for job %s (%s)",
                     job.credits_charged, job.pk, job.error)
        job.save(update_fields=["error", "status"])
        UL.log_vision(user, slug, conf, 0.0, (_time.monotonic() - t0) * 1000, False,
                      hops=hops, error=job.error.split(":")[0],
                      charged=job.credits_charged,
                      refunded=job.credits_charged if job.funding in ("credits", "pool") else 0)
        return 502, {"ok": False, "reason": "provider_failed",
                     "message": pick(lang, "এই মুহূর্তে ছবিটি পড়া গেল না — কোনো ক্রেডিট কাটা হয়নি। আবার চেষ্টা করুন।",
                                     "The photo couldn't be read right now — no credits were used. Please try again."),
                     "job": job_state(job, lang)}
    finally:
        del raw
    parsed = vault.unmask_obj(CV.parse_reply(reply))
    out = CV.postprocess(parsed, question=question,
                         device_text=device_text, lang=lang)
    table = c["action_costs"].get(CV.ACTION) or {}
    cost_usd = max(prov_cost, float(table.get("provider_cost") or 0))
    # only the TEXT answer is kept (no image, no device text, no question)
    out["answer"] = CV.add_purpose_note(out["answer"], purpose, lang)   # p4-world
    job.options = {"answer": out["answer"][:6000], "kind": out["kind"],
                   "medicine": out["medicine"], "doses_removed": out["doses_removed"],
                   "face_refused": out["face_refused"]}
    if purpose == "food":                      # p2food: ids from our table only
        from .logic import food_calories as FC
        job.options["dishes"] = FC.parse_dishes(reply)
    job.cost_bdt = cost_usd * float(c["usd_bdt"])
    job.status = "done"
    job.done_at = timezone.now()
    job.error = ""
    job.save()
    billing.record_cost("ai", job.cost_bdt)
    UL.log_vision(user, slug, conf, cost_usd, (_time.monotonic() - t0) * 1000, True,
                  hops=hops, charged=job.credits_charged)
    _save_to_chat(user, data.get("session_id"), job, question,
                  dict(out, label_text=str(parsed.get("label_text") or "")), lang)
    return 200, {"ok": True, "job": job_state(job, lang)}


def _save_to_chat(user, session_id, job, question, out, lang):
    """aifinal round 2 items 2 + 3 + 5: a photo + question asked in an AI chat
    becomes ONE user turn + ONE answer turn of that chat, so every later turn
    has the photo in its context (the stored vision description — never the
    image bytes) and the answer bubble shows the credits this photo really
    took (= the ledger row). Never raises."""
    if not session_id:
        return
    try:
        from .models import ChatMessage, ChatSession
        s = ChatSession.objects.filter(id=session_id, user=user).first()
        if s is None:
            return
        seen = (out.get("label_text") or "")[:800]
        q = question.strip() or pick(lang, "এই ছবিতে কী আছে?", "What is in this photo?")
        first = not s.messages.filter(role="user").exists()
        ChatMessage.objects.create(session=s, role="user", text="[photo] " + q,
                                   meta={"photo_job": job.pk, "photo": True})
        if first:
            s.derive_title(q)
        from . import ai_chat_guard as G
        ChatMessage.objects.create(session=s, role="assistant", text=out["answer"], meta={
            "source": "ai", "photo_job": job.pk, "ai_generated": True, "photo_text": seen,
            "credits": int(job.credits_charged or 0) if job.funding in ("credits", "pool") else 0,
            "funding": job.funding, "balance": G.balance(user)})
        s.save()
    except Exception:  # noqa: BLE001
        log.exception("chat_vision: could not save the photo turn to the chat")
