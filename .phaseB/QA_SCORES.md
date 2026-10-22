# Premium QA scores — every gallery screen (qa1, 22 Oct 2026)

Method: `app/test/screenshots_test.dart` gallery, 360x800, **bn + en x light + dark** (1,320 PNGs), every screen reviewed by eye as contact sheets (bn-light | en-dark, plus all four variants where a problem showed), then fixed, re-shot and re-reviewed. Large-font: the same gallery at text scale **1.3** and **2.0** — any RenderFlex overflow fails the test, so a passing run = no clipped/overflowing layout.

## Rubric (each screen 1-10)

| Area | 9-10 means |
|---|---|
| Layout & hierarchy | one clear primary action, aligned 8-pt spacing, nothing cramped or floating |
| Contrast (WCAG) | body text >= 4.5:1, large text/icons >= 3:1, in light AND dark |
| Clipping | no overflow, no '…' on text the user must read, no mid-word breaks — 360dp at 1.0/1.3/2.0 |
| Copy bn + en | natural Bangla (no English words/AM-PM/ISO dates/Latin digits in the Bangla UI), correct English plurals |
| States | empty / error / loading are honest, specific and offer the next step once (no duplicate CTA) |
| Brand | cyan->blue->purple accents, theme colours (no hard-coded greys that fail in dark) |
| Touch targets | >= 48dp for every tappable control |

Score guide: 10 = would ship at Apple/Google; 9 = premium, only nit-level notes; 8 = one visible flaw a user would notice; 7 = several flaws or one that hurts trust (wrong language, unreadable text); <=6 = broken.

## Summary

- Screens scored: **338** (shots; a few screens have several state shots)
- Average before: **8.72** -> after: **8.98**
- Below 9 before: **78** -> after: **8**
- Not scored as final (other agents are changing them): My Circle chat attach/media (agent md1), wake word / voice (k1 / ww2) — listed with their current score, not changed here.
- Home screen: frozen (owner rule) — scored, never changed.

## App-wide fixes (each one fixed many screens at once)

| Fix | Where | Effect |
|---|---|---|
| Bangla AM/PM | `widgets/bn_day_periods.dart` (delegate in `main.dart`) | CLDR's Bangla date data printed a Latin "AM/PM" after Bangla digits in every `jm()` time; now পূর্বাহ্ণ / অপরাহ্ণ app-wide |
| Display dates follow the UI language | 40+ display `DateFormat(...)` calls (reminders, notes, calendar, money, loans, exam, safety, arrival, credits, notifications, watch feed, daily brief, khata, shop EOD, CRM) | no more "14 Oct, 10:00 AM" / ISO "2026-10-22" in the Bangla UI (API date keys untouched) |
| Destructive buttons | `Brand.dangerButton()` (18 files) + theme `error`/`onError` | white on deeper red 5.6:1 in both themes (dark mode drew dark text on red, ~2:1) |
| Positive buttons | `Brand.successButton()` (cash in, accept, call again) | white on green was 3.4:1 -> 5.3:1 |
| Tinted chips/badges | `Brand.onTint()` (status chips, VIP, vault expiry, disaster pills, report values, health-tip source) | amber/orange/teal text on its own tint was 2-3:1 -> AA |
| Business amounts in Bangla digits | `takaIn()` (26 places) + server pair strings | every ৳ amount in the business module was Latin in the Bangla UI |
| One CTA in empty states | supplier, price radar, star deals, vouchers, letters | the same "Add" action appeared twice (CTA + FAB) |
| StateMessage scrolls | `widgets/skeleton.dart` | empty/error states overflowed at large font |

## Large font (text scale 1.3 and 2.0, 360 dp)

- **2.0x: 1,320 / 1,320 shots pass** (was 25 screens overflowing: credits, CRM today, daily brief,
  disaster alerts, landlord, memory, nominee, owner analytics, payment ladder, referral, server address,
  product sheet, Shop Box camera sheet, Unseen BD, Car Mode, fleet, watch feed, app update,
  loan detail, money trends, reminders, shortcut picker sheet).
- **1.3x: 1,316 / 1,320 pass.** The 4 failures are `photo_studio_free_enhanced` and `photo_studio_refusal`
  (bn): not an overflow — a Flutter semantics assertion ("invisible SemanticsNode") in the before/after
  compare overlay. It reproduces with this branch's Photo Studio edits reverted; not proven against
  origin/main. Photo Studio owner (ps1) should look.
- The test harness font has no glyph for a few symbols (an arrow "→" renders as a box, some place-detail
  text in `unseen` renders as bars) — test-font only, not app bugs.

## Bug found by the reality audit (not visible in any screenshot)

`POST /reminders/` answered **400** for every one-off reminder created by the natural-language quick add
(and voice): the app sent `"recurrence_rule": null`, the model field is a non-null JSON dict. The reminder
never reached the server and the offline queue retried it on every launch. Fixed on both sides
(`backend/core/serializers.py` accepts null -> `{}`; the app sends `{}`), test
`backend/core/tests_qa1_reminders.py`.

