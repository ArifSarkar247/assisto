"""link_preview.py — SSRF-safe link preview + safe-link check (circlea).

USED ONLY FOR NON-E2E CONTENT (channel posts — plaintext, moderatable).
End-to-end-encrypted chats never send a URL here: the SENDER's phone builds
the preview and ships it inside the encrypted payload (app side:
lib/messaging/link_preview_client.dart), exactly like WhatsApp/Signal.

SSRF guard (every hop, including redirects):
  * only http / https, only ports 80 / 443, no userinfo ("user@host")
  * the host is resolved ONCE per hop and EVERY address must be public
    (ipaddress.is_global; private, loopback, link-local, CGNAT, multicast,
    reserved, unspecified, IPv4-mapped IPv6 of those -> refused)
  * the TCP connection goes to the address we checked (pinned — a DNS
    rebind between check and connect cannot reach an internal host); TLS
    still verifies the certificate for the real host name (SNI)
  * at most MAX_REDIRECTS hops, each re-checked; no cookies are sent or
    kept; a fixed UA; response bodies capped (MAX_HTML / MAX_IMAGE bytes);
    a total time budget per fetch.
Results are cached (django cache) per URL.
"""
from __future__ import annotations

import base64
import hashlib
import http.client
import ipaddress
import re
import socket
import ssl
import time
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

MAX_REDIRECTS = 4
MAX_HTML = 512 * 1024
MAX_IMAGE = 200 * 1024
TIMEOUT_S = 4.0
BUDGET_S = 8.0
CACHE_S = 24 * 3600
NEG_CACHE_S = 3600
UA = "AssistoLinkPreview/1.0 (+https://lifeassisto.com)"
ALLOWED_PORTS = {80, 443}


class Blocked(Exception):
    """The URL (or a redirect hop) is not allowed."""


# ------------------------------------------------------------------ guard
def _ip_ok(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if isinstance(a, ipaddress.IPv6Address) and a.ipv4_mapped is not None:
        a = a.ipv4_mapped
    if a.is_multicast or a.is_unspecified or a.is_loopback or a.is_link_local:
        return False
    if a.is_private or a.is_reserved:
        return False
    return bool(a.is_global)


def check_url(url):
    """(scheme, host, port, path_with_query) or raise Blocked."""
    if not isinstance(url, str) or len(url) > 2048:
        raise Blocked("bad_url")
    try:
        p = urlsplit(url.strip())
    except ValueError:
        raise Blocked("bad_url")
    scheme = (p.scheme or "").lower()
    if scheme not in ("http", "https"):
        raise Blocked("scheme")
    if p.username or p.password or "@" in (p.netloc or ""):
        raise Blocked("userinfo")
    host = (p.hostname or "").strip().rstrip(".").lower()
    if not host:
        raise Blocked("no_host")
    try:
        port = p.port or (443 if scheme == "https" else 80)
    except ValueError:
        raise Blocked("bad_port")
    if port not in ALLOWED_PORTS:
        raise Blocked("port")
    if host in ("localhost",) or host.endswith((".localhost", ".local", ".internal",
                                                 ".lan", ".home.arpa")):
        raise Blocked("private_host")
    path = p.path or "/"
    if p.query:
        path += "?" + p.query
    return scheme, host, port, path


def resolve_public(host, port, resolver=None):
    """All addresses of host; every one must be public. Returns the first."""
    resolver = resolver or socket.getaddrinfo
    try:
        ipaddress.ip_address(host)
        addrs = [host]
    except ValueError:
        try:
            infos = resolver(host, port, 0, socket.SOCK_STREAM)
        except (socket.gaierror, UnicodeError, OSError):
            raise Blocked("dns")
        addrs = [i[4][0] for i in infos]
    if not addrs:
        raise Blocked("dns")
    for a in addrs:
        if not _ip_ok(a.split("%")[0]):
            raise Blocked("private_ip")
    return addrs[0]


class _PinnedHTTP(http.client.HTTPConnection):
    def __init__(self, host, ip, port, timeout):
        super().__init__(host, port, timeout=timeout)
        self._ip = ip

    def connect(self):
        self.sock = socket.create_connection((self._ip, self.port), self.timeout)


class _PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, ip, port, timeout):
        super().__init__(host, port, timeout=timeout,
                         context=ssl.create_default_context())
        self._ip = ip

    def connect(self):
        raw = socket.create_connection((self._ip, self.port), self.timeout)
        self.sock = self._context.wrap_socket(raw, server_hostname=self.host)


