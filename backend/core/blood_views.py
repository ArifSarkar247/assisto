"""
Blood donor panel HTTP API (owner 2 Nov, "রক্তদাতা প্যানেল"). Flag
`blood_donors` (OFF; owner / staff / allow-listed testers preview). Prefix
`blood-panel/` (the older personal registry owns `blood/donors/`).
NEVER flag-gated (privacy): reading my own profile, leaving the panel
(DELETE /me), switching listing OFF, my threads (read / block).

  GET  /blood-panel/config
  GET|POST|DELETE /blood-panel/me                   profile (POST {consent, enabled, ...})
  POST /blood-panel/me/donated                       {date?}
  POST /blood-panel/me/verify                        {photo_b64}
  GET  /blood-panel/donors?group&radius&lat&lng&district&compatible&eligible_only
  POST /blood-panel/donors/<id>/message              {text}
  GET|POST /blood-panel/requests                     {mine, near} / create
  GET  /blood-panel/requests/<id>
  POST /blood-panel/requests/<id>/respond            {answer: can|cannot|withdraw|donated}
  POST /blood-panel/requests/<id>/found              blood found
  POST /blood-panel/requests/<id>/close
  POST /blood-panel/requests/<id>/report             {reason, note}
  GET  /blood-panel/threads
  GET|POST /blood-panel/threads/<id>                 messages / {text}
  POST /blood-panel/threads/<id>/block               {on}
  POST /blood-panel/threads/<id>/circle              {action: ask|accept|decline}
  GET  /blood-panel/banks
"""
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import blood_panel as BP
from .logic import blood_rules as BR
from .logic import missing_rules as MR

R = Response


def _off():
    return R({"ok": False, "reason": "feature_off"}, status=403)


def _bad(reason, status=400, **extra):
    out = {"ok": False, "reason": reason}
    out.update(extra)
    return R(out, status=status)


def _lang(request):
    la = getattr(request.user, "language", "bn")
    return la if la in ("bn", "en") else "bn"


def _body(request):
    return request.data if isinstance(request.data, dict) else {}


def _iso(dt):
    return dt.isoformat() if dt else None


_STATUS = {"rate_limited": 429, "too_many_requests": 429, "too_many_active": 429,
           "banned": 403, "not_allowed": 403, "not_donor": 403, "blocked": 403,
           "not_found": 404, "already": 409, "already_pending": 409,
           "already_verified": 409, "declined": 409}


def _err(reason, **extra):
    return _bad(reason, _STATUS.get(reason, 400), **extra)


def request_json(request, r, role, viewer=None):
    lang = _lang(request)
    d = MR.district(r.district)
    out = {"id": r.id, "role": role, "state": r.state, "blood_group": r.blood_group,
           "units": r.units, "hospital": r.hospital, "area_text": r.area_text,
           "district_name": (d[2] if lang == "bn" else d[1]) if d else "",
           "radius_km": r.radius_km, "needed_by": _iso(r.needed_by), "note": r.note,
           "created_at": _iso(r.created_at), "expires_at": _iso(r.expires_at),
           "closed_at": _iso(r.closed_at),
           "requester_name": BR.first_name(r.requester.name)}
    if viewer is not None:
        out["share"] = BP.share_state(r, viewer)        # both sides agree
    if role == "requester":
        out.update({"pushed": r.pushed, "listed": r.listed,
                    "responders": BP.responders(r, lang),
                    "reports_open": r.reports.filter(status="open").count()})
    elif viewer is not None:
        row = r.recipients.filter(user=viewer).first()
        out["my_response"] = row.response if row else ""
        out["reported"] = r.reports.filter(reporter=viewer).exists()
        me = BP.get_donor(viewer)
        if me is not None:
            _ok, km = BR.within(BR.area_of(r.lat, r.lng, r.district),
                                BR.area_of(me.lat, me.lng, me.district), 10 ** 6)
            out["km"] = BR.shown_km(km)
            out["compatible"] = bool(me.blood_group and BR.can_donate_to(me.blood_group, r.blood_group))
            out["eligible_by_then"] = BR.is_eligible(
                me.last_donation, me.sex, BP.timezone.localtime(r.needed_by).date())
        from .models import BloodThread
        th = BloodThread.objects.filter(donor=viewer, seeker=r.requester).first()
        out["thread_id"] = th.id if th else None
    return out


