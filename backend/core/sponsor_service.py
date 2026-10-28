"""
sponsor_service.py — the DB side of p2-money (direct sponsors, app-open,
community sponsored posts, brand offers, ad exposure, premium offer, P&L).

All rules live in core.logic.sponsor (pure); this module only loads rows,
calls those rules and writes counters. Every public entry point is safe to
call for any signed-in user and never raises into a view.
"""
from datetime import timedelta

from django.core import signing
from django.db import IntegrityError, transaction
from django.db.models import F, Sum
from django.utils import timezone

from .logic import sponsor as SP

TOKEN_SALT = "p2-sponsor-slot"
TOKEN_MAX_AGE = 2 * 24 * 3600


# ----------------------------------------------------------------- config
def ad_cfg():
    from . import billing
    try:
        return billing.cfg()["ad_rewards"]
    except Exception:
        from .logic import pricing
        return pricing.DEFAULTS()["ad_rewards"]


def is_paid(user):
    from . import plans
    try:
        return plans.effective_plan(user) != "free"
    except Exception:
        return False


def admob_ready(placement="app_open"):
    """AdMob may fill an EMPTY slot of `placement` (owner 25 Oct): with
    Google's TEST units until the owner turns `admob_real_ids` on, then with
    the real units. Only the app-open and the home native (hero) slots have
    an AdMob fill; the app still applies every placement rule (allowlist,
    Free only, caps)."""
    try:
        c = ad_cfg()
        if placement == "app_open":
            return bool(c.get("place_app_open", True))
        if placement == "hero":
            return bool(c.get("hero_enabled", False))
        return False
    except Exception:
        return False


def admob_real():
    """REAL AdMob unit ids are being served (owner switch `admob_real_ids`):
    only then can Google's SSV verify a rewarded ad, so only then is a
    rewarded ad offered or any ad value credited."""
    try:
        return bool(ad_cfg().get("admob_real_ids", False))
    except Exception:
        return False


def flag(flag_id):
    from . import billing
    try:
        return billing.flag_on(flag_id)
    except Exception:
        return False


# ----------------------------------------------------------------- prefs
def prefs_of(user, create=False):
    from .models import OfferPrefs
    p = OfferPrefs.objects.filter(user=user).first()
    if p is None and create:
        p, _ = OfferPrefs.objects.get_or_create(user=user)
    return p


def _opted_in(p):
    """Brand-offer notifications are OPT-IN only (ads check 28 Oct): on only
    when the user turned the switch on themselves (no prefs row = OFF)."""
    return bool(p and p.notifs_on and p.notifs_opted_in_at)


# shown under the switch (server copy, so no app update is needed to fix it)
OFFER_NOTIF_NOTE = {
    "bn": ("বন্ধ থাকলে কোনো ব্র্যান্ডের অফার নোটিফিকেশন আসবে না — এটাই "
           "শুরুর অবস্থা। চালু করলে শুধু আপনার বাছাই করা বিষয়ের অফার, দিনে "
           "সর্বোচ্চ সীমার মধ্যে, প্রতিটিতে \"অফার · ব্র্যান্ডের নাম\" লেখা থাকবে। "
           "যেকোনো সময় এখান থেকে বন্ধ করা যায়; অফার পেজ সবসময় খোলা যায়।"),
    "en": ("While this is off you get no brand-offer notifications — that is "
           "the default. Turn it on to get offers only for what you picked, "
           "within the daily limit, each labelled \"Offer · brand name\". "
           "Turn it off here any time; the Offers page always stays open."),
}


def user_ctx(user):
    p = prefs_of(user)
    return {
        "paid": is_paid(user),
        "categories": list(p.categories or []) if p else [],
        "brands": list(p.brands or []) if p else [],
        "muted_brands": list(p.muted_brands or []) if p else [],
        "hidden_campaigns": list(p.hidden_campaigns or []) if p else [],
        "division": (p.division or "") if p else "",
        "notifs_on": _opted_in(p),
    }


