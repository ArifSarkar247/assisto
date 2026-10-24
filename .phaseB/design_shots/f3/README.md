# f3-design proof (owner order F, part 3 — My Circle + call screens)

- `sheets/<screen>.jpg`: before | after for bn/en × light/dark at 360 dp, 1x.
  Before = origin/main at 552e0fb, after = branch `agent/f3-design`.
- `sheets_xl/<screen>_xl.jpg`: the same at 200 % text (`ASSISTO_SHOT_SCALE=2.0`).
- Raw PNGs are not committed; regenerate with
  `ASSISTO_SHOT_DIR=… ASSISTO_SHOT_ONLY=<names> [ASSISTO_SHOT_SCALE=2.0] [ASSISTO_SHOT_A11Y=1] flutter test test/screenshots_test.dart`.

Screens (22): circle, circle_chat, c3_chat, c3_chat_list, contact_info,
c3_x2_contact_info, m3_add_circle, m3_add_found, m3_add_notfound, m3_requests,
messenger, incoming_call, c2_call_incoming_video, c2_call_calling,
c2_call_ringing_no_relay, c2_call_connected_voice, c2_call_video_connected,
c2_call_busy, b1_call_voice_controls, b1_call_mini_bar, f3_ring_checklist and
f3_group_chat (the last two are new gallery specs, `test/f3_shots.dart`).

A11y audit (`ASSISTO_SHOT_A11Y=1`, tap target ≥ 48 dp + labelled tap
targets) over all 88 after shots: **no findings** (before: chat-list filter
chips 36 dp tall, the E2E note in chats 46 dp tall).

What to look for:
- Chat list at 200 %: unread badges and filter chips are no longer clipped
  (the pills grow with the text; the chip row takes the chips' own height).
- Call canvas: same look; colours now come from `CallInk` (theme.dart),
  13/15 sp one-offs snapped to the type scale, timer uses tabular figures.
- E2E note / unread divider / security note: AA warning-container tokens and
  the type scale (line height 1.5 for Bangla instead of 1.3).
- "Request sent" check uses the AA success token; group-chat reaction emoji
  get 48 dp targets; send / close / back buttons have tooltips.
