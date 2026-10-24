"""
photo_studio_service.py — the STATEFUL side of Photo Studio (ps1-photo).

Pure decisions live in core/logic/photo_studio.py; this module owns the DB, the
clock, the atomic debit, the AdMob SSV verification and the provider call.

Money rules (owner order):
  * Funding is decided AND TAKEN before any cost is incurred.
  * Free users: N rewarded ads (only Google's signed SSV callback verifies an
    ad — a no-fill, a dismissed ad or a client claim never counts) or credits.
    No free bypass, ever. Premium/Business: no ads, monthly pool credits.
  * A cloud job is never run if it cannot be priced (no provider cost).
  * Every image that leaves the studio goes through unlock() — one gate for
    save / share / wallpaper / copy / open-in.
"""
import base64
import io
import os
import secrets
import uuid
from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.db.models import F
from django.utils import timezone

from .i18n import pick
from .logic import photo_studio as PS

SSV_KEYS_URL = "https://www.gstatic.com/admob/reward/verifier-keys.json"
MEDIA_DIR = "photo_studio"
MAX_UPLOAD_BYTES = 8 * 1024 * 1024


# ------------------------------------------------------------------ config
def _cfg():
    from . import billing
    return billing.cfg()


def ps_cfg(c=None):
    c = c or _cfg()
    return PS.normalize_cfg(c.get("photo_studio"))


def plan_of(user):
    from . import plans
    try:
        p = plans.effective_plan(user)
    except Exception:
        p = "free"
    return "free" if p == "free" else p


def is_free(user):
    return plan_of(user) == "free"


def photo_worker_enabled():
    from . import photo_worker
    return photo_worker.enabled()


# ------------------------------------------------------------------ providers
_PROVIDER_NEEDS = {
    "photo_gemini": ("Gemini API key + cost per image", "Gemini API key ও ছবি প্রতি খরচ"),
    "photo_openai": ("OpenAI API key + cost per image", "OpenAI API key ও ছবি প্রতি খরচ"),
    "photo_replicate": ("Replicate API token + model + cost per image",
                        "Replicate API token, মডেল ও ছবি প্রতি খরচ"),
}


def _provider_cost(conf):
    try:
        return max(0.0, float((conf or {}).get("cost_per_image_usd") or 0))
    except (TypeError, ValueError):
        return 0.0


def providers_state(lang="bn", c=None):
    """Honest per-provider state: connected? cost set? which one is active."""
    from . import integrations
    ps = ps_cfg(c)
    rows = []
    for slug in PS.PROVIDERS:
        try:
            on = integrations.is_enabled(slug)
            conf = integrations.get(slug) if on else {}
        except Exception:
            on, conf = False, {}
        cost = _provider_cost(conf)
        needs_en, needs_bn = _PROVIDER_NEEDS[slug]
        rows.append({"slug": slug, "connected": bool(on), "cost_usd": cost,
                     "ready": bool(on and cost > 0),
                     "needs": "" if (on and cost > 0) else pick(lang, needs_bn, needs_en)})
    active = None
    if ps["provider"]:
        active = next((r for r in rows if r["slug"] == ps["provider"] and r["ready"]), None)
    if active is None:
        active = next((r for r in rows if r["ready"]), None)
    for r in rows:
        r["active"] = bool(active and r["slug"] == active["slug"])
    return {"providers": rows, "active": active["slug"] if active else "",
            "ready": active is not None,
            "needs": "" if active else pick(
                lang, "ক্লাউড এডিটের জন্য Integrations-এ একটি ইমেজ প্রোভাইডারের key ও ছবি প্রতি খরচ দরকার।",
                "Cloud edits need an image provider key + cost per image in Integrations.")}


def _active_provider(c=None):
    from . import integrations
    st = providers_state("en", c)
    if not st["ready"]:
        return None, {}, 0.0
    slug = st["active"]
    conf = integrations.get(slug)
    return slug, conf, _provider_cost(conf)


# ------------------------------------------------------------------ quotes
def trials_used_today(user):
    from .models import PhotoStudioJob
    return PhotoStudioJob.objects.filter(
        user=user, trial=True, funding="ads",
        created_at__date=timezone.localdate()).exclude(
            status__in=("refused", "expired")).count()


def usage_of(user):
    """d1-photo v2 usage counters for the pricing rules (no side effects)."""
    from .models import PhotoStudioJob
    now = timezone.now()
    live = PhotoStudioJob.objects.filter(user=user).exclude(status__in=("refused", "expired"))
    return {
        "enhance_today": live.filter(feature="enhance_server",
                                     created_at__date=timezone.localdate()).count(),
        "gen_lifetime": live.filter(feature__in=PS.TRIAL_FEATURES, funding="gift").count(),
        "gen_week": live.filter(feature__in=PS.TRIAL_FEATURES, funding="ads",
                                created_at__gte=now - timedelta(days=7)).count(),
    }


def _guard_over():
    from . import billing
    try:
        return bool(billing.guard_state()["over"])
    except Exception:
        return False