def prefs_payload(user):
    p = prefs_of(user)
    c = ad_cfg()
    return {
        "categories": list(p.categories or []) if p else [],
        "brands": list(p.brands or []) if p else [],
        "muted_brands": list(p.muted_brands or []) if p else [],
        "notifs_on": _opted_in(p),
        "notifs_opt_in": True,       # the switch starts OFF; only the user turns it on
        "notifs_note": dict(OFFER_NOTIF_NOTE),
        "division": (p.division or "") if p else "",
        "onboarding_done": bool(p.onboarding_done) if p else False,
        "all_categories": list(SP.CATEGORIES),
        "all_divisions": list(SP.DIVISIONS),
        "notif_daily_cap": int(c.get("offer_notif_daily_cap", 2)),
        "offers_enabled": bool(c.get("offers_enabled", True)),
        "paid": is_paid(user),
        "premium_gets_offers": bool(c.get("offers_premium_notifs", False)),
    }


def save_prefs(user, d):
    p = prefs_of(user, create=True)
    d = d or {}
    if "categories" in d:
        p.categories = SP.clean_categories(d.get("categories"))[:len(SP.CATEGORIES)]
    if "brands" in d:
        p.brands = SP.clean_ids(d.get("brands"), 50)
    if "muted_brands" in d:
        p.muted_brands = SP.clean_ids(d.get("muted_brands"), 200)
    if "notifs_on" in d:
        # opt-in only: an explicit True from the user's own switch (a JSON
        # true, never a truthy string) records the opt-in time
        on = d.get("notifs_on") is True
        p.notifs_on = on
        p.notifs_opted_in_at = (p.notifs_opted_in_at or timezone.now()) if on else None
    if "division" in d:
        dv = SP.clean_divisions([d.get("division")])
        p.division = dv[0] if dv else ""
    if d.get("onboarding_done") is not None:
        p.onboarding_done = bool(d.get("onboarding_done")) or p.onboarding_done
    p.save()
    return prefs_payload(user)


def mute_brand(user, sponsor_id, muted=True):
    p = prefs_of(user, create=True)
    ids = [i for i in (p.muted_brands or []) if i != sponsor_id]
    if muted:
        ids.append(int(sponsor_id))
    p.muted_brands = SP.clean_ids(ids, 200)
    p.brands = [i for i in (p.brands or []) if i not in p.muted_brands]
    p.save(update_fields=["muted_brands", "brands", "updated_at"])
    return p


def hide_campaign(user, campaign_id):
    p = prefs_of(user, create=True)
    p.hidden_campaigns = SP.clean_ids(list(p.hidden_campaigns or []) + [campaign_id], 200)
    p.save(update_fields=["hidden_campaigns", "updated_at"])


# ----------------------------------------------------------------- campaigns
def _totals(ids):
    from .models import SponsorDailyStat
    out = {}
    for r in (SponsorDailyStat.objects.filter(campaign_id__in=ids)
              .values("campaign_id").annotate(imp=Sum("impressions"),
                                              clk=Sum("clicks"))):
        out[r["campaign_id"]] = (int(r["imp"] or 0), int(r["clk"] or 0))
    return out


def campaign_dict(c, totals=None):
    imp, clk = (totals or {}).get(c.id, (0, 0))
    return {
        "id": c.id, "sponsor_id": c.sponsor_id, "placement": c.placement,
        "status": c.status, "pricing": c.pricing,
        "price_bdt": float(c.price_bdt or 0), "budget_bdt": float(c.budget_bdt or 0),
        "start_at": c.start_at, "end_at": c.end_at,
        "categories": list(c.categories or []), "divisions": list(c.divisions or []),
        "daily_imp_cap": int(c.daily_imp_cap or 0), "priority": int(c.priority or 0),
        "sponsor_active": bool(getattr(c.sponsor, "active", True)),
        "total_impressions": imp, "total_clicks": clk,
    }


def live_candidates(placement, now=None):
    from .models import SponsorCampaign
    now = now or timezone.now()
    qs = (SponsorCampaign.objects.select_related("sponsor")
          .filter(placement=placement, status="approved", sponsor__active=True)
          .exclude(start_at__gt=now).exclude(end_at__lte=now))
    rows = list(qs[:200])
    tot = _totals([c.id for c in rows])
    return {c.id: c for c in rows}, [campaign_dict(c, tot) for c in rows]


