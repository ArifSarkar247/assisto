"""halaladz (owner order 23 Nov): HalalAdz link / notify / support chat /
official community. The outbound HalalAdz call is ALWAYS mocked
(core.halaladz._post) — tests never reach the real API. Sample data only."""
import base64
import hashlib
import hmac
import json
import time
from io import StringIO
from unittest import mock

from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from core import halaladz as HZ
from core.models import (Channel, Community, CommunityGroup, CommunityMember,
                         HalalAdzEvent, HalalAdzLink, HalalAdzOfficial, NotifEvent,
                         SupportMessage, SupportTicket, User)

V = "/api/v1"
NOTIFY = "/api/integrations/halaladz/notify"
SECRET = "dummy-test-secret-not-real"
ON = override_settings(HALALADZ_SHARED_SECRET=SECRET)
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
M4A = b"\x00\x00\x00\x18ftypM4A " + b"\x00" * 64


def mk(phone, name, **kw):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language=kw.pop("language", "bn"), **kw)


def cl(u, lang="bn"):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE=lang)
    return c


def signed(body: dict, secret=SECRET):
    raw = json.dumps(body, separators=(",", ":")).encode()
    sig = hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()
    return raw, sig


class SignatureTests(TestCase):
    def test_outbound_signature_is_ts_dot_body(self):
        raw = b'{"code":"AB12CD34","assisto_user_id":"7"}'
        want = hmac.new(b"k", b"1700000000." + raw, hashlib.sha256).hexdigest()
        self.assertEqual(HZ.outbound_signature(1700000000, raw, key="k"), want)

    def test_doc_examples_match(self):
        """owner_actions/HALALADZ_INTEGRATION_BN.md examples (dummy secret)."""
        raw = b'{"code":"AB12CD34","assisto_user_id":"1234"}'
        self.assertEqual(HZ.outbound_signature(1764000000, raw, key="test-secret-123"),
                         "0589adca3670a07e551121156f8819e1caa639d752570175dc528eac04702d0e")
        body = {"event_id": "evt_20261123_0001", "timestamp": 1764000000,
                "assisto_user_id": "1234", "hz_account_id": "hz-901", "type": "order",
                "title_bn": "নতুন অর্ডার", "title_en": "New order",
                "body_bn": "আপনার বিজ্ঞাপনে নতুন অর্ডার এসেছে",
                "body_en": "A new order on your ad",
                "url": "https://halaladz.com/orders/55"}
        raw2 = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode()
        self.assertEqual(HZ.sign(raw2, key="test-secret-123"),
                         "a431261d29400de21225bd429ae5f736e2b8705e9797470a3f179ae01c6057c0")

    @ON
    def test_inbound_verify(self):
        raw, sig = signed({"a": 1})
        self.assertTrue(HZ.verify_inbound(raw, sig))
        self.assertTrue(HZ.verify_inbound(raw, "sha256=" + sig.upper()))
        self.assertFalse(HZ.verify_inbound(raw + b" ", sig))
        self.assertFalse(HZ.verify_inbound(raw, ""))

    def test_verify_false_when_off(self):
        raw, sig = signed({"a": 1})
        self.assertFalse(HZ.verify_inbound(raw, sig))

    def test_code_and_url_rules(self):
        self.assertEqual(HZ.norm_code(" ab12-cd34 "), "AB12CD34")
        for bad in ("", "AB12CD3", "AB12CD345", "AB12CD3!", None):
            self.assertIsNone(HZ.norm_code(bad))
        self.assertTrue(HZ.safe_url("https://halaladz.com/x?y=1"))
        self.assertTrue(HZ.safe_url("https://app.halaladz.com/p/9"))
        for bad in ("http://halaladz.com/", "https://evilhalaladz.com/",
                    "https://halaladz.com.evil.io/", "javascript:alert(1)",
                    "https://user@halaladz.com/", "https://halaladz.com:8443/",
                    "intent://x#Intent;end"):
            self.assertIsNone(HZ.safe_url(bad), bad)