def quote(user, feature, c=None, device_key=""):
    """funding_options for this user right now (no side effects)."""
    c = c or _cfg()
    from .logic import pricing as P
    plan = plan_of(user)
    cost_usd = 0.0
    provider_ready = True
    slug = ""
    usage = None
    if feature == PS.ULTRA_FEATURE:
        # photo-final: Ultra HD on fal.ai — Premium only, monthly quota
        from . import photo_final as PFN
        conf = PFN.ultra_conf()
        provider_ready = conf is not None and photo_worker_enabled()
        cost_usd = PFN.ultra_cost_usd(conf) if provider_ready else 0.0
        slug = "fal" if provider_ready else ""
        usage = PFN.ultra_usage(user) if plan != "free" else {}
    elif feature in PS.RESTORE_FEATURES or feature in PS.WORKER_FEATURES:
        # d1-photo: our photo worker (CPU) or the key-gated GPU API
        from . import photo_restore
        st = photo_restore.status(feature, "en")
        provider_ready = st["ready"]
        slug = photo_restore.GPU_SLUG if st["where"] == "gpu" else "server_cpu"
        table = (c["action_costs"].get(PS.FEATURE_ACTION[feature]) or {})
        cost_usd = max(st["cost_usd"], float(table.get("provider_cost") or 0)) if provider_ready else 0.0
    elif feature in PS.CLOUD_FEATURES:
        slug, _conf, prov_cost = _active_provider(c)
        provider_ready = bool(slug)
        table = (c["action_costs"].get(PS.FEATURE_ACTION[feature]) or {})
        # the larger of the provider's own cost and the pricing table estimate
        cost_usd = max(prov_cost, float(table.get("provider_cost") or 0)) if slug else 0.0
    table_credits = int((c["action_costs"].get(PS.FEATURE_ACTION.get(feature, ""))
                         or {}).get("credits") or 0)
    if feature in PS.WORKER_FEATURES:
        usage = usage_of(user)
        if plan == "free":
            # photo-final: free enhances per account AND device (reinstall-proof)
            from . import photo_final as PFN
            usage.update(PFN.enhance_usage(user, device_key))
    elif usage is None and plan == "free" and feature in PS.TRIAL_FEATURES:
        usage = usage_of(user)
    q = PS.funding_options(
        feature=feature, plan=plan, cost_usd=cost_usd, usd_bdt=c["usd_bdt"],
        table_credits=table_credits, net_floor=P.net_floor(c),
        credit_bdt=c["credit_bdt"], ps_cfg=c.get("photo_studio"),
        ad_rewards=c["ad_rewards"], trials_used_today=trials_used_today(user),
        guard_over=_guard_over() if plan == "free" else False,
        provider_ready=provider_ready, usage=usage)
    q["provider"] = slug
    q["feature"] = feature
    return q


# ------------------------------------------------------------------ messages
def refusal_message(reason, lang):
    m = {
        "sexual": ("যৌন বা কাপড় খোলার মতো এডিট করা হয় না।",
                   "Sexual or undressing edits are not allowed."),
        "fake_scene": ("বাস্তব মানুষকে ভুয়া বা অসম্মানজনক দৃশ্যে বসানো বা মুখ বদলানো হয় না।",
                       "We don't put real people into fake or compromising scenes, or swap faces."),
        "document_fraud": ("পরিচয়পত্র, সনদ, নথির লেখা, টাকা বা সরকারি সিল এডিট করা হয় না — এটা প্রতারণা হতে পারে।",
                           "ID cards, certificates, document text, money and official seals are never edited — that could be fraud."),
        "identity_change": ("মুখের গঠন, চোখ-নাক-ঠোঁটের আকার, গায়ের রং, বয়স বা লিঙ্গ বদলানো হয় না — আপনি আপনিই থাকবেন।",
                            "We never change face shape, eye/nose/lip size, skin colour, age or gender — you stay you."),
        "beauty_not_allowed": ("এই বিউটি অপশনটি অনুমোদিত তালিকায় নেই।",
                               "That beauty option is not on the allowed list."),
        "child_beauty": ("শিশুর ছবিতে বিউটি রিটাচ করা হয় না।",
                         "Beauty retouch is not available for children's photos."),
        "child_generation": ("শিশুর ছবি দিয়ে নতুন ছবি তৈরি করা হয় না।",
                             "We don't generate new images of children."),
        "child_suggestive": ("শিশুর ছবিতে এমন এডিট করা হয় না।",
                             "We don't make edits like this to photos of children."),
        "consent_needed": ("অন্য মানুষের ছবি AI দিয়ে বদলাতে তাঁদের অনুমতি লাগবে — অনুমতি আছে তা নিশ্চিত করুন।",
                           "Editing other people with AI needs their permission — confirm you have it."),
        "bad_option": ("অজানা অপশন।", "Unknown option."),
    }.get(reason, ("এই এডিট করা যাবে না।", "This edit isn't allowed."))
    return pick(lang, m[0], m[1])


def funding_message(reason, lang):
    m = {
        "busy": ("সার্ভার এখন ব্যস্ত — একটু পরে আবার চেষ্টা করুন।",
                 "The server is busy — try again in a moment."),
        "provider_missing": ("ক্লাউড এডিট এখনো চালু হয়নি — মালিককে Integrations-এ ইমেজ প্রোভাইডার যোগ করতে হবে।",
                             "Cloud editing isn't switched on yet — the owner must connect an image provider in Integrations."),
        "unpriced": ("এই কাজের খরচ জানা নেই, তাই চালানো হবে না।",
                     "This job's cost isn't known, so it won't run."),
        "guard_over": ("আজকের ফ্রি ক্লাউড এডিট সীমা শেষ — কাল আবার চেষ্টা করুন, বা প্রিমিয়াম নিন।",
                       "Today's free cloud edits are paused — try tomorrow or go Premium."),
        "trial_used": ("আজকের ফ্রি ট্রায়াল ব্যবহার হয়ে গেছে — ক্রেডিট বা প্রিমিয়াম দিয়ে চালিয়ে যান।",
                       "Today's free trial is used — continue with credits or Premium."),
        "too_many_ads": ("এই কাজের খরচ বিজ্ঞাপনে মেটে না — ক্রেডিট বা প্রিমিয়াম লাগবে।",
                         "Ads can't cover this job's cost — it needs credits or Premium."),
        "insufficient": ("যথেষ্ট ক্রেডিট নেই।", "Not enough credits."),
        "unknown_feature": ("অজানা কাজ।", "Unknown job."),
        "daily_limit": ("আজকের ফ্রি HD এনহ্যান্স শেষ — কাল আবার পাবেন, বা প্রিমিয়াম নিন।",
                        "Today's free HD enhances are used — more tomorrow, or go Premium."),
        "fair_use_cap": ("আজকের ন্যায্য-ব্যবহার সীমা শেষ — কাল আবার চেষ্টা করুন।",
                         "Today's fair-use limit is reached — try again tomorrow."),
        "week_used": ("এই সপ্তাহের ফ্রি AI ছবি ব্যবহার হয়ে গেছে — ক্রেডিট বা প্রিমিয়াম দিয়ে চালিয়ে যান।",
                      "This week's free AI image is used — continue with credits or Premium."),
        # photo-final
        "week_free_used": ("এই সপ্তাহের ফ্রি HD এনহ্যান্স ব্যবহার হয়ে গেছে — আগামী সপ্তাহে আবার পাবেন, বা প্রিমিয়াম নিন।",
                           "This week's free HD enhance is used — next one next week, or go Premium."),
        "premium_only": ("Ultra HD শুধু প্রিমিয়াম/বিজনেস প্ল্যানে।",
                         "Ultra HD is for Premium / Business plans."),
        "ultra_quota": ("এই মাসের Ultra HD শেষ — আগামী মাসে আবার পাবেন।",
                        "This month's Ultra HD images are used — more next month."),
    }.get(reason)
    return pick(lang, m[0], m[1]) if m else ""


