"""Minimal ONVIF client (stdlib + requests): WS-Discovery probe on the LAN and
the few SOAP calls the camera check needs.

  * WS-Discovery: one multicast Probe for dn:NetworkVideoTransmitter to
    239.255.255.250:3702, ProbeMatches collected for `timeout_s`.
  * SOAP 1.2 with WS-Security UsernameToken PasswordDigest
    (Base64(SHA1(nonce + created + password))); HTTP Digest is tried once as a
    fallback when the camera answers 401 to WS-Security.
  * GetDeviceInformation, GetCapabilities (media / events xaddr + PullPoint
    support), GetProfiles, GetStreamUri, GetSnapshotUri, GetEventProperties.

Parsing is defensive: namespaces are ignored (cameras disagree on prefixes and
versions), responses are capped at 256 KB, DTDs/entities are refused, and
every call has a short timeout. Nothing here ever logs a password.
"""
from __future__ import annotations

import base64
import hashlib
import os
import socket
import time
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional, Tuple
from urllib.parse import unquote, urlsplit

MAX_RESPONSE = 256 * 1024
MULTICAST = ("239.255.255.250", 3702)
MAX_DEVICES = 32
MAX_SCOPES = 8


class OnvifError(Exception):
    """code: unreachable | timeout | auth_failed | bad_response | fault"""

    def __init__(self, code: str, detail: str = ""):
        super().__init__(code)
        self.code = code
        self.detail = detail[:200]


# --------------------------------------------------------------------- XML
def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def parse_xml(data: bytes) -> ET.Element:
    if not data or len(data) > MAX_RESPONSE:
        raise OnvifError("bad_response", "empty or too large")
    head = data[:4096].upper()
    if b"<!DOCTYPE" in head or b"<!ENTITY" in data.upper():
        raise OnvifError("bad_response", "DTD refused")
    try:
        return ET.fromstring(data)
    except ET.ParseError as exc:
        raise OnvifError("bad_response", "xml: %s" % exc)


def find_all(root: ET.Element, name: str) -> List[ET.Element]:
    return [e for e in root.iter() if local(e.tag) == name]


def find(root: Optional[ET.Element], name: str) -> Optional[ET.Element]:
    if root is None:
        return None
    for e in root.iter():
        if local(e.tag) == name:
            return e
    return None


def text(root: Optional[ET.Element], name: str) -> Optional[str]:
    e = find(root, name)
    if e is None or e.text is None:
        return None
    t = e.text.strip()
    return t or None


def _fault(root: ET.Element) -> Optional[str]:
    f = find(root, "Fault")
    if f is None:
        return None
    parts = [(e.text or "").strip() for e in f.iter()
             if local(e.tag) in ("Value", "Text", "faultstring", "faultcode")]
    return " ".join(p for p in parts if p)[:200] or "fault"


def _is_auth_fault(msg: str) -> bool:
    m = (msg or "").lower()
    return any(k in m for k in ("notauthorized", "not authorized", "sender not",
                                "failedauthentication", "unauthorized",
                                "authority failure", "invalidsecurity"))


# --------------------------------------------------------------- discovery
PROBE_TEMPLATE = (
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
    'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
    'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
    '<e:Header><w:MessageID>uuid:%s</w:MessageID>'
    '<w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
    '<w:Action e:mustUnderstand="true">'
    'http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>'
    '<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe>'
    '</e:Body></e:Envelope>')


def probe_message(message_id: Optional[str] = None) -> bytes:
    return (PROBE_TEMPLATE % (message_id or uuid.uuid4())).encode("utf-8")


def parse_scopes(scopes: List[str]) -> Dict[str, Optional[str]]:
    """onvif://www.onvif.org/hardware/<model>, /name/<name>, /mfr|manufacturer/<x>."""
    out: Dict[str, Optional[str]] = {"manufacturer": None, "model": None, "name": None}
    for s in scopes:
        low = s.lower()
        if not low.startswith("onvif://www.onvif.org/"):
            continue
        rest = s[len("onvif://www.onvif.org/"):]
        key, _, val = rest.partition("/")
        val = unquote(val).strip()[:80] or None
        k = key.lower()
        if k == "hardware" and not out["model"]:
            out["model"] = val
        elif k == "name" and not out["name"]:
            out["name"] = val
        elif k in ("mfr", "manufacturer") and not out["manufacturer"]:
            out["manufacturer"] = val
    return out


def parse_probe_matches(data: bytes, sender_ip: Optional[str] = None) -> List[dict]:
    """One UDP datagram -> list of discovered device dicts (contract shape)."""
    try:
        root = parse_xml(data)
    except OnvifError:
        return []
    out = []
    for pm in find_all(root, "ProbeMatch"):
        xaddrs = (text(pm, "XAddrs") or "").split()
        scopes = (text(pm, "Scopes") or "").split()
        xaddr = next((x for x in xaddrs if x.lower().startswith("http")), None)
        host = None
        if xaddr:
            try:
                host = urlsplit(xaddr).hostname
            except ValueError:
                host = None
        host = host or sender_ip
        if not host:
            continue
        meta = parse_scopes(scopes)
        out.append({"host": host, "xaddr": xaddr, "manufacturer": meta["manufacturer"],
                    "model": meta["model"], "name": meta["name"],
                    "scopes": [s[:200] for s in scopes[:MAX_SCOPES]]})
    return out


