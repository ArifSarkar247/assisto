"""fcelder — Silent Watch (Family Care V3 Brain 1) + Elder setup by a child.

PRIVACY FIRST: the elder's phone learns the elder's normal day ON THE PHONE
(7 days) and decides on its own when a silence is unusual. It first rings the
ELDER ("Are you OK?", 3 times over ~30 min). Only when nobody answers does the
phone send ONE event here (``alert``). The server never receives a tracking
stream — no unlock times, no app-use pings, no heartbeats. The only other
server-side trigger is a Care Call the server already knows went unanswered
after its retries (``on_carecall_missed``): then the server asks the elder
first ("Are you OK?" push) and starts the ladder only if that stays
unanswered for ASK_WAIT_MIN.

Ladder (``tick``, run from the existing Care Call minute tick):
    step 1  the SETTER (the child who set the watch up)  — amber, now
    step 2  ALL family                                   — +LADDER_MIN
    step 3  the chosen NEARBY person                     — +2*LADDER_MIN
Anyone tapping "I am checking" (ack) or the elder tapping "I am OK" (ok)
stops the ladder; everyone already told hears the outcome.

Storage: the generic PaCollectionItem rows (no migration):
    sw_cfg   on the elder   {enabled, setter_id, nearby_user_id, hours,
                             day_start, day_end, token_hash, consent_at}
    sw_pair  on the child   {code, elder_id, exp, plan{...}, used_at}
    sw_alert on the elder   {status asking|open|resolved, kind, step, due,
                             opened_at, notified[], silent_min, resolved_*}
Always free, never ads (safety).
"""
import hashlib
import logging
import secrets
from datetime import timedelta

from django.utils import timezone
from django.utils.dateparse import parse_datetime

log = logging.getLogger(__name__)

SOURCE = "fcelder"
ASK_WAIT_MIN = 15        # server-side "Are you OK?" (Care Call path) before the ladder
LADDER_MIN = 15          # setter -> all family -> nearby person
PAIR_TTL_MIN = 15
DEFAULT_HOURS = 4
HOURS_RANGE = (2, 12)
DEFAULT_DAY = ("07:00", "22:00")
KINDS = ("inactivity", "carecall", "test")
_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"   # no 0/O, 1/I/L


# ------------------------------------------------------------ helpers
def _now(now=None):
    return now or timezone.now()


def _iso(dt):
    return dt.isoformat() if dt else None


def _dt(s):
    try:
        return parse_datetime(s) if s else None
    except (TypeError, ValueError):
        return None


def _hash(token):
    return hashlib.sha256((token or "").encode()).hexdigest()


def _valid_hhmm(s):
    try:
        h, m = str(s).split(":")
        return 0 <= int(h) < 24 and 0 <= int(m) < 60 and len(str(s)) == 5
    except (TypeError, ValueError):
        return False


def _user(pk):
    from .models import User
    try:
        return User.objects.filter(pk=int(pk)).first()
    except (TypeError, ValueError):
        return None


def name_for(viewer, other):
    try:
        from .carecall import name_for as cc_name
        return cc_name(viewer, other)
    except Exception:  # noqa: BLE001
        from .push import display_name
        return display_name(other)


def _push(user, kind, tbn, ten, bbn="", ben="", data=None):
    """Safety push: high priority, never counted against the 3/day
    non-safety notification budget (fcbrain notif_budget)."""
    try:
        from .push import push_to_user_async
        return push_to_user_async(user, kind, tbn, ten, bbn, ben,
                                  data=data or {}, high_priority=True)
    except Exception:  # noqa: BLE001
        return False


