"""train — Train Tracker service (owner priority C, 2 Nov). Flag `train_tracker`.

Crowd sharing ("I am on this train"), timetable estimate, per-train chat and
the after-trip purge. Pure rules live in core/logic/train_geo.py and
core/logic/train_chat.py; this module only touches the DB.

Privacy:
  * a sharer is never shown to anybody: others see ONE fused position and a
    sharer count; the server keeps only the sharer's LAST accepted fix (no
    track), and deletes the share after the trip;
  * the chat shows nicknames only — no user id, name, phone or profile is
    ever returned; "add to My Circle" is a request the other person accepts;
  * everything for a train+date is purged at ends_at (timetable arrival +
    PURGE_AFTER_H) by the existing per-minute journey sweep (no new cron).
"""
from datetime import datetime, timedelta

from django.db import transaction
from django.utils import timezone

from .logic import train_chat as TC
from .logic import train_geo as TG
from .models import (CircleMember, TrainChatBlock, TrainChatMember, TrainChatMessage,
                     TrainChatReport, TrainCircleRequest, TrainSeatAnswer, TrainShare)

PURGE_AFTER_H = 6
REPORT_KEEP_DAYS = 30
MAX_POINTS = 100
MIN_FIX_GAP_S = 5
FUTURE_SLACK_S = 60
PAST_MAX_MIN = 30
# sjtrain (Safe Journey V2): the chat is open only while the train runs —
# from CHAT_OPEN_BEFORE_MIN before departure to CHAT_CLOSE_AFTER_H after the
# timetable arrival (Bangladesh trains are often hours late; a live position
# that has not arrived keeps it open up to train_geo.LATE_END_H). Nothing in
# a room lives longer than CHAT_MAX_H.
CHAT_OPEN_BEFORE_MIN = 30
CHAT_CLOSE_AFTER_H = 3
CHAT_MAX_H = 24


# ------------------------------------------------------------ dates / trains
def today():
    return timezone.now().astimezone(TG.DHAKA).date()


def parse_date(s, now=None):
    """Service date 'YYYY-MM-DD' within yesterday .. tomorrow (Dhaka), else None."""
    try:
        d = datetime.strptime(str(s or "").strip(), "%Y-%m-%d").date()
    except ValueError:
        return None
    t = (now or timezone.now()).astimezone(TG.DHAKA).date()
    return d if t - timedelta(days=1) <= d <= t + timedelta(days=1) else None


def ends_at(t, service_date):
    if t is None:
        return datetime(service_date.year, service_date.month, service_date.day,
                        tzinfo=TG.DHAKA) + timedelta(days=1, hours=12)
    _, arr = TG.times(t, service_date)
    return arr + timedelta(hours=PURGE_AFTER_H)


def _st(sid):
    s = TG.stations().get(sid) or {}
    return {"id": sid, "bn": s.get("bn", ""), "en": s.get("en", ""),
            "lat": s.get("lat"), "lng": s.get("lng")}


# flagprep (2 Nov): the owner ticks "timetable checked" per train in Owner
# Admin -> Train timetable (/owner/train-schedule) instead of editing the JSON
# file. Stored in AdminFlagState key CHECKED_KEY ({"nos": [...]}); the file's
# own "approved": true still counts. Unchecked trains keep the honest
# "timetable not yet checked" line in the app.
CHECKED_KEY = "train_schedule_checked"
_CHECKED_CACHE = "train:checked:v1"


def checked_nos():
    from django.core.cache import cache
    v = cache.get(_CHECKED_CACHE)
    if v is None:
        v = []
        try:
            from .models import AdminFlagState
            row = AdminFlagState.objects.filter(key=CHECKED_KEY).first()
            v = sorted({str(x) for x in ((row.state or {}).get("nos") or [])}) if row else []
        except Exception:  # noqa: BLE001 — never break the train screen
            v = []
        cache.set(_CHECKED_CACHE, v, 60)
    return set(v)


