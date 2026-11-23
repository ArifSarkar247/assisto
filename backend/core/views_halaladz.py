"""halaladz (owner order 23 Nov) — HalalAdz link / notify / support routes.

App (token auth, under /api/v1/):
  GET  halaladz/status            -> {enabled, linked, account, official, support_unread}
  POST halaladz/link {code}       -> {linked: true, account}   (server calls HalalAdz)
  POST halaladz/unlink            -> {linked: false}
  GET  halaladz/support           -> {ticket, messages}         (marks replies read)
  POST halaladz/support {text, photo_b64 | voice_b64 + duration_ms}
Owner admin (active superuser):
  GET  halaladz/owner/inbox[?status=open|resolved|all]
  GET  halaladz/owner/thread/<id>   (marks it read for the owner)
  POST halaladz/owner/thread/<id>/reply {text}
  POST halaladz/owner/thread/<id>/resolve {resolved}
HalalAdz server (HMAC, no token): POST /api/integrations/halaladz/notify

Everything except the owner inbox answers 503 {"detail":"disabled"} while
settings.HALALADZ_SHARED_SECRET is empty.
"""
import json
import uuid

from django.core.files.base import ContentFile
from django.db import IntegrityError, transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import halaladz as HZ
from .i18n import req_lang
from .models import HalalAdzEvent, HalalAdzLink, SupportMessage, SupportTicket

NOTIFY_MAX_BYTES = 16 * 1024


def _off(request):
    return Response({"detail": "disabled", "enabled": False,
                     "message": HZ.msg("disabled", req_lang(request))},
                    status=status.HTTP_503_SERVICE_UNAVAILABLE)


def _err(request, reason, code):
    return Response({"detail": reason, "message": HZ.msg(reason, req_lang(request))},
                    status=code)


def _account(link):
    if link is None:
        return None
    return {"hz_account_id": link.hz_account_id, "display_name": link.display_name,
            "linked_at": link.linked_at.isoformat() if link.linked_at else None}


class HalalAdzStatusView(APIView):
    def get(self, request):
        if not HZ.enabled():
            return Response({"enabled": False, "linked": False})
        link = HalalAdzLink.objects.filter(user=request.user).first()
        t = HZ.thread_for(request.user, create=False)
        return Response({"enabled": True, "linked": link is not None,
                         "account": _account(link),
                         "official": HZ.official_links(),
                         "support_unread": t.unread_user if t else 0,
                         "support_resolved": bool(t and t.resolved)})


class HalalAdzLinkView(APIView):
    def post(self, request):
        if not HZ.enabled():
            return _off(request)
        code = HZ.norm_code((request.data or {}).get("code"))
        if code is None:
            return _err(request, "bad_format", status.HTTP_400_BAD_REQUEST)
        if not (HZ.rate_ok(request.user, "link10", HZ.LINK_PER_10MIN, 600)
                and HZ.rate_ok(request.user, "linkday", HZ.LINK_PER_DAY, 86400)):
            return _err(request, "rate_limited", status.HTTP_429_TOO_MANY_REQUESTS)
        try:
            acc = HZ.request_link(request.user, code)
        except HZ.LinkError as e:
            return _err(request, e.reason, e.status)
        other = (HalalAdzLink.objects.filter(hz_account_id=acc["hz_account_id"])
                 .exclude(user=request.user).exists())
        if other:
            return _err(request, "taken", status.HTTP_409_CONFLICT)
        link, _ = HalalAdzLink.objects.update_or_create(
            user=request.user,
            defaults={"hz_account_id": acc["hz_account_id"],
                      "display_name": acc["display_name"]})
        return Response({"linked": True, "account": _account(link)})


class HalalAdzUnlinkView(APIView):
    def post(self, request):
        if not HZ.enabled():
            return _off(request)
        HalalAdzLink.objects.filter(user=request.user).delete()
        return Response({"linked": False})


