"""
Anti-theft Batch 5 — lost/stolen server-side.

SERVER IS THE SOURCE OF TRUTH (see views_security). The native engine reports
heartbeats and captured events here; it cannot grant itself a capability. In
particular, turning OFF lost mode is the Section-8 sensitive action
'turn_off_lost' and MUST go through POST security/action — never this file.

Everything here is honest and coarse: we never fabricate a location, a SIM
number, or a police station. When we don't know, we say so.
"""
from datetime import timedelta

from django.conf import settings
from django.http import FileResponse, Http404, HttpResponse
from django.utils import timezone

from rest_framework import status
from rest_framework.parsers import JSONParser, MultiPartParser, FormParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import (ProtectedPhone, PhoneHeartbeat, CapturedEvent,
                     CircleMember, HEARTBEAT_RETENTION_HOURS)
from .i18n import req_lang, pick
from .logic import security as sec
from .views_security import _primary_phone, _notify_owner_and_circle


# --------------------------------------------------------------------------
# shared helpers
# --------------------------------------------------------------------------

# "went dark" = no heartbeat for interval * this multiple. The native engine
# pings every heartbeat_interval_min; a few missed pings is normal (tunnel,
# battery, sleep), so we wait for several before crying theft.
WENT_DARK_MULTIPLE = 3
WENT_DARK_FLOOR_MIN = 30   # never alert on a gap shorter than this
TRAIL_LIMIT = 50           # recent heartbeats returned in the lost-phone view


def _f(v):
    """Parse a float-ish value; '' / None -> None."""
    if v in (None, ""):
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _i(v):
    if v in (None, ""):
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _went_dark_since(phone, now=None):
    """Return the datetime the phone likely went dark, else None.

    A phone is "dark" if it is armed AND we have a last heartbeat AND the gap
    since it exceeds max(interval * WENT_DARK_MULTIPLE, floor). We return the
    last-seen time (so the UI can say "last seen at ..."). A phone that never
    reported a heartbeat is NOT considered dark (we have nothing to compare)."""
    now = now or timezone.now()
    if not phone.armed or not phone.last_heartbeat_at:
        return None
    interval = phone.heartbeat_interval_min or 10
    threshold = max(interval * WENT_DARK_MULTIPLE, WENT_DARK_FLOOR_MIN)
    if (now - phone.last_heartbeat_at) > timedelta(minutes=threshold):
        return phone.last_heartbeat_at
    return None


def _photo_url(request, ev):
    if ev.photo:
        try:
            return request.build_absolute_uri(ev.photo.url)
        except Exception:
            return None
    return None


def _lost_phone_payload(request, phone, viewer_is_owner):
    """The "My lost phone" view data. Coarse + honest."""
    now = timezone.now()
    dark_since = _went_dark_since(phone, now)
    last_loc = None
    if phone.last_lat is not None and phone.last_lng is not None:
        last_loc = {"lat": phone.last_lat, "lng": phone.last_lng,
                    "at": phone.last_heartbeat_at.isoformat()
                    if phone.last_heartbeat_at else None}
    trail = [{"lat": h.lat, "lng": h.lng, "at": h.at.isoformat()}
             for h in phone.heartbeats.all()[:TRAIL_LIMIT]
             if h.lat is not None and h.lng is not None]
    events = [{"kind": e.kind, "data": e.data,
               "at": (e.at or e.created_at).isoformat(),
               "photo_url": _photo_url(request, e)}
              for e in phone.captured_events.all()[:TRAIL_LIMIT]]
    sim = None
    sc = phone.captured_events.filter(kind="sim_change").order_by("-created_at").first()
    if sc:
        sim = dict(sc.data or {})
        sim["at"] = (sc.at or sc.created_at).isoformat()
    return {
        "imei1": phone.imei1,
        "imei2": phone.imei2,
        "model": phone.model_name,
        "armed": phone.armed,
        "lost_mode": phone.lost_mode,
        "frozen": sec.is_frozen(phone, now),
        "went_dark_at": dark_since.isoformat() if dark_since else None,
        "last_location": last_loc,
        "trail": trail,
        "events": events,
        "sim_change": sim,
        "status": phone.status,
        "viewer": "owner" if viewer_is_owner else "circle",
    }