def is_approved(t, checked=None):
    if t.get("approved"):
        return True
    return str(t["no"]) in (checked_nos() if checked is None else checked)


def save_checked(nos, actor=None):
    """Owner Admin: the full set of checked train numbers. Unknown numbers are
    dropped. Returns (before, after) sorted lists."""
    from django.core.cache import cache
    from .models import AdminFlagState
    known = {t["no"] for t in TG.timetable()["trains"]}
    after = sorted({str(n) for n in nos if str(n) in known})
    row, _ = AdminFlagState.objects.get_or_create(key=CHECKED_KEY)
    before = sorted((row.state or {}).get("nos") or [])
    row.state = dict(row.state or {}, nos=after)
    row.audit = ([{"by": getattr(actor, "pk", None), "at": timezone.now().isoformat(),
                   "added": sorted(set(after) - set(before)),
                   "removed": sorted(set(before) - set(after))}] + list(row.audit or []))[:100]
    row.save(update_fields=["state", "audit", "updated_at"])
    cache.delete(_CHECKED_CACHE)
    return before, after


def train_summary(t, checked=None):
    return {"no": t["no"], "name_bn": t["name_bn"], "from": _st(t["from"]),
            "to": _st(t["to"]), "dep": t["dep"], "arr": t["arr"],
            "off_days": t.get("off_days") or [], "km": t.get("km"),
            # flagprep: the owner's per-train tick (Owner Admin -> Train schedule)
            # OR sjalarm: the Owner Admin switch `train_schedule_verified` (all trains)
            "approved": is_approved(t, checked) or _verified()}


def _verified():
    from .sjalarm import schedule_verified
    return schedule_verified()


def search(q):
    q = str(q or "").strip().lower()
    out = []
    checked = checked_nos()
    for t in TG.timetable()["trains"]:
        names = [t["no"], t["name_bn"].lower()]
        for s in t["stops"]:
            st = TG.stations().get(s["st"]) or {}
            names += [st.get("bn", "").lower(), st.get("en", "").lower()]
        if not q or any(q in n for n in names if n):
            out.append(train_summary(t, checked))
    return out[:60]


def data_meta():
    m = TG.timetable()["_meta"]
    return {"trains_source": m.get("trains_source"), "geometry": m.get("geometry"),
            "osm_base": m.get("osm_base"), "built": m.get("built"),
            "approval": m.get("approval"), "schedule_verified": _verified()}


# ------------------------------------------------------------ sharing
def start_share(user, t, service_date, now=None):
    now = now or timezone.now()
    with transaction.atomic():
        TrainShare.objects.filter(user=user, status="active").update(
            status="ended", stopped_at=now)
        return TrainShare.objects.create(user=user, train_no=t["no"],
                                         service_date=service_date, status="active",
                                         ends_at=ends_at(t, service_date))


def stop_share(share, status="ended", now=None):
    if share.status == "active":
        share.status = status
        share.stopped_at = now or timezone.now()
        share.save(update_fields=["status", "stopped_at"])
    return share


def _parse_at(v, now):
    try:
        at = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
        if timezone.is_naive(at):
            at = timezone.make_aware(at, TG.DHAKA)
    except (TypeError, ValueError):
        return None
    if at > now + timedelta(seconds=FUTURE_SLACK_S) or at < now - timedelta(minutes=PAST_MAX_MIN):
        return None
    return min(at, now)


