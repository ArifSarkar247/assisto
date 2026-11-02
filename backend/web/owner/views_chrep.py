"""channels (2 Nov): Owner Admin -> Channel reports. Reports on channels,
channel posts and communities (core.views_messenger.ModerationReportView)
wait here. Severe reports / many reporters already hid the item; the owner
removes it (leaves the directory, posts hidden) or restores it. Channel
posts are public plaintext, so a short excerpt is shown; community chats
are E2E and never shown. Every action is audited."""
from django.http import Http404
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page

KINDS = ("channel", "post", "community")


def _label(it):
    from core.models import Channel, ChannelPost, Community
    tid = int(it.target_id) if str(it.target_id).isdigit() else 0
    if it.target_kind == "channel":
        c = Channel.objects.filter(pk=tid).first()
        return ("%s (@%s, %s)" % (c.name, c.handle, c.follower_count)) if c else "—"
    if it.target_kind == "post":
        p = ChannelPost.objects.filter(pk=tid).select_related("channel").first()
        return ("@%s: %s" % (p.channel.handle, (p.text or p.kind)[:140])) if p else "—"
    c = Community.objects.filter(pk=tid).first()
    return c.name if c else "—"


@require_http_methods(["GET"])
@owner_view()
def channel_reports(request):
    from core.models import ModerationItem
    st = request.GET.get("status") or "open"
    qs = ModerationItem.objects.filter(target_kind__in=KINDS)
    qs = qs.exclude(queue_state="resolved") if st == "open" else \
        qs.filter(queue_state="resolved")
    rows = list(qs.order_by("-severe", "-report_count", "-opened_at")[:100])
    for r in rows:
        r.label = _label(r)
    return page(request, "owner/channel_reports.html",
                {"rows": rows, "st": st,
                 "n_open": ModerationItem.objects.filter(target_kind__in=KINDS)
                 .exclude(queue_state="resolved").count()},
                nav="channel_reports")


@require_http_methods(["POST"])
@owner_view()
def channel_report_act(request, pk):
    from core.logic import msg_moderation as mmod
    from core.models import ModerationAudit, ModerationItem
    from core.views_messenger import _apply_status_to_target
    it = ModerationItem.objects.filter(pk=pk, target_kind__in=KINDS).first()
    if it is None:
        raise Http404
    action = request.POST.get("action")
    if action not in (mmod.A_REMOVE, mmod.A_RESTORE):
        raise Http404
    reason = (request.POST.get("reason") or "").strip()[:300] or "owner review"
    before = {"content_status": it.content_status, "queue_state": it.queue_state}
    new_item, audit = mmod.apply_admin_action(
        {"id": it.id, "target_kind": it.target_kind, "target_id": it.target_id,
         "content_status": it.content_status,
         "legal_retention": it.legal_retention},
        action, request.owner.id, reason)
    it.content_status = new_item["content_status"]
    it.queue_state = new_item["queue_state"]
    it.decision = new_item["decision"]
    it.resolved_at = timezone.now()
    it.save(update_fields=["content_status", "queue_state", "decision",
                           "resolved_at"])
    _apply_status_to_target(it.target_kind, it.target_id, it.content_status)
    ModerationAudit.objects.create(
        actor=request.owner, action=audit["action"],
        target_kind=audit["target_kind"], target_id=str(audit["target_id"]),
        reason=audit["reason"], extra={"via": "owner_admin"})
    S.audit(request, request.owner, "channel_report.%s" % action,
            "moderation:%s" % it.pk, before=before,
            after={"content_status": it.content_status})
    return done("/owner/channel-reports")