# --------------------------------------------------------------------------
# POST security/heartbeat  — the native engine phones home (offline-first)
# --------------------------------------------------------------------------

class HeartbeatView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        phone = _primary_phone(request.user)
        now = timezone.now()
        lat = _f(request.data.get("lat"))
        lng = _f(request.data.get("lng"))
        battery = _i(request.data.get("battery"))
        network = str(request.data.get("network", ""))[:16]

        PhoneHeartbeat.objects.create(
            phone=phone, lat=lat, lng=lng, battery=battery, network=network)
        PhoneHeartbeat.prune(phone)

        phone.last_heartbeat_at = now
        if lat is not None and lng is not None:
            phone.last_lat = lat
            phone.last_lng = lng
        # Phone is alive again — clear the went-dark latch so a future gap can
        # re-alert.
        phone.went_dark_alerted = False
        phone.save(update_fields=["last_heartbeat_at", "last_lat", "last_lng",
                                  "went_dark_alerted", "updated_at"])

        # Return the current actionable state so the device can react even if it
        # goes offline right after.
        return Response({
            "lost_mode": phone.lost_mode,
            "lost_message": phone.lost_message,
            "lost_contact": phone.lost_contact,
            "armed": phone.armed,
            "frozen": sec.is_frozen(phone, now),
            "heartbeat_interval_min": phone.heartbeat_interval_min,
        })


# --------------------------------------------------------------------------
# POST security/events  — store-and-forward captured evidence
#   JSON:       {events:[{kind,data,at}]}
#   multipart:  file=<photo> + kind + data(JSON string)  (single intruder photo)
# --------------------------------------------------------------------------

class CapturedEventsView(APIView):
    permission_classes = [IsAuthenticated]
    parser_classes = [JSONParser, MultiPartParser, FormParser]
    VALID = {k for k, _ in CapturedEvent.KINDS}
    # kind -> theft signal to register (freeze). Not every kind freezes.
    SIGNAL_FOR = {"sim_change": "sim_change", "airplane_guard": "snatch"}

    def _parse_at(self, raw):
        if not raw:
            return timezone.now()
        from django.utils.dateparse import parse_datetime
        try:
            dt = parse_datetime(raw) if isinstance(raw, str) else raw
            return dt or timezone.now()
        except Exception:
            return timezone.now()

    def _store(self, phone, kind, data, at, photo=None):
        return CapturedEvent.objects.create(
            phone=phone, kind=kind, data=data or {}, at=at, photo=photo)

    def post(self, request):
        phone = _primary_phone(request.user)
        now = timezone.now()
        created, signalled = [], set()

        uploaded = request.FILES.get("file") or request.FILES.get("photo")
        if uploaded is not None:
            # multipart single-event variant (intruder photo, usually)
            kind = str(request.data.get("kind", "intruder_photo"))
            if kind not in self.VALID:
                return Response({"ok": False, "reason": "bad_kind"},
                                status=status.HTTP_400_BAD_REQUEST)
            raw = request.data.get("data")
            if isinstance(raw, str):
                import json
                try:
                    raw = json.loads(raw)
                except Exception:
                    raw = {}
            ev = self._store(phone, kind, raw or {},
                             self._parse_at(request.data.get("at")), photo=uploaded)
            created.append(ev)
            if kind in self.SIGNAL_FOR:
                signalled.add(self.SIGNAL_FOR[kind])
        else:
            events = request.data.get("events") or []
            if not isinstance(events, list):
                return Response({"ok": False, "reason": "events_not_list"},
                                status=status.HTTP_400_BAD_REQUEST)
            for e in events:
                kind = str((e or {}).get("kind", ""))
                if kind not in self.VALID:
                    continue
                ev = self._store(phone, kind, (e or {}).get("data") or {},
                                 self._parse_at((e or {}).get("at")))
                created.append(ev)
                if kind in self.SIGNAL_FOR:
                    signalled.add(self.SIGNAL_FOR[kind])

        if not created:
            return Response({"ok": False, "reason": "no_valid_events"},
                            status=status.HTTP_400_BAD_REQUEST)

        # A SIM change / airplane-guard / snatch freezes the handset.
        for signal in signalled:
            sec.register_signal(phone, signal, now)
        if signalled:
            phone.save()

        # Alert owner + circle ONCE per batch.
        kinds = sorted({e.kind for e in created})
        _notify_owner_and_circle(
            request.user,
            "New evidence captured on your phone",
            f"Assisto stored {len(created)} evidence item(s) "
            f"({', '.join(kinds)}) from your protected phone. "
            + ("Sensitive actions are now frozen for safety. "
               if signalled else "")
            + "Open Assisto > My lost phone to review.",
            meta={"kinds": kinds, "count": len(created),
                  "frozen": bool(signalled), "at": now.isoformat()})

        return Response({
            "ok": True,
            "stored": len(created),
            "frozen": sec.is_frozen(phone, now),
            "frozen_until": phone.frozen_until.isoformat() if phone.frozen_until else None,
        })