def discover(timeout_s: float = 4.0, sock_factory: Optional[Callable] = None,
             clock: Callable[[], float] = time.monotonic) -> List[dict]:
    """WS-Discovery on the local network. Returns <= 32 unique devices."""
    timeout_s = max(1.0, min(float(timeout_s or 4.0), 15.0))
    if sock_factory is None:
        def sock_factory():
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
            s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
            s.bind(("", 0))
            return s
    sock = sock_factory()
    found: Dict[str, dict] = {}
    try:
        msg = probe_message()
        sock.sendto(msg, MULTICAST)
        deadline = clock() + timeout_s
        resent = False
        while len(found) < MAX_DEVICES:
            left = deadline - clock()
            if left <= 0:
                break
            if not resent and left < timeout_s / 2:
                sock.sendto(msg, MULTICAST)     # UDP is lossy: probe twice
                resent = True
            sock.settimeout(min(left, 0.5))
            try:
                data, addr = sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            for dev in parse_probe_matches(data, addr[0] if addr else None):
                key = dev["xaddr"] or dev["host"]
                if key not in found and len(found) < MAX_DEVICES:
                    found[key] = dev
    finally:
        try:
            sock.close()
        except OSError:
            pass
    return list(found.values())


# ---------------------------------------------------------- WS-Security
def password_digest(nonce: bytes, created: str, password: str) -> str:
    h = hashlib.sha1(nonce + created.encode("utf-8") + password.encode("utf-8"))
    return base64.b64encode(h.digest()).decode("ascii")


def _xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


def wsse_header(username: str, password: str, nonce: Optional[bytes] = None,
                created: Optional[str] = None) -> str:
    nonce = nonce if nonce is not None else os.urandom(16)
    created = created or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    return (
        '<s:Header><wsse:Security s:mustUnderstand="1" '
        'xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" '
        'xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">'
        '<wsse:UsernameToken><wsse:Username>%s</wsse:Username>'
        '<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/'
        'oasis-200401-wss-username-token-profile-1.0#PasswordDigest">%s</wsse:Password>'
        '<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/'
        'oasis-200401-wss-soap-message-security-1.0#Base64Binary">%s</wsse:Nonce>'
        '<wsu:Created>%s</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header>'
    ) % (_xml_escape(username), password_digest(nonce, created, password),
         base64.b64encode(nonce).decode("ascii"), created)


def envelope(body: str, username: Optional[str] = None,
             password: Optional[str] = None) -> bytes:
    header = wsse_header(username, password or "") if username else ""
    return ('<?xml version="1.0" encoding="UTF-8"?>'
            '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
            'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
            'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
            'xmlns:tev="http://www.onvif.org/ver10/events/wsdl" '
            'xmlns:tt="http://www.onvif.org/ver10/schema">'
            '%s<s:Body>%s</s:Body></s:Envelope>' % (header, body)).encode("utf-8")


# --------------------------------------------------------------- HTTP POST
def requests_post(url: str, data: bytes, headers: dict, timeout: float,
                  auth: Optional[Tuple[str, str]] = None) -> Tuple[int, bytes]:
    """Default transport: (status, body<=256KB). Raises OnvifError."""
    import requests
    from requests.auth import HTTPDigestAuth

    try:
        r = requests.post(url, data=data, headers=headers, timeout=timeout,
                          stream=True, allow_redirects=False,
                          auth=HTTPDigestAuth(*auth) if auth else None)
    except requests.Timeout:
        raise OnvifError("timeout", "ONVIF request timed out")
    except requests.RequestException as exc:
        raise OnvifError("unreachable", type(exc).__name__)
    try:
        buf = b""
        for chunk in r.iter_content(16384):
            buf += chunk
            if len(buf) > MAX_RESPONSE:
                raise OnvifError("bad_response", "response too large")
        return r.status_code, buf
    except requests.RequestException as exc:
        raise OnvifError("timeout", type(exc).__name__)
    finally:
        r.close()


