"""cctvteam (W11, CCTV audit F1 F3 F4 F5 + I) — roles enforced on the server,
multi-site grid, fresh stills, time-limited share links, the access log and
the private neighbourhood watch.

The heart of it: a GUARD allowed only the gate camera can NOT fetch any other
camera's alert list rows, alert detail, evidence, clip, still, live view,
grid tile, overview row or whole-site report — and is not pushed its alerts.
Staff (is_staff / superuser) have no path to anyone's cameras.
"""
import atexit
import io
import shutil
import tempfile
from datetime import timedelta
from unittest import mock

from django.core.files.base import ContentFile
from django.test import SimpleTestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from core.logic import cctv_team as CT
from core.models import User

_MEDIA = tempfile.mkdtemp(prefix="cctvteam-media-")
atexit.register(shutil.rmtree, _MEDIA, True)


def _jpeg(w=320, h=180, color=(30, 80, 140)):
    from PIL import Image
    b = io.BytesIO()
    Image.new("RGB", (w, h), color).save(b, "JPEG")
    return b.getvalue()


# ============================================================ pure rules
class PureTests(SimpleTestCase):
    def test_roles_and_scope(self):
        self.assertEqual(CT.clean_role("guard", [3, 3], [3, 4]), ("guard", [3]))
        self.assertEqual(CT.clean_role(None, None, [3]), ("family", []))
        for args, code in ((("boss", [], [1]), "bad_role"),
                           (("guard", [], [1]), "guard_needs_camera"),
                           (("family", [9], [1]), "unknown_camera"),
                           (("family", "1", [1]), "bad_cameras"),
                           (("family", [True], [1]), "bad_cameras")):
            with self.assertRaises(CT.TeamError) as cm:
                CT.clean_role(*args)
            self.assertEqual(cm.exception.code, code)
        self.assertIsNone(CT.scope_of("family", []))
        self.assertEqual(CT.scope_of("guard", [5]), frozenset({5}))
        self.assertEqual(CT.scope_of("guard", []), frozenset())   # sees nothing
        self.assertTrue(CT.camera_allowed(None, None))
        self.assertFalse(CT.camera_allowed(frozenset({5}), None))
        self.assertFalse(CT.camera_allowed(frozenset({5}), 6))
        self.assertTrue(CT.camera_allowed(frozenset({5}), 5))
        self.assertTrue(CT.can_mark("manager") and not CT.can_mark("guard"))

    def test_share_and_watch_bounds(self):
        self.assertEqual(CT.share_hours(1), 1)
        self.assertEqual(CT.share_hours("72"), 72)
        for bad in (0, 73, "x", True, None):
            with self.assertRaises(CT.TeamError):
                CT.share_hours(bad)
        with self.assertRaises(CT.TeamError):
            CT.share_cameras([], [1])
        self.assertEqual(CT.watch_hours(None), 24)
        with self.assertRaises(CT.TeamError):
            CT.watch_hours(5)
        now = timezone.now()
        self.assertEqual(CT.link_state(None, now + timedelta(hours=1), now), "active")
        self.assertEqual(CT.link_state(None, now, now), "expired")
        self.assertEqual(CT.link_state(now, now + timedelta(hours=1), now), "revoked")
        self.assertEqual(CT.camera_status(False, True, now), "off")
        self.assertEqual(CT.camera_status(True, False, None), "never")
        self.assertEqual(CT.report_reason("weird"), "other")
        self.assertEqual(len(CT.clean_caption("x" * 500)), CT.CAPTION_MAX)


