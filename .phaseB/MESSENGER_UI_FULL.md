# MESSENGER / MY CIRCLE — FULL UI SPEC (owner combined, supersedes v2/v3) 2026-10-14
Original Assisto icons/visuals ONLY (never Meta assets/names/screenshots). One-line labels @360dp bn+en, strict language. Every menu item works OR honest "needs key X" state — NO dead taps. Scenario tests each action.

## 1. SIDEBAR
- Top entry (under New chat) = "আমার সার্কেল / My Circle" → opens hub. (already done v2)
- DELETE expandable My Circle group (done v2). Remove sidebar profile card (done v2 → Settings).
- RULE: exactly ONE entry per module; no feature sub-entries; features live in their module screen.

## 2. MY CIRCLE HUB (chat list)
- Title "My Circle"; top-bar: camera (status/photo) + ⋮.
- Search bar under title: "Ask Assisto or search".
- Filter chips: All · Unread · Favourites · Groups (+ user's own lists).
- Hub ⋮ (order): New group · New community · Broadcast lists · Linked devices · Starred · Read all · Settings.
  - New group: pick contacts, name, photo, desc; admin settings (who edits info/sends msgs/adds members; approve new members).
  - New community: existing create flow.
  - Broadcast lists: one msg → many contacts as SEPARATE personal msgs; only recipients who have YOU in their circle receive.
  - Linked devices: QR link web/desktop (SERVER side now; web later), list devices+last active, logout each.
  - Starred: all starred msgs across chats; tap → jump to msg.
  - Read all: mark every chat read.
  - Settings: profile card top (photo/name/bio/phone/edit) → Account(two-step PIN, change number, data export, delete) · Privacy(last seen/online/read receipts/profile photo/about/status/who-can-msg/who-can-call/blocked/message-requests) · Chats(theme/wallpaper/backup/history) · Notifications · Calls(incoming on-off/silence unknown) · Storage&data · Language · Help · Invite a friend.
- Connected circle (relationships/requests) → top-right people icon + new-chat/contacts screen.
- Circle calls → merge into Calls tab.

## 3. 1:1 CHAT
Top bar: back · photo+name(tap→Contact info) · video(Premium, caller pays) · voice · search · ⋮.
Chat ⋮ (order): Contact info · Search · Select messages · Mute ▸ · Disappearing messages · Chat theme · Add to favourites · Add to list ▸ · Export chat · Close chat · ─ Send call link · Schedule call · New group call · ─ Assisto extras: Summarise chat · Make reminder from chat · Translate chat · ─ Report · Block · Clear chat.
Behaviour: Search=find+jump in-chat. Select=multi→delete(me/everyone within time limit)/forward/star/copy. Mute▸8h/1wk/Always. Disappearing▸Off/24h/7d/90d (server+device enforced). Chat theme=per-chat colour+wallpaper. Favourites+lists feed hub chips. Export=.txt ±media via share. Send call link(expiring)·Schedule call(time+reminder all invitees)·New group call. Report=user picks; LAST 5 MESSAGES decrypted on reporter device → moderation. Block. Clear chat(keeps entry).
Group ⋮ = same + Group info/Group media/Add members/Exit group/Report group. Community+channel = own ⋮ with only applicable actions.

## 4. CONTACT INFO
Photo, name, about, phone, media/links/docs, starred, mute, custom notifications, disappearing, chat lock, encryption note, groups in common, relationship(Connected circle), Block, Report.

## VERIFY: gallery bn/en×light/dark@360dp: sidebar, hub, hub ⋮ open, Settings, Privacy, 1:1 chat, chat ⋮ open, group ⋮, Contact info. analyze 0, gate clean, secret scan, build, 3-line Bangla.
## BACKEND NEEDED (reuse circle_extras[broadcast/disappearing/backup/linked-devices-design/stickers], circle_calls, circle_messaging, moderation): starred-messages, linked-devices(QR gen+list+logout server), scheduled-calls+call-links, report-last-5-messages, read-all, per-chat theme/wallpaper persist, custom lists.
