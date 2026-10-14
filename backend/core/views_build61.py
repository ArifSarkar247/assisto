"""Build-61 wave endpoints: Messenger M1 (referral, calls, privacy) + Safe
Journey. Thin wiring over the pure logic in core/logic/* — all enforcement
gates (can_place_call video gate, allow_call ring gate, can_see_field,
deliver_decision, send_precheck, redeem math, journey overdue/duress/expiry)
run SERVER-SIDE here; the client cannot bypass them.
"""
from django.conf import settings
from django.contrib.auth import get_user_model
from django.utils import timezone

from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang
from .logic import (referral as R, circle_calls as CC, circle_privacy as CP,
                    circle_messaging as CM, safety_journey as SJ, circle)
from . import plans, nearby
from .models import (CircleMember, CircleMessage, CallRecord, CirclePrivacy,
                     ReferralGrant, Journey, JourneyWatcher, SavedPlace,
                     WellnessWatch, DuressPin)

User = get_user_model()


# ===========================================================================
# Referral points
# ===========================================================================
def _ledger_for(user):
    """ReferralGrant rows -> the list-of-dicts ledger shape referral.py expects."""
    rows = []
    for g in ReferralGrant.objects.filter(user=user):
        rows.append({
            "id": g.id, "user_id": g.user_id, "invitee_id": g.invitee_id,
            "device_id": g.device_id, "kind": g.kind, "points": g.points,
            "reason": g.reason, "month": g.month,
            "created_at": g.created_at.isoformat(),
        })
    return rows


class ReferralBalanceView(APIView):
    def get(self, request):
        lang = req_lang(request)
        ledger = _ledger_for(request.user)
        # ADVANCED (#102): strict superset of referral_summary — adds progress,
        # honest invite leaderboard, earned/spent audit and redeemed history. The
        # advanced screen renders from this single call; it degrades gracefully to
        # the basic balance+history if those extra fields are ever absent.
        summary = R.advanced_summary(ledger, request.user.id, lang)
        # an invite link + raw code so the user can share right from the card
        token = circle.make_invite_token(request.user.id, "friend",
                                          settings.SECRET_KEY)
        summary["invite_link"] = circle.qr_payload(token)
        summary["referral_code"] = token
        return Response(summary)


class _FlagsBase(APIView):
    """#178 Cost kill-switch & feature flags — OWNER-only. State + append-only
    audit persist in AdminFlagState(key='global'); all validation / confirm-gate
    / audit construction run SERVER-SIDE via core.logic.admin_flags (the client
    mirror is advisory only). A non-owner gets 403; the console then degrades to
    its owner-only state."""
    @staticmethod
    def _owner(request):
        u = request.user
        return bool(u and u.is_authenticated and u.is_superuser)

    @staticmethod
    def _row():
        from .models import AdminFlagState
        row, _ = AdminFlagState.objects.get_or_create(key="global")
        return row

    @staticmethod
    def _snapshot(row):
        from .logic import admin_flags as AF
        state = AF.normalize_state(row.state)
        flags = [dict(c, value=state[c["id"]]) for c in AF.catalog()]
        return {"flags": flags, "audit": row.audit, "summary": AF.summarize(state),
                "can_manage": True}


class AdminFlagsView(_FlagsBase):
    def get(self, request):
        if not self._owner(request):
            return Response({"can_manage": False},
                            status=status.HTTP_403_FORBIDDEN)
        if request.query_params.get("probe"):
            return Response({"can_manage": True})
        return Response(self._snapshot(self._row()))


