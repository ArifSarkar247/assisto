"""cctvphone — an old Android phone as an Assisto camera (owner CCTV order
3 Nov, part A). PURE helpers: no Django, no DB, no clock (callers pass
`now_ts`), so every rule here is unit-tested in isolation.

* PAIRING CODE — "<site id>-<6 letters>". The letters are an HMAC of the site,
  its owner and a 10-minute window with the server secret, so the code is
  unguessable, needs NO table (no migration) and dies on its own after 10-20
  minutes. The viewer shows it as a QR (an https App Link) and in big type;
  the camera phone claims it once (the claimed camera keeps the code's hash,
  a second claim with the same code is refused).
* HEALTH WARNINGS — charger unplugged, battery < 20 %, battery too hot, lens
  covered / dark. Each kind is pushed at most once per WARN_REPEAT_S and only
  again after the condition cleared or the repeat window passed.
* LIVE — idle stop (5 min without a touch) and the per-account stream cap.
"""
import hashlib
import hmac

CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"   # no 0/O, 1/I/L
CODE_LEN = 6
WINDOW_S = 600
LINK_BASE = "https://lifeassisto.com/pc/"

LOW_BATTERY_PCT = 20
HOT_C = 45.0
WARN_REPEAT_S = 1800
WARN_KINDS = ("unplugged", "low_battery", "hot", "dark")

LIVE_IDLE_S = 300
LIVE_MAX_PER_ACCOUNT = 2


# --------------------------------------------------------------- pairing code
def _tail(secret, site_id, owner_id, window, nonce=0):
    msg = ("phonecam:%d:%d:%d:%d" % (int(site_id), int(owner_id), int(window),
                                     int(nonce or 0))).encode()
    d = hmac.new(str(secret).encode(), msg, hashlib.sha256).digest()
    n = int.from_bytes(d[:8], "big")
    out = []
    for _ in range(CODE_LEN):
        n, r = divmod(n, len(CODE_ALPHABET))
        out.append(CODE_ALPHABET[r])
    return "".join(out)


def window_of(now_ts):
    return int(now_ts) // WINDOW_S


def pair_code(secret, site_id, owner_id, now_ts, nonce=0):
    """The code valid right now, plus the seconds it stays valid at least.
    `nonce` = the site's newest phone-camera id (0 = none): a claim changes
    it, so the next phone gets a fresh code at once."""
    w = window_of(now_ts)
    code = "%d-%s" % (int(site_id), _tail(secret, site_id, owner_id, w, nonce))
    # valid for this window and the next one
    valid_s = (w + 2) * WINDOW_S - int(now_ts)
    return code, valid_s


def normalize_code(raw):
    """Typed / scanned text -> "<site>-<TAIL>" or None. Accepts the full App
    Link, spaces, lower case and a missing dash."""
    s = str(raw or "").strip()
    if LINK_BASE in s:
        s = s.split(LINK_BASE, 1)[1]
    s = s.split("?")[0].split("#")[0].strip("/ ").upper().replace(" ", "")
    if "-" in s:
        site, tail = s.split("-", 1)
    else:
        i = 0
        while i < len(s) and s[i].isdigit():
            i += 1
        site, tail = s[:i], s[i:]
    tail = tail.replace("-", "")
    if not site.isdigit() or len(site) > 9 or len(tail) != CODE_LEN:
        return None
    if any(c not in CODE_ALPHABET for c in tail):
        return None
    return "%d-%s" % (int(site), tail)


def code_site(code):
    c = normalize_code(code)
    return int(c.split("-", 1)[0]) if c else None


def code_valid(secret, code, site_id, owner_id, now_ts, nonce=0):
    c = normalize_code(code)
    if not c or int(c.split("-", 1)[0]) != int(site_id):
        return False
    tail = c.split("-", 1)[1]
    w = window_of(now_ts)
    return any(hmac.compare_digest(tail, _tail(secret, site_id, owner_id, x, nonce))
               for x in (w, w - 1))


def code_sha(code):
    return hashlib.sha256((normalize_code(code) or "").encode()).hexdigest()[:32]


def pair_link(code):
    return LINK_BASE + code


