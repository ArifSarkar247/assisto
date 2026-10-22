"""Module 5 (P13+) endpoints: Health, Life, Launch-gaps, Connected Circle.

Each view threads req_lang so all user-facing copy follows the Accept-Language
header. Pure logic lives in core/logic/* and core/{analytics,reset,legal,photo,
unseen,nmcheck}.py — the views below are thin wiring + the enforcement the
reviewers flagged (CC validate_envelope / auto-block / can_see / single-use
invite; reset rate-limit + neutral response; photo honours declared kind).
"""
from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.mail import send_mail
from django.utils import timezone

from rest_framework import status
from rest_framework.decorators import api_view, permission_classes, throttle_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from .i18n import pick, req_lang
from .logic import (health_tips, medicine_db, birthdays as bdays,
                    meetings, dictionary, ramadan, exam, circle,
                    circle_messaging, circle_privacy)
from . import analytics, reset as reset_logic, legal, photo, unseen, nmcheck
from .models import (Birthday, Appointment, ExamWatcher, PasswordResetToken,
                     AnalyticsEvent, CircleMember, CircleMessage, CircleInvite,
                     CircleReport)
from .serializers import BirthdaySerializer, AppointmentSerializer

User = get_user_model()


# ===========================================================================
# Health: tips library + emergency check
# ===========================================================================

class HealthTipsView(APIView):
    def get(self, request):
        lang = req_lang(request)
        topic = request.query_params.get("topic") or None
        query = request.query_params.get("q") or None
        return Response(health_tips.library(lang, topic=topic, query=query))


class HealthEmergencyView(APIView):
    def post(self, request):
        lang = req_lang(request)
        text = str(request.data.get("text", ""))
        return Response(health_tips.emergency_check(text, lang))


# ===========================================================================
# Health: medicine DB (SAMPLE / DGDA switch) — no model, static seed
# ===========================================================================

class MedicineDbSearchView(APIView):
    def get(self, request):
        lang = req_lang(request)
        q = request.query_params.get("q", "")
        return Response({
            "results": medicine_db.search(q, lang=lang),
            "meta": medicine_db.meta(lang),
        })


class MedicineDbLookupView(APIView):
    def get(self, request):
        lang = req_lang(request)
        brand = request.query_params.get("brand", "")
        rec = medicine_db.lookup(brand, lang=lang)
        if rec is None:
            return Response({"available": False, **medicine_db.needs_data_state(lang),
                             "meta": medicine_db.meta(lang)})
        return Response({"available": True, "record": rec, "meta": medicine_db.meta(lang)})


# ===========================================================================
# Health: birthdays & memorable days
# ===========================================================================

class BirthdaysView(APIView):
    def get(self, request):
        lang = req_lang(request)
        rows = Birthday.objects.filter(user=request.user)
        occasions = [{"id": b.id, "name": b.name, "date": b.date.isoformat(),
                      "kind": b.kind, "lead_days": b.lead_days} for b in rows]
        return Response({
            "upcoming": bdays.upcoming(occasions),
            "all": occasions,
            "kinds": bdays.kinds(lang),
        })

    def post(self, request):
        data = request.data or {}
        d = bdays.parse_date(data.get("date"))
        if d is None:
            return Response({"error": "date_invalid"}, status=status.HTTP_400_BAD_REQUEST)
        b = Birthday.objects.create(
            user=request.user,
            name=str(data.get("name", "")).strip()[:120],
            date=d,
            kind=bdays._kind(data.get("kind", "birthday"))["id"],
            lead_days=bdays.clamp_lead_days(data.get("lead_days", bdays.LEAD_DAYS_DEFAULT)),
        )
        return Response(BirthdaySerializer(b).data, status=status.HTTP_201_CREATED)


class BirthdayDeleteView(APIView):
    def post(self, request, pk):
        Birthday.objects.filter(user=request.user, pk=pk).delete()
        return Response({"ok": True})


class BirthdayDraftsView(APIView):
    def post(self, request):
        lang = req_lang(request)
        data = request.data or {}
        name = str(data.get("name", "")).strip()
        kind = bdays._kind(data.get("kind", "birthday"))["id"]
        age = data.get("age")
        return Response({
            "drafts": bdays.wish_drafts(name, kind_id=kind, age=age, lang=lang),
            "card": bdays.greeting_card(name, kind_id=kind, age=age, lang=lang),
        })


# ===========================================================================
# Life: appointments (bulk list the user owns — matches the meetings screen)
# ===========================================================================

class AppointmentsView(APIView):
    """GET -> list of the user's appointments (DRF-list shape so listItems()
    maps cleanly). POST {items:[...]} -> replace the user's set (the screen
    saves its whole local list). Each item runs through
    meetings.normalise_appointment so title+start are validated and duration
    is clamped."""

    def get(self, request):
        rows = Appointment.objects.filter(user=request.user)
        return Response(AppointmentSerializer(rows, many=True).data)

    def post(self, request):
        items = request.data.get("items")
        if items is None:
            # Single-appointment create also supported.
            items = [request.data]
        kept = []
        for raw in items or []:
            ok, norm = meetings.normalise_appointment(raw)
            if ok:
                kept.append(norm)
        Appointment.objects.filter(user=request.user).delete()
        created = []
        for n in kept:
            created.append(Appointment.objects.create(
                user=request.user,
                title=n["title"][:160],
                start=n["start"],
                duration_min=n["duration_min"],
                place=(n.get("place") or "")[:200],
                place_lat=n.get("place_lat"),
                place_lng=n.get("place_lng"),
                note=n.get("note") or "",
            ))
        return Response(AppointmentSerializer(created, many=True).data,
                        status=status.HTTP_201_CREATED)