# ------------------------------------------------------------------ debit
def _debit(user, credits, note, *, allow_ad_wallet):
    """Atomic debit of `credits` from User.ai_credits (then the ad wallet for
    free users). Unlike billing.charge this ALSO debits paid plans: Premium /
    Business Photo Studio cloud jobs come out of the monthly pool."""
    from .models import AdWallet, CreditLedger, User
    credits = int(credits or 0)
    if credits <= 0:
        return True
    with transaction.atomic():
        locked = User.objects.select_for_update().get(pk=user.pk)
        bal = int(locked.ai_credits or 0)
        wallet = None
        ad = 0
        if allow_ad_wallet:
            wallet = AdWallet.objects.select_for_update().get_or_create(user=locked)[0]
            ad = wallet.spendable_credits()
        if bal + ad < credits:
            return False
        from_bal = min(bal, credits)
        from_ad = credits - from_bal
        if from_bal:
            User.objects.filter(pk=locked.pk).update(ai_credits=F("ai_credits") - from_bal)
            CreditLedger.objects.create(user=locked, delta=-from_bal, reason="consume",
                                        note=note[:120])
        if from_ad:
            AdWallet.objects.filter(pk=wallet.pk).update(
                balance_paisa=F("balance_paisa") - from_ad * 100)
            CreditLedger.objects.create(user=locked, delta=-from_ad, reason="ad_spend",
                                        note=note[:120])
    user.refresh_from_db(fields=["ai_credits"])
    return True


def _refund(user, credits, note):
    from . import billing
    if credits > 0:
        billing.credit(user, "adjust", credits, note=note)


# ------------------------------------------------------------------ jobs
def create_job(user, data, lang="bn"):
    """POST photo-studio/jobs. Safety first, then funding (taken now).

    Returns (http_status, payload)."""
    from .models import PhotoStudioJob
    feature = str(data.get("feature") or "")
    if feature not in PS.FEATURES:
        return 400, {"ok": False, "reason": "unknown_feature",
                     "message": funding_message("unknown_feature", lang)}
    prompt = str(data.get("prompt") or "")[:500]
    tpl = template_prompt(str(data.get("template") or ""))
    if tpl:   # d1-photo v2: server-owned template prompts (+ the user's own words)
        prompt = (tpl + " " + prompt).strip()[:500]
    options = [o for o in (data.get("options") or []) if isinstance(o, str)][:12]
    beauty = [b for b in (data.get("beauty") or []) if isinstance(b, str)][:12]
    strength = data.get("strength") if data.get("strength") in PS.STRENGTHS else PS.DEFAULT_STRENGTH
    verdict = PS.classify(prompt, options, beauty_ops=beauty,
                          photo_kind=str(data.get("photo_kind") or ""),
                          child_in_photo=bool(data.get("child_in_photo")),
                          others_in_photo=bool(data.get("others_in_photo")),
                          own_photo=bool(data.get("own_photo", True)),
                          feature=feature,
                          consent=data.get("consent") if isinstance(data.get("consent"), bool) else None)
    if not verdict["allowed"]:
        PhotoStudioJob.objects.create(
            user=user, feature=feature, prompt="", status="refused",
            options={"options": options, "beauty": beauty},
            error=verdict["reason"], flags=verdict["flags"])
        return 422, {"ok": False, "refused": True, "reason": verdict["reason"],
                     "message": refusal_message(verdict["reason"], lang),
                     "flags": verdict["flags"]}

    from . import billing
    billing.ensure_monthly_pool(user)       # paid: this month's pool first
    c = _cfg()
    from . import photo_final as PFN
    dkey = PFN.device_key(data.get("device_id"))
    q = quote(user, feature, c, device_key=dkey)
    if not q.get("ok"):
        return 409, {"ok": False, "reason": q["reason"],
                     "message": funding_message(q["reason"], lang), "quote": q}
    via = str(data.get("via") or "")
    opt = next((o for o in q["options"] if o["via"] == via), None)
    if opt is None:
        # paid plans have exactly one route; free users must pick ads/credits
        if len(q["options"]) == 1 and q["options"][0]["via"] in ("pool", "free"):
            opt = q["options"][0]
        else:
            return 409, {"ok": False, "reason": "choose_funding",
                         "message": funding_message(q["reason"], lang), "quote": q}

    job_opts = {"options": options, "beauty": beauty, "strength": strength}
    if feature == "old_restore":
        job_opts["restore_colorize"] = data.get("restore_colorize") is not False
    if feature in PS.WORKER_FEATURES:
        job_opts["bg_blur"] = data.get("bg_blur") is True      # photo-final portrait blur
    flags = dict(verdict["flags"] or {})
    if feature in PS.WORKER_FEATURES and opt["via"] == "gift":
        flags["free_kind"] = q.get("free_kind", "lifetime")
    job = PhotoStudioJob(
        user=user, feature=feature, prompt=prompt,
        options=job_opts,
        flags=flags, provider=q.get("provider", ""),
        cost_bdt=0.0, funding=opt["via"], device_key=dkey)
    note = "photo:%s" % feature
    if feature in PS.WORKER_FEATURES and opt["via"] == "gift":
        # photo-final: a free enhance — re-checked under a row lock so two
        # parallel requests can never both take the last free one
        from .models import User
        with transaction.atomic():
            User.objects.select_for_update().get(pk=user.pk)
            q2 = quote(user, feature, c, device_key=dkey)
            if not (q2.get("ok") and any(o["via"] == "gift" for o in q2["options"])):
                return 409, {"ok": False, "reason": q2.get("reason", "week_free_used"),
                             "message": funding_message(q2.get("reason", ""), lang), "quote": q2}
            job.status = "funded"
            job.funded_at = timezone.now()
            job.save()
        return 201, {"ok": True, "job": job_state(job, lang), "quote": q2}
    if opt["via"] in ("free", "gift"):
        # gift = one of the free user's lifetime free AI generations (owner
        # decision; its real cost is tracked by the free-tier Profit Guard)
        job.trial = opt["via"] == "gift"
        job.status = "funded"
        job.funded_at = timezone.now()
    elif opt["via"] in ("credits", "pool"):
        if not _debit(user, opt["credits"], note,
                      allow_ad_wallet=is_free(user)):
            return 402, {"ok": False, "reason": "insufficient",
                         "message": funding_message("insufficient", lang), "quote": q}
        job.credits_charged = int(opt["credits"])
        job.revenue_bdt = float(opt["credits"]) * float(c["credit_bdt"])
        job.status = "funded"
        job.funded_at = timezone.now()
    elif opt["via"] == "ads":
        job.ads_required = int(opt["ads"])
        job.trial = bool(opt.get("trial"))
        job.status = "awaiting_funds"
    job.save()
    # (credit revenue was booked when the pack was sold — never double-booked)
    return 201, {"ok": True, "job": job_state(job, lang), "quote": q}