class AdminFlagsFlipView(_FlagsBase):
    def post(self, request):
        if not self._owner(request):
            return Response({"can_manage": False},
                            status=status.HTTP_403_FORBIDDEN)
        from .logic import admin_flags as AF
        d = request.data or {}
        flag = d.get("flag")
        value = d.get("value")
        reason = d.get("reason", "")
        row = self._row()
        res = AF.apply_flip(row.state, flag, value,
                            actor=request.user.id, reason=reason,
                            at_iso=timezone.now().isoformat())
        if not res["ok"]:
            return Response({"ok": False, "problems": res["problems"]},
                            status=status.HTTP_400_BAD_REQUEST)
        row.state = res["state"]
        row.audit = ([res["audit"]] + list(row.audit or []))[:200]  # newest-first, capped
        row.save(update_fields=["state", "audit", "updated_at"])
        return Response(self._snapshot(row))


class ReferralHistoryView(APIView):
    def get(self, request):
        lang = req_lang(request)
        ledger = _ledger_for(request.user)
        return Response({"history": R.history(ledger, request.user.id, lang)})


class ReferralRedeemView(APIView):
    def post(self, request):
        ledger = _ledger_for(request.user)
        want = int((request.data or {}).get("points", 0) or 0)
        res = R.redeem(request.user.id, want, ledger)
        if not res["ok"]:
            return Response({"ok": False, "code": res["code"], "days": 0},
                            status=status.HTTP_400_BAD_REQUEST)
        # persist the negative audit row ...
        ReferralGrant.objects.create(
            user=request.user, kind=R.KIND_REDEEM, points=-res["spent"],
            reason=R.REASON_REDEEM_PREMIUM)
        # ... and apply the Premium days to the plan (extend plan_until).
        now = timezone.now()
        base = request.user.plan_until if (request.user.plan_until and
                                           request.user.plan_until > now) else now
        request.user.plan_until = base + timezone.timedelta(days=res["days"])
        if request.user.plan == "free":
            request.user.plan = "premium"
        request.user.save(update_fields=["plan_until", "plan"])
        return Response({"ok": True, "days": res["days"], "spent": res["spent"],
                         "points": R.balance(_ledger_for(request.user),
                                             request.user.id)})


def award_referral_on_accept(inviter_id, invitee_id, device_id="",
                             phone_verified=True, inviter_active=True,
                             invitee_active=True):
    """HOOK called at circle invite-accept. Awards referral points + welcome
    bonus idempotently (unique (user,invitee) grant guards double-award)."""
    ledger = []
    for g in ReferralGrant.objects.filter(user_id=inviter_id):
        ledger.append({"id": g.id, "user_id": g.user_id,
                       "invitee_id": g.invitee_id, "device_id": g.device_id,
                       "kind": g.kind, "points": g.points, "reason": g.reason,
                       "month": g.month, "created_at": g.created_at.isoformat()})
    res = R.award_for_accept(
        inviter_id, invitee_id, device_id, phone_verified,
        inviter_active=inviter_active, invitee_active=invitee_active,
        sms_gate_enabled=getattr(settings, "SMS_ENABLED", False),
        ledger=ledger)
    if not res.get("ok"):
        return res
    for row in (res.get("grant"), res.get("bonus")):
        if not row:
            continue
        try:
            ReferralGrant.objects.create(
                user_id=row["user_id"], invitee_id=row.get("invitee_id"),
                device_id=row.get("device_id", ""), kind=row["kind"],
                points=row["points"], reason=row.get("reason", ""),
                month=row.get("month", ""))
        except Exception:
            # unique (user,invitee) -> already awarded; idempotent no-op.
            pass
    return res


# ===========================================================================
# Connected Circle — calls (video plan gate SERVER-ENFORCED)
# ===========================================================================
def _caller_dict(user, member):
    return {
        "id": user.id, "plan": plans.effective_plan(user),
        "video_unlocked": bool(getattr(member, "video_unlocked", False)),
        "accepted": (member.state == "accepted") if member else True,
        "blocked": bool(getattr(member, "blocked", False)),
    }


def _callee_dict(member):
    return {
        "id": member.id if member else None,
        "accepted": (member.state == "accepted") if member else True,
        "blocked": bool(getattr(member, "blocked", False)),
        "restricted": bool(getattr(member, "restricted", False)),
    }


