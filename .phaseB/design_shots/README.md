# f1-design proof

- `before/`: current main (b8159c1). `after/`: branch `agent/f1-design`.
  Both cover the 30 most-used screens in bn and en, light and dark, at 360 px
  (1x). The changes are theme-level only (tokens, type scale, fonts,
  component themes); no screen file was hand-edited.
- `sheets/<screen>.jpg`: one contact sheet per screen showing before | after
  for all 4 variants. Home (`home_welcome`, `home_top`) and My Circle
  (`circle`, `circle_chat`, `c3_chat_list`, `circle_call_history`) come first.
- `xl/`: the same 30 screens at 200% text size (light), produced by the
  `ASSISTO_SHOT_SCALE=2.0` gallery. No RenderFlex overflow was logged.
- `bangla_font_compare/`: Noto Sans Bengali, Hind Siliguri and Anek Bangla on
  6 screens. See `BANGLA_FONT_DECISION.md`.
- `STATUS_BN.md`: Bangla summary for STATUS. `REMAINING.md`: work not done.

Screens: home_welcome, home_top, chat, drawer, circle, circle_chat,
c3_chat_list, circle_call_history, contacts, m3_add_circle,
c2_call_connected_voice, incoming_call, c2_call_video_connected, ai_chat,
photo_studio_free_empty, photo_studio_free_enhanced, settings, money,
reminders, notes_tasks, family, emergency, vault, notification_centre,
biz_hub, biz_quick_sell, biz_khata, login, otp_verify, plans.

Note on app-bar titles: before this change, every app-bar title rendered at
the 14 sp default, not a title size. `AppBarTheme.titleTextStyle` was built
from `ThemeData.textTheme` before localization, which carries colours only
and no font sizes. The new explicit type scale fixes this (20 sp, w700), so
titles look larger in every "after" shot.