# ------------------------------------------------------------ family (ONE swap point)
def family_ids(elder):
    """User ids of the elder's family. Family Care v3 families first
    (fcscreen core.family_v3.members_of), else the elder's accepted,
    consenting My Circle members. Never raises."""
    ids = []
    try:
        from . import family_v3  # fcscreen
        ids = [int(m["user_id"]) for m in family_v3.members_of(elder) if m.get("user_id")]
    except Exception:  # noqa: BLE001 — not merged yet / table missing
        ids = []
    if not ids:
        try:
            from .family_alerts import consenting_members
            ids = [u.pk for u, _m in consenting_members(elder)]
        except Exception:  # noqa: BLE001
            ids = []
    return [i for i in dict.fromkeys(ids) if i != elder.pk]


def family_people(user):
    """[{user_id, name, phone, relation}] for one-tap calls on Easy Home
    (relation as THIS user calls them: son / daughter / ...). Family Care v3
    first, else accepted My Circle members."""
    out = []
    try:
        from . import family_v3  # fcscreen
        for m in family_v3.members_of(user):
            out.append({"user_id": m.get("user_id"), "name": m.get("label") or m.get("name") or "",
                        "phone": m.get("phone") or "", "relation": m.get("relation") or ""})
    except Exception:  # noqa: BLE001
        out = []
    if not out:
        try:
            from .family_alerts import consenting_members
            for u, m in consenting_members(user):
                out.append({"user_id": u.pk, "name": name_for(user, u),
                            "phone": (m.phone or getattr(u, "phone", "") or ""),
                            "relation": (m.relation or "").lower()})
        except Exception:  # noqa: BLE001
            out = []
    return out


def is_family(elder, user):
    return user is not None and user.pk in family_ids(elder)


def _amber(elder, reason):
    try:
        from . import family_v3
        family_v3.set_member_status(elder, "amber", reason, SOURCE)
    except Exception:  # noqa: BLE001
        pass


def _clear_amber(elder):
    try:
        from . import family_v3
        family_v3.clear_member_status(elder, SOURCE)
    except Exception:  # noqa: BLE001
        pass


# ------------------------------------------------------------ rows
def _row(user, collection):
    from .models import PaCollectionItem
    return PaCollectionItem.objects.filter(user=user, collection=collection).order_by("-id").first()


def cfg_row(elder):
    return _row(elder, "sw_cfg")


def cfg_of(elder):
    r = cfg_row(elder)
    return dict(r.data) if r is not None else {}


def _save_cfg(elder, data):
    from .models import PaCollectionItem
    r = cfg_row(elder)
    if r is None:
        return PaCollectionItem.objects.create(user=elder, collection="sw_cfg", data=data)
    r.data = data
    r.save(update_fields=["data", "updated_at"])
    return r


def open_alert(elder):
    from .models import PaCollectionItem
    for r in PaCollectionItem.objects.filter(user=elder, collection="sw_alert").order_by("-id")[:5]:
        if (r.data or {}).get("status") in ("asking", "open", "checking"):
            return r
    return None


def public_cfg(elder):
    c = cfg_of(elder)
    setter = _user(c.get("setter_id"))
    nearby = _user(c.get("nearby_user_id"))
    return {
        "enabled": bool(c.get("enabled")),
        "hours": int(c.get("hours") or DEFAULT_HOURS),
        "day_start": c.get("day_start") or DEFAULT_DAY[0],
        "day_end": c.get("day_end") or DEFAULT_DAY[1],
        "setter_id": setter.pk if setter else None,
        "setter_name": name_for(elder, setter) if setter else "",
        "nearby_user_id": nearby.pk if nearby else None,
        "nearby_name": name_for(elder, nearby) if nearby else "",
        "consent_at": c.get("consent_at"),
    }


def alert_dict(r, viewer=None):
    d = dict(r.data or {})
    elder = r.user
    return {
        "id": r.pk, "elder_id": elder.pk,
        "elder_name": name_for(viewer, elder) if viewer else "",
        "status": d.get("status"), "kind": d.get("kind"), "step": int(d.get("step") or 0),
        "opened_at": d.get("opened_at"), "silent_min": d.get("silent_min"),
        "checking_name": d.get("checking_name") or "",
        "resolved_by": d.get("resolved_by"), "resolved_at": d.get("resolved_at"),
    }