# --------------------------------------------------------------------------
# POST security/lost-mode  {on:bool, message?, contact?, reward?}
#   ON  = protective, no delay.
#   OFF = must go through security/action ('turn_off_lost') -> 409 here.
# --------------------------------------------------------------------------

class LostModeView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        phone = _primary_phone(request.user)
        on = request.data.get("on")
        on = bool(on) if isinstance(on, bool) else str(on).lower() in ("1", "true", "yes", "on")

        if not on:
            # Turning OFF lost mode is the sensitive 'turn_off_lost' action; it
            # cannot be done directly here (a thief must not be able to clear it).
            return Response(
                {"ok": False, "reason": "use_security_action",
                 "action": "turn_off_lost", "endpoint": "security/action",
                 "detail": "Turning off lost mode is a protected action: POST "
                           "security/action {action:'turn_off_lost', pin, lat, lng}."},
                status=status.HTTP_409_CONFLICT)

        now = timezone.now()
        phone.lost_mode = True
        if request.data.get("message") is not None:
            phone.lost_message = str(request.data.get("message"))[:2000]
        if request.data.get("contact") is not None:
            phone.lost_contact = str(request.data.get("contact"))[:120]
        if request.data.get("reward") is not None:
            phone.lost_reward = str(request.data.get("reward"))[:160]
        if phone.lost_since is None:
            phone.lost_since = now
        phone.save()

        when = now.strftime("%Y-%m-%d %H:%M")
        _notify_owner_and_circle(
            request.user,
            "Lost mode turned on",
            f"Lost mode was turned on for your phone around {when}. The device "
            f"will show your contact message and keep reporting its location. "
            f"Open Assisto > My lost phone to help track it.",
            route="security/lost-phone",
            meta={"lost_since": phone.lost_since.isoformat()})

        return Response({"ok": True, "lost_mode": True,
                         "lost_since": phone.lost_since.isoformat()})


# --------------------------------------------------------------------------
# GET security/lost-phone  — the "My lost phone" view
#   Owner always. A circle member (accepted) OR the family_approver may read it
#   ONLY while lost_mode OR went-dark is active (so family can help track).
# --------------------------------------------------------------------------

class LostPhoneView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        pid = request.query_params.get("phone_id")
        if pid:
            phone = ProtectedPhone.objects.filter(pk=pid).first()
            if phone is None:
                return Response({"ok": False, "reason": "not_found"},
                                status=status.HTTP_404_NOT_FOUND)
        else:
            phone = ProtectedPhone.objects.filter(
                owner=request.user).order_by("created_at").first()
            if phone is None:
                phone = _primary_phone(request.user)

        is_owner = phone.owner_id == request.user.id
        if not is_owner:
            # Family-help path: must be an accepted circle member OR the
            # family_approver of THIS phone, AND the phone must actually be
            # lost/dark right now (so this is never a general tracking backdoor).
            now = timezone.now()
            active = phone.lost_mode or (_went_dark_since(phone, now) is not None)
            if not active:
                return Response({"ok": False, "reason": "not_active"},
                                status=status.HTTP_403_FORBIDDEN)
            is_member = CircleMember.objects.filter(
                user=phone.owner, peer_user=request.user, state="accepted").exists()
            is_approver = (phone.family_approver_id is not None
                           and phone.family_approver.peer_user_id == request.user.id)
            if not (is_member or is_approver):
                return Response({"ok": False, "reason": "forbidden"},
                                status=status.HTTP_403_FORBIDDEN)

        return Response(_lost_phone_payload(request, phone, is_owner))