def served_today(ids, today=None):
    from .models import SponsorDailyStat
    today = today or timezone.localdate()
    return {r.campaign_id: int(r.impressions or 0)
            for r in SponsorDailyStat.objects.filter(campaign_id__in=ids, date=today)}


def pick(user, placement, now=None, ctx=None):
    """(campaign_obj | None, user_ctx) — the direct campaign for this slot."""
    now = now or timezone.now()
    ctx = ctx or user_ctx(user)
    if ctx["paid"] or not ad_cfg().get("sponsors_enabled", True):
        return None, ctx
    objs, dicts = live_candidates(placement, now)
    if not dicts:
        return None, ctx
    chosen = SP.pick_campaign(dicts, placement, ctx, now,
                              served_today(list(objs)))
    return (objs.get(chosen["id"]) if chosen else None), ctx


def _image_url(c):
    try:
        return c.image.url if c.image else ""
    except Exception:
        return ""


def make_token(user, campaign, placement):
    return signing.dumps({"c": campaign.id, "u": user.id, "p": placement},
                         salt=TOKEN_SALT, compress=True)


def read_token(user, token):
    try:
        d = signing.loads(token or "", salt=TOKEN_SALT, max_age=TOKEN_MAX_AGE)
    except signing.BadSignature:
        return None
    if not isinstance(d, dict) or d.get("u") != user.id:
        return None
    if d.get("p") not in SP.PLACEMENTS:
        return None
    return d


def creative(user, c, placement, ctx=None):
    lang = getattr(user, "language", "bn") if getattr(user, "language", "bn") in ("bn", "en") else "bn"
    return {
        "campaign_id": c.id, "sponsor_id": c.sponsor_id,
        "sponsor": c.sponsor.name, "placement": placement,
        "label": "sponsored",
        "title": {"bn": c.title_bn, "en": c.title_en},
        "body": {"bn": c.body_bn, "en": c.body_en},
        "cta": {"bn": c.cta_bn, "en": c.cta_en},
        "url": c.link_url, "image_url": _image_url(c),
        "token": make_token(user, c, placement),
        "why": {"bn": SP.why_lines(campaign_dict(c), ctx or user_ctx(user), "bn"),
                "en": SP.why_lines(campaign_dict(c), ctx or user_ctx(user), "en")},
        "lang": lang,
    }


# ----------------------------------------------------------------- exposure
def add_exposure(user, placement, source="direct", now=None):
    from .models import AdExposure
    now = now or timezone.now()
    day = timezone.localdate(now)
    for _ in range(2):
        try:
            with transaction.atomic():
                row, _ = AdExposure.objects.get_or_create(
                    user=user, date=day, placement=placement[:16], source=source[:6])
                AdExposure.objects.filter(pk=row.pk).update(
                    count=F("count") + 1, last_at=now)
                return
        except IntegrityError:
            continue


def exposure_today(user, placement, today=None):
    from .models import AdExposure
    today = today or timezone.localdate()
    rows = AdExposure.objects.filter(user=user, placement=placement, date=today)
    n = sum(int(r.count or 0) for r in rows)
    last = max((r.last_at for r in rows if r.last_at), default=None)
    if placement == "app_open":
        # the most recent app-open on ANY earlier day still counts for the gap
        prev = (AdExposure.objects.filter(user=user, placement="app_open")
                .exclude(last_at=None).order_by("-last_at").first())
        if prev and (last is None or prev.last_at > last):
            last = prev.last_at
    return n, last


# ----------------------------------------------------------------- app open
def appopen_state(user, screen="home", entry="", now=None):
    now = now or timezone.now()
    caps = ad_cfg()
    n, last = exposure_today(user, "app_open")
    joined = timezone.localdate(user.date_joined) if user.date_joined else None
    ok, why = SP.appopen_decision(
        paid=is_paid(user), flag_on=flag("ads_app_open"), caps=caps,
        date_joined_local=joined, today_local=timezone.localdate(now),
        shown_today=n, last_shown_at=last, now=now, screen=screen, entry=entry)
    return ok, why, n


