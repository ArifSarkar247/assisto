"""
Missing person alert HTTP API (owner 2 Nov, "নিখোঁজ সতর্কতা"). Flag
`missing_alert` (OFF; owner / staff / allow-listed testers preview).
NEVER flag-gated (privacy / autonomy): "I am safe", turning nearby alerts
OFF, and the list of alerts about me.

  GET  /missing-alerts/config                    districts, limits, my opt-in, my family
  GET  /missing-alerts                           {near, mine, about_me, cosign}
  POST /missing-alerts                           create (photo_b64 optional)
  GET  /missing-alerts/<id>                      detail by role
  POST /missing-alerts/<id>/found                {share_ok}
  POST /missing-alerts/<id>/close
  POST /missing-alerts/<id>/renew                {gd_number?, gd_still_open?}
  POST /missing-alerts/<id>/gd                   {gd_number, gd_thana, gd_date}
  POST /missing-alerts/<id>/cosign               {confirm: bool}
  POST /missing-alerts/<id>/safe                 the missing person (never gated)
  POST /missing-alerts/<id>/report               {reason, note}
  GET|POST /missing-alerts/<id>/tips             family: all threads / tipster: own thread
  GET|POST /missing-alerts/tips/<thread_id>      read / family reply
  GET|POST /missing-alerts/nearby                opt-in (OFF never gated)
  POST /missing-alerts/where-i-am                {lat, lng} while the app is open
"""
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import missing_alert as MS
from .logic import missing_rules as MR

R = Response


def _off():
    return R({"ok": False, "reason": "feature_off"}, status=403)


def _iso(dt):
    return dt.isoformat() if dt else None


def _lang(request):
    la = getattr(request.user, "language", "bn")
    return la if la in ("bn", "en") else "bn"


def _bad(reason, status=400, **extra):
    out = {"ok": False, "reason": reason}
    out.update(extra)
    return R(out, status=status)


def _photo_url(request, a):
    if not a.photo or a.state not in ("active", "pending", "hidden"):
        return None
    try:
        return request.build_absolute_uri(a.photo.url)
    except Exception:
        return None


def alert_json(request, a, role, viewer=None):
    """What each side sees. Recipients never see the poster's identity or
    phone; nobody but the family sees tips; ended alerts lose the photo +
    description."""
    lang = _lang(request)
    d = MR.district(a.district)
    live = a.state in ("active", "pending", "hidden")
    out = {
        "id": a.id, "state": a.state, "role": role, "name": a.name, "age": a.age,
        "is_child": a.is_child, "area_text": a.area_text, "district": a.district,
        "district_name": (d[2] if lang == "bn" else d[1]) if d else "",
        "last_seen_at": _iso(a.last_seen_at), "radius_km": a.radius_km,
        "created_at": _iso(a.created_at), "activated_at": _iso(a.activated_at),
        "expires_at": _iso(a.expires_at), "closed_at": _iso(a.closed_at),
        "safe_said": bool(a.safe_said_at), "safe_said_at": _iso(a.safe_said_at),
        "photo_url": _photo_url(request, a) if role != "subject" or live else None,
        "description": a.description if live else "",
        "gd": ({"number": a.gd_number, "thana": a.gd_thana, "date": _iso(a.gd_date),
                "verified": False} if a.gd_number else None),
        "basis": a.basis,
    }
    if role in ("family", "cosigner"):
        from .models import MissingRecipient
        out.update({
            "pushed": a.pushed, "listed": a.listed, "renewals": a.renewals,
            "max_renewals": MR.MAX_RENEWALS,
            "can_renew": bool(a.state == "active" and a.expires_at and a.renewals < MR.MAX_RENEWALS
                              and (a.expires_at - MS.now()).total_seconds() <= MR.RENEW_WINDOW_H * 3600),
            "tips_unread": sum(t.family_unread for t in a.tips.all()),
            "tips": a.tips.count(),
            "cosign_asked": ({"id": a.cosign_asked.id, "name": a.cosign_asked.name or ""}
                             if a.cosign_asked_id else None),
            "cosigner": ({"id": a.cosigner.id, "name": a.cosigner.name or ""}
                         if a.cosigner_id else None),
            "relation": a.relation, "share_agreed": a.share_agreed,
            "recipients_family": MissingRecipient.objects.filter(alert=a, source="family").count(),
        })
        if role == "cosigner":
            out["poster_name"] = a.poster.name or ""
    if role == "recipient" and viewer is not None:
        th = a.tips.filter(tipster=viewer).first()
        out["my_tip_thread"] = th.id if th else None
        out["reported"] = a.reports.filter(reporter=viewer).exists()
        if viewer and hasattr(viewer, "nearby_alert_pref"):
            areas = MS.user_area(viewer.nearby_alert_pref, MS.now())
            aa = MR.area_of(a.lat, a.lng, a.district)
            ds = [MR.distance_km(aa, (x[0], x[1], x[2])) for x in areas]
            ds = [x for x in ds if x is not None]
            out["distance_km"] = round(min(ds)) if ds else None
    return out


