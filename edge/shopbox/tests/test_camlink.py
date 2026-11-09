"""camlink (CCTV Guard V3 A2 / A3 / B, agent cctvconnect): discovery
parsers, the multipart event-stream parser, and the ISAPI / Dahua health
probes against a REAL local HTTP DVR simulator with digest auth."""
import json
import socket
import struct
import time

import pytest

from shopbox.camlink import dahua_api as D
from shopbox.camlink import discovery as DS
from shopbox.camlink import health_probe as HP
from shopbox.camlink import isapi as H
from shopbox.camlink.multipart import MultipartStream, boundary_of

from dvr_sim import PASSWORD, USER, DvrSim

SADP_REPLY = (b'<?xml version="1.0" encoding="UTF-8"?><ProbeMatch><Uuid>X</Uuid>'
              b'<Types>inquiry</Types><DeviceType>139</DeviceType>'
              b'<DeviceDescription>DS-7608NI-K2</DeviceDescription>'
              b'<DeviceSN>DS-7608NI-K20820190101CCRRSIM0001WCVU</DeviceSN>'
              b'<CommandPort>8000</CommandPort><HttpPort>80</HttpPort>'
              b'<MAC>aa-bb-cc-00-00-01</MAC><IPv4Address>192.168.1.64</IPv4Address>'
              b'<Activated>true</Activated><AnalogChannelNum>0</AnalogChannelNum>'
              b'<DigitalChannelNum>8</DigitalChannelNum></ProbeMatch>')


def dahua_reply(ip="192.168.1.108"):
    return DS.dhip_packet({"method": "client.notifyDevInfo", "params": {"deviceInfo": {
        "DeviceType": "DHI-NVR4104HS", "SerialNo": "SIMDH0000000001", "HttpPort": 80,
        "Port": 37777, "Mac": "aa:bb:cc:00:00:02", "IPv4Address": {"IPAddress": ip},
        "VideoInputChannels": 4, "Init": False}}})


class FakeSock:
    def __init__(self, replies):
        self.replies = list(replies)
        self.sent = []

    def sendto(self, msg, dest):
        self.sent.append((msg, dest))

    def settimeout(self, t):
        pass

    def recvfrom(self, n):
        if self.replies:
            return self.replies.pop(0)
        raise socket.timeout()

    def close(self):
        pass


# ------------------------------------------------------------ discovery (A3)
def test_sadp_probe_and_parse():
    assert b"<Types>inquiry</Types>" in DS.sadp_probe("U1")
    rows = DS.parse_sadp(SADP_REPLY, "192.168.1.64")
    assert rows[0]["vendor"] == "hikvision" and rows[0]["model"] == "DS-7608NI-K2"
    assert rows[0]["serial"].startswith("DS-7608NI") and rows[0]["channels"] == 8
    assert rows[0]["activated"] is True and rows[0]["http_port"] == 80
    assert DS.parse_sadp(b"<!DOCTYPE x><x/>") == []          # DTD refused
    assert DS.parse_sadp(b"garbage") == []


def test_dahua_dhip_packet_and_parse():
    pkt = DS.dahua_probe()
    assert pkt[4:8] == b"DHIP"
    n = struct.unpack("<I", pkt[16:20])[0]
    assert json.loads(pkt[32:32 + n])["method"] == "DHDiscover.search"
    rows = DS.parse_dahua(dahua_reply())
    assert rows[0] == dict(rows[0], vendor="dahua", host="192.168.1.108",
                           serial="SIMDH0000000001", sdk_port=37777, channels=4,
                           activated=True)
    assert DS.parse_dahua(b"\x00" * 40) == []


def test_udp_search_dedupes_and_resends():
    clock = [0.0]

    def tick():
        clock[0] += 0.4
        return clock[0]
    sock = FakeSock([(SADP_REPLY, ("192.168.1.64", 37020)),
                     (SADP_REPLY, ("192.168.1.64", 37020))])
    rows = DS.udp_search([DS.SADP_ADDR], DS.sadp_probe(), DS.parse_sadp, 2.0,
                         sock_factory=lambda: sock, clock=tick)
    assert len(rows) == 1
    assert len(sock.sent) == 2          # sent twice (UDP is lossy)


