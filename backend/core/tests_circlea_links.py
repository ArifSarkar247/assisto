"""circlea — link previews (SSRF-safe, channel posts only) + safe-link check.

No network: a fake resolver + a fake opener stand in for DNS / HTTP.
Patches return plain values only (no bare MagicMock gets JSON-encoded)."""
import socket
from unittest import mock

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase, override_settings
from rest_framework.test import APIClient

from core import link_preview as LP
from core.logic import safe_link as SL
from core.models import User

V = "/api/v1"
PUBLIC = "93.184.216.34"


def resolver_for(mapping):
    def _r(host, port, *a, **kw):
        ips = mapping.get(host)
        if ips is None:
            raise socket.gaierror("no such host")
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, port)) for ip in ips]
    return _r


PUB = resolver_for({"example.com": [PUBLIC], "img.example.com": [PUBLIC],
                    "bit.ly": [PUBLIC], "bkash-login.top": [PUBLIC],
                    "evil.example": ["10.0.0.5"],
                    "mixed.example": [PUBLIC, "127.0.0.1"],
                    "rebind.example": ["169.254.169.254"]})

HTML = (b"<html><head><title>Fallback</title>"
        b"<meta property='og:title' content='A  Reel about tea'>"
        b"<meta property='og:site_name' content='Facebook'>"
        b"<meta name='description' content='Desc here'>"
        b"<meta property='og:image' content='/img.png'></head><body>x</body></html>")
PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 100


def opener_for(routes):
    def _o(url, method):
        r = routes.get(url)
        if r is None:
            return 404, {"Content-Type": "text/html"}, b""
        return r
    return _o


class GuardTests(SimpleTestCase):
    def test_only_http_https_public_ports_no_userinfo(self):
        for bad, why in [("ftp://example.com/x", "scheme"), ("file:///etc/passwd", "scheme"),
                         ("javascript:alert(1)", "scheme"), ("gopher://x", "scheme"),
                         ("http://user:pw@example.com/", "userinfo"),
                         ("http://example.com:22/", "port"),
                         ("http://localhost/", "private_host"),
                         ("http://printer.local/", "private_host"),
                         ("http:///nohost", "no_host")]:
            with self.assertRaises(LP.Blocked) as cm:
                LP.check_url(bad)
            self.assertEqual(str(cm.exception), why, bad)
        self.assertEqual(LP.check_url("https://example.com/a?b=1")[1:],
                         ("example.com", 443, "/a?b=1"))

    def test_private_addresses_refused_after_dns(self):
        for ip in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254",
                   "100.64.0.1", "0.0.0.0", "::1", "fe80::1", "fc00::1",
                   "::ffff:127.0.0.1", "224.0.0.1", "240.0.0.1"]:
            r = resolver_for({"h.example": [ip]})
            with self.assertRaises(LP.Blocked, msg=ip):
                LP.resolve_public("h.example", 80, r)
        # one bad address among good ones is enough to refuse
        with self.assertRaises(LP.Blocked):
            LP.resolve_public("mixed.example", 80, PUB)
        # raw IP literals are checked too
        with self.assertRaises(LP.Blocked):
            LP.resolve_public("127.0.0.1", 80, PUB)
        with self.assertRaises(LP.Blocked):
            LP.resolve_public("nope.example", 80, PUB)
        self.assertEqual(LP.resolve_public("example.com", 443, PUB), PUBLIC)

    def test_redirect_to_internal_is_refused(self):
        op = opener_for({
            "https://example.com/a": (302, {"Location": "http://169.254.169.254/latest/meta"}, b""),
        })
        with self.assertRaises(LP.Blocked) as cm:
            LP.safe_fetch("https://example.com/a", resolver=PUB, opener=op)
        self.assertEqual(str(cm.exception), "private_ip")
        op = opener_for({
            "https://example.com/b": (301, {"Location": "https://rebind.example/"}, b""),
        })
        with self.assertRaises(LP.Blocked):
            LP.safe_fetch("https://example.com/b", resolver=PUB, opener=op)
        op = opener_for({
            "https://example.com/c": (302, {"Location": "file:///etc/passwd"}, b""),
        })
        with self.assertRaises(LP.Blocked):
            LP.safe_fetch("https://example.com/c", resolver=PUB, opener=op)

    def test_redirect_loop_capped(self):
        op = opener_for({"https://example.com/l": (302, {"Location": "/l"}, b"")})
        with self.assertRaises(LP.Blocked) as cm:
            LP.safe_fetch("https://example.com/l", resolver=PUB, opener=op)
        self.assertEqual(str(cm.exception), "too_many_redirects")

    def test_size_cap(self):
        op = opener_for({"https://example.com/big": (200, {"Content-Type": "text/html"},
                                                     b"x" * (LP.MAX_HTML + 5000))})
        r = LP.safe_fetch("https://example.com/big", resolver=PUB, opener=op)
        self.assertEqual(len(r["body"]), LP.MAX_HTML)

    def test_pinned_connection_goes_to_checked_ip(self):
        seen = []

        def fake_conn(addr, timeout=None):
            seen.append(addr)
            raise OSError("stop here")
        c = LP._PinnedHTTP("example.com", PUBLIC, 80, 1)
        with mock.patch("core.link_preview.socket.create_connection", side_effect=fake_conn):
            with self.assertRaises(OSError):
                c.connect()
        self.assertEqual(seen, [(PUBLIC, 80)])