def add_fixes(share, points, now=None):
    """Validate a batch from the sharer's phone. Only the LAST accepted fix is
    stored. Returns {accepted, rejected, reasons, status}."""
    now = now or timezone.now()
    t = TG.train(share.train_no)
    if share.status == "active" and now >= share.ends_at:
        stop_share(share, "ended", now)
    if share.status != "active" or t is None:
        return {"accepted": 0, "rejected": 0, "reasons": {}, "status": share.status}
    pts = []
    for p in (points or [])[:MAX_POINTS]:
        if not isinstance(p, dict):
            continue
        if p.get("mock"):              # train-engine: isFromMockProvider -> refused
            pts.append(None)
            continue
        at = _parse_at(p.get("at"), now)
        try:
            fix = {"lat": float(p["lat"]), "lng": float(p["lng"]),
                   "acc": float(p.get("acc") or 0), "at": at,
                   "speed_kmh": (float(p["speed_kmh"]) if p.get("speed_kmh") is not None else None),
                   "bearing": (float(p["bearing"]) if p.get("bearing") is not None else None)}
        except (KeyError, TypeError, ValueError):
            fix = None
        pts.append(fix)
    acc = rej = 0
    reasons = dict(share.reasons or {})
    prev = None
    if share.last_fix_at is not None:
        prev = {"chainage": share.last_chainage, "at": share.last_fix_at,
                "lat": share.last_lat, "lng": share.last_lng}
    for fix in sorted([f for f in pts if f and f["at"]], key=lambda f: f["at"]):
        if prev and (fix["at"] - prev["at"]).total_seconds() < MIN_FIX_GAP_S:
            continue
        ok, why, ch, _ = TG.validate_fix(t, share.service_date, fix, prev)
        if ok:
            acc += 1
            prev = {"chainage": ch, "at": fix["at"], "lat": fix["lat"], "lng": fix["lng"],
                    "speed": fix["speed_kmh"]}
        else:
            rej += 1
            reasons[why] = int(reasons.get(why, 0)) + 1
    rej += sum(1 for f in pts if not f or not f["at"])
    if any(not f or not f["at"] for f in pts):
        reasons["bad_point"] = int(reasons.get("bad_point", 0)) + sum(
            1 for f in pts if not f or not f["at"])
    fields = ["accepted", "rejected", "reasons"]
    share.accepted += acc
    share.rejected += rej
    share.reasons = reasons
    if prev and acc:
        share.last_chainage, share.last_fix_at = prev["chainage"], prev["at"]
        share.last_lat, share.last_lng = prev["lat"], prev["lng"]
        share.last_speed = prev.get("speed")
        fields += ["last_chainage", "last_fix_at", "last_lat", "last_lng", "last_speed"]
        rt = TG.route(t["no"])
        if rt is not None and prev["chainage"] >= rt.length - TG.ARRIVE_M:
            share.status, share.stopped_at = "arrived", now
            fields += ["status", "stopped_at"]
    share.save(update_fields=fields)
    return {"accepted": acc, "rejected": rej, "reasons": reasons, "status": share.status}


def live_view(t, service_date, user=None, now=None):
    """The public train view: fused live position or the timetable estimate."""
    now = now or timezone.now()
    rt = TG.route(t["no"])
    latest = [{"chainage": s.last_chainage, "at": s.last_fix_at, "speed_kmh": s.last_speed}
              for s in TrainShare.objects.filter(
                  train_no=t["no"], service_date=service_date,
                  status__in=("active", "arrived"), last_fix_at__isnull=False)]
    live = TG.fuse(t, latest, now)
    est = TG.estimate(t, service_date, now)
    if est is not None:
        est["approved"] = is_approved(t)
    if live:
        live["delay_min"] = TG.delay_minutes(t, service_date, live["chainage_m"], now)
        live["next_stop"] = _st(TG.next_stop_after(t, live["chainage_m"])) \
            if TG.next_stop_after(t, live["chainage_m"]) else None
    if est:
        est = dict(est, dep=est["dep"].isoformat(), arr=est["arr"].isoformat(),
                   approved=bool(est.get("approved")) or _verified(),
                   next_stop=_st(est["next_stop"]) if est["next_stop"] else None)
    stops = []
    if rt is not None:
        for e in TG.stop_etas(t, rt, service_date):
            stops.append(dict(_st(e["st"]), km=e["km"], at=e["at"].isoformat(),
                              label="estimate"))
    mine = None
    if user is not None:
        s = TrainShare.objects.filter(user=user, train_no=t["no"],
                                      service_date=service_date).order_by("-id").first()
        if s:
            mine = {"id": s.id, "status": s.status, "accepted": s.accepted,
                    "rejected": s.rejected}
    pos_ch = None
    if live:
        pos_ch = float(live["chainage_m"])
    elif est and est.get("state") == "running":
        pos_ch = float(est["chainage_m"])
    elif est and est.get("state") == "arrived" and rt is not None:
        pos_ch = rt.length
    line = TG.line_view(t, service_date, pos_ch, now,
                        delay_min=(live or {}).get("delay_min") if live else None)
    return {
        "train": train_summary(t), "date": service_date.isoformat(),
        "runs": TG.runs_on(t, service_date),
        "mode": "live" if live else "estimate",
        # sjtrain: the metro-style station line + header facts
        "line": line,
        "sharers": int(live["sharers"]) if live else 0,
        "delay_min": live.get("delay_min") if live else None,
        "chat": chat_window(t, service_date, now, live),
        "live": live, "estimate": est, "stops": stops,
        "path": t.get("path") or [],
        "sms": {"to": TC.SMS_TO, "body": TC.sms_body(t["no"]), "cost_bdt": TC.SMS_COST_BDT},
        "my_share": mine,
        "chat_count": TrainChatMessage.objects.filter(
            train_no=t["no"], service_date=service_date, hidden=False).count(),
        "source": t.get("source") or {},
    }


