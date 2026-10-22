# md2 — E2E media follow-ups (BUILT)

1. **Forward media to groups** (1:1 → group, group → 1:1, group → group).
   App: `app/lib/messaging/forward.dart` (target picker = accepted members +
   groups I may post in; `buildGroupForwardEnvelope` seals the SAME descriptor
   — ref, key, nonce, sha, name — once per member; `forwardToGroup`,
   `forwardToMember` (keyless member → outbox)). 1:1 screen's forward sheet
   now lists groups; group screen gained a Forward action + the "Forwarded"
   label. Never re-uploaded.
   Server: the blob ↔ message link is every live `CircleMessage.blob_ref`, so
   `can_access` already admitted members of every chat the blob was forwarded
   into; `release()` / `purge()` already count all copies. Fixed:
   `add_recipients` no longer counts the uploader (a forward back to them made
   "all downloaded" unreachable → blob kept to max_days). Group POST now stores
   `forwarded` / `forward_hops`; group + 1:1 lists return them and
   `client_msg_id` (sender's own rows only).
2. **No send-to-poll flicker**: `app/lib/messaging/echo_reconcile.dart`
   (`SentEchoes`). A sent text / finished media bubble is held until the
   fetched page holds the server row with the same id or client_msg_id, then
   dropped in that same frame. `MediaOutbox.recentlySent` (+ descriptor) is
   recorded BEFORE the job leaves the queue, so the screen turns the progress
   bubble into the final bubble in one setState.
3. **Previews**: notifications "📷 Photo / caption", "🎤 Voice message",
   "📄 <file name>" (name/caption decrypted on the phone; hidden previews keep
   the count line only — the server never has a name). Chat list: icon +
   caption / file name. Media ticks: same receipts as text (backend test).

No migration, no ARB change, no nginx change.

Deploy: backup DB, pull, restart `assisto.service` (views only).
