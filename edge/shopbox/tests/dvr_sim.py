"""A tiny simulated Hikvision (ISAPI) + Dahua (CGI) DVR for the camlink
tests and the CI E2E: a real HTTP server on 127.0.0.1 with HTTP DIGEST auth
(like the real boxes), synthetic data only. State is mutable so a test can
fail a disk, stop recording or unplug a camera and watch the report change.
"""
import hashlib
import re
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REALM = "DVR-SIM"
USER, PASSWORD = "admin", "Sim12345"
_AUTH_RE = re.compile(r'(\w+)="?([^",]+)"?')


def _md5(s):
    return hashlib.md5(s.encode()).hexdigest()


class DvrState:
    def __init__(self, vendor="hikvision", channels=4):
        self.vendor = vendor
        self.serial = "SIM%sDVR0001" % ("HK" if vendor == "hikvision" else "DH")
        self.channels = channels
        self.offline = set()
        self.not_recording = set()
        self.disk = "ok"            # ok | error | unformatted | none | full
        self.overwrite = True
        self.total_gb, self.free_gb = 1000.0, 300.0
        self.oldest = time.time() - 12 * 86400
        self.latest = time.time() - 60
        self.events = []            # raw multipart parts for the stream


def _iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class _Handler(BaseHTTPRequestHandler):
    state = None        # set per server
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    # ---- digest
    def _authed(self):
        h = self.headers.get("Authorization") or ""
        if not h.startswith("Digest "):
            return False
        p = dict(_AUTH_RE.findall(h))
        if p.get("username") != USER:
            return False
        ha1 = _md5("%s:%s:%s" % (USER, REALM, PASSWORD))
        ha2 = _md5("%s:%s" % (self.command, p.get("uri", "")))
        if p.get("qop"):
            want = _md5("%s:%s:%s:%s:%s:%s" % (ha1, p.get("nonce"), p.get("nc"),
                                                p.get("cnonce"), p.get("qop"), ha2))
        else:
            want = _md5("%s:%s:%s" % (ha1, p.get("nonce"), ha2))
        return want == p.get("response")

    def _challenge(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Digest realm="%s", qop="auth", nonce="%s", '
                         'algorithm="MD5"' % (REALM, _md5(str(time.time()))))
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send(self, body, ctype="application/xml", code=200):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._route()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.body = self.rfile.read(n) if n else b""
        self._route()

    def _route(self):
        if not self._authed():
            return self._challenge()
        s = self.state
        p = self.path
        if s.vendor == "hikvision":
            return self._hik(s, p)
        return self._dahua(s, p)

    # ---- Hikvision ISAPI
    def _hik(self, s, p):
        if p == "/ISAPI/System/deviceInfo":
            return self._send("<DeviceInfo><deviceName>Shop NVR</deviceName><model>DS-SIM-7604</model>"
                              "<serialNumber>%s</serialNumber><firmwareVersion>V4.0</firmwareVersion>"
                              "</DeviceInfo>" % s.serial)
        if p == "/ISAPI/System/workingstatus":
            ch = "".join("<ChanStatus><chanNo>%d</chanNo><online>%s</online><recordStatus>%s"
                         "</recordStatus><signal>%d</signal></ChanStatus>"
                         % (i, "false" if i in s.offline else "true",
                            "0" if i in s.not_recording or i in s.offline else "1",
                            1 if i in s.offline else 0)
                         for i in range(1, s.channels + 1))
            st = {"ok": "0", "unformatted": "1", "error": "2", "full": "0"}.get(s.disk, "0")
            hd = ("" if s.disk == "none" else
                  "<HDStatus><hdNo>1</hdNo><status>%s</status><volume>%d</volume>"
                  "<freeSpace>%d</freeSpace></HDStatus>" % (st, s.total_gb * 1024,
                                                            0 if s.disk == "full" else s.free_gb * 1024))
            return self._send("<WorkingStatus><runStatus>0</runStatus>%s%s</WorkingStatus>" % (ch, hd))
        if p == "/ISAPI/ContentMgmt/search":
            body = self.body.decode()
            start = re.search(r"<startTime>([^<]+)", body).group(1)
            end = re.search(r"<endTime>([^<]+)", body).group(1)
            t0 = datetime.fromisoformat(start.replace("Z", "+00:00")).timestamp()
            t1 = datetime.fromisoformat(end.replace("Z", "+00:00")).timestamp()
            lo, hi = max(t0, s.oldest), min(t1, s.latest)
            items = "" if lo >= hi else (
                "<searchMatchItem><timeSpan><startTime>%s</startTime><endTime>%s</endTime>"
                "</timeSpan></searchMatchItem>" % (_iso(lo), _iso(hi)))
            return self._send("<CMSearchResult><responseStatus>true</responseStatus>"
                              "<matchList>%s</matchList></CMSearchResult>" % items)
        if p == "/ISAPI/Event/notification/alertStream":
            parts = b"".join(b"--boundary\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n%s\r\n"
                             % (ct.encode(), len(b), b) for ct, b in s.events) + b"--boundary--\r\n"
            return self._send(parts, 'multipart/mixed; boundary=boundary')
        return self._send("<ResponseStatus><statusCode>4</statusCode></ResponseStatus>", code=404)

    # ---- Dahua CGI
    def _dahua(self, s, p):
        if p.startswith("/cgi-bin/magicBox.cgi?action=getSerialNo"):
            return self._send("sn=%s\r\n" % s.serial, "text/plain")
        if p.startswith("/cgi-bin/magicBox.cgi?action=getDeviceType"):
            return self._send("type=DHI-NVR-SIM\r\n", "text/plain")
        if p.startswith("/cgi-bin/storageDevice.cgi"):
            if s.disk == "none":
                return self._send("list.info[0].State=NotExist\r\n", "text/plain")
            used = s.total_gb if s.disk == "full" else s.total_gb - s.free_gb
            return self._send(
                "list.info[0].Name=/dev/sda\r\nlist.info[0].State=%s\r\n"
                "list.info[0].Detail[0].TotalBytes=%d\r\nlist.info[0].Detail[0].UsedBytes=%d\r\n"
                "list.info[0].Detail[0].IsError=%s\r\n"
                % ("Success" if s.disk in ("ok", "full") else "Error", s.total_gb * 1e9, used * 1e9,
                   "true" if s.disk == "error" else "false"), "text/plain")
        if "name=RecordMode" in p:
            return self._send("".join("table.RecordMode[%d].Mode=%s\r\n"
                                      % (i, "2" if (i + 1) in s.not_recording else "0")
                                      for i in range(s.channels)), "text/plain")
        if p.startswith("/cgi-bin/LogicDeviceManager.cgi"):
            return self._send("".join("states[%d].channel=%d\r\nstates[%d].connectionState=%s\r\n"
                                      % (i, i, i, "Disconnected" if (i + 1) in s.offline else "Connected")
                                      for i in range(s.channels)), "text/plain")
        if "name=StorageGlobal" in p:
            return self._send("table.StorageGlobal.OverWrite=%s\r\n"
                              % ("true" if s.overwrite else "false"), "text/plain")
        if p.startswith("/cgi-bin/eventManager.cgi"):
            parts = b"".join(b"--myboundary\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s\r\n"
                             % (len(b), b) for _ct, b in s.events) + b"--myboundary--\r\n"
            return self._send(parts, "multipart/x-mixed-replace; boundary=myboundary")
        return self._send("Error\r\nBad Request!\r\n", "text/plain", code=400)


class DvrSim:
    def __init__(self, vendor="hikvision", channels=4):
        self.state = DvrState(vendor, channels)
        handler = type("H", (_Handler,), {"state": self.state})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *a):
        self.server.shutdown()
        self.server.server_close()