# ------------------------------------------------------------ chat
def member_of(user, no, service_date):
    return TrainChatMember.objects.filter(user=user, train_no=no,
                                          service_date=service_date).first()


def join(user, t, service_date, nickname):
    nick, err = TC.clean_nickname(nickname)
    if err:
        return None, err
    m = member_of(user, t["no"], service_date)
    if m:
        m.nickname = nick
        m.save(update_fields=["nickname"])
        return m, None
    return TrainChatMember.objects.create(user=user, train_no=t["no"], service_date=service_date,
                                          nickname=nick, ends_at=ends_at(t, service_date)), None


def _blocked_ids(user):
    return set(TrainChatBlock.objects.filter(blocker=user).values_list("blocked_id", flat=True))


def rate_limited(user, now=None):
    now = now or timezone.now()
    qs = TrainChatMessage.objects.filter(member__user=user)
    if qs.filter(at__gte=now - timedelta(minutes=1)).count() >= TC.PER_MIN:
        return True
    return qs.filter(at__gte=now - timedelta(days=1)).count() >= TC.PER_DAY


def chat_window(t, service_date, now=None, live=None):
    """sjtrain: {"open", "opens_at", "closes_at"} — open only while the train
    runs (see CHAT_OPEN_BEFORE_MIN / CHAT_CLOSE_AFTER_H)."""
    now = now or timezone.now()
    dep, arr = TG.times(t, service_date)
    opens = dep - timedelta(minutes=CHAT_OPEN_BEFORE_MIN)
    closes = arr + timedelta(hours=CHAT_CLOSE_AFTER_H)
    if live is None:
        try:
            live = TG.fuse(t, [{"chainage": x.last_chainage, "at": x.last_fix_at,
                                "speed_kmh": x.last_speed}
                               for x in TrainShare.objects.filter(
                                   train_no=t["no"], service_date=service_date,
                                   status="active", last_fix_at__isnull=False)], now)
        except Exception:  # noqa: BLE001 — the window never breaks the chat
            live = None
    if live and not live.get("arrived"):
        closes = max(closes, min(arr + timedelta(hours=TG.LATE_END_H), now + timedelta(minutes=10)))
    return {"open": opens <= now <= closes, "opens_at": opens.isoformat(),
            "closes_at": closes.isoformat()}


