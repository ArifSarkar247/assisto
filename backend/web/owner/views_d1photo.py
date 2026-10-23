"""d1-photo v2: Owner Admin → Photo Studio.

  * free-tier Profit Guard — AI cost vs ad revenue per free user (alert when
    the free tier loses money);
  * BLIND A/B test — the same damaged photo through Assisto and through Remini
    (the owner's own Remini outputs, imported with `manage.py photo_ab_import`);
    left/right is random per vote and the labels stay hidden until the vote;
    results per category are shown only after at least one vote;
  * "Report this AI image" reports from the app (Google Play AI-content policy);
  * worker queue state.
Nothing here can claim "better than Remini": the page only counts votes.
"""
import os
import random

from django.conf import settings
from django.http import FileResponse, Http404
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from .base import done, owner_view, page, to_int


@require_http_methods(["GET", "POST"])
@owner_view()
def photo(request):
    from core import photo_studio_service as S
    from core.models import PhotoABPair, PhotoABVote, PhotoAIReport, PhotoWorkItem
    if request.method == "POST":
        act = request.POST.get("action")
        if act == "vote":
            pair = PhotoABPair.objects.filter(pk=to_int(request.POST.get("pair"))).first()
            pick = request.POST.get("pick")            # left | right | same
            left = request.POST.get("left_was")        # assisto | remini
            if pair and pick in ("left", "right", "same") and left in ("assisto", "remini"):
                other = "remini" if left == "assisto" else "assisto"
                choice = {"left": left, "right": other, "same": "same"}[pick]
                PhotoABVote.objects.update_or_create(pair=pair, voter=request.owner,
                                                     defaults={"choice": choice, "left_was": left})
            return done("/owner/photo#ab", "voted")
        if act == "close_report":
            PhotoAIReport.objects.filter(pk=to_int(request.POST.get("rid"))).update(status="closed")
            return done("/owner/photo#reports")
    voted = set(PhotoABVote.objects.filter(voter=request.owner).values_list("pair_id", flat=True))
    pending = PhotoABPair.objects.exclude(pk__in=voted).order_by("name").first()
    left = random.choice(("assisto", "remini"))
    results = {}
    for v in PhotoABVote.objects.select_related("pair"):
        r = results.setdefault(v.pair.category or "-", {"assisto": 0, "remini": 0, "same": 0})
        r[v.choice] += 1
    totals = {k: sum(r[k] for r in results.values()) for k in ("assisto", "remini", "same")}
    q = PhotoWorkItem.objects
    ctx = {
        "guard": S.free_tier_guard(30),
        "pair": pending, "left_was": left,
        "left_tag": "a" if left == "assisto" else "r",
        "right_tag": "r" if left == "assisto" else "a",
        "pairs_total": PhotoABPair.objects.count(), "my_votes": len(voted),
        "results": sorted(results.items()), "totals": totals,
        "reports": PhotoAIReport.objects.select_related("job").order_by("status", "-created_at")[:50],
        "queue": {"queued": q.filter(state="queued").count(), "running": q.filter(state="running").count(),
                  "failed_24h": q.filter(state="failed", finished_at__gte=timezone.now() - timezone.timedelta(hours=24)).count(),
                  "done_24h": q.filter(state="done", finished_at__gte=timezone.now() - timezone.timedelta(hours=24)).count()},
        "worker_on": bool(getattr(settings, "PHOTO_WORKER", False)),
    }
    return page(request, "owner/photo.html", ctx, nav="photo")


@require_http_methods(["GET"])
@owner_view()
def photo_ab_image(request, pk, tag):
    from core.models import PhotoABPair
    pair = PhotoABPair.objects.filter(pk=pk).first()
    if pair is None or tag not in ("in", "a", "r"):
        raise Http404
    name = {"in": pair.input_name, "a": pair.assisto_name, "r": pair.remini_name}[tag]
    path = os.path.join(str(settings.MEDIA_ROOT), name)
    if ".." in name or not os.path.isfile(path):
        raise Http404
    resp = FileResponse(open(path, "rb"), content_type="image/jpeg")
    resp["Cache-Control"] = "private, no-store"
    return resp
