"""
Missing person alert ("নিখোঁজ সতর্কতা", owner 2 Nov) — the service. Behind
the flag `missing_alert` (OFF). Views: core/missing_views.py. Pure rules:
core/logic/missing_rules.py. Owner Admin: web/owner/views_missing.py.

WHO MAY POST (gates, all server-side):
  * a FAMILY member: the missing person is the poster's accepted, unblocked
    close-family My Circle peer (both edges accepted), or a family entry the
    poster keeps in Family (FamilyMember);
  * ADULT (18+): a police GD number + thana + GD date (format check only — we
    never claim we verified it with the police; every viewer sees that line);
  * CHILD (<18): only a VERIFIED parent/guardian — guardian_check(), which
    asks core/guardianship.verified_parent (the ONE rule shared with child
    emergency audio): the child's own account and the poster agree
    parent/child in My Circle (both edges), or a second close-family adult
    of the poster co-signs in the app, or the family adds a GD number.

WHO GETS THE PUSH (honest — there is no background location):
  * users who OPTED IN to "nearby safety alerts" (NearbyAlertPref) whose
    coarse home area (district, or a point rounded to ~1 km) or whose
    "where I am" point sent while the app was OPEN in the last 12 h falls
    inside the alert's radius (+ district fuzz);
  * the poster's other close-family My Circle peers + every other guardian
    of a missing CHILD from any feature (guardianship.alert_audience — e.g.
    the other parent who set up the child's watch), while still an accepted
    Circle peer of the child;
  * the missing person themself (if an Assisto user): "your family posted…
    tap I am safe" — adult autonomy.
  One push per alert per user (MissingRecipient unique), at most 3 nearby
  pushes per user per 24 h, at most 500 pushes per alert (nearest first);
  the rest see it only in the app list.

ENDINGS: found / closed by the family / "I am safe" (adult) / expired after 7
days / removed by the admin -> the PHOTO FILE IS DELETED at once (signed
links 404 from then on), and the same recipients get one "ended" push with
no photo and no name.
"""
import base64
import binascii
import io
import logging
import secrets
import threading
from datetime import timedelta

from django.conf import settings
from django.core.files.base import ContentFile
from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from .logic import missing_rules as MR

log = logging.getLogger(__name__)

FLAG = "missing_alert"
CLOSE_FAMILY = {"father", "mother", "child", "parent", "husband", "wife", "spouse",
                "brother", "sister", "sibling"}
PARENT_EDGES = {"father", "mother", "parent"}
GUARDIAN_COSIGN_EDGES = {"husband", "wife", "spouse", "father", "mother", "parent",
                         "brother", "sister", "sibling"}
CHILD_MEMBER_RELATIONS = {"child", "son", "daughter", "sontan", "chele", "meye",
                          "সন্তান", "ছেলে", "মেয়ে"}


def flag_on(user):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(FLAG, user))
    except Exception:
        return False


def now():
    return timezone.now()


def log_event(kind, alert=None, actor=None, **meta):
    try:
        from .models import MissingEvent
        MissingEvent.objects.create(alert=alert, actor=actor, kind=kind[:24],
                                    meta={k: v for k, v in meta.items() if v is not None})
    except Exception as e:
        log.warning("missing: event log failed %s", type(e).__name__)


# ------------------------------------------------------------- family links
def edge(owner, peer):
    """owner's accepted, unblocked My Circle edge to peer (or None)."""
    from .models import CircleMember
    if owner is None or peer is None:
        return None
    return (CircleMember.objects
            .filter(user=owner, peer_user=peer, state="accepted", blocked=False)
            .first())


def family_pair(poster, other):
    """(poster->other edge, other->poster edge) when BOTH are accepted
    close-family edges; else None."""
    a, b = edge(poster, other), edge(other, poster)
    if a and b and a.relation in CLOSE_FAMILY and b.relation in CLOSE_FAMILY:
        return a, b
    return None


def family_users(poster):
    """The poster's close-family peers with an account (mutual edges)."""
    from .models import CircleMember
    out = []
    for m in (CircleMember.objects.filter(user=poster, state="accepted", blocked=False,
                                          relation__in=CLOSE_FAMILY)
              .select_related("peer_user")):
        u = m.peer_user
        if u is not None and u.id != poster.id and family_pair(poster, u):
            out.append((u, m.relation))
    return out


def family_audience(alert):
    """Who is pushed as FAMILY: the poster's close-family peers, then (for a
    missing child with an account) every other guardian of that child from
    core.guardianship (alert_audience: still-valid Circle peers only).
    Deduplicated, never the poster, never the missing person."""
    out, seen = [], {alert.poster_id, alert.subject_user_id}
    for u, _rel in family_users(alert.poster):
        if u.id not in seen:
            seen.add(u.id)
            out.append(u)
    if alert.is_child and alert.subject_user_id:
        from . import guardianship
        try:
            extra = guardianship.alert_audience(None, [], alert.subject_user)
        except Exception:  # noqa: BLE001 — never block the family push
            log.exception("missing family_audience guardians failed")
            extra = []
        for u in extra:
            if u.id not in seen:
                seen.add(u.id)
                out.append(u)
    return out


