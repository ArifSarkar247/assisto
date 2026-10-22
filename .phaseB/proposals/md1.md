# md1 — E2E media for My Circle 1:1 + group chats (BUILT)

Follows `.phaseB/proposals/mr1-media.md` with these deliberate changes (why):

* **Upload goes through the API, not a signed PUT URL.** Resumable chunks
  (`PUT /circle/media/blobs/<ref>?offset=N`, 512 KiB, ≤ 1 MiB) stay under the
  nginx 25 MB / Django 15 MB body limits, resume after a drop on flaky BD
  mobile networks (409 returns the stored offset), and need no new nginx
  write location. Downloads are still signed links + X-Accel (no worker held).
* **ChaCha20-Poly1305 (same AEAD as messages) in 64 KiB chunks**, not
  XChaCha/AES: no new crypto dependency; chunking keeps RAM flat (a 25 MB file
  never sits in memory) and binds chunk order + the final chunk.
* **Thumbnail travels INSIDE the E2E message** (a ≤32 px PNG, ~1–3 KB) instead
  of a second blob: one upload, instant blurred preview, nothing extra stored.
* **Status media stays gated.** `core/logic/circle.MEDIA_UNLOCKED` and the app's
  `kCircleMediaStorageOn` are unchanged (status photo/video + the camera's
  "send to chats/status" still hidden). Chat media has its own switch:
  server `circle_blobs.CHAT_MEDIA_KINDS`, app `kCircleChatMediaKinds`.
* **Video: HIDDEN.** No reliable on-phone encoder without a heavy native dep
  (ffmpeg/`video_compress` ≈ 10–40 MB, ABI issues on low-RAM phones) and no
  in-app player; a raw camera clip (~100 MB/min) blows any sane cap. Contact
  card, static/live location: also hidden (not built).
* **Message requests:** no media before the request is accepted (server 403
  `media_after_accept`; the "+" button is hidden on a pending edge).

## Crypto (app/lib/messaging/media/media_crypto.dart)

Per file: `key = 32 random bytes`, `nonce = 12 random bytes` (Random.secure).
`chunk_i = ChaCha20-Poly1305(key, nonce ⊕ le64(i) in bytes 4..11, plain_i,
aad = "assisto-md1" || le64(i) || final)`. Reorder / truncation / tamper →
tag fails. `sha256(ciphertext)` is checked before decrypting (swapped blob).
Fast pure-Dart primitives (Uint32 ChaCha, 26-bit-limb Poly1305) — proven
byte-identical to `crypto/e2e.dart` and the RFC 8439 vector; run in
`Isolate.run`. The E2E envelope plaintext is the descriptor
`{md1, kind, ref, k, n, sha, size, psize, mime, name, w, h, ms, wave, thumb,
cap}` encrypted per recipient with the normal text scheme (1:1 inline, group
`per_recipient`). The server sees `content_type`, `blob_ref`, ciphertext only.

Photos are scrubbed on the phone before encryption: image_picker resizes to
≤1600 px at JPEG q80, then every APPn/COM segment (EXIF incl. GPS, XMP, IPTC)
is dropped and a minimal EXIF with ONLY the orientation is written back
(PNG: tEXt/zTXt/iTXt/eXIf/tIME dropped).

## Server (backend/core/circle_blobs.py, views_md1_media.py)

* Model `CircleMediaBlob` (ref, owner, kind, size, received, sha256, complete,
  recipients, downloaded_by, all_downloaded_at) — **migration
  `0065_md1_circle_media_blobs`** (also adds an index on
  `CircleMessage.blob_ref`). Integrator re-chains if needed.
* Storage: `CIRCLE_BLOB_ROOT` (default `backend/private/circle_blobs/`,
  OUTSIDE `MEDIA_ROOT`, git-ignored), `<ref[:2]>/<ref>.bin`, ciphertext only.
* Endpoints: `GET /circle/media/limits`, `POST /circle/media/blobs`,
  `GET|PUT|DELETE /circle/media/blobs/<ref>`, `POST …/finish` (size + sha256),
  `GET …/url` (participants only, 404 otherwise), `GET /circle/media/dl/<ref>
  ?u&e&s` (HMAC, 10 min, bound to the user, AllowAny + `no-store`).
* Access: sender, 1:1 participants of a live message holding the ref, ACTIVE
  group members (left/removed lose access). Forward = same ref + key in a new
  E2E envelope (allowed only if the forwarder can already open the blob).
