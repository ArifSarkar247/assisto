"""Regenerate tools/cashguard/clip_vector.json — the fixed cross-language
test vector for the cash-guard clip envelope (edge seal -> app open).
Run from edge/shopbox:  python ../../tools/cashguard/gen_clip_vector.py > ../../tools/cashguard/clip_vector.json
Deterministic (fixed keys + counter RNG); TEST KEYS ONLY, never used live."""
import base64, json, sys, hashlib
sys.path.insert(0, ".")
from shopbox import clip
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization
priv = bytearray(hashlib.sha256(b"assisto-cashguard-test-recipient").digest())
priv[0] &= 248; priv[31] &= 127; priv[31] |= 64
priv = bytes(priv)
pub = X25519PrivateKey.from_private_bytes(priv).public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
eph = bytearray(hashlib.sha256(b"assisto-cashguard-test-ephemeral").digest())
eph[0] &= 248; eph[31] &= 127; eph[31] |= 64
ctr = [0]
def rand(n):
    ctr[0] += 1
    return hashlib.sha256(b"r%d" % ctr[0]).digest()[:n]
frames = [(1000.0 + i * 0.25, b"\xff\xd8FAKEJPEG%d\xff\xd9" % i) for i in range(16)]
plain = clip.encode_container(frames, 4.0)
ct, meta = clip.seal(plain, [{"uid": 7, "key_id": clip.key_id(pub), "pub": base64.b64encode(pub).decode()}], rand=rand, eph_private=bytes(eph))
meta.update({"frames": 16, "duration_s": clip.duration_of(frames, 4.0), "fps": 4.0})
assert clip.open_clip(ct, meta, 7, priv) == plain
print(json.dumps({"recipient_private": base64.b64encode(priv).decode(), "recipient_public": base64.b64encode(pub).decode(), "uid": 7, "meta": meta, "ciphertext": base64.b64encode(ct).decode(), "plain_sha256": hashlib.sha256(plain).hexdigest()}, indent=1))
