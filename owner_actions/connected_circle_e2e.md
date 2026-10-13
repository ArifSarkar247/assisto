# Connected Circle — End-to-End Encryption (design + owner actions)

**Status:** text E2E works now via a software fallback; media + voice calls are
key-gated. This document records the protocol, the licence choice, key
management, group messaging, forward secrecy, and the encrypted backup +
recovery-code scheme — so the owner can enable the production path (OpenMLS)
and the gated features when ready.

---

## 1. Library choice & licence (STRICT, owner-specified)

| Option | Licence | Verdict |
|---|---|---|
| **MLS via OpenMLS** (RFC 9420) | **Apache-2.0 / MIT** | ✅ **PREFERRED** — permissive, licence-compatible with a closed app, audited, group-native |
| libsignal (Signal protocol) | **AGPL-3.0** | ❌ Rejected — AGPL is incompatible with a closed-source app |

**Decision:** use **MLS (OpenMLS)** for production. OpenMLS is a Rust crate that
is not yet wired into Flutter (no FFI bridge built). So this release ships:

1. A clean **`E2E` interface** in `app/lib/crypto/e2e.dart` — the app (chat
   screen, relay) depends only on this interface.
2. A **working software fallback** (`SoftwareE2E`) so text messaging works
   today, with **no extra pub packages** (pubspec is integrator-owned) and no
   native code. It is original, standards-based, and validated against RFC test
   vectors (see §8).
3. A **clear seam** to drop in `MlsE2E` (OpenMLS over FFI) later — same
   interface, same wire envelope, so **the server relay never changes**.

The two scheme ids:
- `x25519-xchacha-fallback-v1` — the fallback (shipping now).
- `mls-openmls-v1` — the production target (owner action, §6).

---

## 2. The privacy contract (enforced in code)

- **The server stores CIPHERTEXT ONLY.** It is a relay. It holds no message
  key and cannot decrypt a circle message.
- **The server AI never reads circle messages.** `core/logic/circle.py`
  provides `validate_envelope()` (rejects any envelope carrying
  plaintext/secret fields), `server_visible_fields()` (routing-metadata-only
  projection), and `ai_redaction()` (what the AI may know: that a message
  exists and its type — never its content).
- **Keys live on-device** (`flutter_secure_storage`). The private key never
  leaves the device except as an **optional** backup sealed under a recovery
  code the server also never learns (§5).
- **Relationships are mutual + consented** (request → accept). **No
  contact-list upload** without an explicit, expiring consent record
  (`contact_access_allowed`, default OFF).

---

## 3. The software fallback construction (`SoftwareE2E`)

Scheme `x25519-xchacha-fallback-v1`, per message:

1. **Identity:** each device holds an **X25519** (Curve25519) key pair. Public
   key is published to the server; private key stays on-device.
2. **Shared secret:** sender computes `X25519(my_priv, peer_pub)`; recipient
   computes the same with roles swapped (symmetric).
3. **Key derivation:** `HKDF-SHA256(shared_secret, info)` → 32-byte AEAD key.
   `info` binds **both** identities (order-independent) so a shared secret can
   never be reused across different pairs.
4. **Encryption:** **ChaCha20-Poly1305** (RFC 8439) AEAD, random 96-bit nonce
   per message, AAD = sender key id.
5. **Envelope:** `{scheme, ciphertext(b64), nonce(b64), sender_key_id}` + the
   relay's routing metadata. No plaintext, ever.

**Honest limitation of the fallback:** it uses a *static* X25519 DH, so it does
**not** provide forward secrecy or post-compromise security on its own — if a
device's long-term private key leaks, past captured ciphertext for that pair
could be decrypted. This is the key reason to move to MLS (§4, §6). Group
messages in the fallback are sent as **one ciphertext per recipient** (fan-out);
MLS replaces this with a single group ciphertext + a ratchet.

---

## 4. What MLS (OpenMLS) adds — the production path

- **Group-native**: one encryption per message to the whole circle group, not
  per-recipient fan-out.
- **Forward secrecy + post-compromise security** via the MLS key schedule and
  the TreeKEM ratchet: compromising a key does not expose past messages and the
  group self-heals future messages after a member updates.
- **Membership changes** (add/remove a family member) are cryptographic
  Commit/Proposal operations, not ad-hoc re-keying.
