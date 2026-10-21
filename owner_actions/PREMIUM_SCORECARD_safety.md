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

## Batch 2 — My Circle (messenger, chats, calls UI) + incoming call (35 specs / 33 screens)

Shots: before `…/scratchpad/c1/` (sheets `csheets/`), after `…/scratchpad/c3/` (sheets `csheets3/`).
Run with `ASSISTO_QA_BATCH=2`. Layout-error report after fixes: **210/210 OK** (before: `msgr_set_chats` overflowed in 4 shots).
Harness now renders real soft shadows (`debugDisableShadows=false` per shot) — the hard black rings around FABs / hang-up buttons in the default test render were an artefact, not an app bug.

| Screen | Before → After | What was fixed |
|---|---|---|
| My Circle hub (`circle`) | 9 → 9 | — |
| My Circle — empty (`circle_empty`) | 9 → 9 | — |
| My Circle — error (`circle_error`) | 5 → 9 | A failed load said "Your circle is empty" → "Couldn't load" + Retry. |
| 1:1 chat (`circle_chat`) | 9 → 9 | Message bubble times now formatted in the app language (`circle_bubble.dart`). |
| Outgoing voice call (`circle_call_out`) | 7 → 9 | Transport banner always said "ringing arrives when push is enabled" even though FCM is integrated → now driven by `PushService.available` (+ TURN state). Control labels split mid-word ("Speake/r") at 1.5× → single words scale to fit. |
| Incoming video call screen (`circle_call_video_in`) | 7 → 9 | Same banner + labels. |
| Push ringing screen (`incoming_call`) | 8 → 9 | Decline/Accept clumped in the centre → each takes half the width (dialer layout). |
| Call history (`circle_call_history`) | 3 → 9 | **Every row showed "?" and no name**, and call-back had no member id: the backend `/circle/calls` sent no peer at all → now returns `name`, `member_id` (the viewer's own edge), `relation`, `custom_label` (+3 backend tests). Dates were always English ("Oct 10") → app language. |
| Privacy & controls (`circle_privacy`) | 7.5 → 9 | Audience segmented buttons: at 1.5× "My circle" wrapped and was clipped by the pill corner → full width, labels scale to one line. |
| Search (`circle_search`) | 9 → 9 | — |
| Groups list (`circle_groups`) | 8.5 → 9 | "4 জন সদস্য" Latin digit → Bangla digits. |
| Group chat (`circle_group_chat`) | 8.5 → 9 | Empty state was bare text → icon + text like 1:1 chat. |
| Group info (`circle_group_info`) | 8.5 → 9 | Member count + size limit in Bangla digits. |
| Status tray (`circle_status`) | 8 → 9 | "My status / Viewed by" read like a cut-off line → "Seen by N" when the server sends a count, nothing otherwise. |
| New status (`circle_status_new`) | 8.5 → 9 | "0/700" counter in Bangla digits. |
| Messenger home (`messenger`, `messenger_empty`) | 9 → 9 | — |
| Profile (`msgr_profile`) | 8 → 9 | Name/about counters in Bangla digits; name helper text was ellipsized at 1.5× → 2 lines. |
| Contacts on Assisto (`msgr_contacts`) | 9 → 9 | (brand spelling in bn handled by the integrator) |
| Contact info (`msgr_contact_info`) | 8.5 → 9 | Media/links/docs + starred counts in Bangla digits. |
| Discover (`msgr_discover`) | 9 → 9 | — |
| Connection requests (`msgr_requests`) | 8 → 9 | Bare-text empty state → icon + text. |
| Channels (`msgr_channels`) | 9 → 9 | — |
| Communities (`msgr_communities`) | 9 → 9 | — |
| Starred (`msgr_starred`) | 9 → 9 | Error state verified (honest retry). |
| Broadcast lists (`msgr_broadcasts`) | 7 → 9 | The info note at the bottom was **covered by the FAB** → moved to a header strip. |
| Linked devices (`msgr_linked_devices`) | 9 → 9 | — |
| Messenger settings (`msgr_settings`) | 9 → 9 | — |
| Account / Privacy / Notifications / Calls / Two-step (`msgr_set_*`) | 8 → 9 | Shared tile: titles were cut to one line ("Two-step verificati…", "Who can message …") at large font → 2 lines; subtitles 3 lines. |
| Chats settings (`msgr_set_chats`) | 6 → 9 | **Wallpaper row overflowed** (fixed 112px height; labels cut "Cyan to") → height grows with text size. Chat-theme segments "Syste m" → scale to one line. |
| Storage (`msgr_set_storage`) | 8.5 → 9 | Sizes ("0 MB") in Bangla digits. |

## gen-l10n argument-order bug — a6 call sites (from a1's finding)
gen-l10n orders a method's parameters by the ARB metadata placeholder order, not the text order. Fixed callers (ARB untouched), pinned by `app/test/arb_arg_order_a6_test.dart` (7 tests):

| Key | Signature | Was showing | Fix |
|---|---|---|---|
| `fallCountdownValue` | (seconds, minutes) | minutes ⇄ seconds swapped | `fall_detect_screen.dart` ×2 |
| `disFamilyInArea` | (area, kind, sev) | "Area — Flood: Severe" | `disaster_alerts_screen.dart` |
| `disShareHotlines` | (disaster, emergency) | hotlines swapped in the share text | `disaster_alerts_screen.dart` |
| `refCardCaption` | (days, friends) | "invited 30 friends … 3 Premium days" | `ref_achievement_card.dart` |
| `storageUsedOf` | (quota, used) | "5 GB of 1 GB" | `storage_meter.dart` |
| `adRewardedTodayCap` | (cap, done) | "5/2 today" | `rewarded_ad_sheet.dart` (verified on shot: "2/5 today") |
| `updateVersionLine` | (n = latest, v = current) | "latest • current" | `app_update_screen.dart` |
