"""Camera check with fakes: ok, unreachable, wrong password, timeout, ONVIF,
and the hard rule that no secret ever appears in the result."""
import json
import socket

import numpy as np

from shopbox import compat, onvif

SECRET = "S4fety-Code!9"
REQ = {"vendor": "imou", "host": "192.168.1.20", "port": 554, "channel": 1,
       "stream": "sub", "username": "admin", "secret": SECRET}


def tcp_ok(host, port, timeout):
    return None


def tcp_refused(host, port, timeout):
    raise ConnectionRefusedError()


def tcp_timeout(host, port, timeout):
    raise socket.timeout()


def tcp_rtsp_only(host, port, timeout):
    if port != 554:
        raise ConnectionRefusedError()


def describe_ok(url, user, secret, timeout):
    assert "@" not in url                    # creds never in the request line
    return 200, "v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"


def describe_401(url, user, secret, timeout):
    return 401, ""


def opener_ok(url, timeout):
    assert SECRET.replace("!", "%21") in url   # FFmpeg gets the credentialed URL
    return {"ok": True, "frame": np.full((720, 1280, 3), 100, np.uint8),
            "width": 1280, "height": 720, "fps": 14.8, "codec": "h264"}


def opener_timeout(url, timeout):
    return {"ok": False, "code": "timeout",
            "detail": "no frames from %s" % url}     # deliberately leaky detail


def no_onvif(*a):
    raise OSError("no onvif")


def assert_no_secret(out):
    blob = json.dumps(out.result)
    assert SECRET not in blob and "S4fety" not in blob
    assert "admin:" not in blob and "@192" not in blob


def test_check_ok_full_result_and_snapshot():
    out = compat.run_check(REQ, tcp=tcp_rtsp_only, describe=describe_ok,
                           opener=opener_ok, onvif=no_onvif)
    r = out.result
    assert r["ok"] is True
    steps = {s["key"]: s for s in r["steps"]}
    assert [s["key"] for s in r["steps"]] == list(compat.STEP_KEYS)
    assert steps["reachable"]["ok"] and steps["auth"]["ok"] and steps["stream"]["ok"]
    assert steps["snapshot"]["ok"] is True
    assert steps["events"]["ok"] is None and steps["events"]["code"] == "not_checked"
    assert r["info"]["width"] == 1280 and r["info"]["codec"] == "h264"
    assert r["info"]["rtsp_path"] == "/cam/realmonitor?channel=1&subtype=1"
    # one JPEG, long side <= 640
    import cv2
    assert out.snapshot[:3] == b"\xff\xd8\xff"
    img = cv2.imdecode(np.frombuffer(out.snapshot, np.uint8), cv2.IMREAD_COLOR)
    assert max(img.shape[:2]) <= 640
    assert out.stream_url == "rtsp://192.168.1.20:554/cam/realmonitor?channel=1&subtype=1"
    assert out.user == "admin" and out.secret == SECRET
    assert_no_secret(out)


def test_unreachable_and_tcp_timeout():
    out = compat.run_check(REQ, tcp=tcp_refused, describe=describe_ok,
                           opener=opener_ok, onvif=no_onvif)
    s = out.result["steps"][0]
    assert out.result["ok"] is False and s["code"] == "unreachable"
    assert out.snapshot is None and out.stream_url is None
    out = compat.run_check(REQ, tcp=tcp_timeout, describe=describe_ok,
                           opener=opener_ok, onvif=no_onvif)
    assert out.result["steps"][0]["code"] == "timeout"
    assert all(s["ok"] is None for s in out.result["steps"][1:])


def test_wrong_password_is_auth_failed():
    out = compat.run_check(REQ, tcp=tcp_rtsp_only, describe=describe_401,
                           opener=opener_ok, onvif=no_onvif)
    steps = {s["key"]: s for s in out.result["steps"]}
    assert out.result["ok"] is False
    assert steps["auth"]["ok"] is False and steps["auth"]["code"] == "auth_failed"
    assert steps["stream"]["ok"] is None
    assert_no_secret(out)


def test_stream_timeout_and_leaky_detail_is_scrubbed():
    out = compat.run_check(REQ, tcp=tcp_rtsp_only, describe=describe_ok,
                           opener=opener_timeout, onvif=no_onvif)
    steps = {s["key"]: s for s in out.result["steps"]}
    assert out.result["ok"] is False
    assert steps["stream"]["code"] == "timeout"
    assert_no_secret(out)


def test_unknown_describe_error_stays_honest():
    def describe_boom(*a):
        raise ConnectionResetError()

    out = compat.run_check(REQ, tcp=tcp_rtsp_only, describe=describe_boom,
                           opener=lambda u, t: {"ok": False, "detail": "x"},
                           onvif=no_onvif)
    steps = {s["key"]: s for s in out.result["steps"]}
    assert steps["auth"]["ok"] is None            # not claimed as wrong password
    assert steps["stream"]["code"] == "stream_failed"