# ============================================================ API
@override_settings(MEDIA_ROOT=_MEDIA)
class _Base(APITestCase):
    def setUp(self):
        from core import feature_flags as FF
        from core.models import FeatureFlag, ShopCamera, ShopEvent, ShopSite
        mk = User.objects.create_user
        self.owner = mk(name="Rahim", phone="01710009001", password="pw")
        self.guard = mk(name="Gate guard", phone="01710009002", password="pw")
        self.family = mk(name="Karima", phone="01710009003", password="pw")
        self.manager = mk(name="Manager", phone="01710009004", password="pw")
        self.stranger = mk(name="Stranger", phone="01710009005", password="pw")
        self.staff = mk(name="Staff", phone="01710009006", password="pw")
        self.staff.is_staff = True
        self.staff.is_superuser = True
        self.staff.save()
        for u in (self.owner, self.guard, self.family, self.manager):
            u.language = "en"
            u.save()
        self.pushes = []
        p = mock.patch("core.push.safe_push",
                       side_effect=lambda *a, **k: self.pushes.append((a, k)) or True)
        p.start()
        self.addCleanup(p.stop)
        FF.ensure_seeded()
        FeatureFlag.objects.filter(key__in=("home_watchman", "cctv_watchman")).update(
            enabled_all=True, enabled_play=True)
        FF.invalidate()
        self.addCleanup(FF.invalidate)
        now = timezone.now()
        self.site = ShopSite.objects.create(owner=self.owner, name="Main shop",
                                            kind="home", last_seen=now)
        live = {"caps": ["live"], "platform": "android"}
        self.gate = ShopCamera.objects.create(site=self.site, name="Gate", vendor="onvif",
                                              kind="shopbox", last_seen=now, device_info=live)
        self.till = ShopCamera.objects.create(site=self.site, name="Till", vendor="onvif",
                                              kind="shopbox", last_seen=now, device_info=live)

        def ev(cam, etype="person_detected"):
            e = ShopEvent(site=self.site, camera=cam, type=etype, confidence=0.8)
            e.snapshot.save("s.jpg", ContentFile(_jpeg()), save=False)
            e.save()
            return e
        self.ev_gate = ev(self.gate)
        self.ev_till = ev(self.till, "hand_in_cash_zone")
        self.ev_site = ShopEvent.objects.create(site=self.site, camera=None,
                                                type="eod_mismatch", confidence=0.5)
        self.c = {u: self._client(u) for u in ("owner", "guard", "family", "manager",
                                               "stranger", "staff")}
        r = self.c["owner"].post("/api/v1/shop/sites/%d/viewers" % self.site.id,
                                 {"phone": self.guard.phone, "role": "guard",
                                  "cameras": [self.gate.id]}, format="json")
        self.assertIn(r.status_code, (200, 201), r.data)
        self.assertEqual((r.data["role"], r.data["cameras"]), ("guard", [self.gate.id]))
        r = self.c["owner"].post("/api/v1/shop/sites/%d/viewers" % self.site.id,
                                 {"phone": self.family.phone}, format="json")
        self.assertEqual(r.data["role"], "family")
        self.assertTrue(r.data["all_cameras"])
        r = self.c["owner"].post("/api/v1/shop/sites/%d/viewers" % self.site.id,
                                 {"phone": self.manager.phone, "role": "manager"},
                                 format="json")
        self.assertEqual(r.data["role"], "manager")

    def _client(self, name):
        c = APIClient()
        c.force_authenticate(getattr(self, name))
        return c