class ConfigView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        lang = _lang(request)
        return R({
            "enabled": BP.flag_on(request.user), "districts": MR.district_list(lang),
            "groups": list(BR.BLOOD_GROUPS), "radius_choices": list(BR.RADIUS_CHOICES),
            "default_radius": BR.DEFAULT_RADIUS, "interval_days": BR.INTERVAL_DAYS,
            "interval_source": BR.INTERVAL_SOURCE, "consent_version": BR.CONSENT_VERSION,
            "min_age": BR.MIN_AGE, "max_age": BR.MAX_AGE, "min_weight": BR.MIN_WEIGHT_KG,
            "max_req_day": BR.MAX_REQ_DAY, "max_units": BR.MAX_UNITS,
            "max_needed_in_h": BR.MAX_NEEDED_IN_H, "expire_after_h": BR.EXPIRE_AFTER_NEEDED_H,
            "max_push_per_donor_day": BR.MAX_PUSH_PER_DONOR_DAY,
            "report_hide_n": BR.REPORT_HIDE_N, "site": BR.SITE_LINK,
            "me": BP.donor_json(BP.get_donor(request.user), lang),
        })


class MeView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        return R(BP.donor_json(BP.get_donor(request.user), _lang(request)))

    def post(self, request):
        body = _body(request)
        turning_off_only = set(body) <= {"enabled", "available"} and body.get("enabled") is not True
        if not turning_off_only and not BP.flag_on(request.user):
            return _off()
        d, err, fields = BP.save_donor(request.user, body)
        if err:
            return _err(err, fields=fields)
        return R({"ok": True, "me": BP.donor_json(d, _lang(request))})

    def delete(self, request):
        BP.leave(request.user)
        return R({"ok": True, "me": BP.donor_json(None)})


class DonatedView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        on_day = None
        raw = _body(request).get("date")
        if raw:
            on_day, ok = BR.clean_last_donation(raw, BP.today())
            if not ok or on_day is None:
                return _err("invalid", fields=["date"])
        d = BP.mark_donated(request.user, on_day)
        if d is None:
            return _err("not_donor")
        return R({"ok": True, "me": BP.donor_json(d, _lang(request))})


class VerifyView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        if not BP.flag_on(request.user):
            return _off()
        v, err = BP.submit_slip(request.user, _body(request).get("photo_b64"))
        if err:
            return _err(err)
        return R({"ok": True, "state": v.state}, status=201)


class DonorsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        if not BP.flag_on(request.user):
            return _off()
        rows, counts, err = BP.search_full(request.user, request.query_params, _lang(request))
        if err:
            return _err(err)
        return R({"ok": True, "donors": rows, "count": len(rows), "counts": counts})


class DonorMessageView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not BP.flag_on(request.user):
            return _off()
        from .models import BloodDonor
        d = BloodDonor.objects.filter(pk=pk, enabled=True).select_related("user").first()
        if d is None:
            return _err("not_found")
        th, err = BP.start_thread(request.user, d, _body(request).get("text"))
        if err:
            return _err(err)
        return R({"ok": True, "thread": BP.thread_json(th, request.user, _lang(request))}, status=201)


class RequestsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        on = BP.flag_on(request.user)
        if not on:
            return R({"enabled": False, "mine": [], "near": []})
        BP.sweep(limit=20, reminders=False)
        from .models import BloodRequest
        u = request.user
        mine = [request_json(request, r, "requester")
                for r in BloodRequest.objects.filter(requester=u).select_related("requester")[:20]]
        near = [request_json(request, r, "donor", u) for r in BP.visible_requests(u)]
        return R({"enabled": True, "mine": mine, "near": near})

    def post(self, request):
        if not BP.flag_on(request.user):
            return _off()
        r, err, fields = BP.create_request(request.user, _body(request))
        if err:
            return _err(err, fields=fields)
        return R({"ok": True, "request": request_json(request, r, "requester")}, status=201)


