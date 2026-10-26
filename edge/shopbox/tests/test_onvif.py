"""ONVIF: WS-Discovery parsing, WS-Security digest, SOAP parsing (canned XML)."""
import base64
import hashlib
import socket

import pytest

from shopbox import onvif

PROBE_MATCH = b"""<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
  xmlns:wsdd="http://schemas.xmlsoap.org/ws/2005/04/discovery">
 <SOAP-ENV:Body><wsdd:ProbeMatches><wsdd:ProbeMatch>
  <wsdd:Types>dn:NetworkVideoTransmitter</wsdd:Types>
  <wsdd:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/hardware/IPC-F22
   onvif://www.onvif.org/name/Dahua%20Cam onvif://www.onvif.org/mfr/Dahua
   onvif://www.onvif.org/location/country/china</wsdd:Scopes>
  <wsdd:XAddrs>http://192.168.1.20/onvif/device_service http://[fe80::1]/onvif/device_service</wsdd:XAddrs>
 </wsdd:ProbeMatch></wsdd:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>"""


def test_probe_message_is_ws_discovery_probe():
    m = onvif.probe_message("abc").decode()
    assert "dn:NetworkVideoTransmitter" in m and "uuid:abc" in m
    assert "discovery/Probe" in m


def test_parse_probe_match_scopes():
    devs = onvif.parse_probe_matches(PROBE_MATCH, "192.168.1.20")
    assert len(devs) == 1
    d = devs[0]
    assert d["host"] == "192.168.1.20"
    assert d["xaddr"] == "http://192.168.1.20/onvif/device_service"
    assert d["model"] == "IPC-F22" and d["name"] == "Dahua Cam"
    assert d["manufacturer"] == "Dahua"
    assert len(d["scopes"]) <= 8
    assert onvif.parse_probe_matches(b"garbage") == []


class FakeSock:
    def __init__(self, packets):
        self.packets = list(packets)
        self.sent = []

    def sendto(self, data, addr):
        self.sent.append((data, addr))

    def settimeout(self, t):
        pass

    def recvfrom(self, n):
        if self.packets:
            return self.packets.pop(0)
        raise socket.timeout()

    def close(self):
        pass


def test_discover_collects_unique_devices_with_fake_socket():
    clock = {"t": 0.0}

    def tick():
        clock["t"] += 0.3
        return clock["t"]

    sock = FakeSock([(PROBE_MATCH, ("192.168.1.20", 3702)),
                     (PROBE_MATCH, ("192.168.1.20", 3702))])
    devs = onvif.discover(2.0, sock_factory=lambda: sock, clock=tick)
    assert len(devs) == 1
    assert sock.sent[0][1] == onvif.MULTICAST


def test_password_digest_matches_spec_formula():
    nonce, created, pw = b"0123456789abcdef", "2026-10-26T10:00:00.000Z", "secret"
    expect = base64.b64encode(hashlib.sha1(nonce + created.encode() + pw.encode())
                              .digest()).decode()
    assert onvif.password_digest(nonce, created, pw) == expect
    hdr = onvif.wsse_header("admin", pw, nonce=nonce, created=created)
    assert expect in hdr and "secret" not in hdr.replace("secext", "")
    assert base64.b64encode(nonce).decode() in hdr


CAPS = b"""<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
 xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body><tds:GetCapabilitiesResponse
 xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><tds:Capabilities>
 <tt:Events><tt:XAddr>http://192.168.1.20/onvif/event_service</tt:XAddr>
 <tt:WSSubscriptionPolicySupport>true</tt:WSSubscriptionPolicySupport>
 <tt:WSPullPointSupport>true</tt:WSPullPointSupport></tt:Events>
 <tt:Media><tt:XAddr>http://192.168.1.20/onvif/media_service</tt:XAddr></tt:Media>
 </tds:Capabilities></tds:GetCapabilitiesResponse></s:Body></s:Envelope>"""
