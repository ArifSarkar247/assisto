# f6-showpieces: existing ARB strings for the integrator

New keys: `.phaseB/up_f6_arb.json` (13 keys, en and bn). Apply them with `bin/arb_apply.py`.

The f6 Dart code no longer reads any of the existing keys below. They can stay in the ARB files, which is harmless, or the integrator can remove them. No existing value was edited.

| key | where it was used | why it is no longer shown |
|---|---|---|
| `msgrComingSoon` ("Preview") | messenger_home_screen `_placeholder` heading | It said "Preview" above an honest "keys being set up" waiting state |
| `channelsBackendSoon` ("Channels are in preview for now.") | channel_list / channel_detail / discover screens | Channels are live. A failed load now shows `honestFailText` / `checkInternetRetry` |
| `jobsConnectSourceBanner` ("Showing sample jobs…") | jobs_screen | The made-up sample jobs are hidden. The banner now uses `f6JobsNoFeedBanner` |
| `disFeedNoKeyBody` ("…The examples below are NOT live alerts…") | disaster_alerts_screen | The example warnings are hidden (`kShowSampleDisasterWarnings=false`). The banner now uses `f6DisFeedNoKeyBody`. The `disSample*` keys are also unused while that gate is off |
| `probashiDocsWelcomeBody`, `probashiDocsNote` ("Automatic reminders are not wired yet") | probashi_screen | Reminders are real now. Replaced by `f6ProbashiDocsWelcomeBody` / `f6ProbashiDocsNote` |
| `bizPlanPriceTbd` ("Pricing to be announced" / "মূল্য শীঘ্রই জানানো হবে") | business_ui, business_plans_screen | Prices are live on the Plans page. Replaced by `f6BizPlanPriceOnPlans` |
| `qtAiMarker` ("AI-generated…") | quick_tools_screen | The output comes from rules, not AI. Replaced by `f6QtRuleMarker` |
| `bwAiMarker` ("AI-generated draft…") | blog_writer_screen | The output is a template, not AI. Replaced by `f6BwTemplateMarker` |
| `examWatcherSavedLocal` ("Saved on this device") | exam_result_screen | This was shown when the save had FAILED. It now shows `saveFailed` |
| `ramadanWakeCallComing` | ramadan_screen | A "available when a partner is connected" line, which is a coming-soon line. Hidden while `_wakeIvrAvailable=false` |
| `upNeirNotAvailable`, `upTacUnavailable` | used_phone_check_screen | The "not available yet" cards are hidden (`kNeirCheckWired` / `kTacSourceWired`) |
| `msgNotifInAppNotYet`, `msgCommunityAlertsNotYet` | messenger notifications, community menu | The disabled "not yet" rows are hidden (`kInAppSoundBuilt` / `kCommunityAlertsBuilt`) |
| `crmReportUnavailable`, `crmReportUnavailableBooked`, `crmReportUnavailableRenewals` | crm_reports_screen | Panels with no data are hidden instead of showing "not served yet" |

Strings that are still shown and were checked as honest, with no change needed:
- `courierMockNote`: the shop's courier key is missing (bizagent G1 owns it).
- `psGateAdsNotLinked`: AdMob is not linked.
- `plansManageBody` / `plansFaqQRefundA`: billing provider.
- `nearbyMockBanner`: Google Maps key.
- `fallSensorGatedBody`: fall detection is reachable only by the internal CI tour.
- `dictionarySampleNote`: a small but real word list.
