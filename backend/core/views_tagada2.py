"""tagada2 — DRF wiring for core/tagada_engine.py (send order, shop <->
customer chat, invite to Assisto, SMS balance) and the customer's "My Dues".

Shop endpoints are scoped exactly like the rest of the khata
(business_views.resolve_business: owner or active staff; Assisto SMS owner
only). Customer endpoints answer ONLY for the signed-in account's VERIFIED
number and only what each shop recorded under it.
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import business_views as bz
from . import tagada_engine as TE
from .i18n import req_lang
from .logic import business_khata as khata


def _party(request, prof, pk):
    return prof.khata_parties.filter(pk=pk, book=khata.CUSTOMER).first()


def _nf(lang):
    st, body = TE.reason_body("not_found", lang)
    return Response(body, status=st)


class TagadaSendView(APIView):
    """POST business/khata/tagada/send/<party> {channel assisto|whatsapp|
    own_sms|gateway_sms, preset, pay_hint} — ONE reminder on that channel
    (the server re-checks the send order, today's slot, block, STOP, quiet
    hours and the SMS balance). WhatsApp / own SMS: claims today's slot and
    returns the link the owner opens."""
    def post(self, request, pk):
        prof, role, bad = bz._require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        p = _party(request, prof, pk)
        if not p:
            return _nf(lang)
        st, body = TE.send(prof, p, channel=str(request.data.get("channel") or ""),
                           owner=bz.is_owner(role),
                           preset=request.data.get("preset", "polite"),
                           pay_hint=bz._pay_hint(request.data.get("pay_hint")),
                           lang=lang, by=request.user)
        return Response(body, status=st)


class KhataChatView(APIView):
    """GET/POST business/khata/parties/<party>/chat — the shop side of the
    shop <-> customer thread (only for a VERIFIED Assisto customer)."""
    def get(self, request, pk):
        prof, role, bad = bz._require_business(request)
        if bad:
            return bad
        p = _party(request, prof, pk)
        if not p:
            return _nf(req_lang(request))
        return Response(TE.shop_chat(prof, p))

    def post(self, request, pk):
        prof, role, bad = bz._require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        p = _party(request, prof, pk)
        if not p:
            return _nf(lang)
        st, body = TE.shop_chat_post(prof, p, request.data.get("text"), by=request.user,
                                     lang=lang)
        return Response(body, status=201 if st == 200 else st)


class KhataInviteView(APIView):
    """GET status / POST create-or-resend an Assisto invite for a khata
    customer (invite-join short code; owner taps share — never auto-sent)."""
    def get(self, request, pk):
        from .models import KhataInvite
        prof, role, bad = bz._require_business(request)
        if bad:
            return bad
        p = _party(request, prof, pk)
        if not p:
            return _nf(req_lang(request))
        cust = TE.verified_user_for(p.phone_canon or TE._canon(p.phone))
        inv = KhataInvite.objects.filter(party=p).first()
        return Response({"status": TE.invite_status(p, cust),
                         "invited_at": inv.invited_at.isoformat() if inv else None,
                         "phone_ok": bool(khata.bd_msisdn(p.phone))})

    def post(self, request, pk):
        prof, role, bad = bz._require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        p = _party(request, prof, pk)
        if not p:
            return _nf(lang)
        out = TE.invite(prof, p, prof.user or request.user, lang)
        if out["status"] == "rate_limited":
            st, body = TE.reason_body("rate_limited", lang)
            return Response(body, status=st)
        return Response(out)


class SmsBalanceView(APIView):
    """GET business/sms/balance — the owner's SMS parts (Business allowance
    this month + packs), the low-balance line and the SMS-pack table."""
    def get(self, request):
        from . import sms_service, sms_wallet
        prof, role, bad = bz._require_business(request)
        if bad:
            return bad
        guard = bz._owner_only(request, role)
        if guard:
            return guard
        lang = req_lang(request)
        w = sms_wallet.state(prof.user or request.user)
        packs = sms_wallet.packs(lang)
        note = ("বাংলা SMS-এর এক অংশে ৭০ অক্ষর (লম্বা হলে প্রতি অংশে ৬৭); ইংরেজিতে ১৬০ (১৫৩)।"
                if lang != "en" else
                "One Bangla SMS part holds 70 letters (67 each when longer); English 160 (153).")
        return Response({**w, "ready": sms_service.ready(),
                         "packs_on_sale": any(x["on_sale"] for x in packs),
                         "packs": packs, "per_part_note": note})


# ===================================================================== customer
def _shop(bid):
    from .models import BusinessProfile
    return BusinessProfile.objects.filter(pk=bid).first()


class MyDuesView(APIView):
    """GET me/dues — every shop that recorded a khata under MY verified
    number: balance, last entry, unread, mute/block. No ads on this screen."""
    def get(self, request):
        return Response(TE.my_dues(request.user, req_lang(request)))


class MyDuesShopView(APIView):
    def get(self, request, bid):
        lang = req_lang(request)
        prof = _shop(bid)
        if prof is None:
            return _nf(lang)
        st, body = TE.my_shop(request.user, prof, lang)
        return Response(body, status=st)


def _mine(request, bid):
    """The shop only when it really recorded something under my number."""
    prof = _shop(bid)
    if prof is None:
        return None
    canon, qs = TE.my_parties(request.user, prof)
    return prof if canon and qs.exists() else None


class MyDuesPrefsView(APIView):
    """POST me/dues/<shop>/prefs {muted?, blocked?}. Block = no tagada on any
    channel and no chat from that shop; the shop only sees "not reachable"."""
    def post(self, request, bid):
        lang = req_lang(request)
        prof = _mine(request, bid)
        if prof is None:
            return _nf(lang)
        d = request.data or {}
        return Response(TE.set_pref(request.user, prof,
                                    muted=d.get("muted") if "muted" in d else None,
                                    blocked=d.get("blocked") if "blocked" in d else None))


class MyDuesChatView(APIView):
    def get(self, request, bid):
        lang = req_lang(request)
        prof = _mine(request, bid)
        if prof is None:
            return _nf(lang)
        return Response(TE.customer_chat(request.user, prof, lang=lang))

    def post(self, request, bid):
        lang = req_lang(request)
        prof = _shop(bid)
        if prof is None:
            return _nf(lang)
        st, body = TE.customer_chat_post(request.user, prof, (request.data or {}).get("text"),
                                         lang=lang)
        return Response(body, status=201 if st == 200 else st)