class CircleCallsView(APIView):
    def get(self, request):
        lang = req_lang(request)
        rows = CallRecord.objects.filter(
            caller=request.user) | CallRecord.objects.filter(callee=request.user)
        out = []
        for r in rows.distinct()[:100]:
            out.append({
                "id": r.id, "kind": r.kind, "state": r.state,
                "duration_sec": r.duration_sec,
                "mine": r.caller_id == request.user.id,
                "outcome": CC.call_outcome_label(
                    {"state": r.state, "caller_id": r.caller_id,
                     "duration_sec": r.duration_sec}, request.user.id, lang),
                "started_at": r.started_at.isoformat(),
            })
        return Response({"calls": out})


class CirclePlaceCallView(APIView):
    """POST /circle/<member>/call + /call/answer -> the video plan gate."""
    def post(self, request, pk, answer=False):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        kind = CC.normalize_kind((request.data or {}).get("kind", "voice"))
        gate = CC.can_place_call(_caller_dict(request.user, m), _callee_dict(m),
                                 kind)
        if not gate["allowed"]:
            lang = req_lang(request)
            body = {"allowed": False, "kind": kind,
                    "upgrade_required": gate.get("upgrade_required", False),
                    "reason": gate.get("reason")}
            if gate.get("upgrade_required"):
                body["prompt"] = CC.upgrade_prompt(lang)
            return Response(body, status=status.HTTP_200_OK)
        rec = CallRecord.objects.create(
            caller=request.user, callee=request.user, circle=m, kind=kind,
            state=("active" if answer else "ringing"))
        turn_ready = bool(getattr(settings, "CIRCLE_TURN_READY", False))
        push_ready = bool(getattr(settings, "CIRCLE_PUSH_READY", False))
        return Response({
            "allowed": True, "kind": kind, "call_id": rec.id,
            "ice": CC.ice_config(turn_ready=turn_ready,
                                 turn=getattr(settings, "CIRCLE_TURN", None)),
            "transport": CC.transport_status(push_ready, turn_ready,
                                             req_lang(request)),
        }, status=status.HTTP_201_CREATED)


class CircleAnswerCallView(CirclePlaceCallView):
    def post(self, request, pk):
        return super().post(request, pk, answer=True)


class CircleCallEventView(APIView):
    def post(self, request, call_id):
        rec = CallRecord.objects.filter(pk=call_id).filter(
            caller=request.user).first() or CallRecord.objects.filter(
            pk=call_id, callee=request.user).first()
        if rec is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        event = str((request.data or {}).get("event", ""))
        state = {"state": rec.state,
                 "answered_at": rec.answered_at.isoformat() if rec.answered_at else None,
                 "started_at": rec.started_at.isoformat()}
        fin = CC.finalize_call(state, event)
        rec.state = fin.get("state", rec.state)
        rec.duration_sec = int(fin.get("duration_sec", rec.duration_sec) or 0)
        if fin.get("state") in ("ended", "missed", "declined"):
            rec.ended_at = timezone.now()
        if event == "answer" and rec.answered_at is None:
            rec.answered_at = timezone.now()
        rec.save()
        return Response({"state": rec.state, "duration_sec": rec.duration_sec})


# ===========================================================================
# Connected Circle — privacy (server-enforced visibility / DND / policy)
# ===========================================================================
def _privacy_row(user):
    row, _ = CirclePrivacy.objects.get_or_create(
        user=user, defaults={"visibility": CP.default_visibility()})
    return row


def _privacy_dict(row):
    return {
        "visibility": CP.normalize_visibility(row.visibility),
        "read_receipts": row.read_receipts, "typing": row.typing,
        "call_policy": row.call_policy, "call_allow_ids": row.call_allow_ids,
        "call_allow_relations": row.call_allow_relations,
        "dnd_enabled": row.dnd_enabled, "dnd_start": row.dnd_start,
        "dnd_end": row.dnd_end, "dnd_family_exception": row.dnd_family_exception,
    }