class HalalAdzSupportView(APIView):
    def get(self, request):
        if not HZ.enabled():
            return _off(request)
        t = HZ.thread_for(request.user, create=False)
        if t is None:
            return Response({"ticket": None, "messages": [],
                             "quick_hint": True})
        if t.unread_user:
            t.unread_user = 0
            t.save(update_fields=["unread_user"])
        msgs = list(t.messages.order_by("-id")[:200])[::-1]
        return Response({"ticket": HZ.ticket_dict(t),
                         "messages": [HZ.message_dict(m) for m in msgs]})

    def post(self, request):
        if not HZ.enabled():
            return _off(request)
        d = request.data or {}
        lang = req_lang(request)
        text = str(d.get("text") or "").strip()[:HZ.SUPPORT_TEXT_MAX]
        kind, blob, ext, dur = "", None, None, 0
        if d.get("photo_b64"):
            blob = HZ.decode_b64(d.get("photo_b64"), HZ.PHOTO_MAX_BYTES)
            ext = HZ.photo_ext(blob) if blob else None
            kind = "photo"
        elif d.get("voice_b64"):
            blob = HZ.decode_b64(d.get("voice_b64"), HZ.VOICE_MAX_BYTES)
            ext = HZ.voice_ext(blob) if blob else None
            kind = "voice"
            try:
                dur = max(0, min(int(d.get("duration_ms") or 0), HZ.VOICE_MAX_MS))
            except (TypeError, ValueError):
                dur = 0
        if kind and (blob is None or ext is None):
            return Response({"detail": "bad_attachment", "message": (
                "Photo or voice file is not valid or is too big (photo 5 MB, voice 3 MB)."
                if lang == "en" else
                "ছবি বা ভয়েস ফাইলটি ঠিক নেই বা খুব বড় (ছবি ৫ MB, ভয়েস ৩ MB পর্যন্ত)।")},
                status=status.HTTP_400_BAD_REQUEST)
        if not text and not kind:
            return Response({"detail": "empty", "message": (
                "Write a message, or add a photo or voice note."
                if lang == "en" else "একটি বার্তা লিখুন, অথবা ছবি বা ভয়েস দিন।")},
                status=status.HTTP_400_BAD_REQUEST)
        if not HZ.rate_ok(request.user, "support", HZ.SUPPORT_PER_HOUR, 3600):
            return Response({"detail": "rate_limited", "message": (
                "Too many messages. Please wait a little."
                if lang == "en" else "অনেক বার্তা পাঠানো হয়েছে। একটু অপেক্ষা করুন।")},
                status=status.HTTP_429_TOO_MANY_REQUESTS)
        t = HZ.thread_for(request.user)
        m = SupportMessage(ticket=t, sender="user", author=request.user, text=text,
                           attachment_kind=kind, duration_ms=dur)
        if blob is not None:
            m.attachment.save("%s.%s" % (uuid.uuid4().hex, ext), ContentFile(blob),
                              save=False)
        m.save()
        t.unread_owner = t.unread_owner + 1
        t.resolved = False            # a new message re-opens the thread
        t.last_at = timezone.now()
        t.save(update_fields=["unread_owner", "resolved", "last_at"])
        return Response({"ticket": HZ.ticket_dict(t), "message": HZ.message_dict(m)},
                        status=status.HTTP_201_CREATED)


# ------------------------------------------------------------------ owner
def _owner_only(request):
    from . import push
    if not push.is_owner_admin(request.user):
        return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
    return None


def inbox_rows(st="open", limit=200):
    qs = SupportTicket.objects.filter(topic=HZ.TOPIC).select_related("user")
    if st == "open":
        qs = qs.filter(resolved=False)
    elif st == "resolved":
        qs = qs.filter(resolved=True)
    rows = list(qs.order_by("-unread_owner", "-last_at", "-id")[:limit])
    return rows


class HalalAdzOwnerInboxView(APIView):
    def get(self, request):
        denied = _owner_only(request)
        if denied is not None:
            return denied
        st = request.query_params.get("status") or "open"
        rows = inbox_rows(st if st in ("open", "resolved", "all") else "open")
        total_unread = sum(SupportTicket.objects.filter(topic=HZ.TOPIC)
                           .values_list("unread_owner", flat=True))
        return Response({"results": [HZ.ticket_dict(t, with_user=True) for t in rows],
                         "unread_total": total_unread,
                         "quick_replies": [{"bn": bn, "en": en}
                                           for bn, en in HZ.QUICK_REPLIES]})


def _ticket(pk):
    return SupportTicket.objects.filter(pk=pk, topic=HZ.TOPIC).select_related("user").first()


class HalalAdzOwnerThreadView(APIView):
    def get(self, request, pk):
        denied = _owner_only(request)
        if denied is not None:
            return denied
        t = _ticket(pk)
        if t is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        if t.unread_owner:
            t.unread_owner = 0
            t.save(update_fields=["unread_owner"])
        return Response({"ticket": HZ.ticket_dict(t, with_user=True),
                         "messages": [HZ.message_dict(m) for m in t.messages.all()]})