* Limits (owner-editable in admin pricing `limits`, bounded):
  `circle_media_photo_max_mb` 16, `circle_media_voice_max_mb` 16,
  `circle_media_doc_max_mb` 25, `circle_media_daily_mb` 300 (per user / 24 h),
  `circle_media_uploads_per_hour` 60, `circle_media_keep_days` 30,
  `circle_media_max_days` 90.
* Retention (`purge_l1_retention`, hourly cron already installed): keep_days
  after every recipient downloaded, max_days after upload, 24 h for
  unfinished / never-sent, when every referencing message was deleted for
  everyone. Delete-for-everyone (1:1 + group) calls `release()` at once
  (a forward elsewhere keeps the blob). Account deletion cascades the rows; a
  `post_delete` signal removes the file.

## Live deploy steps (integrator)

1. Backup DB, pull, `manage.py migrate` (0065), restart `assisto.service`.
2. `mkdir -p /home/ubuntu/assisto/backend/private/circle_blobs && chmod 700`
   (owned by the gunicorn user; created on first upload anyway).
3. nginx — add INSIDE the existing `api.lifeassisto.com` server block, then
   `nginx -t && systemctl reload nginx`:

   ```nginx
   # md1: E2E media ciphertext (only via X-Accel from Django's signed view)
   location /protected-circle-blobs/ {
       internal;
       alias /home/ubuntu/assisto/backend/private/circle_blobs/;
       add_header Cache-Control "private, no-store" always;
       add_header X-Content-Type-Options nosniff always;
       default_type application/octet-stream;
   }
   ```
4. Add `CIRCLE_BLOB_X_ACCEL=1` to `backend/.env`, restart. (Without steps 3–4
   downloads still work — Django streams them — but hold a worker.)
5. Smoke: `curl -s https://api.lifeassisto.com/api/v1/circle/media/limits -H
   'Authorization: Token …'`; `/media/` must still 404.

## App dependencies (pubspec — pinned, licence-clean, lazy)

| package | version | licence | why / launch safety |
|---|---|---|---|
| `crypto` | 3.0.7 | BSD-3 (dart-lang) | streaming SHA-256; pure Dart; was already transitive |
| `record` | 7.1.1 (`record_android` 2.2.0) | BSD-3 | voice-note AAC-LC .m4a; `AudioRecorder` created only in the recorder sheet after the mic permission. Manifest: only `RECORD_AUDIO` (already in ours); **no ContentProvider / initializer** |
| `audioplayers` | 6.8.1 (`audioplayers_android` 5.3.0) | MIT | inline playback via Android MediaPlayer (no ExoPlayer); one `AudioPlayer`, created on the first Play tap. Manifest: empty; **no ContentProvider** |

`record_android` 2.2.0 is AGP-9 style (`plugins { id("com.android.library") }`,
Kotlin built in) — matches the Flutter 3.47 template CI generates (AGP 9.1).
minSdk 24 ≤ our forced 26.

**android.yml changes: none.** `RECORD_AUDIO`, `CAMERA`, `READ_MEDIA_IMAGES`
are already injected; saving uses MediaStore on Android 10+ (no storage
permission); Android 8–9 save falls back to the share sheet (honest message).

## Native (Kotlin) — `messaging/C3MessagingChannel.kt` (existing channel)

`isMetered()` (ConnectivityManager), `pickDocument({max})` (ACTION_OPEN_DOCUMENT
any type, copied off the main thread into cacheDir, size cap enforced while
copying), `saveToPhone({path,mime,name})` (MediaStore Pictures/Assisto or
Download/Assisto, IS_PENDING, background thread). All try/catch, lazy, no
launch work. Compile-checked with kotlinc 2.x against android-35 +
flutter_embedding (rc=0).

## Cost note

Ciphertext only on the box's own disk. Rough steady state at 1,000 daily
senders × (5 photos × 300 KB + 2 voice × 150 KB + 0.5 doc × 1 MB) ≈ 2.3 GB/day;
most blobs are downloaded within a day and kept 30 days after → worst case
≈ 70 GB on disk (≈ $1/month if moved to R2; $0 on the current disk while
< 60 % full). Egress ≈ 1.2 × upload ≈ 80 GB/month (cloud egress ~$7/month at
$0.09/GB; ~$0 on R2). The daily 300 MB/user cap bounds abuse.