def post(member, text, now=None):
    if timezone.now() >= member.ends_at:
        return None, "trip_over"
    t = TG.train(member.train_no)
    if t is not None and not chat_window(t, member.service_date, now)["open"]:
        return None, "not_running"
    clean, err = TC.clean_message(text)
    if err:
        return None, err
    if rate_limited(member.user, now):
        return None, "rate_limited"
    # sjtrain: AI moderation, step 1 = the shared on-server abuse filter
    # (instant, free, Bangla + Banglish): abuse / threat / hate / sexual is
    # refused before anyone sees it; a plain insult is posted but goes to
    # the AI check like everything else (step 2, after the commit).
    from . import ai_guard
    tox = ai_guard.toxicity(clean)
    if tox["severity"] >= 2:
        return None, "not_allowed"
    m = TrainChatMessage.objects.create(
        member=member, train_no=member.train_no, service_date=member.service_date,
        text=clean, emergency=TC.is_emergency(clean), ends_at=member.ends_at,
        hidden=False)
    if not m.emergency:     # a call for help is never held back
        _ai_check_later(m.id)
    return m, None


MOD_FEATURE = "train.chat_mod"
MOD_TASK = ("You moderate a public chat among passengers of one train in Bangladesh "
            "(Bangla, Banglish or English). Reply with ONE word only: OK or HIDE. "
            "HIDE when the message harasses or insults someone, is sexual, threatens, "
            "spreads hate, asks for money or sells something, shares or asks for a "
            "phone number, address or social-media id, or tries to move a stranger "
            "into a private chat or meeting. Questions about the train, seats, "
            "stations, delays, food or help are OK.")


def ai_moderate(msg_id):
    """Step 2: the shared AI router (cheap class) reads ONE message and may
    hide it for everyone. Best-effort: no key / budget / error = the local
    filter's decision stands. Returns "ok" | "hidden" | "skipped"."""
    from . import ai
    m = TrainChatMessage.objects.filter(pk=msg_id).first()
    if m is None or m.hidden:
        return "skipped"
    try:
        out, _cost = ai.generate(MOD_TASK, data=m.text, tier="cheap", max_tokens=8,
                                 feature="train.chat_mod", user=None, pii=True)
    except Exception:  # noqa: BLE001 — AIUnavailable or a provider hiccup
        return "skipped"
    if "HIDE" in str(out or "").upper():
        TrainChatMessage.objects.filter(pk=msg_id).update(hidden=True)
        return "hidden"
    return "ok"


def _ai_check_later(msg_id):
    """After the commit, in one daemon thread (the poster never waits for the
    AI); inline under PUSH_SYNC (tests), like missing_alert._run_bg."""
    from django.conf import settings
    if getattr(settings, "PUSH_SYNC", False):
        transaction.on_commit(lambda: ai_moderate(msg_id))
        return

    def run():
        from django.db import close_old_connections, connection
        try:
            close_old_connections()
            ai_moderate(msg_id)
        except Exception:  # noqa: BLE001
            pass
        finally:
            try:
                connection.close()
            except Exception:  # noqa: BLE001
                pass

    import threading
    transaction.on_commit(lambda: threading.Thread(target=run, daemon=True,
                                                   name="train-chat-mod").start())


def msg_json(m, me_member):
    """NEVER a user id / phone / name: nickname + mine flag only."""
    return {"id": m.id, "nick": m.member.nickname, "mine": m.member_id == getattr(me_member, "id", None),
            "text": m.text, "at": m.at.isoformat(), "emergency": m.emergency}


def room(user, no, service_date, after=0):
    me = member_of(user, no, service_date)
    blocked = _blocked_ids(user)
    qs = (TrainChatMessage.objects.filter(train_no=no, service_date=service_date, hidden=False,
                                          id__gt=int(after or 0))
          .exclude(member__user_id__in=blocked).select_related("member").order_by("id"))
    msgs = list(qs[:200])
    reqs = []
    if me:
        for r in (TrainCircleRequest.objects.filter(to_member=me, state="pending")
                  .exclude(from_member__user_id__in=blocked).select_related("from_member")):
            reqs.append({"id": r.id, "nick": r.from_member.nickname})
    t = TG.train(no)
    return {"me": {"nickname": me.nickname} if me else None,
            "chat": chat_window(t, service_date) if t is not None else None,
            "messages": [msg_json(m, me) for m in msgs],
            "circle_requests": reqs,
            "ends_at": me.ends_at.isoformat() if me else None,
            "hotlines": {"police": TC.POLICE, "rail": TC.RAIL_HOTLINE}}