def guardian_check(poster, subject_user=None, family_member=None, cosigner=None):
    """THE guardian rule for a missing CHILD (finish1: the parent/child test
    is core.guardianship.verified_parent — one rule for every feature).

    -> {"ok": bool, "basis": "circle_mutual"|"cosigned"|"", "needs": "cosign"|None}
      * circle_mutual — the child's own account and the poster agree
        parent/child in My Circle (poster->child = "child", child->poster in
        father/mother/parent);
      * cosigned — a second close-family adult of the poster (spouse /
        parent / sibling, mutual edges) confirmed in the app;
      * otherwise the alert waits for a co-signer (or a GD number, checked
        by the caller)."""
    from . import guardianship
    if subject_user is not None and guardianship.verified_parent(poster, subject_user):
        return {"ok": True, "basis": "circle_mutual", "needs": None}
    if cosigner is not None and cosigner.id != poster.id:
        pair = family_pair(poster, cosigner)
        if pair and pair[0].relation in GUARDIAN_COSIGN_EDGES:
            return {"ok": True, "basis": "cosigned", "needs": None}
    return {"ok": False, "basis": "", "needs": "cosign"}


def cosigner_choices(poster):
    return [(u, rel) for u, rel in family_users(poster) if rel in GUARDIAN_COSIGN_EDGES]


# ------------------------------------------------------------- photo
def save_photo(alert, raw_b64):
    """Decode, re-encode as JPEG (drops EXIF incl. any GPS), max 1024 px.
    -> True / False (bad image)."""
    try:
        data = base64.b64decode(str(raw_b64 or ""), validate=True)
    except (binascii.Error, ValueError):
        return False
    if not data or len(data) > MR.PHOTO_MAX_BYTES:
        return False
    try:
        from PIL import Image, ImageOps
        im = Image.open(io.BytesIO(data))
        im = ImageOps.exif_transpose(im)
        im = im.convert("RGB")
        im.thumbnail((MR.PHOTO_MAX_SIDE, MR.PHOTO_MAX_SIDE))
        out = io.BytesIO()
        im.save(out, "JPEG", quality=82)   # no exif= -> no metadata written
    except Exception:
        return False
    name = "%s.jpg" % secrets.token_hex(16)
    alert.photo.save(name, ContentFile(out.getvalue()), save=False)
    return True


def delete_photo(alert, why=""):
    """Remove the photo FILE (signed links 404 from now on). Idempotent."""
    if not alert.photo:
        return False
    try:
        alert.photo.delete(save=False)
    except Exception as e:
        log.warning("missing: photo delete failed %s", type(e).__name__)
    alert.photo = ""
    log_event("photo_deleted", alert, why=why)
    return True


# ------------------------------------------------------------- push
def _send_push(user, title_bn, title_en, body_bn, body_en, data, high=False):
    """One visible push (family_alert channel). Patched in tests."""
    from . import push
    return push.push_to_user(user, "family_alert", title_bn, title_en, body_bn, body_en,
                             data=data, high_priority=high)


def _inapp(user, title_bn, title_en, body_bn, body_en, meta):
    try:
        from .models import NotifEvent
        NotifEvent.objects.create(user=user, type="family_alert", title_bn=title_bn[:200],
                                  title_en=title_en[:200], body_bn=body_bn, body_en=body_en,
                                  route="missing_alert", meta=dict(meta))
    except Exception as e:
        log.warning("missing: in-app row failed %s", type(e).__name__)


def notify(user, event, alert, tbn, ten, bbn, ben, push_it=True, high=False):
    data = {"route": "missing_alert", "event": event, "alert_id": alert.id}
    _inapp(user, tbn, ten, bbn, ben, data)
    if push_it:
        try:
            return _send_push(user, tbn, ten, bbn, ben, data, high=high) > 0
        except Exception:
            return False
    return False


def _run_bg(fn, *args):
    """Fan-outs run in ONE background thread that sends sequentially, so a
    big alert never floods the shared push queue in front of SOS / calls.
    Inline under PUSH_SYNC (tests)."""
    if getattr(settings, "PUSH_SYNC", False):
        fn(*args)
        return

    def run():
        from django.db import close_old_connections, connection
        try:
            close_old_connections()
            fn(*args)
        except Exception as e:
            log.warning("missing: fan-out failed %s", type(e).__name__)
        finally:
            try:
                connection.close()
            except Exception:
                pass
    def start():
        threading.Thread(target=run, daemon=True, name="missing-fanout").start()
    # after the commit, so the thread sees the active alert
    transaction.on_commit(start)


# ------------------------------------------------------------- targeting
def user_area(pref, at):
    """The opted-in user's coarse areas: [(lat, lng, fuzz, source)]."""
    out = []
    home = MR.area_of(pref.home_lat, pref.home_lng, pref.district)
    if home:
        out.append(home + ("home_area",))
    if (pref.use_open_location and pref.open_at and pref.open_lat is not None
            and at - pref.open_at <= timedelta(hours=MR.OPEN_LOCATION_TTL_H)):
        out.append((pref.open_lat, pref.open_lng, 0, "recent"))
    return out