def _open(url, resolver=None, method="GET"):
    scheme, host, port, path = check_url(url)
    ip = resolve_public(host, port, resolver)
    cls = _PinnedHTTPS if scheme == "https" else _PinnedHTTP
    conn = cls(host, ip, port, TIMEOUT_S)
    conn.request(method, path, headers={
        "User-Agent": UA, "Accept": "text/html,application/xhtml+xml,image/*;q=0.8",
        "Accept-Language": "bn,en;q=0.8", "Connection": "close"})
    return conn, conn.getresponse()


def safe_fetch(url, max_bytes=MAX_HTML, resolver=None, opener=None, method="GET",
               want_body=True):
    """Follow redirects safely. Returns {final_url, status, ctype, body, hops}.
    `opener` (tests) replaces the network: opener(url, method) -> (status,
    headers dict, body bytes)."""
    start = time.monotonic()
    hops = []
    cur = url
    for _ in range(MAX_REDIRECTS + 1):
        check_url(cur)
        if time.monotonic() - start > BUDGET_S:
            raise Blocked("timeout")
        if opener is not None:
            # tests: the guard still runs on the host (fake resolver allowed)
            scheme, host, port, _p = check_url(cur)
            resolve_public(host, port, resolver)
            status, headers, body = opener(cur, method)
            headers = {k.lower(): v for k, v in (headers or {}).items()}
        else:
            conn, resp = _open(cur, resolver, method)
            try:
                status = resp.status
                headers = {k.lower(): v for k, v in resp.getheaders()}
                body = b""
                if want_body and not (300 <= status < 400):
                    body = resp.read(max_bytes + 1)
            finally:
                conn.close()
        hops.append(cur)
        if 300 <= status < 400 and headers.get("location"):
            cur = urljoin(cur, headers["location"].strip())
            continue
        if want_body and len(body or b"") > max_bytes:
            body = body[:max_bytes]
        return {"final_url": cur, "status": status,
                "ctype": (headers.get("content-type") or "").split(";")[0].strip().lower(),
                "body": body or b"", "hops": hops}
    raise Blocked("too_many_redirects")


