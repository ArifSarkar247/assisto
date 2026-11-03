"""amarket — Assisto Market v1 endpoints (/api/v1/market/...). Logic lives in
core/market.py. Every route is per-user, server-checked and behind the flag
`assisto_market` (default OFF; owner / staff / allow-listed testers preview).
Errors carry {reason, detail} — `detail` is ready-to-show bn/en text."""
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import feature_flags as FF
from . import market as MK
from .i18n import is_play_flavour, pick, req_lang

_MSG = {
    "off": ("Assisto Market এখনো চালু হয়নি।", "Assisto Market is not open yet."),
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "bad_category": ("একটা ক্যাটাগরি বাছুন।", "Pick a category."),
    "title_required": ("কী লাগবে, অন্তত ৩ অক্ষরে লিখুন।", "Write what you need (at least 3 letters)."),
    "banned_item": ("এই জিনিস Assisto Market-এ চাওয়া বা বিক্রি করা যায় না।",
                    "This item can't be asked for or sold on Assisto Market."),
    "bad_quantity": ("পরিমাণ ঠিক নয় (১ থেকে ১,০০,০০০)।", "Quantity must be 1 to 100,000."),
    "bad_unit": ("একক বাছুন।", "Pick a unit."),
    "dhaka_only": ("এখন শুধু ঢাকার এলাকা — তালিকা থেকে এলাকা বাছুন।",
                   "Dhaka areas only for now — pick an area from the list."),
    "bad_budget": ("বাজেট ঠিক নয় (কম থেকে বেশি, টাকায়)।", "The budget is not valid (low to high, in taka)."),
    "bad_deadline": ("শেষ সময় ১ ঘণ্টা থেকে ৩০ দিনের মধ্যে দিন।", "Pick a deadline between 1 hour and 30 days."),
    "rate_limited": ("আজকের সীমা শেষ। কাল আবার চেষ্টা করুন।", "Today's limit is reached. Try again tomorrow."),
    "too_many_open": ("একসাথে ১০টির বেশি চাহিদা খোলা রাখা যায় না — পুরনো একটা বন্ধ করুন।",
                      "You can keep at most 10 needs open — close an old one."),
    "not_open": ("এটা আর খোলা নেই।", "This is no longer open."),
    "own_need": ("এটা আপনার নিজের চাহিদা।", "This is your own need."),
    "need_business": ("বিক্রেতা হতে আগে Business চালু করুন (ড্রয়ার → Business)।",
                      "Turn on Business first to become a seller (menu → Business)."),
    "not_seller": ("অফার দিতে Owner Admin-এর অনুমোদন লাগে — আবেদন অপেক্ষায় আছে।",
                   "Offers need the owner's approval — your application is waiting."),
    "not_your_category": ("এই ক্যাটাগরি আপনার বিক্রেতা-তালিকায় নেই।",
                          "This category is not in your seller list."),
    "bad_price": ("প্রতি এককের দাম টাকায় লিখুন।", "Write the price per unit in taka."),
    "bad_delivery": ("কত ঘণ্টায় ডেলিভারি দেবেন লিখুন (১–৭২০)।", "Write delivery time in hours (1–720)."),
    "bid_gone": ("এই অফার আর নেই — অন্য একটা বাছুন।", "This offer is no longer available — pick another."),
    "bad_action": ("ঠিক কাজ নয়।", "Not a valid action."),
    "bad_rating": ("১ থেকে ৫ তারা দিন।", "Give 1 to 5 stars."),
    "chat_blocked": ("চ্যাট খোলা গেল না — কেউ একজন ব্লক করেছেন।",
                     "Chat could not open — one of you has blocked the other."),
    "bad_report": ("রিপোর্ট ঠিক নয়।", "Not a valid report."),
    "own_item": ("নিজেকে রিপোর্ট করা যায় না।", "You can't report yourself."),
    # bizai (owner 4 Nov): verified sellers, bulk tiers, negotiation
    "need_business_plan": ("Market-এ বিক্রেতা হতে Business প্ল্যান লাগে (যাচাই করা বিক্রেতা)।",
                           "Selling on Market needs the Business plan (verified sellers)."),
    "bad_bulk": ("বাল্ক দাম একক দামের চেয়ে কম আর কমপক্ষে ২টি পরিমাণ দিন।",
                 "The bulk price must be lower than the single price, from at least 2 pieces."),
    "need_budget": ("দাম কমাতে বলার আগে চাহিদায় সর্বোচ্চ বাজেট দিন।",
                    "Add your highest budget to the need before asking for a lower price."),
}

