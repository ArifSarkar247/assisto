"""cctvarm — the API of the automatic guard (core/logic/cctv_arm.py).

Owner (behind the watchman flag, like every watchman view):
  GET/PUT shop/sites/<id>/arm   settings, live status, members, cameras, log
Family member (their OWN consent and their OWN location only):
  GET  shop/arm/mine            sites that asked me; my yes/no; Home point
                                only after I said yes
  POST shop/arm/consent         {site, consent: true|false} — any time
  POST shop/arm/presence        {reports: [{site, distance_m, accuracy_m}]}
                                distance only — never coordinates
  GET  shop/arm/sos-live        cameras an SOS opened for me right now
"""
import logging

from django.utils import timezone
from rest_framework.response import Response

from .i18n import req_lang, pick
from . import shop_views as SV
from .logic import cctv_arm as ARM
from .watchman_views import _OwnerBase

log = logging.getLogger("assisto.shop")


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


def _uid_list(v, limit=32):
    out = []
    for x in (v if isinstance(v, list) else []):
        if isinstance(x, bool):
            continue
        try:
            out.append(int(x))
        except (TypeError, ValueError):
            continue
    return out[:limit]


def _home_places(user):
    from .models import SavedPlace
    from .logic import journey_dest as JD
    rows = [p for p in SavedPlace.objects.filter(user=user)
            if p.lat is not None and p.lng is not None]
    rows.sort(key=lambda p: 0 if JD.place_kind(p.label) == "home" else 1)
    return [{"id": p.id, "name": p.name or p.label, "home": JD.place_kind(p.label) == "home"}
            for p in rows]


def _candidates(site, arm):
    """Owner's accepted My Circle people + the site's viewers, family first."""
    from . import family_alerts as FA
    from .logic import circle_family as CF
    out, seen = [], set(arm["members"].keys()) | {str(site.owner_id)}
    try:
        for u, m in FA.consenting_members(site.owner):
            if str(u.pk) in seen:
                continue
            g, _auto = CF.effective_group(getattr(m, "circle_group", ""),
                                          getattr(m, "relation", ""))
            seen.add(str(u.pk))
            out.append({"uid": u.pk, "name": m.name or u.name or "",
                        "family": g == "family"})
    except Exception:
        log.exception("cctvarm candidates failed")
    for v in site.viewers.select_related("user"):
        if str(v.user_id) not in seen:
            seen.add(str(v.user_id))
            out.append({"uid": v.user_id, "name": v.user.name or "", "family": True})
    out.sort(key=lambda r: (not r["family"], r["name"]))
    return out


def _state_row(arm, now):
    st = arm.get("state") or {}
    fam = bool(st.get("fam_armed") and arm["family_on"])
    closed = bool(st.get("closed_armed") and arm["closed_on"])
    summary = st.get("summary") or ("off" if not arm["family_on"] else "unknown")
    if arm["family_on"]:
        summary, _home = ARM.summarize(arm["members"], now)
    return {"auto_armed": fam or closed,
            "reason": "family_away" if fam else ("shop_closed" if closed else ""),
            "summary": summary,
            "privacy": bool(st.get("privacy")) and arm["privacy_on"] and arm["family_on"],
            "eod_until": st.get("eod_until") if closed else None,
            "sos_until": (arm.get("sos") or {}).get("until") if ARM.sos_active(arm, now) else None}


def _member_rows(arm, now, me_id):
    from .models import User
    ids = [int(k) for k in arm["members"].keys() if k.isdigit()]
    names = {u.pk: u.name or "" for u in User.objects.filter(pk__in=ids)}
    rows = []
    for k, m in arm["members"].items():
        uid = int(k) if k.isdigit() else 0
        rows.append({"uid": uid, "name": names.get(uid, ""), "consent": bool(m.get("consent")),
                     "state": ARM.member_state(m, now) if m.get("consent") else "no_consent",
                     "at": m.get("at") if m.get("consent") else None,
                     "is_me": uid == me_id})
    rows.sort(key=lambda r: (not r["is_me"], r["name"]))
    return rows


