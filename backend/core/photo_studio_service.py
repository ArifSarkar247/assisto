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


def _guard_over():
    from . import billing
    try:
        return bool(billing.guard_state()["over"])
    except Exception:
        return False


def quote(user, feature, c=None):
    """funding_options for this user right now (no side effects)."""
    c = c or _cfg()
    from .logic import pricing as P
    plan = plan_of(user)
    cost_usd = 0.0
    provider_ready = True
    slug = ""
    if feature in PS.CLOUD_FEATURES:
        slug, _conf, prov_cost = _active_provider(c)
        provider_ready = bool(slug)
        table = (c["action_costs"].get(PS.FEATURE_ACTION[feature]) or {})
        # the larger of the provider's own cost and the pricing table estimate
        cost_usd = max(prov_cost, float(table.get("provider_cost") or 0)) if slug else 0.0
    table_credits = int((c["action_costs"].get(PS.FEATURE_ACTION.get(feature, ""))
                         or {}).get("credits") or 0)
    q = PS.funding_options(
        feature=feature, plan=plan, cost_usd=cost_usd, usd_bdt=c["usd_bdt"],
        table_credits=table_credits, net_floor=P.net_floor(c),
        credit_bdt=c["credit_bdt"], ps_cfg=c.get("photo_studio"),
        ad_rewards=c["ad_rewards"], trials_used_today=trials_used_today(user),
        guard_over=_guard_over() if plan == "free" else False,
        provider_ready=provider_ready)
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
        "bad_option": ("অজানা অপশন।", "Unknown option."),
    }.get(reason, ("এই এডিট করা যাবে না।", "This edit isn't allowed."))
    return pick(lang, m[0], m[1])


def funding_message(reason, lang):
    m = {
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
    options = [o for o in (data.get("options") or []) if isinstance(o, str)][:12]
    beauty = [b for b in (data.get("beauty") or []) if isinstance(b, str)][:12]
    strength = data.get("strength") if data.get("strength") in PS.STRENGTHS else PS.DEFAULT_STRENGTH
    verdict = PS.classify(prompt, options, beauty_ops=beauty,
                          photo_kind=str(data.get("photo_kind") or ""),
                          child_in_photo=bool(data.get("child_in_photo")),
                          others_in_photo=bool(data.get("others_in_photo")),
                          own_photo=bool(data.get("own_photo", True)),
                          feature=feature)
    if not verdict["allowed"]:
        PhotoStudioJob.objects.create(
            user=user, feature=feature, prompt="", status="refused",
            options={"options": options, "beauty": beauty},
            error=verdict["reason"], flags=verdict["flags"])
        return 422, {"ok": False, "refused": True, "reason": verdict["reason"],
                     "message": refusal_message(verdict["reason"], lang),
                     "flags": verdict["flags"]}

    c = _cfg()
    q = quote(user, feature, c)
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

    job = PhotoStudioJob(
        user=user, feature=feature, prompt=prompt,
        options={"options": options, "beauty": beauty, "strength": strength},
        flags=verdict["flags"], provider=q.get("provider", ""),
        cost_bdt=0.0, funding=opt["via"])
    note = "photo:%s" % feature
    if opt["via"] == "free":
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
    if job.feature not in PS.CLOUD_FEATURES:
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
    if job.feature in PS.CLOUD_FEATURES and not job.result_name:
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
def client_config(user, lang="bn"):
    c = _cfg()
    ps = ps_cfg(c)
    plan = plan_of(user)
    prov = providers_state(lang, c)
    quotes = {f: quote(user, f, c) for f in PS.FEATURES}
    for f, q in quotes.items():
        q["message"] = funding_message(q.get("reason", ""), lang) if q.get("reason") != "ok" else ""
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
    }


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
