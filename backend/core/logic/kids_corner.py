"""sjkids — Children Corner (Safe Journey v2, owner order 9 Nov 11:15).

A PURE layer on top of the Child School state machine (logic/school_mode.py):
the same plan (one per child, set by a guardian, accepted by the child), the
same three position sources (kids watch, tracker chip, the child's phone) and
the same per-day state. No new geofence engine: distances and the in / out /
far hysteresis are school_mode's.

Places (cfg["kc_places"], at most MAX_PLACES):
  * SAFE  — school, coaching, tuition, playground, relative, other — each with
            time windows [{days:[0-6], start:"HH:MM", end:"HH:MM"}] (when the
            child is expected there; a relative's house may have none = safe
            any time);
  * WATCH — market, river, highway, other — the guardians hear when the child
            ENTERS (amber, at most once per WATCH_COOLDOWN_MIN per place).
The plan's own home and school are always SAFE (school in its school hours).

Rules (owner: "an unknown place during school hours asks the guardian"):
  * inside a safe place -> nothing to ask;
  * during an active window (school hours, or a coaching / tuition window)
    and outside EVERY safe place for UNKNOWN_MIN minutes -> ONE question to
    the guardians ("Do you know where NAME is?"), never a red alarm. For a
    window other than school, WINDOW_GRACE_MIN after its start is travel time.
    For the school window the "not there yet" case is school_mode's
    late_school (no double message) — we ask only after the child had been
    at school today (a mid-day exit), and school_mode's immediate
    left_school_early alarm is turned into this question (history kept).
  * a guardian answers "I know, it is OK" -> no more questions for that
    window today; coming back inside a safe place closes the question.
  * arrive / leave at a SAFE corner place -> news (shared with Family Care).

Times are LOCAL (Asia/Dhaka) aware datetimes, as in school_mode.
"""
from datetime import datetime, timedelta

from . import school_mode as SM

SAFE_KINDS = ("school", "coaching", "tuition", "playground", "relative", "other")
WATCH_KINDS = ("market", "river", "highway", "watch_other")
MAX_PLACES = 12
MAX_WINDOWS = 4
UNKNOWN_MIN = 10
WINDOW_GRACE_MIN = 20
WATCH_COOLDOWN_MIN = 30
STALE_FIX_MIN = 45            # an older position never starts a question
HOME_ID, SCHOOL_ID = -1, 0    # the plan's own places
DEFAULT_RADIUS = {"river": 200, "highway": 100}
FENCE_BASE = 900_000_000      # on-phone fence ids for fcbrain: BASE + plan*100 + id


def _hhmm(s):
    return SM.hhmm_min(s)


def clean_window(w):
    if not isinstance(w, dict):
        raise ValueError("bad_window")
    s, e = _hhmm(w.get("start")), _hhmm(w.get("end"))
    if s is None or e is None or e <= s:
        raise ValueError("bad_window")
    try:
        days = sorted({int(d) for d in (w.get("days") or [])})
    except (TypeError, ValueError):
        raise ValueError("bad_window")
    if not days or any(d < 0 or d > 6 for d in days):
        raise ValueError("bad_window")
    return {"days": days, "start": "%02d:%02d" % divmod(s, 60),
            "end": "%02d:%02d" % divmod(e, 60)}


def clean_places(raw):
    """Normalized list (stable ids 1..99); raises ValueError(reason)."""
    if not raw:
        return []
    if not isinstance(raw, (list, tuple)):
        raise ValueError("bad_places")
    if len(raw) > MAX_PLACES:
        raise ValueError("too_many_places")
    out, used = [], set()
    for p in raw:
        if not isinstance(p, dict):
            raise ValueError("bad_places")
        kind = str(p.get("kind") or "")
        if kind not in SAFE_KINDS + WATCH_KINDS:
            raise ValueError("bad_kind")
        geo = SM.clean_place({"lat": p.get("lat"), "lng": p.get("lng"),
                              "radius_m": p.get("radius_m") or DEFAULT_RADIUS.get(kind),
                              "name": p.get("name")})
        if geo is None:
            raise ValueError("bad_location")
        role = "watch" if kind in WATCH_KINDS else "safe"
        wins = p.get("windows") or []
        if not isinstance(wins, list) or len(wins) > MAX_WINDOWS:
            raise ValueError("bad_window")
        try:
            pid = int(p.get("id") or 0)
        except (TypeError, ValueError):
            pid = 0
        if not 1 <= pid <= 99 or pid in used:
            pid = 0
        out.append({"id": pid, "kind": kind, "role": role,
                    "name": (geo["name"] or "").strip()[:40],
                    "lat": geo["lat"], "lng": geo["lng"], "radius_m": geo["radius_m"],
                    "windows": [clean_window(w) for w in wins] if role == "safe" else []})
        if pid:
            used.add(pid)
    nxt = 1
    for p in out:
        if not p["id"]:
            while nxt in used:
                nxt += 1
            p["id"] = nxt
            used.add(nxt)
    return out


