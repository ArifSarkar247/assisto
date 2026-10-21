# Premium QA scorecard — slot a1 (PART 7)

Scope (coordinator split): home, drawer, AI chat, Reminders & Memory, Daily Life,
Work, plans. NOT here: Business/Money (a2), Safety/SOS/Family/My Circle/Settings/
Account/Onboarding (a6), shop/CCTV (a2), voice assistant (a3), push/calls/ads (a6).

Method: gallery harness `app/test/screenshots_test.dart`, 360x800, bn/en x light/dark,
plus a large-font pass (`ASSISTO_SHOT_SCALE=1.5`, files suffixed `_xl`). Any
RenderFlex overflow fails the test, so both passes passing = no layout overflow.
Score /10 = clipping, contrast, spacing, empty/error states, bn quality.

Re-render a screen:
`ASSISTO_SHOT_DIR=<dir> ASSISTO_SHOT_ONLY=<name> [ASSISTO_SHOT_SCALE=1.5] flutter test test/screenshots_test.dart`
Shots: `<dir>/<name>_<bn|en>_<light|dark>[_xl].png` (review set was rendered to the
a1 scratchpad `qa/`; the integrator re-renders into `~/assisto/screenshots`).

Harness fixes: real elevation shadows (flutter_test drew FABs with a solid black
outline), text-scale pass, `ASSISTO_SHOT_DIR`, new shots `ai_chat`, `nearby`,
`used_phone_check`, `vehicles`, `smartwatch`, `quick_grid_owner`.

| # | Screen (shot) | Before → After | What was fixed |
|---|---|---|---|
| 1 | Home (`home_welcome`, `home_top`) | 7 → 9 | XL: Discover carousel overflowed (fixed 112px height) and shortcut tiles overflowed + broke words mid-word ("Reminder s"). Carousel + tile height now follow font size; tile labels cap at 1.2x. |
| 2 | Drawer (`drawer`, `drawer_bottom`) | 8 → 9 | Single "New chat" (no duplicate). XL: section/item titles were cut with "…" → 2 lines. |
| 3 | Assisto AI chat (`ai_chat`) | 7 → 9 | Welcome state was a logo + text over an empty screen → 4 tap-to-send suggestion cards (bn/en). Shared-mic stuck-pulsing bug fixed (see voice commit). |
| 4 | Reminders (`reminders`) | 8 → 9 | Quick-add example hint was cut mid-sentence → shows on 2 lines. |
| 5 | Birthdays (`birthdays`) | 9 → 9 | — |
| 6 | Meetings (`meetings`) | 8 → 9 | "1 meetings" → "1 meeting" (en; bn ১টি মিটিং). |
| 7 | Notes & tasks (`notes_tasks`) | 9 → 9 | — |
| 8 | What AI knows (`memory`) | 7 → 9 | Consent buttons wrapped/broke mid-word ("Rememb er it") → one line, scale-to-fit. Search hint was truncated → shorter hint. |
| 9 | Saved (`saved`) | 8 → 9 | Empty state showed the same "Save item" action twice (CTA + FAB) → FAB hidden when empty. |
| 10 | Plans (`plans`) | 6 → 9 | Comparison table threw a layout assertion (infinite-width header in a horizontal scroll → blank in release). Free plan said "15 / mo" while the live pool is 0 → AI cell + benefit text from live config. |
