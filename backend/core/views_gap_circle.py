"""gap-circle (17 Nov gap sweep): remove calls from MY call log.

POST /circle/calls/hide {"ids": [..]}  -> those calls leave my log only
POST /circle/calls/hide {"all": true}  -> clear my whole call log
The other person's log is never touched. Stored in MsgUserSettings.calls
(no migration): "log_hidden" (capped id list) + "log_cleared_at" (ISO time).
"""
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import CallRecord

HIDDEN_CAP = 1000


def _row(user):
    from .views_m1_messenger import user_settings
    return user_settings(user)


def visible_calls(user, rows):
    """Filter a CallRecord queryset by what `user` removed from their log."""
    try:
        from .models import MsgUserSettings
        st = MsgUserSettings.objects.filter(user=user).first()
        calls = (st.calls or {}) if st else {}
    except Exception:  # noqa: BLE001 — never break the call log
        return rows
    hidden = [i for i in calls.get("log_hidden", []) if isinstance(i, int)]
    if hidden:
        rows = rows.exclude(pk__in=hidden)
    cut = parse_datetime(str(calls.get("log_cleared_at") or ""))
    if cut is not None:
        rows = rows.filter(started_at__gt=cut)
    return rows


class CallLogHideView(APIView):
    def post(self, request):
        d = request.data or {}
        row = _row(request.user)
        calls = dict(row.calls or {})
        if d.get("all") is True:
            calls["log_cleared_at"] = timezone.now().isoformat()
            calls["log_hidden"] = []
            row.calls = calls
            row.save(update_fields=["calls", "updated_at"])
            return Response({"ok": True, "cleared": True})
        raw = d.get("ids")
        if not isinstance(raw, list) or not raw:
            return Response({"detail": "ids required"},
                            status=status.HTTP_400_BAD_REQUEST)
        try:
            want = {int(i) for i in raw[:200]}
        except (TypeError, ValueError):
            return Response({"detail": "bad ids"},
                            status=status.HTTP_400_BAD_REQUEST)
        u = request.user
        mine = set((CallRecord.objects.filter(caller=u, pk__in=want)
                    | CallRecord.objects.filter(callee=u, pk__in=want))
                   .values_list("id", flat=True))
        if not mine:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        hidden = [i for i in calls.get("log_hidden", []) if isinstance(i, int)]
        hidden = sorted(set(hidden) | mine)[-HIDDEN_CAP:]
        calls["log_hidden"] = hidden
        row.calls = calls
        row.save(update_fields=["calls", "updated_at"])
        return Response({"ok": True, "hidden": sorted(mine)})
