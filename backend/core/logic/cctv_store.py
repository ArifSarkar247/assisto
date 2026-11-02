"""
cctv_store.py — the ONE storage module for CCTV alert photos and clips
(owner CCTV order 3 Nov, D1/D3/I1/I2; package W7).

Every object (alert snapshot, camera preview, cash-guard clip ciphertext,
SD-card clip) is sealed PER OBJECT with AES-256-GCM before it leaves this
process:

    blob = b"ASV1" | salt(16) | nonce(12) | AESGCM(k_obj).encrypt(data, aad=name)
    k_obj = HKDF-SHA256(master, salt, info=b"assisto-cctv-obj:" + name)

`master` = settings.CCTV_STORE_KEY (base64 / hex, 32 bytes; env) or, until the
owner sets one, a key derived from SECRET_KEY under its own label. The object
NAME is bound as AAD, so a blob copied onto another name does not open.

BACKENDS (chosen at call time, no restart logic needed):
  * S3-compatible object storage (Cloudflare R2 / any S3 API) — used when
    CCTV_S3_ENDPOINT + CCTV_S3_BUCKET + CCTV_S3_KEY_ID + CCTV_S3_SECRET are
    all set. NO account is opened by this code; the owner decides + pays.
    Plain SigV4 over `requests` (no new dependency); tests inject `http`.
  * encrypted local fallback under MEDIA_ROOT (same names as before, so the
    existing signed links keep working) — never a plain file.

LEGACY plain files (written before this module) are read once, re-sealed in
place (or uploaded to S3 and the local copy removed) — "migrate on access";
`manage.py cctv_store_migrate --dry-run` does the same for every file at once.

SERVING: only through the existing signed-link path (/api/v1/m/<name>,
core/media_sign.serve_signed), which opens the object here and returns the
plain bytes to whoever holds a valid, expiring link. Links are handed out
only by views that already checked owner / allowed viewer.
"""
import base64
import binascii
import datetime as _dt
import hashlib
import hmac
import logging
import os
import secrets
from urllib.parse import quote, urlparse

from django.conf import settings
from django.core.files.base import ContentFile
from django.core.files.storage import Storage
from django.utils.deconstruct import deconstructible

log = logging.getLogger("assisto.cctv_store")

MAGIC = b"ASV1"
SALT_LEN, NONCE_LEN = 16, 12
HEADER_LEN = len(MAGIC) + SALT_LEN + NONCE_LEN
PREFIX = "shop/"                 # every CCTV FileField lives under shop/
TIMEOUT_S = 15


class StoreError(Exception):
    pass


# ---------------------------------------------------------------- crypto
def _master_key():
    raw = (getattr(settings, "CCTV_STORE_KEY", "") or
           os.getenv("CCTV_STORE_KEY", "") or "").strip()
    if raw:
        for dec in (base64.b64decode, bytes.fromhex):
            try:
                k = dec(raw)
            except (ValueError, binascii.Error):
                continue
            if len(k) == 32:
                return k
        log.error("CCTV_STORE_KEY is not 32 bytes (base64/hex) - using derived key")
    return hashlib.sha256(b"assisto-cctv-store-v1:" + settings.SECRET_KEY.encode()).digest()


def _obj_key(salt, name):
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt,
                info=b"assisto-cctv-obj:" + name.encode()).derive(_master_key())