class FeatureOffTests(TestCase):
    def setUp(self):
        cache.clear()
        self.u = mk("01710000001", "Rahim")
        self.c = cl(self.u)

    def test_everything_off_without_secret(self):
        r = self.c.get("%s/halaladz/status" % V)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json(), {"enabled": False, "linked": False})
        for path, body in (("link", {"code": "AB12CD34"}), ("unlink", {}),
                           ("support", {"text": "hi"})):
            r = self.c.post("%s/halaladz/%s" % (V, path), body, format="json")
            self.assertEqual(r.status_code, 503, path)
        self.assertEqual(self.c.get("%s/halaladz/support" % V).status_code, 503)
        raw, sig = signed({"event_id": "e1"})
        r = APIClient().post(NOTIFY, raw, content_type="application/json",
                             HTTP_X_HZ_SIGNATURE=sig)
        self.assertEqual(r.status_code, 503)


@ON
class LinkTests(TestCase):
    def setUp(self):
        cache.clear()
        self.u = mk("01710000002", "Karim")
        self.c = cl(self.u)

    def test_link_success_signed_request_and_unlink(self):
        seen = {}

        def fake(url, raw, headers, timeout=8):
            seen.update(url=url, raw=raw, headers=headers, timeout=timeout)
            return 200, {"hz_account_id": "hz-901", "display_name": "Karim Shop"}

        with mock.patch.object(HZ, "_post", side_effect=fake):
            r = self.c.post("%s/halaladz/link" % V, {"code": "ab12cd34"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["account"]["display_name"], "Karim Shop")
        self.assertEqual(seen["url"], "https://hz.invalid/v1/integrations/assisto/link")
        self.assertLessEqual(seen["timeout"], 10)
        body = json.loads(seen["raw"])
        self.assertEqual(body, {"code": "AB12CD34", "assisto_user_id": str(self.u.id)})
        ts = seen["headers"]["X-Assisto-Timestamp"]
        self.assertEqual(seen["headers"]["X-Assisto-Signature"],
                         hmac.new(SECRET.encode(), ts.encode() + b"." + seen["raw"],
                                  hashlib.sha256).hexdigest())
        st = self.c.get("%s/halaladz/status" % V).json()
        self.assertTrue(st["enabled"] and st["linked"])
        self.assertEqual(st["account"]["hz_account_id"], "hz-901")
        r = self.c.post("%s/halaladz/unlink" % V, {}, format="json")
        self.assertEqual(r.json(), {"linked": False})
        self.assertFalse(HalalAdzLink.objects.filter(user=self.u).exists())

    def test_bad_format_never_calls_out(self):
        with mock.patch.object(HZ, "_post") as p:
            r = self.c.post("%s/halaladz/link" % V, {"code": "12"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["detail"], "bad_format")
        self.assertIn("৮", r.json()["message"])        # honest Bangla error
        p.assert_not_called()

    def test_failures_map_to_honest_errors(self):
        for code, want, http in ((404, "bad_code", 400), (409, "taken", 409),
                                 (0, "unreachable", 502), (500, "unreachable", 502)):
            cache.clear()
            with mock.patch.object(HZ, "_post", return_value=(code, {})):
                r = self.c.post("%s/halaladz/link" % V, {"code": "AB12CD34"},
                                format="json")
            self.assertEqual(r.status_code, http, code)
            self.assertEqual(r.json()["detail"], want)
        self.assertFalse(HalalAdzLink.objects.exists())

    def test_account_already_linked_elsewhere(self):
        other = mk("01710000003", "Other")
        HalalAdzLink.objects.create(user=other, hz_account_id="hz-1", display_name="X")
        with mock.patch.object(HZ, "_post", return_value=(200, {"hz_account_id": "hz-1"})):
            r = self.c.post("%s/halaladz/link" % V, {"code": "AB12CD34"}, format="json")
        self.assertEqual(r.status_code, 409)

    def test_rate_limited(self):
        with mock.patch.object(HZ, "_post", return_value=(404, {})) as p:
            codes = [self.c.post("%s/halaladz/link" % V, {"code": "AB12CD34"},
                                 format="json").status_code for _ in range(7)]
        self.assertEqual(codes[:5], [400] * 5)
        self.assertEqual(codes[5:], [429, 429])
        self.assertEqual(p.call_count, 5)


@ON
class NotifyTests(TestCase):
    def setUp(self):
        cache.clear()
        self.u = mk("01710000004", "Salma", language="en")
        HalalAdzLink.objects.create(user=self.u, hz_account_id="hz-77", display_name="S")
        self.api = APIClient()

    def body(self, **kw):
        d = {"event_id": "evt_1", "timestamp": int(time.time()),
             "assisto_user_id": str(self.u.id), "type": "order",
             "title_bn": "নতুন অর্ডার", "title_en": "New order",
             "body_bn": "আপনার বিজ্ঞাপনে নতুন অর্ডার", "body_en": "A new order on your ad",
             "url": "https://halaladz.com/orders/55"}
        d.update(kw)
        return d

    def post(self, d, sig=None):
        raw, good = signed(d)
        return self.api.post(NOTIFY, raw, content_type="application/json",
                             HTTP_X_HZ_SIGNATURE=good if sig is None else sig)

    def test_valid_creates_notification_and_push(self):
        with mock.patch("core.push.safe_push") as sp:
            r = self.post(self.body())
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["status"], "delivered")
        ev = NotifEvent.objects.get(user=self.u)
        self.assertEqual(ev.title_en, "New order")
        self.assertEqual(ev.title_bn, "নতুন অর্ডার")
        self.assertEqual(ev.meta["url"], "https://halaladz.com/orders/55")
        args, kwargs = sp.call_args
        self.assertEqual(args[1], "halaladz")
        self.assertEqual(kwargs["data"]["url"], "https://halaladz.com/orders/55")
        feed = cl(self.u, "en").get("%s/notifications" % V)
        if feed.status_code == 200:
            self.assertIn("halaladz", json.dumps(feed.json()))

    def test_invalid_signature(self):
        r = self.post(self.body(), sig="0" * 64)
        self.assertEqual(r.status_code, 401)
        r = self.post(self.body(), sig="")
        self.assertEqual(r.status_code, 401)
        self.assertFalse(NotifEvent.objects.exists())

    def test_signed_with_other_secret(self):
        raw, sig = signed(self.body(), secret="wrong")
        r = self.api.post(NOTIFY, raw, content_type="application/json",
                          HTTP_X_HZ_SIGNATURE=sig)
        self.assertEqual(r.status_code, 401)

    def test_stale_and_future_timestamp(self):
        for ts in (int(time.time()) - 301, int(time.time()) + 301, "x", None):
            r = self.post(self.body(timestamp=ts, event_id="e%s" % abs(hash(str(ts)))))
            self.assertEqual(r.status_code, 401, ts)
            self.assertEqual(r.json()["detail"], "stale")

    def test_idempotent_by_event_id(self):
        with mock.patch("core.push.safe_push") as sp:
            self.assertEqual(self.post(self.body()).json()["status"], "delivered")
            r = self.post(self.body(title_en="again"))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["status"], "duplicate")
        self.assertEqual(NotifEvent.objects.filter(user=self.u).count(), 1)
        self.assertEqual(HalalAdzEvent.objects.count(), 1)
        self.assertEqual(sp.call_count, 1)

    def test_unknown_or_unlinked_user_same_404(self):
        stranger = mk("01710000005", "Nobody")
        outs = []
        for uid in (str(stranger.id), "999999", "abc"):
            r = self.post(self.body(assisto_user_id=uid, event_id="e-%s" % uid))
            outs.append((r.status_code, r.json()))
        self.assertTrue(all(o == (404, {"detail": "not_found"}) for o in outs), outs)
        r = self.post(self.body(hz_account_id="hz-other", event_id="e-mismatch"))
        self.assertEqual(r.status_code, 404)
        self.assertFalse(NotifEvent.objects.exists())

    def test_unsafe_url_rejected(self):
        for i, u in enumerate(("http://halaladz.com/", "https://evil.example/",
                               "javascript:alert(1)")):
            r = self.post(self.body(url=u, event_id="u%d" % i))
            self.assertEqual(r.status_code, 400)
            self.assertEqual(r.json()["detail"], "bad_url")

    def test_plain_title_fills_both_languages(self):
        d = self.body(event_id="plain")
        for k in ("title_bn", "title_en", "body_bn", "body_en", "url"):
            d.pop(k)
        d.update(title="HalalAdz", body="Hello")
        with mock.patch("core.push.safe_push"):
            self.assertEqual(self.post(d).status_code, 200)
        ev = NotifEvent.objects.get(user=self.u)
        self.assertEqual((ev.title_bn, ev.title_en), ("HalalAdz", "HalalAdz"))


