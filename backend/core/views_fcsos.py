"""fcsos — Family Care v3 SOS sender / receiver endpoints (all free, own
data only; logic in core/family_sos_v3.py)."""
from django.http import FileResponse
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import family_sos_v3 as SV


class SosLocationView(APIView):
    """POST /family/sos/location {lat, lng} — live position while SOS is on."""
    def post(self, request):
        d = request.data or {}
        out = SV.post_location(request.user, d.get("lat"), d.get("lng"))
        code = status.HTTP_200_OK if out.get("ok") else status.HTTP_409_CONFLICT
        if out.get("reason") == "bad_location":
            code = status.HTTP_400_BAD_REQUEST
        return Response(out, status=code)


class SosAudioView(APIView):
    """POST /family/sos/audio {audio_b64, sec} — the 30 s recording."""
    def post(self, request):
        d = request.data or {}
        out = SV.save_audio(request.user, d.get("audio_b64"), d.get("sec"))
        if out.get("ok"):
            return Response(out)
        code = (status.HTTP_409_CONFLICT if out.get("reason") == "no_active_sos"
                else status.HTTP_400_BAD_REQUEST)
        return Response(out, status=code)


class SosStatusView(APIView):
    """GET /family/sos/status — the sender's active SOS + who is going."""
    def get(self, request):
        return Response(SV.sender_status(request.user))


class SosSettingsView(APIView):
    """GET/POST /family/sos/settings {share_info} — share blood group and
    emergency contacts with family during an SOS (off by default)."""
    def get(self, request):
        return Response(SV.get_settings(request.user))

    def post(self, request):
        v = (request.data or {}).get("share_info")
        return Response(SV.set_settings(request.user, v in (True, "true", "1", 1)))


class SosEventView(APIView):
    """GET /family/sos/event/<delivery_id> — the receiver's alarm screen."""
    def get(self, request, pk):
        out = SV.event_detail(request.user, pk)
        if out is None:
            return Response({"detail": "not_found"}, status=status.HTTP_404_NOT_FOUND)
        return Response(out)


class SosEventAudioView(APIView):
    """GET /family/sos/event/<delivery_id>/audio — the m4a (recipient/sender)."""
    def get(self, request, pk):
        f, why = SV.audio_for(request.user, pk)
        if f is None:
            return Response({"detail": why}, status=status.HTTP_404_NOT_FOUND)
        return FileResponse(f, content_type="audio/mp4")