def test_merge_prefers_vendor_rows_and_keeps_onvif_xaddr():
    onvif = [{"host": "192.168.1.64", "xaddr": "http://192.168.1.64/onvif/device_service",
              "manufacturer": "HIKVISION", "model": "DS-2CD"},
             {"host": "192.168.1.30", "xaddr": "http://192.168.1.30:2020/onvif",
              "manufacturer": "TP-Link", "model": "Tapo C200"}]
    rows = DS.discover_all(onvif_fn=lambda: onvif,
                           sadp_fn=lambda: DS.parse_sadp(SADP_REPLY),
                           dahua_fn=lambda: DS.parse_dahua(dahua_reply()))
    by = {r["host"]: r for r in rows}
    assert by["192.168.1.64"]["vendor"] == "hikvision"
    assert by["192.168.1.64"]["onvif"].startswith("http://192.168.1.64")
    assert by["192.168.1.64"]["sources"] == ["sadp", "onvif"]
    assert by["192.168.1.30"]["vendor"] == "tapo"
    assert by["192.168.1.108"]["vendor"] == "dahua"
    assert [r["host"] for r in rows] == ["192.168.1.30", "192.168.1.64", "192.168.1.108"]


def test_discover_all_survives_a_failing_method():
    def boom():
        raise OSError("no multicast here")
    rows = DS.discover_all(onvif_fn=boom, sadp_fn=lambda: DS.parse_sadp(SADP_REPLY),
                           dahua_fn=boom)
    assert [r["vendor"] for r in rows] == ["hikvision"]


# ------------------------------------------------------------ multipart (A2)
def test_multipart_stream_split_across_chunks():
    raw = (b"--boundary\r\nContent-Type: application/xml\r\nContent-Length: 11\r\n\r\n<a>one</a>\n\r\n"
           b"--boundary\r\nContent-Type: image/jpeg\r\nContent-Length: 3\r\n\r\nJPG\r\n"
           b"--boundary\r\nContent-Type: application/xml\r\n\r\n<b/>\r\n--boundary--\r\n")
    mp = MultipartStream(boundary_of('multipart/mixed; boundary="boundary"'))
    parts = []
    for i in range(0, len(raw), 7):
        parts += mp.feed(raw[i:i + 7])
    assert [p[0] for p in parts] == ["application/xml", "image/jpeg", "application/xml"]
    assert parts[0][1] == b"<a>one</a>\n" and parts[1][1] == b"JPG" and parts[2][1] == b"<b/>"


def test_heartbeat_dropped_and_event_forwarded():
    hb = (b'<EventNotificationAlert><eventType>videoloss</eventType>'
          b'<eventState>inactive</eventState></EventNotificationAlert>')
    ev = (b'<EventNotificationAlert><eventType>linedetection</eventType>'
          b'<eventState>active</eventState><targetType>human</targetType></EventNotificationAlert>')
    sent = []

    def post(url, body, headers):
        sent.append((url, body, headers))
        return 200
    assert H.forward_event(post, "https://x.test", "TOK", "application/xml", hb) is False
    assert H.forward_event(post, "https://x.test/", "TOK", "application/xml", ev) is True
    assert sent[0][0] == "https://x.test/api/v1/shop/hook/hikvision/TOK"
    assert D.forward_event(post, "https://x.test", "T2", "text/plain", b"Heartbeat") is False
    assert D.forward_event(post, "https://x.test", "T2", "text/plain",
                           b"Code=SmartMotionHuman;action=Start;index=0") is True
    assert sent[-1][0].endswith("/shop/hook/dahua/T2")


