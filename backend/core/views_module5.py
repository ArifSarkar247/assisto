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
        peer = User.objects.filter(phone=m.phone.strip()).first()
    if peer is not None:
        name = (getattr(peer, "name", "") or "").strip() or name or peer.username
        photo = getattr(peer, "photo_url", "") or ""
    return name, photo


def _member_dict(m):
    name, photo = _resolve_peer(m)
    return {
        "id": m.id, "name": name, "display_name": name, "photo": photo,
        "relation": m.relation,
        "relation_label": circle.relation_label(m.relation, "bn", m.custom_label),
        "custom_label": m.custom_label, "state": m.state,
        "public_key": m.public_key, "key_id": m.key_id, "scheme": m.scheme,
        "sharing": m.sharing or {},
    }


class CircleMembersView(APIView):
    def get(self, request):
        # BUG 3 FIX: a person is in "Your circle" ONLY once accepted. Pending
        # (incoming OR outgoing) must NOT appear here.
        rows = CircleMember.objects.filter(user=request.user, state="accepted")
        return Response({"results": [_member_dict(m) for m in rows]})


class CircleRequestsView(APIView):
    def get(self, request):
        lang = req_lang(request)
        rows = CircleMember.objects.filter(user=request.user, state="pending")
        out = []
        for m in rows:
            name, photo = _resolve_peer(m)
            out.append(circle.serialize_request(
                m, direction=getattr(m, "direction", "outgoing"),
                display_name=name, photo=photo, lang=lang))
        return Response({"results": out})


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
        phone = str(data.get("phone", "")).strip()[:40]
        relation = circle.normalize_relation(data.get("relation", "friend"))
        note = str(data.get("note", "")).strip()[:500]  # ONE optional pre-accept note
        peer = User.objects.filter(phone=phone).first() if phone else None
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
        # before persisting. The M1 validator extends the base contract with the
        # reply/forward/delete/link-preview checks (all still ciphertext-only).
        ok, reason = circle_messaging.validate_message_envelope(env)
        if not ok:
            return Response({"detail": reason}, status=status.HTTP_400_BAD_REQUEST)
        # M1 send gate: both sides accepted + not blocked (circle-only).
        blocked_either = bool(getattr(m, "blocked", False))
        ok2, pre = circle_messaging.send_precheck(
            m.state, "accepted", blocked_either=blocked_either,
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
        # Privacy relay decision (block -> drop, restrict -> quiet inbox).
        decision = circle_privacy.deliver_decision(
            {"id": request.user.id},
            {"blocked": [m.id] if getattr(m, "blocked", False) else [],
             "restricted": [m.id] if getattr(m, "restricted", False) else []})
        if not decision["deliver"]:
            return Response({"ok": True, "dropped": True,
                             "reason": decision["reason"]},
                            status=status.HTTP_200_OK)
        notify = circle_privacy.should_notify(
            {"muted": bool(getattr(m, "muted_until", None))}, decision["inbox"])
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
        return Response({"id": x.id, "ok": True, "inbox": decision["inbox"],
                         "notify": notify},
                        status=status.HTTP_201_CREATED)


class CircleMessageActionView(APIView):
    """POST /circle/messages/<id>/<action> -> react|star|pin|edit|delete.
    All gates (edit-window, pin-cap, delete scope) run server-side."""
    def post(self, request, pk, action):
        x = CircleMessage.objects.filter(
            pk=pk, member__user=request.user).first()
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
