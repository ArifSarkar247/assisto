"""Encrypted secret storage for the shop's enrollment token and camera
credentials (RTSP username/password, per-camera tokens).

  * Windows: DPAPI (CryptProtectData, CURRENT_USER scope) via ctypes — the
    ciphertext can only be decrypted by the same Windows user on the same PC.
    No key file exists to steal.
  * Linux/macOS: Fernet (AES-128-CBC + HMAC-SHA256, `cryptography`) with a
    random key in `secret.key`, chmod 600, inside the per-user config dir.

Secrets are stored base64-encoded in `secrets.json` (ciphertext only). They are
NEVER written to config.json, the outbox, or logs; every value read is also
registered with the log redaction filter.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import threading
from typing import Dict, Optional

from . import logutil, paths

_SCHEME_DPAPI = "dpapi"
_SCHEME_FERNET = "fernet"


# --------------------------------------------------------------------- DPAPI
def _dpapi_crypt(data: bytes, protect: bool) -> bytes:
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD),
                    ("pbData", ctypes.POINTER(ctypes.c_char))]

    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    buf = ctypes.create_string_buffer(data, len(data))
    blob_in = DATA_BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    blob_out = DATA_BLOB()
    entropy_bytes = b"AssistoShopBox/v1"
    ebuf = ctypes.create_string_buffer(entropy_bytes, len(entropy_bytes))
    entropy = DATA_BLOB(len(entropy_bytes),
                        ctypes.cast(ebuf, ctypes.POINTER(ctypes.c_char)))
    CRYPTPROTECT_UI_FORBIDDEN = 0x01
    fn = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    if protect:
        ok = fn(ctypes.byref(blob_in), "AssistoShopBox", ctypes.byref(entropy),
                None, None, CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(blob_out))
    else:
        ok = fn(ctypes.byref(blob_in), None, ctypes.byref(entropy),
                None, None, CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(blob_out))
    if not ok:
        raise OSError("DPAPI %s failed" % ("protect" if protect else "unprotect"))
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


class _DpapiCipher:
    scheme = _SCHEME_DPAPI

    def encrypt(self, data: bytes) -> bytes:
        return _dpapi_crypt(data, True)

    def decrypt(self, data: bytes) -> bytes:
        return _dpapi_crypt(data, False)


# -------------------------------------------------------------------- Fernet
class _FernetCipher:
    scheme = _SCHEME_FERNET

    def __init__(self, key_path: str):
        from cryptography.fernet import Fernet

        self.key_path = key_path
        if not os.path.exists(key_path):
            key = Fernet.generate_key()
            # create with 0600 from the start (no window where it is readable)
            fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(key)
        try:
            os.chmod(key_path, 0o600)
        except OSError:
            pass
        with open(key_path, "rb") as f:
            self._f = Fernet(f.read().strip())

    def encrypt(self, data: bytes) -> bytes:
        return self._f.encrypt(data)

    def decrypt(self, data: bytes) -> bytes:
        return self._f.decrypt(data)


def _default_cipher(base_dir: str):
    if sys.platform == "win32":
        return _DpapiCipher()
    return _FernetCipher(os.path.join(base_dir, "secret.key"))


# --------------------------------------------------------------------- store
class SecretStore:
    """name -> secret string, encrypted at rest. Thread-safe."""

    def __init__(self, base_dir: Optional[str] = None, cipher=None):
        self.base_dir = base_dir or paths.data_dir()
        os.makedirs(self.base_dir, exist_ok=True)
        self.file = os.path.join(self.base_dir, "secrets.json")
        self._cipher = cipher or _default_cipher(self.base_dir)
        self._lock = threading.Lock()

    @property
    def scheme(self) -> str:
        return self._cipher.scheme

    def _load(self) -> Dict[str, str]:
        try:
            with open(self.file, "r", encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            return {}
        if d.get("scheme") not in (None, self._cipher.scheme):
            # e.g. a Fernet file copied to a Windows box: unreadable, start over
            return {}
        return dict(d.get("items", {}))

    def _save(self, items: Dict[str, str]) -> None:
        tmp = self.file + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"scheme": self._cipher.scheme, "items": items}, f)
        os.replace(tmp, self.file)

    def set(self, name: str, value: Optional[str]) -> None:
        with self._lock:
            items = self._load()
            if value:
                ct = self._cipher.encrypt(value.encode("utf-8"))
                items[name] = base64.b64encode(ct).decode("ascii")
                logutil.register_secret(value)
            else:
                items.pop(name, None)
            self._save(items)

    def get(self, name: str) -> Optional[str]:
        with self._lock:
            items = self._load()
        raw = items.get(name)
        if not raw:
            return None
        try:
            value = self._cipher.decrypt(base64.b64decode(raw)).decode("utf-8")
        except Exception:
            return None     # wrong user/PC (DPAPI) or tampered (Fernet HMAC)
        logutil.register_secret(value)
        return value

    def delete_prefix(self, prefix: str) -> None:
        with self._lock:
            items = {k: v for k, v in self._load().items()
                     if not k.startswith(prefix)}
            self._save(items)

    def raw_file_bytes(self) -> bytes:
        """For tests: what is actually on disk."""
        with open(self.file, "rb") as f:
            return f.read()


# Secret names used across the app.
SITE_TOKEN = "site_token"


def cam_key(camera_id: str, what: str) -> str:
    """what in {"user", "pass", "token"}."""
    return "cam:%s:%s" % (camera_id, what)