def _load(request, pk):
    from .models import MissingAlert
    a = (MissingAlert.objects.filter(pk=pk)
         .select_related("poster", "cosigner", "cosign_asked", "subject_user").first())
    if a is None:
        return None, None, _bad("not_found", 404)
    role = MS.role(request.user, a)
    if role is None:
        return None, None, _bad("not_found", 404)
    # a hidden / pending alert is visible only to the family side + the subject
    if role == "recipient" and a.state in ("hidden", "pending", "removed"):
        return None, None, _bad("not_found", 404)
    return a, role, None


class ConfigView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        on = MS.flag_on(request.user)
        lang = _lang(request)
        fam = [{"id": u.id, "name": u.name or "", "relation": rel}
               for u, rel in MS.family_users(request.user)] if on else []
        cos = [{"id": u.id, "name": u.name or "", "relation": rel}
               for u, rel in MS.cosigner_choices(request.user)] if on else []
        members = []
        if on:
            from .models import FamilyMember
            members = [{"id": m.id, "name": m.name, "relation": m.relation}
                       for m in FamilyMember.objects.filter(user=request.user, circle_member__isnull=True)[:30]]
        return R({
            "enabled": on, "districts": MR.district_list(lang),
            "radius_choices": list(MR.RADIUS_CHOICES), "default_radius": MR.DEFAULT_RADIUS,
            "expiry_days": MR.EXPIRY_DAYS, "renew_days": MR.RENEW_DAYS,
            "max_active": MR.MAX_ACTIVE_PER_POSTER, "max_posts_30d": MR.MAX_POSTS_30D,
            "child_under": MR.CHILD_UNDER, "cooling_days": MR.COOLING_DAYS,
            "report_hide_n": MR.REPORT_HIDE_N, "max_push_per_user_day": MR.MAX_PUSH_PER_USER_DAY,
            "open_location_hours": MR.OPEN_LOCATION_TTL_H, "site": MR.SITE_LINK,
            "optin": MS.pref_json(MS.get_pref(request.user), lang),
            "family_users": fam, "cosigners": cos, "family_members": members,
        })


