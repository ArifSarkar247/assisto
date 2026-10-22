# mr1 — E2E media for My Circle (design note, NOT built)

Status: proposal for the integrator to queue. mr1 HID every My Circle attach
option (and the "+" button) because none can really send today
(`kCircleMediaStorageOn == false`, `circle.MEDIA_UNLOCKED` all False). This
note is what has to exist before the flag flips.

## Flow (sender -> recipient)

1. **Encrypt on device.** For each file the sender's phone generates a random
   32-byte key `K` and 24-byte nonce, encrypts the bytes with
   XChaCha20-Poly1305 (or AES-256-GCM via `cryptography`/`pointycastle`), and
   computes `sha256(ciphertext)`. A small thumbnail (photo/video, <= 20 KB,
   blurred) is encrypted the same way with its own key.
2. **Upload ciphertext only.** `POST /circle/media/upload-url {size, kind,
   sha256}` -> the server checks quota/size, returns a short-lived signed PUT
   URL (`media_sign.py` HMAC, 10 min) + a `blob_ref` (random id). The phone
   PUTs the ciphertext straight to storage. The server never sees `K`.
3. **Send the key inside the E2E message.** The normal 1:1/group message
   envelope (already X25519 + XSalsa20) carries `{blob_ref, K, nonce, sha256,
   mime, size, w, h, duration, thumb_ref, thumb_key, caption}` as its
   PLAINTEXT, so only the recipients can decrypt it. `CircleMessage.blob_ref`
   (exists) is set for server-side retention/cleanup only.
4. **Download + decrypt on device.** Recipient asks `GET /circle/media/<ref>`
   -> signed GET URL (only members of that chat/group), downloads, checks
   `sha256`, decrypts with `K`, caches in the app sandbox (no_backup), and
   only then shows Save / Forward (forward re-sends the same `blob_ref` + `K`
   in a new E2E envelope — no re-upload).
5. **Groups:** one upload; `K` travels in each member's per-recipient
   envelope (the existing `per_recipient` fan-out).

## Limits (owner-editable in admin pricing `limits`)

| kind | free | premium |
|---|---|---|
| photo (sent compressed to <= 1600 px, ~300 KB) | 16 MB | 16 MB |
| video | 16 MB (~2 min 480p) | 64 MB |
| voice note | 16 MB (~15 min Opus 24 kbps) | same |
| document | 32 MB | 100 MB |

Plus a per-user daily upload cap (e.g. 200 MB free / 1 GB premium) and a
message-request rule: no media before the request is accepted (abuse).

## Retention

* Blob deleted after **30 days** or when every recipient has downloaded it
  (whichever first) — WhatsApp-like; the phone keeps its decrypted copy.
* Delete-for-everyone deletes the blob immediately.
* Account deletion / grace (dl1) purges the user's uploaded blobs.
* Disappearing-message chats: blob TTL = the chat timer.
* A nightly job removes orphans (uploaded, never referenced by a message
  within 1 h).

## Storage + cost

* Start on the server's own disk (`/srv/assisto/media`, ciphertext only,
  served by Caddy via the signed URLs); move to S3-compatible object storage
  (Backblaze B2 / Cloudflare R2 — R2 has no egress fee) when disk > 60%.
* Rough cost at 1,000 daily active senders x 5 photos/day x 300 KB and 30-day
  retention: ~45 GB stored -> **~$0.7/month on R2** (+ ~$0 egress), disk
  first so $0 until the box fills. Video is the cost driver: cap it per plan.
* No server-side processing is possible (E2E), so no transcoding cost; all
  compression happens on the phone (needs `flutter_image_compress` /
  `video_compress`, both work on Android 8+ common BD phones).

## What to build (checklist)

1. Backend: `CircleMediaBlob` model (ref, owner, size, sha256, created,
   expires, downloaded_by), upload-url + download-url views, quota, cleanup
   job, tests. Migration after the latest on main.
2. App: `circle_media_crypto.dart` (encrypt/decrypt streams, chunked for
   video), picker per kind, upload with retry through the existing outbox
   (queued with a clock, sent when online — never a key error), viewer gets
   bytes, Save to gallery (MediaStore) + Forward.
3. Flip `kCircleMediaStorageOn` and `circle.MEDIA_UNLOCKED` together; the
   attach sheet (`circleAttachKinds`) then lists the kinds automatically.
4. Gallery shots + two-phone checklist (send photo/voice both ways, offline
   send, forward, save, 30-day expiry message).