# ===========================================================================
# Life: dictionary (open-sample only; honest needs-data state)
# ===========================================================================

class DictionaryLookupView(APIView):
    def get(self, request):
        q = request.query_params.get("q", "")
        direction = request.query_params.get("direction", "auto")
        return Response(dictionary.lookup(q, direction=direction))


# ===========================================================================
# Life: ramadan times + eid drafts
# ===========================================================================

class RamadanTimesView(APIView):
    def get(self, request):
        try:
            lat = float(request.query_params.get("lat"))
            lon = float(request.query_params.get("lon"))
        except (TypeError, ValueError):
            return Response({"error": "lat_lon_required"},
                            status=status.HTTP_400_BAD_REQUEST)
        d = timezone.localdate()
        return Response(ramadan.prayer_times(d, lat, lon, tz_offset_hours=6.0))


class RamadanEidCardView(APIView):
    def post(self, request):
        lang = req_lang(request)
        data = request.data or {}
        kind = data.get("kind", "greeting")
        to = str(data.get("to", "")).strip()
        frm = str(data.get("from", "")).strip()
        if kind == "salami":
            d = ramadan.salami_card_draft(to_name=to, amount=data.get("amount"),
                                          from_name=frm, lang=lang)
        else:
            d = ramadan.eid_greeting_draft(to_name=to, from_name=frm, lang=lang)
        return Response({"text": d})


# ===========================================================================
# Life: exam watcher (public url only; never scrapes behind auth)
# ===========================================================================

class ExamWatcherView(APIView):
    def post(self, request):
        ok, data = exam.normalise_watcher(request.data or {})
        if not ok:
            return Response({"error": data}, status=status.HTTP_400_BAD_REQUEST)
        exp = None
        if data.get("expected_date"):
            exp = exam.parse_dt(data["expected_date"])
            exp = exp.date() if exp else None
        w = ExamWatcher.objects.create(
            user=request.user,
            label=data["label"][:120],
            url=data["url"],
            expected_date=exp,
            roll=data["roll"][:40],
            board=data["board"][:40],
            exam=data["exam"][:40],
            year=data["year"][:8],
        )
        return Response({"id": w.id, **data}, status=status.HTTP_201_CREATED)


# ===========================================================================
# Launch-gap A: password reset (rate-limited, neutral, no enumeration)
# ===========================================================================

class ResetRequestView(APIView):
    permission_classes = [AllowAny]
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "reset"

    def post(self, request):
        lang = req_lang(request)
        email = str(request.data.get("email", "")).strip().lower()
        neutral = Response({"message": reset_logic.neutral_response(lang, "email")})
        if not email:
            return neutral
        user = User.objects.filter(email=email).first()
        if user is not None:
            raw, token_hash = reset_logic.generate_token()
            PasswordResetToken.objects.create(
                user=user,
                token_hash=token_hash,
                channel="email",
                expires_at=reset_logic.expiry(timezone.now()),
            )
            link = reset_logic.reset_link(
                getattr(settings, "APP_DEEP_LINK_BASE", "assisto://reset/confirm"), raw)
            subject, body = reset_logic.build_email(lang, user.name or "", link)
            try:
                send_mail(subject, body, settings.DEFAULT_FROM_EMAIL, [email],
                          fail_silently=True)
            except Exception:
                pass
        return neutral


class ResetConfirmView(APIView):
    permission_classes = [AllowAny]
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "reset"

    def post(self, request):
        lang = req_lang(request)
        raw = str(request.data.get("token", ""))
        pw = str(request.data.get("password", ""))
        ok_pw, pw_msg = reset_logic.validate_password(pw, lang)
        if not ok_pw:
            return Response({"ok": False, "message": pw_msg},
                            status=status.HTTP_400_BAD_REQUEST)
        th = reset_logic.hash_token(raw)
        now = timezone.now()
        # Only consider matching, unused, unexpired tokens; collapse all other
        # failures into one neutral "invalid/expired" message.
        tok = PasswordResetToken.objects.filter(token_hash=th).order_by("-created_at").first()
        ok, reason = (False, "invalid")
        if tok is not None:
            ok, reason = reset_logic.check_token(tok.token_hash, raw,
                                                 tok.expires_at, now, tok.used)
        if not ok:
            return Response({"ok": False, "message": reset_logic.confirm_message(lang, reason)},
                            status=status.HTTP_400_BAD_REQUEST)
        tok.used = True
        tok.save(update_fields=["used"])
        tok.user.set_password(pw)
        tok.user.save(update_fields=["password"])
        return Response({"ok": True, "message": reset_logic.confirm_message(lang, "ok")})


# ===========================================================================
# Launch-gap: privacy-first analytics
# ===========================================================================

class AnalyticsIngestView(APIView):
    def post(self, request):
        data = request.data or {}
        events = data.get("events", data)
        consent = bool(data.get("consent", True)) if isinstance(data, dict) else True
        result = analytics.ingest(request.user.id, events, consent=consent)
        AnalyticsEvent.objects.bulk_create(
            [AnalyticsEvent(uid_hash=r["uid_hash"], name=r["name"],
                            day=r["day"], props=r["props"]) for r in result["rows"]])
        return Response({"accepted": result["accepted"]})


class AnalyticsDashboardView(APIView):
    def get(self, request):
        if not request.user.is_staff:
            return Response({"detail": "owner only"}, status=status.HTTP_403_FORBIDDEN)
        rows = list(AnalyticsEvent.objects.all())
        return Response(analytics.dashboard(rows))


# ===========================================================================
# Launch-gap C: legal viewer + about-the-name
# ===========================================================================

class LegalIndexView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        return Response({"pages": legal.index(req_lang(request))})