def nearby_candidates(alert, at):
    """[(distance_km, user, source)] nearest first — opted-in users only."""
    from .models import NearbyAlertPref
    a_area = MR.area_of(alert.lat, alert.lng, alert.district)
    if not a_area:
        return []
    excluded = {alert.poster_id}
    if alert.subject_user_id:
        excluded.add(alert.subject_user_id)
    out = []
    for pref in (NearbyAlertPref.objects.filter(enabled=True, user__is_active=True)
                 .exclude(user_id__in=excluded).select_related("user")):
        best = None
        for la, ln, fz, src in user_area(pref, at):
            u_area = (la, ln, fz)
            same = (src == "home_area" and fz and alert.district
                    and pref.district == alert.district)
            if MR.is_nearby(a_area, alert.radius_km, u_area, same_district=bool(same)):
                d = MR.distance_km(a_area, u_area) or 0.0
                if best is None or d < best[0]:
                    best = (d, pref.user, src)
        if best:
            out.append(best)
    out.sort(key=lambda r: r[0])
    return out


def _pushes_today(user, at):
    from .models import MissingRecipient
    return (MissingRecipient.objects
            .filter(user=user, pushed_at__gte=at - timedelta(hours=24))
            .exclude(source="family").count())


def _texts_new(alert):
    who_bn = "একটি শিশু" if alert.is_child else "একজন মানুষ"
    who_en = "A child" if alert.is_child else "A person"
    return ("নিখোঁজ সতর্কতা: আপনার এলাকার কাছে",
            "Missing person alert near you",
            "%s নিখোঁজ — শেষ দেখা গেছে %s এলাকায়। খুলে ছবি দেখুন; কিছু জানলে গোপনে পরিবারকে জানান।"
            % (who_bn, alert.area_text),
            "%s is missing — last seen around %s. Open to see the photo; tell the family privately if you know anything."
            % (who_en, alert.area_text))


def fan_out(alert_id):
    """Create recipient rows + push. Idempotent (unique rows)."""
    from .models import MissingAlert, MissingRecipient
    alert = MissingAlert.objects.filter(pk=alert_id, state="active").first()
    if alert is None:
        return {"pushed": 0, "listed": 0}
    at = now()
    pushed = listed = 0
    tbn, ten, bbn, ben = _texts_new(alert)
    # 1. family (close-family peers of the poster + a child's other guardians;
    #    always pushed)
    for u in family_audience(alert):
        if u.id == alert.subject_user_id:
            continue
        row, made = MissingRecipient.objects.get_or_create(alert=alert, user=u,
                                                           defaults={"source": "family"})
        if made:
            if notify(u, "new_family", alert,
                      "নিখোঁজ সতর্কতা: পরিবারের একজন",
                      "Missing alert in your family",
                      "%s %s-এর জন্য নিখোঁজ সতর্কতা দিয়েছেন।" % (alert.poster.name or "", alert.name),
                      "%s posted a missing alert for %s." % (alert.poster.name or "", alert.name),
                      high=True):
                row.pushed_at = at
                row.save(update_fields=["pushed_at"])
                pushed += 1
    # 2. nearby opted-in users, nearest first
    for _d, u, src in nearby_candidates(alert, at):
        row, made = MissingRecipient.objects.get_or_create(alert=alert, user=u,
                                                           defaults={"source": src})
        if not made:
            continue
        listed += 1
        if pushed >= MR.MAX_PUSH_PER_ALERT or _pushes_today(u, at) >= MR.MAX_PUSH_PER_USER_DAY:
            _inapp(u, tbn, ten, bbn, ben, {"route": "missing_alert", "event": "new",
                                          "alert_id": alert.id})
            continue
        if notify(u, "new", alert, tbn, ten, bbn, ben, high=True):
            row.pushed_at = at
            row.save(update_fields=["pushed_at"])
            pushed += 1
    MissingAlert.objects.filter(pk=alert.id).update(pushed=alert.pushed + pushed,
                                                     listed=alert.listed + listed)
    log_event("fan_out", alert, pushed=pushed, listed=listed)
    return {"pushed": pushed, "listed": listed}


def tell_subject(alert):
    """The missing person (an Assisto user) hears about the alert at once."""
    u = alert.subject_user
    if u is None:
        return
    if alert.is_child:
        notify(u, "about_you", alert, "তোমার পরিবার তোমাকে খুঁজছে",
               "Your family is looking for you",
               "নিরাপদে থাকলে অ্যাপে 'আমি নিরাপদ' চাপো, অথবা বাড়িতে ফোন করো।",
               "If you are safe, tap 'I am safe' in the app, or call home.", high=True)
    else:
        notify(u, "about_you", alert, "আপনার পরিবার আপনার জন্য নিখোঁজ সতর্কতা দিয়েছে",
               "Your family posted a missing alert about you",
               "আপনি নিরাপদ থাকলে 'আমি নিরাপদ' চাপুন — সতর্কতা বন্ধ হবে, আপনার অবস্থান কাউকে জানানো হবে না।",
               "If you are safe, tap 'I am safe' — the alert closes and your location is never shared.",
               high=True)


