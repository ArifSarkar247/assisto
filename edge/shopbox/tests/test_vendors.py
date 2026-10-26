"""RTSP URL templates per brand + credential redaction."""
import pytest

from shopbox import vendors
from shopbox.config import split_rtsp_credentials


def test_imou_dahua_template_user_is_admin_and_subtype():
    u = vendors.build_rtsp_url("imou", "192.168.1.20", 554, 1, "main",
                               username="ignored", secret="ABC123")
    assert u == "rtsp://admin:ABC123@192.168.1.20:554/cam/realmonitor?channel=1&subtype=0"
    u = vendors.build_rtsp_url("dahua", "10.0.0.5", 554, 2, "sub", "op", "pw")
    assert u == "rtsp://op:pw@10.0.0.5:554/cam/realmonitor?channel=2&subtype=1"


def test_hikvision_channels():
    assert vendors.build_rtsp_url("hikvision", "192.168.1.64", 554, 1, "main",
                                  "admin", "x") == \
        "rtsp://admin:x@192.168.1.64:554/Streaming/Channels/101"
    assert vendors.stream_path("hikvision", 3, "sub") == "/Streaming/Channels/302"


def test_tapo_and_ezviz():
    assert vendors.build_rtsp_url("tapo", "192.168.0.9", None, 1, "main",
                                  "camacct", "pw") == \
        "rtsp://camacct:pw@192.168.0.9:554/stream1"
    assert vendors.stream_path("tapo", 1, "sub") == "/stream2"
    assert vendors.build_rtsp_url("ezviz", "192.168.0.7", 554, 1, "main",
                                  None, "VERIFY") == \
        "rtsp://admin:VERIFY@192.168.0.7:554/H.264"
    assert vendors.stream_path("ezviz", 1, "sub") == "/h264/ch1/sub/av_stream"


def test_special_characters_are_url_encoded_and_round_trip():
    u = vendors.build_rtsp_url("hikvision", "192.168.1.64", 554, 1, "main",
                               "ad@min", "p@ss:w/#d")
    assert "p%40ss%3Aw%2F%23d" in u
    clean, user, pwd = split_rtsp_credentials(u)
    assert (user, pwd) == ("ad@min", "p@ss:w/#d")
    assert clean == "rtsp://192.168.1.64:554/Streaming/Channels/101"


def test_custom_rtsp_and_validation():
    assert vendors.build_rtsp_url("rtsp", rtsp_url="rtsp://h/live") == "rtsp://h/live"
    assert vendors.build_rtsp_url("rtsp", rtsp_url="rtsp://h/live", username="u",
                                  secret="s") == "rtsp://u:s@h/live"
    for bad in ({"vendor": "rtsp", "rtsp_url": "http://x"},
                {"vendor": "nope", "host": "1.2.3.4"},
                {"vendor": "hikvision", "host": "1.2.3.4/evil"},
                {"vendor": "hikvision", "host": "1.2.3.4", "port": 70000}):
        with pytest.raises(ValueError):
            vendors.build_rtsp_url(**bad)


def test_redaction():
    assert vendors.redact_url("rtsp://admin:SECRET@1.2.3.4:554/x?a=1") == \
        "rtsp://1.2.3.4:554/x?a=1"
    assert vendors.url_path("rtsp://a:b@h:554/cam/realmonitor?channel=1&subtype=0") \
        == "/cam/realmonitor?channel=1&subtype=0"
    t = vendors.redact_text("failed rtsp://u:p%40ss@h/x with p@ss", ["p@ss"])
    assert "p@ss" not in t and "p%40ss" not in t and "u:" not in t
