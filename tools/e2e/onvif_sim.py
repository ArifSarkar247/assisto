"""Minimal simulated ONVIF camera (e2e harness) — Profile S subset.

    python onvif_sim.py --http-port 18080 --user admin --password onvifpw \
        --rtsp rtsp://127.0.0.1:18554/cam1

  * WS-Discovery: joins 239.255.255.250:3702 and answers a Probe for
    dn:NetworkVideoTransmitter with a ProbeMatch (XAddrs + onvif:// scopes),
    exactly like a camera on the shop LAN (ONVIF Core spec §7, WS-Discovery
    2005/04). --no-discovery skips it (e.g. a host where UDP 3702 is taken).
  * SOAP 1.2 device/media/events services on --http-port:
    GetDeviceInformation, GetCapabilities, GetServices, GetProfiles,
    GetStreamUri (-> the mediamtx stream), GetSnapshotUri,
    GetEventProperties. Every call except GetSystemDateAndTime requires a
    valid WS-Security UsernameToken PasswordDigest
    (Base64(SHA1(nonce + created + password))); a wrong one gets the
    ter:NotAuthorized SOAP fault real cameras send.
Message shapes follow the ONVIF WSDLs (devicemgmt.wsdl, media.wsdl,
event.wsdl at https://www.onvif.org/ver10/).
"""
import argparse
import base64
import hashlib
import re
import socket
import struct
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NS = ('xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
      'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
      'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
      'xmlns:tev="http://www.onvif.org/ver10/events/wsdl" '
      'xmlns:tt="http://www.onvif.org/ver10/schema" '
      'xmlns:wstop="http://docs.oasis-open.org/wsn/t-1" '
      'xmlns:ter="http://www.onvif.org/ver10/error"')


def env(body):
    return ('<?xml version="1.0" encoding="UTF-8"?><s:Envelope %s><s:Body>%s'
            '</s:Body></s:Envelope>' % (NS, body)).encode()


FAULT_AUTH = env('<s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode>'
                 '<s:Value>ter:NotAuthorized</s:Value></s:Subcode></s:Code>'
                 '<s:Reason><s:Text xml:lang="en">Sender not Authorized</s:Text>'
                 '</s:Reason></s:Fault>')


class Cfg:
    user = "admin"
    password = ""
    rtsp = ""
    http_port = 18080
    host = "127.0.0.1"
    calls = []


def _tag(xml, name):
    m = re.search(r"<(?:\w+:)?%s\b[^>]*>(.*?)</(?:\w+:)?%s>" % (name, name), xml, re.S)
    return m.group(1).strip() if m else None


def auth_ok(xml):
    user, pw = _tag(xml, "Username"), _tag(xml, "Password")
    nonce, created = _tag(xml, "Nonce"), _tag(xml, "Created")
    if not (user and pw and nonce and created) or user != Cfg.user:
        return False
    want = base64.b64encode(hashlib.sha1(
        base64.b64decode(nonce) + created.encode() + Cfg.password.encode()).digest())
    return want.decode() == pw


def xaddr(path):
    return "http://%s:%d/onvif/%s" % (Cfg.host, Cfg.http_port, path)