# ------------------------------------------------------------- lifecycle
def activate(alert, at=None):
    at = at or now()
    alert.state = "active"
    alert.activated_at = at
    alert.expires_at = at + timedelta(days=MR.EXPIRY_DAYS)
    alert.save(update_fields=["state", "activated_at", "expires_at", "basis", "cosigner",
                              "gd_number", "gd_thana", "gd_date"])
    log_event("activated", alert, basis=alert.basis)
    tell_subject(alert)
    _run_bg(fan_out, alert.id)


_END_TEXTS = {
    "found": ("নিখোঁজ সতর্কতা: পাওয়া গেছে", "Missing alert: found",
              "যাঁকে খোঁজা হচ্ছিল, তাঁকে পাওয়া গেছে। সাহায্যের জন্য ধন্যবাদ।",
              "The person who was missing has been found. Thank you for helping."),
    "safe": ("নিখোঁজ সতর্কতা বন্ধ", "Missing alert closed",
             "মানুষটি নিজে জানিয়েছেন তিনি নিরাপদ। আর খোঁজার দরকার নেই।",
             "The person said they are safe. No need to keep looking."),
    "closed": ("নিখোঁজ সতর্কতা বন্ধ", "Missing alert closed",
               "পরিবার সতর্কতাটি বন্ধ করেছে। আর খোঁজার দরকার নেই।",
               "The family closed the alert. No need to keep looking."),
    "removed": ("নিখোঁজ সতর্কতা সরানো হয়েছে", "Missing alert removed",
                "এই সতর্কতাটি পর্যালোচনার পর সরানো হয়েছে।",
                "This alert was removed after a review."),
}


def end_push(alert_id, state):
    """One 'ended' push to the SAME recipients that got the first one (no
    photo, no name)."""
    from .models import MissingAlert, MissingRecipient
    alert = MissingAlert.objects.filter(pk=alert_id).first()
    if alert is None or state not in _END_TEXTS:
        return 0
    tbn, ten, bbn, ben = _END_TEXTS[state]
    at = now()
    n = 0
    for row in (MissingRecipient.objects.filter(alert=alert, pushed_at__isnull=False,
                                                end_pushed_at__isnull=True)
                .select_related("user")):
        if notify(row.user, "ended", alert, tbn, ten, bbn, ben):
            n += 1
        row.end_pushed_at = at
        row.save(update_fields=["end_pushed_at"])
    return n


def end(alert, state, by, at=None, actor=None):
    """found / safe / closed / expired / removed. Photo deleted at once."""
    at = at or now()
    was_active = alert.state == "active"
    alert.state = state
    alert.closed_at = at
    alert.closed_by = by[:12]
    if state == "safe":
        alert.safe_said_at = at
    delete_photo(alert, why=state)
    alert.save()
    log_event("end_" + state, alert, actor=actor, by=by)
    if was_active and state in _END_TEXTS:
        _run_bg(end_push, alert.id, state)
    return alert


def sweep(at=None, limit=200):
    """Expire alerts past expires_at and delete their photos. Also deletes any
    photo still attached to an ended alert (belt and braces). Never raises."""
    from .models import MissingAlert
    at = at or now()
    n = 0
    try:
        for a in MissingAlert.objects.filter(state__in=("active", "pending", "hidden"),
                                             expires_at__lte=at)[:limit]:
            end(a, "expired", "system", at)
            n += 1
        # a pending alert nobody co-signed in 7 days expires too
        for a in MissingAlert.objects.filter(state="pending", expires_at__isnull=True,
                                             created_at__lte=at - timedelta(days=MR.EXPIRY_DAYS))[:limit]:
            end(a, "expired", "system", at)
            n += 1
        for a in (MissingAlert.objects.exclude(state__in=MissingAlert.LIVE)
                  .exclude(photo="")[:limit]):
            delete_photo(a, why="sweep")
            a.save(update_fields=["photo"])
    except Exception as e:
        log.warning("missing: sweep failed %s", type(e).__name__)
    return n


# ------------------------------------------------------------- roles
def role(user, alert):
    """family | cosigner | subject | recipient | None (cannot see it)."""
    if user is None or not user.is_authenticated:
        return None
    if alert.poster_id == user.id:
        return "family"
    if alert.cosigner_id == user.id or alert.cosign_asked_id == user.id:
        return "cosigner"
    if alert.subject_user_id == user.id:
        return "subject"
    from .models import MissingRecipient
    if MissingRecipient.objects.filter(alert=alert, user=user).exists():
        return "recipient"
    return None


def is_tip_family(user, alert):
    return user is not None and (alert.poster_id == user.id or
                                 (alert.cosigner_id and alert.cosigner_id == user.id))


