"""cctvcap (owner decision 3 Nov 10:40): pure rules for the CCTV monthly caps.

  "CCTV relay cap YES: 0.3 GB relay and 50 AI checks per camera per month,
   but SOS, alerts and evidence never stop; at the cap show a clear Bangla
   notice and offer an extra pack; live view prefers P2P and LAN."

What a cap may stop (and nothing else):
  * relay  -> only a NEW live view through OUR TURN relay (and a relayed one
              in progress, unless an SOS / fall is active). P2P / same Wi-Fi
              live, alerts (push + photo), evidence pack and clips never.
  * ai     -> only the paid AI calls on CCTV photos (visitor descriptions);
              alerts then carry the honest template text ("not AI").

Both caps are pooled per account (cameras x per-camera allowance) plus the
"extra packs" bought for THIS month. Everything lives in the cctvguard
month doc (PaCollectionItem "cctv_traffic") — no migration:
  doc["ai_used"]   int   AI checks taken this month (the ONE shared counter)
  doc["extra"]     {"relay_mb": n, "ai": n, "buys": [...]}
  doc["pushed"]    {"relay": "YYYY-MM", "ai": "YYYY-MM"}  one push at 100 %
Plain values in, plain values out (tests run without a DB).
"""
import math

NOTICE_PCT = 80
FULL_PCT = 100
KINDS = ("relay", "ai")
KEEP_BUYS = 20

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn(x):
    return str(x).translate(_BN)


def _int(v):
    try:
        if isinstance(v, bool):
            return 0
        x = float(v)
        return int(x) if math.isfinite(x) and x > 0 else 0
    except (TypeError, ValueError):
        return 0


# ---------------------------------------------------------------- levels
def ai_state(used, cap):
    """-> {"level": ok|notice|full, "pct", "used", "cap", "left"}. The AI cap
    is always a cap (it guards a paid API call); cap 0 = no AI at all."""
    used, cap = _int(used), _int(cap)
    pct = int(math.floor(100.0 * used / cap)) if cap else 100
    if cap == 0 or used >= cap:
        level = "full"
    elif pct >= NOTICE_PCT:
        level = "notice"
    else:
        level = "ok"
    return {"level": level, "pct": min(pct, 999), "used": used, "cap": cap,
            "left": max(0, cap - used)}


def ai_can_take(doc, cap):
    return _int((doc or {}).get("ai_used")) < _int(cap)


def ai_take(doc):
    """One AI check taken (BEFORE the paid call: a paid call is never free)."""
    doc = dict(doc or {})
    doc["ai_used"] = _int(doc.get("ai_used")) + 1
    return doc


# ---------------------------------------------------------------- packs
def extra(doc):
    e = (doc or {}).get("extra") or {}
    return {"relay_mb": _int(e.get("relay_mb")), "ai": _int(e.get("ai"))}


def add_pack(doc, kind, size, credits, ref="", ts=0):
    """Add one bought pack to THIS month's doc. `size` = MB (relay) or
    checks (ai). Returns the new doc."""
    if kind not in KINDS:
        raise ValueError("bad_kind")
    doc = dict(doc or {})
    e = dict((doc.get("extra") or {}))
    key = "relay_mb" if kind == "relay" else "ai"
    e[key] = _int(e.get(key)) + _int(size)
    buys = list(e.get("buys") or [])
    buys.append({"kind": kind, "size": _int(size), "credits": _int(credits),
                 "ref": str(ref)[:80], "at": int(ts or 0)})
    e["buys"] = buys[-KEEP_BUYS:]
    doc["extra"] = e
    # a pack re-opens the cap: a later 100 % may push again
    p = dict(doc.get("pushed") or {})
    p.pop(kind, None)
    doc["pushed"] = p
    return doc


def credits_for(price_bdt, credit_bdt):
    try:
        cb = float(credit_bdt)
    except (TypeError, ValueError):
        cb = 1.0
    cb = cb if cb > 0 else 1.0
    return int(math.ceil(_int(price_bdt) / cb))


# ---------------------------------------------------------------- push once
def push_due(doc, kind, level):
    """True once per month per kind, when that cap is reached."""
    if level not in ("paused", "full"):
        return False
    return not ((doc or {}).get("pushed") or {}).get(kind)


def mark_pushed(doc, kind, month):
    doc = dict(doc or {})
    p = dict(doc.get("pushed") or {})
    p[kind] = str(month)
    doc["pushed"] = p
    return doc


# ---------------------------------------------------------------- words
def ai_message(level, pct, lang="bn"):
    """Honest notice for the AI checks ('' when none). Never says alerts stop."""
    if level == "notice":
        if lang == "bn":
            return ("এই মাসের AI ছবি-যাচাইয়ের %s%% ব্যবহার হয়েছে। শেষ হলেও সতর্কতা ও ছবি "
                    "আগের মতো আসবে — শুধু বর্ণনা হবে ধরন-সময় থেকে লেখা।" % bn(pct))
        return ("%d%% of this month's AI photo checks are used. When they run out, "
                "alerts and photos still arrive — the description is then written "
                "from the alert type and time." % pct)
    if level == "full":
        if lang == "bn":
            return ("এই মাসের AI ছবি-যাচাই শেষ — নতুন ছবির বর্ণনা এখন ধরন-সময় থেকে লেখা (AI নয়)। "
                    "সতর্কতা, ছবি, SOS ও প্রমাণ আগের মতো চলবে।")
        return ("This month's AI photo checks are used up — new photo descriptions are "
                "written from the alert type and time (not AI). Alerts, photos, SOS and "
                "evidence keep working.")
    return ""


def push_text(kind, lang="bn"):
    """(title, body) of the ONE push at 100 %."""
    if kind == "relay":
        if lang == "bn":
            return ("রিলে-লাইভ সীমা শেষ",
                    "একই Wi-Fi-তে বা সরাসরি সংযোগে লাইভ চলবে; সতর্কতা, ছবি ও SOS চলবে। "
                    "চাইলে বাড়তি প্যাক নিন।")
        return ("Relay live allowance used up",
                "Live on the same Wi-Fi or a direct connection still works; alerts, "
                "photos and SOS keep working. You can add an extra pack.")
    if lang == "bn":
        return ("AI ছবি-যাচাই শেষ",
                "সতর্কতা ও ছবি আগের মতো আসবে — বর্ণনা হবে ধরন-সময় থেকে। চাইলে বাড়তি প্যাক নিন।")
    return ("AI photo checks used up",
            "Alerts and photos still arrive — descriptions come from the type and "
            "time. You can add an extra pack.")