class PreviewTests(SimpleTestCase):
    def test_og_preview_with_image(self):
        op = opener_for({
            "https://example.com/reel": (200, {"Content-Type": "text/html; charset=utf-8"}, HTML),
            "https://example.com/img.png": (200, {"Content-Type": "image/png"}, PNG),
        })
        p = LP.build_preview("https://example.com/reel", resolver=PUB, opener=op)
        self.assertTrue(p["ok"])
        self.assertEqual(p["title"], "A Reel about tea")
        self.assertEqual(p["site"], "Facebook")
        self.assertEqual(p["description"], "Desc here")
        self.assertTrue(p["image"].startswith("data:image/png;base64,"))

    def test_too_big_image_dropped_not_html_refused(self):
        op = opener_for({
            "https://example.com/reel": (200, {"Content-Type": "text/html"}, HTML),
            "https://example.com/img.png": (200, {"Content-Type": "image/png"},
                                            b"0" * (LP.MAX_IMAGE + 10)),
            "https://example.com/f.pdf": (200, {"Content-Type": "application/pdf"}, b"%PDF"),
        })
        p = LP.build_preview("https://example.com/reel", resolver=PUB, opener=op)
        self.assertTrue(p["ok"])
        self.assertEqual(p["image"], "")
        p = LP.build_preview("https://example.com/f.pdf", resolver=PUB, opener=op)
        self.assertEqual((p["ok"], p["reason"]), (False, "not_html"))
        p = LP.build_preview("http://evil.example/", resolver=PUB, opener=op)
        self.assertEqual((p["ok"], p["reason"]), (False, "private_ip"))

    def test_bangla_title(self):
        html = "<title>চায়ের গল্প</title>".encode()
        op = opener_for({"https://example.com/bn": (200, {"Content-Type": "text/html"}, html)})
        p = LP.build_preview("https://example.com/bn", resolver=PUB, opener=op)
        self.assertEqual(p["title"], "চায়ের গল্প")


class SafeLinkHeuristics(SimpleTestCase):
    def v(self, url):
        return SL.check(url)["verdict"]

    def test_official_links_ok(self):
        for u in ["https://www.bkash.com/", "https://www.facebook.com/reel/123",
                  "https://youtu.be/abc", "https://www.youtube.com/watch?v=1",
                  "https://www.tiktok.com/@a/video/1", "https://nagad.com.bd/",
                  "https://rocketchat.com", "https://lh3.googleusercontent.com/x"]:
            self.assertEqual(self.v(u), "ok", u)

    def test_lookalikes_bad(self):
        for u in ["https://bkash-bonus.xyz/login", "http://b1kash.com", "https://bkassh.com",
                  "https://nagad.com.bd.verify-now.top/", "https://foo.com/bkash/login",
                  "https://xn--bkash-9za.com", "https://user@evil.com",
                  "https://faceb00k-login.com"]:
            self.assertEqual(self.v(u), "bad", u)

    def test_warnings(self):
        self.assertIn("shortener", SL.check("https://bit.ly/abc")["reasons"])
        self.assertIn("not_https", SL.check("http://example.com")["reasons"])
        self.assertIn("ip_host", SL.check("https://8.8.8.8/x")["reasons"])
        self.assertIn("suspicious_tld", SL.check("https://example.zip/")["reasons"])
        self.assertEqual(self.v("https://bit.ly/abc"), "warn")


class Endpoints(TestCase):
    def setUp(self):
        cache.clear()
        self.u = User.objects.create_user(name="A", phone="01711400001", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_e2e_context_never_accepted(self):
        for body in [{"url": "https://example.com"},
                     {"url": "https://example.com", "context": "chat"},
                     {"url": "https://example.com", "context": "e2e"}]:
            r = self.c.post(V + "/links/preview", body, format="json")
            self.assertEqual((r.status_code, r.json()["detail"]), (400, "e2e_never"))
            r = self.c.post(V + "/links/check", body, format="json")
            self.assertEqual(r.status_code, 400)

    def test_preview_cached(self):
        calls = []

        def fake(url, **kw):
            calls.append(url)
            return {"ok": True, "url": url, "final_url": url, "title": "T",
                    "description": "", "site": "example.com", "image": ""}
        with mock.patch("core.link_preview.build_preview", side_effect=fake):
            for _ in range(2):
                r = self.c.post(V + "/links/preview",
                                {"url": "https://example.com/x", "context": "channel"},
                                format="json")
                self.assertEqual(r.json()["title"], "T")
        self.assertEqual(calls, ["https://example.com/x"])

    def test_shortener_resolved_to_real_destination(self):
        def fake_fetch(url, max_bytes=0, resolver=None, opener=None, method="GET",
                       want_body=True):
            return {"final_url": "https://bkash-login.top/x", "status": 200,
                    "ctype": "text/html", "body": b"", "hops": [url]}
        with mock.patch("core.link_preview.safe_fetch", side_effect=fake_fetch):
            r = self.c.post(V + "/links/check", {"url": "https://bit.ly/zz", "context": "channel"},
                            format="json")
        d = r.json()
        self.assertEqual(d["final_host"], "bkash-login.top")
        self.assertEqual(d["verdict"], "bad")
        self.assertEqual(d["safe_browsing"], "not_configured")

    @override_settings(GOOGLE_SAFE_BROWSING_KEY="test-key")
    def test_safe_browsing_when_configured(self):
        class Resp:
            status_code = 200

            def json(self):
                return {"matches": [{"threatType": "SOCIAL_ENGINEERING"}]}
        with mock.patch("requests.post", return_value=Resp()):
            r = self.c.post(V + "/links/check",
                            {"url": "https://example.com/p", "context": "channel"},
                            format="json")
        d = r.json()
        self.assertEqual((d["safe_browsing"], d["verdict"]), ("unsafe", "bad"))

    def test_rate_limited(self):
        cache.set("lp:rate:%d" % self.u.id, 10_000, 60)
        r = self.c.post(V + "/links/check", {"url": "https://example.com", "context": "channel"},
                        format="json")
        self.assertEqual(r.status_code, 429)