def _load(request, pk):
    from .models import BloodRequest
    r = BloodRequest.objects.filter(pk=pk).select_related("requester").first()
    if r is None or not BP.can_see(request.user, r):
        return None, _err("not_found")
    return r, None


class RequestDetailView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        if not BP.flag_on(request.user):
            return _off()
        r, err = _load(request, pk)
        if err:
            return err
        role = BP.role(request.user, r)
        return R(request_json(request, r, role, request.user))


class RespondView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not BP.flag_on(request.user):
            return _off()
        r, err = _load(request, pk)
        if err:
            return err
        e = BP.respond(r, request.user, str(_body(request).get("answer") or ""))
        if e:
            return _err(e)
        r.refresh_from_db()
        return R({"ok": True, "request": request_json(request, r, "donor", request.user)})


class _EndView(APIView):
    permission_classes = [IsAuthenticated]
    state = ""

    def post(self, request, pk):
        if not BP.flag_on(request.user):
            return _off()
        r, err = _load(request, pk)
        if err:
            return err
        if r.requester_id != request.user.id:
            return _err("not_allowed")
        e = BP.end_request(r, self.state, request.user)
        if e:
            return _err(e)
        return R({"ok": True, "request": request_json(request, r, "requester"),
                  "site": BR.SITE_LINK})


class FoundView(_EndView):
    state = "fulfilled"


class CloseView(_EndView):
    state = "closed"


class ShareAgreeView(APIView):
    """POST: this side agrees to the public thank-you card (finish1)."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not BP.flag_on(request.user):
            return _off()
        r, err = _load(request, pk)
        if err:
            return err
        e = BP.share_agree(r, request.user)
        if e:
            return _err(e)
        return R({"ok": True, "share": BP.share_state(r, request.user)})


class ReportView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not BP.flag_on(request.user):
            return _off()
        r, err = _load(request, pk)
        if err:
            return err
        b = _body(request)
        st, hidden = BP.report(r, request.user, str(b.get("reason") or ""), b.get("note"))
        if st != "ok":
            return _err(st)
        return R({"ok": True, "hidden": hidden})


class ThreadsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        lang = _lang(request)
        return R({"threads": [BP.thread_json(t, request.user, lang)
                              for t in BP.my_threads(request.user)]})


def _thread(request, pk):
    from .models import BloodThread
    th = BloodThread.objects.filter(pk=pk).select_related("donor", "seeker").first()
    if th is None or BP.side(th, request.user) is None:
        return None, _err("not_found")
    return th, None


class ThreadView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        th, err = _thread(request, pk)
        if err:
            return err
        BP.mark_read(th, request.user)
        s = BP.side(th, request.user)
        msgs = [{"id": m.id, "mine": m.by_donor == (s == "donor"), "text": m.text, "at": _iso(m.at)}
                for m in th.messages.order_by("-id")[:200]][::-1]
        return R({"thread": BP.thread_json(th, request.user, _lang(request)), "messages": msgs})

    def post(self, request, pk):
        if not BP.flag_on(request.user):
            return _off()
        th, err = _thread(request, pk)
        if err:
            return err
        e = BP.send(th, request.user, _body(request).get("text"))
        if e:
            return _err(e)
        return R({"ok": True}, status=201)


class ThreadBlockView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        th, err = _thread(request, pk)
        if err:
            return err
        e = BP.block(th, request.user, _body(request).get("on") is not False)
        if e:
            return _err(e)
        return R({"ok": True, "thread": BP.thread_json(th, request.user, _lang(request))})


class ThreadCircleView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        if not BP.flag_on(request.user):
            return _off()
        th, err = _thread(request, pk)
        if err:
            return err
        e, extra = BP.circle(th, request.user, str(_body(request).get("action") or ""))
        if e:
            return _err(e)
        out = {"ok": True, "thread": BP.thread_json(th, request.user, _lang(request))}
        out.update(extra)
        return R(out)


class BanksView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        if not BP.flag_on(request.user):
            return _off()
        g = request.query_params
        return R(BP.banks(_lang(request), district=g.get("district", ""),
                          q=g.get("q", ""), lat=g.get("lat"), lng=g.get("lng")))
