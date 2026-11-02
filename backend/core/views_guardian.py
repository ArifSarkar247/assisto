"""journey2 / owner idea 1 — the guardian-requested journey API.

  GET  /journey/requests                 incoming + outgoing + who can be asked
  POST /journey/requests                 ask {member_id, destination, start, end, note}
                                         (child school mode: standing + schedule +
                                          minor_declared, own child only)
  POST /journey/requests/<id>/accept     traveller, one tap (consent every time)
  POST /journey/requests/<id>/decline    traveller
  POST /journey/requests/<id>/start      traveller's app at/after the window start
  POST /journey/requests/<id>/stop       traveller, one tap, no PIN
  POST /journey/requests/<id>/cancel     requester (also turns child mode off)

Free on every plan: nothing here touches billing (safety, SAFETY_EXEMPT).
Rules + sweeper: core/guardian_journey.py."""
from django.db import transaction
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import guardian_journey as GJ
from .i18n import req_lang
from .models import CircleMember, JourneyRequest


def _bad(code, http=status.HTTP_400_BAD_REQUEST):
    return Response({"detail": code}, status=http)


class JourneyRequestsView(APIView):
    def get(self, request):
        lang, me = req_lang(request), request.user
        live = list(GJ.LIVE)
        inc = JourneyRequest.objects.filter(traveller=me).select_related(
            "requester", "traveller", "journey")
        out = JourneyRequest.objects.filter(requester=me).select_related(
            "requester", "traveller", "journey")
        people = []
        for m in CircleMember.objects.filter(user=me, state="accepted", blocked=False,
                                             peer_user__isnull=False).select_related("peer_user"):
            people.append({"member_id": m.id, "name": m.name or GJ._name(me, m.peer_user),
                           "relation": m.relation,
                           "child": GJ.is_child_pair(me, m.peer_user)})
        return Response({
            "incoming": [GJ.as_dict(r, me, lang) for r in inc.filter(status__in=live)[:20]],
            "outgoing": [GJ.as_dict(r, me, lang) for r in out.filter(status__in=live)[:20]],
            "history": [GJ.as_dict(r, me, lang) for r in
                        (inc | out).exclude(status__in=live).order_by("-updated_at")[:10]],
            "people": people,
        })

    def post(self, request):
        me, d = request.user, (request.data or {})
        m = CircleMember.objects.filter(user=me, pk=d.get("member_id"), state="accepted",
                                        blocked=False).select_related("peer_user").first()
        if m is None or m.peer_user is None:
            return _bad("not_in_circle")
        now = GJ._now()
        clean, err = GJ.validate_new(me, m.peer_user, d, now)
        if err:
            return _bad(err)
        err = GJ.spam_ok(me, m.peer_user, now)
        if err:
            return _bad(err, status.HTTP_429_TOO_MANY_REQUESTS)
        if clean["standing"] and JourneyRequest.objects.filter(
                requester=me, traveller=m.peer_user, standing=True,
                status__in=GJ.LIVE).exists():
            return _bad("standing_exists")
        req = JourneyRequest(requester=me, traveller=m.peer_user, **clean)
        GJ.add_log(req, "requester", "asked", now)
        req.save()
        rn = GJ._name(req.traveller, me)
        tbn, bbn = GJ.request_texts(req, "bn", rn)
        ten, ben = GJ.request_texts(req, "en", rn)
        GJ.notify(req.traveller, req, "asked", tbn, ten, bbn, ben, high=True)
        return Response(GJ.as_dict(req, me, req_lang(request)), status=status.HTTP_201_CREATED)


class JourneyRequestActionView(APIView):
    def post(self, request, pk, action):
        me, lang, now = request.user, req_lang(request), GJ._now()
        with transaction.atomic():
            req = (JourneyRequest.objects.select_for_update()
                   .filter(pk=pk).first())
            if req is None or me.pk not in (req.requester_id, req.traveller_id):
                return _bad("not_found", status.HTTP_404_NOT_FOUND)
            is_trav = me.pk == req.traveller_id
            if action in ("accept", "decline", "start", "stop") and not is_trav:
                return _bad("not_found", status.HTTP_404_NOT_FOUND)
            if action == "cancel" and is_trav:
                return _bad("not_found", status.HTTP_404_NOT_FOUND)
            if action == "accept":
                if req.status != "pending":
                    return _bad("not_pending", status.HTTP_409_CONFLICT)
                if not req.standing and now >= req.window_end:
                    return _bad("window_over", status.HTTP_409_CONFLICT)
                req.status = "accepted"
                GJ.add_log(req, "traveller", "accepted", now)
                req.save()
                tn = GJ._name(req.requester, req.traveller)
                GJ.notify(req.requester, req, "accepted", "%s রাজি হয়েছেন" % tn,
                          "%s accepted" % tn,
                          "সময় শুরু হলে যাত্রা দেখতে পাবেন।",
                          "You will see the trip when the window starts.")
                occ = GJ.occurrence(req, now)
                if occ and occ[0] <= now:
                    GJ.start_trip(req, now)     # accepted inside the window: start now
            elif action == "decline":
                if req.status != "pending":
                    return _bad("not_pending", status.HTTP_409_CONFLICT)
                req.status, req.outcome = "declined", "declined"
                GJ.add_log(req, "traveller", "declined", now)
                req.save()
                tn = GJ._name(req.requester, req.traveller)
                GJ.notify(req.requester, req, "declined", "%s রাজি হননি" % tn,
                          "%s declined" % tn, "এবার যাত্রা শেয়ার হবে না।",
                          "The trip will not be shared this time.")
            elif action == "start":
                j, err = GJ.start_trip(req, now)
                if err:
                    return _bad(err, status.HTTP_409_CONFLICT)
            elif action == "stop":
                if req.status not in ("active", "accepted"):
                    return _bad("not_active", status.HTTP_409_CONFLICT)
                if req.status == "accepted" and not req.standing:
                    # stopping before it began = withdrawing consent
                    req.status, req.outcome = "ended", "withdrawn"
                    GJ.add_log(req, "traveller", "withdrawn", now)
                    req.save()
                    tn = GJ._name(req.requester, req.traveller)
                    GJ.notify(req.requester, req, "withdrawn", "%s সম্মতি ফিরিয়ে নিয়েছেন" % tn,
                              "%s withdrew consent" % tn, "এই যাত্রা শেয়ার হবে না।",
                              "This trip will not be shared.")
                else:
                    GJ.stop_by_traveller(req, now)
            elif action == "cancel":
                if req.status not in GJ.LIVE:
                    return _bad("not_active", status.HTTP_409_CONFLICT)
                GJ.finish(req, "cancelled", now, by="requester")
                rn = GJ._name(req.traveller, req.requester)
                GJ.notify(req.traveller, req, "cancelled", "%s অনুরোধ তুলে নিয়েছেন" % rn,
                          "%s cancelled the request" % rn,
                          "আর কেউ আপনার যাত্রা দেখছেন না।", "Nobody is following your trip now.")
            else:
                return _bad("unknown_action", status.HTTP_404_NOT_FOUND)
        req.refresh_from_db()
        return Response(GJ.as_dict(req, me, lang))