def fund_with_credits(user, job, lang="bn"):
    """Switch an ads-awaiting job to credits (the 'ad failed to load -> use
    credits' path). Any ads already verified are kept as revenue; the full
    credit price is still charged — there is no partial free bypass."""
    if job.status != "awaiting_funds":
        return 409, {"ok": False, "reason": "not_awaiting_funds", "job": job_state(job, lang)}
    q = quote(user, job.feature)
    opt = next((o for o in q.get("options", []) if o["via"] == "credits"), None)
    if not q.get("ok") or opt is None:
        return 409, {"ok": False, "reason": q.get("reason", "no_credit_option"),
                     "message": funding_message(q.get("reason", ""), lang)}
    if not _debit(user, opt["credits"], "photo:%s" % job.feature,
                  allow_ad_wallet=is_free(user)):
        return 402, {"ok": False, "reason": "insufficient",
                     "message": funding_message("insufficient", lang), "quote": q}
    c = _cfg()
    job.funding = "credits"
    job.trial = False
    job.credits_charged = int(opt["credits"])
    job.revenue_bdt = float(job.revenue_bdt or 0) + float(opt["credits"]) * float(c["credit_bdt"])
    job.status = "funded"
    job.funded_at = timezone.now()
    job.save()
    job.tickets.filter(status="pending").update(status="expired")
    return 200, {"ok": True, "job": job_state(job, lang)}


def _owned_job(user, pk):
    from .models import PhotoStudioJob
    return PhotoStudioJob.objects.filter(user=user, pk=pk).first()


def _verified_count(job):
    return job.tickets.filter(kind="rewarded", status="verified").count()


def job_state(job, lang="bn"):
    verified = _verified_count(job) if job.pk else 0
    out = {
        "id": job.pk, "feature": job.feature, "status": job.status,
        "funding": job.funding, "trial": job.trial,
        "ads_required": job.ads_required, "ads_verified": verified,
        "ads_remaining": max(0, job.ads_required - verified) if job.funding == "ads" else 0,
        "credits_charged": job.credits_charged, "provider": job.provider,
        "flags": job.flags or {}, "error": job.error,
        "has_result": bool(job.result_name),
        "corner_mark": is_free(job.user),
    }
    if job.preview_name:
        out["preview"] = _signed(job.preview_name)
    if job.status == "queued":
        from . import photo_worker
        out["queue_position"] = photo_worker.queue_position(job)
    fl = (job.flags or {}).get("face_lock")
    if isinstance(fl, dict):
        out["face_lock"] = fl
    return out


def _signed(name):
    from .media_sign import signed_url
    return signed_url(name)


# ------------------------------------------------------------------ ad tickets
def issue_ticket(user, job, lang="bn"):
    """A rewarded-ad ticket for one ad of an ads-funded job. The app hands
    `custom_data` (= nonce) and `user_id` to AdMob's ServerSideVerification
    options; only the signed SSV callback can verify it."""
    from .models import PhotoAdTicket
    if job.funding != "ads" or job.status != "awaiting_funds":
        return 409, {"ok": False, "reason": "not_awaiting_ads"}
    if _verified_count(job) >= job.ads_required:
        return 409, {"ok": False, "reason": "already_funded"}
    c = _cfg()
    ps = ps_cfg(c)
    cutoff = timezone.now() - timedelta(minutes=ps["ticket_ttl_min"])
    PhotoAdTicket.objects.filter(job=job, status="pending",
                                 created_at__lt=cutoff).update(status="expired")
    # never more open tickets than ads still needed (no farming)
    open_n = job.tickets.filter(status="pending").count()
    if open_n + _verified_count(job) >= job.ads_required:
        t = job.tickets.filter(status="pending").order_by("-created_at").first()
    else:
        t = PhotoAdTicket.objects.create(user=user, job=job, kind="rewarded",
                                         placement="job",
                                         nonce=secrets.token_urlsafe(24))
    units = _ad_units()
    return 201, {"ok": True, "nonce": t.nonce, "custom_data": t.nonce,
                 "user_id": str(user.pk), "rewarded_unit": units.get("rewarded", ""),
                 "ads_configured": units.get("_configured", False),
                 "job": job_state(job, lang)}


def _ad_units():
    from . import integrations
    from .logic import ads as A
    try:
        conf = integrations.get("admob")
        working = integrations.is_enabled("admob")
    except Exception:
        conf, working = {}, False
    ok, _ = A.validate_admob_ids(conf)
    configured = bool(working and ok)
    out = {"_configured": configured}
    for field, key in A.UNIT_FIELDS.items():
        out[key] = str(conf.get(field) or "").strip() if configured else ""
    return out