def places(cfg):
    return list((cfg or {}).get("kc_places") or [])


def safe_places(cfg):
    """[(id, place, kind, name)] — the plan's home and school + safe corner places."""
    out = []
    if cfg.get("home"):
        out.append((HOME_ID, cfg["home"], "home", cfg["home"].get("name") or ""))
    if cfg.get("school"):
        out.append((SCHOOL_ID, cfg["school"], "school", cfg["school"].get("name") or ""))
    for p in places(cfg):
        if p["role"] == "safe":
            out.append((p["id"], p, p["kind"], p["name"]))
    return out


def active_windows(cfg, local_dt):
    """[{key, place_id, kind, name, start, end}] active at local_dt."""
    d0 = local_dt.replace(hour=0, minute=0, second=0, microsecond=0)
    out = []
    if cfg.get("school") and SM.is_school_day(cfg, local_dt):
        s = d0 + timedelta(minutes=_hhmm(cfg["start"]))
        e = d0 + timedelta(minutes=_hhmm(cfg["end"]))
        if s <= local_dt < e:
            out.append({"key": "0@%s" % cfg["start"], "place_id": SCHOOL_ID,
                        "kind": "school", "name": cfg["school"].get("name") or "",
                        "start": s, "end": e})
    for p in places(cfg):
        for w in p.get("windows") or []:
            if local_dt.weekday() not in w["days"]:
                continue
            s = d0 + timedelta(minutes=_hhmm(w["start"]))
            e = d0 + timedelta(minutes=_hhmm(w["end"]))
            if s <= local_dt < e:
                out.append({"key": "%d@%s" % (p["id"], w["start"]), "place_id": p["id"],
                            "kind": p["kind"], "name": p["name"], "start": s, "end": e})
    return out


def _kc(day):
    kc = day.get("kc")
    if not isinstance(kc, dict):
        kc = {}
    kc.setdefault("inside", [])          # safe ids we are inside now
    kc.setdefault("in_watch", [])        # watch ids we are inside now
    kc.setdefault("out_since", None)     # outside every safe place since
    kc.setdefault("visited", {})         # safe id -> last arrive iso
    kc.setdefault("watch_at", {})        # watch id -> last notice iso
    kc.setdefault("asks", [])            # [{id, key, at, place_kind, place_name, state}]
    kc.setdefault("known", [])           # window keys a guardian said "OK" for
    kc.setdefault("last", None)          # {lat, lng, at, place} — guardians only
    day["kc"] = kc
    return kc


def _ev(kind, local_dt, notify, **kw):
    e = {"kind": kind, "at": local_dt.isoformat(), "notify": notify}
    e.update(kw)
    return e


def _parse(s):
    try:
        return datetime.fromisoformat(s) if s else None
    except (TypeError, ValueError):
        return None


def _place_label(cfg, pid):
    if pid == HOME_ID:
        return "home", (cfg.get("home") or {}).get("name") or ""
    if pid == SCHOOL_ID:
        return "school", (cfg.get("school") or {}).get("name") or ""
    for p in places(cfg):
        if p["id"] == pid:
            return p["kind"], p["name"]
    return "other", ""


def _set_inside(cfg, kc, local_dt, pid, now_in, ev, source):
    """Safe-place transition bookkeeping; corner places (id >= 1) emit news."""
    ins = set(kc["inside"])
    was = pid in ins
    if now_in and not was:
        ins.add(pid)
        kc["visited"][str(pid)] = local_dt.isoformat()
        if pid >= 1:
            k, n = _place_label(cfg, pid)
            ev.append(_ev("kc_arrive", local_dt, "family", place_id=pid,
                          place_kind=k, place_name=n, source=source))
    elif was and not now_in:
        ins.discard(pid)
        if pid >= 1:
            k, n = _place_label(cfg, pid)
            ev.append(_ev("kc_leave", local_dt, "family", place_id=pid,
                          place_kind=k, place_name=n, source=source))
    kc["inside"] = sorted(ins)


def _after_move(kc, local_dt, ev):
    if kc["inside"]:
        kc["out_since"] = None
        # back inside a safe place: every open question is answered by itself
        for a in kc["asks"]:
            if a.get("state") == "open":
                a["state"] = "back_safe"
                a["closed_at"] = local_dt.isoformat()
                ev.append(_ev("kc_back_safe", local_dt, "push", ask_id=a["id"],
                              place_kind=a.get("place_kind", ""),
                              place_name=a.get("place_name", "")))
    elif kc["out_since"] is None:
        kc["out_since"] = local_dt.isoformat()