def report(user, msg, reason="other"):
    if msg.member.user_id == user.id:
        return "self"
    day = timezone.now() - timedelta(days=1)
    if TrainChatReport.objects.filter(reporter=user, created_at__gte=day).count() >= TC.REPORTS_PER_DAY:
        return "rate_limited"
    TrainChatReport.objects.create(reporter=user, reported_id=msg.member.user_id,
                                   train_no=msg.train_no, service_date=msg.service_date,
                                   text=msg.text, reason=str(reason or "other")[:30])
    rep = list(msg.reporters or [])
    if user.id not in rep:
        rep.append(user.id)
    msg.reporters = rep
    msg.hidden = len(rep) >= TC.HIDE_AFTER_REPORTS
    msg.save(update_fields=["reporters", "hidden"])
    _queue_for_owner(user, msg, reason)
    return "ok"


def _queue_for_owner(user, msg, reason):
    """playaudit2 (Play UGC policy): a train-chat report also lands in the
    owner's moderation queue (Owner Admin -> Channel reports, kind "person")
    so a human reviews it — the reported text rides along as the snapshot
    (the room itself is public to that train and deleted after the trip).
    Best-effort: a queue hiccup never fails the user's report."""
    try:
        with transaction.atomic():  # savepoint: never poisons the caller
            from .logic import msg_moderation as mmod
            from .models import ModerationItem, ModerationReport
            cats = mmod.normalize_categories([reason]) or [mmod.R_OTHER]
            tid = str(msg.member.user_id)
            ModerationReport.objects.create(
                reporter=user, target_kind=mmod.T_PERSON, target_id=tid,
                categories=cats, valid=True,
                note=("train %s %s" % (msg.train_no, msg.service_date))[:200],
                snapshot=[{"text": (msg.text or "")[:500], "msg_id": msg.id}],
                snapshot_source="train_chat")
            severe = mmod.is_severe(cats)
            item = ModerationItem.objects.filter(
                target_kind=mmod.T_PERSON, target_id=tid).exclude(
                queue_state=mmod.Q_RESOLVED).order_by("-opened_at").first()
            if item is None:
                built = mmod.build_queue_item(None, mmod.T_PERSON, tid, cats, severe,
                                              mmod.STATUS_VISIBLE)
                ModerationItem.objects.create(
                    target_kind=mmod.T_PERSON, target_id=tid,
                    categories=built["categories"], severe=built["severe"],
                    content_status=built["content_status"],
                    queue_state=built["queue_state"],
                    legal_retention=built["legal_retention"], report_count=1)
            else:
                b = mmod.bump_queue_item(
                    {"report_count": item.report_count, "categories": item.categories,
                     "legal_retention": item.legal_retention, "severe": item.severe,
                     "queue_state": item.queue_state}, severe=severe, categories=cats)
                for k in ("report_count", "categories", "legal_retention", "severe",
                          "queue_state"):
                    setattr(item, k, b[k])
                item.save()
    except Exception:  # noqa: BLE001
        import logging
        logging.getLogger(__name__).warning("train report -> moderation queue failed",
                                            exc_info=True)


def block(user, msg):
    if msg.member.user_id == user.id:
        return "self"
    TrainChatBlock.objects.get_or_create(blocker=user, blocked_id=msg.member.user_id)
    TrainCircleRequest.objects.filter(from_member__user_id=msg.member.user_id,
                                      to_member__user=user, state="pending").update(
        state="declined", acted_at=timezone.now())
    return "ok"