# ------------------------------------------------------------- posting limits
def posting_ban_until(user, at):
    from .models import MissingEvent
    ev = (MissingEvent.objects.filter(actor=user, kind="poster_banned",
                                      at__gte=at - timedelta(days=MR.POSTING_BAN_DAYS))
          .order_by("-at").first())
    return (ev.at + timedelta(days=MR.POSTING_BAN_DAYS)) if ev else None


def limit_problem(poster, at):
    from .models import MissingAlert
    if posting_ban_until(poster, at):
        return "banned"
    if MissingAlert.objects.filter(poster=poster, state__in=MissingAlert.LIVE).count() >= MR.MAX_ACTIVE_PER_POSTER:
        return "too_many_active"
    if MissingAlert.objects.filter(poster=poster,
                                   created_at__gte=at - timedelta(days=30)).count() >= MR.MAX_POSTS_30D:
        return "too_many_posts"
    return None


def cooling_problem(subject_user, gd_number, at):
    """After the person said 'I am safe': no new alert for them for 7 days
    unless a NEW GD number (one not used before for them)."""
    from .models import MissingAlert
    if subject_user is None:
        return None
    recent = (MissingAlert.objects.filter(subject_user=subject_user, state="safe",
                                          safe_said_at__gte=at - timedelta(days=MR.COOLING_DAYS))
              .order_by("-safe_said_at").first())
    if recent is None:
        return None
    used = set(MissingAlert.objects.filter(subject_user=subject_user)
               .exclude(gd_number="").values_list("gd_number", flat=True))
    if gd_number and gd_number not in used:
        return None
    return "cooling"


def duplicate_problem(poster, subject_user, family_member, name):
    from .models import MissingAlert
    qs = MissingAlert.objects.filter(state__in=MissingAlert.LIVE)
    if subject_user is not None and qs.filter(subject_user=subject_user).exists():
        return "already_active"
    if family_member is not None and qs.filter(family_member=family_member).exists():
        return "already_active"
    if qs.filter(poster=poster, name__iexact=name).exists():
        return "already_active"
    return None


# ------------------------------------------------------------- create
@transaction.atomic
def create(poster, body, at=None):
    """-> (alert, None) or (None, {"reason": code, ...})."""
    from .models import FamilyMember, MissingAlert, User
    at = at or now()
    p = limit_problem(poster, at)
    if p:
        log_event("refused", None, poster, reason=p)
        return None, {"reason": p}
    name = MR.clean_text(body.get("name"), 80)
    age = MR.clean_age(body.get("age"))
    area = MR.clean_text(body.get("area_text"), 120)
    desc = MR.clean_text(body.get("description"), 500)
    bad = []
    if len(name) < 2:
        bad.append("name")
    if age is None:
        bad.append("age")
    if len(area) < 3:
        bad.append("area_text")
    if MR.looks_like_address(area) or MR.looks_like_address(desc):
        bad.append("address")
    if MR.has_phone(area) or MR.has_phone(desc) or MR.has_phone(name):
        bad.append("phone")
    district = (body.get("district") or "").strip().lower()
    lat, lng = MR.coarse(body.get("lat")), MR.coarse(body.get("lng"))
    if lat is not None and not MR.in_bangladesh(lat, lng):
        lat = lng = None
    if not MR.district(district):
        district = MR.nearest_district(lat, lng) if lat is not None else ""
    if not district:
        bad.append("district")
    try:
        from django.utils.dateparse import parse_datetime
        seen = parse_datetime(str(body.get("last_seen_at") or ""))
        if seen is not None and timezone.is_naive(seen):
            seen = timezone.make_aware(seen)
    except (TypeError, ValueError):
        seen = None
    if seen is None or seen > at + timedelta(minutes=5) or seen < at - timedelta(days=30):
        bad.append("last_seen_at")
    for need in ("is_family", "no_address", "false_post"):
        if body.get("confirm_" + need) is not True:
            bad.append("confirm_" + need)
    if bad:
        return None, {"reason": "invalid", "fields": bad}

    # who is missing
    subject_user = fm = None
    relation = ""
    if body.get("subject_user_id"):
        try:
            subject_user = User.objects.filter(pk=int(body["subject_user_id"])).first()
        except (TypeError, ValueError):
            subject_user = None
        pair = family_pair(poster, subject_user) if subject_user else None
        if not pair:
            log_event("refused", None, poster, reason="not_family")
            return None, {"reason": "not_family"}
        relation = pair[0].relation
    elif body.get("family_member_id"):
        try:
            fm = FamilyMember.objects.filter(pk=int(body["family_member_id"]), user=poster).first()
        except (TypeError, ValueError):
            fm = None
        if fm is None:
            return None, {"reason": "not_family"}
        relation = (fm.relation or "")[:20]
    else:
        rel = MR.clean_text(body.get("relation"), 20).lower()
        if not rel:
            return None, {"reason": "invalid", "fields": ["relation"]}
        relation = rel   # a new Family entry is created only once every check passed
    child = MR.is_child(age)
    gd = {}
    if body.get("gd_number") or not child:
        gd, gd_bad = MR.gd_problems(body.get("gd_number"), body.get("gd_thana"),
                                    body.get("gd_date"), timezone.localdate(at))
        if gd_bad and not child:
            log_event("refused", None, poster, reason="gd_required", fields=gd_bad)
            return None, {"reason": "gd_required", "fields": gd_bad}
        if gd_bad:
            return None, {"reason": "invalid", "fields": gd_bad}
    p = cooling_problem(subject_user, gd.get("gd_number"), at)
    if p:
        log_event("refused", None, poster, reason=p, subject=subject_user.id)
        return None, {"reason": p, "days": MR.COOLING_DAYS}
    p = duplicate_problem(poster, subject_user, fm, name)
    if p:
        return None, {"reason": p}

    if subject_user is None and fm is None:
        fm = FamilyMember.objects.create(user=poster, name=name, relation=relation)
    a = MissingAlert(poster=poster, subject_user=subject_user, family_member=fm,
                     relation=relation, name=name, age=age, is_child=child,
                     description=desc, last_seen_at=seen, area_text=area,
                     district=district, lat=lat, lng=lng,
                     radius_km=MR.clean_radius(body.get("radius_km")), **gd)
    if body.get("photo_b64") and not save_photo(a, body.get("photo_b64")):
        return None, {"reason": "invalid", "fields": ["photo"]}
    # gates
    if not child:
        a.basis = "gd"
    else:
        g = guardian_check(poster, subject_user, fm)
        if g["ok"]:
            a.basis = g["basis"]
        elif gd:
            a.basis = "gd"
    a.save()
    log_event("created", a, poster, child=child, basis=a.basis or "pending")
    if a.basis:
        activate(a, at)
        return a, None
    # child without a verified guardian link: ask a co-signer
    cos = None
    try:
        cid = int(body.get("cosigner_id") or 0)
    except (TypeError, ValueError):
        cid = 0
    for u, _rel in cosigner_choices(poster):
        if u.id == cid:
            cos = u
    if cos is not None:
        a.cosign_asked = cos
        a.save(update_fields=["cosign_asked"])
        notify(cos, "cosign", a, "নিখোঁজ সতর্কতা: আপনার নিশ্চিত করা দরকার",
               "Missing alert: please confirm",
               "%s বলছেন %s নিখোঁজ। সত্যি হলে অ্যাপে নিশ্চিত করুন।" % (poster.name or "", a.name),
               "%s says %s is missing. If it is true, confirm in the app." % (poster.name or "", a.name),
               high=True)
    return a, None