class LegalPageView(APIView):
    permission_classes = [AllowAny]

    def get(self, request, key):
        p = legal.page(key, req_lang(request))
        if p is None:
            return Response({"detail": "unknown page"}, status=status.HTTP_404_NOT_FOUND)
        return Response(p)


class NameAboutView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        return Response(nmcheck.about_the_name(req_lang(request)))


# ===========================================================================
# Launch-gap E: photo enhance (server re-enforces doc/own/faithful rules)
# ===========================================================================

class PhotoPlanView(APIView):
    def post(self, request):
        lang = req_lang(request)
        data = request.data or {}
        return Response(photo.plan(
            kind=data.get("kind", "personal"),
            ops=data.get("ops", []),
            own_photo=bool(data.get("own_photo", False)),
            lang=lang,
        ))


# ===========================================================================
# Launch-gap F: Unseen Bangladesh travel companion
# ===========================================================================

class UnseenView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        return Response(unseen.companion(req_lang(request)))


# ===========================================================================
# Connected Circle
# ===========================================================================

User = get_user_model()


def _resolve_peer(m):
    """Resolve the OTHER party's display name + photo for a circle edge.
    Prefers the linked peer_user account; falls back to the phone number; and
    finally to whatever name was captured on the row.  photo is "" today
    (the User model has no photo field yet — see MIGRATION NOTE in the report)."""
    name, photo = (m.name or "").strip(), ""
    peer = getattr(m, "peer_user", None)
    if peer is None and (m.phone or "").strip():
        from .phone import find_user as _find_by_phone
        peer = _find_by_phone(m.phone)
    if peer is not None:
        name = (getattr(peer, "name", "") or "").strip() or name or peer.username
        photo = getattr(peer, "photo_url", "") or ""
    return name, photo


def x2_photo_v(photo):
    """x2-ticks: a STABLE version tag for an avatar URL. The signed media
    link's ?e=&s= rotate every hour; the stored file name (a fresh name per
    upload) does not — so clients cache by this and refetch only when the
    contact really changed their photo."""
    if not photo:
        return ""
    import hashlib
    base = str(photo).split("?", 1)[0] if "/m/" in str(photo) else str(photo)
    return hashlib.sha1(base.encode()).hexdigest()[:12]


def _member_dict(m):
    name, photo = _resolve_peer(m)
    return {
        "id": m.id, "name": name, "display_name": name, "photo": photo,
        "photo_v": x2_photo_v(photo),   # x2-ticks
        "relation": m.relation,
        "relation_label": circle.relation_label(m.relation, "bn", m.custom_label),
        "custom_label": m.custom_label, "state": m.state,
        # mr1: message requests — direction + the pre-accept send budget
        "direction": getattr(m, "direction", "outgoing") or "outgoing",
        "request": _msgreq_info(m),
        # e2-keys: the peer's key is read LIVE from the per-user directory
        # (UserPublicKey) — never from the edge.
        **_live_key_fields(m),
        "sharing": m.sharing or {},
    }


def _msgreq_info(m):
    from . import msgreq
    try:
        return msgreq.info(m)
    except Exception:  # noqa: BLE001 — a payload never fails on this
        return None


def _live_key_fields(m):
    from . import e2_keys
    peer = e2_keys.edge_peer(m)
    row = e2_keys.key_row(peer)
    return {"public_key": row.public_key if row else "",
            "key_id": row.key_id if row else "",
            "scheme": row.scheme if row else "",
            "peer_user_id": peer.id if peer is not None else None,
            "key_changed_at": (row.changed_at.isoformat()
                               if row and row.changed_at else None)}


def _organise_map(user):
    """#87 — the viewer's per-chat organise state keyed by str(chat_id) for the
    'member' chat kind. Mute is reported HONESTLY via msg_organise.is_muted so a
    lapsed timed-mute never shows a stale badge."""
    from .models import ChatOrganiseState
    from .logic import msg_organise as MO
    out = {}
    for s in ChatOrganiseState.objects.filter(user=user, chat_kind="member"):
        muted = MO.is_muted({
            "mute_until": s.mute_until.isoformat() if s.mute_until else None,
            "duration": s.muted_duration,
            "muted_at": s.updated_at.isoformat(),
        }) if (s.mute_until or s.muted_duration) else False
        out[str(s.chat_id)] = {
            "favourite": False,
            "pinned": s.pinned,
            "pin_at": s.pin_at.isoformat() if s.pin_at else None,
            "archived": s.archived,
            "muted": muted,
        }
    return out


class CircleMembersView(APIView):
    def get(self, request):
        # BUG 3 FIX: a person is in "Your circle" ONLY once accepted. Pending
        # (incoming OR outgoing) must NOT appear here.
        rows = CircleMember.objects.filter(user=request.user, state="accepted")
        org = _organise_map(request.user)
        out = []
        from .models import MsgChatPref
        favs = set(MsgChatPref.objects.filter(
            user=request.user, chat_kind="member", favourite=True
        ).values_list("chat_id", flat=True))
        for m in rows:
            d = _member_dict(m)
            d.update(org.get(str(m.id), {
                "pinned": False, "pin_at": None, "archived": False, "muted": False}))
            d["favourite"] = str(m.id) in favs
            out.append(d)
        return Response({"results": out})


class _OrganiseBase(APIView):
    """#87 Chat organise — PER-USER pin/archive/mute/read. Enforcement runs
    SERVER-SIDE via core.logic.msg_organise; state persists in ChatOrganiseState
    so organise survives a reload / new device. Carries NO message content."""
    @staticmethod
    def _row(user, chat_id):
        from .models import ChatOrganiseState
        row, _ = ChatOrganiseState.objects.get_or_create(
            user=user, chat_kind="member", chat_id=str(chat_id))
        return row


