"""credout — ONE shape for "this AI task needs more credits".

When `ai.generate` raises AIUnavailable('credits') inside a task the user
typed (home chat, Assisto AI chat, voice → home chat), the view answers
HTTP 402 with this body and saves NOTHING (no user turn, no reply, no
charge), so the app can keep the typed text in the box, open the shared
buy-credits sheet and send the same request again once credits land.

    {"ok": false, "reason": "credits", "code": "out_of_credits",
     "need": <credits this request costs>, "balance": <spendable now>,
     "message": <bn|en line>}

Credits are never cash: they cannot be withdrawn, and no plan is unlimited.
"""
from rest_framework import status
from rest_framework.response import Response

from .i18n import pick

REASON = "credits"
CODE = "out_of_credits"


HEADER = "HTTP_X_ASSISTO_CREDOUT"


def supported(request):
    """Only apps that send `X-Assisto-Credout: 1` (build 247+) know the 402 +
    buy-credits sheet. Older builds keep the free, honest Brain answer so an
    update of the server never breaks their chat."""
    try:
        return str(request.META.get(HEADER, "")).strip() == "1"
    except Exception:  # noqa: BLE001
        return False


class CreditsOut(Exception):
    """Raised by a reply producer when the user cannot cover the AI call."""

    def __init__(self, need=0):
        super().__init__("credits")
        self.need = int(need or 0)


def spendable(user):
    """Credits the user can spend right now (balance + ad wallet on Free)."""
    from . import billing
    try:
        billing.ensure_monthly_pool(user)
    except Exception:  # noqa: BLE001 — never break the honest answer
        pass
    bal = int(getattr(user, "ai_credits", 0) or 0)
    try:
        if billing._is_free(user):  # noqa: SLF001 — the rule charge() uses
            bal += billing.ad_wallet_credits(user)
    except Exception:  # noqa: BLE001
        pass
    return bal


def need_for_tier(user, tier):
    """Credits one AI message of `tier` costs this user (0 if unknown)."""
    try:
        from . import billing
        from .logic import pricing
        eff = billing.effective_tier(user, tier)
        action = pricing.TIER_ACTION.get(eff, "ai_msg_cheap")
        return int(pricing.credits_for(action, 1, billing.cfg()) or 0)
    except Exception:  # noqa: BLE001
        return 0


def body(user, lang, need=0):
    return {
        "ok": False,
        "reason": REASON,
        "code": CODE,
        "need": int(need or 0),
        "balance": spendable(user),
        "message": pick(lang,
                        "AI ক্রেডিট শেষ। ক্রেডিট যোগ করলে আপনার লেখাটি আবার পাঠানো যাবে — কোনো ক্রেডিট কাটা হয়নি।",
                        "You're out of AI credits. Add credits and your message can be sent again — "
                        "no credits were used."),
    }


def response(user, lang, need=0):
    return Response(body(user, lang, need), status=status.HTTP_402_PAYMENT_REQUIRED)
