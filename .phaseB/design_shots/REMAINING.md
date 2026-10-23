# f1-design — what is NOT done yet (stopped early for owner order 6)

Branch `agent/f1-design` stopped at a clean checkpoint on the coordinator's
request. Done: tokens + type scale + component themes (`app/lib/theme.dart`),
bundled OFL fonts (Inter + Noto Sans Bengali, static 400/500/600/700),
the Bangla font decision, the no-clip / tap-target / contrast test
(`app/test/f1_design_test.dart`), and before/after shots of the 30 key screens
(theme-level change only — no screen was hand-edited).

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
