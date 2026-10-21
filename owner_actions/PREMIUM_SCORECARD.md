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
| 11 | Medicine database (`medicine_db`) | 9 → 9 | — |
| 12 | Health tips (`health_tips`) | 9 → 9 | — |
| 13 | Documents / vault (`vault`) | 9 → 9 | — |
| 14 | Service guide (`guide`) | 8 → 9 | XL: portal domain broke mid-word ("nidw.gov.b d") → one line, scale-to-fit. |
| 15 | Nearby (`nearby`, new shot) | 8 → 9 | XL: "Direction s" mid-word break → button labels one line, scale-to-fit. |
| 16 | Unseen Bangladesh (`unseen`) | 7 → 9 | XL: card hero overflowed (fixed 72px) → min-height. |
| 17 | Dictionary (`dictionary`) | 8 → 9 | XL: segment label "স্বয়ংক্রি য়" broke mid-word → segments cap at 1.2x. Share text had detail/bn/en swapped (arg-order bug). |
| 18 | Ramadan (`ramadan`) | 6 → 9 | Fasting counter showed "30/0" instead of "0/30" (arg-order bug). Location banner used fixed dark-amber text, unreadable in dark mode → theme colours. |
| 19 | My Watch (`watch_feed`) | 7 → 9 | XL: "Take medicin e" (due chip squeezed the title) → chip moves under the title at large font. FAB covered the last card → bottom padding. |
| 20 | Exam result (`exam`) | 8 → 9 | XL: URL helper text cut off → wraps (3 lines). |
| 21 | Photo enhance (`photo_enhance`) | 9 → 9 | — |
| 22 | Ride & food (`ride_food`) | 6 → 9 | Screen stayed on grey skeletons until every app-install probe finished (sequential, no timeout; hangs forever if one never answers) → data shows at once, probes run in parallel with a 2 s timeout. Empty states now visible. |
| 23 | Used phone check (`used_phone_check`, new shot) | 8 → 8 | XL field labels ellipsize (full text is in the helper below). "→" renders as a box only in the test font. |
| 24 | My vehicles (`vehicles`, new shot) | 8 → 9 | Empty state showed "Add vehicle" twice (CTA + FAB) → FAB hidden when empty. |
| 25 | Student corner (`student`) | 8 → 9 | CGPA/course/credits lines had arguments swapped (arg-order bug). |
| 26 | Wedding & events (`wedding`) | 8 → 9 | "Estimated vs actual" swapped (arg-order bug). |
| 27 | Probashi corner (`probashi`) | 8 → 9 | Remittance rate/date swapped (arg-order bug). |
| 28 | Qurbani planner (`qurbani`) | 9 → 9 | — |
| 29 | Farmer mode (`farmer`) | 9 → 9 | — |
| 30 | Health timeline (`health_tl`) | 9 → 9 | — |
| 31 | Water, sleep & diet (`wellness`) | 7 → 9 | Glasses/hours value and goal were swapped, and so were the water and sleep averages (arg-order bug). |
| 32 | Fitness partner (`fitness`) | 9 → 9 | — |
| 33 | Smartwatch (`smartwatch`, new shot) | 9 → 9 | — |
| 34 | Daily challenge (`challenges`) | 9 → 9 | — |
| 35 | Contract analyzer (`contract`) | 9 → 9 | — |
| 36 | Language partner (`lang_partner`) | 9 → 9 | — |
| 37 | Daily brief (`daily_brief`) | 7 → 9 | Completion line showed "50 of 4 done (2%)" (arg-order bug). The bn "Night" tab label was cut at large font → tabs scroll. |
| 38 | Document scanner (`doc_scan`) | 9 → 9 | — |
| 39 | Calls & voice notes (`transcribe`) | 8 → 9 | Empty state showed "Add note" twice (CTA + FAB) → FAB hidden when empty. |
| 40 | Travel planner (`travel`) | 7 → 9 | Same duplicate CTA, plus itinerary summary and budget line swapped (arg-order bug). |
| 41 | Mood & energy (`mood`) | 7 → 9 | Energy showed "5 of 3" and the trend summary was swapped (arg-order bug). |
| 42 | Proactive helper (`proactive`) | 9 → 9 | — |
| 43 | Area community (`area`) | 8 → 9 | Empty board showed "Post a notice" twice → FAB hidden when empty. |
| 44 | Agent Studio (`agent_studio`) | 8 → 9 | XL: tab label cut → tabs scroll at large font. |
| 45 | Task manager (`task_mgr`) | 9 → 9 | — |
| 46 | Cost & time estimator (`cost_est`) | 7 → 9 | Qty / Unit cost / Min labels were cut to "প…/এ…/মি…" in three ~95px columns → the layout adapts (3 → 2+1 → stacked) to the space each label needs. |
| 47 | Mock interview (`mock_iv`) | 9 → 9 | — |
| 48 | Quick tools (`quick_tools`) | 9 → 9 | — |
| 49 | Blog & script (`blog`) | 9 → 9 | — |
| 50 | Job hunter (`jobs`) | 8 → 9 | bn "আবেদন ট্র্যাকার" tab was cut even at normal size → tabs scroll in bn and at large font. |
| 51 | CV builder (`cv_builder`) | 9 → 9 | — |
| 52 | AI inbox (`inbox`) | 9 → 9 | — |
| 53 | PA secretary hub (`pa_hub`) | 8 → 9 | The PA sub-screens' summaries and email templates had swapped values (arg-order bug: visitors, delegate audit, minutes, shoot checklist, biz travel, call/email templates). |