def slot(user, placement, *, screen="home", entry="", ctx_kind="", ctx_id=None,
         now=None):
    """The /ads/slot answer. Never serves to a paid user or a blocked screen."""
    now = now or timezone.now()
    caps = ad_cfg()
    skip = SP.skip_after_s(caps)
    base = {"placement": placement, "show": False, "source": "none",
            "skip_after_s": skip, "label": "sponsored"}
    if placement not in SP.PLACEMENTS or placement == "brand_offer":
        return {**base, "reason": "bad_placement"}
    if is_paid(user):
        return {**base, "reason": "paid_plan"}
    if placement == "app_open":
        ok, why, n = appopen_state(user, screen, entry, now)
        if not ok:
            return {**base, "reason": why, "shown_today": n}
    elif placement == "community_post":
        ok, why = community_gate(user, ctx_kind, ctx_id)
        if not ok:
            return {**base, "reason": why}
    elif placement == "hero":
        if not caps.get("hero_enabled", False):
            return {**base, "reason": "disabled"}
    c, ctx = pick(user, placement, now)
    src = SP.slot_source(c, admob_ready(placement))
    if src == "direct":
        return {**base, "show": True, "source": "direct", "reason": "ok",
                "creative": creative(user, c, placement, ctx)}
    if src == "admob":
        return {**base, "show": True, "source": "admob", "reason": "ok"}
    return {**base, "reason": "no_fill"}


# ----------------------------------------------------------- community post
def _space(kind, cid):
    from .models import Channel, Community, CommunityMember
    try:
        cid = int(cid)
    except (TypeError, ValueError):
        return None, 0
    if kind == "channel":
        ch = Channel.objects.filter(pk=cid).first()
        return ch, int(getattr(ch, "follower_count", 0) or 0) if ch else 0
    if kind == "community":
        co = Community.objects.filter(pk=cid).first()
        if co is None:
            return None, 0
        n = (CommunityMember.objects.filter(community=co, status="active")
             .values("member_id").distinct().count())
        return co, n
    return None, 0


def _is_space_admin(user, kind, obj):
    try:
        if kind == "channel":
            from .models import ChannelAdmin
            return (getattr(obj, "owner_id", None) == user.id or
                    ChannelAdmin.objects.filter(channel=obj, user=user).exists())
        from .models import CommunityMember
        return (obj.creator_id == user.id or CommunityMember.objects.filter(
            community=obj, member=user, role="admin", status="active").exists())
    except Exception:
        return False


def community_gate(user, kind, cid):
    obj, members = _space(kind, cid)
    if obj is None:
        return False, "not_found"
    caps = ad_cfg()
    n, _ = exposure_today(user, "community_post")
    return SP.community_post_ok(
        paid=is_paid(user), enabled=bool(caps.get("community_sponsored_enabled", True)),
        member_count=members, threshold=caps.get("community_sponsored_min_members", 500),
        shown_today=n, daily_cap=caps.get("community_sponsored_daily_cap", 6),
        is_admin=_is_space_admin(user, kind, obj))


# ----------------------------------------------------------------- events
def record_event(user, token, kind, now=None):
    """Count an impression / click / hide / mute for a served creative.
    Returns {ok, counted}. Impressions are capped per user per day."""
    from .models import SponsorCampaign, SponsorDailyStat, SponsorSeen
    d = read_token(user, token)
    if d is None:
        return {"ok": False, "reason": "bad_token"}
    c = SponsorCampaign.objects.filter(pk=d["c"]).first()
    if c is None:
        return {"ok": False, "reason": "not_found"}
    now = now or timezone.now()
    day = timezone.localdate(now)
    if kind == "hide":
        hide_campaign(user, c.id)
        _bump(c, day, "hides")
        return {"ok": True, "counted": True}
    if kind == "mute":
        mute_brand(user, c.sponsor_id, True)
        _bump(c, day, "hides")
        return {"ok": True, "counted": True}
    if kind not in ("impression", "click"):
        return {"ok": False, "reason": "bad_kind"}
    if is_paid(user):
        return {"ok": True, "counted": False}
    col = "impressions" if kind == "impression" else "clicks"
    limit = SP.MAX_COUNTED_IMPS_PER_USER_DAY if kind == "impression" else 1
    with transaction.atomic():
        seen, _ = SponsorSeen.objects.select_for_update().get_or_create(
            campaign=c, user=user, date=day)
        if getattr(seen, col) >= limit:
            counted = False
        elif kind == "click" and seen.impressions <= seen.clicks:
            # ads check 28 Oct: never more clicks than impressions
            counted = False
        else:
            SponsorSeen.objects.filter(pk=seen.pk).update(**{col: F(col) + 1})
            counted = True
    if counted:
        _bump(c, day, col)
    if kind == "impression":
        # the user really saw an ad (caps + retention) even past the billing cap
        add_exposure(user, d["p"], "direct", now)
    return {"ok": True, "counted": counted}