def answer(op):
    if op == "GetDeviceInformation":
        return env("<tds:GetDeviceInformationResponse><tds:Manufacturer>AssistoSim"
                   "</tds:Manufacturer><tds:Model>E2E-ONVIF-1</tds:Model>"
                   "<tds:FirmwareVersion>1.0.0</tds:FirmwareVersion>"
                   "<tds:SerialNumber>SIM0001</tds:SerialNumber><tds:HardwareId>1"
                   "</tds:HardwareId></tds:GetDeviceInformationResponse>")
    if op == "GetCapabilities":
        return env("<tds:GetCapabilitiesResponse><tds:Capabilities>"
                   "<tt:Device><tt:XAddr>%s</tt:XAddr></tt:Device>"
                   "<tt:Events><tt:XAddr>%s</tt:XAddr><tt:WSSubscriptionPolicySupport>"
                   "true</tt:WSSubscriptionPolicySupport><tt:WSPullPointSupport>true"
                   "</tt:WSPullPointSupport></tt:Events>"
                   "<tt:Media><tt:XAddr>%s</tt:XAddr></tt:Media>"
                   "</tds:Capabilities></tds:GetCapabilitiesResponse>"
                   % (xaddr("device_service"), xaddr("event_service"),
                      xaddr("media_service")))
    if op == "GetServices":
        return env("<tds:GetServicesResponse><tds:Service><tds:Namespace>"
                   "http://www.onvif.org/ver10/media/wsdl</tds:Namespace><tds:XAddr>%s"
                   "</tds:XAddr></tds:Service></tds:GetServicesResponse>"
                   % xaddr("media_service"))
    if op == "GetProfiles":
        prof = ('<trt:Profiles token="%s" fixed="true"><tt:Name>%s</tt:Name>'
                '<tt:VideoEncoderConfiguration token="v%s"><tt:Name>v</tt:Name>'
                '<tt:Encoding>H264</tt:Encoding><tt:Resolution><tt:Width>%d'
                '</tt:Width><tt:Height>%d</tt:Height></tt:Resolution>'
                '</tt:VideoEncoderConfiguration></trt:Profiles>')
        return env("<trt:GetProfilesResponse>%s%s</trt:GetProfilesResponse>" % (
            prof % ("Profile_1", "mainStream", "1", 640, 360),
            prof % ("Profile_2", "subStream", "2", 640, 360)))
    if op == "GetStreamUri":
        return env("<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>%s</tt:Uri>"
                   "<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect>"
                   "<tt:InvalidAfterReboot>false</tt:InvalidAfterReboot>"
                   "<tt:Timeout>PT0S</tt:Timeout></trt:MediaUri>"
                   "</trt:GetStreamUriResponse>" % Cfg.rtsp)
    if op == "GetSnapshotUri":
        return env("<trt:GetSnapshotUriResponse><trt:MediaUri><tt:Uri>%s</tt:Uri>"
                   "</trt:MediaUri></trt:GetSnapshotUriResponse>"
                   % xaddr("snapshot.jpg"))
    if op == "GetEventProperties":
        return env("<tev:GetEventPropertiesResponse><tev:TopicNamespaceLocation>"
                   "http://www.onvif.org/onvif/ver10/topics/topicns.xml"
                   "</tev:TopicNamespaceLocation><wstop:FixedTopicSet>true"
                   "</wstop:FixedTopicSet><wstop:TopicSet><tns1:RuleEngine "
                   'xmlns:tns1="http://www.onvif.org/ver10/topics"><CellMotionDetector>'
                   '<Motion wstop:topic="true"/></CellMotionDetector></tns1:RuleEngine>'
                   "</wstop:TopicSet></tev:GetEventPropertiesResponse>")
    if op == "GetSystemDateAndTime":
        return env("<tds:GetSystemDateAndTimeResponse/>")
    return None


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        xml = self.rfile.read(min(n, 256 * 1024)).decode("utf-8", "replace")
        m = re.search(r"<s:Body>\s*<(?:\w+:)?(\w+)", xml)
        op = m.group(1) if m else ""
        Cfg.calls.append(op)
        if op != "GetSystemDateAndTime" and not auth_ok(xml):
            return self._out(400, FAULT_AUTH)
        body = answer(op)
        if body is None:
            return self._out(400, env("<s:Fault><s:Code><s:Value>s:Receiver"
                                      "</s:Value></s:Code></s:Fault>"))
        self._out(200, body)

    def _out(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/soap+xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def probe_match(relates_to):
    return ('<?xml version="1.0" encoding="UTF-8"?>'
            '<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" '
            'xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
            'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
            'xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><SOAP-ENV:Header>'
            '<wsa:MessageID>uuid:%s</wsa:MessageID><wsa:RelatesTo>%s</wsa:RelatesTo>'
            '<wsa:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous'
            '</wsa:To><wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/'
            'ProbeMatches</wsa:Action></SOAP-ENV:Header><SOAP-ENV:Body>'
            '<d:ProbeMatches><d:ProbeMatch><wsa:EndpointReference><wsa:Address>'
            'urn:uuid:5f5a69c2-e0ae-504f-829b-00fa0e2e5e5e</wsa:Address>'
            '</wsa:EndpointReference><d:Types>dn:NetworkVideoTransmitter</d:Types>'
            '<d:Scopes>onvif://www.onvif.org/type/video_encoder '
            'onvif://www.onvif.org/hardware/E2E-ONVIF-1 '
            'onvif://www.onvif.org/name/Assisto%%20Sim%%20Camera '
            'onvif://www.onvif.org/mfr/AssistoSim</d:Scopes>'
            '<d:XAddrs>%s</d:XAddrs><d:MetadataVersion>1</d:MetadataVersion>'
            '</d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>'
            % (uuid.uuid4(), relates_to, xaddr("device_service"))).encode()


def discovery_loop():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", 3702))
    grp = socket.inet_aton("239.255.255.250")
    # the LAN NIC (a real camera) and loopback (CI / hosts whose firewall drops
    # inbound multicast; the Shop Box probes every local interface)
    for iface in (struct.pack("=I", socket.INADDR_ANY), socket.inet_aton("127.0.0.1")):
        try:
            s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, grp + iface)
        except OSError:
            pass
    while True:
        data, addr = s.recvfrom(65535)
        txt = data.decode("utf-8", "replace")
        if "Probe" not in txt or "ProbeMatches" in txt:
            continue
        if "NetworkVideoTransmitter" not in txt:
            continue
        mid = _tag(txt, "MessageID") or ""
        s.sendto(probe_match(mid), addr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--http-port", type=int, default=18080)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", required=True)
    ap.add_argument("--rtsp", required=True)
    ap.add_argument("--no-discovery", action="store_true")
    a = ap.parse_args()
    Cfg.user, Cfg.password, Cfg.rtsp, Cfg.http_port = (a.user, a.password, a.rtsp,
                                                       a.http_port)
    if not a.no_discovery:
        threading.Thread(target=discovery_loop, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", a.http_port), H).serve_forever()


if __name__ == "__main__":
    main()