def cosign(alert, user, yes, at=None):
    at = at or now()
    if alert.state != "pending" or alert.cosign_asked_id != user.id:
        return "not_allowed"
    if not yes:
        alert.cosign_asked = None
        alert.save(update_fields=["cosign_asked"])
        log_event("cosign_declined", alert, user)
        notify(alert.poster, "cosign_declined", alert, "নিশ্চিত করা হয়নি", "Not confirmed",
               "আপনার পরিবারের সদস্য সতর্কতাটি নিশ্চিত করেননি। GD নম্বর দিলে সতর্কতা চালু হবে।",
               "Your family member did not confirm. Add a GD number to start the alert.")
        return None
    g = guardian_check(alert.poster, alert.subject_user, alert.family_member, cosigner=user)
    if not g["ok"]:
        return "not_allowed"
    alert.basis, alert.cosigner = g["basis"], user
    activate(alert, at)
    log_event("cosigned", alert, user)
    return None


def add_gd(alert, body, at=None):
    at = at or now()
    gd, bad = MR.gd_problems(body.get("gd_number"), body.get("gd_thana"),
                             body.get("gd_date"), timezone.localdate(at))
    if bad:
        return {"reason": "invalid", "fields": bad}
    for k, v in gd.items():
        setattr(alert, k, v)
    if alert.state == "pending":
        alert.basis = "gd"
        activate(alert, at)
    else:
        alert.save(update_fields=["gd_number", "gd_thana", "gd_date"])
    return None


def renew(alert, body, at=None):
    at = at or now()
    if alert.state != "active" or not alert.expires_at:
        return {"reason": "not_active"}
    if alert.expires_at - at > timedelta(hours=MR.RENEW_WINDOW_H):
        return {"reason": "too_early"}
    if alert.renewals >= MR.MAX_RENEWALS:
        return {"reason": "max_renewals"}
    if not alert.is_child:
        # adult: the family re-confirms the GD is still open (same number)
        n = MR.clean_gd_number(body.get("gd_number"))
        if body.get("gd_still_open") is not True or n is None or n != alert.gd_number:
            return {"reason": "gd_reconfirm"}
    alert.expires_at = alert.expires_at + timedelta(days=MR.RENEW_DAYS)
    alert.renewals += 1
    alert.save(update_fields=["expires_at", "renewals"])
    log_event("renewed", alert, alert.poster, n=alert.renewals)
    return None