def _bump(c, day, col, n=1):
    from .models import SponsorDailyStat
    for _ in range(2):
        try:
            with transaction.atomic():
                row, _ = SponsorDailyStat.objects.get_or_create(campaign=c, date=day)
                SponsorDailyStat.objects.filter(pk=row.pk).update(**{col: F(col) + n})
                return
        except IntegrityError:
            continue


def why(user, token):
    from .models import SponsorCampaign
    d = read_token(user, token)
    c = SponsorCampaign.objects.filter(pk=d["c"]).first() if d else None
    if c is None:
        return None
    ctx = user_ctx(user)
    return {"sponsor": c.sponsor.name, "sponsor_id": c.sponsor_id,
            "lines": {"bn": SP.why_lines(campaign_dict(c), ctx, "bn"),
                      "en": SP.why_lines(campaign_dict(c), ctx, "en")}}


# ----------------------------------------------------------------- offers
def offers_visible_to(user):
    c = ad_cfg()
    if not c.get("offers_enabled", True):
        return False
    return (not is_paid(user)) or bool(c.get("offers_premium_notifs", False))


def offers_feed(user, now=None):
    now = now or timezone.now()
    if not offers_visible_to(user):
        return {"offers": [], "reason": "premium_no_ads" if is_paid(user) else "disabled"}
    ctx = user_ctx(user)
    ctx_any = dict(ctx, paid=False)   # premium only reaches here when allowed
    objs, dicts = live_candidates("brand_offer", now)
    rows = []
    for cd in dicts:
        if not SP.campaign_live(cd, now) or not SP.audience_ok(cd, ctx_any):
            continue
        rows.append((0 if SP.interest_match(cd, ctx) else 1,
                     -cd["priority"], cd["id"], objs[cd["id"]]))
    rows.sort(key=lambda r: r[:3])
    out = []
    for m, _, _, c in rows[:30]:
        cr = creative(user, c, "brand_offer", ctx)
        cr["matches_you"] = m == 0
        cr["categories"] = list(c.categories or [])
        cr["ends_at"] = c.end_at.isoformat() if c.end_at else None
        out.append(cr)
    return {"offers": out, "reason": "ok" if out else "none"}


def brands_list(user, now=None):
    """Sponsors with a live offer (so a user can follow / mute them)."""
    from .models import Sponsor
    now = now or timezone.now()
    ids = set()
    for p in ("brand_offer",):
        _, dicts = live_candidates(p, now)
        ids |= {d["sponsor_id"] for d in dicts}
    p = prefs_of(user)
    muted = set(p.muted_brands or []) if p else set()
    followed = set(p.brands or []) if p else set()
    mids = ids | muted | followed
    return [{"id": s.id, "name": s.name, "category": s.category,
             "muted": s.id in muted, "followed": s.id in followed}
            for s in Sponsor.objects.filter(pk__in=mids).order_by("name")[:200]]


def offer_notifs_sent_today(user, now=None):
    from .models import OfferNotifLog
    now = now or timezone.now()
    start = timezone.localtime(now).replace(hour=0, minute=0, second=0, microsecond=0)
    return OfferNotifLog.objects.filter(user=user, sent_at__gte=start).count()