def circle_request(me_member, msg):
    """A REQUEST only; nothing about either side is revealed until accept."""
    to = msg.member
    if to.user_id == me_member.user_id:
        return None, "self"
    if TrainCircleRequest.objects.filter(from_member=me_member).count() >= TC.CIRCLE_REQ_PER_ROOM:
        return None, "rate_limited"
    existing = TrainCircleRequest.objects.filter(from_member=me_member, to_member=to).first()
    if existing:
        return existing, "ok"
    if TrainChatBlock.objects.filter(blocker_id=to.user_id, blocked_id=me_member.user_id).exists():
        # silently "sent" — a block is never revealed
        return TrainCircleRequest(from_member=me_member, to_member=to, state="pending"), "ok"
    return TrainCircleRequest.objects.create(from_member=me_member, to_member=to), "ok"


def act_request(user, req, accept):
    if req.to_member.user_id != user.id or req.state != "pending":
        return "not_found"
    req.state = "accepted" if accept else "declined"
    req.acted_at = timezone.now()
    req.save(update_fields=["state", "acted_at"])
    if accept:
        _connect(req.from_member.user, user)
    return "ok"


def _connect(a, b):
    """The recipient accepted: both become My Circle members (accepted pair)."""
    from . import connect_flow, msgreq
    from .logic import circle
    if msgreq.i_blocked(a, b) or msgreq.i_blocked(b, a):
        return
    if CircleMember.objects.filter(user=a, peer_user=b, state="accepted").exists():
        return
    with transaction.atomic():
        CircleMember.objects.filter(user__in=(a, b), peer_user__in=(a, b), state="pending").delete()
        CircleMember.objects.create(user=a, peer_user=b, direction="outgoing",
                                    name=(b.name or "")[:120], phone=(b.phone or "")[:40],
                                    relation="friend", state="accepted",
                                    sharing=circle.default_sharing("friend"))
        inc = CircleMember.objects.create(user=b, peer_user=a, direction="incoming",
                                          name=(a.name or "")[:120], phone=(a.phone or "")[:40],
                                          relation="friend", state="accepted",
                                          sharing=circle.default_sharing("friend"))
    try:
        from . import e2_keys
        e2_keys.ensure_pair_keys(a, b)
    except Exception:  # noqa: BLE001 — keys are best-effort plumbing
        pass
    connect_flow.on_connected(inc)


def leave(user, no, service_date):
    m = member_of(user, no, service_date)
    if m:
        m.delete()   # cascades: their messages + requests


# ------------------------------------------------------------ purge
def purge(now, stats):
    """After the trip: delete the whole room + shares. Called from
    journey_watch.sweep (existing per-minute cron)."""
    n = TrainChatMessage.objects.filter(ends_at__lte=now).delete()[0]
    # sjtrain: nothing said in a train chat outlives 24 hours
    n += TrainChatMessage.objects.filter(at__lte=now - timedelta(hours=CHAT_MAX_H)).delete()[0]
    n += TrainChatMember.objects.filter(
        joined_at__lte=now - timedelta(hours=CHAT_MAX_H)).delete()[0]
    n += TrainChatMember.objects.filter(ends_at__lte=now).delete()[0]
    TrainShare.objects.filter(status="active", ends_at__lte=now).update(
        status="ended", stopped_at=now)
    n += TrainShare.objects.filter(ends_at__lte=now).delete()[0]
    n += TrainChatReport.objects.filter(
        created_at__lte=now - timedelta(days=REPORT_KEEP_DAYS)).delete()[0]
    if n:
        stats["train_purged"] += n


# ------------------------------------------------------------ sjtrain: seat card
SEAT_VERIFY_N = 3          # distinct people agreeing before a fact is "verified"
SEAT_VERIFY_SHARE = 0.66   # ... and at least this share of all answers
SEAT_ANSWERS_PER_DAY = 6
SEAT_ANSWER_AFTER_H = 12   # answers accepted from departure up to this long after arrival
_SEAT_CHOICES = {"facing": ("forward", "backward"), "place": ("window", "aisle", "middle"),
                 "side": ("left", "right")}


def clean_seat_key(coach, seat):
    """Ticket-style coach / seat ('ঝ', 'KA', 'Cha' / '32'): short, no
    symbols. -> (coach, seat) or None."""
    import re
    c = re.sub(r"[^\wঀ-৿]", "", str(coach or ""))[:8].upper()
    st = re.sub(r"[^\wঀ-৿]", "", str(seat or ""))[:8].upper()
    return (c, st) if c and st else None