class ChatPinView(_OrganiseBase):
    def post(self, request, pk):
        from .models import ChatOrganiseState
        from .logic import msg_organise as MO
        want = bool((request.data or {}).get("pinned", True))
        row = self._row(request.user, pk)
        pinned_count = ChatOrganiseState.objects.filter(
            user=request.user, chat_kind="member", pinned=True).count()
        ok, reason = MO.can_pin_chat(pinned_count, row.pinned)
        if want and not ok:
            return Response({"ok": False, "code": reason},
                            status=status.HTTP_400_BAD_REQUEST)
        row.pinned = want
        row.pin_at = timezone.now() if want else None
        if want:
            row.archived = False  # a chat can't be both pinned-to-top and archived
        row.save()
        return Response({"ok": True, "pinned": row.pinned})


class ChatArchiveView(_OrganiseBase):
    def post(self, request, pk):
        want = bool((request.data or {}).get("archived", True))
        row = self._row(request.user, pk)
        row.archived = want
        if want:  # archiving clears the pin (set_archived semantics)
            row.pinned = False
            row.pin_at = None
        row.save()
        return Response({"ok": True, "archived": row.archived})


class ChatMuteView(_OrganiseBase):
    def post(self, request, pk):
        from .logic import msg_organise as MO
        from django.utils.dateparse import parse_datetime
        dur = str((request.data or {}).get("duration", "8h"))
        row = self._row(request.user, pk)
        if dur == "off":
            row.mute_until = None
            row.muted_duration = None
            row.save()
            return Response({"ok": True, "muted": False})
        rec = MO.build_mute(str(pk), dur)
        until = rec["mute_until"]
        row.mute_until = parse_datetime(until) if until else None
        row.muted_duration = rec["duration"]
        row.save()
        return Response({"ok": True, "muted": True, "duration": rec["duration"]})


class ChatReadView(APIView):
    """Mark every message in this 1:1 chat read by the viewer (adds the viewer
    to CircleMessage.read_by). Honest: no-op if nothing is unread."""
    def post(self, request, pk):
        # c3-msg UNREAD-BADGE FIX: the peer's messages live on THEIR reverse
        # edge, so filtering member_id=pk never touched them and the badge
        # stayed at "10" forever. Mark the whole conversation seen (receipts +
        # read_by) and clear a manual "marked unread" flag.
        from . import views_c3_msg as C3
        n = C3.mark_chat_seen(request.user, "member", pk)
        if n is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        C3.set_marked_unread(request.user, "member", pk, False)
        return Response({"ok": True, "marked": n})


class MessagePrivacyView(APIView):
    """#96 Message-level privacy — who-can-message + phone-hidden. Conservative
    defaults (my_circle / hidden), persisted on CirclePrivacy; the normalize
    helper fails closed to the safe default. The message RELAY enforces the gate
    via msg_contacts.message_request_routing before persisting a stranger msg."""
    def _row(self, user):
        from .models import CirclePrivacy
        from .logic import msg_contacts as MC
        row, created = CirclePrivacy.objects.get_or_create(user=user)
        if created:
            row.who_can_message = MC.default_who_can_message()
            row.phone_hidden = MC.default_phone_hidden()
            row.save(update_fields=["who_can_message", "phone_hidden"])
        return row

    def get(self, request):
        row = self._row(request.user)
        return Response({"who_can_message": row.who_can_message,
                         "phone_hidden": bool(row.phone_hidden)})

    def post(self, request):
        from .logic import msg_contacts as MC
        d = request.data or {}
        row = self._row(request.user)
        row.who_can_message = MC.normalize_who_can_message(d.get("who_can_message"))
        if "phone_hidden" in d:
            row.phone_hidden = bool(d.get("phone_hidden"))
        row.save(update_fields=["who_can_message", "phone_hidden"])
        return Response({"ok": True, "who_can_message": row.who_can_message,
                         "phone_hidden": bool(row.phone_hidden)})


class CircleBlockedView(APIView):
    """#95 GET /circle/blocked — the viewer's blocked members (unblock reuses
    the existing /circle/<id>/controls {blocked:false})."""
    def get(self, request):
        rows = CircleMember.objects.filter(user=request.user, blocked=True)
        out = []
        for m in rows:
            name, photo = _resolve_peer(m)
            out.append({"id": m.id, "name": name, "phone": m.phone, "photo": photo})
        return Response({"blocked": out})


# (CircleMessageRequestsView moved to views_m1_messenger.MessageRequestsView —
#  backed by the real CommunityMessageRequest store, m1-messenger.)


class CircleRequestsView(APIView):
    def get(self, request):
        lang = req_lang(request)
        rows = CircleMember.objects.filter(user=request.user, state="pending")
        out = []
        for m in rows:
            name, photo = _resolve_peer(m)
            d = circle.serialize_request(
                m, direction=getattr(m, "direction", "outgoing"),
                display_name=name, photo=photo, lang=lang)
            _mr1_enrich(request.user, m, d)
            out.append(d)
        # mr1: newest activity first (a request with a fresh message on top)
        out.sort(key=lambda r: r.get("at") or r.get("created_at") or "",
                 reverse=True)
        return Response({"results": out})


