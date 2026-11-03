"""adminsafe (owner 3 Nov 04:22): Owner Admin user stats, support + moderation
actions, server-side restrictions, ban identities, appeals, staff roles and
the HARD privacy wall."""
import re
from datetime import timedelta
from pathlib import Path

from django.core.cache import cache
from django.test import override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import admin_safety as AS
from core import admin_stats
from core.models import (AccountAction, AccountAppeal, ActiveDay, AdminStaffRole,
                         BannedIdentity, Channel, ChannelPost, Device, Document,
                         LinkedDevice, ModerationItem, NotifEvent, OwnerAudit,
                         OwnerSession, PushDeadMark, SupportTicket, User,
                         UserRestriction)
from web.owner import security as S
from web.tests_o2_owner_admin import OwnerBase, SClient, _ot

PW = "pw-user-123"


def _api(user):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.get_or_create(user=user)[0].key)
    return c


def _login(phone, pw=PW):
    return APIClient().post("/api/v1/auth/login", {"identifier": phone, "password": pw},
                            format="json")


class Base(OwnerBase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.ready()
        self.u = User.objects.create_user(name="Rahim", phone="01710001111", password=PW,
                                          email="rahim@example.com")

    def act(self, kind, uid=None, **data):
        d = {"kind": kind, **data}
        return self.post("/owner/users/%d/act" % (uid or self.u.pk), d)


# ================================================================== stats
class StatsTests(Base):
    def test_counts_match_lists_and_definitions(self):
        today = timezone.localdate()
        a = User.objects.create_user(name="A", phone="01710001112", password=PW)
        b = User.objects.create_user(name="B", phone="01710001113", password=PW)
        old = User.objects.create_user(name="Old", phone="01710001114", password=PW)
        User.objects.filter(pk=old.pk).update(date_joined=timezone.now() - timedelta(days=60),
                                             last_active=timezone.now() - timedelta(days=45))
        ActiveDay.objects.create(user=a, day=today, cohort_day=today)
        ActiveDay.objects.create(user=b, day=today - timedelta(days=3), cohort_day=today)
        ActiveDay.objects.create(user=b, day=today - timedelta(days=20), cohort_day=today)
        c = admin_stats.compute()["counts"]
        self.assertEqual(c["active_today"], 1)
        self.assertEqual(c["active_7"], 2)
        self.assertEqual(c["active_30"], 2)
        self.assertEqual(c["inactive_30"], 1)
        self.assertEqual(c["new_today"], User.objects.filter(date_joined__date=today).count())
        self.assertEqual(c["all"], User.objects.count())
        self.assertEqual(c["plan_free"] + c["plan_paid"] + c["plan_trial"], c["all"])
        # every number is a clickable filter of the same queryset
        r = self.c.get("/owner/users", {"f": "active_7"})
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "/owner/users/%d\"" % a.pk)
        self.assertContains(r, "/owner/users/%d\"" % b.pk)
        self.assertNotContains(r, "/owner/users/%d\"" % old.pk)
        self.assertEqual(r.context["total"], 2)
        r = self.c.get("/owner/users", {"f": "inactive_30"})
        self.assertContains(r, "/owner/users/%d\"" % old.pk)
        # exact definitions are on the tiles (hover title) + the chart is SVG
        r = self.c.get("/owner/users")
        self.assertContains(r, 'href="/owner/users?f=active_today" title="')
        self.assertContains(r, "<svg")
        self.assertNotContains(r, "<script>")
        self.assertContains(self.c.get("/owner/"), 'id="user-stats"')

    def test_stats_are_cached_briefly(self):
        admin_stats.cached()
        User.objects.create_user(name="N", phone="01710001119", password=PW)
        self.assertEqual(admin_stats.cached()["counts"]["all"], User.objects.count() - 1)
        self.assertEqual(admin_stats.cached(force=True)["counts"]["all"], User.objects.count())

    def test_likely_uninstalled_from_fcm_dead_token(self):
        from core import push
        Device.objects.create(user=self.u, push_token="tok-a")
        Device.objects.create(user=self.u, push_token="tok-b")
        push._drop_token("tok-a")
        self.assertFalse(PushDeadMark.objects.filter(user=self.u).exists())   # one left
        push._drop_token("tok-b")
        self.assertTrue(PushDeadMark.objects.filter(user=self.u).exists())
        self.assertIn(self.u, admin_stats.queryset("uninstalled"))
        # a new token from the app -> not uninstalled any more
        r = _api(self.u).post("/api/v1/devices/register", {"push_token": "tok-new"},
                              format="json")
        if r.status_code in (200, 201):
            self.assertFalse(PushDeadMark.objects.filter(user=self.u).exists())
        AS.note_token_registered(self.u)
        self.assertNotIn(self.u, admin_stats.queryset("uninstalled"))

    def test_bad_filter_falls_back_to_all(self):
        r = self.c.get("/owner/users", {"f": "nope'><script>"})
        self.assertEqual(r.context["f"], "all")


