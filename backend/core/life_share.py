"""p3life — read-only share links for a trip plan / an event, and a per-guest
RSVP link (owner PART 3, 3 Nov).

No migration: the rows live in the generic PaCollectionItem store
(travel/*, wedding/*). A link is a Django-SIGNED token carrying
[user_id, kind, row_id, rev]; nothing secret is stored. Turning a link off
bumps the row's `share_rev` (or `rsvp_rev` for a guest), so every older
token stops working at once ("revoked"), and a new link can be made later.

Privacy (shown on the page too): a trip link shows the day plan and the
transport legs only — NEVER the budget, packing list or documents. An event
link shows the programme schedule, the date and head counts only — NEVER the
budget, vendors, gifts or other guests' names. A guest link shows only that
guest's own name + the event programme, and lets them answer yes/no/maybe.
"""
from django.core import signing
from django.utils import timezone

SALT = "p3life.share.v1"
KINDS = {"trip": "travel/trips", "event": "wedding/event",
         "guest": "wedding/guests"}
RSVP_CHOICES = ("yes", "no", "maybe")
MAX_PLUS = 20
LEG_MODES = ("train", "bus", "launch", "air", "car", "other")

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
_BN_MONTHS = ("জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই",
              "আগস্ট", "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর")
_EN_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep",
              "Oct", "Nov", "Dec")


def bn_digits(v):
    return str(v).translate(_BN)


def nice_date(iso, lang="bn"):
    """'2026-12-05' -> '৫ ডিসেম্বর ২০২৬' / '5 Dec 2026'; junk -> ''."""
    try:
        y, m, d = (int(p) for p in str(iso or "")[:10].split("-"))
        if not (1 <= m <= 12 and 1 <= d <= 31):
            return ""
    except (TypeError, ValueError):
        return ""
    if lang == "en":
        return "%d %s %d" % (d, _EN_MONTHS[m - 1], y)
    return "%s %s %s" % (bn_digits(d), _BN_MONTHS[m - 1], bn_digits(y))


def rev_key(kind):
    return "rsvp_rev" if kind == "guest" else "share_rev"


def make_token(user_id, kind, row_id, rev):
    return signing.dumps([int(user_id), kind, int(row_id), int(rev)],
                         salt=SALT, compress=True)


def read_token(token):
    """-> (user_id, kind, row_id, rev) or None for anything malformed."""
    try:
        v = signing.loads(str(token or "")[:400], salt=SALT)
        uid, kind, rid, rev = v
        if kind not in KINDS:
            return None
        return int(uid), kind, int(rid), int(rev)
    except Exception:  # BadSignature, ValueError, TypeError…
        return None


def url_for(kind, token):
    from .journey_watch import site
    return "%s/%s/%s" % (site(), "rsvp" if kind == "guest" else "p", token)


def _row(user, kind, row_id):
    from .models import PaCollectionItem
    return PaCollectionItem.objects.filter(
        user=user, collection=KINDS[kind], id=row_id).first()


def issue(user, kind, row_id):
    """Turn a link on for the user's own row. -> url or None (not theirs)."""
    if kind not in KINDS:
        return None
    row = _row(user, kind, row_id)
    if row is None:
        return None
    data = dict(row.data or {})
    key = rev_key(kind)
    rev = int(data.get(key) or 0)
    if data.get(key + "_off"):
        data[key + "_off"] = False
        row.data = data
        row.save(update_fields=["data", "updated_at"])
    return url_for(kind, make_token(user.id, kind, row.id, rev))


def revoke(user, kind, row_id):
    """Every link made so far for this row stops working. -> bool."""
    if kind not in KINDS:
        return False
    row = _row(user, kind, row_id)
    if row is None:
        return False
    data = dict(row.data or {})
    key = rev_key(kind)
    data[key] = int(data.get(key) or 0) + 1
    data[key + "_off"] = True
    row.data = data
    row.save(update_fields=["data", "updated_at"])
    return True


def resolve(token, kinds):
    """-> (state, row) with state in ok | bad | revoked."""
    t = read_token(token)
    if t is None or t[1] not in kinds:
        return "bad", None
    uid, kind, rid, rev = t
    from .models import PaCollectionItem
    row = PaCollectionItem.objects.filter(
        user_id=uid, collection=KINDS[kind], id=rid).first()
    if row is None:
        return "bad", None
    data = row.data or {}
    if int(data.get(rev_key(kind)) or 0) != rev:
        return "revoked", row
    return "ok", row


