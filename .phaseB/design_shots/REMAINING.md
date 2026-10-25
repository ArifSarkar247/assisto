# f1-design — what is NOT done yet (stopped early for owner order 6)

Branch `agent/f1-design` stopped at a clean checkpoint on the coordinator's
request. Done: tokens + type scale + component themes (`app/lib/theme.dart`),
bundled OFL fonts (Inter + Noto Sans Bengali, static 400/500/600/700),
the Bangla font decision, the no-clip / tap-target / contrast test
(`app/test/f1_design_test.dart`), and before/after shots of the 30 key screens
(theme-level change only — no screen was hand-edited).

## f2-design (part 2, branch `agent/f2-design`) — done

- `AType` in `lib/theme.dart`: the one type scale as colour-/weight-less
  metrics; the text theme is now *built from it* (single source). Replaces bare
  `TextStyle(fontSize: n)` and keeps inheriting colour/weight like the literal.
- Item 3 (not the messenger/circle/calls part): AI chat (`ai_chat_screen`,
  `agent_thread_screen` — tokens only, home layout untouched), Photo Studio
  (`photo_studio_screen`, `photo_studio/*`), Settings (`settings_screen`),
  Business (`screens/business/**`, CRM `screens/crm/*`, `crm_contacts_screen`,
  Shop Box `shop_*`), money (`money_*`), reminders: every `fontSize:` literal →
  `AType`/text theme (one exception: the export watermark painted onto the
  image), spacing/radius literals equal to a token → `Gap`/`Radii`,
  `Brand.success/warning/danger` → `AssistoTokens`/`colorScheme.error` (these
  are AA in both themes; e.g. amber text on white was ~2:1), white text on
  primary → `onPrimary` (dark-mode user bubble was ~2.6:1), purple/blue/cyan
  text → `Brand.onTint`.
- Item 8: tabular figures on amounts/times in money (+ common stat cards /
  delta chip), khata, quick-sell, cashbox, `MoneyRow`, reminders chips.
- Item 6 (partial): guard test `test/f2_design_guard_test.dart` — fails on any
  NEW `Color(0x…)` outside `theme.dart` (per-file allowlist of today's 287
  literals in 53 files; counts may only go down) and on any `fontSize:` in the
  f2 screens; checks `AType` == text theme metrics.
- Item 7 on these screens: tooltips on all icon-only buttons (19), 48 dp
  quick-sell qty steppers, labels for the voice mic button, khata FAB,
  reminder checkboxes, CRM pipeline cards; money tabs no longer break
  "Transaction" mid-word at 1x. Gallery audit: `ASSISTO_SHOT_A11Y=1` runs the
  tap-target + label guidelines on every shot → `$ASSISTO_SHOT_DIR/a11y.txt`.
- Proof: `.phaseB/design_shots/f2/` (README there).

### Still open after f2
- Home-chat "Undo" chip on `ChatCard` is 40 dp tall and the home drawer's
  "Edit" button 40 dp (home frozen — needs owner OK to change layout).
- Item 6 sweep for the rest of `lib/` (~280 `Color(0x…)` still allowlisted,
  ~1,500 `fontSize:` outside the f2 screens); the call/messenger files are
  being edited by the circle agent — its new literals need the allowlist or
  tokens when merged.
- Items 1, 2, 4, 5, 9 unchanged (item 5 icon migration not started on purpose).

## f3-design (part 3, branch `agent/f3-design`) — item 1 done

- `CallInk` in `lib/theme.dart`: the always-dark call canvas palette (text /
  soft / hint ink, failure red, quality bars, glass, scrims, mini bar).
- Call screens (`circle_call_screen`, `push/incoming_call_screen`,
  `calls/call_mini_bar`, `calls/video_stage`, `calls/call_avatar`): every
  `Color(0x…)` → `CallInk`, every `fontSize:` → `AType` (avatar initial
  stays radius-relative), spacing/radius → `Gap`/`Radii`, timer + mini-bar
  time tabular.