# --------------------------------------------------------------------------
# GET security/event/<id>/photo  — owner-only evidence photo stream
# --------------------------------------------------------------------------

class CapturedPhotoView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        ev = CapturedEvent.objects.filter(pk=pk).first()
        if ev is None or ev.phone.owner_id != request.user.id or not ev.photo:
            raise Http404
        return FileResponse(ev.photo.open("rb"))


# ==========================================================================
# RECOVERY HELPERS  (/api/v1/recovery/...)  — mostly text; auth required.
# NEVER fabricate data: unknown values are left as clear placeholders.
# ==========================================================================

def _vault_sims(user):
    """Best-effort old SIM numbers from the user's document vault, else []. We
    look for SIM/phone numbers stored in a vault doc's structured details; if
    none, we return [] and the draft prints a blank placeholder (honest)."""
    try:
        from .models import Document
    except Exception:
        return []
    out = []
    for d in Document.objects.filter(user=user):
        det = d.details or {}
        for k, v in det.items():
            kl = str(k).lower()
            if ("sim" in kl or "msisdn" in kl or "mobile" in kl
                    or "phone" in kl) and v:
                out.append(str(v))
    return out


def _when_place(phone):
    """(when_text, place_text) from last_location + went_dark — honest/coarse."""
    ds = _went_dark_since(phone)
    when = ds.strftime("%Y-%m-%d %H:%M") if ds else (
        phone.lost_since.strftime("%Y-%m-%d %H:%M") if phone.lost_since else "")
    place = ""
    if phone.last_lat is not None and phone.last_lng is not None:
        place = f"{phone.last_lat:.5f}, {phone.last_lng:.5f}"
    return when, place


