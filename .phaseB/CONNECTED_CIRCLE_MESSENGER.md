# CONNECTED CIRCLE MESSENGER — FULL SPEC (supersedes ALL earlier Connected Circle / referral / photo / video / privacy notes)
Owner wants everything WhatsApp + Messenger offer, premium standard. Rules: premium reviewer (benchmark = WhatsApp + Messenger feature-by-feature), language gate (no Bangla in .dart / bn+en), gallery (every chat/media/call/group/status/settings screen bn/en×light/dark), e2e tests incl SERVER-SIDE enforcement, server throttle, public-window. ORIGINAL design — never copy their UI/icons/sounds/text/assets.
FOUNDATION: extend the module-5 circle (app/lib/screens/circle_*, app/lib/crypto/e2e.dart MLS-seam software fallback, backend/core/logic/circle.py, CircleMember/Message/Invite/Report models). Don't duplicate.
CORE: only accepted-relationship members can message/call; no strangers/unsolicited; groups = circle members only. E2E (MLS; software fallback now); server stores CIPHERTEXT ONLY; server AI never reads.

## PHASE M1 (ship with the Module-5 wave — next APK):
1. Invites/relationships: invite by phone/QR/share-link; MANDATORY relationship (Family/Friend/Cousin/Husband/Wife; optional family sub Father/Mother/Child/Sibling/Other — never required, no proof); existing user→in-app Accept/Decline; non-user→link→install→signup→Accept/Decline.
2. Referral points: inviter earns points when invitee installs+signs up+accepts; redeem for Premium days (rate TO REVIEW BY OWNER); balance+history in Plans/Profile; anti-abuse (active acct, phone-verified when SMS key, one reward/real person+device, monthly cap, reject self-invite/dup-device, revocable, logged); optional welcome bonus.
3. 1:1 messaging: text formatting, emoji, delivered/read ticks, typing, reply, reactions, edit (time-limited), delete-for-me/everyone, forward(+label), copy, star/save, pin in chat, search in-chat + across chats, link previews on SENDER device (no server fetch), offline queue+retry.
4. Media (WhatsApp/Messenger-class): gallery multi-select/camera, preview+caption, thumbnails+progress, full-screen viewer (pinch/swipe), save, forward; standard vs HD; compression; voice notes (hold-record, slide-cancel, playback speed); short videos; docs (PDF/Office); contact cards; current + LIVE location (15m/1h/8h) — all encrypted, size limits, auto-cleanup undelivered blobs, disk floor.
5. Calls: VOICE free for all. VIDEO Premium-only — CALLER must be Premium/Family/Business, receiver can be free; free caller sees upgrade prompt; referral points can unlock; GATED SERVER-SIDE. History/missed/callback/mute/speaker/switch-camera/low-data. App-closed ring = FCM/PushKit-CallKit (owner keys); prod TURN = separate server; until then calls work while app open (stated in UI).
6. Privacy/controls (SERVER-ENFORCED, safe defaults): incoming calls off / chosen people / relationship types / DND schedule w/ optional family exception (missed still logged); block (silent); restrict (separate inbox, no notif, no active-status/read-receipts, calls don't ring); report (attach recent msgs optional, block too); last-seen/profile-photo/about/status visibility = circle/family/nobody; read-receipts+typing on/off reciprocal (WhatsApp rule); mute 8h/1wk/always, archive, pin chats, chat lock PIN/fingerprint, delete chat.

## PHASE M2 (right after M1):
7. Groups (circle only): name/photo/desc, admins/roles, add/remove, invite-link circle-only, @mentions, replies, reactions, polls, pinned, announcements-only, leave/report; group voice free, group video Premium; size limit configurable.
8. Status/Stories: photo/video/text 24h, visibility (circle/family/chosen/exclude), view list, reply privately, mute.
9. Extras: disappearing msgs (24h/7d/90d), view-once, per-chat wallpapers/themes, ORIGINAL sticker packs + user stickers from own photos, GIF search (Tenor/GIPHY owner key), on-device voice transcription, message translation (AI key), scheduled msgs, broadcast list (chosen circle), "@Assisto" in chat → reminder/expense/event (on-device, on tap), encrypted chat backup + recovery code + restore, export chat.
10. Linked devices / multi-device encryption: DESIGN now; web client after Android+iPhone (platform order).

## PHASE M3 (needs separate server): 11. Group video (SFU), screen share, call links — build client+API, mark 🔑 until server.

## NOT BUILT (record reasons): in-chat money transfer (needs Bangladesh Bank licence — at most payment-link via licensed partner); public channels/communities with strangers (conflicts circle-only safety + needs moderation team — owner decision later).

## DONE CRITERIA: feature-by-feature table vs WhatsApp+Messenger in ASSISTO_REPORT.md (✅/➕/⏳/⛔+reason); e2e tests incl server-side block/restrict/call-permissions/video-plan-gate/reciprocal-visibility/invite-acceptance; gallery every screen bn/en×light/dark; APK after M1 and after M2.