def on_fix(cfg, day, local_dt, lat, lng, source="gps"):
    """A position (watch, chip or the child's phone). Returns (day, events)."""
    day = SM.ensure_day(day, local_dt)
    kc = _kc(day)
    ev = []
    if day.get("paused") or lat is None or lng is None:
        return day, ev
    kc["last"] = {"lat": lat, "lng": lng, "at": local_dt.isoformat()}
    for pid, place, _k, _n in safe_places(cfg):
        rel = SM.relation(place, lat, lng)
        if rel == "in":
            _set_inside(cfg, kc, local_dt, pid, True, ev, source)
        elif rel in ("out", "far"):
            _set_inside(cfg, kc, local_dt, pid, False, ev, source)
    inw = set(kc["in_watch"])
    for p in places(cfg):
        if p["role"] != "watch":
            continue
        rel = SM.relation(p, lat, lng)
        if rel == "in" and p["id"] not in inw:
            inw.add(p["id"])
            last = _parse(kc["watch_at"].get(str(p["id"])))
            if last is None or local_dt - last >= timedelta(minutes=WATCH_COOLDOWN_MIN):
                kc["watch_at"][str(p["id"])] = local_dt.isoformat()
                ev.append(_ev("kc_watch_enter", local_dt, "push", place_id=p["id"],
                              place_kind=p["kind"], place_name=p["name"],
                              lat=lat, lng=lng, source=source))
        elif rel in ("out", "far"):
            inw.discard(p["id"])
    kc["in_watch"] = sorted(inw)
    _after_move(kc, local_dt, ev)
    ev += _unknown_check(cfg, day, kc, local_dt)
    return day, ev


def on_fence_event(cfg, day, local_dt, kind, place_id, source="phone"):
    """An on-phone geofence crossing (fcbrain FamilyWatchService): kind
    'arrive' | 'leave', place_id = HOME_ID, SCHOOL_ID or a corner place id.
    No coordinates — the phone only tells which place."""
    day = SM.ensure_day(day, local_dt)
    kc = _kc(day)
    ev = []
    if day.get("paused") or kind not in ("arrive", "leave"):
        return day, ev
    p = next((x for x in places(cfg) if x["id"] == place_id), None)
    if p is not None and p["role"] == "watch":
        inw = set(kc["in_watch"])
        if kind == "arrive" and place_id not in inw:
            inw.add(place_id)
            last = _parse(kc["watch_at"].get(str(place_id)))
            if last is None or local_dt - last >= timedelta(minutes=WATCH_COOLDOWN_MIN):
                kc["watch_at"][str(place_id)] = local_dt.isoformat()
                ev.append(_ev("kc_watch_enter", local_dt, "push", place_id=place_id,
                              place_kind=p["kind"], place_name=p["name"], source=source))
        elif kind == "leave":
            inw.discard(place_id)
        kc["in_watch"] = sorted(inw)
    elif place_id in (HOME_ID, SCHOOL_ID) or p is not None:
        if kind == "arrive":
            _sync_school_day(cfg, day, local_dt, place_id)
        _set_inside(cfg, kc, local_dt, place_id, kind == "arrive", ev, source)
        _after_move(kc, local_dt, ev)
    ev += _unknown_check(cfg, day, kc, local_dt)
    return day, ev


def _sync_school_day(cfg, day, local_dt, place_id):
    """The phone fence proved school / home: mark it in school_mode's day so
    its late_school / late_home ask never fires for a child who is there.
    No message here — fcbrain already shares the arrival with the family."""
    w = SM.window(cfg, local_dt)
    if place_id == SCHOOL_ID and w in ("morning", "school") and not day.get("arrived_school_at"):
        day.update(state="at_school", arrived_school_at=local_dt.isoformat())
    elif place_id == HOME_ID and w == "afternoon" and not day.get("home_at"):
        day.update(state="home", home_at=local_dt.isoformat())


def on_tick(cfg, day, local_dt):
    """Every minute (server job): the clock side of the unknown-place rule."""
    day = SM.ensure_day(day, local_dt)
    kc = _kc(day)
    if day.get("paused"):
        return day, []
    return day, _unknown_check(cfg, day, kc, local_dt)