def send_offer_notifications(campaign, limit=5000, now=None, push_sync=None):
    """Send ONE offer notification for `campaign` to every interested user who
    passes the rules (cap/day, mute, notifs off, Premium flag). Returns
    {sent, skipped:{reason: n}}. Interested = picked one of its categories or
    follows the brand. In-app notification centre row + push (best effort)."""
    from .models import NotifEvent, OfferNotifLog, OfferPrefs
    from . import push
    now = now or timezone.now()
    caps = ad_cfg()
    out = {"sent": 0, "skipped": {}}
    if campaign.placement != "brand_offer" or not SP.campaign_live(
            campaign_dict(campaign), now):
        out["skipped"]["not_live"] = 1
        return out
    cats = set(campaign.categories or [])
    sent_ids = set(OfferNotifLog.objects.filter(campaign=campaign)
                   .values_list("user_id", flat=True))
    # opt-in only (ads check 28 Oct): never a user who did not switch it on
    qs = OfferPrefs.objects.select_related("user").filter(
        notifs_on=True, notifs_opted_in_at__isnull=False)
    n = 0
    for p in qs.iterator():
        if n >= limit:
            break
        u = p.user
        if not u.is_active:
            continue
        interested = bool(cats & set(p.categories or [])) or \
            campaign.sponsor_id in set(p.brands or [])
        if not interested:
            continue
        cd = campaign_dict(campaign)
        ctx = {"paid": False, "muted_brands": p.muted_brands,
               "hidden_campaigns": p.hidden_campaigns, "division": p.division}
        ok, why_ = SP.offer_notif_ok(
            paid=is_paid(u), premium_allowed=bool(caps.get("offers_premium_notifs", False)),
            offers_enabled=bool(caps.get("offers_enabled", True)), notifs_on=_opted_in(p),
            sent_today=offer_notifs_sent_today(u, now),
            daily_cap=caps.get("offer_notif_daily_cap", 2),
            muted=not SP.audience_ok(cd, ctx), already_sent=u.id in sent_ids)
        if not ok:
            out["skipped"][why_] = out["skipped"].get(why_, 0) + 1
            continue
        try:
            OfferNotifLog.objects.create(user=u, campaign=campaign, sent_at=now)
        except IntegrityError:
            continue
        sp = campaign.sponsor.name
        NotifEvent.objects.create(
            user=u, type="offer", route="offers",
            title_bn=("অফার · %s" % sp)[:200], title_en=("Offer · %s" % sp)[:200],
            body_bn=campaign.title_bn[:200], body_en=campaign.title_en[:200])
        try:
            push.push_to_user_async(u, "offer", "অফার · %s" % sp, "Offer · %s" % sp,
                                    campaign.title_bn, campaign.title_en,
                                    data={"route": "offers"}, sync=push_sync)
        except Exception:
            pass
        n += 1
    out["sent"] = n
    if n:
        _bump(campaign, timezone.localdate(now), "notifs", n)
    return out


# ----------------------------------------------------------- premium offer
def premium_benefits(lang, cfg=None):
    """Premium-ONLY benefits, every line derived from live config / live
    rules (nothing that Free also gets, nothing not enforced)."""
    from . import billing
    from .logic import pricing as P
    cfg = cfg or billing.cfg()
    bn = lang == "bn"
    fr, pr = cfg["plans"]["free"], cfg["plans"]["premium"]
    out = []

    def add(key, b, e):
        out.append({"key": key, "text": b if bn else e})
    if pr["credits"] > fr["credits"]:
        add("credits", "প্রতি মাসে %s AI ক্রেডিট" % P._bn_num(pr["credits"]),
            "%d AI credits every month" % pr["credits"])
    if fr["ads"] and not pr["ads"]:
        add("no_ads", "কোনো বিজ্ঞাপন নেই — অ্যাপ খুললে, হোমে, কমিউনিটিতে কোথাও না",
            "No ads anywhere — not on app open, home or communities")
    if pr["family"] > fr["family"]:
        add("family", "%s জন পর্যন্ত পরিবার সার্কেল ও কেয়ারগিভার ড্যাশবোর্ড" % P._bn_num(pr["family"]),
            "Family circle of up to %d & caregiver dashboard" % pr["family"])
    if pr["storage_bytes"] > fr["storage_bytes"]:
        gb = pr["storage_bytes"] // P.GB
        add("storage", "%s GB স্টোরেজ" % P._bn_num(gb), "%d GB storage" % gb)
    try:
        from .calls_free import calls_free
        if not calls_free():
            add("video", "ভিডিও কল (একজনের সাথে ও গ্রুপে)", "Video calls (1:1 and group)")
    except Exception:
        pass
    if not cfg["ad_rewards"].get("offers_premium_notifs", False):
        add("no_offer_notifs", "অফারের নোটিফিকেশন নেই", "No offer notifications")
    return out