class HalalAdzOwnerReplyView(APIView):
    def post(self, request, pk):
        denied = _owner_only(request)
        if denied is not None:
            return denied
        t = _ticket(pk)
        if t is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        m = HZ.owner_reply(t, request.user, (request.data or {}).get("text"))
        if m is None:
            return Response({"detail": "empty"}, status=status.HTTP_400_BAD_REQUEST)
        return Response({"ticket": HZ.ticket_dict(t), "message": HZ.message_dict(m)},
                        status=status.HTTP_201_CREATED)


class HalalAdzOwnerResolveView(APIView):
    def post(self, request, pk):
        denied = _owner_only(request)
        if denied is not None:
            return denied
        t = _ticket(pk)
        if t is None:
            return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)
        v = (request.data or {}).get("resolved", True)
        t.resolved = v not in (False, "false", "0", 0)
        if t.resolved:
            t.unread_owner = 0
        t.save(update_fields=["resolved", "unread_owner"])
        return Response({"ticket": HZ.ticket_dict(t)})


# ------------------------------------------------------------------ notify
class HalalAdzNotifyView(APIView):
    """POST /api/integrations/halaladz/notify — called by the HalalAdz server.
    Header X-HZ-Signature = hex HMAC-SHA256(secret, raw body). Body JSON:
    {event_id, timestamp, assisto_user_id, type?, title|title_bn/title_en,
     body|body_bn/body_en, url?}. 200 delivered | 200 duplicate | 400 bad |
    401 bad signature / stale | 404 unknown user | 503 feature off."""
    authentication_classes = []
    permission_classes = [AllowAny]
    throttle_classes = []

    def post(self, request):
        if not HZ.enabled():
            return Response({"detail": "disabled"},
                            status=status.HTTP_503_SERVICE_UNAVAILABLE)
        raw = request.body or b""
        if len(raw) > NOTIFY_MAX_BYTES:
            return Response({"detail": "too_large"},
                            status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE)
        if not HZ.verify_inbound(raw, request.META.get("HTTP_X_HZ_SIGNATURE")):
            return Response({"detail": "bad_signature"},
                            status=status.HTTP_401_UNAUTHORIZED)
        try:
            d = json.loads(raw.decode("utf-8"))
        except Exception:  # noqa: BLE001
            return Response({"detail": "bad_json"}, status=status.HTTP_400_BAD_REQUEST)
        if not isinstance(d, dict):
            return Response({"detail": "bad_json"}, status=status.HTTP_400_BAD_REQUEST)
        if not HZ.fresh(d.get("timestamp")):
            return Response({"detail": "stale"}, status=status.HTTP_401_UNAUTHORIZED)
        eid = str(d.get("event_id") or "")
        if not HZ.EVENT_ID_RE.match(eid):
            return Response({"detail": "bad_event_id"},
                            status=status.HTTP_400_BAD_REQUEST)
        title_bn, title_en = HZ._texts(d, "title")
        body_bn, body_en = HZ._texts(d, "body")
        if not title_bn:
            return Response({"detail": "bad_title"}, status=status.HTTP_400_BAD_REQUEST)
        url = ""
        if d.get("url"):
            url = HZ.safe_url(d.get("url"))
            if url is None:
                return Response({"detail": "bad_url"},
                                status=status.HTTP_400_BAD_REQUEST)
        uid = str(d.get("assisto_user_id") or "").strip()
        link = None
        if uid.isdigit():
            link = (HalalAdzLink.objects.filter(user_id=int(uid), user__is_active=True)
                    .select_related("user").first())
        hz_acc = str(d.get("hz_account_id") or "").strip()
        if link is not None and hz_acc and hz_acc != link.hz_account_id:
            link = None
        if link is None:
            # same answer for "no such user" and "not linked" — no leak
            return Response({"detail": "not_found"}, status=status.HTTP_404_NOT_FOUND)
        try:
            with transaction.atomic():
                HalalAdzEvent.objects.create(event_id=eid, user=link.user,
                                             kind=str(d.get("type") or "")[:40], url=url)
        except IntegrityError:
            return Response({"status": "duplicate", "event_id": eid})
        HZ.deliver(link.user, title_bn, title_en, body_bn, body_en, url, eid)
        return Response({"status": "delivered", "event_id": eid})