# ------------------------------------------------------------ ISAPI sim (A2 + B)
def test_isapi_probe_healthy_then_problems():
    with DvrSim("hikvision", channels=4) as sim:
        c = H.IsapiClient("127.0.0.1", sim.port, USER, PASSWORD)
        rep = HP.probe_hikvision(c)
        assert rep["device"] == sim.state.serial and rep["source"] == "isapi"
        assert [ch["online"] for ch in rep["channels"]] == [True] * 4
        assert all(ch["recording"] is True for ch in rep["channels"])
        assert rep["disks"][0]["state"] == "ok"
        assert 11 <= (time.time() - rep["oldest_record"]) / 86400 <= 13
        assert time.time() - rep["latest_record"] < 300
        # the owner's technician pulled camera 3, recording off on 2, disk failed
        sim.state.offline.add(3)
        sim.state.not_recording.add(2)
        sim.state.disk = "error"
        rep = HP.probe_hikvision(c)
        chans = {ch["no"]: ch for ch in rep["channels"]}
        assert chans[3]["online"] is False and chans[2]["recording"] is False
        assert rep["disks"][0]["state"] == "error"


def test_isapi_wrong_password_is_auth_failed_not_crash():
    with DvrSim("hikvision") as sim:
        rep = HP.probe_hikvision(H.IsapiClient("127.0.0.1", sim.port, USER, "wrong"))
        assert rep["error"] == "auth_failed"
        sent = []
        assert HP.post_reports(lambda *a: sent.append(a) or 200, "https://x", "S", [rep]) == 0
        assert sent == []


def test_isapi_alert_stream_parts():
    with DvrSim("hikvision") as sim:
        sim.state.events = [("application/xml",
                             b"<EventNotificationAlert><eventType>fielddetection</eventType>"
                             b"<eventState>active</eventState></EventNotificationAlert>"),
                            ("image/jpeg", b"\xff\xd8JPEG")]
        c = H.IsapiClient("127.0.0.1", sim.port, USER, PASSWORD)
        parts = list(c.alert_stream(timeout=5))
        assert [p[0] for p in parts] == ["application/xml", "image/jpeg"]
        assert b"fielddetection" in parts[0][1]


# ------------------------------------------------------------ Dahua sim
def test_dahua_probe_healthy_then_problems():
    with DvrSim("dahua", channels=4) as sim:
        c = D.DahuaClient("127.0.0.1", sim.port, USER, PASSWORD)
        rep = HP.probe_dahua(c)
        assert rep["device"] == sim.state.serial and rep["overwrite"] is True
        assert rep["disks"][0]["state"] == "ok" and rep["disks"][0]["total_gb"] == 1000.0
        assert [ch["online"] for ch in rep["channels"]] == [True] * 4
        sim.state.offline.add(1)
        sim.state.not_recording.add(4)
        sim.state.disk = "full"
        sim.state.overwrite = False
        rep = HP.probe_dahua(c)
        chans = {ch["no"]: ch for ch in rep["channels"]}
        assert chans[1]["online"] is False and chans[4]["recording"] is False
        assert rep["disks"][0]["state"] == "full" and rep["overwrite"] is False


def test_dahua_event_stream():
    with DvrSim("dahua") as sim:
        sim.state.events = [("text/plain", b"Code=SmartMotionHuman;action=Start;index=0;"
                                            b"data={\"Object\":{\"ObjectType\":\"Human\"}}")]
        parts = list(D.DahuaClient("127.0.0.1", sim.port, USER, PASSWORD).event_stream(timeout=5))
        assert parts and parts[0][1].startswith(b"Code=SmartMotionHuman")


def test_post_reports_never_sends_secrets():
    got = []
    st = HP.post_reports(lambda url, body, h: got.append((url, body, h)) or 200,
                         "https://srv.test", "SITETOKEN",
                         [{"source": "isapi", "device": "X", "password": "p"}])
    assert st == 200 and "password" not in json.dumps(got[0][1])
    assert got[0][0] == "https://srv.test/api/v1/shop/gateway/dvr-health"
    assert got[0][2] == {"X-Shop-Token": "SITETOKEN"}


@pytest.mark.parametrize("raw,expect", [
    ({"list.info[0].State": "NotExist"}, "none"),
    ({"list.info[0].State": "Success", "list.info[0].Detail[0].IsError": "true"}, "error"),
])
def test_dahua_storage_states(raw, expect):
    assert D.parse_storage(raw)[0]["state"] == expect
