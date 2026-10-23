"""
p2-money API — app-facing endpoints (all signed-in users).

  GET  /ads/slot?placement=app_open|hero|discover|community_post
            &screen=home&entry=&ctx_kind=channel|community&ctx_id=N
                       -> {show, source: direct|admob|none, reason,
                           skip_after_s, creative?}
  POST /ads/sponsor/event {token, kind: impression|click|hide|mute}
  GET  /ads/why?token=   -> {sponsor, lines{bn,en}}
  GET  /offers/prefs   POST /offers/prefs {categories, brands, notifs_on, ...}
  GET  /offers/feed    GET /offers/brands
  POST /offers/brands/<id>/mute {muted}
  POST /credits/rewarded/ticket          -> SSV ticket (nonce) for one ad
  GET  /credits/rewarded/ticket/<nonce>  -> {status: pending|verified|rejected|expired}
  GET  /premium/offer?reason=            -> premium-only benefits, prices, trial
  POST /plans/trial/start                -> start the 3-day trial (once)
"""
import secrets
from datetime import timedelta

from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import sponsor_service as SS
from .i18n import pick, req_lang


class AdsSlotView(APIView):
    def get(self, request):
        q = request.query_params
        placement = (q.get("placement") or "")[:16]
        res = SS.slot(request.user, placement,
                      screen=(q.get("screen") or "home")[:40],
                      entry=(q.get("entry") or "")[:16],
                      ctx_kind=(q.get("ctx_kind") or "")[:10],
                      ctx_id=q.get("ctx_id"))
        return Response(res)


class SponsorEventView(APIView):
    def post(self, request):
        d = request.data or {}
        res = SS.record_event(request.user, str(d.get("token") or "")[:2000],
                              str(d.get("kind") or "")[:12])
        return Response(res, status=200 if res.get("ok") else 400)


class SponsorWhyView(APIView):
    def get(self, request):
        res = SS.why(request.user, (request.query_params.get("token") or "")[:2000])
        if res is None:
            return Response({"ok": False, "reason": "bad_token"}, status=400)
        return Response(res)


class OfferPrefsView(APIView):
    def get(self, request):
        return Response(SS.prefs_payload(request.user))

    def post(self, request):
        return Response(SS.save_prefs(request.user, request.data or {}))


class OfferFeedView(APIView):
    def get(self, request):
        return Response(SS.offers_feed(request.user))


class OfferBrandsView(APIView):
    def get(self, request):
        return Response({"brands": SS.brands_list(request.user)})


class OfferBrandMuteView(APIView):
    def post(self, request, pk):
        from .models import Sponsor
        if not Sponsor.objects.filter(pk=pk).exists():
            return Response({"ok": False, "reason": "not_found"}, status=404)
        muted = (request.data or {}).get("muted", True) not in (False, "false", 0, "0")
        SS.mute_brand(request.user, int(pk), muted)
        return Response({"ok": True, "muted": muted})


# ----------------------------------------------------------- rewarded (SSV)
def _rewarded_cap_left(user):
    from . import billing
    st = billing.ad_wallet_state(user)
    r = (st.get("caps") or {}).get("rewarded") or {}
    return int(r.get("remaining") or 0), int(r.get("cap") or 0)


class RewardTicketView(APIView):
    """One SSV ticket per rewarded ad. HONEST: no AdMob -> no ticket, no ad,
    no credit (reason ads_not_configured); cap reached -> reason capped."""
    def post(self, request):
        from . import billing
        from .models import PhotoAdTicket
        from .photo_studio_service import _ad_units
        lang = req_lang(request)
        user = request.user
        if not (SS.admob_ready() and billing.flag_on("ads_rewarded")):
            return Response({"ok": False, "reason": "ads_not_configured",
                             "msg": pick(lang, "এখন কোনো বিজ্ঞাপন নেই — AdMob যুক্ত হলে চালু হবে।",
                                         "No ads available yet — this starts once AdMob is linked.")})
        left, cap = _rewarded_cap_left(user)
        if left <= 0:
            return Response({"ok": False, "reason": "capped", "cap": cap,
                             "msg": pick(lang, "আজকের সীমা শেষ — কাল আবার দেখুন।",
                                         "Today's limit is reached — try again tomorrow.")})
        cutoff = timezone.now() - timedelta(minutes=30)
        PhotoAdTicket.objects.filter(user=user, placement="credits", status="pending",
                                     created_at__lt=cutoff).update(status="expired")
        # at most one open ticket per user (no farming)
        t = (PhotoAdTicket.objects.filter(user=user, placement="credits",
                                          status="pending").order_by("-created_at").first())
        if t is None:
            t = PhotoAdTicket.objects.create(user=user, kind="rewarded",
                                             placement="credits",
                                             nonce=secrets.token_urlsafe(24))
        units = _ad_units()
        return Response({"ok": True, "nonce": t.nonce, "custom_data": t.nonce,
                         "user_id": str(user.pk),
                         "rewarded_unit": units.get("rewarded", ""),
                         "remaining_today": left}, status=status.HTTP_201_CREATED)


class RewardTicketStateView(APIView):
    def get(self, request, nonce):
        from .models import PhotoAdTicket
        t = PhotoAdTicket.objects.filter(user=request.user, nonce=nonce[:48],
                                         placement="credits").first()
        if t is None:
            return Response({"ok": False, "reason": "not_found"}, status=404)
        return Response({"ok": True, "status": t.status,
                         "credited": t.status == "verified",
                         "value_bdt": round(float(t.value_bdt or 0), 2)})


# ----------------------------------------------------------- premium / trial
class PremiumOfferView(APIView):
    def get(self, request):
        return Response(SS.premium_offer(request.user,
                                         (request.query_params.get("reason") or "generic")[:20],
                                         req_lang(request)))


class TrialStartView(APIView):
    def post(self, request):
        from . import plans
        lang = req_lang(request)
        ok, why = plans.start_trial_button(request.user)
        if not ok:
            return Response({"ok": False, "reason": why,
                             "msg": pick(lang, "ফ্রি ট্রায়াল একবারই পাওয়া যায় — আপনি আগেই নিয়েছেন।",
                                         "The free trial is once per account — you already used it.")
                             if why == "trial_used" else
                             pick(lang, "আপনার প্ল্যানে ট্রায়াল প্রযোজ্য নয়।",
                                  "The trial isn't available on your plan.")},
                            status=status.HTTP_409_CONFLICT)
        u = request.user
        return Response({"ok": True, "trial_until": u.trial_until.isoformat(),
                         "days": plans.trial_days(), "credits": u.ai_credits,
                         "plan": plans.effective_plan(u)})