def _ssv_keys(force=False):
    """Google's AdMob SSV public keys {key_id(str): pem}. Cached 12h."""
    from django.core.cache import cache
    if not force:
        cached = cache.get("ps1_ssv_keys")
        if cached:
            return cached
    import requests
    r = requests.get(SSV_KEYS_URL, timeout=10)
    r.raise_for_status()
    keys = {str(k["keyId"]): k["pem"] for k in (r.json().get("keys") or [])}
    cache.set("ps1_ssv_keys", keys, 12 * 3600)
    return keys


def _verify_sig(message, sig_b64, key_id):
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    keys = _ssv_keys()
    pem = keys.get(str(key_id))
    if pem is None:
        keys = _ssv_keys(force=True)
        pem = keys.get(str(key_id))
    if pem is None:
        return False
    pad = "=" * (-len(sig_b64) % 4)
    sig = base64.urlsafe_b64decode(sig_b64 + pad)
    pub = serialization.load_pem_public_key(pem.encode())
    try:
        pub.verify(sig, message.encode(), ec.ECDSA(hashes.SHA256()))
        return True
    except InvalidSignature:
        return False


def ssv_callback(raw_query, params):
    """GET /ads/ssv — Google AdMob rewarded server-side verification.

    Verifies Google's ECDSA signature over the query string, then flips the
    matching pending ticket (custom_data = nonce, user_id must match) to
    'verified'. A replayed transaction_id is ignored. Returns (status, body)."""
    from . import billing
    from .models import PhotoAdTicket
    message, sig, key_id = PS.ssv_split(raw_query)
    if not message or not sig or not key_id:
        return 400, {"ok": False, "reason": "unsigned"}
    try:
        if not _verify_sig(message, sig, key_id):
            return 403, {"ok": False, "reason": "bad_signature"}
    except Exception:
        return 503, {"ok": False, "reason": "keys_unavailable"}
    nonce = (params.get("custom_data") or "").strip()
    txn = (params.get("transaction_id") or "").strip()
    uid = (params.get("user_id") or "").strip()
    if not nonce or not txn:
        return 200, {"ok": True, "ignored": "no_ticket"}   # SSV must get 200
    with transaction.atomic():
        t = PhotoAdTicket.objects.select_for_update().filter(nonce=nonce).first()
        if t is None or t.kind != "rewarded":
            return 200, {"ok": True, "ignored": "unknown_ticket"}
        if PhotoAdTicket.objects.filter(transaction_id=txn).exists():
            return 200, {"ok": True, "ignored": "replay"}
        if t.status != "pending" or (uid and uid != str(t.user_id)):
            return 200, {"ok": True, "ignored": "not_pending"}
        if t.placement == "credits" and t.job is None:
            # p2-money: rewarded ad for credits - Google verified it, credit
            # the ad wallet now (daily cap + fraud guard inside ad_event).
            res = billing.ad_event(t.user, "rewarded", ad_id=txn[:80],
                                   verified=True)
            t.status = "verified" if res.get("ok") else "rejected"
            t.transaction_id = txn
            t.ad_unit = (params.get("ad_unit") or "")[:80]
            t.value_bdt = float(res.get("credited_paisa") or 0) / 100.0
            t.source = "ssv"
            t.verified_at = timezone.now()
            t.save()
            return 200, {"ok": True}
        c = _cfg()
        val = PS.ad_value_bdt(c.get("photo_studio"), c["ad_rewards"])
        t.status = "verified"
        t.transaction_id = txn
        t.ad_unit = (params.get("ad_unit") or "")[:80]
        t.value_bdt = val
        t.source = "ssv"
        t.verified_at = timezone.now()
        t.save()
        job = t.job
        if job is not None:
            job.revenue_bdt = float(job.revenue_bdt or 0) + val
            if (job.status == "awaiting_funds"
                    and _verified_count(job) >= job.ads_required):
                job.status = "funded"
                job.funded_at = timezone.now()
            job.save(update_fields=["revenue_bdt", "status", "funded_at"])
    billing.record_revenue("ads", val)
    return 200, {"ok": True}


# ------------------------------------------------------------------ entry ad
def entry_ad_state(user):
    """Should the entry interstitial be shown now? Free users only, at most once
    per `entry_interstitial_gap_min` (server-checked)."""
    from .models import PhotoAdTicket
    ps = ps_cfg()
    if not is_free(user) or not ps["entry_interstitial_enabled"]:
        return {"due": False, "gap_min": ps["entry_interstitial_gap_min"],
                "reason": "paid" if not is_free(user) else "disabled"}
    last = PhotoAdTicket.objects.filter(user=user, placement="entry").order_by(
        "-created_at").first()
    gap = timedelta(minutes=ps["entry_interstitial_gap_min"])
    due = last is None or (timezone.now() - last.created_at) >= gap
    units = _ad_units()
    return {"due": bool(due), "gap_min": ps["entry_interstitial_gap_min"],
            "interstitial_unit": units.get("interstitial", ""),
            "ads_configured": units.get("_configured", False),
            "reason": "ok" if due else "too_soon"}


def record_entry_ad(user, shown):
    """The app reports an entry interstitial it actually showed. Server cap
    enforced; the value is booked as an estimate (interstitials have no SSV)."""
    from . import billing
    from .models import PhotoAdTicket
    st = entry_ad_state(user)
    if not st["due"]:
        return 409, {"ok": False, "reason": st["reason"]}
    if not shown:
        return 200, {"ok": True, "recorded": False}
    c = _cfg()
    val = PS.ad_value_bdt(c.get("photo_studio"), c["ad_rewards"]) if st["ads_configured"] else 0.0
    PhotoAdTicket.objects.create(user=user, kind="interstitial", placement="entry",
                                 nonce=secrets.token_urlsafe(24), status="verified",
                                 source="client", value_bdt=val,
                                 verified_at=timezone.now())
    billing.record_revenue("ads", val)
    return 200, {"ok": True, "recorded": True}


# ------------------------------------------------------------------ images
def _media_path(name):
    return os.path.join(str(settings.MEDIA_ROOT), name)


def _save_bytes(data, ext="png"):
    name = "%s/%s.%s" % (MEDIA_DIR, uuid.uuid4().hex, ext)
    path = _media_path(name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)
    return name


