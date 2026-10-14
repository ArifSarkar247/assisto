# Connected Circle — Linked Devices / Multi-Device Encryption (design + owner actions)

**Spec:** CONNECTED_CIRCLE_MESSENGER.md item 10. **Status:** DESIGN now; data
model + stubs shipped in `core/logic/circle_extras.py` (`device_record`,
`can_link_device`, `build_link_request`, `revoke_device`). **No web client is
built in this release.** Platform order is owner-specified: **Android + iPhone
first, web client AFTER.**

This document records the per-device key model, the key-transfer (MLS "welcome")
handshake, the data model the integrator wires, and the exact owner actions
required to enable the production path. It builds on
`owner_actions/connected_circle_e2e.md` (the E2E protocol + OpenMLS decision).

---

## 1. Goal & non-goals

**Goal:** a user runs Assisto on several of their OWN devices (phone + tablet +,
later, web), each able to read/send circle messages, WITHOUT the server ever
holding a message key or plaintext.

**Non-goals (this release):**
- No web client (comes AFTER Android + iPhone — owner platform order).
- No cross-USER device sharing (devices belong to ONE account).
- No screenshot/clipboard restrictions (OS-dependent; stated in UI).

---

## 2. Per-device keys (the core idea)

Each device generates its OWN identity key pair on first run and NEVER transmits
the private half. The account is the set of its non-revoked devices. In MLS
terms (production), each device is a distinct **leaf** in the user's group; in
the software fallback (shipping now) each device has its own X25519 identity
(see `app/lib/crypto/e2e.dart`).

| Field (server-stored) | Secret? | Notes |
|---|---|---|
| `device_id` | no | opaque client-generated id |
| `platform` | no | `android` / `ios` / `web` |
| `role` | no | `primary` / `linked` |
| `public_key_id` | no | fingerprint of the device PUBLIC key |
| `name`, `linked_at`, `revoked` | no | registry meta |
| **private key** | **YES** | **NEVER leaves the device, NEVER stored server-side** |

The server stores ONLY the registry rows above. It is a relay for the opaque
link handshake — it cannot read a message on any device.

---

## 3. Linking a new device — the "welcome" handshake

```
New device D2                 Server (relay)              Primary device D1
    |  show QR (D2 pubkey id)      |                              |
    |----------------------------->|  (D1 scans QR off-screen)    |
    |                              |<-----------------------------|  seal welcome
    |                              |   build_link_request(...)     |  to D2 pubkey
    |<-----------------------------|   relay OPAQUE sealed_welcome |
    |  open sealed_welcome w/ D2   |                              |
    |  private key -> group keys   |                              |
    |  register device_record      |                              |
```

1. **D2** generates its key pair, displays a QR containing only its PUBLIC key id
   (+ a short-lived nonce). Nothing secret is shown.
2. **D1** (the already-trusted primary) scans the QR, then **seals** the current
   group/ratchet key material to D2's public key:
   - **Production (MLS):** D1 issues an MLS **Welcome** message adding D2's leaf.
   - **Now (software fallback):** D1 seals the chat key material with
     ChaCha20-Poly1305 under a shared secret from `X25519(D1_priv, D2_pub)`
     (same primitives as `KeyBackup`/`SoftwareE2E` in `e2e.dart`).
3. D1 calls `circle_extras.build_link_request(primary_device_id,
   new_device_public_key_id, platform, sealed_welcome_b64)` → an OPAQUE relay
   object. The validator refuses any secret field (`FORBIDDEN_META_KEYS`).
4. The server relays the opaque `sealed_welcome` to D2 and stores D2's
   `device_record`. **The server never sees a key.**
5. D2 opens the welcome with its own private key, joins the group, and is now a
   `linked` device.

`can_link_device()` enforces: the companion cap (`MAX_LINKED_DEVICES = 4`) and
the platform order — **web is rejected (`web_after_mobile`) until the account
has an Android or iOS device**, encoding the owner's "web after mobile" rule.

---

## 4. Message fan-out across a user's own devices

With per-device keys, a message to a circle contact is encrypted to EACH of that
contact's non-revoked device leaves (MLS does this natively; the fallback sends
one ciphertext per recipient device). The server still sees only ciphertext +
routing. Sender devices also sync to the user's OTHER devices the same way (self
is a member of their own device group).

---

## 5. Revocation & recovery

- **Revoke** (`revoke_device`): the primary marks a device revoked; the group
  key is rotated (MLS **Remove** proposal) so the revoked device can decrypt
  nothing new. Past messages it already decrypted are, by definition, already on
  that device — revocation is forward-only (standard).
- **Lost primary:** the user restores keys on a new device via the encrypted
  **chat backup + recovery code** (`circle_extras.build_backup_envelope` /
  `restore_plan`, reusing `KeyBackup`). The new device then re-links the others.

---

## 6. Data model (integrator — migration)

New model **`LinkedDevice`** (fields map 1:1 to `device_record()`):

```
LinkedDevice:
  user           FK -> account owner
  device_id      CharField (unique per user)
  platform       CharField (android|ios|web)
  role           CharField (primary|linked)
  public_key_id  CharField   # fingerprint of PUBLIC key only
  name           CharField
  linked_at      DateTimeField
  revoked        BooleanField default False
```

The opaque link request (`build_link_request`) is RELAYED, not persisted beyond
a short TTL (it is one-time key material for D2). No `LinkedDevice` field is a
secret.

---

## 7. Endpoints (integrator)

| Method | Path | Body / returns | Notes |
|---|---|---|---|
| `GET`  | `/circle/devices` | list of `LinkedDevice` | the user's own devices |
| `POST` | `/circle/devices/link` | `build_link_request(...)` object | relay opaque welcome to D2 |
| `POST` | `/circle/devices/{id}/revoke` | — | mark revoked + trigger key rotation |

All bodies are validated opaque (no secret keys). Server-side `can_link_device`
re-check before accepting a link (cap + platform order), never trusting the
client.

---

## 8. Owner actions (to enable production)

1. **Wire OpenMLS** per `connected_circle_e2e.md` §6 (the FFI bridge). Linked
   devices become MLS leaves; `build_link_request` carries a real MLS Welcome.
2. **Provision the relay TTL store** for one-time welcome blobs (short expiry).
3. **Build the web client — AFTER Android + iPhone ship** (owner platform
   order). Until then `can_link_device` returns `web_after_mobile` and the UI
   shows a clean "web coming after mobile" state. No web code ships now.

---

## 9. What ships in THIS release

- `LinkedDevice` data-model stubs + helpers in `circle_extras.py` (tested).
- The opaque link-request builder + validator (no secret can travel).
- Cap + platform-order enforcement (`can_link_device`).
- This design doc. **No web client. No key leaves the device.**
