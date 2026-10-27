"""family100 — family alerts over server push: SOS from any surface, the
recipient's alert list, seen / received receipts, and 'I'm safe now'.

Every endpoint is the caller's own data only. SOS is free and never blocked
(billing.SAFETY_EXEMPT); the per-recipient caps live in core/family_alerts.py.
"""
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import family_alerts as FA


def _coord(v, lim):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return round(f, 6) if -lim <= f <= lim else None


def _summary(st):
    return {k: st.get(k, 0) for k in ("recipients", "sent", "no_device",
                                      "push_off", "held", "failed", "duplicate")}


class FamilySosView(APIView):
    """POST /family/sos {lat?, lng?, source?, client_id?} — the Emergency
    screen, Safety screen and elderly home all fire here. Returns how many
    family members were addressed so the screen can say so honestly."""
    def post(self, request):
        d = request.data or {}
        lat, lng = _coord(d.get("lat"), 90), _coord(d.get("lng"), 180)
        if lat is None or lng is None:
            lat = lng = None
        st = FA.sos(request.user, lat=lat, lng=lng,
                    client_id=str(d.get("client_id") or ""),
                    source=str(d.get("source") or "app"))
        return Response({"ok": True, **_summary(st)})


class FamilySosResolveView(APIView):
    """POST /family/sos/resolve — 'I'm safe now'."""
    def post(self, request):
        st = FA.sos_resolved(request.user)
        return Response({"ok": True, "recipients": st.get("recipients", 0),
                         "sent": st.get("sent", 0)})


class FamilyAlertsView(APIView):
    """GET /family/alerts — alerts I received (7 days) + events I raised with
    each member's received / seen receipt."""
    def get(self, request):
        rec = FA.received_rows(request.user)
        return Response({"received": rec, "sent": FA.sent_rows(request.user),
                         "unseen": sum(1 for r in rec if not r["seen"])})


class FamilyAlertSeenView(APIView):
    """POST /family/alerts/<id>/seen — the recipient saw it (tap / button);
    the sender's screen shows it as seen."""
    def post(self, request, pk):
        d = FA.mark_seen(request.user, pk)
        if d is None:
            return Response({"detail": "not_found"}, status=status.HTTP_404_NOT_FOUND)
        return Response({"ok": True})


class FamilyAlertReceivedView(APIView):
    """POST /family/alerts/received {ids:[...]} — the phone got the push."""
    def post(self, request):
        ids = (request.data or {}).get("ids") or []
        if not isinstance(ids, list):
            return Response({"detail": "bad_ids"}, status=status.HTTP_400_BAD_REQUEST)
        return Response({"ok": True, "updated": FA.mark_received(request.user, ids)})