class OnvifClient:
    """One camera's ONVIF services. `post` is injectable for tests."""

    def __init__(self, device_xaddr: str, username: Optional[str] = None,
                 password: Optional[str] = None, post: Callable = requests_post,
                 timeout: float = 5.0):
        self.device_xaddr = device_xaddr
        self.username = username
        self.password = password
        self.post = post
        self.timeout = float(timeout)
        self.media_xaddr: Optional[str] = None
        self.events_xaddr: Optional[str] = None
        self.pullpoint = False
        self._use_http_digest = False

    @classmethod
    def for_host(cls, host: str, port: int = 80, **kw) -> "OnvifClient":
        h = "[%s]" % host if ":" in host and not host.startswith("[") else host
        return cls("http://%s:%d/onvif/device_service" % (h, int(port)), **kw)

    def call(self, url: str, body: str) -> ET.Element:
        headers = {"Content-Type": "application/soap+xml; charset=utf-8"}
        auth = (self.username or "", self.password or "") \
            if (self._use_http_digest and self.username) else None
        status, data = self.post(url, envelope(body, self.username, self.password),
                                 headers, self.timeout, auth)
        if status == 401 and self.username and not self._use_http_digest:
            self._use_http_digest = True        # some firmwares want HTTP Digest
            status, data = self.post(url, envelope(body, self.username, self.password),
                                     headers, self.timeout,
                                     (self.username, self.password or ""))
        if status in (401, 403):
            raise OnvifError("auth_failed", "HTTP %d" % status)
        try:
            root = parse_xml(data)
        except OnvifError:
            if status >= 400:
                raise OnvifError("fault", "HTTP %d" % status)
            raise
        fault = _fault(root)
        if fault:
            raise OnvifError("auth_failed" if _is_auth_fault(fault) else "fault", fault)
        if status >= 400:
            raise OnvifError("fault", "HTTP %d" % status)
        return root

    # ---------------------------------------------------------- device
    def get_device_information(self) -> Dict[str, Optional[str]]:
        r = self.call(self.device_xaddr, "<tds:GetDeviceInformation/>")
        return {"manufacturer": text(r, "Manufacturer"), "model": text(r, "Model"),
                "firmware": text(r, "FirmwareVersion")}

    def get_capabilities(self) -> Dict[str, object]:
        r = self.call(self.device_xaddr,
                      "<tds:GetCapabilities><tds:Category>All</tds:Category>"
                      "</tds:GetCapabilities>")
        media, events = find(r, "Media"), find(r, "Events")
        self.media_xaddr = text(media, "XAddr") or self.media_xaddr
        self.events_xaddr = text(events, "XAddr") or self.events_xaddr
        pp = (text(events, "WSPullPointSupport") or "").lower()
        self.pullpoint = pp in ("true", "1")
        return {"media": self.media_xaddr, "events": self.events_xaddr,
                "pullpoint": self.pullpoint}

    def get_services(self) -> Dict[str, Optional[str]]:
        """Fallback for devices whose GetCapabilities is incomplete."""
        r = self.call(self.device_xaddr, "<tds:GetServices><tds:IncludeCapability>"
                      "true</tds:IncludeCapability></tds:GetServices>")
        for svc in find_all(r, "Service"):
            ns, xa = text(svc, "Namespace") or "", text(svc, "XAddr")
            if ns.endswith("/ver10/media/wsdl") and xa:
                self.media_xaddr = self.media_xaddr or xa
            elif ns.endswith("/ver10/events/wsdl") and xa:
                self.events_xaddr = self.events_xaddr or xa
                caps = find(svc, "Capabilities")
                if caps is not None:
                    for e in caps.iter():
                        if str(e.attrib.get("WSPullPointSupport", "")).lower() in (
                                "true", "1"):
                            self.pullpoint = True
        return {"media": self.media_xaddr, "events": self.events_xaddr}

    def _media(self) -> str:
        if not self.media_xaddr:
            try:
                self.get_capabilities()
            except OnvifError as exc:
                if exc.code == "auth_failed":
                    raise
            if not self.media_xaddr:
                self.get_services()
        return self.media_xaddr or self.device_xaddr

    # ----------------------------------------------------------- media
    def get_profiles(self) -> List[dict]:
        r = self.call(self._media(), "<trt:GetProfiles/>")
        out = []
        for p in find_all(r, "Profiles"):
            tok = p.attrib.get("token")
            if not tok:
                continue
            venc = find(p, "VideoEncoderConfiguration")
            w = text(venc, "Width")
            h = text(venc, "Height")
            out.append({"token": tok[:64], "name": text(p, "Name"),
                        "encoding": text(venc, "Encoding"),
                        "width": int(w) if w and w.isdigit() else None,
                        "height": int(h) if h and h.isdigit() else None})
        return out

    def get_stream_uri(self, profile_token: str) -> Optional[str]:
        r = self.call(self._media(), (
            "<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream>"
            "<tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>"
            "</trt:StreamSetup><trt:ProfileToken>%s</trt:ProfileToken>"
            "</trt:GetStreamUri>") % _xml_escape(profile_token))
        return text(r, "Uri")

    def get_snapshot_uri(self, profile_token: str) -> Optional[str]:
        r = self.call(self._media(), ("<trt:GetSnapshotUri><trt:ProfileToken>%s"
                                      "</trt:ProfileToken></trt:GetSnapshotUri>")
                      % _xml_escape(profile_token))
        return text(r, "Uri")

    # ---------------------------------------------------------- events
    def get_event_properties(self) -> bool:
        """True when the camera answers GetEventProperties (events supported)."""
        url = self.events_xaddr
        if not url:
            try:
                self.get_capabilities()
            except OnvifError as exc:
                if exc.code == "auth_failed":
                    raise
            url = self.events_xaddr
        if not url:
            raise OnvifError("not_supported", "no events service")
        r = self.call(url, "<tev:GetEventProperties/>")
        return find(r, "GetEventPropertiesResponse") is not None or \
            find(r, "TopicSet") is not None