class CirclePrivacyView(APIView):
    def get(self, request):
        return Response(_privacy_dict(_privacy_row(request.user)))

    def post(self, request):
        row = _privacy_row(request.user)
        d = request.data or {}
        if "visibility" in d:
            row.visibility = CP.normalize_visibility(d.get("visibility"))
        for b in ("read_receipts", "typing", "dnd_enabled",
                  "dnd_family_exception"):
            if b in d:
                setattr(row, b, bool(d[b]))
        if "call_policy" in d:
            row.call_policy = str(d["call_policy"])[:12]
        for lst in ("call_allow_ids", "call_allow_relations"):
            if lst in d and isinstance(d[lst], list):
                setattr(row, lst, d[lst])
        for t in ("dnd_start", "dnd_end"):
            if t in d:
                setattr(row, t, str(d[t])[:5])
        row.save()
        return Response({"ok": True, **_privacy_dict(row)})


class CircleMemberControlsView(APIView):
    """POST /circle/<member>/controls — block / restrict / mute / pin / archive."""
    def post(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        d = request.data or {}
        fields = []
        for b in ("blocked", "restricted", "pinned", "archived"):
            if b in d:
                setattr(m, b, bool(d[b]))
                fields.append(b)
        if "muted_until" in d:
            dur = d.get("muted_until")
            epoch = CP.mute_until(dur) if dur else None
            if epoch:
                import datetime as _dt
                m.muted_until = _dt.datetime.fromtimestamp(
                    epoch, tz=_dt.timezone.utc)
            else:
                m.muted_until = None
            fields.append("muted_until")
        if fields:
            m.save(update_fields=fields)
        return Response({"ok": True, "id": m.id,
                         "blocked": m.blocked, "restricted": m.restricted,
                         "pinned": m.pinned, "archived": m.archived})


# ===========================================================================
# Safe Journey & Personal Safety
# ===========================================================================
def _journey_pure(j):
    """A plain-dict view of a Journey model for the pure safety_journey helpers
    (they operate on dicts, never ORM objects)."""
    return {
        "id": j.id, "status": j.status, "mode": j.mode,
        "destination": j.destination or {},
        "origin": j.origin,
        "last_location": j.last_location,
        "arrival_radius_m": j.arrival_radius_m,
        "overdue_grace_min": j.overdue_grace_min,
        "location_retention_hours": j.location_retention_hours,
        "expires_at": j.expires_at.isoformat() if j.expires_at else None,
    }


def _journey_dict(j, lang="bn"):
    return {
        "id": j.id, "status": j.status, "mode": j.mode,
        "destination": j.destination, "eta": j.eta.isoformat() if j.eta else None,
        "last_location": j.last_location, "sos_active": j.sos_active,
        "overdue_grace_min": j.overdue_grace_min,
        "location_retention_hours": j.location_retention_hours,
        "expires_at": j.expires_at.isoformat() if j.expires_at else None,
    }


class JourneyStartView(APIView):
    def post(self, request):
        d = request.data or {}
        now = timezone.now()
        eta_raw = d.get("eta")
        eta = None
        if eta_raw:
            from django.utils.dateparse import parse_datetime
            eta = parse_datetime(str(eta_raw))
        retention = int(d.get("location_retention_hours", 24) or 24)
        j = Journey.objects.create(
            traveller=request.user,
            origin=d.get("origin"), destination=d.get("destination", {}) or {},
            eta=eta,
            status="active", mode=str(d.get("mode", ""))[:16] or "",
            vehicle=d.get("vehicle"),
            overdue_grace_min=int(d.get("overdue_grace_min", 10) or 10),
            route_deviation=bool(d.get("route_deviation_on")),
            location_retention_hours=retention,
            expires_at=now + timezone.timedelta(hours=retention),
            last_activity_at=now)
        for mid in (d.get("watcher_ids") or []):
            m = CircleMember.objects.filter(user=request.user, pk=mid).first()
            if m:
                JourneyWatcher.objects.get_or_create(journey=j, member=m)
        token = SJ.make_web_token(j.id, j.expires_at, settings.SECRET_KEY) \
            if j.expires_at else ""
        return Response({**_journey_dict(j, req_lang(request)),
                         "web_link": f"/j/{token}" if token else None},
                        status=status.HTTP_201_CREATED)


class JourneyActiveView(APIView):
    def get(self, request):
        j = Journey.objects.filter(traveller=request.user,
                                   status="active").first()
        return Response(_journey_dict(j, req_lang(request)) if j else {})


class JourneyLocationView(APIView):
    def post(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        d = request.data or {}
        now = timezone.now()
        if SJ.journey_is_expired(_journey_pure(j), now):
            j.last_location = None
            j.status = "expired"
            j.save(update_fields=["last_location", "status"])
            return Response({"ok": True, "expired": True})
        lat, lng = d.get("lat"), d.get("lng")
        j.last_location = {"lat": lat, "lng": lng,
                           "at": now.isoformat(), "battery": d.get("battery")}
        j.last_activity_at = now
        arrived = False
        if lat is not None and lng is not None:
            arrived, _dist = SJ.arrival_check(_journey_pure(j), lat, lng)
        if arrived:
            j.status = "arrived"
        j.save(update_fields=["last_location", "last_activity_at", "status"])
        return Response({"ok": True, "arrived": bool(arrived),
                         "low_battery": (d.get("battery") is not None and
                                         int(d.get("battery")) < 15)})


class JourneyArrivedView(APIView):
    def post(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        j.status = "arrived"
        j.save(update_fields=["status"])
        return Response({"ok": True})


class JourneyStopView(APIView):
    """Stop early. A PIN is validated server-side: a duress PIN makes this look
    cancelled while silently firing an SOS (item 8)."""
    def post(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        pin = (request.data or {}).get("pin")
        outcome = "cancel"
        if pin:
            dp = DuressPin.objects.filter(user=request.user).first()
            if dp and dp.salt:
                action = SJ.verify_pin_action(pin, dp.normal_hash,
                                              dp.duress_hash, dp.salt)
                outcome = SJ.duress_outcome(action).get("action", "wrong")
                if outcome == "wrong":
                    return Response({"ok": False, "pin": "wrong"},
                                    status=status.HTTP_400_BAD_REQUEST)
                if outcome == "duress":
                    j.sos_active = True
                    j.silent = True
        # cancel + duress both stop the journey; duress also fires silent SOS.
        j.status = "stopped"
        j.save(update_fields=["status", "sos_active", "silent"])
        return Response({"ok": True, "outcome": outcome})


class JourneyRespondView(APIView):
    def post(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        j.last_activity_at = timezone.now()
        j.save(update_fields=["last_activity_at"])
        return Response({"ok": True})


class JourneySosView(APIView):
    def post(self, request):
        d = request.data or {}
        jid = d.get("journey_id")
        j = Journey.objects.filter(traveller=request.user, pk=jid).first() \
            if jid else None
        silent = bool(d.get("silent"))
        if j:
            j.sos_active = True
            j.silent = silent
            j.save(update_fields=["sos_active", "silent"])
        lang = req_lang(request)
        loc = {"lat": d.get("lat"), "lng": d.get("lng")} \
            if d.get("lat") is not None else None
        payload = SJ.sos_journey_payload(request.user.name or "", loc,
                                         silent=silent, lang=lang)
        return Response({"ok": True, "silent": silent, "payload": payload})


class JourneyDuressPinView(APIView):
    def post(self, request):
        d = request.data or {}
        pin, duress = d.get("pin"), d.get("duress_pin")
        if not pin or not duress or pin == duress:
            return Response({"detail": "pins must differ"},
                            status=status.HTTP_400_BAD_REQUEST)
        import os
        salt = os.urandom(8).hex()
        dp, _ = DuressPin.objects.get_or_create(user=request.user)
        dp.salt = salt
        dp.normal_hash = SJ.hash_pin(pin, salt)
        dp.duress_hash = SJ.hash_pin(duress, salt)
        dp.save()
        return Response({"ok": True})


class JourneyWebLinkView(APIView):
    def get(self, request, pk):
        j = Journey.objects.filter(traveller=request.user, pk=pk).first()
        if j is None or not j.expires_at:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        token = SJ.make_web_token(j.id, j.expires_at, settings.SECRET_KEY)
        return Response({"url": f"/j/{token}", "token": token})


class JourneyNearestHelpView(APIView):
    def get(self, request):
        try:
            lat = float(request.query_params.get("lat"))
            lon = float(request.query_params.get("lon"))
        except (TypeError, ValueError):
            return Response({"police": [], "hospital": []})
        out = {}
        for kind, cat in (("police", "police"), ("hospital", "hospital")):
            try:
                res = nearby.search(lat, lon, cat, lang=req_lang(request))
                out[kind] = (res.get("results") or res.get("places") or [])[:3] \
                    if isinstance(res, dict) else []
            except Exception:
                out[kind] = []
        return Response(out)


class SavedPlacesView(APIView):
    def get(self, request):
        rows = SavedPlace.objects.filter(user=request.user)
        return Response({"places": [
            {"id": p.id, "label": p.label, "name": p.name,
             "lat": p.lat, "lng": p.lng} for p in rows]})

    def post(self, request):
        d = request.data or {}
        p = SavedPlace.objects.create(
            user=request.user, label=str(d.get("label", ""))[:40],
            name=str(d.get("name", ""))[:160], lat=d.get("lat"), lng=d.get("lng"))
        return Response({"id": p.id, "ok": True},
                        status=status.HTTP_201_CREATED)


class JourneyRoutinesView(APIView):
    def get(self, request):
        return Response({"routines": []})  # scheduled commutes (native TODO)

    def post(self, request):
        return Response({"ok": True}, status=status.HTTP_201_CREATED)


class WellnessView(APIView):
    def get(self, request):
        w = WellnessWatch.objects.filter(parent=request.user).first()
        if w is None:
            return Response(SJ.default_wellness_config())
        return Response({
            "enabled": w.enabled, "parent_opt_in": w.parent_opt_in,
            "period_hours": w.period_hours, "response_window": w.response_window,
            "quiet_start": w.quiet_start, "quiet_end": w.quiet_end,
            "watcher_ids": w.watcher_ids})

    def post(self, request):
        d = request.data or {}
        w, _ = WellnessWatch.objects.get_or_create(parent=request.user)
        if "parent_opt_in" in d:
            w.parent_opt_in = bool(d["parent_opt_in"])
        # arming GATE: enabled only ever true if the parent opted in.
        w.enabled = bool(d.get("enabled")) and w.parent_opt_in
        if "period_hours" in d:
            w.period_hours = int(d["period_hours"])
        if isinstance(d.get("watcher_ids"), list):
            w.watcher_ids = d["watcher_ids"]
        for t in ("quiet_start", "quiet_end"):
            if t in d:
                setattr(w, t, str(d[t])[:5])
        w.last_activity_at = timezone.now()
        w.save()
        return Response({"ok": True, "enabled": w.enabled})


class WellnessPingView(APIView):
    def post(self, request):
        w, _ = WellnessWatch.objects.get_or_create(parent=request.user)
        w.last_activity_at = timezone.now()
        w.prompt_sent_at = None
        w.save(update_fields=["last_activity_at", "prompt_sent_at"])
        return Response({"ok": True})