- **Same envelope shape** on the wire → the server relay and the `E2E`
  interface are unchanged; only `SoftwareE2E` is swapped for `MlsE2E`.

---

## 5. Encrypted key backup + recovery code (`KeyBackup`)

Optional. Lets a user restore their identity on a new phone **without the server
ever being able to**:

1. Generate a human-friendly **recovery code** (`generateRecoveryCode()` →
   4×4 groups, ambiguity-free alphabet, e.g. `K7PQ-M2NR-...`). The user writes
   it down. **The server never stores it.**
2. Stretch the code with **PBKDF2-HMAC-SHA256** (120k iterations, random salt)
   → a wrapping key.
3. Seal the X25519 private key with **ChaCha20-Poly1305** under that wrapping
   key. Store only the sealed blob (optionally on the server — still opaque).
4. Restore: re-enter the code → re-derive the wrapping key → open the blob.
   Wrong code / tamper → authentication fails, returns null (no partial leak).

**By design, losing the recovery code = losing the backup.** The server cannot
help recover it. This is the privacy trade-off; the UI must warn the user to
store the code safely.

---

## 6. OWNER ACTIONS to reach production

1. **Build the OpenMLS FFI bridge** (Rust crate → Dart FFI) and implement
   `MlsE2E implements E2E`. Keep `scheme = "mls-openmls-v1"`. No server change.
2. **Enable encrypted media storage** (object storage bucket for encrypted
   blobs). Flip `MEDIA_UNLOCKED['voice'|'photo'|'video'] = True` in
   `core/logic/circle.py`. Media stays ciphertext-only (encrypt the file
   client-side, upload the blob, store only `blob_ref`).
3. **Provision a production TURN server** (coturn) + **push-to-ring**
   (FCM data message → CallKit/ConnectionService) for 1:1 WebRTC voice calls.
   Flip `MEDIA_UNLOCKED['call'] = True`. The call signalling path is a design +
   stub in this release (not required to fully work now).
4. **Provide the invite-token secret** (`settings.SECRET_KEY` is fine) to
   `make_invite_token` / `parse_invite_token`; enforce single-use in the DB.
5. **Legal/UX:** add a "store your recovery code" warning screen; confirm the
   privacy copy ("end-to-end encrypted; we can't read your messages") in the
   store listing.

---

## 7. Benchmark vs Signal / WhatsApp (family E2E)

Legend: ✅ done · ➕ original twist · ⏳ key-gated/owner-action.

| Capability | Signal/WA | Assisto Circle |
|---|---|---|
| E2E text | ✅ | ✅ (software fallback now) |
| Audited permissive-licence crypto lib | ✅ (libsignal, but AGPL) | ⏳ OpenMLS (Apache/MIT) — preferred, FFI pending |
| Server stores ciphertext only | ✅ | ✅ (relay + `validate_envelope`) |
| AI never reads messages | n/a | ✅ `ai_redaction` (➕ — Assisto has an AI) |
| Forward secrecy / PCS | ✅ (ratchet) | ⏳ with MLS (fallback is static-DH) |
| Group messaging | ✅ | ✅ fan-out now; ➕ MLS group later |
| Relationship graph + consent | ➖ (flat contacts) | ➕ typed relations, reciprocals, scoped sharing |
| Encrypted backup + recovery code | ✅ | ✅ PBKDF2 + AEAD, server-blind |
| Voice/photo/video E2E | ✅ | ⏳ key-gated ("Available when …") |
| 1:1 voice call | ✅ | ⏳ WebRTC + TURN design/stub |
| 1-tap call/msg from a parent's med card | ➖ | ➕ `quick_contact_actions` hook |

---

## 8. Validation (ran locally, no Flutter/migrations)

- **Dart crypto** (`app/lib/crypto/e2e.dart`) verified against RFC test vectors:
  SHA-256 ("abc"), X25519 (RFC 7748 §5.2 vector), ChaCha20-Poly1305 (RFC 8439
  §2.8.2 vector), plus E2E roundtrip (bn+en+emoji), confidentiality
  (wrong-key-fails), and key-backup seal/open (wrong-code-fails). All pass.
- **Backend relay/logic** (`core/logic/circle.py`): 31 pure-Python assert tests
  in `core/logic/circle_tests_snippets.py`, all pass — including proof that an
  envelope carrying `plaintext`/`private_key`/`recovery_code` is **rejected** by
  the relay, and that the AI projection is never readable.