def _cameras(site, arm, now):
    out = []
    for c in site.cameras.filter(enabled=True):
        nm = arm["nomove"].get(str(c.id)) or {}
        out.append({"id": c.id, "name": c.name or "", "online": SV.is_online(c.last_seen, now),
                    "indoor": c.id in arm["indoor"],
                    "nomove": {"on": bool(nm.get("on")),
                               "from": nm.get("from") or ARM.NOMOVE_FROM_DEFAULT,
                               "by": nm.get("by") or ARM.NOMOVE_BY_DEFAULT,
                               "people": _uid_list(nm.get("people"), ARM.MAX_NOMOVE_PEOPLE)}})
    return out


def owner_row(site, request, now=None):
    now = now or timezone.now()
    lang = req_lang(request)
    arm = ARM.arm_of(site)
    hours = site.hours if isinstance(site.hours, dict) else {}
    return {
        "site": site.id, "name": site.name, "kind": site.kind,
        "config": {"family_on": arm["family_on"], "radius_m": arm["radius_m"],
                   "exit_m": arm["radius_m"] + ARM.EXIT_EXTRA_M,
                   "privacy_on": arm["privacy_on"], "closed_on": arm["closed_on"],
                   "sos_live": arm["sos_live"],
                   "home": ({"name": arm["home"]["name"], "place_id": arm["home"].get("place_id")}
                            if arm["home"] else None)},
        "status": _state_row(arm, now),
        "members": _member_rows(arm, now, request.user.pk),
        "candidates": _candidates(site, arm),
        "cameras": _cameras(site, arm, now),
        "home_places": _home_places(request.user),
        "hours_set": bool(hours.get("open") and hours.get("close")),
        "log": [{"at": x.get("at"), "what": x.get("what"),
                 "text": x.get("en") if lang == "en" else x.get("bn")}
                for x in arm["log"][:20]],
        "rules": {"radius_bounds": list(ARM.RADIUS_BOUNDS_M),
                  "stale_min": ARM.STALE_MIN, "dwell_min": ARM.ARM_DWELL_MIN,
                  "hold_min": ARM.HOLD_MIN, "sos_live_min": ARM.SOS_LIVE_MIN},
    }


def _invite_push(site, uid):
    try:
        from .models import User
        from . import push
        u = User.objects.filter(pk=uid).first()
        if u is None:
            return
        who = site.owner.name or ""
        push.safe_push(
            u, "shop_alert",
            "%s জানতে চান: আপনি বাড়িতে আছেন কি না দিয়ে ক্যামেরা পাহারা চলবে?" % (who or "একজন"),
            "%s asks: may the camera guard use whether you are at home?" % (who or "Someone"),
            "আপনি হ্যাঁ বললে তবেই। যেকোনো সময় বন্ধ করা যায়।",
            "Only if you say yes. You can stop any time.",
            data={"site_id": site.id, "route": "watchman", "notice": "arm_invite"})
    except Exception:
        pass


