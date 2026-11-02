"""acctmode (owner order 2 Nov, PART 1 e) — accounts & finance mode:
personal only / business only / personal + business.

The mode is a VIEW PREFERENCE only. Personal books (Account / Transaction /
Budget) and business books (BusinessProfile / KhataParty / KhataEntry /
Product) already live in separate tables, so switching in ANY direction never
deletes, moves or re-tags a single entry: it only decides which areas the app
shows in its menus. Switching back shows everything again.

Storage: one PaCollectionItem row (collection "acct_mode") per user — no new
model, no migration. Users who never chose get mode "both" (= exactly the app
they already had, nothing hidden) plus a `suggested` mode derived from what
they actually use, which the Settings sheet shows as a hint.

GET  /api/v1/account-mode -> {mode, chosen, suggested, usage, modes}
POST /api/v1/account-mode {mode} -> same shape + `hidden_with_data` (areas the
     new mode hides from the menu that still hold entries — kept, not deleted).
"""
from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang

PERSONAL, BUSINESS, BOTH = "personal", "business", "both"
MODES = (PERSONAL, BUSINESS, BOTH)
COLLECTION = "acct_mode"
HISTORY_MAX = 20


# ---------------------------------------------------------------- pure logic
def normalize(mode):
    m = (mode or "").strip().lower()
    return m if m in MODES else None


def shows(mode, area):
    """Is `area` ('personal' | 'business') shown in the menus for `mode`?"""
    mode = normalize(mode) or BOTH
    return mode == BOTH or mode == area


def suggest(personal_used, business_used):
    """What the user already uses. Nothing used yet -> personal (the common
    case); only the ledger -> business; both -> both."""
    if personal_used and business_used:
        return BOTH
    if business_used:
        return BUSINESS
    return PERSONAL


def hidden_with_data(mode, usage):
    """Areas `mode` hides from the menu that still hold entries."""
    out = []
    if not shows(mode, PERSONAL) and usage["personal"]["used"]:
        out.append(PERSONAL)
    if not shows(mode, BUSINESS) and usage["business"]["used"]:
        out.append(BUSINESS)
    return out


# ---------------------------------------------------------------- data access
def usage_for(user):
    """Read-only counts of the user's entries in each area."""
    from .models import (BusinessProfile, BusinessStaff, KhataParty, Product,
                         Transaction)
    txns = Transaction.objects.filter(user=user).count()
    own = BusinessProfile.objects.filter(user=user).first()
    parties = KhataParty.objects.filter(business=own).count() if own else 0
    products = Product.objects.filter(user=user).count()
    staff = BusinessStaff.objects.filter(member=user, active=True).count()
    named = bool(own and (own.shop_name or "").strip())
    return {
        "personal": {"used": txns > 0, "entries": txns},
        "business": {"used": bool(parties or products or staff or named),
                     "parties": parties, "products": products,
                     "staff_of": staff},
    }


def _row(user):
    from .models import PaCollectionItem
    return (PaCollectionItem.objects.filter(user=user, collection=COLLECTION)
            .order_by("id").first())


def current(user):
    """(mode, chosen). Never chosen -> BOTH: nothing hidden for existing users."""
    row = _row(user)
    mode = normalize((row.data or {}).get("mode")) if row else None
    return (mode, True) if mode else (BOTH, False)


def set_mode(user, mode, source="settings"):
    """Persist the choice. Touches ONLY the acct_mode row."""
    from .models import PaCollectionItem
    mode = normalize(mode)
    if mode is None:
        raise ValueError("bad mode")
    row = _row(user)
    data = dict(row.data or {}) if row else {}
    prev = normalize(data.get("mode"))
    hist = list(data.get("history") or [])
    hist.append({"from": prev, "to": mode, "source": source[:16],
                 "at": timezone.now().isoformat()})
    data.update(mode=mode, history=hist[-HISTORY_MAX:])
    if row:
        row.data = data
        row.save(update_fields=["data", "updated_at"])
    else:
        PaCollectionItem.objects.create(user=user, collection=COLLECTION,
                                        data=data)
    return mode


def payload(user):
    mode, chosen = current(user)
    usage = usage_for(user)
    return {
        "mode": mode,
        "chosen": chosen,
        "suggested": suggest(usage["personal"]["used"], usage["business"]["used"]),
        "usage": usage,
        "modes": list(MODES),
        "hidden_with_data": hidden_with_data(mode, usage),
    }


# ---------------------------------------------------------------- view
class AccountModeView(APIView):
    def get(self, request):
        return Response(payload(request.user))

    def post(self, request):
        lang = req_lang(request)
        mode = normalize((request.data or {}).get("mode"))
        if mode is None:
            msg = ("হিসাবের ধরন ভুল।" if lang == "bn"
                   else "Invalid account mode.")
            return Response({"detail": msg, "code": "bad_mode"}, status=422)
        source = str((request.data or {}).get("source") or "settings")
        set_mode(request.user, mode, source=source)
        return Response(payload(request.user))