# ------------------------------------------------------------ config (elder side)
def _clean_cfg(data, elder, base):
    out = dict(base)
    if "enabled" in data:
        out["enabled"] = bool(data.get("enabled"))
    if "hours" in data:
        try:
            h = int(data.get("hours"))
        except (TypeError, ValueError):
            return None, "bad_hours"
        if not HOURS_RANGE[0] <= h <= HOURS_RANGE[1]:
            return None, "bad_hours"
        out["hours"] = h
    for k in ("day_start", "day_end"):
        if k in data:
            if not _valid_hhmm(data.get(k)):
                return None, "bad_day"
            out[k] = data.get(k)
    if "nearby_user_id" in data:
        nid = data.get("nearby_user_id")
        if nid in (None, "", 0):
            out["nearby_user_id"] = None
        else:
            nu = _user(nid)
            setter = _user(out.get("setter_id"))
            ok = nu is not None and nu.pk != elder.pk and (
                is_family(elder, nu) or (setter is not None and is_family(setter, nu)))
            if not ok:
                return None, "nearby_not_family"
            out["nearby_user_id"] = nu.pk
    return out, None


def set_config(elder, data):
    """Elder: change hours / day window / nearby person, or turn off. Turning
    it off tells the setter (no hidden switch-offs, no hidden watching)."""
    base = cfg_of(elder)
    if not base:
        return None, "not_set_up"
    new, err = _clean_cfg(data or {}, elder, base)
    if err:
        return None, err
    _save_cfg(elder, new)
    if base.get("enabled") and not new.get("enabled"):
        r = open_alert(elder)
        if r is not None:
            resolve(elder, by="off")
        setter = _user(new.get("setter_id"))
        if setter is not None:
            n = name_for(setter, elder)
            _push(setter, "silentwatch_off",
                  "%s নীরব পাহারা বন্ধ করেছেন" % n, "%s turned Silent Watch off" % n,
                  "উনি চাইলে আবার চালু করতে পারবেন।", "They can turn it back on any time.",
                  data={"route": "family", "elder_id": str(elder.pk)})
    return public_cfg(elder), None


def rotate_token(elder):
    """A fresh alert token for the elder's phone (reinstall / new phone).
    Only the hash is stored."""
    c = cfg_of(elder)
    if not c:
        return None
    tok = secrets.token_urlsafe(32)
    c["token_hash"] = _hash(tok)
    _save_cfg(elder, c)
    return tok


def elder_for_token(token):
    from .models import PaCollectionItem
    if not token or len(token) < 20:
        return None
    r = PaCollectionItem.objects.filter(collection="sw_cfg", data__token_hash=_hash(token)).first()
    return r.user if r is not None else None


# ------------------------------------------------------------ setup by a child (QR)
def _new_code():
    return "".join(secrets.choice(_CODE_ALPHABET) for _ in range(8))


