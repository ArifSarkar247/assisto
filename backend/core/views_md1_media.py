"""md1 — My Circle E2E media blob API (ciphertext only; see core/circle_blobs).

  GET    /circle/media/limits                 -> owner-editable caps for the phone
  POST   /circle/media/blobs {kind,size,sha256} -> {ref, offset:0, chunk_bytes}
  GET    /circle/media/blobs/<ref>            -> {received, size, complete} (owner)
  PUT    /circle/media/blobs/<ref>?offset=N   -> append one raw chunk (owner)
  POST   /circle/media/blobs/<ref>/finish     -> verify size + sha256 (owner)
  DELETE /circle/media/blobs/<ref>            -> cancel an unsent upload (owner)
  GET    /circle/media/blobs/<ref>/url        -> 10-min signed link (participants)
  GET    /circle/media/dl/<ref>?u=&e=&s=      -> the ciphertext (signed, no auth)
"""
import os

from django.conf import settings
from django.db import transaction
from django.http import FileResponse, Http404, HttpResponse
from django.utils import timezone
from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import circle_blobs as CB
from .i18n import req_lang
from .models import CircleMediaBlob


def _nf():
    return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)


def _refuse(request, code, http=status.HTTP_400_BAD_REQUEST):
    return Response({"detail": CB.reason_text(code, req_lang(request)),
                     "reason": code}, status=http)


def _mine(request, ref):
    if not CB.valid_ref(ref):
        return None
    return CircleMediaBlob.objects.filter(ref=ref, owner=request.user).first()


def _state(b):
    return {"ref": b.ref, "size": b.size, "received": b.received,
            "complete": b.complete, "chunk_bytes": 512 * 1024}


class MediaLimitsView(APIView):
    def get(self, request):
        return Response(CB.public_limits())


class MediaBlobsView(APIView):
    def post(self, request):
        d = request.data or {}
        kind = str(d.get("kind", ""))
        try:
            size = int(d.get("size", 0))
        except (TypeError, ValueError):
            size = 0
        sha = str(d.get("sha256", "")).lower()
        if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
            return Response({"detail": "bad sha256"},
                            status=status.HTTP_400_BAD_REQUEST)
        why = CB.quota_check(request.user, kind, size)
        if why:
            http = (status.HTTP_429_TOO_MANY_REQUESTS
                    if why in ("daily_quota", "rate_limit")
                    else status.HTTP_413_REQUEST_ENTITY_TOO_LARGE
                    if why == "too_big" else status.HTTP_400_BAD_REQUEST)
            return _refuse(request, why, http)
        ref = CB.new_ref()
        b = CircleMediaBlob.objects.create(ref=ref, owner=request.user,
                                           kind=kind, size=size, sha256=sha)
        os.makedirs(os.path.dirname(CB.path_for(ref)), exist_ok=True)
        open(CB.path_for(ref), "wb").close()
        return Response(_state(b), status=status.HTTP_201_CREATED)


class MediaBlobView(APIView):
    def get(self, request, ref):
        b = _mine(request, ref)
        return _nf() if b is None else Response(_state(b))

    def put(self, request, ref):
        b = _mine(request, ref)
        if b is None:
            return _nf()
        if b.complete:
            return Response(_state(b))
        try:
            n = int(request.META.get("CONTENT_LENGTH") or 0)
            offset = int(request.query_params.get("offset", -1))
        except (TypeError, ValueError):
            return Response({"detail": "bad offset"},
                            status=status.HTTP_400_BAD_REQUEST)
        if n <= 0 or n > CB.CHUNK_MAX:
            return Response({"detail": "chunk size"},
                            status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE)
        body = request._request.body  # raw bytes (never request.data)
        if len(body) != n:
            return Response({"detail": "short body"},
                            status=status.HTTP_400_BAD_REQUEST)
        with transaction.atomic():
            b = CircleMediaBlob.objects.select_for_update().get(pk=b.pk)
            if offset != b.received:
                # resume: the phone re-reads the offset and continues
                return Response(_state(b), status=status.HTTP_409_CONFLICT)
            if b.received + n > b.size:
                return Response({"detail": "over declared size"},
                                status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE)
            p = CB.path_for(b.ref)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "r+b" if os.path.exists(p) else "wb") as f:
                f.seek(offset)
                f.write(body)
                f.truncate(offset + n)
            b.received = offset + n
            b.save(update_fields=["received"])
        return Response(_state(b))

    def delete(self, request, ref):
        b = _mine(request, ref)
        if b is None:
            return _nf()
        from .models import CircleMessage
        if CircleMessage.objects.filter(blob_ref=b.ref).exists():
            return Response({"detail": "in use"},
                            status=status.HTTP_409_CONFLICT)
        b.delete()
        return Response({"ok": True})


class MediaBlobFinishView(APIView):
    def post(self, request, ref):
        b = _mine(request, ref)
        if b is None:
            return _nf()
        if b.complete:
            return Response({**_state(b), "ok": True})
        p = CB.path_for(b.ref)
        if b.received != b.size or not os.path.isfile(p) or \
                os.path.getsize(p) != b.size:
            return Response({**_state(b), "ok": False, "detail": "incomplete"},
                            status=status.HTTP_409_CONFLICT)
        if CB.sha256_file(p) != b.sha256:
            # corrupted in transit: start over (the phone re-uploads)
            b.received = 0
            b.save(update_fields=["received"])
            open(p, "wb").close()
            return Response({**_state(b), "ok": False, "detail": "sha256"},
                            status=status.HTTP_409_CONFLICT)
        b.complete = True
        b.completed_at = timezone.now()
        b.save(update_fields=["complete", "completed_at"])
        return Response({**_state(b), "ok": True})


class MediaBlobUrlView(APIView):
    def get(self, request, ref):
        if not CB.valid_ref(ref):
            return _nf()
        b = CircleMediaBlob.objects.filter(ref=ref, complete=True).first()
        if b is None:
            return _nf()
        if b.owner_id != request.user.id and not CB.can_access(request.user, ref):
            return _nf()   # never reveal that the blob exists
        return Response({"url": CB.signed_url(ref, request.user.id),
                         "expires_in": CB.URL_TTL_S, "size": b.size,
                         "sha256": b.sha256})


class MediaBlobDownloadView(APIView):
    """Signed, unauthenticated (an http GET from the phone's downloader).
    404 on any bad/expired signature — never says whether a blob exists."""
    permission_classes = [AllowAny]
    authentication_classes = []
    throttle_classes = []

    def get(self, request, ref):
        q = request.query_params
        if not CB.valid_ref(ref) or not CB.verify(ref, q.get("u"), q.get("e"),
                                                  q.get("s")):
            raise Http404
        b = CircleMediaBlob.objects.filter(ref=ref, complete=True).first()
        p = CB.path_for(ref)
        if b is None or not os.path.isfile(p):
            raise Http404
        try:
            CB.mark_downloaded(b, int(q.get("u")))
        except (TypeError, ValueError):
            pass
        if getattr(settings, "CIRCLE_BLOB_X_ACCEL", False):
            resp = HttpResponse(content_type="application/octet-stream")
            resp["X-Accel-Redirect"] = CB.ACCEL_PREFIX + CB.rel_name(ref)
        else:
            resp = FileResponse(open(p, "rb"),
                                content_type="application/octet-stream")
            resp["Content-Length"] = str(os.path.getsize(p))
        resp["Cache-Control"] = "private, no-store"
        resp["X-Content-Type-Options"] = "nosniff"
        resp["Content-Disposition"] = "attachment"
        return resp