## Systemic bug: swapped values in 48 translated strings

gen-l10n orders a method's parameters by the ARB **metadata** placeholder order,
not by the order they appear in the text. 48 strings have those two orders
different, and almost every call site passed arguments in text order, so values
were silently swapped on screen. Examples: Ramadan "30/0", daily brief
"50 of 4 done (2%)", wellness glasses value/goal, mood energy "5 of 3", PA email
templates with subject and sender swapped.

- **Fixed in a1 scope (call sites now follow the signature):**
  - dictShareTemplate, ramadanFastingCount, paVisSummary, paAuditSummary;
  - studentCourseMath, studentCreditsSummary, studentFormulaBody;
  - weddingEstVsAct, probashiRateOnDate;
  - wellGlassesOf (2 sites), wellHoursOf, wellTrendAverages;
  - tvItinerarySummary, tvBudgetLine, dbCompletion;
  - paCeTpl* (4), paMinActionCount, shootChecklistProgress, paBizEstVsAct (2);
  - moodEnergyValue (2), moodTrendSummary.
- **Same bug, outside a1 scope. Owners must fix (the swap is visible today):**
  - a2 (money/business):
    - plMsgReceivable, plMsgPayable (payment_ladder)
    - splitPaidBySplit (expense_split)
    - samityRecordPayoutBody (samity)
    - rentStatusCounts, rentBillPaid (landlord_tenant)
    - staffDaysPresent (domestic_staff)
    - spendObs* (6 keys, spending_advice)
    - pnlRevCost, pnlBreakEvenBody (owner_pnl)
    - camSentPartial (camera_send_sheet)
  - a6 (safety/settings/ads):
    - fallCountdownValue (fall_detect: minutes and seconds swapped)
    - disFamilyInArea, disShareHotlines (disaster_alerts)
    - refCardCaption (ref_achievement_card)
    - storageUsedOf (storage_meter)
    - adRewardedTodayCap (rewarded_ad_sheet)
    - updateVersionLine (app_update: needs a check)
  - jobsSalaryRange is already correct.
- **Guard:** `app/test/arb_arg_order_test.dart` pins the fixed signatures and fails on
  any new key whose metadata order differs from its text order.

## Not covered by a1 (other slots or not in the gallery)
- Contacts (CRM contacts) → a2. The Family & Safety drawer section (incl. blood
  donor, doctor serial, kid school, disaster) → a6/a2 per the scope split.
- Test-font artifacts only: "→" and "৳" render as a box or "b" in the harness font
  (NotoSans without those glyphs); on a phone the system font has them.