PROFILES = b"""<Envelope><Body><GetProfilesResponse>
 <Profiles token="MainStream"><Name>Main</Name><VideoEncoderConfiguration>
 <Encoding>H264</Encoding><Resolution><Width>1920</Width><Height>1080</Height>
 </Resolution></VideoEncoderConfiguration></Profiles>
 <Profiles token="SubStream"><Name>Sub</Name></Profiles>
 </GetProfilesResponse></Body></Envelope>"""
STREAM = b"""<Envelope><Body><GetStreamUriResponse><MediaUri>
 <Uri>rtsp://192.168.1.20:554/cam/realmonitor?channel=1&amp;subtype=0</Uri>
 </MediaUri></GetStreamUriResponse></Body></Envelope>"""
INFO = b"""<Envelope><Body><GetDeviceInformationResponse><Manufacturer>Dahua</Manufacturer>
 <Model>IPC-F22</Model><FirmwareVersion>2.8</FirmwareVersion>
 </GetDeviceInformationResponse></Body></Envelope>"""
EVENTS = b"""<Envelope><Body><GetEventPropertiesResponse><TopicSet/>
 </GetEventPropertiesResponse></Body></Envelope>"""
FAULT = b"""<Envelope><Body><Fault><Code><Value>Sender</Value><Subcode>
 <Value>ter:NotAuthorized</Value></Subcode></Code><Reason><Text>Sender not
 Authorized</Text></Reason></Fault></Body></Envelope>"""


def fake_post(routes, calls=None):
    def post(url, data, headers, timeout, auth=None):
        if calls is not None:
            calls.append((url, data, auth))
        body = data.decode()
        for key, resp in routes.items():
            if key in body:
                return resp
        return 500, b"<Envelope><Body><Fault><Reason><Text>x</Text></Reason></Fault></Body></Envelope>"
    return post


def test_client_capabilities_profiles_stream_info_events():
    calls = []
    c = onvif.OnvifClient.for_host("192.168.1.20", 80, username="admin",
                                   password="pw", post=fake_post({
                                       "GetCapabilities": (200, CAPS),
                                       "GetProfiles": (200, PROFILES),
                                       "GetStreamUri": (200, STREAM),
                                       "GetDeviceInformation": (200, INFO),
                                       "GetEventProperties": (200, EVENTS)}, calls))
    assert c.get_device_information()["model"] == "IPC-F22"
    caps = c.get_capabilities()
    assert caps["pullpoint"] is True
    assert caps["media"].endswith("/onvif/media_service")
    profs = c.get_profiles()
    assert [p["token"] for p in profs] == ["MainStream", "SubStream"]
    assert profs[0]["encoding"] == "H264" and profs[0]["width"] == 1920
    assert c.get_stream_uri("MainStream").startswith("rtsp://192.168.1.20:554/cam/")
    assert c.get_event_properties() is True
    # every SOAP body carries the WS-Security digest, never the plain password
    for _, data, _ in calls:
        assert b"PasswordDigest" in data and b">pw<" not in data


def test_auth_fault_and_401_raise_auth_failed():
    c = onvif.OnvifClient("http://h/onvif/device_service", "admin", "bad",
                          post=fake_post({"GetDeviceInformation": (400, FAULT)}))
    with pytest.raises(onvif.OnvifError) as e:
        c.get_device_information()
    assert e.value.code == "auth_failed"
    calls = []
    c = onvif.OnvifClient("http://h/onvif/device_service", "admin", "bad",
                          post=fake_post({"GetDeviceInformation": (401, b"")}, calls))
    with pytest.raises(onvif.OnvifError) as e:
        c.get_device_information()
    assert e.value.code == "auth_failed"
    assert calls[-1][2] == ("admin", "bad")      # HTTP Digest fallback tried once


def test_parser_refuses_dtd_and_oversize():
    with pytest.raises(onvif.OnvifError):
        onvif.parse_xml(b'<!DOCTYPE x [<!ENTITY a "b">]><x>&a;</x>')
    with pytest.raises(onvif.OnvifError):
        onvif.parse_xml(b"<x>" + b"a" * (onvif.MAX_RESPONSE + 1) + b"</x>")
