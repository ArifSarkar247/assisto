# f5-icons proof (owner order F, REMAINING item 5 — one icon style)

- `before/` = origin/main 347d1b9, `after/` = branch `agent/f5-icons`;
  en / light, 360 dp, 1x. Screens: drawer, settings, messenger, money,
  reminders, biz_hub. (bn / dark variants not committed; regenerate with
  `ASSISTO_SHOT_DIR=… ASSISTO_SHOT_ONLY=drawer,settings,messenger,money,biz_hub,reminders flutter test test/screenshots_test.dart`.)
- Change: every `Icons.*` in `lib/` + `test/` now uses Material Icons
  **Rounded** (same bundled MaterialIcons font, +0 KB). Script:
  `app/tool/icons_to_rounded.py` (idempotent; reads the SDK `icons.dart`).
- What to look for: outlined icons become solid rounded glyphs (pencil,
  sparkles, voice, palette in Settings); filled ones get rounded corners.
  Selected/unselected pairs stay distinct (pins, messenger nav tabs, filter,
  shield toggle keep their outlined "off" state).