def start_pair(child, data, now=None):
    """Child: a one-time, 15-minute code (shown as a QR) that configures one
    chosen family member's phone. The elder must be in the child's family."""
    from .models import PaCollectionItem
    now = _now(now)
    elder = _user((data or {}).get("elder_user_id"))
    if elder is None or elder.pk == child.pk or not is_family(child, elder):
        return None, "not_family"
    plan = {
        "easy_home": bool(data.get("easy_home", True)),
        "silent_watch": bool(data.get("silent_watch", True)),
        "carecall": bool(data.get("carecall", True)),
    }
    cfg, err = _clean_cfg({k: data[k] for k in ("hours", "day_start", "day_end") if k in data},
                          elder, {"hours": DEFAULT_HOURS, "day_start": DEFAULT_DAY[0],
                                  "day_end": DEFAULT_DAY[1], "setter_id": child.pk})
    if err:
        return None, err
    nid = data.get("nearby_user_id")
    if nid not in (None, "", 0):
        nu = _user(nid)
        if nu is None or nu.pk == elder.pk or not (is_family(child, nu) or is_family(elder, nu)):
            return None, "nearby_not_family"
        cfg["nearby_user_id"] = nu.pk
    # one live code per child: older unused ones die
    PaCollectionItem.objects.filter(user=child, collection="sw_pair").delete()
    code = _new_code()
    exp = now + timedelta(minutes=PAIR_TTL_MIN)
    PaCollectionItem.objects.create(user=child, collection="sw_pair", data={
        "code": code, "elder_id": elder.pk, "exp": _iso(exp), "plan": plan, "cfg": cfg})
    return {"code": code, "url": "https://lifeassisto.com/e/%s" % code,
            "expires_at": _iso(exp), "ttl_s": PAIR_TTL_MIN * 60,
            "elder_id": elder.pk, "elder_name": name_for(child, elder), "plan": plan}, None