# --------------------------------------------------------------- health
def clean_health(d):
    """Device-reported battery/view state -> a bounded dict (unknown = None)."""
    if not isinstance(d, dict):
        return None

    def num(v, lo, hi):
        try:
            if isinstance(v, bool):
                return None
            x = float(v)
        except (TypeError, ValueError):
            return None
        return x if lo <= x <= hi else None

    lvl = num(d.get("level"), 0, 100)
    ch = d.get("charging")
    return {"level": int(lvl) if lvl is not None else None,
            "charging": ch if isinstance(ch, bool) else None,
            "temp_c": num(d.get("temp_c"), -30, 100),
            "dark": d.get("dark") is True}


def active_conditions(h):
    """Which warning conditions hold for one clean health dict."""
    if not h:
        return set()
    out = set()
    if h.get("charging") is False:
        out.add("unplugged")
        if h.get("level") is not None and h["level"] < LOW_BATTERY_PCT:
            out.add("low_battery")
    t = h.get("temp_c")
    if t is not None and t >= HOT_C:
        out.add("hot")
    if h.get("dark"):
        out.add("dark")
    return out


def health_warnings(h, warned, now_ts):
    """-> (kinds to push now, the new `warned` map {kind: ts}). A kind is
    pushed when its condition holds and it was not pushed within
    WARN_REPEAT_S; a cleared condition is forgotten, so it alerts again the
    next time it happens."""
    warned = {k: v for k, v in (warned or {}).items() if k in WARN_KINDS}
    now_c = active_conditions(h)
    out = []
    new = {}
    for k in WARN_KINDS:
        if k not in now_c:
            continue
        last = warned.get(k)
        try:
            last = float(last) if last is not None else None
        except (TypeError, ValueError):
            last = None
        if last is None or now_ts - last >= WARN_REPEAT_S:
            out.append(k)
            new[k] = now_ts
        else:
            new[k] = last
    return out, new


WARN_TEXT = {
    "unplugged": ("চার্জার খুলে গেছে", "Charger unplugged",
                  "%s — ফোন-ক্যামেরার চার্জার খুলে গেছে। ব্যাটারি শেষ হলে পাহারা বন্ধ হবে।",
                  "%s — the phone camera was unplugged. It stops watching when the battery runs out."),
    "low_battery": ("ব্যাটারি কম", "Battery low",
                    "%s — ফোন-ক্যামেরার ব্যাটারি %s%%-এর নিচে। চার্জে লাগান।",
                    "%s — the phone camera battery is below %s%%. Plug it in."),
    "hot": ("ফোন গরম হয়েছে", "Phone is hot",
            "%s — ফোন-ক্যামেরা খুব গরম (%s°C)। ছায়ায় রাখুন, কভার খুলুন।",
            "%s — the phone camera is very hot (%s°C). Move it to shade and remove the case."),
    "dark": ("ক্যামেরা ঢাকা বা অন্ধকার", "Camera covered or dark",
             "%s — ফোন-ক্যামেরা কিছু দেখছে না (লেন্স ঢাকা বা ঘর অন্ধকার)। একবার দেখে নিন।",
             "%s — the phone camera sees nothing (lens covered or room dark). Please check."),
}


def warning_text(kind, cam_name, h):
    """(title_bn, title_en, body_bn, body_en) for one warning."""
    tbn, ten, bbn, ben = WARN_TEXT[kind]
    name = cam_name or "Phone camera"
    if kind == "low_battery":
        return tbn, ten, bbn % (name, LOW_BATTERY_PCT), ben % (name, LOW_BATTERY_PCT)
    if kind == "hot":
        t = (h or {}).get("temp_c")
        v = ("%d" % round(t)) if t is not None else "?"
        return tbn, ten, bbn % (name, v), ben % (name, v)
    return tbn, ten, bbn % name, ben % name


# --------------------------------------------------------------- live
def idle_expiry(created_ts, now_ts, hard_cap_s, idle_s=LIVE_IDLE_S):
    """A touch keeps a live view going for idle_s more, never past the hard
    cap counted from the start."""
    return min(float(now_ts) + idle_s, float(created_ts) + hard_cap_s)


def live_slot_free(active_other, limit=LIVE_MAX_PER_ACCOUNT):
    return int(active_other) < int(limit)


def clean_quality(payload):
    """The viewer's SD/HD choice -> {"hd": bool} or None."""
    if isinstance(payload, dict) and isinstance(payload.get("hd"), bool):
        return {"hd": payload["hd"]}
    return None
