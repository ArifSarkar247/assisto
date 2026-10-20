from shopbox.config import (AppConfig, ConfigStore, join_rtsp_credentials,
                            split_rtsp_credentials)
from shopbox.strings import STRINGS, Tr


def test_both_languages_have_the_same_keys():
    assert set(STRINGS["bn"]) == set(STRINGS["en"])


def test_wording_never_accuses():
    for lang in STRINGS.values():
        for v in lang.values():
            text = " ".join(v) if isinstance(v, list) else v
            assert "theft" not in text.lower() and "thief" not in text.lower()
            assert "চুরি" not in text and "চোর" not in text


def test_translator_formats():
    assert Tr("en")("queue_line", n=3) == "Waiting to send: 3"
    assert Tr("xx").lang == "bn"


def test_rtsp_credentials_split_and_join_roundtrip():
    url = "rtsp://admin:p%40ss%3Aw@192.168.1.64:554/Streaming/Channels/102"
    clean, user, pwd = split_rtsp_credentials(url)
    assert clean == "rtsp://192.168.1.64:554/Streaming/Channels/102"
    assert (user, pwd) == ("admin", "p@ss:w")
    assert split_rtsp_credentials(join_rtsp_credentials(clean, user, pwd)) == \
        (clean, user, pwd)
    assert split_rtsp_credentials("rtsp://cam/1") == ("rtsp://cam/1", None, None)


def test_config_never_contains_credentials(tmp_path):
    from shopbox.config import CameraConfig
    cfg = AppConfig()
    cfg.cameras.append(CameraConfig.new("Counter", split_rtsp_credentials(
        "rtsp://admin:hunter2@10.0.0.5/live")[0]))
    store = ConfigStore(str(tmp_path / "config.json"))
    store.save(cfg)
    text = open(tmp_path / "config.json", encoding="utf-8").read()
    assert "hunter2" not in text and "admin" not in text
    assert store.load().cameras[0].rtsp_url == "rtsp://10.0.0.5/live"
