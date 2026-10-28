"""AF-3: Owner Admin -> Crisis helplines. The numbers the crisis handover
shows users (core.agentcore.crisis_guard). 999 ships verified and is locked;
every other entry ships "unverified — owner must confirm" and is shown to
users ONLY after the owner ticks "verified" here with the official source.
Every change is audited (OwnerAudit action "crisis_helpline")."""
from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page

AUDIT_ACTION = "crisis_helpline"


@require_http_methods(["GET"])
@owner_view()
def crisis_helplines(request):
    from core.agentcore import crisis_guard as CG
    from core.models import OwnerAudit
    rows = CG.all_helplines()
    lang = getattr(request, "owner_lang", "bn")
    shown = CG.helplines("", lang)
    log = list(OwnerAudit.objects.filter(action=AUDIT_ACTION).select_related("actor")[:40])
    return page(request, "owner/crisis_helplines.html", {
        "rows": rows, "cats": CG.CATEGORIES, "shown": shown, "log": log,
        "unverified_note": CG.UNVERIFIED_NOTE,
    }, nav="crisis")


@require_http_methods(["POST"])
@owner_view()
def crisis_helpline_save(request, key):
    from core.agentcore import crisis_guard as CG
    if not any(d["key"] == key for d in CG.DEFAULT_HELPLINES):
        raise Http404
    clean, problems = CG.validate_edit(key, request.POST)
    back = "/owner/crisis-helplines"
    if problems:
        S.audit(request, request.owner, AUDIT_ACTION, key, after={"rejected": problems}, ok=False)
        return done(back, "invalid")
    before, after = CG.save_helpline(key, clean, actor=request.owner)
    S.audit(request, request.owner, AUDIT_ACTION, key, before=before, after=after)
    return done(back)
