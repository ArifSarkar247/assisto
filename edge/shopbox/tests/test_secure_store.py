import os
import stat
import sys

import pytest

from shopbox import logutil
from shopbox.secure_store import SecretStore, _FernetCipher, cam_key


def make(tmp_path):
    d = tmp_path / "store"
    d.mkdir(exist_ok=True)
    return SecretStore(str(d), cipher=_FernetCipher(str(d / "secret.key")))


def test_fernet_roundtrip_and_ciphertext_on_disk(tmp_path):
    s = make(tmp_path)
    s.set("site_token", "tok-SECRET-123456")
    s.set(cam_key("c1", "pass"), "p@ss:w/rd!")
    assert s.get("site_token") == "tok-SECRET-123456"
    assert s.get(cam_key("c1", "pass")) == "p@ss:w/rd!"
    raw = s.raw_file_bytes()
    assert b"tok-SECRET" not in raw and b"p@ss" not in raw
    # a fresh instance with the same key file decrypts it too
    assert make(tmp_path).get("site_token") == "tok-SECRET-123456"


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permissions")
def test_key_file_is_owner_only(tmp_path):
    make(tmp_path)
    mode = stat.S_IMODE(os.stat(tmp_path / "store" / "secret.key").st_mode)
    assert mode == 0o600


def test_wrong_key_returns_none_not_garbage(tmp_path):
    s = make(tmp_path)
    s.set("site_token", "tok-ABCDEFG")
    os.remove(tmp_path / "store" / "secret.key")      # key lost / file copied
    assert make(tmp_path).get("site_token") is None


def test_delete_and_prefix_delete(tmp_path):
    s = make(tmp_path)
    s.set(cam_key("c1", "user"), "admin1")
    s.set(cam_key("c1", "pass"), "secret1")
    s.set(cam_key("c2", "pass"), "secret2")
    s.delete_prefix(cam_key("c1", ""))
    assert s.get(cam_key("c1", "pass")) is None
    assert s.get(cam_key("c2", "pass")) == "secret2"
    s.set(cam_key("c2", "pass"), None)
    assert s.get(cam_key("c2", "pass")) is None


def test_loaded_secrets_are_redacted_from_logs(tmp_path):
    s = make(tmp_path)
    s.set("site_token", "zzTOKENzz9")
    assert "zzTOKENzz9" not in logutil.redact("posting with zzTOKENzz9 now")
    assert logutil.redact("rtsp://admin:hunter2@192.168.1.64:554/x") == \
        "rtsp://***@192.168.1.64:554/x"
    assert "abc123" not in logutil.redact('{"site_token": "abc123"}')