PAYWALL_REASONS = ("out_of_credits", "video_call", "family_limit", "ad_free",
                   "storage_full", "generic")


def premium_offer(user, reason="generic", lang="bn"):
    from . import billing, plans
    from .logic import pricing as P
    cfg = billing.cfg()
    reason = reason if reason in PAYWALL_REASONS else "generic"
    pr = cfg["plans"]["premium"]
    disc = P.effective_annual_discount_pct("premium", cfg)
    yearly = P.annual_price("premium", cfg)
    return {
        "reason": reason,
        "plan": plans.effective_plan(user),
        "benefits": premium_benefits(lang, cfg),
        "monthly_price": pr["price"],
        "yearly_price": yearly,
        "yearly_discount_pct": disc,
        "yearly_monthly_equiv": round(yearly / 12.0, 2),
        "trial_available": plans.trial_available(user),
        "trial_days": plans.trial_days(user),
        "trial_plan": plans.trial_plan(user),
        "trial_active": plans.trial_active(user),
        "cur": "BDT",
    }


# ----------------------------------------------------------- owner reports
def stats_for(c):
    """{date: {impressions, clicks, hides}} for a campaign — its own counters
    plus, for a discover campaign, its linked Discover card's counters."""
    from .models import DiscoverDailyStat, SponsorDailyStat
    out = {}
    for r in SponsorDailyStat.objects.filter(campaign=c):
        out[r.date] = {"impressions": r.impressions, "clicks": r.clicks,
                       "hides": r.hides}
    if c.discover_card_id:
        for r in DiscoverDailyStat.objects.filter(card_id=c.discover_card_id):
            v = out.setdefault(r.date, {"impressions": 0, "clicks": 0, "hides": 0})
            v["impressions"] += int(r.impressions or 0)
            v["clicks"] += int(r.clicks or 0)
    return out


def campaign_report(c, d_from, d_to):
    stats = stats_for(c)
    # revenue is computed over the WHOLE run (CPM budget clamp), then windowed
    imps = {d: v["impressions"] for d, v in stats.items()}
    rev_all = SP.revenue_by_day(campaign_dict(c), imps, timezone.localdate)
    rep = SP.report_rows(campaign_dict(c), stats, d_from, d_to, timezone.localdate)
    tot = 0.0
    for r in rep["rows"]:
        from datetime import date as _date
        r["revenue"] = round(float(rev_all.get(_date.fromisoformat(r["date"]), 0.0)), 2)
        tot += r["revenue"]
    rep["totals"]["revenue"] = round(tot, 2)
    rep.update({"from": d_from.isoformat(), "to": d_to.isoformat(),
                "campaign": c.name, "sponsor": c.sponsor.name,
                "placement": c.placement, "pricing": c.pricing})
    return rep


def report_csv(rep):
    import csv
    import io
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["sponsor", "campaign", "placement", "date", "impressions",
                "clicks", "ctr_pct", "hides", "revenue_bdt"])
    for r in rep["rows"]:
        w.writerow([rep["sponsor"], rep["campaign"], rep["placement"], r["date"],
                    r["impressions"], r["clicks"], r["ctr"], r["hides"], r["revenue"]])
    t = rep["totals"]
    w.writerow([rep["sponsor"], rep["campaign"], rep["placement"], "TOTAL",
                t["impressions"], t["clicks"], t["ctr"], t["hides"], t["revenue"]])
    return buf.getvalue()


_ADMOB_KIND_TO_PLACE = {"app_open": "app_open", "native": "hero",
                        "rewarded": "rewarded", "interstitial": "interstitial"}


