"""m2-reality — small backend routes the app already called but that did not
exist (found by tools/route_check.py). Each one is a REAL implementation or an
explicit, honest "not persisted" answer; nothing here fakes success."""
from rest_framework import status
from rest_framework.decorators import api_view
from rest_framework.response import Response


@api_view(["POST"])
def notif_reminder_done(request, item_id):
    """POST notif/reminders/<id>/done — the Notification Centre "Done" action.

    reminder:<pk> / todo:<pk> are marked done for real. Other sources (e.g. a
    medicine dose, which needs a slot + inventory update) are NOT completed
    here: we answer persisted=false with the module to open, so the app can be
    honest instead of showing a fake tick."""
    iid = str(item_id)
    kind, _, rest = iid.partition(":")
    persisted = False
    if kind in ("reminder", "todo"):
        try:
            pk = int(rest.split(":", 1)[0])
        except ValueError:
            return Response({"ok": False, "error": "bad_id"},
                            status=status.HTTP_400_BAD_REQUEST)
        qs = request.user.reminders if kind == "reminder" else request.user.todos
        obj = qs.filter(pk=pk).first()
        if obj is None:
            return Response({"ok": False, "error": "not_found"},
                            status=status.HTTP_404_NOT_FOUND)
        obj.done = True
        obj.save(update_fields=["done", "updated_at"])
        persisted = True
    return Response({"ok": True, "id": iid, "persisted": persisted,
                     "open": None if persisted else (kind or None)})
