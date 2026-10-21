# Premium QA scorecard — slot a6 (Safety/SOS · Family · My Circle · Settings · Account · Onboarding)

Method: every screen rendered at **360×800** in **bn/en × light/dark**, plus a
**1.5× font** pass (bn-light + en-dark), with the QA harness
`app/test/qa_a6_shots_test.dart` (`ASSISTO_SHOT_DIR`, `ASSISTO_SHOT_SCALE`,
`ASSISTO_SHOT_ONLY`). The harness also records every layout error (RenderFlex
overflow = clipped text) per shot in `<dir>/_report.txt`.
Score /10 = clipping · contrast · spacing · empty/error/loading states · bn quality.

Shots (scratchpad of this session):
- before: `/tmp/claude-1000/-home-ubuntu-assisto/ea8a0e54-3e29-4bc2-a831-7f9d2da14cc0/scratchpad/qa/`
- after:  `/tmp/claude-1000/-home-ubuntu-assisto/ea8a0e54-3e29-4bc2-a831-7f9d2da14cc0/scratchpad/qa2/`
- 6-up review sheets (bn-light, bn-dark, bn-1.5×, en-light, en-dark, en-1.5×): `…/scratchpad/sheets/<name>.png` (before), `…/scratchpad/sheets2/<name>.png` (after)

Layout-error report after fixes: **138/138 shots OK** (0 overflow) — batch 1.

## Batch 1 (23 specs / 21 screens)

| Screen | Before → After | What was fixed |
|---|---|---|
| Safety hub (`safety`) | 7 → 9 | Safe-arrival "no check-in" card: trailing *Set* button squeezed the text to 2–3 words/line (1 word at 1.5×) — button moved under the text. Journey description + countdown/footer notes were `Colors.grey` (≈2.6:1 on light) → `onSurfaceVariant`. Warning ink readable in dark. |
| Emergency card (`emergency`) | 7 → 9 | "Share my location" / "Safety tools" side-by-side pills wrapped to 3 lines in Bangla and the label spilled outside the border — now full-width, stacked. Grey notes → `onSurfaceVariant`. |
| Hands-free Voice SOS (`voice_sos`) | 3 → 9 | **Endless spinner** if any plugin/channel probe threw (foreground-task / mic) — every probe now guarded, screen always renders. |
| Fall detection (`fall_detect`) | 8 → 9 | "Needs motion access" banner: dark-amber `0xFF8A6D00` text on a dark surface ≈2:1 → new `Brand.warnInk(context)` (light amber in dark). |
| Journey start (`journey_start`) | 8.5 → 9 | Grey helper texts → `onSurfaceVariant`. |
| Journey live (`journey_live`) | 7.5 → 9 | "I've arrived safely": white on `Colors.green` 2.8:1 → deep green `#1E7E4E` (≈5:1). Fake-call / Stop pair now stacks at large font (`AdaptiveButtonPair`). Footer contrast. |
| Journey SOS countdown (`journey_sos`) | 8.5 → 9 | "Enter your PIN to cancel" hint `white70` 12px on red → white 13px. Grey note → `onSurfaceVariant`. |
| Lost / stolen (`lost_stolen`) | 3 → 9 | **Endless spinner** when secure storage threw (keystore reset / ColorOS) — guarded. Status banner: amber title on cream ≈2.5:1 → `warnInk`; *Enable* button no longer squeezes the text (moved below). |
| My lost phone (`my_lost_phone`) | 8.5 → 9 | Error state verified (honest retry). Now also rendered with realistic data in the harness. |
| Recovery help (`recovery`) | 9 → 9 | No change needed. |
| Phone safety check-up (`phone_safety`) | 8 → 9 | "What really protects your phone" was one wall of text — split into spaced paragraphs, line-height 1.45. |
| Phone ownership protection (`security_hub`) | 9 → 9 | Data state now rendered (harness fake for `/security/state`); no change needed. |
| Family care — data (`family`) | 7.5 → 9 | Mixed digits in Bangla ("১টা … আর 3 দিনের", "08:00", "14:30:00") → Bangla digits; PRN time showed seconds → HH:MM; adherence % localized. Tab bar started with an odd 52px indent → `TabAlignment.start`. |
| Family care — empty (`family_empty`) | 8 → 9 | Empty state had no way forward → "Medicines" button opens the Medicines tab. |
| Family care — error (`family_error`) | 4 → 9 | **A failed load showed "No medicine doses today"** (misleading on a care screen) → honest error + Retry. Raw exception no longer shown in export-failed snackbar. |
| Login (`login`) | 9 → 9 | — |
| Language picker (`language_picker`) | 9 → 9 | — |
| Onboarding (`onboarding`) | 7.5 → 9 | Language tiles both said "Choose your language" as subtitle → title is the language's own name, subtitle its name in the UI language (hidden when identical). Skip button no longer touches the screen edge (RTL-safe padding). |
| Settings (`settings`) | 8 → 9 | Language cards: "English" ran into the radio at 1.5× → scales to fit + gap; duplicate sub-label ("English / English") hidden. Theme tile label ellipsized ("ডিফল্ট (ফোন অ…") → 3 lines. Grey notes → `onSurfaceVariant`. Export-failed snackbar no longer prints the raw exception. |
| Accessibility mode (`accessibility`) | 8.5 → 9 | "100%" in Latin digits in Bangla → localized. |
| Battery guidance (`battery_guidance`) | 9 → 9 | — (English menu names are deliberate: they match the phone's menus). |
| About (`about`) | 8.5 → 9 | Values floated mid-row (Spacer+Flexible 50/50 split) → flush right. |
| Delete account (`delete_account`) | 5 → 9 | **Raw exception + URL shown to users** ("ClientException … uri=https://…") → friendly text (server message when it has one). When the preview failed it still said "There's no stored data to delete" — now hidden until we actually know. Amber nudge text → `warnInk`. |

### Shared / app-wide changes (small, additive)
- `theme.dart`: `Brand.warnInk(context)` (readable warning ink in light AND dark). No palette change.
- `widgets/adaptive_button_pair.dart`: equal button pair that stacks above 1.15× text.
- New ARB file `app/up_a6qa_arb.json` (2 keys: `qaLoadFailedRetry`, `qaActionFailed`).

### Not fixed here (needs the integrator / owner)
- **Bangla brand spelling is inconsistent**: 42 bn strings write the brand as "অ্যাসিস্টো", the rest as "Assisto" (e.g. Lost/Stolen, Phone safety). `arb_apply` refuses to change existing values, so this needs a direct ARB edit — recommend "Assisto" everywhere.
- The **Emergency info card** stays white in dark mode on purpose (it is shown to responders / printed).

## Batch 2 — My Circle (messenger, chats, calls UI) — next