- My Circle (`circle_screen`, `circle_chat_screen`, `circle_group_chat_screen`,
  `ring_checklist_screen`, `messenger/messenger_home_screen`, `m3_add_to_circle`,
  `connection_requests`, `widgets/msgr_hub_chat_list`, `messaging/date_separators`,
  `messaging/call_events`, `messaging/chat_header`): type scale, tokens
  (typing/online green → `AssistoTokens.success`, E2E note → warning
  container, "sent" check → success/onSuccess), tooltips on send / close /
  back / add, 48 dp group reaction targets, 48 dp E2E note + call-event
  chip tap areas, chat-list chips + badges no longer clip at 200 %,
  request Accept/Decline wraps instead of overflowing.
- Guard: allowlist down 287 → 267 `Color(0x…)` (removed circle_call_screen 9,
  call_mini_bar 2, video_stage 1, msgr_hub_chat_list 2, date_separators 4,
  chat_header 2); the no-`fontSize` guard now covers the call + circle files
  above. Proof: `.phaseB/design_shots/f3/` (a11y audit clean on all 22 screens).

### Still open after f3
- `circle_chat_screen` / `circle_group_chat_screen` are `fontSize`-clean but
  not in the guard yet (the My Circle media branch is adding attach options
  there — add them once it has merged).
- `call_events.dart` keeps its 2 missed-call reds (a1_circle_test asserts
  `0xFFB91C1C`); `msg_ticks.dart` (10) untouched.
- Chat list: the "Invite" text link on not-on-Assisto rows is < 48 dp tall
  (the whole row is also tappable); names truncate earlier at 200 % (16 sp).
- `chat_header` status fitting keeps its own computed font sizes.

## Remaining work (in the owner's priority order)

1. ~~My Circle + call screens hand polish~~ — done in f3 (see above).
2. **Home** (structure kept, look may change): `home_screen.dart`,
   `home_quick_buttons.dart`, `app_drawer.dart`.
3. **Assisto AI chat** (`ai_chat_screen.dart`, `agent_thread_screen.dart`),
   **Photo Studio** (`photo_studio/*`, `photo_studio_screen.dart`),
   **Settings** (`settings_screen.dart`, `messenger_settings*`),
   **Business tools** (`screens/business/*`, CRM, shop box).
4. **Everything else** (the remaining ~280 screens) — sweep.
5. ~~**Icon migration**~~ — done in f5 (branch `agent/f5-icons`): Material
   Icons Rounded everywhere (+0 KB, same bundled font), via
   `app/tool/icons_to_rounded.py` (reads the SDK `icons.dart`, idempotent).
   799 distinct names / 5,129 uses in lib + test moved together. Toggle pairs
   (ternary or `icon:`/`selectedIcon:`) that would collapse keep the outlined
   "off" glyph: `push_pin_outlined` (6 files), `shield_outlined`
   (fall_detect), `filter_alt_outlined` (task_manager), messenger nav tabs
   (`forum/auto_awesome/groups_2/call_outlined`). Still open:
   - no rounded variant in the SDK: `Icons.outgoing_mail` (community_list,
     moderation_appeal), `Icons.workspaces_outline` (subs_common);
   - skipped on purpose (home frozen): `home_screen.dart`,
     `home_quick_buttons.dart` (42 icon uses) and `test/b2_badges_test.dart`
     (finds the home bell / My Circle icons) — run the script with those
     removed from `SKIP` when the owner opens the home look.
   Proof: `.phaseB/design_shots/f5/`.
6. **Hard-coded colour/size sweep** — 173 `Color(0x…)` literals and 1,806
   `fontSize:` in `lib/`; replace with tokens, then add the guard test that
   fails on a NEW `Color(0x…)` outside `theme.dart` (allowlist the call-screen
   dark canvas, brand gradient, camera overlays).
7. **Accessibility** — `meetsGuideline(androidTapTargetGuideline)` +
   `labeledTapTargetGuideline` on the key screens themselves (today only the
   theme's components are covered), semantics labels on icon-only buttons,
   fix every overflow found in the 200% pass (`.phaseB/design_shots/xl/`).
8. **Tabular figures on amounts/times** — helper is ready
   (`AFonts.figures(style)` / `AFonts.tabular`); apply in money, khata,
   quick-sell, call timer, reminders.
9. Remaining 300+ screens: before/after shots beyond the first 30.
