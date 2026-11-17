"""train-engine — parse ANY train-status text a user shares or pastes into Assisto.

Owner order (17 Nov, updated F): a 16318 SMS reply, a Facebook / Telegram
group post, a WhatsApp message — Bangla, English, Banglish, typos. We take
out: train, station, time, state (reached / left) and "late by N min". The
engine then applies the SAME plausibility checks as every other report
(station on that train's route, time plausible, near the station or 2+
independent reports agree) before anybody sees it.

NOT ALLOWED and not done: READ_SMS, bots, automatic scraping of any group or
app, reverse-engineering. The user chooses to share; we never store the text
or the sender: parse() returns only {no, candidates, station_id, kind, at,
late_min}; phone numbers are blanked before parsing.

16318 (Bangladesh Railway SMS): the user sends "TR <train no>" from their own
SMS app; the public description of the reply is a one-line English status —
train number + name, the last station, arrived at / left, the clock time,
often the date, late minutes. All samples in tests are MADE UP in that style.
"""
import re
import unicodedata
from datetime import datetime, timedelta

BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
_PHONE = re.compile(r"(?:\+?88)?0?1[3-9]\d{8}")
_MONTHS = {m: i + 1 for i, m in enumerate(
    ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"))}
_W = r"[\wঀ-৿]"

LEFT_WORDS = (
    "left", "has left", "departed", "departs", "depart", "crossed", "passed", "lefted",
    "leave", "leaving", "started from", "start from", "dep from", "dept",
    # Banglish (typos included)
    "chere geche", "chere gese", "chhere geche", "chereche", "cheresey", "cherese",
    "chere dilo", "chere dise", "charlo", "charse", "charche", "chere", "chhere", "sere geche",
    "par holo", "par hoise", "par hoyeche", "cross korlo", "cross korse",
    # Bangla
    "ছেড়ে গেছে", "ছেড়েছে", "ছাড়ল", "ছাড়লো", "ছেড়ে", "ছাড়ছে", "পার হলো", "পার হয়েছে",
    "অতিক্রম করেছে",
)
REACHED_WORDS = (
    "arrived at", "arrived", "arived", "arrivd", "reached", "has reached", "reach", "is at",
    "standing at", "now at", "stopped at", "waiting at", "arr at",
    # Banglish
    "pouchheche", "poucheche", "pouchese", "pouchse", "pocheche", "poucheche",
    "pouchalo", "pouchlo", "pochlo", "aise", "asche", "eseche", "ase ache", "dariye ache",
    "dariye ase", "thame ache", "thamse", "theme ache", "ache ekhon",
    # Bangla
    "পৌঁছেছে", "পৌছেছে", "পৌঁছাল", "পৌঁছালো", "পৌঁছায়", "এসেছে", "আসছে", "অবস্থান করছে",
    "দাঁড়িয়ে আছে", "দাড়িয়ে আছে", "থেমে আছে",
)
LATE_WORDS = r"(?:late|let|lait|delay|delayed|deri|dery|derite|behind|লেট|বিলম্ব|বিলম্বে|দেরি|দেরিতে)"
MIN_WORDS = r"(?:m\b|min\b|mins|minute|minutes|minit|miniet|mnt|মিনিট|মি\.)"
HOUR_WORDS = r"(?:h\b|hr\b|hrs|hour|hours|ghonta|ghanta|ghonda|ঘণ্টা|ঘন্টা)"
ON_TIME = (r"\b(on time|right time|in time|ontime|thik time|thik shomoy|shomoy moto|"
           r"time moto)\b|সঠিক সময়ে|সময়মতো|সময়মত|ঠিক সময়ে")
_DROP_NAME = re.compile(r"\b(railway station|rail station|station|junction|jn|halt|bazar)\b")
_ALIASES = {"bogura": ("bogra",), "chattogram": ("chittagong", "ctg"),
            "kamalapur": ("dhaka", "kamlapur"), "ishwardi": ("isurdi", "iswardi", "ishurdi"),
            "lalmonirhat": ("lalmonirhat", "lalmonirhut"), "joydebpur": ("joydevpur", "gazipur"),
            "biman bandar": ("airport", "bimanbondor", "biman bondor"),
            "sirajganj bazar": ("sirajganj",), "santahar": ("shantahar",),
            "parbatipur": ("parbotipur",), "rajshahi": ("rajshahi",)}


def _norm(s):
    s = str(s or "").translate(BN_DIGITS).replace("‌", "").replace("‍", "")
    # nukta letters (ড় ঢ় য়) come precomposed or as base + nukta: NFC makes both
    # the same sequence (these letters are excluded from composition)
    s = unicodedata.normalize("NFC", s)
    return re.sub(r"\s+", " ", s).strip()


def _key(s):
    return re.sub(r"[^\wঀ-৿]+", " ", _norm(s).lower()).strip()


def _lev1(a, b):
    """True when a and b differ by at most one edit."""
    if a == b:
        return True
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) > len(b):
        a, b = b, a
    i = j = diff = 0
    while i < len(a) and j < len(b):
        if a[i] != b[j]:
            diff += 1
            if diff > 1:
                return False
            if len(a) == len(b):
                i += 1
            j += 1
        else:
            i += 1
            j += 1
    return diff + (len(b) - j) + (len(a) - i) <= 1


def station_names(st):
    """Matchable spellings of one station {en, bn, en_alt?, bn_alt?}."""
    out = set()
    for raw in (st.get("en"), st.get("bn"), st.get("en_alt"), st.get("bn_alt")):
        for v in ([raw] if isinstance(raw, str) else (raw or [])):
            k = _key(v)
            if k:
                out.add(k)
                k2 = _key(_DROP_NAME.sub(" ", k))
                if k2 and len(k2) >= 3:
                    out.add(k2)
    for name in list(out):
        words = name.split()
        for base, alts in _ALIASES.items():
            if base in out and name == base:
                out.update(alts)
            elif " " not in base and base in words:
                out.update(" ".join(a if w == base else w for w in words) for a in alts)
    return out


def _find_words(text, words):
    best = None
    for w in sorted(words, key=len, reverse=True):
        m = re.search(r"(?<!%s)%s(?!%s)" % (_W, re.escape(_key(w)), _W), text)
        if m and (best is None or m.start() < best[0]):
            best = (m.start(), m.end())
    return best


def _find_kind(text):
    lf = _find_words(text, LEFT_WORDS)
    rc = _find_words(text, REACHED_WORDS)
    if lf and (not rc or lf[0] <= rc[0]):
        return ("left",) + lf
    if rc:
        return ("reached",) + rc
    return None


def find_trains(text, known_nos, names):
    """-> (candidate numbers, (start, end) of the matched name or None).
    names = {no: [name, ...]} (Bangla / English / Banglish)."""
    nums = [n for n in re.findall(r"(?<![\d:./-])(\d{2,4})(?!\d|[:./]\d)", text)
            if n in known_nos]
    hits = []
    for no, ns in names.items():
        for nm in ns:
            k = _key(nm)
            for v in {k, re.sub(r"\bexpress\b", "exp", k), re.sub(r"\bexpress\b", "ex", k),
                      k.replace("এক্সপ্রেস", "").strip()}:
                if len(v) < 4:
                    continue
                m = re.search(r"(?<!%s)%s(?!%s)" % (_W, re.escape(v), _W), text)
                if m:
                    hits.append((len(v), no, (m.start(), m.end())))
    span = None
    if hits:
        best = max(h[0] for h in hits)
        top = [h for h in hits if h[0] == best]
        span = top[0][2]
    if nums:                    # a known number wins; the name is still blanked
        return [nums[0]], span
    if not hits:
        return [], None
    return sorted({h[1] for h in top}), span


def _find_station(text, stations, prefer=None, around=None):
    """Longest station name in `text` (whole words, one typo allowed for
    names >= 5 letters). `prefer` = ids on this train's line (first)."""
    pools = [prefer, None] if prefer else [None]
    toks = [(m.group(0), m.start(), m.end()) for m in re.finditer(r"%s+" % _W, text)]
    for pool in pools:
        hits = []
        for sid, st in stations.items():
            if pool is not None and sid not in pool:
                continue
            for name in station_names(st):
                for m in re.finditer(r"(?<!%s)%s(?!%s)" % (_W, re.escape(name), _W), text):
                    hits.append((len(name), 0, sid, m.start(), m.end()))
                if " " not in name and len(name) >= 5:
                    for tok, a, b in toks:
                        if tok != name and _lev1(tok, name):
                            hits.append((len(name) - 1, 1, sid, a, b))
        if hits:
            def rank(h):
                dist = 0 if around is None else min(abs(h[3] - around[1]), abs(around[0] - h[4]))
                return (dist > 30, h[1], -h[0], dist)
            return sorted(hits, key=rank)[0][2]
    return None


def _time(text, base_date):
    m = re.search(r"(\d{1,2})[:.](\d{2})\s*(am|pm|a\.m\.|p\.m\.)?", text)
    if not m:
        return None, None
    h, mi = int(m.group(1)), int(m.group(2))
    ap = (m.group(3) or "").replace(".", "")
    if not ap and h < 12:
        if re.search(r"রাত|সন্ধ্যা|বিকাল|বিকেল|\b(rat|raat|sondha|shondha|bikal|bikel|bikale)\b",
                     text):
            if not (re.search(r"রাত|\b(rat|raat)\b", text) and h < 5):
                h += 12
        elif re.search(r"দুপুর|\b(dupur|dupure)\b", text) and h < 6:
            h += 12
    if ap == "pm" and h < 12:
        h += 12
    if ap == "am" and h == 12:
        h = 0
    if h > 23 or mi > 59:
        return None, None
    d = base_date
    dm = re.search(r"(\d{1,2})[-/ ]([a-z]{3})[a-z]*[-/ ,]+(\d{2,4})", text)
    dn = re.search(r"\b(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})\b", text)
    try:
        if dm and dm.group(2) in _MONTHS:
            y = int(dm.group(3))
            d = d.replace(year=y + 2000 if y < 100 else y, month=_MONTHS[dm.group(2)],
                          day=int(dm.group(1)))
        elif dn:
            y = int(dn.group(3))
            d = d.replace(year=y + 2000 if y < 100 else y, month=int(dn.group(2)),
                          day=int(dn.group(1)))
    except ValueError:
        pass
    return (h, mi), d


def _late(text):
    if re.search(ON_TIME, text):
        return 0
    hm = re.search(r"(\d+)\s*%s\s*(\d+)\s*%s" % (HOUR_WORDS, MIN_WORDS), text)
    if hm and re.search(LATE_WORDS, text):
        return int(hm.group(1)) * 60 + int(hm.group(2))
    for pat in (LATE_WORDS + r"\s*(?:by|of|:|-|holo|hoyeche)?\s*(\d+)\s*" + MIN_WORDS,
                r"(\d+)\s*" + MIN_WORDS + r"\s*" + LATE_WORDS,
                LATE_WORDS + r"\s*[:\-]\s*(\d+)\b"):
        m = re.search(pat, text)
        if m:
            return int(m.group(1))
    hr = re.search(r"(\d+)\s*%s\s*%s" % (HOUR_WORDS, LATE_WORDS), text)
    if hr:
        return int(hr.group(1)) * 60
    return None


def parse(raw, stations, now, tz, train_no=None, line_ids=None, known_trains=None,
          train_names=None):
    """-> {no, candidates, station_id, kind, at (aware), late_min} or None.
    stations = {id: {en, bn}}; train_no = the train the user had open;
    line_ids = that train's station ids (matched first); known_trains = set
    of numbers; train_names = {no: [names]}."""
    if not raw or len(str(raw)) > 2000:
        return None
    clean = _PHONE.sub(" ", _norm(raw))
    text_t = clean.lower()
    cands, span = find_trains(text_t, set(known_trains or ()), train_names or {})
    if not cands and train_no:
        cands = [str(train_no)]
    if train_no and str(train_no) in cands:
        cands = [str(train_no)]
    text = _key(clean if span is None else text_t[:span[0]] + " " * (span[1] - span[0])
                + text_t[span[1]:])
    kind = _find_kind(text)
    if kind is None:
        return None
    sid = _find_station(text, stations, prefer=line_ids, around=kind[1:])
    if sid is None:
        return None
    local_now = now.astimezone(tz)
    hm, d = _time(text_t, local_now.date())
    if hm is None:
        at = local_now
    else:
        at = datetime(d.year, d.month, d.day, hm[0], hm[1], tzinfo=tz)
        if at > local_now + timedelta(minutes=10):       # "11:50 PM" read after midnight
            at -= timedelta(days=1)
    return {"no": cands[0] if len(cands) == 1 else None, "candidates": cands,
            "station_id": sid, "kind": kind[0], "at": at, "late_min": _late(text_t),
            "time_given": hm is not None}