class GdDraftView(APIView):
    """GET recovery/gd-draft -> {text}: a ready-to-paste General Diary draft."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        lang = req_lang(request)
        phone = _primary_phone(request.user)
        sims = _vault_sims(request.user)
        when, place = _when_place(phone)
        name = getattr(request.user, "name", "") or ""

        imei1 = phone.imei1 or pick(lang, "(জানা নেই)", "(unknown)")
        imei2 = phone.imei2 or pick(lang, "(জানা নেই)", "(নেই)" if False else "(none)")
        model = phone.model_name or pick(lang, "(জানা নেই)", "(unknown)")
        sim_line = ", ".join(sims) if sims else pick(
            lang, "(পুরোনো সিম নম্বর এখানে লিখুন)", "(write your old SIM number(s) here)")
        when = when or pick(lang, "(আনুমানিক সময় লিখুন)", "(write the approximate time)")
        place = place or pick(lang, "(স্থান লিখুন)", "(write the place)")

        if lang == "en":
            text = (
                f"To\nThe Officer-in-Charge\n[Police Station]\n\n"
                f"Subject: General Diary for a lost/stolen mobile phone\n\n"
                f"Sir,\n"
                f"I, {name or '[your name]'}, respectfully state that my mobile "
                f"phone went missing on/around {when} near {place}.\n\n"
                f"Phone details:\n"
                f"  Model: {model}\n"
                f"  IMEI 1: {imei1}\n"
                f"  IMEI 2: {imei2}\n"
                f"  SIM number(s): {sim_line}\n\n"
                f"The phone was protected by the Assisto app. Server-side evidence "
                f"(a recent location trail and any SIM-change record) is available "
                f"and can be produced on request.\n\n"
                f"I request a General Diary be recorded so I can inform my mobile "
                f"operator and request an IMEI block.\n\n"
                f"Yours faithfully,\n{name or '[your name]'}\n"
                f"[your phone] [date]")
        else:
            text = (
                f"বরাবর\nভারপ্রাপ্ত কর্মকর্তা\n[থানার নাম]\n\n"
                f"বিষয়: হারানো/চুরি হওয়া মোবাইল ফোন সম্পর্কে সাধারণ ডায়েরি\n\n"
                f"জনাব,\n"
                f"আমি {name or '[আপনার নাম]'} বিনীতভাবে জানাচ্ছি যে, আমার মোবাইল "
                f"ফোনটি আনুমানিক {when} সময়ে {place} এলাকার কাছে হারিয়ে যায়।\n\n"
                f"ফোনের বিবরণ:\n"
                f"  মডেল: {model}\n"
                f"  IMEI ১: {imei1}\n"
                f"  IMEI ২: {imei2}\n"
                f"  সিম নম্বর: {sim_line}\n\n"
                f"ফোনটি Assisto অ্যাপ দিয়ে সুরক্ষিত ছিল। সার্ভারে সংরক্ষিত প্রমাণ "
                f"(সাম্প্রতিক অবস্থানের তথ্য ও সিম পরিবর্তনের রেকর্ড) প্রয়োজনে "
                f"সরবরাহ করা সম্ভব।\n\n"
                f"অনুগ্রহ করে একটি সাধারণ ডায়েরি লিপিবদ্ধ করুন, যাতে আমি আমার "
                f"মোবাইল অপারেটরকে জানিয়ে IMEI ব্লক করার অনুরোধ করতে পারি।\n\n"
                f"নিবেদক,\n{name or '[আপনার নাম]'}\n"
                f"[আপনার ফোন] [তারিখ]")
        return Response({"text": text})


class SpLetterView(APIView):
    """GET recovery/sp-letter -> {text}: escalation letter to the District SP."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        lang = req_lang(request)
        phone = _primary_phone(request.user)
        when, place = _when_place(phone)
        name = getattr(request.user, "name", "") or ""
        gd = phone.gd_number or pick(lang, "(জিডি নম্বর লিখুন)", "(write your GD number)")
        model = phone.model_name or pick(lang, "(জানা নেই)", "(unknown)")
        imei1 = phone.imei1 or pick(lang, "(জানা নেই)", "(unknown)")

        if lang == "en":
            text = (
                f"To\nThe Superintendent of Police (SP)\n[District]\n\n"
                f"Subject: Request for assistance recovering a stolen mobile phone "
                f"(GD No. {gd})\n\n"
                f"Respected Sir,\n"
                f"With reference to General Diary No. {gd}, my phone ({model}, "
                f"IMEI {imei1}) was lost/stolen on/around {when} near {place}. "
                f"Despite filing the GD, the phone has not yet been recovered.\n\n"
                f"The device is protected by the Assisto app, which has preserved a "
                f"recent location trail and SIM-change evidence. I respectfully "
                f"request your office to direct the concerned station to pursue the "
                f"IMEI block with the operator and to make use of the available "
                f"location evidence.\n\n"
                f"I am ready to provide all evidence and cooperate fully.\n\n"
                f"Yours faithfully,\n{name or '[your name]'}\n[your phone] [date]")
        else:
            text = (
                f"বরাবর\nপুলিশ সুপার (এসপি)\n[জেলা]\n\n"
                f"বিষয়: চুরি হওয়া মোবাইল ফোন উদ্ধারে সহায়তার আবেদন "
                f"(জিডি নং {gd})\n\n"
                f"শ্রদ্ধেয় মহোদয়,\n"
                f"সাধারণ ডায়েরি নং {gd} এর সূত্রে জানাচ্ছি যে, আমার ফোনটি "
                f"({model}, IMEI {imei1}) আনুমানিক {when} সময়ে {place} এলাকার "
                f"কাছে হারিয়ে/চুরি হয়ে যায়। জিডি করার পরও এখনো ফোনটি উদ্ধার "
                f"হয়নি।\n\n"
                f"ফোনটি Assisto অ্যাপ দিয়ে সুরক্ষিত এবং অ্যাপে সাম্প্রতিক "
                f"অবস্থানের তথ্য ও সিম পরিবর্তনের প্রমাণ সংরক্ষিত আছে। অনুগ্রহ "
                f"করে সংশ্লিষ্ট থানাকে অপারেটরের মাধ্যমে IMEI ব্লক করার এবং "
                f"সংরক্ষিত অবস্থানের তথ্য কাজে লাগানোর নির্দেশ দিন।\n\n"
                f"আমি সকল প্রমাণ সরবরাহ করতে এবং সম্পূর্ণ সহযোগিতা করতে প্রস্তুত।\n\n"
                f"নিবেদক,\n{name or '[আপনার নাম]'}\n[আপনার ফোন] [তারিখ]")
        return Response({"text": text})


