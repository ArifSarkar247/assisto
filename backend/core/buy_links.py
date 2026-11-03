"""
buy_links.py — chipbuy2 (owner 3 Nov): "Buy" links to the owner's OWN shop
asalifymart, shown where the app recommends hardware (tracker chip, CCTV
camera, vehicle tracker, kids watch).

  * The list is OWNER ADMIN-EDITABLE (/owner/buy-links) — nothing about a
    product is hard-coded in the app; no PRICE field exists at all (prices
    live only on the shop's own page, so the app can never show a stale one).
  * Only https links on asalifymart.com (or www.) are accepted.
  * Stored in AdminFlagState(key="buy_links") — no migration, audited.
  * The app opens the link in the phone's browser; we add only
    utm_source=assisto. Neither the app nor this server ever calls an
    Asalify system.
  * Placement is decided by the APP and limited to set-up screens; never on
    SOS / alerts / live location / permission / payment / login screens.
"""
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from django.utils import timezone

KEY = "buy_links"
CATEGORIES = ("chip", "cctv", "vehicle", "kids_watch")
HOSTS = ("asalifymart.com", "www.asalifymart.com")
SHOP_NAME = "asalifymart"
MAX_ITEMS = 40
MAX_PER_CATEGORY = 3
_CACHE = "buy_links:v1"

# First-run seed (the owner edits/removes them): the shop's home page per
# category, i.e. exactly what the app linked to before (no product, no price).
SEED_URL = "https://asalifymart.com/"
SEED = [
    {"category": c, "title_bn": "", "title_en": "", "url": SEED_URL, "on": True}
    for c in CATEGORIES
]


def clean_url(raw):
    """https + asalifymart host only; adds utm_source=assisto. None if bad."""
    s = str(raw or "").strip()
    if not s or len(s) > 400:
        return None
    try:
        u = urlsplit(s)
    except ValueError:
        return None
    if u.scheme != "https" or (u.hostname or "").lower() not in HOSTS:
        return None
    if u.username or u.password or u.port not in (None, 443):
        return None
    q = [(k, v) for k, v in parse_qsl(u.query, keep_blank_values=True)
         if k != "utm_source"]
    q.append(("utm_source", "assisto"))
    return urlunsplit(("https", (u.hostname or "").lower(), u.path or "/",
                       urlencode(q), ""))


def clean_item(raw):
    """One row -> normalized dict, or (None, reason)."""
    if not isinstance(raw, dict):
        return None, "bad_row"
    cat = str(raw.get("category") or "")
    if cat not in CATEGORIES:
        return None, "bad_category"
    url = clean_url(raw.get("url"))
    if url is None:
        return None, "bad_url"
    return {"category": cat,
            "title_bn": str(raw.get("title_bn") or "").strip()[:80],
            "title_en": str(raw.get("title_en") or "").strip()[:80],
            "url": url, "on": bool(raw.get("on", True))}, ""


def _row():
    from .models import AdminFlagState
    return AdminFlagState.objects.filter(key=KEY).first()


def items():
    """All rows (owner view). Seeded until the owner first saves."""
    from django.core.cache import cache
    v = cache.get(_CACHE)
    if v is None:
        try:
            row = _row()
            stored = (row.state or {}).get("items") if row else None
        except Exception:  # noqa: BLE001 — never break a set-up screen
            stored = None
        src = SEED if stored is None else stored
        v = [it for it, _ in (clean_item(x) for x in src) if it][:MAX_ITEMS]
        cache.set(_CACHE, v, 300)
    return v


def public(category=None):
    """What the app gets: enabled rows (max 3 per category)."""
    out, per = [], {}
    for it in items():
        if not it["on"] or (category and it["category"] != category):
            continue
        n = per.get(it["category"], 0)
        if n >= MAX_PER_CATEGORY:
            continue
        per[it["category"]] = n + 1
        out.append({k: it[k] for k in ("category", "title_bn", "title_en", "url")})
    return {"shop": SHOP_NAME, "own_shop": True, "items": out}


def save(rows, actor=None):
    """Replace the list. Returns (ok, problems, before, after)."""
    from django.core.cache import cache
    from .models import AdminFlagState
    clean, problems = [], []
    for i, r in enumerate(rows or []):
        if isinstance(r, dict) and not str(r.get("url") or "").strip():
            continue                       # an empty / cleared form row = removed
        it, why = clean_item(r)
        if it is None:
            problems.append("%s:%d" % (why, i + 1))
        else:
            clean.append(it)
    if len(clean) > MAX_ITEMS:
        problems.append("too_many")
    if problems:
        return False, problems, None, None
    row, _ = AdminFlagState.objects.get_or_create(key=KEY)
    before = (row.state or {}).get("items")
    row.state = dict(row.state or {}, items=clean)
    row.audit = ([{"by": getattr(actor, "pk", None), "at": timezone.now().isoformat(),
                   "n_before": len(before or []), "n_after": len(clean)}]
                 + list(row.audit or []))[:100]
    row.save(update_fields=["state", "audit", "updated_at"])
    cache.delete(_CACHE)
    return True, [], before, clean
