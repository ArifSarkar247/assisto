# P3 — My Circle = WhatsApp + AI assistant + family safety (design)

Owner order P3: "@Assisto" inside chats/groups, family-safety links inside
chats, Stories (24 h) + profile Notes in the Updates tab with privacy.

Written BEFORE coding. The hard rule for everything below:

> My Circle 1:1 and group messages are END-TO-END ENCRYPTED. The server stores
> ciphertext only and can never read a message. Nothing in P3 changes that.

## 1. The E2E rule for "@Assisto"

* The server NEVER reads chat content. There is no server-side job, no
  background summariser, no "AI watches the chat".
* An AI action that needs message content (Summarize unread, Translate a
  message, Ask with context) runs ONLY when the user taps it, on the user's own
  phone: the phone decrypts the messages it already holds, shows exactly WHICH
  text will be sent ("These 12 messages will be sent to Assisto AI"), and sends
  only that text to `POST /circle/assisto/run`.
* A clear one-time notice is shown before the first such action: "This sends
  these messages to Assisto AI. They leave end-to-end encryption for this one
  request; Assisto does not keep them." The user ticks "Don't show again" to
  remember the choice on this phone (SharedPreferences `p3_ai_consent_v1`).
  Even after that, every run still shows the message count + credit cost on the
  confirm button — nothing is ever sent silently.
* The request body carries `consent: true`; the server refuses content-bearing
  actions without it (`400 consent_required`). The server does not store the
  text: only the normal `AIUsage` row (feature, model, token counts, cost).
* Translate of my own DRAFT and "Ask a question" send only what I typed.
* Non-AI actions (reminder, split, shopping list, safety cards) never touch the
  AI or the server's plaintext: they are E2E-encrypted card messages.

## 2. Assisto cards (E2E like any message)

A card is a normal `content_type: "text"` message whose PLAINTEXT (encrypted per
recipient exactly like a text message) is:

    <readable fallback line>\n⁣AC1:<base64url(JSON)>

* The readable first line is what notifications, chat-list previews and older
  app versions show ("⏰ Reminder: Pay the bill · Tue 9:00 AM").
* New clients detect the `⁣AC1:` marker and render a rich card instead.
* No backend change, no new content type, no server plaintext.

Card types (`t`):

| t            | Shown as                                   | Who acts                     |
|--------------|--------------------------------------------|------------------------------|
| `summary`    | AI summary of unread (posted only if user chooses "Share in chat") | — |
| `answer`     | AI answer to a question (optional share)   | —                            |
| `translate`  | translated text (optional share)           | —                            |
| `reminder`   | reminder for me / for everyone             | each member taps **Add to my reminders** (nobody gets one silently) |
| `rem_ack`    | hidden event: "X added it"                 | folds into the reminder card |
| `split`      | bill split: total, per-person shares       | sender's Expense-split book gets the entry |
| `list`       | shared shopping checklist                  | every member can tick        |
| `tick`       | hidden event: item i ticked/unticked by X  | folds into the list card     |
| `arrived`    | "I reached safely" (+ place, time)         | —                            |
| `sos`        | SOS with live-location link                | — (also fires existing SOS)  |
| `med`        | missed / taken medicine status             | —                            |
| `lost`       | lost-phone alert (don't trust OTP/money requests from my number) | — |

Shopping-list sync and reminder acceptance are themselves encrypted messages
(`tick` / `rem_ack`), so the server sees nothing and every member's phone folds
the same event log into the same list state (last event per item wins).

## 3. Credits (nothing unlimited)

* Every AI call goes through `core.ai.generate` → `billing.charge` (atomic
  pre-charge, refund if every provider fails, Profit Guard for free users).
* `GET /circle/assisto/quote` returns the live credit cost per action from the
  owner-editable pricing table (`ai_msg_cheap` = 1 credit by default) and the
  user's balance; the sheet shows "Uses 1 credit" on the button BEFORE running.
* Out of credits → honest "You are out of credits" + **Get credits** (opens the
  existing Credits screen). AI key missing → honest "AI is not available right
  now" (no charge). Profit Guard over → "Paused for today" (no charge).
* Non-AI actions (reminder / split / list / safety cards / scam check) cost 0
  credits: they never call an AI provider.
* Caps per call: ≤ 80 messages, ≤ 6 000 characters (bounded cost).

## 4. Family safety inside chats

All reuse existing features; each posts an E2E card into THIS chat:

* **I reached safely** — if a Safe Journey is active, marks it arrived
  (`POST /journey/<id>/arrived`) and posts the card with the destination.
* **SOS** — confirm dialog, then the existing `POST /journey/sos` (safety-exempt,
  never charged) + an SOS card with the location link (journey web link when a
  journey is active; else the phone's last known map point if available).
* **Medicine update** — today's doses from `/medicines/today`; the user sends a
  card listing missed (and taken) doses to this family chat.
* **Lost phone alert** — reads `/security/lost-phone` (last location) and posts
  "My phone was lost — don't share OTPs or send money if asked from my number".
* **Scam warning** — ON-DEVICE rule engine (`lib/p3/scam_guard.dart`) runs over
  each incoming decrypted message: OTP/PIN sharing requests, bKash/Nagad agent
  fraud, prize/lottery, look-alike domains, urgent money requests (stronger for
  a chat that is new). bn + Banglish + en. Shows a non-blocking banner under
  the message with **Why?**. Never sends content anywhere. Combination rules
  (e.g. "OTP" alone is fine; "OTP ta dao" is not) keep false positives low.

## 5. Stories (24 h) + Notes

What existed: `CircleStatus` / `StatusView` / `StatusMute` + views, but the
text was sealed to the AUTHOR's own key (viewers could not decrypt), tray
response keys did not match the app, author ids were confused with circle edge
ids. P3 completes it:

* **E2E per viewer**: the phone resolves the audience, encrypts the story (text,
  or the photo's md1 media descriptor) once per allowed viewer and posts
  `per_recipient {user_id: {ciphertext, nonce}}` (+ a self copy). The server
  returns each viewer ONLY their own entry, and only if `can_view_status`
  still allows them (block both ways, mute, audience, expiry).
* **Photo stories** use the existing encrypted media path (`circle_media_blobs`):
  the photo is encrypted on the phone, uploaded as ciphertext; the key travels
  inside the per-viewer ciphertext. `circle_blobs.can_access` lets a viewer of
  an ACTIVE story download it; retention purge never deletes a blob an active
  story still uses. Video stories: not supported (no video pipeline exists).
* **24 h expiry server-side**: every read filters `expires_at > now`; the
  hourly `purge_l1_retention` deletes expired stories (+ views) and notes.
* **Viewers list** with read-receipt rule (anonymous count), **mute**, **delete
  my story**.
* **Privacy**: My contacts / My contacts except… / Only share with… — saved as
  the default (`CirclePrivacy.visibility["status_default"]`) and overridable per
  story. Server re-resolves per viewer.
* **Profile Notes** (Instagram-style): ≤ 60 chars, 24 h, same privacy modes,
  E2E per viewer (`CircleNote`), shown on the Updates tab, the chat header
  sheet and contact rows.

## 6. Migration

`0069_p3_circle` (depends on the newest migration on origin/main at the time):
adds `CircleStatus.per_recipient` (JSON, nullable) and creates `CircleNote`.
Reversible (AddField / CreateModel only).