_CODE = {"off": 404, "not_found": 404, "rate_limited": 429, "too_many_open": 429,
         "not_seller": 403, "need_business": 403, "not_your_category": 403,
         "need_business_plan": 402,
         "not_open": 409, "bid_gone": 409, "chat_blocked": 409}


def refuse(request, reason):
    bn, en = _MSG.get(reason, _MSG["not_found"])
    return Response({"reason": reason, "detail": pick(req_lang(request), bn, en)},
                    status=_CODE.get(reason, status.HTTP_400_BAD_REQUEST))


class _Base(APIView):
    """Flag gate for every Market route."""

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        self.lang = req_lang(request)

    def off(self, request):
        return not FF.is_on(MK.FLAG, request.user, is_play_flavour(request))

    def handle(self, request, fn):
        if self.off(request):
            return refuse(request, "off")
        return fn()


class OverviewView(_Base):
    def get(self, request):
        def go():
            s = MK.seller_row(request.user)
            return Response({
                **MK.catalogue(self.lang),
                "has_business": MK.biz_of(request.user) is not None,
                "seller": MK.seller_payload(s, self.lang),
                "needs": MK.my_needs(request.user, self.lang),
                "cod_only": True,
                # bizai: the deal fee is paid by the SELLER (never the buyer)
                "fee": 0, "seller_fee": {"single_pct": 1.5, "group_pct": 2.0,
                                         "collected_in_app": False},
            })
        return self.handle(request, go)


class NeedsView(_Base):
    def post(self, request):
        def go():
            need, err = MK.create_need(request.user, request.data)
            if err:
                return refuse(request, err)
            return Response({"need": MK.need_payload(need, request.user, self.lang)},
                            status=status.HTTP_201_CREATED)
        return self.handle(request, go)


class NeedDetailView(_Base):
    def get(self, request, pk):
        def go():
            from .models import MarketBid, MarketNeed
            n = MarketNeed.objects.filter(pk=pk).first()
            if n is None:
                return refuse(request, "not_found")
            me = request.user
            mine = n.buyer_id == me.pk
            joined = n.joins.filter(user=me).exists()
            seller_ok = MK.is_approved(me) and n.category in (MK.seller_row(me).categories or [])
            if not (mine or joined):
                if MK.blocked_between(me.pk, n.buyer_id) or not MK._visible(n):
                    return refuse(request, "not_found")
                if not (seller_ok or (n.group_open and n.status == "open")):
                    return refuse(request, "not_found")
            p = MK.need_payload(n, me, self.lang, with_bids=True)
            if not (mine or joined):
                b = MarketBid.objects.filter(need=n, seller=me).first()
                p["my_bid"] = MK.bid_payload(b) if b else None
                p["can_bid"] = seller_ok and MK.bidding_open(n)
                s = MK.seller_row(me)
                p["km"] = MK.distance_km(s.area, n.area) if s else None
            return Response({"need": p})
        return self.handle(request, go)