def _mr1_enrich(viewer, m, d):
    """mr1: a request row also carries the conversation so far (the latest
    message envelope for the on-device preview, the count), the member
    payload to open the read-only request chat, and the sender's number
    ONLY when the sender allows it (show_phone) — else "" and the card says
    "Not in your contacts". Never raises."""
    try:
        from . import msgreq
        from .views_m1_messenger import visible_conversation
        d["photo_v"] = x2_photo_v(d.get("photo") or "")
        d["member"] = _member_dict(m)
        d["not_in_contacts"] = True
        peer = getattr(m, "peer_user", None)
        d["phone"] = msgreq.public_phone(peer) if (
            peer is not None and d.get("direction") == "incoming") else ""
        rows = list(visible_conversation(viewer, m))
        d["msg_count"] = len(rows)
        last = rows[-1] if rows else None
        if last is not None:
            from . import e2_keys
            d["last"] = {"id": last.id, "ciphertext": last.ciphertext,
                         "nonce": last.nonce, "scheme": last.scheme,
                         "sender_key_id": last.sender_key_id,
                         "content_type": last.content_type,
                         "mine": last.sender_id == viewer.id,
                         "deleted": last.deleted or "",
                         "peer_public_key": e2_keys.edge_key(m)[0] or "",
                         "created_at": last.created_at.isoformat()}
            d["at"] = last.created_at.isoformat()
            unseen = [x for x in rows if x.sender_id != viewer.id
                      and viewer.id not in (x.read_by or [])]
            d["unread"] = len(unseen)
        else:
            d["last"] = None
            d["unread"] = 0
    except Exception:  # noqa: BLE001
        pass
    return d


class CircleKeysView(APIView):
    def post(self, request):
        # Publish the PUBLIC key only (private key never leaves the device).
        # Reject anything that looks like a private key / recovery code.
        data = request.data or {}
        for forbidden in ("private_key", "priv", "recovery_code", "plaintext"):
            if data.get(forbidden):
                return Response({"detail": "only the public key may be sent"},
                                status=status.HTTP_400_BAD_REQUEST)
        # e2-keys: the key goes into the per-USER directory (UserPublicKey),
        # so it is never discarded (it used to be written only onto edges
        # pointing at me — none existed yet -> lost). Every peer-key read is
        # LIVE from there; nothing is copied onto edges any more.
        from . import e2_keys
        pub = str(data.get("public_key", "")).strip()[:200]
        row, created, changed = (None, False, False)
        if pub:
            row, created, changed = e2_keys.publish(
                request.user, pub, data.get("key_id", ""), data.get("scheme", ""))
        edges = CircleMember.objects.filter(peer_user=request.user).count() \
            if pub else 0
        return Response({"ok": True, "published": bool(pub), "edges": edges,
                         "created": created, "changed": changed,
                         "key_id": row.key_id if row else ""})


def _published_key(user):
    """(public_key, key_id, scheme) the user last published — from the
    per-user directory (e2-keys); empty strings when they never published."""
    from . import e2_keys
    return e2_keys.key_of(user)


def _thread_q(m):
    """m2-reality fix: a 1:1 thread is BOTH edges. A message is stored on the
    SENDER's edge, so the recipient's GET must also read the mirror edge
    (owner = my peer, peer_user = me). Without this the peer never saw it."""
    from django.db.models import Q
    q = Q(member=m)
    if getattr(m, "peer_user_id", None):
        q |= Q(member__user_id=m.peer_user_id, member__peer_user_id=m.user_id)
    return q


class CircleRequestCreateView(APIView):
    def post(self, request):
        data = request.data or {}
        raw_phone = str(data.get("phone", "")).strip()[:40]
        relation = circle.normalize_relation(data.get("relation", "friend"))
        note = str(data.get("note", "")).strip()[:500]  # ONE optional pre-accept note
        # c1-contacts: the number may arrive in ANY format (01…, +880…,
        # spaces, dashes, Bangla digits). Canonicalise it, refuse an invalid
        # one honestly, and find the account across legacy spellings.
        from .phone import canonical_phone, find_user as _find_by_phone
        phone = canonical_phone(raw_phone) if raw_phone else ""
        legacy_peer = None
        if raw_phone and not phone:
            # A pre-0051 account whose stored phone is not a valid number
            # (reported by the migration) stays reachable by its exact value;
            # anything else is refused honestly.
            legacy_peer = User.objects.filter(phone=raw_phone).first()
            if legacy_peer is None:
                return Response({"detail": "bad_phone", "reason": "bad_phone"},
                                status=status.HTTP_400_BAD_REQUEST)
            phone = raw_phone
        peer = legacy_peer
        to_id = data.get("to_user_id")
        if to_id not in (None, ""):
            try:
                peer = User.objects.filter(pk=int(to_id), is_active=True).first()
            except (TypeError, ValueError):
                peer = None
            if peer is None:
                return Response({"detail": "user not found"},
                                status=status.HTTP_404_NOT_FOUND)
            phone = phone or canonical_phone(peer.phone or "") or ""
        elif phone and peer is None:
            peer = _find_by_phone(phone)
        if not phone and peer is None:
            return Response({"detail": "bad_phone", "reason": "bad_phone"},
                            status=status.HTTP_400_BAD_REQUEST)
        if peer is not None and peer.id == request.user.id:
            return Response({"detail": "self_request", "reason": "self_request"},
                            status=status.HTTP_400_BAD_REQUEST)
        if peer is not None:
            existing = (CircleMember.objects.filter(
                user=request.user, peer_user=peer, direction="outgoing",
                state__in=("pending", "accepted")).order_by("-id").first())
            if existing is not None:
                return Response(_member_dict(existing), status=status.HTTP_200_OK)
            # m3-circle: WhatsApp-like "add each other". Already connected the
            # other way -> return that edge (no duplicate request). They already
            # asked ME -> adding them back IS accepting (both sides converge).
            from .views_m3_circle import mutual_add
            done = mutual_add(request.user, peer, relation,
                              str(data.get("custom_label", "")).strip()[:60])
            if done is not None:
                return Response(_member_dict(done), status=status.HTTP_200_OK)
        # mr1: new requests per sender per day are capped (abuse).
        from . import msgreq
        if peer is not None and msgreq.over_daily_limit(request.user):
            from .views_mr1 import refusal
            return refusal(req_lang(request), "rate_limited")
        # e2-keys: no key is copied onto the edge — _member_dict reads it live.
        # The SENDER's own row is OUTGOING (can only cancel it).
        m = CircleMember.objects.create(
            user=request.user,
            name=str(data.get("name", "")).strip()[:120],
            relation=relation,
            custom_label=str(data.get("custom_label", "")).strip()[:60],
            phone=phone,
            direction="outgoing",
            note=note,
            peer_user=peer,
            state="pending",
            sharing=circle.default_sharing(relation),
        )
        # Mirror an INCOMING row on the recipient's side so they get accept/
        # decline (and see WHO sent it). Only when the recipient has an account.
        if peer is not None and peer.id != request.user.id:
            CircleMember.objects.get_or_create(
                user=peer, peer_user=request.user, direction="incoming",
                state="pending",
                defaults={
                    "name": (getattr(request.user, "name", "") or "").strip(),
                    "phone": (getattr(request.user, "phone", "") or "")[:40],
                    "relation": circle.reciprocal_relation(relation),
                    "note": note,
                    "sharing": circle.default_sharing(
                        circle.reciprocal_relation(relation)),
                },
            )
        return Response(_member_dict(m), status=status.HTTP_201_CREATED)