class SiteArmView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        return Response(owner_row(s, request))

    def put(self, request, pk):
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        d = request.data if isinstance(request.data, dict) else {}
        now = timezone.now()
        cam_ids = set(s.cameras.values_list("id", flat=True))
        allowed = ARM.allowed_people(s)
        home = None
        if "home_place" in d:
            from .models import SavedPlace
            try:
                p = SavedPlace.objects.filter(pk=int(d.get("home_place")),
                                              user=request.user).first()
            except (TypeError, ValueError):
                p = None
            if p is None or p.lat is None or p.lng is None:
                return _err(lang, "বাড়ির জায়গাটি পাওয়া যায়নি — আগে নিরাপদ যাত্রায় 'বাড়ি' সেভ করুন।",
                            "That Home place was not found — save 'Home' in Safe Journey first.",
                            status=422, code="bad_home")
            home = {"lat": p.lat, "lng": p.lng, "name": p.name or p.label, "place_id": p.id}
        if d.get("family_on") is True and home is None and not ARM.arm_of(s)["home"]:
            places = _home_places(request.user)
            if not places:
                return _err(lang, "আগে 'বাড়ি' জায়গাটি সেভ করুন (নিরাপদ যাত্রা → জায়গা)।",
                            "Save your 'Home' place first (Safe Journey → Places).",
                            status=422, code="no_home")
            from .models import SavedPlace
            p = SavedPlace.objects.get(pk=places[0]["id"])
            home = {"lat": p.lat, "lng": p.lng, "name": p.name or p.label, "place_id": p.id}
        invited = []
        events = []

        def apply(a):
            del invited[:]
            del events[:]
            for k in ("family_on", "privacy_on", "closed_on", "sos_live"):
                if isinstance(d.get(k), bool):
                    a[k] = d[k]
            if "radius_m" in d:
                a["radius_m"] = ARM.clamp_radius(d.get("radius_m"))
            if home is not None:
                a["home"] = home
            if "indoor" in d:
                a["indoor"] = [i for i in _uid_list(d.get("indoor")) if i in cam_ids]
            for uid in _uid_list(d.get("invite"), ARM.MAX_MEMBERS):
                if uid in allowed and str(uid) not in a["members"] and \
                        len(a["members"]) < ARM.MAX_MEMBERS:
                    a["members"][str(uid)] = {"consent": False, "invited": ARM.iso(now)}
                    if uid != request.user.pk:
                        invited.append(uid)
            for uid in _uid_list(d.get("remove")):
                a["members"].pop(str(uid), None)
            if isinstance(d.get("my_consent"), bool):
                me = a["members"].setdefault(str(request.user.pk), {"invited": ARM.iso(now)})
                me["consent"] = d["my_consent"]
                me["consent_at"] = ARM.iso(now)
                if not d["my_consent"]:
                    me.pop("state", None)
                    me.pop("at", None)
            nm = d.get("nomove")
            if isinstance(nm, dict):
                for k, v in nm.items():
                    try:
                        cid = int(k)
                    except (TypeError, ValueError):
                        continue
                    if cid not in cam_ids or not isinstance(v, dict):
                        continue
                    f, b = ARM.hm(v.get("from", ARM.NOMOVE_FROM_DEFAULT)), ARM.hm(v.get("by"))
                    if v.get("on") and (f is None or b is None or b <= f):
                        raise ValueError("bad_window")
                    cur = a["nomove"].get(str(cid)) or {}
                    cur.update({"on": bool(v.get("on")),
                                "from": v.get("from", cur.get("from", ARM.NOMOVE_FROM_DEFAULT)),
                                "by": v.get("by", cur.get("by", ARM.NOMOVE_BY_DEFAULT)),
                                "people": [u for u in _uid_list(v.get("people"),
                                                                ARM.MAX_NOMOVE_PEOPLE)
                                           if u in allowed]})
                    cur.pop("last_day", None)        # a new setting checks today again
                    a["nomove"][str(cid)] = cur
            if d.get("privacy_pause") is True and (a.get("state") or {}).get("privacy"):
                st = dict(a["state"])
                st["privacy"], st["privacy_by"] = False, None
                a["state"] = st
                ARM.add_log(a, now, "privacy_paused", (), s.name)
            if d.get("family_on") is False and (a.get("state") or {}).get("fam_armed"):
                st = dict(a["state"])
                st.update(fam_armed=False, privacy=False, all_away_since=None)
                a["state"] = st
                ARM.add_log(a, now, "family_off", (), s.name)
            if d.get("closed_on") is False and (a.get("state") or {}).get("closed_armed"):
                st = dict(a["state"])
                st.update(closed_armed=False, eod_until=None)
                a["state"] = st
        try:
            ARM.mutate(s, apply)
        except ValueError:
            return _err(lang, "সময় ঠিক নয় — 'থেকে' সময়টি 'মধ্যে' সময়ের আগে দিন।",
                        "The times are not valid — 'from' must be before 'by'.",
                        status=422, code="bad_window")
        for uid in invited:
            _invite_push(s, uid)
        return Response(owner_row(s, request, now))

    # the app's ApiClient posts; PUT and POST are the same partial update
    post = put