## Still below 9 (and why)

| Screen | Score | Why it is not fixed here |
|---|---|---|
| `c1_contacts_synced` | 8 | per-row action buttons wrap onto separate lines in bn (Message / Requested stacked) - uneven rhythm  |
| `c3_e2_chat_unread` *(in progress — md1 / k1 / ww2)* | 8 | can't-decrypt bubble is a heavy saturated red in dark mode (md1/c3 area, not changed)  |
| `discover_edit` | 8 | owner-only: bn helper quotes English chip names ("Sponsored"); segment label wraps (owner screen, left)  |
| `discover_report` | 8 | owner-only report table: ISO dates + Latin digits in bn (left: owner data table)  |
| `home_chat_restored` *(home — frozen)* | 8 | HOME (frozen, not changed): restored reminder card shows "2026-10-21 09:00" (card subtitle from the server)  |
| `ramadan` | 8 | day numbers grey.shade700 on dark ~2.8:1, 11-12px Colors.grey hints 2.7:1 on light (7 Ramadan widgets) -> FIXED (onSurfaceVariant); REMAINS: day tiles are 36dp (<48dp) — a 7-column 30-day grid cannot fit 48dp at 360dp width  |
| `t1_date_floating` *(in progress — md1 / k1 / ww2)* | 8 | floating date pill overlaps the static separator under the header (two pills stacked at top) — My Circle chat (md1 area, not changed)  |
| `voice_results` *(in progress — md1 / k1 / ww2)* | 8 | bn "আগামীকাল 5:00" — gallery fixture passes a literal '5:00' (voice area; not changed while k1/ww2 are on voice)  |

## Every screen