def _vote(values):
    """{"value", "n", "agree", "verified"} for one field (None = no answer)."""
    vals = [v for v in values if v not in ("", None)]
    if not vals:
        return None
    from collections import Counter
    top, k = Counter(vals).most_common(1)[0]
    return {"value": top, "n": len(vals), "agree": k,
            "verified": k >= SEAT_VERIFY_N and k / float(len(vals)) >= SEAT_VERIFY_SHARE}


def seat_view(t, coach, seat, service_date=None, user=None):
    """The seat card. Crowd facts (unverified until SEAT_VERIFY_N people
    agree), the coach's place from the engine, and the CALCULATED sun side
    for this trip. Never a name or user id."""
    rows = list(TrainSeatAnswer.objects.filter(train_no=t["no"], coach=coach, seat=seat)
                .values("facing", "place", "side"))
    coach_rows = list(TrainSeatAnswer.objects.filter(train_no=t["no"], coach=coach)
                      .exclude(coach_pos=None).values_list("coach_pos", flat=True))
    out = {"train": t["no"], "coach": coach, "seat": seat, "answers": len(rows),
           "facing": _vote([r["facing"] for r in rows]),
           "place": _vote([r["place"] for r in rows]),
           "side": _vote([r["side"] for r in rows]),
           "coach_pos": _vote(list(coach_rows)),
           "verify_n": SEAT_VERIFY_N}
    sd = service_date or today()
    sun = TG.sun_side(t, sd)
    out["sun"] = sun
    side = (out["side"] or {}).get("value")
    out["sun_on_seat"] = None
    if sun and side:
        out["sun_on_seat"] = {"pct": sun.get(side, 0), "label": "calculated"}
    mine = None
    if user is not None:
        a = TrainSeatAnswer.objects.filter(user=user, train_no=t["no"], coach=coach,
                                           seat=seat).first()
        if a:
            mine = {"facing": a.facing, "place": a.place, "side": a.side,
                    "coach_pos": a.coach_pos}
    out["mine"] = mine
    return out


def seat_answer(user, t, service_date, coach, seat, data, now=None):
    """One-tap answers after (or during) a trip. -> (view, None) | (None, why)."""
    now = now or timezone.now()
    dep, arr = TG.times(t, service_date)
    if not (dep - timedelta(minutes=CHAT_OPEN_BEFORE_MIN) <= now <=
            arr + timedelta(hours=SEAT_ANSWER_AFTER_H)):
        return None, "not_this_trip"
    vals = {}
    for k, ok in _SEAT_CHOICES.items():
        v = str((data or {}).get(k) or "").strip().lower()
        if v and v not in ok:
            return None, "bad_" + k
        vals[k] = v
    cp = (data or {}).get("coach_pos")
    if cp not in (None, ""):
        try:
            cp = int(cp)
        except (TypeError, ValueError):
            return None, "bad_coach_pos"
        if not 1 <= cp <= 30:
            return None, "bad_coach_pos"
    else:
        cp = None
    if not any(vals.values()) and cp is None:
        return None, "empty"
    existing = TrainSeatAnswer.objects.filter(user=user, train_no=t["no"], coach=coach,
                                              seat=seat).first()
    if existing is None and TrainSeatAnswer.objects.filter(
            user=user, created_at__gte=now - timedelta(days=1)).count() >= SEAT_ANSWERS_PER_DAY:
        return None, "rate_limited"
    if existing is None:
        TrainSeatAnswer.objects.create(user=user, train_no=t["no"], coach=coach, seat=seat,
                                       coach_pos=cp, **vals)
    else:
        for k, v in vals.items():
            if v:
                setattr(existing, k, v)
        if cp is not None:
            existing.coach_pos = cp
        existing.save()
    return seat_view(t, coach, seat, service_date, user), None