def seal(data, name):
    """Plain bytes -> sealed blob bound to `name`."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    salt, nonce = secrets.token_bytes(SALT_LEN), secrets.token_bytes(NONCE_LEN)
    ct = AESGCM(_obj_key(salt, name)).encrypt(nonce, bytes(data), name.encode())
    return MAGIC + salt + nonce + ct


def is_sealed(blob):
    return isinstance(blob, (bytes, bytearray)) and bytes(blob[:4]) == MAGIC and \
        len(blob) >= HEADER_LEN + 16


def open_blob(blob, name):
    """Sealed blob -> plain bytes. Raises StoreError when it does not open
    (wrong name, wrong key, tampered)."""
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if not is_sealed(blob):
        raise StoreError("not_sealed")
    salt = bytes(blob[4:4 + SALT_LEN])
    nonce = bytes(blob[4 + SALT_LEN:HEADER_LEN])
    try:
        return AESGCM(_obj_key(salt, name)).decrypt(nonce, bytes(blob[HEADER_LEN:]),
                                                    name.encode())
    except InvalidTag:
        raise StoreError("bad_tag")


# ---------------------------------------------------------------- S3
def s3_config():
    """The S3-compatible backend settings, or None when not configured."""
    def g(k):
        return (getattr(settings, k, "") or os.getenv(k, "") or "").strip()
    cfg = {"endpoint": g("CCTV_S3_ENDPOINT").rstrip("/"), "bucket": g("CCTV_S3_BUCKET"),
           "key_id": g("CCTV_S3_KEY_ID"), "secret": g("CCTV_S3_SECRET"),
           "region": g("CCTV_S3_REGION") or "auto"}
    if not all(cfg[k] for k in ("endpoint", "bucket", "key_id", "secret")):
        return None
    if urlparse(cfg["endpoint"]).scheme != "https":
        log.error("CCTV_S3_ENDPOINT must be https - S3 backend off")
        return None
    return cfg


def _default_http(method, url, headers, body, timeout):
    import requests
    r = requests.request(method, url, headers=headers, data=body, timeout=timeout,
                         allow_redirects=False)
    return r.status_code, r.content


class S3Backend:
    """Minimal path-style S3 client (PUT / GET / HEAD / DELETE) with AWS
    Signature V4 — works with Cloudflare R2, Backblaze B2 S3, MinIO, Wasabi."""

    def __init__(self, cfg, http=None, now=None):
        self.cfg = cfg
        self.http = http or _default_http
        self.now = now or (lambda: _dt.datetime.now(_dt.timezone.utc))

    def _url_path(self, name):
        return "/%s/%s" % (quote(self.cfg["bucket"]), quote(name, safe="/-_.~"))

    def _signed_headers(self, method, path, payload):
        t = self.now()
        amz = t.strftime("%Y%m%dT%H%M%SZ")
        day = t.strftime("%Y%m%d")
        host = urlparse(self.cfg["endpoint"]).netloc
        ph = hashlib.sha256(payload or b"").hexdigest()
        canon_h = "host:%s\nx-amz-content-sha256:%s\nx-amz-date:%s\n" % (host, ph, amz)
        signed = "host;x-amz-content-sha256;x-amz-date"
        canon = "\n".join([method, path, "", canon_h, signed, ph])
        scope = "%s/%s/s3/aws4_request" % (day, self.cfg["region"])
        sts = "\n".join(["AWS4-HMAC-SHA256", amz, scope,
                         hashlib.sha256(canon.encode()).hexdigest()])

        def h(k, m):
            return hmac.new(k, m.encode(), hashlib.sha256).digest()
        k = h(("AWS4" + self.cfg["secret"]).encode(), day)
        k = h(h(h(k, self.cfg["region"]), "s3"), "aws4_request")
        sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
        return {"x-amz-date": amz, "x-amz-content-sha256": ph,
                "Authorization": "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, "
                                 "Signature=%s" % (self.cfg["key_id"], scope, signed, sig)}

    def _req(self, method, name, body=b""):
        path = self._url_path(name)
        hdr = self._signed_headers(method, path, body)
        try:
            return self.http(method, self.cfg["endpoint"] + path, hdr, body or None,
                             TIMEOUT_S)
        except Exception as e:  # noqa: BLE001 - network
            raise StoreError("network: %s" % str(e)[:80])

    def put(self, name, blob):
        st, _ = self._req("PUT", name, blob)
        if st not in (200, 201):
            raise StoreError("s3_put_%s" % st)

    def get(self, name):
        st, body = self._req("GET", name)
        if st == 404:
            return None
        if st != 200:
            raise StoreError("s3_get_%s" % st)
        return body

    def exists(self, name):
        st, _ = self._req("HEAD", name)
        return st == 200

    def delete(self, name):
        st, _ = self._req("DELETE", name)
        if st not in (200, 204, 404):
            raise StoreError("s3_delete_%s" % st)


_http_override = None      # tests: a fake S3 http callable


def s3_backend():
    cfg = s3_config()
    return S3Backend(cfg, http=_http_override) if cfg else None


def backend_name():
    return "s3" if s3_config() else "local_encrypted"


# ---------------------------------------------------------------- local
def _local_path(name):
    root = os.path.realpath(str(settings.MEDIA_ROOT))
    path = os.path.realpath(os.path.join(root, name))
    if not path.startswith(root + os.sep):
        raise StoreError("bad_name")
    return path


def _write_local(name, blob):
    path = _local_path(name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp%s" % (path, secrets.token_hex(4))
    with open(tmp, "wb") as f:
        f.write(blob)
    os.replace(tmp, path)


def _read_local(name):
    path = _local_path(name)
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        return f.read()


# ---------------------------------------------------------------- API
def valid_name(name):
    name = str(name or "")
    return bool(name) and name.startswith(PREFIX) and ".." not in name.split("/") \
        and not name.startswith("/") and "\\" not in name


def put(name, data):
    """Seal + store `data` under `name` (S3 when configured, else local)."""
    if not valid_name(name):
        raise StoreError("bad_name")
    blob = seal(data, name)
    s3 = s3_backend()
    if s3 is not None:
        s3.put(name, blob)
        try:                                   # no stale local copy
            os.remove(_local_path(name))
        except OSError:
            pass
    else:
        _write_local(name, blob)
    return name


def get(name, migrate=True):
    """Plain bytes of `name`, or None when it does not exist. A legacy plain
    local file is returned AND (migrate=True) re-sealed / uploaded at once."""
    if not valid_name(name):
        return None
    s3 = s3_backend()
    if s3 is not None:
        blob = s3.get(name)
        if blob is not None:
            return open_blob(blob, name)
    blob = _read_local(name)
    if blob is None:
        return None
    if is_sealed(blob):
        try:
            data = open_blob(blob, name)
        except StoreError:
            raise
        if s3 is not None and migrate:
            _migrate_one(name, data, s3)
        return data
    # legacy plain file (written before cctv_store)
    if migrate:
        _migrate_one(name, blob, s3)
    return blob


def _migrate_one(name, data, s3):
    try:
        if s3 is not None:
            s3.put(name, seal(data, name))
            os.remove(_local_path(name))
        else:
            _write_local(name, seal(data, name))
    except Exception:  # noqa: BLE001 - next access / the command retries
        log.exception("cctv_store migrate failed for %s", name)


def exists(name):
    if not valid_name(name):
        return False
    s3 = s3_backend()
    if s3 is not None and s3.exists(name):
        return True
    return os.path.isfile(_local_path(name))


def delete(name):
    if not valid_name(name):
        return
    s3 = s3_backend()
    if s3 is not None:
        s3.delete(name)
    try:
        os.remove(_local_path(name))
    except OSError:
        pass


def local_state(name):
    """'missing' | 'sealed' | 'plain' — for the migration command."""
    blob = _read_local(name)
    if blob is None:
        return "missing"
    return "sealed" if is_sealed(blob) else "plain"


# ---------------------------------------------------------------- Django
@deconstructible
class VaultStorage(Storage):
    """Django Storage over this module: FileField.save/open/delete/url go
    through seal/open; .url() is the existing short-lived signed link."""

    def _open(self, name, mode="rb"):
        data = get(name)
        if data is None:
            raise FileNotFoundError(name)
        f = ContentFile(data, name=name)
        f.mode = mode
        return f

    def _save(self, name, content):
        if hasattr(content, "seek"):
            try:
                content.seek(0)
            except Exception:
                pass
        data = content.read()
        if isinstance(data, str):
            data = data.encode()
        put(name, data)
        return name

    def get_available_name(self, name, max_length=None):
        # never overwrite: a random suffix instead of an exists() round trip
        name = name.replace("\\", "/")
        if not exists(name):
            return name
        root, ext = os.path.splitext(name)
        return "%s_%s%s" % (root, secrets.token_hex(4), ext)

    def delete(self, name):
        delete(name)

    def exists(self, name):
        return exists(name)

    def size(self, name):
        data = get(name, migrate=False)
        return len(data or b"")

    def url(self, name):
        from ..media_sign import signed_url
        return signed_url(name)

    def path(self, name):
        """The LOCAL fallback location (sealed bytes; may not exist when the
        object lives in S3). Never readable as a plain image."""
        return _local_path(name)


_vault = None


def vault_storage():
    """Callable storage for the CCTV FileFields (migration-stable)."""
    global _vault
    if _vault is None:
        _vault = VaultStorage()
    return _vault


def response_for(name):
    """(plain bytes, content type) for the signed-link view, or None."""
    import mimetypes
    try:
        data = get(name)
    except StoreError:
        log.warning("cctv_store: %s did not open", name)
        return None
    if data is None:
        return None
    return data, (mimetypes.guess_type(name)[0] or "application/octet-stream")


def sha256_of(name):
    data = get(name, migrate=False)
    return hashlib.sha256(data).hexdigest() if data is not None else ""


__all__ = ["seal", "open_blob", "put", "get", "delete", "exists", "VaultStorage",
           "vault_storage", "response_for", "S3Backend", "backend_name"]