# ------------------------------------------------------------------ parse
class _Meta(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.meta = {}
        self.title = ""
        self._in_title = False

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag == "meta":
            key = (a.get("property") or a.get("name") or "").strip().lower()
            if key and "content" in a and key not in self.meta:
                self.meta[key] = a["content"].strip()
        elif tag == "title":
            self._in_title = True

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title and len(self.title) < 300:
            self.title += data


def parse_html(html, base_url):
    m = _Meta()
    try:
        m.feed(html[:MAX_HTML])
    except Exception:  # noqa: BLE001 — broken HTML still gives what it can
        pass
    g = m.meta.get
    title = (g("og:title") or g("twitter:title") or m.title or "").strip()
    desc = (g("og:description") or g("twitter:description") or g("description") or "").strip()
    site = (g("og:site_name") or "").strip() or (urlsplit(base_url).hostname or "")
    img = (g("og:image:secure_url") or g("og:image") or g("twitter:image") or "").strip()
    return {"title": re.sub(r"\s+", " ", title)[:200],
            "description": re.sub(r"\s+", " ", desc)[:300],
            "site": site[:80],
            "image_url": urljoin(base_url, img) if img else ""}


def _decode(body, ctype_full=""):
    for enc in ("utf-8", "cp1252"):
        try:
            return body.decode(enc)
        except UnicodeDecodeError:
            continue
    return body.decode("utf-8", "replace")


def build_preview(url, resolver=None, opener=None):
    """{ok, url, final_url, title, description, site, image (data: URI|"")}
    or {ok: False, reason}. Never raises."""
    try:
        r = safe_fetch(url, MAX_HTML, resolver, opener)
    except Blocked as e:
        return {"ok": False, "reason": str(e)}
    except Exception:  # noqa: BLE001 — network trouble is not an error page
        return {"ok": False, "reason": "unreachable"}
    if r["status"] >= 400 or r["ctype"] not in ("text/html", "application/xhtml+xml"):
        return {"ok": False, "reason": "not_html", "final_url": r["final_url"]}
    meta = parse_html(_decode(r["body"]), r["final_url"])
    image = ""
    if meta["image_url"]:
        try:
            ir = safe_fetch(meta["image_url"], MAX_IMAGE, resolver, opener)
            if (ir["status"] < 400 and ir["ctype"] in ("image/jpeg", "image/png",
                                                      "image/webp", "image/gif")
                    and 0 < len(ir["body"]) <= MAX_IMAGE):
                image = "data:%s;base64,%s" % (ir["ctype"],
                                               base64.b64encode(ir["body"]).decode())
        except Exception:  # noqa: BLE001 — a preview without a picture is fine
            image = ""
    if not (meta["title"] or meta["description"]):
        return {"ok": False, "reason": "no_meta", "final_url": r["final_url"]}
    return {"ok": True, "url": url, "final_url": r["final_url"], "title": meta["title"],
            "description": meta["description"], "site": meta["site"], "image": image}


def cache_key(prefix, url):
    return "lp:%s:%s" % (prefix, hashlib.sha256(url.encode("utf-8", "replace")).hexdigest())


def cached_preview(url, **kw):
    from django.core.cache import cache
    k = cache_key("pv", url)
    hit = cache.get(k)
    if hit is not None:
        return hit
    res = build_preview(url, **kw)
    cache.set(k, res, CACHE_S if res.get("ok") else NEG_CACHE_S)
    return res


# --------------------------------------------------------- safe-link check
SB_URL = "https://safebrowsing.googleapis.com/v4/threatMatches:find?key=%s"


def safe_browsing_key():
    import os
    from django.conf import settings
    return (getattr(settings, "GOOGLE_SAFE_BROWSING_KEY", "")
            or os.environ.get("GOOGLE_SAFE_BROWSING_KEY", "") or "").strip()


def safe_browsing(urls):
    """'unsafe' | 'clean' | 'not_configured' | 'error'.  Only called for
    NON-E2E content (channel posts)."""
    key = safe_browsing_key()
    if not key:
        return "not_configured"
    try:
        import requests
        body = {"client": {"clientId": "assisto", "clientVersion": "1.0"},
                "threatInfo": {"threatTypes": ["MALWARE", "SOCIAL_ENGINEERING",
                                               "UNWANTED_SOFTWARE",
                                               "POTENTIALLY_HARMFUL_APPLICATION"],
                               "platformTypes": ["ANY_PLATFORM"],
                               "threatEntryTypes": ["URL"],
                               "threatEntries": [{"url": u} for u in urls if u]}}
        r = requests.post(SB_URL % key, json=body, timeout=3)
        if r.status_code != 200:
            return "error"
        return "unsafe" if (r.json() or {}).get("matches") else "clean"
    except Exception:  # noqa: BLE001
        return "error"


def check_link(url, resolver=None, opener=None):
    """Heuristics on the URL and (for shorteners / redirects) on the REAL
    destination, resolved server-side through the SSRF-safe fetcher."""
    from .logic import safe_link as SL
    res = SL.check(url)
    out = {**res, "url": url, "final_url": url, "final_host": res["host"]}
    if "shortener" in res["reasons"]:
        try:
            r = safe_fetch(url, 1, resolver, opener, want_body=False)
            out["final_url"] = r["final_url"]
        except Blocked as e:
            out["resolve_error"] = str(e)
        except Exception:  # noqa: BLE001
            out["resolve_error"] = "unreachable"
        if out["final_url"] != url:
            fin = SL.check(out["final_url"])
            out["final_host"] = fin["host"]
            out["reasons"] = sorted(set(res["reasons"]) | set(fin["reasons"]))
            if fin["verdict"] == "bad" or res["verdict"] == "bad":
                out["verdict"] = "bad"
            if fin["brand"]:
                out["brand"] = fin["brand"]
    sb = safe_browsing([url, out["final_url"]] if out["final_url"] != url else [url])
    out["safe_browsing"] = sb
    if sb == "unsafe":
        out["verdict"] = "bad"
        out["reasons"] = sorted(set(out["reasons"]) | {"safe_browsing"})
    return out