@ON
class SupportTests(TestCase):
    def setUp(self):
        cache.clear()
        self.u = mk("01710000006", "Jamal")
        self.owner = mk("01710000007", "Owner", is_superuser=True, is_staff=True)
        self.cu, self.co = cl(self.u), cl(self.owner)

    def send(self, **body):
        return self.cu.post("%s/halaladz/support" % V, body, format="json")

    def test_text_photo_voice_unread_reply_resolve(self):
        self.assertEqual(self.send(text="আমার বিজ্ঞাপন দেখাচ্ছে না").status_code, 201)
        r = self.send(photo_b64=base64.b64encode(JPEG).decode())
        self.assertEqual(r.status_code, 201, r.content)
        url = r.json()["message"]["media_url"]
        self.assertTrue(url.startswith("/api/v1/m/support/msg/"), url)   # signed
        self.assertIn("&s=", url)
        r = self.send(voice_b64=base64.b64encode(M4A).decode(), duration_ms=4200)
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.json()["message"]["kind"], "voice")
        t = SupportTicket.objects.get(user=self.u, topic="halaladz")
        self.assertEqual(t.unread_owner, 3)
        # owner inbox: unread count; normal users can't see it
        self.assertEqual(self.cu.get("%s/halaladz/owner/inbox" % V).status_code, 404)
        inbox = self.co.get("%s/halaladz/owner/inbox" % V).json()
        self.assertEqual(inbox["unread_total"], 3)
        self.assertEqual(inbox["results"][0]["unread_owner"], 3)
        self.assertTrue(inbox["quick_replies"])
        th = self.co.get("%s/halaladz/owner/thread/%d" % (V, t.id)).json()
        self.assertEqual(len(th["messages"]), 3)
        t.refresh_from_db()
        self.assertEqual(t.unread_owner, 0)
        with mock.patch("core.push.safe_push") as sp:
            r = self.co.post("%s/halaladz/owner/thread/%d/reply" % (V, t.id),
                             {"text": HZ.QUICK_REPLIES[0][0]}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(sp.call_args[1]["data"]["route"], "halaladz_support")
        self.assertEqual(self.cu.get("%s/halaladz/status" % V).json()["support_unread"], 1)
        mine = self.cu.get("%s/halaladz/support" % V).json()
        self.assertEqual([m["sender"] for m in mine["messages"]],
                         ["user", "user", "user", "owner"])
        t.refresh_from_db()
        self.assertEqual(t.unread_user, 0)
        r = self.co.post("%s/halaladz/owner/thread/%d/resolve" % (V, t.id),
                         {"resolved": True}, format="json")
        self.assertTrue(r.json()["ticket"]["resolved"])
        self.assertEqual(self.co.get("%s/halaladz/owner/inbox" % V).json()["results"], [])
        self.assertEqual(len(self.co.get("%s/halaladz/owner/inbox?status=resolved" % V)
                             .json()["results"]), 1)
        self.send(text="আবার সমস্যা")               # a new message re-opens it
        t.refresh_from_db()
        self.assertFalse(t.resolved)

    def test_bad_attachments_and_empty(self):
        self.assertEqual(self.send().status_code, 400)
        self.assertEqual(self.send(photo_b64=base64.b64encode(b"GIF89a....").decode())
                         .status_code, 400)
        self.assertEqual(self.send(photo_b64="!!notbase64!!").status_code, 400)
        big = base64.b64encode(b"\xff\xd8\xff" + b"0" * (HZ.PHOTO_MAX_BYTES + 1)).decode()
        self.assertEqual(self.send(photo_b64=big).status_code, 400)
        self.assertEqual(SupportMessage.objects.count(), 0)

    def test_users_see_only_their_own_thread(self):
        self.send(text="private")
        other = mk("01710000008", "Other")
        r = cl(other).get("%s/halaladz/support" % V).json()
        self.assertEqual(r["messages"], [])

    def test_owner_web_inbox_page_needs_owner_login(self):
        r = APIClient().get("/owner/halaladz-support", secure=True)
        self.assertIn(r.status_code, (301, 302, 403))


class CommunityCommandTests(TestCase):
    def setUp(self):
        cache.clear()
        self.owner = mk("01710000009", "Owner")

    def run_cmd(self, *extra):
        out = StringIO()
        call_command("halaladz_community", "--owner", str(self.owner.id), *extra,
                     stdout=out)
        return out.getvalue()

    def test_idempotent_and_reuses_existing_engines(self):
        out1 = self.run_cmd()
        self.assertIn("created", out1)
        off = HalalAdzOfficial.objects.get(pk=1)
        ch = off.channel
        self.assertEqual(ch.name, "HalalAdz কমিউনিটি")
        self.assertTrue(ch.verified)
        self.assertEqual(ch.verification_state, "verified")
        self.assertEqual(ch.owner, self.owner)
        self.assertTrue(ch.invite_code)
        self.assertIn("/ch/%s" % ch.handle, out1)
        c = off.community
        self.assertIn("/cm/%s" % c.invite_code, out1)
        kinds = sorted(CommunityGroup.objects.filter(community=c).values_list("kind", flat=True))
        self.assertEqual(kinds, ["announcements", "topic"])
        self.assertEqual(off.group.name, "HalalAdz কমিউনিটি")
        self.assertTrue(off.group.circle_group_id)        # real group chat
        roles = set(CommunityMember.objects.filter(community=c, member=self.owner)
                    .values_list("role", flat=True))
        self.assertEqual(roles, {"admin"})
        out2 = self.run_cmd()
        self.assertNotIn("created", out2)
        self.assertEqual(Channel.objects.count(), 1)
        self.assertEqual(Community.objects.count(), 1)
        self.assertEqual(CommunityGroup.objects.count(), 2)
        self.assertEqual(CommunityMember.objects.filter(member=self.owner).count(), 2)

    def test_owner_by_phone_and_status_shows_links(self):
        out = StringIO()
        call_command("halaladz_community", "--owner", "01710000009", stdout=out)
        self.assertTrue(HalalAdzOfficial.objects.filter(pk=1).exists())
        with ON:
            st = cl(self.owner).get("%s/halaladz/status" % V).json()
        self.assertIn("/ch/", st["official"]["channel_url"])
        self.assertIn("/cm/", st["official"]["community_url"])

    def test_unknown_owner(self):
        from django.core.management.base import CommandError
        with self.assertRaises(CommandError):
            call_command("halaladz_community", "--owner", "424242", stdout=StringIO())
