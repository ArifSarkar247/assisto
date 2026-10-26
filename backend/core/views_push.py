"""
Push-device endpoints (FCM). Token auth + IsAuthenticated (project default).

  POST devices/register   {push_token, platform, app_version,
                           replace_token?}                     -> upsert
  POST devices/unregister {push_token}                         -> delete
  GET  push/status                                             -> {available}

Rules:
  - A push token identifies ONE app install. If the same token arrives from a
    different account (logout → login on the same phone) it is MOVED to the
    caller so the previous account's pushes stop landing on this phone.
  - At most MAX_DEVICES per user; the least-recently-seen rows are dropped.
  - The token is never echoed back or logged.
  - Works with or without Firebase credentials (registration is harmless and
    lets pushes start the moment the owner adds the key).
"""
from django.db import transaction
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import push
from .i18n import req_lang, pick
from .models import Device

MAX_DEVICES = 10
_PLATFORMS = ("android", "ios", "web")


def _token_from(request):
    return str((request.data or {}).get("push_token", "") or "").strip()


class DeviceRegisterView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        lang = req_lang(request)
        d = request.data or {}
        token = _token_from(request)
        if not token or len(token) > 255:
            return Response({"detail": pick(lang, "সঠিক push token দিন।",
                                            "A valid push token is required.")},
                            status=status.HTTP_400_BAD_REQUEST)
        platform = str(d.get("platform", "android") or "android").strip().lower()
        if platform not in _PLATFORMS:
            platform = "android"
        app_version = str(d.get("app_version", "") or "").strip()[:24]
        user = request.user
        # ring-everywhere: phone brand / model / Android SDK for the Owner
        # Admin call-delivery table (no PII). Old builds send none -> kept.
        from . import call_ack
        brand, model, sdk = call_ack.clean_facts(d)
        defaults = {"platform": platform, "app_version": app_version}
        if brand:
            defaults.update(brand=brand, model=model, sdk_int=sdk)
        with transaction.atomic():
            # Same install now belongs to this account -> drop other owners.
            moved = Device.objects.filter(push_token=token).exclude(
                user=user).delete()[0]
            # calls95: FCM rotated this install's token -> the app sends the
            # one it registered before; drop that row so rings never go to
            # (and wait on) the dead token.
            prev = str(d.get("replace_token", "") or "").strip()
            if prev and prev != token and len(prev) <= 255:
                Device.objects.filter(user=user, push_token=prev).delete()
            dev, created = Device.objects.update_or_create(
                user=user, push_token=token, defaults=defaults)
            keep = list(Device.objects.filter(user=user)
                        .order_by("-last_seen", "-id")
                        .values_list("id", flat=True)[:MAX_DEVICES])
            Device.objects.filter(user=user).exclude(id__in=keep).delete()
        # t1-ticks 1c: the peer-version banner reads User.app_version.
        from .views_t1_ticks import record_app_version
        record_app_version(user, app_version)
        return Response({"ok": True, "id": dev.id, "created": created,
                         "reassigned": bool(moved),
                         "push_available": push.is_available(),
                         # ring-everywhere: never-delivered missed calls are
                         # waiting (GET circle/calls/missed_pending)
                         "missed_pending": call_ack.pending_count(user)},
                        status=status.HTTP_201_CREATED if created
                        else status.HTTP_200_OK)


class DeviceUnregisterView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        lang = req_lang(request)
        token = _token_from(request)
        if not token:
            return Response({"detail": pick(lang, "push token দিন।",
                                            "push_token is required.")},
                            status=status.HTTP_400_BAD_REQUEST)
        n = Device.objects.filter(user=request.user, push_token=token).delete()[0]
        return Response({"ok": True, "removed": n})


class PushStatusView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        return Response({"available": push.is_available()})