def _rows(user_id, collection):
    from .models import PaCollectionItem
    out = []
    for r in PaCollectionItem.objects.filter(user_id=user_id,
                                             collection=collection):
        d = dict(r.data or {})
        d["id"] = r.id
        out.append(d)
    return out


def _txt(v, n=200):
    return str(v or "").strip()[:n]


def trip_view(row, lang="bn"):
    """Public, read-only trip plan: day plan + transport only."""
    d = row.data or {}
    tid = row.id
    days = []
    for r in _rows(row.user_id, "travel/days"):
        if r.get("trip_id") != tid:
            continue
        acts = []
        for a in (r.get("activities") or [])[:40]:
            if isinstance(a, dict):
                acts.append({"what": _txt(a.get("what")),
                             "place": _txt(a.get("place")),
                             "time": _txt(a.get("time"), 10)})
        try:
            dn = int(r.get("day") or 0)
        except (TypeError, ValueError):
            dn = 0
        days.append({"day": dn, "day_txt": bn_digits(dn) if lang == "bn" else str(dn),
                     "title": _txt(r.get("title")), "activities": acts})
    days.sort(key=lambda x: x["day"])
    legs = [leg_view(r, lang) for r in _rows(row.user_id, "travel/legs")
            if r.get("trip_id") == tid]
    legs.sort(key=lambda x: (x["date"], x["time"]))
    return {"title": _txt(d.get("destination")),
            "start": nice_date(d.get("start"), lang),
            "end": nice_date(d.get("end"), lang),
            "days": days, "legs": legs}


def leg_view(r, lang="bn"):
    mode = r.get("mode") if r.get("mode") in LEG_MODES else "other"
    t = _txt(r.get("time"), 10)
    return {"mode": mode, "from": _txt(r.get("from")), "to": _txt(r.get("to")),
            "date": _txt(r.get("date"), 10),
            "date_txt": nice_date(r.get("date"), lang),
            "time": t, "time_txt": bn_digits(t) if lang == "bn" else t,
            "ref": _txt(r.get("ref"), 60)}


def schedule_view(user_id, lang="bn"):
    rows = []
    for r in _rows(user_id, "wedding/schedule"):
        t = _txt(r.get("time"), 10)
        rows.append({"title": _txt(r.get("title")),
                     "date": _txt(r.get("date"), 10),
                     "date_txt": nice_date(r.get("date"), lang),
                     "time": t, "time_txt": bn_digits(t) if lang == "bn" else t,
                     "place": _txt(r.get("place"))})
    rows.sort(key=lambda x: (x["date"], x["time"]))
    return rows


def event_view(row, lang="bn", with_counts=True):
    """Public, read-only event page: date, venue, programme, head counts."""
    from .logic.wedding_events import guest_summary
    d = row.data or {}
    out = {"title": _txt(d.get("title")),
           "date": nice_date(d.get("event_date"), lang),
           "venue": _txt(d.get("venue")),
           "schedule": schedule_view(row.user_id, lang)}
    if with_counts:
        s = guest_summary(_rows(row.user_id, "wedding/guests"))
        f = bn_digits if lang == "bn" else str
        out["confirmed"] = f(s["confirmed_heads"])
        out["expected"] = f(s["expected_heads"])
    return out


def event_for(user_id):
    from .models import PaCollectionItem
    return PaCollectionItem.objects.filter(
        user_id=user_id, collection="wedding/event").order_by("id").first()


def apply_rsvp(row, answer, plus_ones):
    """Record a guest's own answer. -> error code or ''."""
    a = str(answer or "").strip().lower()
    if a not in RSVP_CHOICES:
        return "answer"
    try:
        p = int(str(plus_ones or "0").strip() or 0)
    except (TypeError, ValueError):
        return "plus"
    if not 0 <= p <= MAX_PLUS:
        return "plus"
    data = dict(row.data or {})
    data["rsvp"] = a
    data["plus_ones"] = p if a != "no" else 0
    data["rsvp_via"] = "link"
    data["rsvp_at"] = timezone.now().isoformat()
    row.data = data
    row.save(update_fields=["data", "updated_at"])
    return ""
