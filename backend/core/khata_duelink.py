"""qbiz (quality push 9 Nov, board row 8 "গ্রাহকের বাকি-দেখার লিংক"):
a read-only, signed, expiring link a shop sends to ONE khata customer so the
customer sees their own due + history in any browser (no app, no login) —
what Khatabook / TallyKhata send with every reminder.

Least data: shop name, the customer's name, the current due and the last
lines (date, gave / paid, amount, running balance). NEVER the entry notes
(a shop may write private remarks), the phone number, other customers,
cost or profit. Customer book only (the supplier book is owner-private).

Token: django signing (own salt), "p<party id>", timestamped, valid
LINK_DAYS days. An archived / deleted customer → the link stops working.
No migration, no new key, no cron.
"""
from django.core import signing
from rest_framework.response import Response
from rest_framework.views import APIView

from . import business_views as bz
from .i18n import req_lang
from .logic import business_khata as khata

SALT = "core.khata.due.v1"
LINK_DAYS = 30
MAX_LINES = 20


def token_for(party_id):
    return signing.TimestampSigner(salt=SALT, sep=".").sign("p%d" % int(party_id))


def parse_token(token):
    """party id of a valid, unexpired token, else None."""
    try:
        val = signing.TimestampSigner(salt=SALT, sep=".").unsign(
            str(token or ""), max_age=LINK_DAYS * 86400)
    except (signing.BadSignature, signing.SignatureExpired):
        return None
    if len(val) < 2 or val[0] != "p" or not val[1:].isdigit():
        return None
    return int(val[1:])


def link_path(party_id):
    return "/kh/" + token_for(party_id)


def public_statement(party_id, lang):
    """The customer-visible view, or None (unknown / archived / supplier)."""
    from .models import KhataParty
    p = (KhataParty.objects.select_related("business")
         .filter(pk=party_id, book=khata.CUSTOMER, archived=False).first())
    if p is None:
        return None
    entries = [{"id": e.id, "direction": e.direction, "amount": e.amount_poisha,
                "note": "", "at": e.at.isoformat()} for e in p.entries.all()]
    stmt = khata.party_statement({"id": p.id, "name": p.name}, entries, p.book, lang)
    lines = khata.statement_lines(stmt, p.book)[:MAX_LINES]
    L = "bn" if lang == "bn" else "en"
    bal = int(stmt.get("balance") or 0)
    return {
        "shop": (p.business.shop_name or "").strip(),
        "name": p.name,
        "balance": bal,
        "balance_display": khata.fmt_amount(abs(bal))[L],
        "state": "due" if bal > 0 else ("advance" if bal < 0 else "clear"),
        "lines": [{"date": (r.get("at_display") or {}).get(L, ""),
                   "what": (r.get("particulars") or {}).get(L, ""),
                   "gave": (r.get("debit_display") or {}).get(L, ""),
                   "paid": (r.get("credit_display") or {}).get(L, ""),
                   "balance": (r.get("balance_display") or {}).get(L, "")}
                  for r in lines],
        "more": max(0, len(stmt.get("entries") or []) - MAX_LINES),
        # bizai2: how to pay — the shop's own bKash/Nagad merchant number or
        # the pay-to number it already put on its reminders (never anything
        # else); only while something is due.
        "pay": _pay(p) if bal > 0 else [],
    }


PROVIDER_NAME = {"bkash": "bKash", "nagad": "Nagad", "rocket": "Rocket"}


def _pay(party):
    try:
        from . import tagada_engine as TE
        return [{"provider": PROVIDER_NAME.get(m["provider"], m["provider"]),
                 "number": m["number"]}
                for m in TE._pay_methods(party.business, [party])][:3]
    except Exception:  # noqa: BLE001 — the page never fails over a pay hint
        return []


def tagada_line(party, lang):
    """bizai2: the due-link line a tagada carries on the FREE channels
    (WhatsApp, the phone's own SMS) — the customer taps once and sees the
    due, every entry and how to pay. Never on the paid gateway SMS (a link
    costs the owner an extra SMS part). Customer book only."""
    from .growth import site
    if party is None or getattr(party, "book", "") != khata.CUSTOMER or party.archived:
        return ""
    url = site() + link_path(party.id) + ("?lang=en" if lang == "en" else "")
    return ("\nSee your account and how to pay: %s" if lang == "en"
            else "\nহিসাব ও পরিশোধের উপায় দেখুন: %s") % url


def with_link(text, party, lang):
    return (text + tagada_line(party, lang)) if text else text


def _share_text(shop, name, url, lang):
    if lang == "bn":
        return ("%s, %s-এ আপনার হিসাব (বাকি ও সব লেনদেন) এই লিংকে দেখুন — "
                "শুধু আপনার জন্য, %s দিন খোলা থাকবে:\n%s") % (
            name, shop or "আমাদের দোকান",
            khata.normalize_digits_out(str(LINK_DAYS)), url)
    return ("%s, see your account at %s (due and every entry) on this link — "
            "only for you, open for %d days:\n%s") % (
        name, shop or "our shop", LINK_DAYS, url)


class KhataDueLinkView(APIView):
    """POST business/khata/parties/<pk>/due-link → {url, text, expires_days}.
    The app shares it (WhatsApp / SMS / any app); nothing is sent by the
    server. Customer book only."""

    def post(self, request, pk):
        prof, role, bad = bz._require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        p = prof.khata_parties.filter(pk=pk, book=khata.CUSTOMER, archived=False).first()
        if p is None:
            return bz._err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        from .growth import site
        url = site() + link_path(p.id)
        return Response({"url": url, "expires_days": LINK_DAYS,
                         "text": _share_text((prof.shop_name or "").strip(), p.name, url,
                                             "bn" if lang == "bn" else "en")})