class EvidencePdfView(APIView):
    """GET recovery/evidence.pdf -> a PDF evidence pack. Owner-only. Reuses the
    same reportlab mechanism as MoneyReportExportView; falls back to text."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        phone = _primary_phone(request.user)  # owner's own primary phone
        when, place = _when_place(phone)
        lines = [
            "ASSISTO — LOST / STOLEN PHONE EVIDENCE PACK",
            f"Generated: {timezone.now().strftime('%Y-%m-%d %H:%M %Z')}",
            "",
            f"Owner: {getattr(request.user, 'name', '') or ''}",
            f"Model: {phone.model_name or '(unknown)'}",
            f"IMEI 1: {phone.imei1 or '(unknown)'}",
            f"IMEI 2: {phone.imei2 or '(unknown)'}",
            f"GD number: {phone.gd_number or '(not filed)'}",
            f"Status: {phone.status}   Armed: {phone.armed}   Lost mode: {phone.lost_mode}",
            f"Approx. last seen: {when or '(unknown)'}  at  {place or '(unknown)'}",
            "",
            "LOCATION TRAIL (recent heartbeats):",
        ]
        trail = [h for h in phone.heartbeats.all()[:TRAIL_LIMIT]
                 if h.lat is not None and h.lng is not None]
        if trail:
            for h in trail:
                lines.append(f"  {h.at.strftime('%Y-%m-%d %H:%M')}  "
                             f"{h.lat:.5f}, {h.lng:.5f}  "
                             f"(battery {h.battery if h.battery is not None else '?'}%, "
                             f"{h.network or '?'})")
        else:
            lines.append("  (no location heartbeats recorded)")
        lines += ["", "CAPTURED EVENTS:"]
        evs = list(phone.captured_events.all()[:TRAIL_LIMIT])
        if evs:
            for e in evs:
                t = (e.at or e.created_at).strftime("%Y-%m-%d %H:%M")
                lines.append(f"  {t}  {e.kind}  {e.data or {}}")
        else:
            lines.append("  (no captured events)")
        lines += ["", "THEFT SIGNALS:"]
        for s in (phone.signals or []):
            lines.append(f"  {s.get('at', '?')}  {s.get('kind', '?')}")
        if not (phone.signals or []):
            lines.append("  (none)")
        lines += ["", "This pack is generated from Assisto's own server records. "
                      "Values marked (unknown) were never captured — not withheld."]

        try:
            import io
            from reportlab.pdfgen import canvas
            buf = io.BytesIO()
            c = canvas.Canvas(buf)
            y = 800
            for ln in lines:
                c.drawString(40, y, ln[:110])
                y -= 16
                if y < 40:
                    c.showPage()
                    y = 800
            c.showPage()
            c.save()
            resp = HttpResponse(buf.getvalue(), content_type="application/pdf")
            resp["Content-Disposition"] = 'attachment; filename="assisto-evidence.pdf"'
            return resp
        except Exception:
            return HttpResponse("\n".join(lines), content_type="text/plain")


class PoliceStationsView(APIView):
    """GET recovery/police-stations?lat&lng -> nearest police stations. Reuses
    the curated nearby dataset (source: 'mock'); honest about being coarse. If
    no location is supplied we return available:false (never fake stations)."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        lang = req_lang(request)
        lat = _f(request.query_params.get("lat"))
        lng = _f(request.query_params.get("lng"))
        if lat is None or lng is None:
            return Response({"available": False,
                             "reason": "no_location",
                             "message": pick(lang,
                                "অবস্থান দিলে কাছের থানা দেখানো যাবে।",
                                "Share a location to see nearby police stations.")})
        # Use the curated OFFLINE dataset (core.logic.nearby, source "mock") so
        # this never makes a live network call and never fakes ratings. The live
        # Places/OSM path (core.nearby) is key-gated and not used here.
        try:
            from .logic import nearby as nb
        except Exception:
            nb = None
        if nb is None:
            return Response({"available": False, "stations": []})
        results, source = nb.search(category="police", lat=lat, lon=lng,
                                    sort="distance", limit=10)
        stations = [{
            "name": p.get("name_en") if lang == "en" else p.get("name_bn"),
            "lat": p.get("lat"), "lng": p.get("lon"),
            "phone": p.get("phone"),
            "distance_m": p.get("distance_m"),
            "directions": p.get("directions"),
        } for p in results]
        return Response({
            "available": bool(stations),
            "source": source,  # 'mock' -> app shows the honest "live when Maps key" banner
            "stations": stations,
        })