class FakeOnvif:
    pullpoint = True

    def __init__(self, auth_ok=True, events=True):
        self.auth_ok, self.events = auth_ok, events

    def get_device_information(self):
        if not self.auth_ok:
            raise onvif.OnvifError("auth_failed", "NotAuthorized")
        return {"manufacturer": "Hikvision", "model": "DS-2CD1023"}

    def get_capabilities(self):
        return {"pullpoint": True}

    def get_profiles(self):
        return [{"token": "p0"}, {"token": "p1"}]

    def get_stream_uri(self, token):
        return "rtsp://192.168.1.64:554/Streaming/Channels/%s" % (
            "101" if token == "p0" else "102")

    def get_event_properties(self):
        return self.events


def test_onvif_vendor_resolves_stream_and_events():
    req = {"vendor": "onvif", "host": "192.168.1.64", "onvif_port": 80,
           "stream": "sub", "username": "admin", "secret": SECRET}
    out = compat.run_check(req, tcp=tcp_ok, describe=describe_ok,
                           opener=lambda u, t: {"ok": True, "frame": np.zeros(
                               (360, 640, 3), np.uint8), "width": 640, "height": 360,
                               "fps": 10.0},
                           onvif=lambda h, p, u, s: FakeOnvif())
    r = out.result
    assert r["ok"] and r["info"]["onvif"] and r["info"]["events_supported"]
    assert r["info"]["manufacturer"] == "Hikvision"
    assert r["info"]["rtsp_path"] == "/Streaming/Channels/102"
    ev = [s for s in r["steps"] if s["key"] == "events"][0]
    assert ev["ok"] is True and "PullPoint" in ev["detail"]
    assert_no_secret(out)


def test_onvif_vendor_auth_failed():
    req = {"vendor": "onvif", "host": "192.168.1.64", "username": "admin",
           "secret": SECRET}
    out = compat.run_check(req, tcp=tcp_ok, describe=describe_ok, opener=opener_ok,
                           onvif=lambda h, p, u, s: FakeOnvif(auth_ok=False))
    auth = [s for s in out.result["steps"] if s["key"] == "auth"][0]
    assert out.result["ok"] is False and auth["code"] == "auth_failed"


def test_custom_rtsp_url_credentials_never_returned():
    req = {"vendor": "rtsp", "rtsp_url": "rtsp://user:%s@10.0.0.9:8554/live" % SECRET}
    out = compat.run_check(req, tcp=tcp_ok, describe=describe_ok,
                           opener=lambda u, t: {"ok": True, "frame": np.zeros(
                               (100, 100, 3), np.uint8), "width": 100, "height": 100,
                               "fps": 5.0},
                           onvif=no_onvif)
    assert out.result["ok"]
    assert out.stream_url == "rtsp://10.0.0.9:8554/live"
    assert out.result["info"]["rtsp_path"] == "/live"
    assert_no_secret(out)


def test_rtsp_digest_auth_header():
    h = compat.rtsp_auth_header("DESCRIBE", "rtsp://h/x", "admin", "pw",
                                'Digest realm="IPC", nonce="abc"')
    assert h.startswith('Digest username="admin"') and "pw" not in h
    assert compat.rtsp_auth_header("DESCRIBE", "rtsp://h/x", "a", "b",
                                   'Basic realm="x"') == "Basic YTpi"


class RtspSock:
    """Answers 401 Digest, then 200 + SDP once the Authorization arrives."""

    def __init__(self):
        self.sent, self.out = [], b""

    def settimeout(self, t):
        pass

    def sendall(self, data):
        self.sent.append(data.decode())
        if "Authorization: Digest" in self.sent[-1]:
            sdp = "v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\n"
            self.out += ("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: %d\r\n\r\n%s"
                         % (len(sdp), sdp)).encode()
        else:
            self.out += (b'RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\n'
                         b'WWW-Authenticate: Digest realm="IPC", nonce="n1"\r\n\r\n')

    def recv(self, n):
        chunk, self.out = self.out[:n], self.out[n:]
        return chunk

    def close(self):
        pass


def test_rtsp_describe_digest_retry_and_codec():
    sock = RtspSock()
    st, sdp = compat.rtsp_describe("rtsp://192.168.1.20:554/cam/x", "admin", SECRET,
                                   connect=lambda addr, t: sock)
    assert st == 200 and compat.sdp_codec(sdp) == "h265"
    assert all(SECRET not in s for s in sock.sent)     # digest only, never plain
    assert sock.sent[0].startswith("DESCRIBE rtsp://192.168.1.20:554/cam/x RTSP/1.0")


def test_gateway_status_line_bangla_digits():
    from shopbox.strings import Tr, gateway_line
    assert gateway_line(Tr("bn"), "idle", {"action": "discover", "count": 12}) \
        .endswith("১২টি")
    assert "12" in gateway_line(Tr("en"), "idle", {"action": "discover", "count": 12})
    assert gateway_line(Tr("en"), "check", None) == Tr("en")("gw_checking")
    assert gateway_line(Tr("en"), "idle", None) == ""


def test_run_discover_shape_and_failure():
    devs = [{"host": "192.168.1.%d" % i, "xaddr": None, "manufacturer": None,
             "model": None, "name": None, "scopes": []} for i in range(40)]
    r = compat.run_discover({"timeout_s": 2}, discover=lambda t: devs)
    assert r["ok"] and len(r["discovered"]) == 32

    def boom(t):
        raise OSError("no multicast")
    r = compat.run_discover({}, discover=boom)
    assert r["ok"] is False and r["discovered"] == []