class GuardScopeTests(_Base):
    def test_guard_sees_only_the_gate_on_every_endpoint(self):
        g = self.c["guard"]
        sid = self.site.id
        # alert list
        r = g.get("/api/v1/shop/events?site=%d" % sid)
        self.assertEqual(r.status_code, 200)
        self.assertEqual([e["id"] for e in r.data["events"]], [self.ev_gate.id])
        self.assertEqual(r.data["team_role"], "guard")
        # even when asking for the other camera by filter
        r = g.get("/api/v1/shop/events?site=%d&camera=%d" % (sid, self.till.id))
        self.assertEqual(r.data["events"], [])
        # alert detail / evidence / clip of another camera: 404
        for path in ("/api/v1/shop/events/%d", "/api/v1/shop/events/%d/evidence",
                     "/api/v1/shop/events/%d/clip"):
            self.assertEqual(g.get(path % self.ev_till.id).status_code, 404, path)
            self.assertEqual(g.get(path % self.ev_site.id).status_code, 404, path)
        self.assertEqual(g.get("/api/v1/shop/events/%d" % self.ev_gate.id).status_code, 200)
        # stills
        self.assertEqual(g.get("/api/v1/shop/cameras/%d/still" % self.till.id).status_code, 404)
        self.assertEqual(g.post("/api/v1/shop/cameras/%d/still" % self.till.id).status_code, 404)
        r = g.get("/api/v1/shop/cameras/%d/still" % self.gate.id)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["still_url"])
        # live
        r = g.post("/api/v1/shop/live/start", {"camera": self.till.id}, format="json")
        self.assertEqual(r.status_code, 404)
        r = g.post("/api/v1/shop/live/start", {"camera": self.gate.id}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["error"], "viewer_live_off")
        # overview + grid
        r = g.get("/api/v1/shop/watchman")
        site = [s for s in r.data["sites"] if s["id"] == sid][0]
        self.assertEqual([c["id"] for c in site["cameras_list"]], [self.gate.id])
        self.assertEqual(site["open_alerts"], 1)
        self.assertEqual(site["team_role"], "guard")
        r = g.get("/api/v1/shop/grid")
        self.assertEqual(r.status_code, 200)
        self.assertEqual([c["id"] for c in r.data["sites"][0]["cameras"]], [self.gate.id])
        # whole-site report and marking: refused
        r = g.get("/api/v1/shop/sites/%d/guard/report" % sid)
        self.assertEqual(r.status_code, 403)
        r = g.post("/api/v1/shop/events/%d/mark" % self.ev_gate.id, {"status": "checked"},
                   format="json")
        self.assertEqual(r.status_code, 404)
        # owner-only screens
        for path in ("/api/v1/shop/sites/%d/access-log", "/api/v1/shop/sites/%d/share-links",
                     "/api/v1/shop/sites/%d/roles", "/api/v1/shop/sites/%d/viewers"):
            self.assertEqual(g.get(path % sid).status_code, 404, path)

    def test_live_only_when_owner_allows_and_only_in_scope(self):
        r = self.c["owner"].put("/api/v1/shop/sites/%d/viewers/%d/role"
                                % (self.site.id, self.guard.id),
                                {"role": "guard", "cameras": [self.gate.id], "live_ok": True},
                                format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["live_ok"])
        g = self.c["guard"]
        r = g.post("/api/v1/shop/live/start", {"camera": self.gate.id}, format="json")
        self.assertNotIn(r.status_code, (403, 404), r.data)
        r = g.post("/api/v1/shop/live/start", {"camera": self.till.id}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_push_recipients_follow_the_role(self):
        from core import cctv_team_views as CTV
        gate_people = {u.pk for u in CTV.viewer_users(self.site, self.gate.id)}
        till_people = {u.pk for u in CTV.viewer_users(self.site, self.till.id)}
        site_people = {u.pk for u in CTV.viewer_users(self.site, None)}
        self.assertIn(self.guard.pk, gate_people)
        self.assertNotIn(self.guard.pk, till_people)
        self.assertNotIn(self.guard.pk, site_people)
        self.assertTrue({self.family.pk, self.manager.pk} <= till_people)
        # a real camera ingest: the guard is not pushed the till's alert
        from core.models import ShopCamera
        dev = APIClient()
        dev.credentials(HTTP_X_SHOP_TOKEN=ShopCamera.objects.get(pk=self.till.id).camera_token)
        self.pushes.clear()
        dev.post("/api/v1/shop/ingest", {"type": "person_detected",
                                         "signals": {"human": True}}, format="json")
        pushed_to = {a[0].pk for a, k in self.pushes if a and hasattr(a[0], "pk")}
        self.assertNotIn(self.guard.pk, pushed_to)

    def test_role_validation(self):
        o = self.c["owner"]
        url = "/api/v1/shop/sites/%d/viewers/%d/role" % (self.site.id, self.guard.id)
        r = o.put(url, {"role": "guard", "cameras": []}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (422, "guard_needs_camera"))
        r = o.put(url, {"role": "boss"}, format="json")
        self.assertEqual(r.data["error"], "bad_role")
        r = o.put(url, {"role": "family", "cameras": [999999]}, format="json")
        self.assertEqual(r.data["error"], "unknown_camera")
        # another owner can't touch my viewers
        r = self.c["stranger"].put(url, {"role": "family"}, format="json")
        self.assertEqual(r.status_code, 404)
        r = o.get("/api/v1/shop/sites/%d/roles" % self.site.id)
        roles = {v["user_id"]: v["role"] for v in r.data["viewers"]}
        self.assertEqual(roles[self.guard.id], "guard")


class ManagerFamilyTests(_Base):
    def test_manager_marks_family_cannot(self):
        r = self.c["manager"].post("/api/v1/shop/events/%d/mark" % self.ev_till.id,
                                   {"status": "false_alarm"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        r = self.c["family"].post("/api/v1/shop/events/%d/mark" % self.ev_till.id,
                                  {"status": "checked"}, format="json")
        self.assertEqual(r.status_code, 404)
        r = self.c["family"].get("/api/v1/shop/events?site=%d" % self.site.id)
        self.assertEqual(len(r.data["events"]), 3)


class NobodyElseTests(_Base):
    def test_stranger_and_staff_see_nothing(self):
        for who in ("stranger", "staff"):
            c = self.c[who]
            self.assertEqual(c.get("/api/v1/shop/events?site=%d" % self.site.id).status_code, 404)
            self.assertEqual(c.get("/api/v1/shop/events/%d" % self.ev_gate.id).status_code, 404)
            self.assertEqual(c.get("/api/v1/shop/cameras/%d/still" % self.gate.id).status_code, 404)
            r = c.post("/api/v1/shop/live/start", {"camera": self.gate.id}, format="json")
            self.assertEqual(r.status_code, 404)
            self.assertEqual(c.get("/api/v1/shop/grid").data["sites"], [])

    def test_flag_off_hides_team_endpoints(self):
        from core import feature_flags as FF
        from core.models import FeatureFlag
        FeatureFlag.objects.filter(key="cctv_watchman").update(enabled_all=False,
                                                               enabled_play=False)
        FF.invalidate()
        r = self.c["guard"].get("/api/v1/shop/grid")
        self.assertEqual(r.status_code, 403)


class AccessLogTests(_Base):
    def test_owner_sees_who_viewed_what(self):
        g = self.c["guard"]
        g.get("/api/v1/shop/events?site=%d" % self.site.id)
        g.get("/api/v1/shop/events/%d" % self.ev_gate.id)
        g.get("/api/v1/shop/cameras/%d/still" % self.gate.id)
        g.get("/api/v1/shop/cameras/%d/still" % self.gate.id)       # deduped
        self.c["owner"].get("/api/v1/shop/events?site=%d" % self.site.id)  # not logged
        r = self.c["owner"].get("/api/v1/shop/sites/%d/access-log" % self.site.id)
        self.assertEqual(r.status_code, 200)
        rows = r.data["rows"]
        self.assertTrue(all(x["user_id"] == self.guard.id for x in rows), rows)
        acts = sorted(x["action"] for x in rows)
        self.assertEqual(acts, ["alert", "alerts", "still"])
        self.assertEqual([x["camera_name"] for x in rows if x["action"] == "still"], ["Gate"])


class StillTests(_Base):
    def setUp(self):
        super().setUp()
        self.gate.vendor = "imou"
        self.gate.vendor_ref = "DEV1:0"
        self.gate.save()

    def test_fresh_still_rate_limited_and_honest(self):
        o = self.c["owner"]
        with mock.patch("core.cctv_team_views.vendor_still",
                        return_value=(_jpeg(color=(200, 10, 10)), None)) as vs:
            r = o.post("/api/v1/shop/cameras/%d/still" % self.gate.id)
            self.assertEqual(r.status_code, 200, r.data)
            self.assertTrue(r.data["fresh"])
            self.assertEqual(r.data["source"], "camera")
            self.assertTrue(r.data["still_url"])
            r = o.post("/api/v1/shop/cameras/%d/still" % self.gate.id)
            self.assertEqual(r.data["reason"], "too_soon")
            self.assertEqual(vs.call_count, 1)
        # a camera no cloud can photograph: the last alert photo, said so
        r = o.post("/api/v1/shop/cameras/%d/still" % self.till.id)
        self.assertEqual((r.data["reason"], r.data["source"]), ("unsupported", "alert"))
        self.assertFalse(r.data["fresh_supported"])
        self.assertTrue(r.data["detail"])

    def test_retention_zero_never_stores(self):
        from core.models import ShopCamera
        self.site.snapshot_retention_days = 0
        self.site.save()
        with mock.patch("core.cctv_team_views.vendor_still", return_value=(_jpeg(), None)):
            r = self.c["owner"].post("/api/v1/shop/cameras/%d/still" % self.gate.id)
        self.assertTrue(r.data["inline_jpeg"])
        self.assertFalse(ShopCamera.objects.get(pk=self.gate.id).still)

    def test_grid_tiles(self):
        r = self.c["owner"].get("/api/v1/shop/grid")
        self.assertEqual(r.status_code, 200)
        s = r.data["sites"][0]
        self.assertEqual(s["role"], "owner")
        tiles = {c["id"]: c for c in s["cameras"]}
        self.assertEqual(set(tiles), {self.gate.id, self.till.id})
        self.assertEqual(tiles[self.till.id]["still_source"], "alert")
        self.assertTrue(tiles[self.till.id]["still_url"])
        self.assertEqual(tiles[self.till.id]["status"], "online")
        self.assertTrue(tiles[self.gate.id]["fresh_supported"])
        self.assertTrue(tiles[self.gate.id]["live_ok"])
        self.assertEqual(r.data["live_max"], 2)


class ShareLinkTests(_Base):
    def _make(self, **body):
        b = {"cameras": [self.gate.id], "hours": 1, "label": "Cousin"}
        b.update(body)
        return self.c["owner"].post("/api/v1/shop/sites/%d/share-links" % self.site.id,
                                    b, format="json")

    def test_link_lifecycle_view_only_scoped_revocable(self):
        r = self._make()
        self.assertEqual(r.status_code, 201, r.data)
        self.assertIn("/c/", r.data["url"])
        self.assertFalse(r.data["audio"])
        token = r.data["url"].rsplit("/c/", 1)[1]
        anon = APIClient()
        r2 = anon.get("/c/%s" % token)
        self.assertEqual(r2.status_code, 200)
        self.assertEqual(r2["X-Robots-Tag"], "noindex, nofollow")
        self.assertIn("Main shop", r2.content.decode())
        d = anon.get("/c/%s/data" % token).json()
        self.assertEqual(d["state"], "active")
        self.assertEqual([c["id"] for c in d["cameras"]], [self.gate.id])
        self.assertFalse(d["audio"])
        img = anon.get("/c/%s/img/%d" % (token, self.gate.id))
        self.assertEqual((img.status_code, img["Content-Type"]), (200, "image/jpeg"))
        # a camera NOT in the link: nothing
        self.assertEqual(anon.get("/c/%s/img/%d" % (token, self.till.id)).status_code, 404)
        # the owner sees the open in the access log + the view count
        log = self.c["owner"].get("/api/v1/shop/sites/%d/access-log" % self.site.id).data
        self.assertIn("link", [x["action"] for x in log["rows"]])
        links = self.c["owner"].get("/api/v1/shop/sites/%d/share-links" % self.site.id).data
        self.assertEqual(links["links"][0]["views"], 1)
        self.assertNotIn("url", links["links"][0])          # token never shown again
        # revoke: stops at once
        r = self.c["owner"].post("/api/v1/shop/share-links/%d/revoke" % r.data["id"])
        self.assertEqual(r.data["state"], "revoked")
        self.assertEqual(anon.get("/c/%s/data" % token).json()["state"], "revoked")
        self.assertEqual(anon.get("/c/%s/img/%d" % (token, self.gate.id)).status_code, 404)

    def test_expiry_bad_token_and_bounds(self):
        from core.models import CctvShareLink
        r = self._make(hours=24)
        token = r.data["url"].rsplit("/c/", 1)[1]
        CctvShareLink.objects.filter(pk=r.data["id"]).update(
            expires_at=timezone.now() - timedelta(seconds=1))
        anon = APIClient()
        self.assertEqual(anon.get("/c/%s/data" % token).json()["state"], "expired")
        self.assertEqual(anon.get("/c/%s/img/%d" % (token, self.gate.id)).status_code, 404)
        self.assertEqual(anon.get("/c/nope/data").status_code, 404)
        self.assertEqual(self._make(hours=73).data["error"], "bad_hours")
        self.assertEqual(self._make(cameras=[]).data["error"], "pick_camera")
        self.assertEqual(self._make(cameras=[999999]).data["error"], "unknown_camera")
        for _ in range(CT.MAX_ACTIVE_LINKS):
            self._make()
        self.assertEqual(self._make().status_code, 409)
        # nobody but the owner may make one
        r = self.c["manager"].post("/api/v1/shop/sites/%d/share-links" % self.site.id,
                                   {"cameras": [self.gate.id], "hours": 1}, format="json")
        self.assertEqual(r.status_code, 404)
        r = self.c["guard"].post("/api/v1/shop/share-links/1/revoke")
        self.assertEqual(r.status_code, 404)


class NeighbourhoodWatchTests(_Base):
    def setUp(self):
        super().setUp()
        from core.models import Community, CommunityGroup, CommunityMember
        self.n1 = User.objects.create_user(name="Neighbour 1", phone="01710009101", password="pw")
        self.n2 = User.objects.create_user(name="Neighbour 2", phone="01710009102", password="pw")
        self.n3 = User.objects.create_user(name="Neighbour 3", phone="01710009103", password="pw")
        com = Community.objects.create(creator=self.owner, name="Road 3 neighbours")
        self.grp = CommunityGroup.objects.create(community=com, creator=self.owner,
                                                 name="Road 3 watch")
        for u, role in ((self.owner, "admin"), (self.n1, "member"), (self.n2, "member"),
                        (self.n3, "member"), (self.guard, "member")):
            CommunityMember.objects.create(community=com, group=self.grp, member=u, role=role)
        pub = Community.objects.create(creator=self.owner, name="Public", is_public=True)
        self.pub_grp = CommunityGroup.objects.create(community=pub, creator=self.owner,
                                                     name="Public group")
        CommunityMember.objects.create(community=pub, group=self.pub_grp, member=self.owner)
        for u in ("n1", "n2", "n3"):
            self.c[u] = self._client(u)

    def _post(self, who="owner", **body):
        b = {"group": self.grp.id, "event": self.ev_gate.id, "caption": "Suspicious bike",
             "confirm": True}
        b.update(body)
        return self.c[who].post("/api/v1/shop/watch/posts", b, format="json")

    def test_share_one_photo_privately_never_public_never_automatic(self):
        groups = self.c["owner"].get("/api/v1/shop/watch/groups").data
        self.assertEqual([g["id"] for g in groups["groups"]], [self.grp.id])   # no public one
        self.assertIn("blur", groups["note"].lower())
        self.assertEqual(self._post(confirm=False).status_code, 422)
        self.assertEqual(self._post(group=self.pub_grp.id).status_code, 404)
        self.pushes.clear()
        r = self._post()
        self.assertEqual(r.status_code, 201, r.data)
        self.assertTrue(r.data["image_url"])
        pushed = {a[0].pk for a, k in self.pushes if a and hasattr(a[0], "pk")}
        self.assertTrue({self.n1.pk, self.n2.pk} <= pushed)
        self.assertNotIn(self.owner.pk, pushed)
        d = self.c["n1"].get("/api/v1/shop/watch/posts?group=%d" % self.grp.id).data
        self.assertEqual([p["id"] for p in d["posts"]], [r.data["id"]])
        self.assertEqual(self.c["stranger"].get(
            "/api/v1/shop/watch/posts?group=%d" % self.grp.id).status_code, 404)

    def test_guard_cannot_share_a_camera_they_cannot_see(self):
        r = self._post(who="guard", event=self.ev_till.id)
        self.assertEqual((r.status_code, r.data["error"]), (404, "no_photo"))
        r = self._post(who="guard", event=None, camera=self.till.id)
        self.assertEqual(r.status_code, 404)
        r = self._post(who="guard", event=self.ev_gate.id)
        self.assertEqual(r.status_code, 201)

    def test_report_block_expire(self):
        from core.models import CctvWatchPost
        pid = self._post().data["id"]
        # block: n1 never sees the owner's posts again
        self.c["n1"].post("/api/v1/shop/watch/block", {"user": self.owner.id}, format="json")
        d = self.c["n1"].get("/api/v1/shop/watch/posts?group=%d" % self.grp.id).data
        self.assertEqual(d["posts"], [])
        # three reports hide it for everyone and delete the photo
        for u in ("n1", "n2"):
            r = self.c[u].post("/api/v1/shop/watch/posts/%d/report" % pid,
                               {"reason": "private"}, format="json")
            self.assertFalse(r.data["hidden_for_all"])
        self.assertEqual(self.c["owner"].post("/api/v1/shop/watch/posts/%d/report" % pid,
                                              {}, format="json").status_code, 409)
        r = self.c["n3"].post("/api/v1/shop/watch/posts/%d/report" % pid, {}, format="json")
        self.assertTrue(r.data["hidden_for_all"])
        p = CctvWatchPost.objects.get(pk=pid)
        self.assertTrue(p.removed)
        self.assertFalse(p.image)
        # expiry deletes the photo too
        pid2 = self._post().data["id"]
        CctvWatchPost.objects.filter(pk=pid2).update(expires_at=timezone.now() - timedelta(seconds=1))
        d = self.c["n2"].get("/api/v1/shop/watch/posts?group=%d" % self.grp.id).data
        self.assertEqual(d["posts"], [])
        p = CctvWatchPost.objects.get(pk=pid2)
        self.assertEqual((p.removed, p.removed_reason, bool(p.image)), (True, "expired", False))

    def test_author_or_admin_deletes(self):
        pid = self._post(who="guard", event=self.ev_gate.id).data["id"]
        self.assertEqual(self.c["n1"].delete("/api/v1/shop/watch/posts/%d" % pid).status_code, 404)
        self.assertEqual(self.c["owner"].delete("/api/v1/shop/watch/posts/%d" % pid).status_code, 200)