class NeedActView(_Base):
    """POST market/needs/<pk>/<action>: cancel | accept | join | leave | bid |
    withdraw."""

    def post(self, request, pk, action):
        def go():
            d = request.data or {}
            u = request.user
            if action == "cancel":
                _, err = MK.cancel_need(u, pk)
            elif action == "accept":
                deals, err = MK.accept_bid(u, pk, MK._int(d.get("bid_id")))
                if not err:
                    return Response({"ok": True, "deals": [MK.deal_payload(x, u, self.lang)
                                                           for x in deals if x.buyer_id == u.pk]})
            elif action == "join":
                _, err = MK.join_need(u, pk, d.get("quantity"))
            elif action == "leave":
                err = MK.leave_need(u, pk)
            elif action == "bid":
                b, err = MK.place_bid(u, pk, d)
                if not err:
                    return Response({"ok": True, "bid": MK.bid_payload(b)})
            elif action == "withdraw":
                err = MK.withdraw_bid(u, pk)
            elif action == "negotiate":      # bizai: ask sellers to meet my limit
                n, err = MK.negotiate(u, pk)
                if not err:
                    return Response({"ok": True, "asked": n})
            elif action == "counter":        # bizai: seller meets the buyer's ask
                b, err = MK.accept_counter(u, pk)
                if not err:
                    return Response({"ok": True, "bid": MK.bid_payload(b)})
            else:
                err = "bad_action"
            if err:
                return refuse(request, err)
            return Response({"ok": True})
        return self.handle(request, go)


class GroupFeedView(_Base):
    def get(self, request):
        def go():
            area = str(request.query_params.get("area", "")).strip()
            return Response({"needs": MK.group_feed(request.user, area, self.lang)})
        return self.handle(request, go)


class SellView(_Base):
    def get(self, request):
        def go():
            s = MK.seller_row(request.user)
            return Response({"seller": MK.seller_payload(s, self.lang),
                             "has_business": MK.biz_of(request.user) is not None,
                             "needs": MK.seller_feed(request.user, self.lang)})
        return self.handle(request, go)


class SellerApplyView(_Base):
    def post(self, request):
        def go():
            d = request.data or {}
            cats = d.get("categories") or []
            if not isinstance(cats, list):
                cats = []
            s, err = MK.apply_seller(request.user, str(d.get("area", "")).strip(), cats,
                                     invite=str(d.get("invite") or "")[:40])
            if err:
                return refuse(request, err)
            return Response({"seller": MK.seller_payload(s, self.lang)})
        return self.handle(request, go)


class DealsView(_Base):
    def get(self, request):
        return self.handle(request, lambda: Response(
            {"deals": MK.my_deals(request.user, self.lang)}))


class DealActView(_Base):
    def post(self, request, pk):
        def go():
            d = request.data or {}
            deal, err = MK.deal_act(request.user, pk, str(d.get("action", "")), d.get("rating"))
            if err:
                return refuse(request, err)
            return Response({"deal": MK.deal_payload(deal, request.user, self.lang)})
        return self.handle(request, go)


class DealChatView(_Base):
    """Open (or re-open) the My Circle chat with the other side of a deal."""

    def post(self, request, pk):
        def go():
            from .views_module5 import _member_dict
            edge, err = MK.deal_chat_edge(request.user, pk)
            if err:
                return refuse(request, err)
            return Response({"member": _member_dict(edge), "state": edge.state})
        return self.handle(request, go)


class ReportView(_Base):
    def post(self, request):
        def go():
            d = request.data or {}
            _, err = MK.report(request.user, str(d.get("kind", "")), d.get("id"),
                               str(d.get("category", "other")), str(d.get("note", "")))
            if err:
                return refuse(request, err)
            return Response({"ok": True})
        return self.handle(request, go)


class BlockView(_Base):
    def post(self, request):
        def go():
            d = request.data or {}
            err = MK.block(request.user, str(d.get("kind", "")), d.get("id"))
            if err:
                return refuse(request, err)
            return Response({"ok": True})
        return self.handle(request, go)


class SellerInviteView(_Base):
    """bizai: POST market/invites {n} — Assisto owner/staff makes a seller
    invite link for his community (the seller is approved on applying)."""
    def post(self, request):
        def go():
            if not request.user.is_staff:
                return refuse(request, "not_found")
            n = MK._int((request.data or {}).get("n")) or 1
            return Response({"code": MK.invite_code(n), "link": MK.invite_link(n)})
        return self.handle(request, go)