class ListCreateView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        MS.sweep(limit=20)
        on = MS.flag_on(request.user)
        u = request.user
        near, mine, about, cosign = [], [], [], []
        for a in MS.visible_for(u).select_related("poster", "cosigner", "cosign_asked")[:80]:
            r = MS.role(u, a)
            if r == "subject":
                about.append(alert_json(request, a, r, u))
            elif not on:
                continue
            elif r == "family":
                mine.append(alert_json(request, a, r, u))
            elif r == "cosigner":
                cosign.append(alert_json(request, a, r, u))
            elif r == "recipient" and a.state not in ("hidden", "pending", "removed"):
                near.append(alert_json(request, a, r, u))
        near.sort(key=lambda x: (x["state"] != "active", x.get("distance_km") or 999))
        return R({"enabled": on, "near": near[:40], "mine": mine, "about_me": about,
                  "cosign": cosign, "optin": MS.pref_json(MS.get_pref(u), _lang(request))})

    def post(self, request):
        if not MS.flag_on(request.user):
            return _off()
        a, err = MS.create(request.user, request.data if isinstance(request.data, dict) else {})
        if err:
            status = 429 if err["reason"] in ("too_many_active", "too_many_posts") else (
                403 if err["reason"] in ("banned", "not_family", "cooling") else 400)
            return R({"ok": False, **err}, status=status)
        return R({"ok": True, "alert": alert_json(request, a, "family", request.user),
                  "needs": None if a.state == "active" else "cosign"}, status=201)


class DetailView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        a, role, err = _load(request, pk)
        if err:
            return err
        if role != "subject" and not MS.flag_on(request.user):
            return _off()
        return R({"ok": True, "alert": alert_json(request, a, role, request.user)})


class _Act(APIView):
    permission_classes = [IsAuthenticated]
    roles = ("family",)
    gated = True

    def post(self, request, pk):
        if self.gated and not MS.flag_on(request.user):
            return _off()
        a, role, err = _load(request, pk)
        if err:
            return err
        if role not in self.roles:
            return _bad("forbidden", 403)
        body = request.data if isinstance(request.data, dict) else {}
        res = self.act(request, a, role, body)
        if res:
            return res
        a.refresh_from_db()
        return R({"ok": True, "alert": alert_json(request, a, MS.role(request.user, a), request.user)})


class FoundView(_Act):
    def act(self, request, a, role, body):
        if a.state not in ("active", "pending", "hidden"):
            return _bad("not_active", 409)
        a.share_agreed = body.get("share_ok") is True
        MS.end(a, "found", "family", actor=request.user)
        return None


class CloseView(_Act):
    def act(self, request, a, role, body):
        if a.state not in ("active", "pending", "hidden"):
            return _bad("not_active", 409)
        MS.end(a, "closed", "family", actor=request.user)
        return None


class RenewView(_Act):
    def act(self, request, a, role, body):
        err = MS.renew(a, body)
        return _bad(err["reason"], 409) if err else None


class GdView(_Act):
    def act(self, request, a, role, body):
        if a.state not in ("pending", "active"):
            return _bad("not_active", 409)
        err = MS.add_gd(a, body)
        return R({"ok": False, **err}, status=400) if err else None


class CosignView(_Act):
    roles = ("cosigner",)

    def act(self, request, a, role, body):
        err = MS.cosign(a, request.user, body.get("confirm") is True)
        return _bad(err, 403) if err else None


class SafeView(_Act):
    roles = ("subject",)
    gated = False    # autonomy: never hidden behind a flag

    def act(self, request, a, role, body):
        err = MS.say_safe(a, request.user)
        return _bad(err, 409) if err else None


class ReportView(_Act):
    roles = ("recipient", "subject")

    def act(self, request, a, role, body):
        status, hidden = MS.report(a, request.user, str(body.get("reason") or ""),
                                   body.get("note"))
        if status == "rate_limited":
            return _bad("rate_limited", 429)
        return R({"ok": True, "status": status, "hidden": hidden})


def _thread_json(th, lang, for_family):
    return {"id": th.id, "alert_id": th.alert_id,
            "tipster": MS.tipster_label(th, lang) if for_family else None,
            "share_identity": th.share_identity,
            "tipster_phone": (th.tipster.phone or "") if (for_family and th.share_identity) else None,
            "unread": th.family_unread if for_family else th.tipster_unread,
            "last_at": _iso(th.last_at),
            "messages": [{"id": m.id, "by_family": m.by_family, "text": m.text,
                          "at": _iso(m.at),
                          "point": ({"lat": m.lat, "lng": m.lng} if m.lat is not None else None)}
                         for m in th.messages.all()[:200]]}


class TipsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        if not MS.flag_on(request.user):
            return _off()
        a, role, err = _load(request, pk)
        if err:
            return err
        lang = _lang(request)
        if MS.is_tip_family(request.user, a):
            threads = list(a.tips.select_related("tipster").all()[:100])
            a.tips.update(family_unread=0)
            return R({"ok": True, "family": True,
                      "threads": [_thread_json(t, lang, True) for t in threads]})
        th = a.tips.filter(tipster=request.user).first()
        if th:
            th.tipster_unread = 0
            th.save(update_fields=["tipster_unread"])
        return R({"ok": True, "family": False,
                  "threads": [_thread_json(th, lang, False)] if th else []})

    def post(self, request, pk):
        if not MS.flag_on(request.user):
            return _off()
        a, role, err = _load(request, pk)
        if err:
            return err
        if role not in ("recipient", "subject"):
            return _bad("forbidden", 403)
        th, e = MS.tip(a, request.user, request.data if isinstance(request.data, dict) else {})
        if e:
            return _bad(e, 429 if e == "rate_limited" else 400)
        return R({"ok": True, "thread": _thread_json(th, _lang(request), False)}, status=201)


class ThreadView(APIView):
    permission_classes = [IsAuthenticated]

    def _get(self, request, tid):
        from .models import MissingTipThread
        th = (MissingTipThread.objects.filter(pk=tid)
              .select_related("alert", "tipster", "alert__poster").first())
        if th is None:
            return None, None
        if th.tipster_id == request.user.id:
            return th, False
        if MS.is_tip_family(request.user, th.alert):
            return th, True
        return None, None

    def get(self, request, tid):
        if not MS.flag_on(request.user):
            return _off()
        th, fam = self._get(request, tid)
        if th is None:
            return _bad("not_found", 404)
        if fam:
            th.family_unread = 0
        else:
            th.tipster_unread = 0
        th.save(update_fields=["family_unread", "tipster_unread"])
        return R({"ok": True, "family": fam, "alert_state": th.alert.state,
                  "thread": _thread_json(th, _lang(request), fam)})

    def post(self, request, tid):
        if not MS.flag_on(request.user):
            return _off()
        th, fam = self._get(request, tid)
        if th is None:
            return _bad("not_found", 404)
        body = request.data if isinstance(request.data, dict) else {}
        if fam:
            e = MS.family_reply(th, request.user, body.get("text"))
            if e:
                return _bad(e, 429 if e == "rate_limited" else 400)
        else:
            _th, e = MS.tip(th.alert, request.user, body)
            if e:
                return _bad(e, 429 if e == "rate_limited" else 400)
        th.refresh_from_db()
        return R({"ok": True, "thread": _thread_json(th, _lang(request), fam)})


class NearbyPrefView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        return R({"ok": True, "pref": MS.pref_json(MS.get_pref(request.user), _lang(request)),
                  "districts": MR.district_list(_lang(request))})

    def post(self, request):
        body = request.data if isinstance(request.data, dict) else {}
        turning_off = body.get("enabled") is False
        if not turning_off and not MS.flag_on(request.user):
            return _off()
        if body.get("enabled") is True and not (MR.district(body.get("district") or "")
                                                 or body.get("lat") is not None
                                                 or MS.get_pref(request.user).district):
            return _bad("area_required")
        p = MS.set_pref(request.user, body)
        MS.log_event("optin" if p.enabled else "optout", None, request.user)
        return R({"ok": True, "pref": MS.pref_json(p, _lang(request))})


class WhereIAmView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        if not MS.flag_on(request.user):
            return _off()
        body = request.data if isinstance(request.data, dict) else {}
        e = MS.where_i_am(request.user, body.get("lat"), body.get("lng"))
        if e:
            return _bad(e, 409 if e == "not_opted_in" else 400)
        return R({"ok": True})