def placement_pnl(days=30, today=None):
    """Revenue per placement per day: direct sponsor revenue (+ SPONSORED
    Discover cards' booked revenue) and the AdMob ESTIMATE."""
    from .models import AdEvent, AdExposure, DiscoverCard, SponsorCampaign
    from .logic import discover as D
    today = today or timezone.localdate()
    d_from = today - timedelta(days=days - 1)
    direct = {}
    for c in SponsorCampaign.objects.exclude(status__in=("draft", "rejected")):
        imps = {d: v["impressions"] for d, v in stats_for(c).items()}
        for d, v in SP.revenue_by_day(campaign_dict(c), imps, timezone.localdate).items():
            if d_from <= d <= today:
                k = (c.placement, d)
                direct[k] = direct.get(k, 0.0) + v
    linked = set(SponsorCampaign.objects.exclude(discover_card=None)
                 .values_list("discover_card_id", flat=True))
    for card in DiscoverCard.objects.filter(type="SPONSORED").exclude(pk__in=linked):
        row = {"type": card.type, "sponsor_revenue": card.sponsor_revenue,
               "start_at": card.start_at, "end_at": card.end_at,
               "created_at": card.created_at}
        for d, v in D.revenue_by_day(row, timezone.localdate).items():
            if d_from <= d <= today:
                k = ("discover", d)
                direct[k] = direct.get(k, 0.0) + v
    admob = {}
    for r in (AdExposure.objects.filter(source="admob", date__gte=d_from, date__lte=today)
              .values("placement", "date").annotate(n=Sum("count"))):
        admob[(r["placement"], r["date"])] = int(r["n"] or 0)
    # rewarded / interstitial impressions live in AdEvent (credited or not)
    from django.db.models import Count
    from django.db.models.functions import TruncDate
    for kind in ("rewarded", "interstitial"):
        for r in (AdEvent.objects.filter(kind=kind, at__date__gte=d_from, at__date__lte=today)
                  .annotate(d=TruncDate("at")).values("d").annotate(n=Count("id"))):
            k = (_ADMOB_KIND_TO_PLACE[kind], r["d"])
            admob[k] = admob.get(k, 0) + int(r["n"] or 0)
    c = ad_cfg()
    out = SP.placement_pnl(direct, admob, c.get("ecpm_bdt", 0), c.get("revenue_share", 0))
    out.update({"days": days, "from": d_from.isoformat(), "to": today.isoformat(),
                "admob_linked": admob_real()})
    return out


def retention_impact(days=60, today=None):
    """D1/D7 retention + uninstall proxy per ad-exposure bucket, for users who
    signed up in the last `days` days (only Free-at-signup matters; we use the
    current plan as an approximation and say so)."""
    from django.contrib.auth import get_user_model
    from .models import AdExposure
    User = get_user_model()
    today = today or timezone.localdate()
    since = today - timedelta(days=days)
    users = list(User.objects.filter(date_joined__date__gte=since, is_superuser=False)
                 .values("id", "date_joined", "last_active")[:20000])
    joined = {u["id"]: timezone.localdate(u["date_joined"]) for u in users}
    # ONE query: every exposure row of these users since the window start
    seen = {}
    for r in (AdExposure.objects.filter(user_id__in=list(joined), date__gte=since)
              .values("user_id", "date").annotate(n=Sum("count"))):
        j = joined.get(r["user_id"])
        if j is not None and j <= r["date"] <= j + timedelta(days=6):
            seen[r["user_id"]] = seen.get(r["user_id"], 0) + int(r["n"] or 0)
    rows = [{"joined": joined[u["id"]], "ads_first7": seen.get(u["id"], 0),
             "last_active": timezone.localdate(u["last_active"]) if u["last_active"] else None}
            for u in users]
    return {"buckets": SP.retention_by_bucket(rows, today), "days": days,
            "users": len(rows), "small_sample_n": SP.SMALL_SAMPLE,
            "bucket_defs": [(n, lo, hi if hi < 10 ** 9 else None)
                            for n, lo, hi in SP.EXPOSURE_BUCKETS]}