# ============================================================ user detail
class DetailTests(Base):
    def test_every_view_is_audited_and_shows_facts(self):
        Device.objects.create(user=self.u, push_token="t1", brand="realme", model="RMX3491",
                              app_version="1.2.3")
        SupportTicket.objects.create(user=self.u, message="help me with credits")
        r = self.c.get("/owner/users/%d" % self.u.pk)
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "RMX3491")
        self.assertContains(r, "help me with credits")
        self.assertContains(r, "rahim@example.com")
        a = OwnerAudit.objects.filter(action="user.view", target="user:%d" % self.u.pk)
        self.assertEqual(a.count(), 1)
        self.c.get("/owner/users/%d" % self.u.pk)
        self.assertEqual(a.count(), 2)

    def test_reason_is_required_for_every_action(self):
        for kind in ("warn", "restrict", "suspend", "ban", "force_logout", "remove_content"):
            r = self.act(kind, reason="", days="3", kinds=["stranger_msg"])
            self.assertEqual(r.status_code, 400, kind)
        self.assertFalse(AccountAction.objects.exists())

    def test_owner_cannot_be_actioned(self):
        r = self.act("ban", uid=self.owner.pk, reason="x")
        self.assertEqual(r.status_code, 400)


# ================================================================ actions
class ActionTests(Base):
    def test_warn_notice_and_appeal_flow(self):
        r = self.act("warn", reason="Rude messages in a channel")
        self.assertEqual(r.status_code, 302)
        a = AccountAction.objects.get(user=self.u, kind="warn")
        self.assertTrue(NotifEvent.objects.filter(user=self.u, route="account_standing").exists())
        self.assertTrue(OwnerAudit.objects.filter(action="user.warn").exists())
        api = _api(self.u)
        st = api.get("/api/v1/account/standing").json()
        self.assertEqual(st["notices"][0]["reason"], "Rude messages in a channel")
        self.assertTrue(st["notices"][0]["appealable"])
        self.assertEqual(api.post("/api/v1/account/appeal", {"action_id": a.id, "text": "short"},
                                  format="json").status_code, 400)
        r = api.post("/api/v1/account/appeal",
                     {"action_id": a.id, "text": "I was quoting someone, please check."},
                     format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(api.post("/api/v1/account/appeal",
                                  {"action_id": a.id, "text": "again again again"},
                                  format="json").status_code, 409)
        ap = AccountAppeal.objects.get(user=self.u)
        self.assertContains(self.c.get("/owner/appeals"), "I was quoting someone")
        r = self.post("/owner/appeals/%d/decide" % ap.id, {"decision": "uphold", "note": ""})
        ap.refresh_from_db()
        self.assertEqual(ap.state, "open")                   # reply required
        self.post("/owner/appeals/%d/decide" % ap.id,
                  {"decision": "uphold", "note": "The post was abusive."})
        ap.refresh_from_db()
        self.assertEqual(ap.state, "upheld")
        st = api.get("/api/v1/account/standing").json()
        self.assertEqual(st["notices"][0]["appeal"]["decision_note"], "The post was abusive.")

    def test_restrictions_enforced_server_side(self):
        api = _api(self.u)
        before = {
            "stranger": api.post("/api/v1/messenger/request", {"target_id": 999999},
                                 format="json").status_code,
            "post": api.post("/api/v1/channels/999999/posts", {"text": "hi"},
                             format="json").status_code,
            "join": api.post("/api/v1/communities/join", {"code": "nope"},
                             format="json").status_code,
        }
        self.assertNotIn(403, before.values())
        r = self.act("restrict", reason="Spam to strangers",
                     kinds=["stranger_msg", "channel_post", "community_join"], days="7")
        self.assertEqual(r.status_code, 302)
        self.assertEqual(UserRestriction.objects.filter(user=self.u).count(), 3)
        checks = [
            ("/api/v1/messenger/request", {"target_id": 999999}, "stranger_msg"),
            ("/api/v1/community/message", {"recipient_id": 999999}, "stranger_msg"),
            ("/api/v1/channels/999999/posts", {"text": "hi"}, "channel_post"),
            ("/api/v1/channels", {"name": "x", "handle": "xyzabc"}, "channel_post"),
            ("/api/v1/communities/join", {"code": "nope"}, "community_join"),
            ("/api/v1/community/group/999999/join", {}, "community_join"),
        ]
        for url, body, kind in checks:
            r = api.post(url, body, format="json")
            self.assertEqual(r.status_code, 403, url)
            self.assertEqual(r.json()["reason"], "account_restricted", url)
            self.assertIn("কমিউনিটি" if kind == "community_join" else "", r.json()["detail"])
            self.assertEqual(r.json()["kind"], kind)
            self.assertEqual(r.json()["admin_reason"], "Spam to strangers")
        # other users are not affected
        other = User.objects.create_user(name="O", phone="01710001115", password=PW)
        self.assertNotEqual(_api(other).post("/api/v1/communities/join", {"code": "nope"},
                                             format="json").status_code, 403)
        # a limit with an end date stops by itself
        UserRestriction.objects.filter(user=self.u).update(
            until=timezone.now() - timedelta(minutes=1))
        self.assertNotEqual(api.post("/api/v1/communities/join", {"code": "nope"},
                                     format="json").status_code, 403)

    def test_unrestrict_lifts(self):
        self.act("restrict", reason="spam", kinds=["community_join"])
        self.assertIsNotNone(AS.restricted(self.u, "community_join"))
        self.act("unrestrict", reason="ok now")
        self.assertIsNone(AS.restricted(self.u, "community_join"))

    def test_suspend_n_days_auto_expires_and_shows_reason(self):
        api = _api(self.u)
        LinkedDevice.objects.create(user=self.u, device_id="web-1")
        r = self.act("suspend", reason="Harassment report", days="3")
        self.assertEqual(r.status_code, 302)
        self.u.refresh_from_db()
        self.assertEqual(self.u.account_status, "suspended")
        self.assertFalse(Token.objects.filter(user=self.u).exists())
        self.assertTrue(LinkedDevice.objects.get(device_id="web-1").revoked)
        self.assertEqual(api.get("/api/v1/me").status_code, 401)
        r = _login("01710001111")
        self.assertEqual(r.status_code, 403)
        body = r.json()
        self.assertEqual(body["reason"], "account_blocked")
        self.assertEqual(body["standing"]["status"], "suspended")
        self.assertIsNotNone(body["standing"]["until"])
        self.assertEqual(body["standing"]["notices"][0]["reason"], "Harassment report")
        # appeal without a session, with the signed token from sign-in
        act = AccountAction.objects.get(user=self.u, kind="suspend")
        anon = APIClient()
        self.assertEqual(anon.post("/api/v1/account/appeal/blocked",
                                   {"appeal_token": "forged", "action_id": act.id,
                                    "text": "please check again"}, format="json").status_code, 403)
        r = anon.post("/api/v1/account/appeal/blocked",
                      {"appeal_token": body["appeal_token"], "action_id": act.id,
                       "text": "It was a misunderstanding, please check."}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(AccountAppeal.objects.filter(user=self.u, state="open").count(), 1)
        self.assertEqual(admin_stats.queryset("suspended").count(), 1)
        # end passes -> active again on the next sign-in, no staff action
        AccountAction.objects.filter(pk=act.pk).update(until=timezone.now() - timedelta(seconds=1))
        self.assertEqual(_login("01710001111").status_code, 200)
        self.u.refresh_from_db()
        self.assertEqual(self.u.account_status, "active")

    def test_appeal_lift_unblocks(self):
        self.act("suspend", reason="mistake", days="10")
        act = AccountAction.objects.get(user=self.u, kind="suspend")
        ap, err = AS.create_appeal(self.u, act.id, "Not me, my phone was stolen.")
        self.assertIsNone(err)
        self.post("/owner/appeals/%d/decide" % ap.id, {"decision": "lift", "note": "Sorry!"})
        self.u.refresh_from_db()
        self.assertEqual(self.u.account_status, "active")

    def test_ban_blocks_same_phone_and_email_by_hash(self):
        self.act("ban", reason="Scam")
        self.u.refresh_from_db()
        self.assertEqual(self.u.account_status, "banned")
        rows = list(BannedIdentity.objects.filter(user=self.u))
        self.assertEqual({r.kind for r in rows}, {"phone", "email"})
        for r in rows:                                    # never the plain value
            self.assertNotIn("1710001111", r.value_hash)
            self.assertNotIn("rahim", r.value_hash)
            self.assertEqual(len(r.value_hash), 64)
        self.assertEqual(_login("01710001111").status_code, 403)
        # the account is deleted; the same phone / email still cannot sign up
        User.objects.filter(pk=self.u.pk).delete()
        for body in ({"name": "N", "phone": "01710001111", "password": "pw-new-12345"},
                     {"name": "N", "email": "RAHIM@example.com", "password": "pw-new-12345"}):
            r = APIClient().post("/api/v1/auth/register", body, format="json")
            self.assertEqual(r.status_code, 403, body)
            self.assertEqual(r.json()["reason"], "identity_banned")
        ok = APIClient().post("/api/v1/auth/register",
                              {"name": "N", "phone": "01710001199", "password": "pw-new-12345"},
                              format="json")
        self.assertEqual(ok.status_code, 201)

    def test_unblock_lifts_ban_identities(self):
        self.act("ban", reason="Scam")
        self.act("unblock", reason="Appeal accepted")
        self.assertFalse(AS.banned_identity(phone="01710001111"))
        self.assertEqual(_login("01710001111").status_code, 200)

    def test_force_logout_revokes_everything(self):
        Token.objects.get_or_create(user=self.u)
        Device.objects.create(user=self.u, push_token="t9")
        LinkedDevice.objects.create(user=self.u, device_id="desk-1")
        self.act("force_logout", reason="Lost phone")
        self.assertFalse(Token.objects.filter(user=self.u).exists())
        self.assertFalse(Device.objects.filter(user=self.u).exists())
        self.assertTrue(LinkedDevice.objects.get(device_id="desk-1").revoked)
        self.u.refresh_from_db()
        self.assertEqual(self.u.account_status, "active")
        self.assertEqual(_login("01710001111").status_code, 200)

    def test_remove_reported_content_only(self):
        ch = Channel.objects.create(owner=self.u, name="News", handle="newsadminsafe")
        bad = ChannelPost.objects.create(channel=ch, author=self.u, kind="text", text="bad")
        fine = ChannelPost.objects.create(channel=ch, author=self.u, kind="text", text="fine")
        ModerationItem.objects.create(target_kind="post", target_id=str(bad.pk))
        self.act("remove_content", reason="Hate speech")
        bad.refresh_from_db()
        fine.refresh_from_db()
        self.assertEqual(bad.content_status, "removed")
        self.assertNotEqual(fine.content_status, "removed")


# ================================================================== staff
@override_settings(OWNER_ADMIN_REQUIRE_HTTPS=True)
class StaffTests(Base):
    def staff_client(self, role, phone):
        s = User.objects.create_user(name="Staff " + role, phone=phone, password=PW)
        AdminStaffRole.objects.create(user=s, role=role, granted_by=self.owner)
        c = SClient()
        r = c.post("/owner/login", {"phone": phone, "password": PW})
        self.assertEqual(r["Location"], "/owner/enrol")          # 2FA is mandatory
        self.assertEqual(c.get("/owner/users").status_code, 302)  # nothing before 2FA
        sess = OwnerSession.objects.get(key_hash=S.sha256(c.cookies[S.COOKIE].value))
        c.get("/owner/enrol")
        sess.refresh_from_db()
        secret = S.decrypt(sess.pending_secret_enc)
        r = c.post("/owner/enrol", {"code": S.totp(secret), "_ot": sess.csrf})
        self.assertEqual(r.status_code, 200)
        return s, c

    def spost(self, c, url, data):
        d = dict(data)
        d["_ot"] = _ot(c)
        return c.post(url, d)

    def test_readonly_sees_masked_and_cannot_act(self):
        s, c = self.staff_client("readonly", "01710002001")
        r = c.get("/owner/users/%d" % self.u.pk)
        self.assertEqual(r.status_code, 200)
        self.assertNotContains(r, "01710001111")
        self.assertNotContains(r, "rahim@example.com")
        self.assertTrue(OwnerAudit.objects.filter(action="user.view", actor=s).exists())
        self.assertEqual(self.spost(c, "/owner/users/%d/act" % self.u.pk,
                                    {"kind": "warn", "reason": "x"}).status_code, 403)
        for url in ("/owner/pricing", "/owner/audit", "/owner/staff", "/owner/payments",
                    "/owner/channel-reports", "/owner/features"):
            self.assertEqual(c.get(url).status_code, 403, url)
        self.assertEqual(c.get("/owner/")["Location"], "/owner/users")
        self.assertTrue(OwnerAudit.objects.filter(action="staff.denied", actor=s).exists())

    def test_support_warns_but_cannot_ban_or_change_money(self):
        s, c = self.staff_client("support", "01710002002")
        self.assertEqual(self.spost(c, "/owner/users/%d/act" % self.u.pk,
                                    {"kind": "warn", "reason": "be nice"}).status_code, 302)
        self.assertEqual(self.spost(c, "/owner/users/%d/act" % self.u.pk,
                                    {"kind": "ban", "reason": "x"}).status_code, 403)
        self.assertEqual(self.spost(c, "/owner/users/%d" % self.u.pk,
                                    {"action": "credits", "delta": "50",
                                     "reason": "x"}).status_code, 403)
        self.assertEqual(c.get("/owner/appeals").status_code, 200)
        self.assertEqual(AccountAction.objects.get(user=self.u).actor, s)

    def test_moderator_suspends_and_reviews_reports(self):
        s, c = self.staff_client("moderator", "01710002003")
        self.assertEqual(self.spost(c, "/owner/users/%d/act" % self.u.pk,
                                    {"kind": "suspend", "days": "2",
                                     "reason": "abuse"}).status_code, 302)
        self.assertEqual(c.get("/owner/channel-reports").status_code, 200)
        self.assertEqual(c.get("/owner/payments").status_code, 403)
        # never on another staff account or the owner
        other, _ = User.objects.get_or_create(phone="01710002009",
                                              defaults={"name": "S2", "username": "01710002009"})
        AdminStaffRole.objects.create(user=other, role="support")
        self.assertEqual(self.spost(c, "/owner/users/%d/act" % other.pk,
                                    {"kind": "warn", "reason": "x"}).status_code, 403)

    def test_finance_reads_payments_only(self):
        s, c = self.staff_client("finance", "01710002004")
        self.assertEqual(c.get("/owner/payments").status_code, 200)
        self.assertEqual(c.get("/owner/channel-reports").status_code, 403)
        self.assertEqual(self.spost(c, "/owner/users/%d/act" % self.u.pk,
                                    {"kind": "warn", "reason": "x"}).status_code, 403)

    def test_revoked_role_loses_access_at_once(self):
        s, c = self.staff_client("support", "01710002005")
        AdminStaffRole.objects.filter(user=s).update(active=False)
        self.assertEqual(c.get("/owner/users")["Location"], "/owner/login")

    def test_owner_grants_and_revokes_roles(self):
        staff = User.objects.create_user(name="New", phone="01710002006", password=PW)
        r = self.post("/owner/staff", {"action": "grant", "who": "01710002006",
                                       "role": "moderator", "reason": "night shift"})
        self.assertEqual(r.status_code, 302)
        row = AdminStaffRole.objects.get(user=staff)
        self.assertEqual(row.role, "moderator")
        self.post("/owner/staff", {"action": "revoke", "id": row.id, "reason": "left"})
        row.refresh_from_db()
        self.assertFalse(row.active)
        self.assertTrue(OwnerAudit.objects.filter(action="staff.grant").exists())
        self.assertTrue(OwnerAudit.objects.filter(action="staff.revoke").exists())


# ============================================================ privacy wall
OWNER_DIR = Path(__file__).resolve().parent / "owner"
TPL_DIR = Path(__file__).resolve().parent / "templates" / "owner"
# Models whose content Owner Admin / staff must NEVER read: My Circle
# messages + calls, vault documents, private photos, CCTV video/snapshots,
# live location. Related accessors (user.documents, …) are listed too.
FORBIDDEN = (
    # My Circle messages + calls
    "CircleMessage", "CircleMessageCopy", "CircleMediaBlob", "CircleNote", "CircleStatus",
    "ScheduledMessage", "StarredMessage", "CommunityMessageRequest", "CallRecord",
    "CallSession", "CallLink", "ScheduledCall", "BloodMessage", "MissingTipMessage",
    # vault
    "Document", "Nominee",
    # private photos
    "PhotoStudioJob", "PhotoExport", "WebPhotoDrop", "UserSticker",
    # CCTV video / snapshots
    "ShopEventClip", "ShopLiveSession", "CapturedEvent", "KidAudioSession", "KidsVoiceNote",
    # live location
    "JourneyPoint", "KidsWatchPosition", "VehiclePosition", "PhoneHeartbeat", "SavedPlace",
    "TrainShare", "CirclePresence", "AntiTheftEvent",
    # related accessors
    ".documents", ".journey_points", ".circle_messages", ".vehicle_positions",
)
# (file, token) pairs reviewed by hand: aggregate state counts only, no content
ALLOW = {("views_d1photo.py", "PhotoWorkItem")}


class PrivacyWallTests(Base):
    def _files(self):
        return list(OWNER_DIR.glob("*.py")) + list(TPL_DIR.glob("*.html"))

    def test_owner_code_never_touches_private_models(self):
        hits = []
        for f in self._files():
            text = f.read_text(encoding="utf-8")
            for tok in FORBIDDEN:
                pat = re.escape(tok) if tok.startswith(".") else r"\b%s\b" % re.escape(tok)
                if re.search(pat, text) and (f.name, tok) not in ALLOW:
                    hits.append("%s: %s" % (f.name, tok))
        self.assertEqual(hits, [], "Owner Admin must never read private content: %s" % hits)

    def test_core_admin_modules_never_touch_private_models(self):
        base = Path(__file__).resolve().parent.parent / "core"
        for name in ("admin_safety.py", "admin_stats.py", "views_safety.py"):
            text = (base / name).read_text(encoding="utf-8")
            for tok in FORBIDDEN:
                if not tok.startswith("."):
                    self.assertIsNone(re.search(r"\b%s\b" % tok, text), (name, tok))

    def test_vault_document_never_rendered(self):
        Document.objects.create(user=self.u, title="SECRET-VAULT-PASSPORT-77")
        for url in ("/owner/users/%d" % self.u.pk, "/owner/users?q=Rahim", "/owner/",
                    "/owner/appeals", "/owner/channel-reports", "/owner/audit"):
            r = self.c.get(url)
            self.assertNotContains(r, "SECRET-VAULT-PASSPORT-77", msg_prefix=url)
        st = _api(self.u).get("/api/v1/account/standing").content.decode()
        self.assertNotIn("SECRET-VAULT", st)
