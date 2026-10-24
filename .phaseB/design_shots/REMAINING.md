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

## Remaining work (in the owner's priority order)

1. **My Circle + call screens hand polish** — `lib/screens/circle_screen.dart`,
   `lib/screens/messenger/*` (circle chat, chat list, contact info, add to
   circle, requests), `lib/calls/*` (calling / ringing / connected / video /
   incoming). Replace literal colours/sizes with `AssistoTokens`, `Gap`,
   `Radii`, text-theme styles; check 200% font (`ASSISTO_SHOT_SCALE=2.0`).
2. **Home** (structure kept, look may change): `home_screen.dart`,
   `home_quick_buttons.dart`, `app_drawer.dart`.
3. **Assisto AI chat** (`ai_chat_screen.dart`, `agent_thread_screen.dart`),
   **Photo Studio** (`photo_studio/*`, `photo_studio_screen.dart`),
   **Settings** (`settings_screen.dart`, `messenger_settings*`),
   **Business tools** (`screens/business/*`, CRM, shop box).
4. **Everything else** (the remaining ~280 screens) — sweep.
5. **Icon migration** — one style everywhere. Decision prepared: use Flutter's
   built-in *Material Icons Rounded* (`Icons.*_rounded`, same MaterialIcons
   font that is already bundled + tree-shaken, +0 KB) instead of the
   `material_symbols_icons` package (pub archive 34.6 MB; its Rounded variable
   font alone is 14.8 MB in debug/test builds, `symbols.dart` 7.4 MB of Dart).
   Mapping rule: `X` → `X_rounded`; `X_outlined` → `X_outline_rounded` if it
   exists else `X_rounded`; keep toggles distinct (`star`/`star_border`).
   808 distinct icon names / ~4,950 uses in lib + tests must move together
   (tests use `find.byIcon(Icons.x)`). Not started.
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