def say_safe(alert, user, at=None):
    """The missing person: 'I am safe'. Adult -> closes, NO location, the
    family sees only 'said they are safe'. Child -> the family is told at
    once; the alert stays until the family closes it (child safety first)."""
    at = at or now()
    if alert.subject_user_id != user.id or alert.state not in ("active", "pending", "hidden"):
        return "not_allowed"
    if alert.is_child:
        alert.safe_said_at = at
        alert.save(update_fields=["safe_said_at"])
        log_event("child_said_safe", alert, user)
        for u in _family_side(alert):
            notify(u, "said_safe", alert, "%s বলেছে সে নিরাপদ" % alert.name,
                   "%s says they are safe" % alert.name,
                   "অ্যাপে 'আমি নিরাপদ' চাপা হয়েছে। ফোন করে নিশ্চিত হোন, তারপর সতর্কতা বন্ধ করুন।",
                   "They tapped 'I am safe'. Call to make sure, then close the alert.", high=True)
        return None
    end(alert, "safe", "subject", at, actor=user)
    for u in _family_side(alert):
        notify(u, "said_safe", alert, "নিরাপদ বলেছেন", "Said they are safe",
               "%s অ্যাপে জানিয়েছেন তিনি নিরাপদ। সতর্কতা বন্ধ হয়েছে।" % alert.name,
               "%s said in the app that they are safe. The alert is closed." % alert.name,
               high=True)
    return None


def _family_side(alert):
    out = [alert.poster]
    if alert.cosigner_id:
        out.append(alert.cosigner)
    return out


# ------------------------------------------------------------- reports
def report(alert, user, reason, note, at=None):
    """-> (status, hidden_now). One report per user per alert."""
    from .models import MissingReport
    at = at or now()
    if reason not in MR.REPORT_REASONS:
        reason = "other"
    if MissingReport.objects.filter(reporter=user, created_at__gte=at - timedelta(days=1)).count() >= MR.MAX_REPORTS_DAY:
        return "rate_limited", False
    if MissingReport.objects.filter(alert=alert, reporter=user).exists():
        return "already", False
    joined = getattr(user, "date_joined", None) or getattr(user, "created_at", None)
    young = bool(joined and at - joined < timedelta(days=MR.REPORTER_MIN_AGE_DAYS))
    fam = {u.id for u in family_audience(alert)}
    counted = not young and user.id not in fam and user.id != alert.poster_id
    MissingReport.objects.create(alert=alert, reporter=user, reason=reason,
                                 note=MR.clean_text(note, 300), counted=counted)
    log_event("reported", alert, user, reason=reason, counted=counted)
    n = MissingReport.objects.filter(alert=alert, counted=True, status="open").count()
    if alert.state == "active" and n >= MR.REPORT_HIDE_N:
        alert.hidden_from = alert.state
        alert.state = "hidden"
        alert.save(update_fields=["state", "hidden_from"])
        log_event("auto_hidden", alert, reports=n)
        notify(alert.poster, "hidden", alert, "সতর্কতা পর্যালোচনায়", "Alert under review",
               "কয়েকজন ব্যবহারকারী রিপোর্ট করায় সতর্কতাটি সাময়িকভাবে লুকানো — পর্যালোচনা চলছে।",
               "Several users reported it, so the alert is hidden while we review it.")
        return "ok", True
    return "ok", False


def admin_action(alert, action, owner, at=None):
    """Owner Admin: hide / restore / remove (fake: posting ban) / close."""
    at = at or now()
    from .models import MissingReport
    if action == "hide" and alert.state == "active":
        alert.hidden_from, alert.state = "active", "hidden"
        alert.save(update_fields=["state", "hidden_from"])
    elif action == "restore" and alert.state == "hidden":
        alert.state = "active"
        alert.save(update_fields=["state"])
        MissingReport.objects.filter(alert=alert, status="open").update(status="dismissed")
    elif action in ("remove", "remove_ban") and alert.state in _live():
        end(alert, "removed", "admin", at)
        MissingReport.objects.filter(alert=alert, status="open").update(status="upheld")
        if action == "remove_ban":
            log_event("poster_banned", alert, alert.poster, days=MR.POSTING_BAN_DAYS)
    elif action == "close" and alert.state in _live():
        end(alert, "closed", "admin", at)
    else:
        return "invalid"
    log_event("admin_" + action, alert, owner)
    return None


def _live():
    from .models import MissingAlert
    return MissingAlert.LIVE


