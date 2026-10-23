# CDE — order 6 parts C (video call), D (chat themes), E (nicknames)

## D. Why the old chat theme "did not work" (root cause, found before any change)

The ⋮ → "Chat theme" flow in `app/lib/screens/circle_chat_screen.dart`
(`_chatThemeFlow`, picker `showChatThemePicker` in
`app/lib/widgets/chat_menu_pickers.dart`) had FOUR independent faults — any one
of them alone makes the feature look dead:

1. **Nothing ever painted it.** `_chatTheme` was written (`setState(() =>
   _chatTheme = token)`) but never READ by `build()` — no bubble colour, no
   background, no widget used it. Tapping a swatch changed a variable only.
2. **The server silently threw the value away.** The picker sends tokens
   `cyanBlue / bluePurple / nightInk / warmPaper / forestCalm`, but
   `core/logic/circle_extras.build_chat_settings` only accepts theme ids
   `system | light | dark` (`_THEME_IDS`) and coerces anything else to
   `"system"` WITHOUT an error. So on the next open `GET .../settings` returned
   `theme: "system"` and the picker showed the default again.
3. **Per-user only.** `ChatSettings` is keyed `(user, peer edge)`; nothing was
   sent to the other phone (no message, no mirror like the disappearing timer
   has), so the other side could never see it.
4. The Settings → Chats wallpaper (`WallpaperThemePicker`, M2 item 9) is
   "chosen on this device only" and is also never read by the chat screen.

## The new design (D + E)

* **Sync = E2E control messages inside the chat.** A theme change / nickname
  change is an ordinary E2E text message whose plaintext is
  `<readable fallback line>\n⁣CC1:<base64url(JSON)>` (same shape as the p3
  Assisto cards, `lib/messaging/chat_decor/chat_control.dart`). Both phones see
  it instantly (normal relay + realtime `msg.new`), an offline peer gets it when
  it comes online, old app versions / notifications show the readable line. The
  app renders it as a centred system line ("Rahim changed the theme to Love",
  "You set the nickname for Rahim to Bhaiya") and folds it into the chat state.
* **Persistence:** on the device in SharedPreferences (`DecorStore`, survives a
  restart), and on the server in `ChatDecor` (migration `0077_cde_chat`) —
  theme id + nicknames per chat (1:1 pair key or group id) — so a reinstall /
  second phone gets them back. Nicknames are not secret; the theme is only an id.
  The server copy is written FIRST (it also enforces Free/Premium), then the E2E
  control message goes out; both carry the same server timestamp, so the newest
  write wins on every phone.
* **Custom photo theme:** the photo is sealed on the phone and uploaded as
  ciphertext through the md1 media pipeline (`MediaOutbox`, signed URLs); the
  file key travels only inside the E2E message (a normal md1 photo descriptor
  plus a `cc1` block). The server stores `theme: custom` and never the key.
  Old app versions see it as a normal photo. Shown dimmed so text stays
  readable. After a reinstall the photo comes back from chat history while that
  message is still loaded; otherwise a dark fallback is shown (honest limit: the
  server can't hold the key).
* **AI theme from a prompt:** reuses Photo Studio `generate` (credits / Premium
  pool, Profit Guard, safety classifier, FACE_RULE "Face Lock"). The entry is
  shown ONLY when the server's photo-studio config says `generate` is fundable
  (an image provider key + cost is connected) AND the user is Premium. No key →
  no entry (no "coming soon").
* **Free vs Premium:** server `chat_decor.FREE_THEMES` (classic, love, sunset,
  calm); everything else + custom + AI needs a paid plan
  (`plans.effective_plan != free`). The server refuses a locked theme with 402.
* **Nicknames:** set/change/remove for me or the other person (1:1) or any
  member (group). Shown in the chat header, chat list, notifications (server
  push title + device notification), call screen (`member['nickname']`, push
  `caller_name`). The real name stays in contact info / group info.

## C. Video call

`lib/calls/video_stage.dart` (`VideoStage`): tap the small view → swap big /
small; drag the small view → snaps to the nearest corner; pinch-zoom the big
view (InteractiveViewer 1–4×, reset on swap); double-tap the big view → full
screen (controls hidden, double-tap again to bring them back); flip camera
(existing `call-flip`); camera on/off is signalled to the other side (existing
`camera_off` signal → `call-remote-camera-off` badge + avatar placeholder).

## Honest limits

* Real 2-phone proof (OPPO/ColorOS etc.) can't be done on this build box — the
  owner's steps are in `owner_actions/CDE_TEST_BN.md`.
* AI theme stays hidden until an image provider key is connected in
  Integrations.