class CircleRequestActView(APIView):
    def post(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        event = str((request.data or {}).get("event", ""))
        # BUG 2 FIX + server authorization: only the RECEIVER (incoming) may
        # accept/decline; the SENDER (outgoing) may only cancel. A user trying to
        # accept/decline their OWN outgoing request is rejected with 403.
        allowed, reason = circle.can_act_on_request(
            getattr(m, "direction", "outgoing"), event)
        if not allowed:
            return Response({"detail": reason},
                            status=status.HTTP_403_FORBIDDEN)
        prev_state = m.state
        new_state, changed = circle.apply_request_event(m.state, event)
        if not changed:
            return Response({"detail": "bad event"}, status=status.HTTP_400_BAD_REQUEST)
        m.state = new_state
        m.save(update_fields=["state"])
        # Mirror the accept/decline onto the sender's OUTGOING row (if linked) so
        # both sides converge: accept -> both accepted; decline -> sender's row
        # declined too.
        if event in ("accept", "decline") and getattr(m, "peer_user_id", None):
            mirror = CircleMember.objects.filter(
                user_id=m.peer_user_id, peer_user=request.user,
                direction="outgoing").first()
            if mirror is not None:
                mstate, mchanged = circle.apply_request_event(
                    mirror.state, event if event == "decline" else "accept")
                if mchanged:
                    mirror.state = mstate
                    mirror.save(update_fields=["state"])
        # e2-keys: an accept never dead-ends on "key missing" — whichever side
        # has not published yet gets a silent key_request push.
        if prev_state != "accepted" and new_state == "accepted":
            from . import e2_keys
            e2_keys.ensure_pair_keys(request.user, e2_keys.edge_peer(m))
        # Referral hook: award points when a relationship transitions to accepted.
        if prev_state != "accepted" and new_state == "accepted":
            try:
                from .views_build61 import award_referral_on_accept
                invitee_id = (request.data or {}).get("invitee_id")
                if invitee_id:
                    award_referral_on_accept(
                        request.user.id, invitee_id,
                        device_id=str((request.data or {}).get("device_id", "")))
            except Exception:
                pass  # referral is best-effort; never block the accept.
        return Response(_member_dict(m))


class CircleSharingView(APIView):
    def post(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        policy = (request.data or {}).get("sharing", {})
        m.sharing = circle.normalize_sharing(policy)
        m.save(update_fields=["sharing"])
        return Response(_member_dict(m))


class CircleReportView(APIView):
    def post(self, request, pk):
        lang = req_lang(request)
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        data = request.data or {}
        payload = circle.report_payload(request.user.id, m.id,
                                        data.get("reason", "other"),
                                        note=data.get("note", ""), lang=lang)
        CircleReport.objects.create(reporter=request.user, target=m,
                                    reason=payload["reason"], note=payload["note"])
        # Auto-block is a FLAG from the pure fn — the view enforces it.
        if payload.get("auto_block"):
            blocked, changed = circle.apply_request_event(m.state, "block")
            if changed:
                m.state = blocked
                m.save(update_fields=["state"])
        return Response(payload)


class CircleInviteView(APIView):
    def get(self, request):
        relation = request.query_params.get("relation", "friend")
        token = circle.make_invite_token(request.user.id, relation, settings.SECRET_KEY)
        inv = CircleInvite.objects.create(
            inviter=request.user,
            relation=circle.normalize_relation(relation),
            token=token,
            expires_at=timezone.now() + timezone.timedelta(minutes=1440),
        )
        # m3-circle: the link used to point at the OLD domain
        # (assisto.asalify.com) with no /i/ page behind it. It now uses the
        # live base and a real landing page (web/urls.py i/<token>).
        from .views_m3_circle import invite_base
        link = circle.qr_payload(token, base_url=invite_base())
        return Response({"token": token, "qr": link, "link": link, "id": inv.id})


class CircleMessagesView(APIView):
    def get(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        # m1-messenger: the WHOLE conversation (my sent rows on my edge + the
        # peer's rows on their reverse edge), minus what I cleared, deleted
        # for me, or what is past the disappearing timer.
        from .views_m1_messenger import visible_conversation
        uid = request.user.id
        msgs = visible_conversation(request.user, m)
        # e2-keys item 2: optional paging (?limit=&before=) for the reversed
        # chat list; no params = the whole conversation (older builds).
        from . import chat_paging
        meta = None
        if chat_paging.wants_page(request):
            msgs, meta = chat_paging.page(request, msgs, request.user)
        out = [{
            "id": x.id, "sender_id": x.sender_id, "content_type": x.content_type,
            "ciphertext": x.ciphertext, "nonce": x.nonce, "blob_ref": x.blob_ref,
            "sender_key_id": x.sender_key_id, "scheme": x.scheme,
            "created_at": x.created_at.isoformat(),
            "mine": x.sender_id == uid,
            "reply_to": x.reply_to_id, "reactions": x.reactions or {},
            "starred": uid in (x.starred_by or []), "pinned": x.pinned,
            "deleted": x.deleted or "",
            "edited_at": x.edited_at.isoformat() if x.edited_at else None,
            "forwarded": x.forwarded,
        } for x in msgs]
        # c3-msg: ticks (sent/delivered/read) on my own messages.
        from . import views_c3_msg as C3
        C3.annotate(out, msgs, request.user)
        C3.mark_fetched(request.user, msgs)   # x2-ticks: ack on any fetch
        # mr1: the chat learns live when a message request is accepted
        edge = {"state": m.state, "direction": m.direction or "outgoing",
                "request": _msgreq_info(m)}
        if meta is not None:
            chat_paging.mark_unseen(out, meta["unseen"])
            return Response({"results": out, "has_more": meta["has_more"],
                             "unread_count": meta["unread_count"],
                             "edge": edge})
        return Response({"results": out, "edge": edge})

    def post(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        env = dict(request.data or {})
        env.setdefault("content_type", "text")
        # Route to the member unless the client said otherwise.
        env.setdefault("recipient_ids", [m.id])
        # REVIEWER P1: the relay MUST prove the envelope is ciphertext-only
        # before persisting. The M1 validator extends the base contract with the
        # reply/forward/delete/link-preview checks (all still ciphertext-only).
        ok, reason = circle_messaging.validate_message_envelope(env)
        if not ok:
            return Response({"detail": reason}, status=status.HTTP_400_BAD_REQUEST)
        # M1 send gate: both sides accepted + not blocked (circle-only).
        blocked_either = bool(getattr(m, "blocked", False))
        # mr1: a MESSAGE REQUEST (my outgoing pending edge) may carry up to
        # N messages before the recipient accepts (core/msgreq.py).
        mr1_first = None
        if m.state != "accepted" and not blocked_either:
            from . import msgreq
            ok_r, why, first = msgreq.send_gate(m)
            _cm = str(env.get("client_msg_id", ""))[:64]
            if not ok_r and why == "request_limit" and _cm:
                dup = CircleMessage.objects.filter(
                    sender=request.user, member=m, client_msg_id=_cm).first()
                if dup is not None:   # an outbox retry of a stored message
                    return Response({"id": dup.id, "ok": True,
                                     "deduped": True},
                                    status=status.HTTP_200_OK)
            if not ok_r:
                lang = req_lang(request)
                detail = {
                    "request_limit": pick(
                        lang, "গ্রহণ না করা পর্যন্ত আর মেসেজ পাঠানো যাবে না।",
                        "You can send more after they accept."),
                    "accept_first": pick(
                        lang, "উত্তর দিতে আগে অনুরোধটি গ্রহণ করুন।",
                        "Accept the request to reply."),
                    "strangers_refused": pick(
                        lang, "এই মানুষটি শুধু তাঁর সার্কেলের লোকজনের মেসেজ নেন।",
                        "This person only takes messages from their circle."),
                }.get(why)
                body = {"detail": detail or why, "reason": why}
                return Response(body, status=status.HTTP_403_FORBIDDEN)
            mr1_first = first
        ok2, pre = circle_messaging.send_precheck(
            "accepted" if mr1_first is not None else m.state, "accepted",
            blocked_either=blocked_either,
            restricted=bool(getattr(m, "restricted", False)))
        if not ok2:
            return Response({"detail": pre}, status=status.HTTP_403_FORBIDDEN)
        # idempotent dedupe on (sender, client_msg_id).
        cmid = str(env.get("client_msg_id", ""))[:64]
        if cmid:
            dup = CircleMessage.objects.filter(
                sender=request.user, member=m, client_msg_id=cmid).first()
            if dup is not None:
                return Response({"id": dup.id, "ok": True, "deduped": True},
                                status=status.HTTP_200_OK)
        # m1-messenger: if the OTHER side blocked me, drop silently (WhatsApp
        # semantics: the sender is not told; nothing is stored or pushed).
        from .views_m1_messenger import reverse_edge
        _rev = reverse_edge(m)
        if _rev is not None and _rev.blocked:
            return Response({"ok": True, "dropped": True, "reason": "blocked"},
                            status=status.HTTP_200_OK)
        # Privacy relay decision (block -> drop, restrict -> quiet inbox).
        decision = circle_privacy.deliver_decision(
            {"id": request.user.id},
            {"blocked": [m.id] if getattr(m, "blocked", False) else [],
             "restricted": [m.id] if getattr(m, "restricted", False) else []})
        if not decision["deliver"]:
            return Response({"ok": True, "dropped": True,
                             "reason": decision["reason"]},
                            status=status.HTTP_200_OK)
        # x2-ticks ROOT-CAUSE FIX: `m` is the SENDER's own edge. Its
        # muted_until (the sender muted THIS chat — and bool() of a long-
        # expired timestamp is still True) used to suppress the push to the
        # RECIPIENT, so their phone never acked delivery and the tick stayed
        # ✓. The recipient's own mute is applied in push.hook_circle_message
        # (silent delivery ping there), so only the inbox routing counts here.
        notify = circle_privacy.should_notify({}, decision["inbox"])
        fh = int(env.get("forward_hops", 0) or 0)
        x = CircleMessage.objects.create(
            member=m, sender=request.user,
            recipient_ids=env.get("recipient_ids", []),
            content_type=env["content_type"],
            ciphertext=env.get("ciphertext", ""),
            nonce=env.get("nonce", ""),
            blob_ref=env.get("blob_ref", ""),
            sender_key_id=env.get("sender_key_id", ""),
            scheme=env.get("scheme", ""),
            client_msg_id=cmid,
            forwarded=bool(env.get("forwarded")),
            forward_hops=fh,
            link_preview=env.get("link_preview"),
        )
        # c3-msg: keep the quoted-reply link (it was dropped, so a reply lost
        # its quote after a reload). Only a message of THIS conversation.
        try:
            rid = int(env.get("reply_to") or 0)
        except (TypeError, ValueError):
            rid = 0
        if rid:
            from .views_m1_messenger import conversation_rows
            if conversation_rows(m).filter(pk=rid).exists():
                x.reply_to_id = rid
                x.save(update_fields=["reply_to"])
        if mr1_first is not None:
            # mr1: request push (one per sender) + silent delivery ping only.
            from . import msgreq
            msgreq.notify(request.user, m, x, mr1_first)
        elif notify:
            # FCM (key-gated, async, never raises): name + ids only, no text.
            from . import push
            push.hook_circle_message(request.user, m, x)
        return Response({"id": x.id, "ok": True, "inbox": decision["inbox"],
                         "notify": notify},
                        status=status.HTTP_201_CREATED)


class CircleMessageActionView(APIView):
    """POST /circle/messages/<id>/<action> -> react|star|pin|edit|delete.
    All gates (edit-window, pin-cap, delete scope) run server-side."""
    def post(self, request, pk, action):
        from django.db.models import Q
        # m2-reality: the recipient may act (react/star/delete-for-me) on a
        # message stored on the sender's edge of the same 1:1 thread.
        x = CircleMessage.objects.filter(
            Q(member__user=request.user) | Q(member__peer_user=request.user),
            pk=pk, group__isnull=True).first()
        if x is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        d = request.data or {}
        mid = request.user.id
        env = {
            "id": x.id, "sender_id": x.sender_id, "created_at": x.created_at,
            "reactions": x.reactions or {}, "starred_by": x.starred_by or [],
            "deleted": x.deleted or "",
        }
        if action == "react":
            emoji = str(d.get("emoji", ""))[:8]
            if emoji:
                env, _ = circle_messaging.add_reaction(env, mid, emoji)
            else:
                env, _ = circle_messaging.remove_reaction(env, mid)
            x.reactions = env["reactions"]
            x.save(update_fields=["reactions"])
            return Response({"ok": True, "reactions": x.reactions})
        if action == "star":
            env, now_starred = circle_messaging.toggle_star(env, mid)
            x.starred_by = env["starred_by"]
            x.save(update_fields=["starred_by"])
            return Response({"ok": True, "starred": now_starred})
        if action == "pin":
            pinned_count = CircleMessage.objects.filter(
                member=x.member, pinned=True).exclude(pk=x.pk).count()
            if not x.pinned and not circle_messaging.can_pin(
                    [0] * pinned_count, x.id):
                lang = req_lang(request)
                return Response({"ok": False, "detail": "pin_cap"},
                                status=status.HTTP_400_BAD_REQUEST)
            x.pinned = not x.pinned
            x.save(update_fields=["pinned"])
            return Response({"ok": True, "pinned": x.pinned})
        if action == "edit":
            if x.sender_id != mid or not circle_messaging.can_edit(env, mid):
                return Response({"ok": False, "detail": "edit_window"},
                                status=status.HTTP_403_FORBIDDEN)
            x.ciphertext = str(d.get("ciphertext", x.ciphertext))
            x.nonce = str(d.get("nonce", x.nonce))
            x.edited_at = timezone.now()
            x.save(update_fields=["ciphertext", "nonce", "edited_at"])
            return Response({"ok": True, "edited_at": x.edited_at.isoformat()})
        if action == "delete":
            scope = str(d.get("scope", "me"))
            if scope == "everyone":
                if x.sender_id != mid or not \
                        circle_messaging.can_delete_for_everyone(env, mid):
                    return Response({"ok": False, "detail": "delete_window"},
                                    status=status.HTTP_403_FORBIDDEN)
                x.deleted = "everyone"
                x.ciphertext = ""
                x.nonce = ""
                x.save(update_fields=["deleted", "ciphertext", "nonce"])
            else:
                hidden = set(x.hidden_for or [])
                hidden.add(mid)
                x.hidden_for = list(hidden)
                x.save(update_fields=["hidden_for"])
            return Response({"ok": True, "deleted": x.deleted or "me"})
        return Response({"detail": "unknown action"},
                        status=status.HTTP_400_BAD_REQUEST)


# ---------------------------------------------------------------------------
# Scoped read gate (REVIEWER P1 #3): a member may only read a scope the owner
# shares with them. Server-side enforcement — never trust the client.
# ---------------------------------------------------------------------------

class CircleScopedReadView(APIView):
    """GET /circle/<id>/see/<scope> -> {allowed, scope}. Demonstrates the
    server-side can_see gate the real scoped data endpoints reuse."""
    def get(self, request, pk, scope):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        if m.state != "accepted" or not circle.can_see(m.sharing or {}, scope):
            return Response({"allowed": False, "scope": scope},
                            status=status.HTTP_403_FORBIDDEN)
        return Response({"allowed": True, "scope": scope})