def composite_faces(original, edited, boxes, feather=0.12):
    """FACE-LOCK (server side): paste the ORIGINAL face pixels back over the
    edited image inside each box with a feathered elliptical mask. Boxes are
    normalised [x, y, w, h] in 0..1 (from on-device face detection). Returns
    PNG bytes. Needs Pillow; returns `edited` unchanged if Pillow is missing."""
    try:
        from PIL import Image, ImageDraw, ImageFilter
    except Exception:
        return edited
    o = Image.open(io.BytesIO(original)).convert("RGBA")
    e = Image.open(io.BytesIO(edited)).convert("RGBA").resize(o.size)
    mask = Image.new("L", o.size, 0)
    d = ImageDraw.Draw(mask)
    W, H = o.size
    for b in boxes or []:
        try:
            x, y, w, h = [float(v) for v in b][:4]
        except (TypeError, ValueError):
            continue
        d.ellipse([x * W, y * H, (x + w) * W, (y + h) * H], fill=255)
    rad = max(1, int(min(W, H) * feather * 0.25))
    mask = mask.filter(ImageFilter.GaussianBlur(rad))
    out = Image.composite(o, e, mask)
    buf = io.BytesIO()
    out.convert("RGB").save(buf, "PNG")
    return buf.getvalue()


def make_preview(data, max_px, watermark):
    """Reduced-size preview; free users get a visible tiled watermark. Returns
    PNG bytes, or None when Pillow is unavailable (honest: no preview)."""
    try:
        from PIL import Image, ImageDraw
    except Exception:
        return None
    im = Image.open(io.BytesIO(data)).convert("RGB")
    im.thumbnail((max_px, max_px))
    if watermark:
        layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        step = max(80, im.size[0] // 4)
        for yy in range(0, im.size[1], step):
            for xx in range(-step, im.size[0], step):
                d.text((xx + (yy // step % 2) * step // 2, yy), "Assisto preview",
                       fill=(255, 255, 255, 110))
        im = Image.alpha_composite(im.convert("RGBA"), layer).convert("RGB")
    buf = io.BytesIO()
    im.save(buf, "PNG")
    return buf.getvalue()


def run_cloud(user, job, image_b64, lang="bn", face_boxes=None):
    """Run a FUNDED cloud job on the active provider. Funding was taken before;
    the provider cost is booked only on a real result. A provider failure
    keeps the job funded for a retry (max 3 runs), then refunds credits."""
    from . import billing
    from . import photo_providers as PP
    from . import integrations
    if (job.feature not in PS.CLOUD_FEATURES and job.feature not in PS.WORKER_FEATURES
            and job.feature != PS.ULTRA_FEATURE):
        return 400, {"ok": False, "reason": "not_cloud"}
    if job.status != "funded":
        return 402, {"ok": False, "reason": "not_funded", "job": job_state(job, lang)}
    raw = b""
    if image_b64:
        try:
            raw = base64.b64decode(image_b64, validate=False)
        except Exception:
            return 400, {"ok": False, "reason": "bad_image"}
        if len(raw) > MAX_UPLOAD_BYTES:
            return 413, {"ok": False, "reason": "too_large"}
    if job.feature != "generate" and not raw:
        return 400, {"ok": False, "reason": "no_image"}
    from . import photo_worker
    if photo_worker.should_queue(job.feature):
        # d1-photo v2: heavy work never runs in the API — the photo worker
        # does it (and the FACE LOCK); the phone polls the job.
        if job.feature == PS.ULTRA_FEATURE:
            from . import photo_final as PFN
            if not (photo_worker.enabled() and PFN.ultra_conf()):
                return 409, {"ok": False, "reason": "provider_missing",
                             "message": funding_message("provider_missing", lang)}
        elif job.feature in photo_worker.WORKER_ONLY:
            from . import photo_restore
            st = photo_restore.status(job.feature, lang)
            if not st["ready"]:
                return 409, {"ok": False, "reason": "provider_missing", "message": st["needs"]}
        photo_worker.enqueue(job, raw, face_boxes)
        job.refresh_from_db()
        if job.status == "done":
            return 200, {"ok": True, "job": job_state(job, lang)}
        if job.status in ("queued", "running"):
            return 202, {"ok": True, "queued": True, "job": job_state(job, lang)}
        # processed right away (inline) and failed: funds kept unless final
        return 502, {"ok": False, "reason": "provider_failed",
                     "message": pick(lang, "এডিট এখন হয়নি — আবার চেষ্টা করুন (আর বিজ্ঞাপন/ক্রেডিট লাগবে না)।",
                                     "The edit didn't work this time — try again (no extra ads or credits)."),
                     "job": job_state(job, lang)}
    c = _cfg()
    slug, conf, prov_cost = _active_provider(c)
    if not slug:
        return 409, {"ok": False, "reason": "provider_missing",
                     "message": funding_message("provider_missing", lang)}
    table = c["action_costs"].get(PS.FEATURE_ACTION[job.feature]) or {}
    cost_usd = max(prov_cost, float(table.get("provider_cost") or 0))
    job.status = "running"
    job.runs += 1
    job.provider = slug
    job.save(update_fields=["status", "runs", "provider"])
    mime = "image/png" if raw[:8] == b"\x89PNG\r\n\x1a\n" else "image/jpeg"
    try:
        out = PP.run(slug, conf, feature=job.feature, image_bytes=raw,
                     prompt=job.prompt, mime=mime)
    except PP.ProviderError as e:
        job.error = str(e)[:200]
        if job.runs >= 3:
            job.status = "failed"
            if job.funding in ("credits", "pool") and job.credits_charged:
                _refund(user, job.credits_charged, "photo:refund:%d" % job.pk)
        else:
            job.status = "funded"     # funds kept: retry is free
        job.save(update_fields=["error", "status"])
        return 502, {"ok": False, "reason": "provider_failed",
                     "message": pick(lang, "এডিট সার্ভার এখন সাড়া দেয়নি — আবার চেষ্টা করুন (আর বিজ্ঞাপন/ক্রেডিট লাগবে না)।",
                                     "The edit server didn't respond — try again (no extra ads or credits)."),
                     "job": job_state(job, lang)}
    if raw and face_boxes and job.feature != "generate":
        out = composite_faces(raw, out, face_boxes)
    job.result_name = _save_bytes(out, "png")
    ps = ps_cfg(c)
    prev = make_preview(out, ps["preview_max_px"], watermark=is_free(user))
    if prev:
        job.preview_name = _save_bytes(prev, "png")
    job.cost_bdt = cost_usd * float(c["usd_bdt"])
    job.status = "done"
    job.done_at = timezone.now()
    job.error = ""
    job.save()
    billing.record_cost("ai", job.cost_bdt)
    return 200, {"ok": True, "job": job_state(job, lang)}


# ------------------------------------------------------------------ export gate
def unlock(user, job, kind, lang="bn"):
    """THE export gate. Every way an image leaves the studio (save / share /
    wallpaper / copy / open-in) calls this first. Free users: only a funded
    job (ads SSV-verified or credits taken) unlocks, and the corner mark is
    required. Premium/Business: always clean, never an ad."""
    from .models import PhotoExport
    if kind not in PS.EXPORT_KINDS:
        return 400, {"ok": False, "reason": "bad_kind"}
    free = is_free(user)
    if job.status not in ("funded", "done"):
        st = job_state(job, lang)
        return 402, {"ok": False, "reason": "locked", "job": st,
                     "message": pick(lang, "সেভ/শেয়ার করতে আগে বিজ্ঞাপন দেখুন বা ক্রেডিট ব্যবহার করুন।",
                                     "Watch the ads or use credits first to save or share.")}
    if (job.feature in PS.CLOUD_FEATURES or job.feature in PS.WORKER_FEATURES) and not job.result_name:
        return 409, {"ok": False, "reason": "no_result"}
    exp = PhotoExport.objects.create(user=user, job=job, kind=kind,
                                     token=secrets.token_urlsafe(24),
                                     corner_mark=free)
    out = {"ok": True, "token": exp.token, "kind": kind, "corner_mark": free,
           "full_quality": True,
           "ai_note": "Edited with Assisto (AI-assisted)" if (job.flags or {}).get("ai_edited")
           else "Enhanced with Assisto"}
    if job.result_name:
        out["result"] = _signed(job.result_name)
    return 200, out


# ------------------------------------------------------------------ config view
def client_config(user, lang="bn", request=None):
    c = _cfg()
    ps = ps_cfg(c)
    plan = plan_of(user)
    prov = providers_state(lang, c)
    from . import photo_final as PFN
    dkey = ""
    if request is not None:
        from .otp import device_id
        dkey = PFN.device_key(device_id(request))
    quotes = {f: quote(user, f, c, device_key=dkey) for f in PS.FEATURES}
    for f, q in quotes.items():
        q["message"] = funding_message(q.get("reason", ""), lang) if q.get("reason") != "ok" else ""
    enhance_cap = PFN.capability(user, lang)
    return {
        "plan": plan, "free": plan == "free", "ads_shown": plan == "free",
        "entry_ad": entry_ad_state(user),
        "features": quotes,
        "providers": prov,
        "trials_left_today": max(0, ps["free_prompt_trials_per_day"] - trials_used_today(user))
        if plan == "free" else None,
        "ready_options": list(PS.READY_OPTIONS),
        "beauty_allowed": list(PS.BEAUTY_ALLOWED),
        "strengths": list(PS.STRENGTHS), "default_strength": PS.DEFAULT_STRENGTH,
        "bd_sizes": PS.BD_PHOTO_SIZES,
        "export_kinds": list(PS.EXPORT_KINDS),
        "preview_max_px": ps["preview_max_px"],
        "balance": int(getattr(user, "ai_credits", 0) or 0),
        # ---- p2-photo ---- on-device AI restore model (download once, offline)
        # and whether this viewer is the owner (only the owner sees the
        # "add an image-AI key" note when no cloud provider is connected).
        "ai_model": _ai_model(request),
        "is_owner": bool(getattr(user, "is_superuser", False)),
        # d1-photo: heavy restore jobs — ready? (owner sees what is missing)
        "restore": _restore_state(lang),
        # face restoration: only when the owner turned the GFPGAN legal switch
        # on AND a Replicate key is connected (photo-final, MODEL_LICENSES.md)
        "face_restore": {"available": bool(enhance_cap["face_restore"]),
                         "reason": "" if enhance_cap["face_restore"] else "owner_legal_decision"},
        # photo-final: what the server enhance REALLY offers right now
        "enhance": enhance_cap,
        # d1-photo v2: one-tap templates + what is left today/this week
        "templates": templates(lang),
        "usage": usage_of(user),
        "limits": {k: ps[k] for k in ("free_enhance_per_day", "free_enhance_ads",
                                      "premium_enhance_daily_cap", "free_gen_lifetime",
                                      "free_gen_per_week", "free_gen_min_ads",
                                      "free_enhance_lifetime", "enhance_unlock_ads",
                                      "free_enhance_per_week_no_ads")},
    }


# ------------------------------------------------------------------ templates (v2)
_TEMPLATES = (
    # id, feature, prompt (sent to the provider), en label, bn label
    ("hd_portrait", "enhance_server", "", "HD portrait", "HD পোর্ট্রেট"),
    ("old_restore", "old_restore", "", "Old photo: restore + colour", "পুরোনো ছবি: ঠিক + রং"),
    ("passport_bd", "prompt_edit", "Make a Bangladesh passport photo: plain white background, "
     "head and shoulders, centred, even soft light, 40x50 mm framing.", "Passport (BD)", "পাসপোর্ট (বাংলাদেশ)"),
    ("visa_bd", "prompt_edit", "Make a visa photo: plain white background, head and shoulders, "
     "centred, even light, 2x2 inch framing.", "Visa photo", "ভিসা ছবি"),
    ("linkedin", "prompt_edit", "Professional profile photo: neat business attire, soft studio "
     "light, clean light-grey background.", "Professional / LinkedIn", "প্রফেশনাল / LinkedIn"),
    ("eid_outfit", "prompt_edit", "Dress the person in a modest, elegant Eid outfit "
     "(panjabi or salwar kameez / sari) with a festive background.", "Eid outfit", "ঈদের পোশাক"),
    ("puja_outfit", "prompt_edit", "Dress the person in a modest, elegant traditional Puja outfit "
     "(sari or dhoti-panjabi) with a festive background.", "Puja outfit", "পূজার পোশাক"),
    ("wedding_outfit", "prompt_edit", "Dress the person in a modest, elegant traditional Bangladeshi "
     "wedding outfit with a decorated background.", "Wedding outfit", "বিয়ের পোশাক"),
    ("studio_bg", "prompt_edit", "Replace the background with a clean professional studio backdrop "
     "and soft studio lighting.", "Studio background", "স্টুডিও ব্যাকগ্রাউন্ড"),
    ("product_shop", "prompt_edit", "Product photo for an online shop: clean white background, "
     "soft shadow, sharp and well lit; keep the product exactly as it is.", "Product photo (shop)",
     "দোকানের পণ্যের ছবি"),
)


def templates(lang="bn"):
    """One-tap templates. Generative ones go through the prompt-edit
    provider + FACE LOCK (the face rule is prepended to every prompt)."""
    return [{"id": t[0], "feature": t[1], "prompt": t[2],
             "label": pick(lang, t[4], t[3])} for t in _TEMPLATES]


def template_prompt(tid):
    t = next((x for x in _TEMPLATES if x[0] == tid), None)
    return t[2] if t else None


# ------------------------------------------------------------------ AI image reports (Play policy)
def report_ai_image(user, job, reason, note, lang="bn"):
    from .models import PhotoAIReport
    reason = reason if reason in dict(PhotoAIReport.REASONS) else "other"
    if PhotoAIReport.objects.filter(user=user, created_at__gte=timezone.now() - timedelta(hours=1)).count() >= 10:
        return 429, {"ok": False, "reason": "too_many"}
    PhotoAIReport.objects.create(user=user, job=job, reason=reason, note=str(note or "")[:300])
    return 201, {"ok": True, "message": pick(lang, "ধন্যবাদ — রিপোর্টটি আমরা দেখব।",
                                             "Thank you — we will review this report.")}


# ------------------------------------------------------------------ free-tier Profit Guard (v2)
def free_tier_guard(days=30):
    """AI cost vs ad revenue PER FREE USER (last `days`). alert = the free
    tier as a whole loses money, or any single free user costs more than
    they earned us (owner order: "alert me if the free tier loses money")."""
    from .models import PhotoAdTicket, PhotoStudioJob
    since = timezone.now() - timedelta(days=max(1, int(days)))
    rows = {}
    for j in PhotoStudioJob.objects.filter(created_at__gte=since).select_related("user"):
        if not is_free(j.user):
            continue
        r = rows.setdefault(j.user_id, {"user_id": j.user_id, "cost_bdt": 0.0, "ad_bdt": 0.0,
                                        "jobs": 0, "gifts": 0})
        r["cost_bdt"] += float(j.cost_bdt or 0)
        r["jobs"] += 1
        r["gifts"] += 1 if j.funding == "gift" else 0
    for t in PhotoAdTicket.objects.filter(status="verified", created_at__gte=since):
        if t.user_id in rows:
            rows[t.user_id]["ad_bdt"] += float(t.value_bdt or 0)
    users = sorted(rows.values(), key=lambda r: r["ad_bdt"] - r["cost_bdt"])
    cost = sum(r["cost_bdt"] for r in users)
    ads = sum(r["ad_bdt"] for r in users)
    losing = [r for r in users if r["cost_bdt"] > r["ad_bdt"] + 1e-9]
    return {"days": days, "free_users": len(users), "cost_bdt": round(cost, 2),
            "ad_bdt": round(ads, 2), "net_bdt": round(ads - cost, 2),
            "losing_users": len(losing), "worst": [{k: (round(v, 2) if isinstance(v, float) else v)
                                                   for k, v in r.items()} for r in losing[:20]],
            "alert": cost > ads + 1e-9}


def _restore_state(lang):
    from . import photo_restore
    out = {}
    for f in PS.RESTORE_FEATURES + PS.WORKER_FEATURES:
        try:
            st = photo_restore.status(f, lang)
        except Exception:
            st = {"ready": False, "where": "", "needs": ""}
        out[f] = {"ready": bool(st["ready"]), "where": st["where"], "needs": st["needs"]}
    return out


def _ai_model(request):
    from . import photo_models
    try:
        return photo_models.client_manifest(request)
    except Exception:
        return {"available": False, "reason": "model_pending", "files": [], "version": ""}


# ------------------------------------------------------------------ owner stats
def owner_stats(days=30):
    """Photo Studio ad revenue vs cost per day per feature (REAL rows only)."""
    from .models import PhotoAdTicket, PhotoStudioJob
    since = timezone.localdate() - timedelta(days=max(1, int(days)) - 1)
    credit_bdt = float(_cfg()["credit_bdt"])
    rows = {}

    def row(d, f):
        return rows.setdefault((d, f), {"date": d, "feature": f, "ad_revenue_bdt": 0.0,
                                        "credit_revenue_bdt": 0.0, "cost_bdt": 0.0,
                                        "jobs": 0, "ads": 0})
    for j in PhotoStudioJob.objects.filter(created_at__date__gte=since).exclude(
            status="refused"):
        d = timezone.localtime(j.created_at).date().isoformat()
        r = row(d, j.feature)
        r["jobs"] += 1
        r["cost_bdt"] += float(j.cost_bdt or 0)
        if j.funding in ("credits", "pool"):
            r["credit_revenue_bdt"] += float(j.credits_charged or 0) * credit_bdt
    for t in PhotoAdTicket.objects.filter(status="verified",
                                          created_at__date__gte=since).select_related("job"):
        d = timezone.localtime(t.verified_at or t.created_at).date().isoformat()
        f = "entry" if t.placement == "entry" else (t.job.feature if t.job else "other")
        r = row(d, f)
        r["ad_revenue_bdt"] += float(t.value_bdt or 0)
        r["ads"] += 1
    return PS.feature_stats(list(rows.values()))
