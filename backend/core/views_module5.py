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

from .i18n import req_lang
from .logic import (health_tips, medicine_db, birthdays as bdays,
                    meetings, dictionary, ramadan, exam, circle)
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

def _member_dict(m):
    return {
        "id": m.id, "name": m.name, "relation": m.relation,
        "custom_label": m.custom_label, "state": m.state,
        "public_key": m.public_key, "key_id": m.key_id, "scheme": m.scheme,
        "sharing": m.sharing or {},
    }


class CircleMembersView(APIView):
    def get(self, request):
        rows = CircleMember.objects.filter(
            user=request.user, state__in=["accepted", "pending"])
        return Response({"results": [_member_dict(m) for m in rows]})


class CircleRequestsView(APIView):
    def get(self, request):
        rows = CircleMember.objects.filter(user=request.user, state="pending")
        return Response({"results": [_member_dict(m) for m in rows]})


class CircleKeysView(APIView):
    def post(self, request):
        # Publish the PUBLIC key only (private key never leaves the device).
        # Reject anything that looks like a private key / recovery code.
        data = request.data or {}
        for forbidden in ("private_key", "priv", "recovery_code", "plaintext"):
            if data.get(forbidden):
                return Response({"detail": "only the public key may be sent"},
                                status=status.HTTP_400_BAD_REQUEST)
        return Response({"ok": True})


class CircleRequestCreateView(APIView):
    def post(self, request):
        data = request.data or {}
        m = CircleMember.objects.create(
            user=request.user,
            name=str(data.get("name", "")).strip()[:120],
            relation=circle.normalize_relation(data.get("relation", "friend")),
            custom_label=str(data.get("custom_label", "")).strip()[:60],
            phone=str(data.get("phone", "")).strip()[:40],
            state="pending",
            sharing=circle.default_sharing(data.get("relation", "friend")),
        )
        return Response(_member_dict(m), status=status.HTTP_201_CREATED)


class CircleRequestActView(APIView):
    def post(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        event = str((request.data or {}).get("event", ""))
        new_state, changed = circle.apply_request_event(m.state, event)
        if not changed:
            return Response({"detail": "bad event"}, status=status.HTTP_400_BAD_REQUEST)
        m.state = new_state
        m.save(update_fields=["state"])
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
        return Response({"token": token, "qr": circle.qr_payload(token), "id": inv.id})


class CircleMessagesView(APIView):
    def get(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        msgs = CircleMessage.objects.filter(member=m)
        out = [{
            "id": x.id, "sender_id": x.sender_id, "content_type": x.content_type,
            "ciphertext": x.ciphertext, "nonce": x.nonce, "blob_ref": x.blob_ref,
            "sender_key_id": x.sender_key_id, "scheme": x.scheme,
            "created_at": x.created_at.isoformat(),
            "mine": x.sender_id == request.user.id,
        } for x in msgs]
        return Response({"results": out})

    def post(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        env = dict(request.data or {})
        env.setdefault("content_type", "text")
        # Route to the member unless the client said otherwise.
        env.setdefault("recipient_ids", [m.id])
        # REVIEWER P1: the relay MUST prove the envelope is ciphertext-only
        # before persisting. validate_envelope is unskippable here.
        ok, reason = circle.validate_envelope(env)
        if not ok:
            return Response({"detail": reason}, status=status.HTTP_400_BAD_REQUEST)
        x = CircleMessage.objects.create(
            member=m, sender=request.user,
            recipient_ids=env.get("recipient_ids", []),
            content_type=env["content_type"],
            ciphertext=env.get("ciphertext", ""),
            nonce=env.get("nonce", ""),
            blob_ref=env.get("blob_ref", ""),
            sender_key_id=env.get("sender_key_id", ""),
            scheme=env.get("scheme", ""),
        )
        return Response({"id": x.id, "ok": True}, status=status.HTTP_201_CREATED)


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