# ------------------------------------------------------------- tips
def tip(alert, user, body, at=None):
    """-> (thread, error). Tipster -> family, private."""
    from .models import MissingTipMessage, MissingTipThread
    at = at or now()
    if alert.state != "active":
        return None, "not_active"
    if is_tip_family(user, alert):
        return None, "not_allowed"
    text = MR.clean_text(body.get("text"), 600)
    if len(text) < 2:
        return None, "invalid"
    th = MissingTipThread.objects.filter(alert=alert, tipster=user).first()
    if th is None:
        if MissingTipThread.objects.filter(tipster=user, created_at__gte=at - timedelta(days=1)).count() >= MR.MAX_TIP_THREADS_DAY:
            return None, "rate_limited"
        th = MissingTipThread.objects.create(alert=alert, tipster=user,
                                             share_identity=body.get("share_identity") is True)
    elif body.get("share_identity") is True and not th.share_identity:
        th.share_identity = True
    if th.messages.filter(by_family=False, at__gte=at - timedelta(days=1)).count() >= MR.MAX_TIP_MSGS_DAY:
        return None, "rate_limited"
    lat, lng = MR.coarse(body.get("lat")), MR.coarse(body.get("lng"))
    if lat is not None and not MR.in_bangladesh(lat, lng):
        lat = lng = None
    MissingTipMessage.objects.create(thread=th, by_family=False, text=text, lat=lat, lng=lng, at=at)
    th.last_at, th.family_unread = at, th.family_unread + 1
    th.save(update_fields=["last_at", "family_unread", "share_identity"])
    log_event("tip", alert, user, thread=th.id)
    for u in _family_side(alert):
        notify(u, "tip", alert, "নতুন তথ্য এসেছে", "New tip",
               "%s নিয়ে কেউ গোপনে তথ্য পাঠিয়েছেন। অ্যাপে দেখুন।" % alert.name,
               "Someone sent a private tip about %s. Open the app." % alert.name, high=True)
    return th, None


def family_reply(thread, user, text, at=None):
    from .models import MissingTipMessage
    at = at or now()
    alert = thread.alert
    if not is_tip_family(user, alert):
        return "not_allowed"
    text = MR.clean_text(text, 600)
    if len(text) < 1:
        return "invalid"
    if thread.messages.filter(by_family=True, at__gte=at - timedelta(days=1)).count() >= MR.MAX_TIP_MSGS_DAY:
        return "rate_limited"
    MissingTipMessage.objects.create(thread=thread, by_family=True, text=text, at=at)
    thread.last_at, thread.tipster_unread = at, thread.tipster_unread + 1
    thread.save(update_fields=["last_at", "tipster_unread"])
    notify(thread.tipster, "tip_reply", alert, "পরিবার উত্তর দিয়েছে", "The family replied",
           "নিখোঁজ সতর্কতায় আপনার তথ্যের উত্তর এসেছে।",
           "The family replied to your tip on a missing alert.")
    return None


def tipster_label(thread, lang="bn"):
    if thread.share_identity:
        u = thread.tipster
        return (u.name or "").strip() or ("Assisto ব্যবহারকারী" if lang == "bn" else "Assisto user")
    code = "%03d" % (thread.id % 1000)
    return ("অজ্ঞাত তথ্যদাতা #%s" % code) if lang == "bn" else ("Anonymous tipster #%s" % code)


# ------------------------------------------------------------- nearby pref
def get_pref(user):
    from .models import NearbyAlertPref
    p, _ = NearbyAlertPref.objects.get_or_create(user=user)
    return p


def pref_json(p, lang="bn"):
    d = MR.district(p.district)
    return {"enabled": p.enabled, "district": p.district,
            "district_name": (d[2] if lang == "bn" else d[1]) if d else "",
            "has_point": p.home_lat is not None,
            "use_open_location": p.use_open_location,
            "open_fresh": bool(p.open_at and now() - p.open_at <= timedelta(hours=MR.OPEN_LOCATION_TTL_H))}


def set_pref(user, body):
    p = get_pref(user)
    if "enabled" in body:
        p.enabled = body.get("enabled") is True
    if "district" in body:
        code = (body.get("district") or "").strip().lower()
        p.district = code if MR.district(code) else ""
    if body.get("clear_point") is True:
        p.home_lat = p.home_lng = None
    if body.get("lat") is not None:
        la, ln = MR.coarse(body.get("lat")), MR.coarse(body.get("lng"))
        if MR.in_bangladesh(la, ln):
            p.home_lat, p.home_lng = la, ln
            if not p.district:
                p.district = MR.nearest_district(la, ln)
    if "use_open_location" in body:
        p.use_open_location = body.get("use_open_location") is True
        if not p.use_open_location:
            p.open_lat = p.open_lng = p.open_at = None
    if not p.enabled:
        # off = nothing kept
        p.home_lat = p.home_lng = p.open_lat = p.open_lng = p.open_at = None
        p.use_open_location = False
    p.save()
    return p


def where_i_am(user, lat, lng, at=None):
    at = at or now()
    p = get_pref(user)
    if not (p.enabled and p.use_open_location):
        return "not_opted_in"
    la, ln = MR.coarse(lat), MR.coarse(lng)
    if not MR.in_bangladesh(la, ln):
        return "invalid"
    if p.open_at and at - p.open_at < timedelta(minutes=MR.OPEN_LOCATION_MIN_GAP_MIN):
        return None   # throttled, silently fine
    p.open_lat, p.open_lng, p.open_at = la, ln, at
    p.save(update_fields=["open_lat", "open_lng", "open_at", "updated_at"])
    return None


def visible_for(user):
    """Alerts a user may see: posted, co-sign asked, about me, recipient."""
    from .models import MissingAlert
    return (MissingAlert.objects
            .filter(Q(poster=user) | Q(cosigner=user) | Q(cosign_asked=user) |
                    Q(subject_user=user) | Q(recipients__user=user))
            .distinct())