def _pair_row(code, now=None):
    from .models import PaCollectionItem
    code = (code or "").translate(str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789"))
    code = "".join(ch for ch in code.upper() if ch.isascii() and ch.isalnum())
    if len(code) != 8:
        return None, "bad_code"
    r = PaCollectionItem.objects.filter(collection="sw_pair", data__code=code).first()
    if r is None or (r.data or {}).get("used_at"):
        return None, "bad_code"
    exp = _dt((r.data or {}).get("exp"))
    if exp is None or exp < _now(now):
        return None, "code_expired"
    return r, None


def preview_pair(elder, code, now=None):
    r, err = _pair_row(code, now)
    if err:
        return None, err
    if int(r.data.get("elder_id") or 0) != elder.pk:
        return None, "wrong_phone"
    child = r.user
    return {"child_id": child.pk, "child_name": name_for(elder, child),
            "plan": r.data.get("plan") or {}, "hours": r.data["cfg"].get("hours"),
            "day_start": r.data["cfg"].get("day_start"), "day_end": r.data["cfg"].get("day_end")}, None


def accept_pair(elder, code, now=None):
    """Elder said YES on the spoken consent screen: configure everything in
    one go and hand the phone its alert token (shown once)."""
    now = _now(now)
    r, err = _pair_row(code, now)
    if err:
        return None, err
    if int(r.data.get("elder_id") or 0) != elder.pk:
        return None, "wrong_phone"
    child = r.user
    plan = r.data.get("plan") or {}
    base = cfg_of(elder)
    cfg = dict(base)
    cfg.update(r.data.get("cfg") or {})
    cfg["enabled"] = bool(plan.get("silent_watch"))
    cfg["setter_id"] = child.pk
    cfg["consent_at"] = _iso(now)
    tok = secrets.token_urlsafe(32)
    cfg["token_hash"] = _hash(tok)
    _save_cfg(elder, cfg)
    d = dict(r.data)
    d["used_at"] = _iso(now)
    r.data = d
    r.save(update_fields=["data", "updated_at"])
    if plan.get("carecall"):
        _accept_carecall(child, elder)
    n = name_for(child, elder)
    _push(child, "elder_setup_done",
          "%s-এর ফোন সেটআপ হয়ে গেছে ✓" % n, "%s's phone is set up ✓" % n,
          "উনি নিজে হ্যাঁ বলেছেন। সহজ হোম, কেয়ার কল আর নীরব পাহারা চালু।",
          "They said yes themselves. Easy home, Care Call and Silent Watch are on.",
          data={"route": "family", "elder_id": str(elder.pk)})
    return {"token": tok, "config": public_cfg(elder), "plan": plan,
            "child_name": name_for(elder, child)}, None


def _accept_carecall(setter, receiver):
    """The elder's one spoken Yes also accepts Care Calls from this child."""
    try:
        from .models import CareCallLink
        from . import carecall as CC
        link = CC.link_of(setter, receiver)
        if link is None:
            qs, qe = CC._default_quiet(receiver)
            CareCallLink.objects.create(setter=setter, receiver=receiver, status="pending",
                                        quiet_start=qs, quiet_end=qe)
        CC.decide(receiver, setter.pk, True)
    except Exception:  # noqa: BLE001 — Care Call can still be accepted later
        log.warning("fcelder: carecall link accept failed", exc_info=True)


# ------------------------------------------------------------ alerts
def _ask_elder(elder, kind):
    _push(elder, "silentwatch_ask", "আপনি ঠিক আছেন?", "Are you OK?",
          "‘আমি ভালো আছি’ চাপুন — আপনার পরিবার নিশ্চিন্ত হবে।",
          "Tap ‘I am OK’ so your family knows.",
          data={"route": "silentwatch", "kind": kind})


def _new_alert(elder, status, kind, due, silent_min=None, now=None):
    from .models import PaCollectionItem
    return PaCollectionItem.objects.create(user=elder, collection="sw_alert", data={
        "status": status, "kind": kind, "step": 0, "due": _iso(due),
        "opened_at": _iso(_now(now)), "notified": [], "silent_min": silent_min})


def on_carecall_missed(elder, now=None):
    """Care Call unanswered after its retries (server already knows): if this
    elder opted in, ask the elder first, the ladder starts after ASK_WAIT_MIN."""
    try:
        c = cfg_of(elder)
        if not c.get("enabled") or open_alert(elder) is not None:
            return None
        now = _now(now)
        r = _new_alert(elder, "asking", "carecall", now + timedelta(minutes=ASK_WAIT_MIN), now=now)
        _ask_elder(elder, "carecall")
        return r
    except Exception:  # noqa: BLE001 — never breaks the Care Call tick
        log.warning("fcelder: on_carecall_missed failed", exc_info=True)
        return None


def start_test(setter, elder, now=None):
    """Two-phone owner test: the setter asks the elder's phone now; the ladder
    runs exactly like a real one (labelled TEST in every message)."""
    c = cfg_of(elder)
    if not c or int(c.get("setter_id") or 0) != setter.pk:
        return None, "not_setter"
    if open_alert(elder) is not None:
        return None, "already_open"
    now = _now(now)
    r = _new_alert(elder, "asking", "test", now + timedelta(minutes=ASK_WAIT_MIN), now=now)
    _ask_elder(elder, "test")
    return r, None


def raise_alert(elder, kind="inactivity", silent_min=None, now=None):
    """The elder's PHONE: nobody answered "Are you OK?" — one event, the
    ladder starts at step 1 (setter) at once. Idempotent per open alert."""
    c = cfg_of(elder)
    if not c.get("enabled"):
        return None, "off"
    if kind not in KINDS:
        kind = "inactivity"
    try:
        silent_min = max(0, min(int(silent_min), 7 * 24 * 60)) if silent_min is not None else None
    except (TypeError, ValueError):
        silent_min = None
    now = _now(now)
    r = open_alert(elder)
    if r is None:
        r = _new_alert(elder, "open", kind, now, silent_min=silent_min, now=now)
    elif r.data.get("status") == "asking":
        d = dict(r.data)
        d["status"], d["due"] = "open", _iso(now)
        r.data = d
        r.save(update_fields=["data", "updated_at"])
    else:
        return r, None
    _advance(r, now)
    return r, None


def _texts(step, kind, elder_name, hours, setter_name):
    test_bn, test_en = ("(টেস্ট) ", "(TEST) ") if kind == "test" else ("", "")
    if kind == "carecall":
        why_bn = "কেয়ার কল বারবার ধরেননি, ‘আপনি ঠিক আছেন?’-এরও উত্তর দেননি।"
        why_en = "did not answer the Care Call or ‘Are you OK?’."
    elif kind == "test":
        why_bn, why_en = "এটা নীরব পাহারার টেস্ট।", "This is a Silent Watch test."
    else:
        why_bn = "অনেকক্ষণ ফোন ব্যবহার করেননি, ‘আপনি ঠিক আছেন?’-এরও উত্তর দেননি।"
        why_en = "has not used the phone for a long time and did not answer ‘Are you OK?’."
    if step == 1:
        return (test_bn + "%s-এর খোঁজ নিন" % elder_name, test_en + "Check on %s" % elder_name,
                "%s এখনই কল করুন।" % why_bn, "%s %s Call now." % (elder_name, why_en))
    if step == 2:
        return (test_bn + "%s-এর খোঁজ নিন — এখনো কেউ পৌঁছায়নি" % elder_name,
                test_en + "Check on %s — nobody has reached them yet" % elder_name,
                "%s কল করুন, বা ‘আমি দেখছি’ চাপুন।" % why_bn,
                "%s %s Call, or tap ‘I am checking’." % (elder_name, why_en))
    return (test_bn + "%s-এর পরিবার আপনাকে অনুরোধ করছে" % (setter_name or elder_name),
            test_en + "%s's family is asking you" % (setter_name or elder_name),
            "দয়া করে %s-এর খোঁজ নিন — উনি ফোন ধরছেন না।" % elder_name,
            "Please check on %s — they are not answering the phone." % elder_name)


def _notify(r, user_ids, step, now):
    elder = r.user
    c = cfg_of(elder)
    setter = _user(c.get("setter_id"))
    d = dict(r.data)
    told = list(d.get("notified") or [])
    for uid in user_ids:
        u = _user(uid)
        if u is None or u.pk == elder.pk:
            continue
        en = name_for(u, elder)
        sn = name_for(u, setter) if setter is not None else ""
        tbn, ten, bbn, ben = _texts(step, d.get("kind"), en, c.get("hours"), sn)
        _push(u, "silentwatch_alert", tbn, ten, bbn, ben,
              data={"route": "silentwatch_family", "elder_id": str(elder.pk),
                    "alert_id": str(r.pk), "step": str(step), "kind": d.get("kind") or ""})
        if u.pk not in told:
            told.append(u.pk)
    d["notified"] = told
    r.data = d


def _advance(r, now):
    """Move an OPEN alert one ladder step and set the next due time."""
    elder = r.user
    c = cfg_of(elder)
    d = dict(r.data)
    step = int(d.get("step") or 0) + 1
    if step == 1:
        _amber(elder, "carecall_missed" if d.get("kind") == "carecall" else "watch")
        targets = [c.get("setter_id")] if c.get("setter_id") else family_ids(elder)[:1]
    elif step == 2:
        targets = [i for i in family_ids(elder) if i not in (d.get("notified") or [])]
    else:
        nid = c.get("nearby_user_id")
        targets = [nid] if nid and nid not in (d.get("notified") or []) else []
    d["step"] = step
    d["due"] = _iso(now + timedelta(minutes=LADDER_MIN)) if step < 3 else None
    r.data = d
    _notify(r, targets, step, now)
    r.save(update_fields=["data", "updated_at"])


def tick(now=None):
    """Called every minute (from the Care Call tick). Idempotent."""
    from .models import PaCollectionItem
    now = _now(now)
    out = {"asked_to_open": 0, "advanced": 0}
    for r in PaCollectionItem.objects.filter(collection="sw_alert").order_by("id")[:2000]:
        d = r.data or {}
        if d.get("status") not in ("asking", "open"):
            continue
        due = _dt(d.get("due"))
        if due is None or due > now:
            continue
        try:
            if d.get("status") == "asking":
                d = dict(d)
                d["status"] = "open"
                r.data = d
                out["asked_to_open"] += 1
            _advance(r, now)
            out["advanced"] += 1
        except Exception:  # noqa: BLE001
            log.warning("fcelder: ladder step failed", exc_info=True)
    return out


def resolve(elder, by="elder", now=None):
    """"I am OK" (or the watch turned off): close the alert, clear amber, tell
    everyone already told."""
    now = _now(now)
    r = open_alert(elder)
    _clear_amber(elder)
    if r is None:
        return None
    d = dict(r.data)
    d.update({"status": "resolved", "resolved_by": by, "resolved_at": _iso(now), "due": None})
    r.data = d
    r.save(update_fields=["data", "updated_at"])
    if by == "elder":
        for uid in d.get("notified") or []:
            u = _user(uid)
            if u is None:
                continue
            n = name_for(u, elder)
            _push(u, "silentwatch_ok", "%s ভালো আছেন ✓" % n, "%s is OK ✓" % n,
                  "উনি নিজে ‘আমি ভালো আছি’ চেপেছেন।", "They tapped ‘I am OK’ themselves.",
                  data={"route": "family", "elder_id": str(elder.pk), "alert_id": str(r.pk)})
    return r


def ack(user, alert_id, now=None):
    """A family member: "I am checking" — stops the ladder (no more people
    woken), keeps amber until the elder is OK, tells the others who went."""
    from .models import PaCollectionItem
    r = PaCollectionItem.objects.filter(pk=alert_id, collection="sw_alert").first()
    if r is None or not is_family(r.user, user) and int(cfg_of(r.user).get("setter_id") or 0) != user.pk:
        return None, "not_found"
    d = dict(r.data or {})
    if d.get("status") not in ("asking", "open"):
        return r, None
    elder = r.user
    d["status"] = "checking"
    d["due"] = None
    d["checking_id"] = user.pk
    d["checking_name"] = name_for(elder, user)
    r.data = d
    r.save(update_fields=["data", "updated_at"])
    for uid in d.get("notified") or []:
        if uid == user.pk:
            continue
        u = _user(uid)
        if u is None:
            continue
        en, wn = name_for(u, elder), name_for(u, user)
        _push(u, "silentwatch_checking", "%s %s-এর খোঁজ নিচ্ছেন" % (wn, en),
              "%s is checking on %s" % (wn, en), "", "",
              data={"route": "family", "elder_id": str(elder.pk), "alert_id": str(r.pk)})
    return r, None


def status_for(viewer):
    """What the viewer needs: their own watch (as elder) and the elders they
    watch (open alerts first)."""
    from .models import PaCollectionItem
    mine = None
    if cfg_row(viewer) is not None:
        a = open_alert(viewer)
        mine = {"config": public_cfg(viewer), "alert": alert_dict(a, viewer) if a else None}
    watching = []
    elders = set(family_ids(viewer))
    rows = list(PaCollectionItem.objects.filter(collection="sw_cfg", user_id__in=list(elders))
                .select_related("user")[:200])
    rows += list(PaCollectionItem.objects.filter(collection="sw_cfg", data__setter_id=viewer.pk)
                 .exclude(user_id__in=list(elders)).select_related("user")[:50])
    for r in rows:
        d = r.data or {}
        if not d.get("enabled") or r.user_id == viewer.pk:
            continue
        a = PaCollectionItem.objects.filter(user=r.user, collection="sw_alert").order_by("-id").first()
        watching.append({"elder_id": r.user_id, "elder_name": name_for(viewer, r.user),
                         "i_set_it_up": int(d.get("setter_id") or 0) == viewer.pk,
                         "hours": d.get("hours"), "consent_at": d.get("consent_at"),
                         "alert": alert_dict(a, viewer) if a is not None else None})
    watching.sort(key=lambda w: (0 if (w["alert"] or {}).get("status") in ("open", "asking", "checking") else 1,
                                 w["elder_name"].lower()))
    return {"mine": mine, "watching": watching, "family": family_people(viewer)}