class MyArmView(_OwnerBase):
    """GET shop/arm/mine — what the family asked of ME."""
    def get(self, request):
        from .models import ShopSite
        now = timezone.now()
        rows = []
        for s in ShopSite.objects.filter(away__has_key="arm").select_related("owner")[:500]:
            arm = ARM.arm_of(s)
            m = arm["members"].get(str(request.user.pk))
            if m is None:
                continue
            ok = bool(m.get("consent"))
            rows.append({"site": s.id, "name": s.name, "owner_name": s.owner.name or "",
                         "is_owner": s.owner_id == request.user.pk,
                         "consent": ok, "state": ARM.member_state(m, now) if ok else "no_consent",
                         "family_on": arm["family_on"],
                         # the Home point only for someone who said yes (the
                         # phone measures the distance itself)
                         "home": ({"lat": arm["home"]["lat"], "lng": arm["home"]["lng"]}
                                  if ok and arm["home"] else None),
                         "radius_m": arm["radius_m"],
                         "exit_m": arm["radius_m"] + ARM.EXIT_EXTRA_M})
        return Response({"sites": rows, "stale_min": ARM.STALE_MIN})


class ArmConsentView(_OwnerBase):
    """POST shop/arm/consent {site, consent} — only for an invited member."""
    def post(self, request):
        from .models import ShopSite
        lang = req_lang(request)
        consent = request.data.get("consent")
        if not isinstance(consent, bool):
            return _err(lang, "হ্যাঁ বা না বেছে নিন।", "Choose yes or no.", status=422,
                        code="bad_consent")
        try:
            s = ShopSite.objects.filter(pk=int(request.data.get("site"))).first()
        except (TypeError, ValueError):
            s = None
        if s is None or str(request.user.pk) not in ARM.arm_of(s)["members"]:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        now = timezone.now()

        def apply(a):
            m = a["members"].get(str(request.user.pk))
            if m is None:
                return
            m["consent"] = consent
            m["consent_at"] = ARM.iso(now)
            if not consent:                 # withdrawn: forget the last state
                m.pop("state", None)
                m.pop("at", None)
        ARM.mutate(s, apply)
        return Response({"ok": True, "consent": consent, "message": pick(
            lang,
            "ধন্যবাদ — অ্যাপ খুললে আপনার ফোন শুধু জানাবে আপনি বাড়ির কাছে কি না।"
            if consent else "বন্ধ হয়েছে — আপনার অবস্থান আর ব্যবহার হবে না।",
            "Thanks — when you open the app, your phone only tells whether you are near Home."
            if consent else "Stopped — your location is no longer used.")})


class ArmPresenceView(_OwnerBase):
    """POST shop/arm/presence {reports: [{site, distance_m, accuracy_m}]} —
    the phone measured the distance to Home itself; only that number comes
    here, and only the derived home/away state is kept."""
    def post(self, request):
        from .models import ShopSite
        reps = request.data.get("reports") if isinstance(request.data, dict) else None
        now = timezone.now()
        out = []
        for r in (reps if isinstance(reps, list) else [])[:10]:
            if not isinstance(r, dict):
                continue
            try:
                s = ShopSite.objects.filter(pk=int(r.get("site"))).first()
            except (TypeError, ValueError):
                s = None
            if s is None:
                continue
            m = ARM.arm_of(s)["members"].get(str(request.user.pk))
            if not m or not m.get("consent"):
                out.append({"site": s.id, "state": "no_consent"})
                continue
            ARM.mutate(s, lambda a, r=r: ARM.set_member_reading(
                a, request.user.pk, r.get("distance_m"), r.get("accuracy_m"), now, "phone"))
            m = ARM.arm_of(s)["members"].get(str(request.user.pk)) or {}
            out.append({"site": s.id, "state": ARM.member_state(m, now)})
        return Response({"sites": out})


class SosLiveView(_OwnerBase):
    """GET shop/arm/sos-live — the home cameras an SOS opened for me."""
    def get(self, request):
        now = timezone.now()
        rows = []
        from .models import User
        for s, arm in ARM.sos_grants(request.user, now):
            by = User.objects.filter(pk=(arm["sos"] or {}).get("by")).first()
            cams = [{"id": c.id, "name": c.name or "",
                     "online": SV.is_online(c.last_seen, now),
                     "live": "live" in ((c.device_info or {}).get("caps") or [])}
                    for c in s.cameras.filter(enabled=True)]
            rows.append({"site": s.id, "name": s.name,
                         "by_name": (by.name if by else "") or "",
                         "until": arm["sos"].get("until"), "cameras": cams})
        return Response({"grants": rows, "minutes": ARM.SOS_LIVE_MIN})