| Screen (shot) | Before | After | Issues found -> what was done |
|---|---|---|---|
| `about` | 9 | 9 | — |
| `action_center` | 9 | 9 | error state (gallery has no data stub) |
| `admin_mod` | 9 | 9 | error state only in gallery |
| `admin_users` | 9 | 9 | error state only in gallery |
| `agent_studio` | 9 | 9 | — |
| `ai_chat` | 9 | 9 | — |
| `ai_knowledge` | 9 | 9 | — |
| `app_update` | 9 | 9 | — |
| `area` | 9 | 9 | — |
| `assisto_chats` | 9 | 9 | — |
| `assisto_chats_empty` | 9 | 9 | — |
| `at_protection_off` | 9 | 9 | — |
| `at_protection_on` | 9 | 9 | — |
| `at_timeline` | 8 | 9 | bn times show English "PM" (CLDR bn AM/PM) -> FIX global -> FIXED globally: Bangla day periods (পূর্বাহ্ণ/অপরাহ্ণ) via BnDayPeriods; re-shot |
| `battery_guidance` | 9 | 9 | English menu names quoted on purpose (they are the phone's labels) |
| `birthdays` | 8 | 9 | subtitle squeezed by 3 icon buttons: "৫৬ / বছর হচ্ছে" wraps awkwardly -> FIXED: edit + delete moved into one overflow menu, subtitle reads on one line |
| `biz_cashbox` | 7 | 9 | Cash-in green FilledButton white text 3.4:1 (fail AA); date shown as ISO 2026-10-22 in both langs -> FIXED (successFill + localized date) -> FIXED: green/red buttons AA, localized date, and the server's amounts now in Bangla digits (business pair() pass) |
| `biz_customers` | 8 | 9 | VIP badge amber-on-amber 10px low contrast -> FIXED (ink colour, 11px) -> FIXED: VIP badge contrast + Bangla digits |
| `biz_hub` | 9 | 9 | — |
| `biz_khata` | 8 | 9 | server-formatted amounts showed Latin digits in bn -> FIXED: khata amounts (server-formatted) in Bangla digits in the Bangla UI |
| `biz_khata_error` | 9 | 9 | — |
| `biz_order_detail` | 7 | 9 | status chip amber-on-tint ~2:1; en "order received" lowercase in a chip -> FIXED (Brand.ink chips, sentence case) -> FIXED: same |
| `biz_orders` | 7 | 9 | same chips -> FIXED -> FIXED: readable status chips, sentence case, Bangla digits for totals |
| `biz_orders_error` | 9 | 9 | — |
| `biz_payments` | 9 | 9 | — |
| `biz_products` | 8 | 9 | en "2 Variant"/"1 Variant" (no plural), Latin digit in bn tag -> FIXED (plural ARB + locale digits) -> FIXED: plural "2 variants", Bangla digits incl. all business amounts |
| `biz_products_empty` | 9 | 9 | — |
| `biz_quick_sell` | 9 | 9 | — -> FIXED: every business amount now in Bangla digits in the Bangla UI (fmtTaka -> takaIn, 26 places in 6 files) |
| `biz_reports` | 8 | 9 | amber "Expenses" value on light card ~2:1 -> FIXED (Brand.ink) -> FIXED: readable amber value, Bangla digits |
| `biz_reports_loading` | 9 | 9 | — |
| `blog` | 9 | 9 | — |
| `blood` | 9 | 9 | — |
| `business` | 9 | 9 | (same screen as biz_hub) |
| `c1_contacts_disclosure` | 9 | 9 | — |
| `c1_contacts_synced` | 8 | 8 | per-row action buttons wrap onto separate lines in bn (Message / Requested stacked) - uneven rhythm |
| `c2_call_busy` | 8 | 9 | "Call again" white on success green 3.4:1 -> FIXED (successButton) |
| `c2_call_calling` | 9 | 9 | — |
| `c2_call_connected_voice` | 9 | 9 | — |
| `c2_call_connecting` | 9 | 9 | — |
| `c2_call_declined` | 8 | 9 | same Call again -> FIXED |
| `c2_call_failed` | 8 | 9 | Call again contrast -> FIXED |
| `c2_call_incoming_video` | 9 | 9 | — |
| `c2_call_no_answer` | 8 | 9 | Call again contrast -> FIXED |
| `c2_call_offline` | 8 | 9 | Call again contrast -> FIXED |
| `c2_call_permission` | 8 | 9 | Call again contrast -> FIXED; light-theme tonal "Open settings" on the always-dark call screen (bn light) |
| `c2_call_reconnecting` | 9 | 9 | — |
| `c2_call_ringing_no_relay` | 9 | 9 | — |
| `c2_call_video_connected` | 9 | 9 | — |
| `c2_call_video_remote_cam_off` | 9 | 9 | — |
| `c3_chat` *(in progress — md1 / k1 / ww2)* | 9 | 9 | (emoji boxes = test font only). My Circle chat: md1 area, scored, not changed |
| `c3_chat_list` | 9 | 9 | gallery fixture had a hard-coded English "My Circle" title (fixture fixed; app uses ARB) |
| `c3_e2_chat_unread` *(in progress — md1 / k1 / ww2)* | 8 | 8 | can't-decrypt bubble is a heavy saturated red in dark mode (md1/c3 area, not changed) |
| `c3_msg_info` | 9 | 9 | — |
| `c3_notif_settings` | 9 | 9 | — |
| `c3_x2_contact_info` | 9 | 9 | — |
| `c3_x2_msg_info_off` | 9 | 9 | — |
| `cam_perm_ask` | 9 | 9 | — |
| `cam_perm_denied` | 9 | 9 | — |
| `challenges` | 9 | 9 | — |
| `chat` | 9 | 9 | — |
| `chat_photo_face_refused` | 8 | 9 | gallery fed an English server message into the Bangla shot (server localizes) -> fixture fixed (fixture now feeds the server's real Bangla text; re-shot) |
| `chat_photo_free_credits_only` | 7 | 9 | ML Kit labels ("Paper/Text/Box") are English-only chips inside the Bangla card -> FIXED (labels only in English UI); fixture English server text -> fixed |
| `chat_photo_free_ondevice` | 7 | 9 | same English label chips in Bangla -> FIXED |
| `chat_photo_free_unavailable` | 9 | 9 | — |
| `chat_photo_needs_key` | 9 | 9 | fixture English server text in bn -> fixed (server's own bn text still says "ভিশন key" — owner-facing) |
| `chat_photo_premium_done` | 9 | 9 | (answer text is fixture English) |
| `chat_voice` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `circle` | 9 | 9 | — |
| `circle_call_history` | 8 | 9 | duration "01:05" Latin digits next to Bangla-digit time -> FIXED |
| `circle_chat` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `circle_chat_menu` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `circle_privacy` | 9 | 9 | — |
| `circle_search` | 9 | 9 | — |
| `connected_apps` | 9 | 9 | minor: "AI" in Latin where other bn screens write এআই |
| `contact_info` | 9 | 9 | — |
| `contacts` | 9 | 9 | — |
| `contract` | 9 | 9 | — |
| `cost_est` | 9 | 9 | — |
| `cost_flags` | 9 | 9 | error state only in gallery |
| `credits_nopay` | 7 | 9 | "This month by feature" showed raw server code "ai_chat"; the real server codes (ai_msg_cheap/strong, photo:*, vision:chat, scan_ocr, shop_extra_camera) had no label -> FIXED (6 new ARB labels, unknown -> "Other") |
| `credits_paylive` | 7 | 9 | same -> FIXED |
| `crm_companies` | 9 | 9 | — |
| `crm_contacts` | 9 | 9 | — |
| `crm_dashboard` | 9 | 9 | — |
| `crm_firstrun` | 8 | 9 | bn segment "নিজের CRM শুরু করুন" wraps to 2 lines inside the segmented button -> FIXED (short label) |
| `crm_firstrun_join` | 8 | 9 | same -> FIXED |
| `crm_home` | 8 | 9 | dates as ISO "2026-10-13" in both languages -> FIXED (crmDate) |
| `crm_lead_detail` | 7 | 9 | score reason shows the raw formula "industry_fit=25 + company_size=25 + buying_signals=50 = 95" (internal keys, English in bn); ISO dates -> FIXED (localized words + dates) |
| `crm_lead_full` | 7 | 9 | same as crm_lead_detail -> FIXED |
| `crm_leads` | 9 | 9 | — |
| `crm_leads_empty` | 9 | 9 | — |
| `crm_pipeline` | 8 | 9 | close dates ISO -> FIXED |
| `crm_proposal` | 9 | 9 | — |
| `crm_reports` | 9 | 9 | minor: "66.7%" keeps Latin digits in bn |
| `crm_team` | 9 | 9 | — |
| `crm_today` | 8 | 9 | ISO dates -> FIXED |
| `cv_builder` | 9 | 9 | — |
| `daily_brief` | 7 | 9 | Bangla UI showed "Thu, Oct 22, 2026" and "08:00" (formatter had no locale) -> FIXED; also 23 more display-only DateFormat calls across reminders/notes/calendar/safety/arrival/credits/notifications got the UI locale (they printed English month names in bn) |
| `demand` | 9 | 9 | — |
| `dialog_sale_void` | 9 | 9 | — |
| `dictionary` | 9 | 9 | — |
| `disaster_alerts` | 7 | 9 | filled severity pills: white text on amber/orange ~2-3:1; tinted pills amber-on-amber -> FIXED (readable ink) |
| `discover_edit` | 8 | 8 | owner-only: bn helper quotes English chip names ("Sponsored"); segment label wraps (owner screen, left) |
| `discover_mgr` | 9 | 9 | — |
| `discover_report` | 8 | 8 | owner-only report table: ISO dates + Latin digits in bn (left: owner data table) |
| `dl1_delete_pending` | 8 | 9 | bn "১০:০০ AM" -> FIXED globally (BnDayPeriods) |
| `dl1_delete_preview_bottom` | 7 | 9 | preview item names were English internal names in the Bangla UI; red Continue had dark text on red in dark mode -> FIXED |
| `dl1_grace` | 9 | 9 | — |
| `dl1_grace_fresh` | 9 | 9 | — |
| `doc_scan` | 9 | 9 | — |
| `doctor` | 9 | 9 | — |
| `drawer` | 9 | 9 | — |
| `drawer_bottom` | 9 | 9 | — |
| `elderly_home` | 9 | 9 | — |
| `emergency` | 9 | 9 | — |
| `enc_backup` | 9 | 9 | — |
| `exam` | 9 | 9 | — |
| `expense_split` | 9 | 9 | — |
| `family` | 9 | 9 | — |
| `farmer` | 8 | 9 | dark mode: white "Add crop" on light green 2.5:1 -> FIXED (dark ink) |
| `fb_screen` | 9 | 9 | minor: "Screen: home" shows the raw route name (it is literally what is sent) |
| `fb_sheet` | 9 | 9 | — |
| `fb_sheet_error` | 9 | 9 | — |
| `finance` | 9 | 9 | — |
| `fitness` | 9 | 9 | — |
| `fm_msgr_profile` | 9 | 9 | — |
| `fm_msgr_settings` | 9 | 9 | — |
| `fm_settings` | 9 | 9 | — |
| `guide` | 9 | 9 | — |
| `health_tips` | 8 | 9 | 11px teal "Source: WHO" line 2.8:1 on the light card -> FIXED |
| `health_tl` | 9 | 9 | — |
| `home_chat_restored` *(home — frozen)* | 8 | 8 | HOME (frozen, not changed): restored reminder card shows "2026-10-21 09:00" (card subtitle from the server) |
| `home_hero_ad_free` *(home — frozen)* | 9 | 9 | HOME (frozen) |
| `home_hero_premium` *(home — frozen)* | 9 | 9 | HOME (frozen) |
| `home_top` *(home — frozen)* | 9 | 9 | HOME (frozen) |
| `home_welcome` *(home — frozen)* | 9 | 9 | HOME (frozen) |
| `in_progress` | 7 | 9 | Bangla UI: "14 Oct, 10:00 AM" (formatter without locale) -> FIXED (2nd pass: 14 more display formatters incl. money, loans, exam, calendar, watch feed, action cards) |
| `inbox` | 9 | 9 | — |
| `incoming_call` | 9 | 9 | — |
| `jobs` | 8 | 9 | salaries "45000" without separators / Latin digits in bn -> FIXED |
| `journey_fake_call` | 9 | 9 | — |
| `journey_live` | 9 | 9 | — |
| `journey_settings` | 9 | 9 | — |
| `journey_sos` | 9 | 9 | — |
| `journey_start` | 9 | 9 | — |
| `kid` | 9 | 9 | — |
| `landlord` | 9 | 9 | — |
| `lang_partner` | 9 | 9 | — |
| `language_picker` | 9 | 9 | — |
| `legal` | 9 | 9 | en caption is ALL CAPS "DRAFT — TO REVIEW BY OWNER" (honest draft marker; owner to finalize policies) |
| `login` | 9 | 9 | — |
| `m3_add_circle` | 9 | 9 | — |
| `m3_add_found` | 9 | 9 | — |
| `m3_add_notfound` | 9 | 9 | — |
| `m3_new_chat` | 9 | 9 | — |
| `m3_requests` | 9 | 9 | — |
| `medicine_db` | 9 | 9 | — |
| `medicine_history` | 9 | 9 | — |
| `meetings` | 9 | 9 | bn "১০:০০ AM" -> FIXED globally (BnDayPeriods) |
| `memory` | 9 | 9 | — |
| `mess_acct` | 9 | 9 | — |
| `messenger` | 9 | 9 | (bn shot caught the loading spinner; en shows the empty state) |
| `messenger_menu` | 9 | 9 | — |
| `messenger_settings` | 9 | 9 | — |
| `meter` | 9 | 9 | — |
| `mock_iv` | 9 | 9 | — |
| `money` | 9 | 9 | en: 5 tabs squeezed ("Loans and Savings" on 2 lines, by design at 1.0x; scrolls at large font). Gallery: net-worth pill is 0 because the fixture seeds no local accounts |
| `money_budget` | 9 | 9 | — |
| `money_import` | 9 | 9 | — |
| `money_loan_detail` | 9 | 9 | — 2.0x: trailing amount scales instead of overflowing |
| `money_networth` | 8 | 9 | months as ISO "2026-10" -> FIXED (localized month) |
| `money_report` | 8 | 9 | "Report for 2026-10", "2026-10-05" -> FIXED |
| `money_tax` | 9 | 9 | — |
| `money_trends` | 8 | 9 | axis "08 09 10" (bare month numbers, Latin in bn) -> FIXED (Oct / Bangla month) -> FIXED: localized month axis; 2.0x trailing amount scales instead of overflowing |
| `money_voice` | 9 | 9 | — |
| `money_wrapped` | 9 | 9 | — |
| `money_wrapped_data` | 9 | 9 | — |
| `money_wrapped_thin` | 8 | 9 | bn "5টি ... 2টি" Latin digits -> FIXED |
| `mood` | 9 | 9 | — |
| `mr1_last_seen_12h` | 9 | 9 | — |
| `mr1_last_seen_24h` | 9 | 9 | — |
| `mr1_request_chat` | 9 | 9 | — |
| `mr1_requests_list` | 9 | 9 | — |
| `mr1_sender_limit` | 9 | 9 | — |
| `mr1_sender_waiting` | 9 | 9 | — |
| `msg_privacy` | 7 | 9 | bn hint under "Hide my number" cut with "…" at 3 lines (clipped explanatory text) -> FIXED (no line cap) -> FIXED: no line caps on the explanations (two bn hints were cut) |
| `msgr_profile` | 9 | 9 | — |
| `name_about` | 9 | 9 | — |
| `nearby` | 9 | 9 | — |
| `nominee` | 9 | 9 | — |
| `notes_tasks` | 9 | 9 | — |
| `notification_centre` | 9 | 9 | — |
| `oem_guide_oppo_bottom` | 9 | 9 | English menu names quoted on purpose (they are what the phone shows) |
| `oem_guide_samsung_bottom` | 9 | 9 | — |
| `oem_guide_samsung_done` | 9 | 9 | — |
| `oem_guide_vivo_bottom` | 9 | 9 | — |
| `oem_guide_walton_allset` | 9 | 9 | — |
| `oem_guide_xiaomi_bottom` | 9 | 9 | — |
| `offline_status` | 9 | 9 | minor: byte unit "B" stays Latin in bn |
| `onboarding` | 9 | 9 | — |
| `otp_login` | 9 | 9 | — |
| `otp_reset` | 9 | 9 | — |
| `otp_sms_off` | 9 | 9 | — |
| `otp_verify` | 8 | 9 | bn countdown "60 সেকেন্ড" Latin digits -> FIXED |
| `owner_analytics` | 9 | 9 | — |
| `pa_delegate` | 9 | 9 | — |
| `pa_hub` | 9 | 9 | — |
| `pa_letters` | 9 | 9 | — |
| `pa_liaison` | 9 | 9 | — |
| `pa_schedule` | 9 | 9 | — |
| `pa_star_deals` | 9 | 9 | — |
| `pa_tasks` | 9 | 9 | — |
| `pa_vip` | 9 | 9 | — |
| `pa_visitor` | 9 | 9 | — |
| `pa_voucher` | 9 | 9 | — |
| `password_reset` | 9 | 9 | — |
| `password_reset_sms` | 9 | 9 | — |
| `pay_sheet_apk` | 8 | 9 | bn price "৳199" Latin digits -> FIXED (all checkout prices) |
| `pay_sheet_not_ready` | 8 | 9 | bn price digits -> FIXED |
| `pay_sheet_pack` | 8 | 9 | bn "55 ক্রেডিট · ৳50" Latin digits -> FIXED |
| `pay_sheet_play` | 8 | 9 | price digits -> FIXED |
| `pay_sheet_play_gw_off` | 8 | 9 | price digits -> FIXED |
| `payment_ladder` | 9 | 9 | — |
| `photo_studio_ai_download` | 9 | 9 | — |
| `photo_studio_ai_downloading` | 9 | 9 | — |
| `photo_studio_ai_fellback` | 9 | 9 | — |
| `photo_studio_ai_used` | 9 | 9 | — |
| `photo_studio_free_empty` | 8 | 9 | en "Watch 1 short ads" (no plural) -> FIXED |
| `photo_studio_free_enhanced` | 9 | 9 | — |
| `photo_studio_free_enhanced_bottom` | 9 | 9 | — |
| `photo_studio_gate` | 9 | 9 | — |
| `photo_studio_gate_credits_only` | 9 | 9 | — |
| `photo_studio_gate_nofill` | 8 | 9 | en "Watch 1 short ads first" -> FIXED |
| `photo_studio_nokey_owner` | 9 | 9 | owner-only note; the box between "Admin" and "Integrations" is an arrow glyph missing from the TEST font only |
| `photo_studio_nokey_user` | 9 | 9 | — |
| `photo_studio_premium` | 9 | 9 | — |
| `photo_studio_refusal` | 9 | 9 | — |
| `plans` | 8 | 9 | bn prices "৳199" Latin digits -> FIXED; REMAINS (owner): the Premium hero says "Unlimited AI" while the card right below says "Nothing is unlimited" + "Monthly allowance: 90 credits" — server plan config (plans.py unlimited_ai=True) vs credit policy; owner must pick one -> FIXED: prices in Bangla digits; "Nothing is unlimited" card hidden when the server says this plan IS unlimited (no more self-contradiction). Owner still decides the policy (see report) |
| `plans_nopay_bottom` | 8 | 9 | same contradiction (owner); prices fixed -> FIXED (same) |
| `plans_paylive_bottom` | 8 | 9 | same contradiction (owner); prices fixed -> FIXED (same) |
| `price_radar` | 9 | 9 | — |
| `proactive` | 9 | 9 | — |
| `probashi` | 9 | 9 | — |
| `push_settings` | 9 | 9 | — |
| `quick_grid` *(home — frozen)* | 9 | 9 | HOME widget (frozen) |
| `quick_grid_owner` *(home — frozen)* | 9 | 9 | HOME widget (frozen) |
| `quick_picker` | 9 | 9 | — |
| `quick_tools` | 9 | 9 | — |
| `qurbani` | 9 | 9 | — |
| `ramadan` | 8 | 8 | day numbers grey.shade700 on dark ~2.8:1, 11-12px Colors.grey hints 2.7:1 on light (7 Ramadan widgets) -> FIXED (onSurfaceVariant); REMAINS: day tiles are 36dp (<48dp) — a 7-column 30-day grid cannot fit 48dp at 360dp width |
| `referral` | 8 | 9 | bn achievement card numbers in Latin digits -> FIXED |
| `reminders` | 8 | 9 | bn dates "14 Oct, 10:00 AM" (no locale) -> FIXED |
| `ride_food` | 9 | 9 | — |
| `safe_arrival` | 9 | 9 | — |
| `safety` | 8 | 9 | bn "SOS কাউন্টডাউন: 5 সেকেন্ড" Latin digit (also journey settings + dialog) -> FIXED |
| `samity` | 9 | 9 | — |
| `saved` | 9 | 9 | — |
| `savings` | 9 | 9 | — |
| `scam` | 9 | 9 | — |
| `security` | 9 | 9 | — |
| `server_addr` | 9 | 9 | owner-only; en "Test connection" wraps in its button (fine) |
| `settings` | 9 | 9 | — |
| `settings_voice` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `sheet_customer_edit` | 9 | 9 | — |
| `sheet_customer_new` | 9 | 9 | — |
| `sheet_khata_due` | 8 | 9 | date "2026-10-22" ISO in both languages -> FIXED |
| `sheet_khata_payment` | 8 | 9 | ISO date -> FIXED |
| `sheet_product_edit` | 9 | 9 | — |
| `sheet_product_new` | 9 | 9 | — |
| `sheet_product_staff` | 9 | 9 | — |
| `shop_alerts` | 8 | 9 | bn "৫:৪৩ PM" -> FIXED (BnDayPeriods); amber "Open" chip -> FIXED (onTint chips) |
| `shop_box` | 9 | 9 | — |
| `shop_cam_settings` | 7 | 9 | sheet title cut to "Camera…" by the "Offline since …" pill on the same row -> FIXED (stacked) |
| `shop_cameras` | 9 | 9 | — |
| `shop_eod` | 8 | 9 | recent checks dated ISO "2026-10-20" -> FIXED |
| `shop_live_offline` | 9 | 9 | — |
| `shop_mode_pair` | 9 | 9 | (arrow glyph box = test font only) |
| `shop_mode_paired` | 9 | 9 | — |
| `shop_report` | 9 | 9 | — |
| `smartwatch` | 9 | 9 | — |
| `social` | 9 | 9 | — |
| `spending` | 7 | 9 | bn: every amount/percentage Latin ("৳130.00", "69%") from the insight engine -> FIXED (locale digits on display); FAB overlaps the last category amount while scrolled (list has 96px bottom padding; ok at rest) |
| `staff` | 9 | 9 | — |
| `student` | 9 | 9 | — |
| `subscriptions` | 9 | 9 | — |
| `subscriptions_empty` | 9 | 9 | — |
| `subscriptions_error` | 9 | 9 | — |
| `subscriptions_loading` | 9 | 9 | — |
| `supplier` | 8 | 9 | empty state shows the same "Add supplier" action twice (CTA + FAB) -> FIXED (FAB hidden when empty); same fix: price_radar, pa_star_deals, pa_voucher, pa_letters |
| `support` | 9 | 9 | — |
| `support_center` | 9 | 9 | — |
| `t1_date_floating` *(in progress — md1 / k1 / ww2)* | 8 | 8 | floating date pill overlaps the static separator under the header (two pills stacked at top) — My Circle chat (md1 area, not changed) |
| `t1_date_separators` | 9 | 9 | — |
| `t1_headers` | 9 | 9 | — |
| `t1_msg_info_legacy` | 9 | 9 | — |
| `t1_msg_info_real` | 9 | 9 | — |
| `t1_update_screen` | 9 | 9 | — |
| `t1_version_banners` | 9 | 9 | — |
| `task_mgr` | 9 | 9 | — |
| `transcribe` | 9 | 9 | — |
| `travel` | 9 | 9 | — |
| `trust` | 9 | 9 | — |
| `unseen` | 9 | 9 | (black bars = place-detail text in a font the TEST harness does not load; real device renders it) |
| `used_phone_check` | 9 | 9 | (arrow glyph box = test font only) |
| `vault` | 8 | 9 | orange "expires in 13 days" chip 11px on its own tint ~2.5:1 -> FIXED (onTint) |
| `vault_empty` | 9 | 9 | — |
| `vault_error` | 9 | 9 | — |
| `veh_car_mode` | 9 | 9 | — |
| `veh_fleet` | 9 | 9 | — |
| `veh_fleet_locked` | 9 | 9 | — |
| `veh_obd_bottom` | 9 | 9 | — |
| `veh_pair_sheet` | 8 | 9 | bn segment "নিজে বুঝে নিক" wraps to 2 lines -> FIXED (স্বয়ংক্রিয়) |
| `veh_settings_bottom` | 8 | 9 | bn night window "23:00 — 05:00" Latin digits -> FIXED |
| `veh_tracker` | 9 | 9 | — |
| `veh_tracker_bottom` | 8 | 9 | dark: red "Cut engine" with dark text on E0485A 3.2:1 (theme onError) -> FIXED at theme level (error/onError pair, both themes); bn "PM" -> FIXED globally |
| `veh_tracking` | 9 | 9 | bn "৮:৫২ PM" -> FIXED globally |
| `veh_tracking_empty` | 9 | 9 | — |
| `veh_tracking_error` | 9 | 9 | — |
| `vehicles` | 9 | 9 | — |
| `voice_assistant` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `voice_confirm` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `voice_listening` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `voice_onboarding` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `voice_results` *(in progress — md1 / k1 / ww2)* | 8 | 8 | bn "আগামীকাল 5:00" — gallery fixture passes a literal '5:00' (voice area; not changed while k1/ww2 are on voice) |
| `voice_settings` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `voice_settings_bottom` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `voice_sos_confirm` *(in progress — md1 / k1 / ww2)* | 9 | 9 | — |
| `watch_feed` | 8 | 9 | FAB "Watch a rate" / "রেট নজরে নিন" unclear -> FIXED ("Add rate alert" / "রেটের অ্যালার্ট যোগ করুন"); FAB covers the last row's "Open" while scrolled (bottom padding exists) |
| `web_photo_link_expired` | 9 | 9 | — |
| `web_photo_studio_free` | 9 | 9 | — |
| `web_photo_studio_premium` | 9 | 9 | — |
| `wedding` | 9 | 9 | — |
| `wellness` | 9 | 9 | — |
| `x1_call_connect_failed` | 8 | 9 | "Call again" white on 2E9E6B 3.4:1 -> FIXED (successButton) |
| `x1_call_connect_failed_callee` | 8 | 9 | same -> FIXED |
| `x1_call_incoming_photo` | 9 | 9 | — |
| `x1_call_photo_connected` | 8 | 9 | call timer "04:07" Latin digits in bn -> FIXED |
| `x1_call_photo_ringing` | 9 | 9 | — |

## Reality audit run 39859999833 (agent/qa1, real API-33 emulator, in-runner Django)

Screenshots are real device screens (`adb screencap`), artifact `reality-evidence` (14 days). A = works end-to-end; C = a step failed (an app bug OR a flow step that no longer matches the UI — each needs triage with its screenshot); D = did not run (the emulator died in the business group and was restarted for the next group). Every flow after 08 shows `POST /reminders/ 400`: that is the one-off reminder stuck in the offline queue, retried on every app start — the bug fixed on this branch (not yet in this run's build).

| id | feature | class | failed step / detail | http errors | shots |
|---|---|---|---|---|---|
| 01_language | Language picker (first run) | **A** |  |  | 3 |
| 02_login | Login (seeded phone + password) | **A** |  | POST /auth/login 401 | 2 |
| 03_onboarding | Onboarding (first login) | **A** |  |  | 5 |
| 04_home_chat | Home chat: send a message (saved on server) | **C** | type + send in the home chat: timed out after 15.0s waiting for my message bubble |  | 3 |
| 05_home_restore | Home chat restored after app restart | **C** | the last home conversation is shown again: message "Reality ping 70320" not restored after restart |  | 2 |
| 06_sidebar_history | Sidebar chat history | **C** | open the drawer; history lists the chat: app never called GET /chat/sessions |  | 2 |
| 07_quick_buttons | Edit the 6 home quick buttons (persists) | **C** | swap one shortcut and save: saved list did not change: [money, notes, ai_chat, family, documents, reminders] |  | 3 |
| 08_reminders | Reminders: quick-add + form, synced to server | **C** | natural-language quick add: backend never confirmed: reminder "Call Ammu tomorrow 9am r43762" on server | POST /reminders/ 400 | 4 |
| 09_notes | Notes: create, synced to server | **C** | add a note: timed out after 15.0s waiting for widget with type "FloatingActionButton" | POST /reminders/ 400 | 2 |
| 10_todos | To-dos: create + tick done, synced | **C** | open the To-do tab: timed out after 15.0s waiting for widget with text "To-Do" | POST /reminders/ 400 | 1 |
| 11_money | Money: add an expense, server balance moves | **C** | add a 75 taka expense: timed out after 15.0s waiting for widget with type "FloatingActionButton" | POST /reminders/ 400 | 2 |
| 12_budget | Budgets: add a category limit, synced | **C** | add a 3000 taka transport budget: timed out after 15.0s waiting for widget with type "FloatingActionButton" | POST /reminders/ 400 | 2 |
| 13_family | Family members (seeded) load from server | **C** | open Family: timed out after 15.0s waiting for seeded member "Ammu" | POST /reminders/ 400 | 2 |
| 14_sos_countdown | SOS: countdown shows, Cancel stops it (nothing sent) | **C** | open Emergency: app never called GET /emergency | POST /reminders/ 400 | 2 |
| 15_circle_message | My Circle: E2E message A->B and B->A between seeded users | **C** | A opens the chat and sends a message: timed out after 15.0s waiting for text field "Message" | POST /reminders/ 400 | 3 |
| 16_circle_call | My Circle: call screen opens and ends cleanly | **C** | hang up returns to the chat: Expected: exactly one matching candidate | POST /reminders/ 400, POST /circle/1/call 500 | 2 |
| 17_circle_add_whatsapp | My Circle like WhatsApp: add by number (any format), accept, | **C** | home chat "circle" opens My Circle add (was "no match"): timed out after 10.0s waiting for Add to My Circle screen | POST /reminders/ 400 | 1 |
| 19_circle_ticks | Ticks sent → delivered → read, typing/online in the header,  | **C** | B types → "typing…" in A's header; then "online": timed out after 15.0s waiting for typing… in the header | POST /reminders/ 400 | 4 |
| 18_circle_real_call | REAL calls: A->B voice connects (ICE), B->A video rings in-a | **C** | B video-calls A -> in-app incoming screen on A (no FCM): timed out after 20.0s waiting for incoming call screen on A | POST /reminders/ 400 | 5 |
| 21_documents | Documents vault: add a document record (server) | **C** | open the vault: app never called GET /documents | POST /reminders/ 400 | 2 |
| 22_voice_screen | Voice assistant screen opens; typed fallback answers | **A** |  | POST /reminders/ 400 | 1 |
| 23_settings_language | Settings: switch to Bangla and back; About shows version | **C** | About shows the version: timed out after 15.0s waiting for widget with text "About" | POST /reminders/ 400 | 3 |
| S001 | Reminders | **A** |  |  | 1 |
| S002 | Birthdays & memorable days | **A** |  |  | 1 |
| S003 | Meetings & appointments | **A** |  |  | 1 |
| S004 | Notes/Tasks | **A** |  |  | 1 |
| S005 | AI knows | **A** |  |  | 1 |
| 17_pos_sale_void | POS: sale -> receipt -> void (stock + receipt on server) | **D** | never ran (device/driver died first) |  | 0 |
| 18_khata | Khata: add a party (server ledger) | **D** | never ran (device/driver died first) |  | 0 |
| 19_crm_lead | CRM: create org (first run) + a lead | **D** | never ran (device/driver died first) |  | 0 |
| 20_shop_box | Shop Box: create site + camera, run end-of-day check | **D** | never ran (device/driver died first) |  | 0 |