def _unknown_check(cfg, day, kc, local_dt):
    if kc["inside"] or kc["out_since"] is None:
        return []
    out_since = _parse(kc["out_since"])
    last = kc.get("last") or {}
    seen = _parse(last.get("at")) or out_since
    if seen is None or (last.get("lat") is not None
                         and local_dt - seen > timedelta(minutes=STALE_FIX_MIN)):
        return []                       # an old position never starts a question
    asked = {a["key"] for a in kc["asks"]}
    for w in active_windows(cfg, local_dt):
        key = w["key"]
        if key in asked or key in kc["known"]:
            continue
        been = _parse(kc["visited"].get(str(w["place_id"])))
        been_here = been is not None and been >= w["start"]
        if w["place_id"] == SCHOOL_ID:
            if not (day.get("arrived_school_at") or been is not None):
                continue                # not arrived yet = school_mode's late_school
        elif not been_here and local_dt < w["start"] + timedelta(minutes=WINDOW_GRACE_MIN):
            continue                    # travel time to coaching / tuition
        since = max(out_since, w["start"]) if out_since else w["start"]
        if local_dt - since < timedelta(minutes=UNKNOWN_MIN):
            continue
        aid = "%s-%s" % (day.get("date", ""), key.replace(":", ""))
        kc["asks"] = kc["asks"][-9:] + [{
            "id": aid, "key": key, "at": local_dt.isoformat(), "state": "open",
            "place_kind": w["kind"], "place_name": w["name"],
            "out_since": out_since.isoformat() if out_since else None}]
        return [_ev("kc_ask_unknown", local_dt, "ask", ask_id=aid, place_id=w["place_id"],
                    place_kind=w["kind"], place_name=w["name"],
                    lat=last.get("lat"), lng=last.get("lng"))]
    return []


def answer(day, ask_id, ans, local_dt, by_name=""):
    """A guardian's answer: 'ok' ("I know, it is fine") -> no more questions
    for that window today. Returns the ask or None."""
    kc = _kc(day)
    for a in kc["asks"]:
        if a["id"] == ask_id:
            if ans == "ok" and a["key"] not in kc["known"]:
                kc["known"].append(a["key"])
            if a.get("state") == "open":
                a["state"] = "ok"
                a["closed_at"] = local_dt.isoformat()
                a["by"] = str(by_name or "")[:40]
            return a
    return None


def suppress_sm(events):
    """school_mode's immediate left_school_early alarm becomes the corner's
    question (history kept, no push); its back_in_school news goes only
    when a question was actually sent (closed by kc_back_safe instead)."""
    for e in events:
        if e.get("kind") in ("left_school_early", "back_in_school"):
            e["notify"] = "none"
    return events


def step_fix(cfg, day, local_dt, lat=None, lng=None, wifi=None, source="gps"):
    """school_mode.on_fix + the corner, in one call (the only entry the
    position pipelines use). Returns (day, events)."""
    day, ev = SM.on_fix(cfg, day, local_dt, lat, lng, wifi, source)
    ev = suppress_sm(list(ev))
    if lat is not None and lng is not None:
        day, kev = on_fix(cfg, day, local_dt, lat, lng, source or "gps")
        ev += kev
    return day, ev


def today_view(cfg, day, local_dt):
    """What a guardian sees for today: where now (place name only), open
    questions, watch-place entries. Never raw coordinates except the
    question's last position (guardians only — the API checks)."""
    if not day or day.get("date") != local_dt.date().isoformat():
        return {"where": "unknown", "place_kind": "", "place_name": "", "since": None,
                "asks": [], "windows": [], "watch_today": []}
    kc = _kc(dict(day))
    where, pk, pn, since = "unknown", "", "", None
    if kc["inside"]:
        pid = kc["inside"][0]
        pk, pn = _place_label(cfg, pid)
        where, since = "safe", kc["visited"].get(str(pid))
    elif kc["in_watch"]:
        pk, pn = _place_label(cfg, kc["in_watch"][0])
        where, since = "watch", kc["watch_at"].get(str(kc["in_watch"][0]))
    elif kc["out_since"]:
        where, since = "outside", kc["out_since"]
    last = kc.get("last") or {}
    asks = []
    for a in kc["asks"]:
        x = dict(a)
        if a.get("state") == "open":
            x["lat"], x["lng"] = last.get("lat"), last.get("lng")
            x["last_at"] = last.get("at")
        asks.append(x)
    return {"where": where, "place_kind": pk, "place_name": pn, "since": since,
            "asks": asks,
            "windows": [{"kind": w["kind"], "name": w["name"],
                         "start": w["start"].strftime("%H:%M"),
                         "end": w["end"].strftime("%H:%M")}
                        for w in active_windows(cfg, local_dt)],
            "watch_today": [{"place_id": int(k), "at": v}
                            for k, v in sorted(kc["watch_at"].items())]}


def fence_id(plan_id, place_id):
    return FENCE_BASE + int(plan_id) * 100 + int(place_id)


def parse_fence_id(fid):
    """(plan_id, place_id) for a corner fence id, else None."""
    try:
        fid = int(fid)
    except (TypeError, ValueError):
        return None
    if fid < FENCE_BASE:
        return None
    rest = fid - FENCE_BASE
    return rest // 100, rest % 100
