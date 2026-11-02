"""flagprep (2 Nov): Owner Admin -> Train timetable. The owner compares each
train with the official Bangladesh Railway timetable and ticks "checked";
the app then drops the "timetable not yet checked" line for that train.
OwnerAudit action train_schedule_checked."""
from django.views.decorators.http import require_http_methods

from .base import owner_view, page

# Python weekday(): 0 = Monday (train_geo.runs_on)
_DAYS_BN = ("সোম", "মঙ্গল", "বুধ", "বৃহস্পতি", "শুক্র", "শনি", "রবি")
_DAYS_EN = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")


@require_http_methods(["GET", "POST"])
@owner_view()
def train_schedule(request):
    if request.method == "POST":
        return _save(request)
    from core import train_service as TS
    from core.logic import train_geo as TG
    lang = getattr(request, "owner_lang", "bn")
    days = _DAYS_BN if lang == "bn" else _DAYS_EN
    checked = TS.checked_nos()
    rows = []
    for t in TG.timetable()["trains"]:
        s = TS.train_summary(t, checked)
        rows.append({"no": s["no"], "name": s["name_bn"],
                     "from": s["from"].get(lang) or s["from"].get("bn") or "",
                     "to": s["to"].get(lang) or s["to"].get("bn") or "",
                     "dep": s["dep"], "arr": s["arr"],
                     "off": ", ".join(days[d] for d in s["off_days"] if 0 <= d < 7) or "—",
                     "checked": s["approved"], "in_file": bool(t.get("approved")),
                     "note": (t.get("source") or {}).get("timetable_note", "")})
    return page(request, "owner/train_schedule.html", {
        "rows": rows, "n_checked": sum(1 for r in rows if r["checked"]), "n": len(rows),
    }, nav="train_schedule")


def _save(request):
    from core import train_service as TS
    from . import security as S
    from .base import done
    before, after = TS.save_checked(request.POST.getlist("checked"), actor=request.owner)
    S.audit(request, request.owner, "train_schedule_checked", "trains",
            before={"nos": before}, after={"nos": after})
    return done("/owner/train-schedule")
