"""buyinside (owner order 10 Nov): the central Plans page's recommendation
from REAL usage — only when it truly saves money (core.logic.plan_book.
recommend) — and the owner's "where did purchases start" counts."""
from datetime import timedelta

from django.db.models import Sum
from django.utils import timezone
from rest_framework.permissions import IsAdminUser
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import pick, req_lang
from .logic import plan_book as BOOK


def usage_30d(user, now=None):
    """(credits really spent, taka really paid for credit packs) in 30 days."""
    from .models import CreditLedger, PaymentOrder, PlayPurchase
    now = now or timezone.now()
    since = now - timedelta(days=30)
    spent = CreditLedger.objects.filter(user=user, reason="consume", created_at__gte=since) \
        .aggregate(s=Sum("delta"))["s"] or 0
    back = CreditLedger.objects.filter(user=user, reason="return", created_at__gte=since) \
        .aggregate(s=Sum("delta"))["s"] or 0
    used = max(0, -int(spent) - int(back))
    play = PlayPurchase.objects.filter(user=user, kind="pack", granted=True, revoked=False,
                                       is_test=False, created_at__gte=since) \
        .aggregate(s=Sum("price_bdt"))["s"] or 0
    gw = PaymentOrder.objects.filter(user=user, kind="pack", status="paid",
                                     paid_at__gte=since).aggregate(s=Sum("amount_bdt"))["s"] or 0
    return used, float(play) + float(gw)


def recommendation(user, now=None):
    from . import billing, plans
    now = now or timezone.now()
    cfg = billing.cfg()
    table = {pid: (float(p.get("price") or 0), int(p.get("credits") or 0))
             for pid, p in (cfg.get("plans") or {}).items() if isinstance(p, dict)}
    used, spent = usage_30d(user, now)
    joined = getattr(user, "date_joined", None)
    days = (now - joined).days if joined else 0
    return BOOK.recommend(plans.effective_plan(user), table, used, spent, days)


class PlanRecommendView(APIView):
    """GET /plans/recommend -> {recommend: null | {...}, text}."""

    def get(self, request):
        lang = req_lang(request)
        try:
            r = recommendation(request.user)
        except Exception:
            r = None
        if not r:
            return Response({"recommend": None})
        from .logic.entitlements import bn_digits
        names = {"plus": ("প্লাস", "Plus"), "premium": ("প্রিমিয়াম", "Premium"),
                 "premium_pro": ("প্রিমিয়াম প্রো", "Premium Pro")}
        bn_name, en_name = names.get(r["plan"], (r["plan"], r["plan"]))
        text = pick(lang,
                    bn_digits("গত ৩০ দিনে আপনি {u} ক্রেডিট খরচ করেছেন এবং মোট ৳{n} দিয়েছেন। "
                              "{p} প্ল্যানে ({c} ক্রেডিট/মাস) ৳{price} — প্রতি মাসে প্রায় ৳{s} বাঁচবে।"
                              .format(u=r["used_30d"], n=r["now_bdt"], p=bn_name, c=r["credits"],
                                      price=r["price"], s=r["saves_bdt"])),
                    "In the last 30 days you used {u} credits and paid ৳{n} in total. "
                    "{p} ({c} credits a month) costs ৳{price} — about ৳{s} less every month."
                    .format(u=r["used_30d"], n=r["now_bdt"], p=en_name, c=r["credits"],
                            price=r["price"], s=r["saves_bdt"]))
        return Response({"recommend": r, "text": text})


class BuyOriginsView(APIView):
    """Owner Admin: where purchases started (last 30 days), no personal data."""
    permission_classes = [IsAdminUser]

    def get(self, request):
        from . import buy_origin
        return Response({"origins": buy_origin.origin_counts(30)})
