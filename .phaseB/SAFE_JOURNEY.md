# SAFE JOURNEY & PERSONAL SAFETY — FULL SPEC (replaces earlier "SAFE JOURNEY")
Owner: women's safety at night + parents living alone = TOP priorities; must be the best safety feature in any app used in Bangladesh. UPGRADE the existing module-4b check-in (backend/core/logic/safety.py, app/lib/screens/safety_screen.dart, widgets safety_checkin_card.dart/safety_sos_countdown.dart). Benchmark CAPABILITY ONLY (never design/text) vs best personal-safety apps (bSafe/Life360/Noonlight-class). Rules: premium reviewer, language gate (no Bangla in .dart/bn+en), gallery every state, tests, server throttle. Ship with the next APK (build 61 wave).
Alerts flow through Connected Circle + push (FCM when key; polling until then). Watchers = circle members/family (read circle membership — hand integrator hook).

1. START JOURNEY: destination (saved Home/Office/College or map pick), expected arrival time, choose watchers; one-tap presets for frequent trips.
2. LIVE LOCATION journey-only, auto-ends on arrival/stop. Foreground service + visible notif ("Assisto is watching your journey") + Play prominent-location-disclosure; battery-efficient; all Android brands (battery-guidance link if restricted). [native foreground service = platform work; build Dart+backend, mark native bits TODO/key-gated.]
3. VEHICLE DETAILS: photo of CNG/rickshaw/car number plate or ride info → watchers one tap.
4. AUTO-ARRIVAL: geofence destination → watchers "arrived safely ✅"; manual "I'm safe" too.
5. OVERDUE: at expected time ask "Are you OK?" (configurable grace) → no answer → alert watchers w/ last known location + trip timeline; offer 999 call.
6. LOW BATTERY: <15% during journey → auto-send latest location to watchers.
7. DISCREET SOS: power-button ×5 / shake / lock-screen quick tile / hidden widget → SILENT alert + live location to chosen contacts; optional loud siren mode (settings); optional audio recording only if pre-enabled. [power-button/shake/tile/widget = native; build logic + in-app triggers now, native key-gated.]
8. DURESS PIN: stopping journey / cancelling SOS requires PIN; a SEPARATE duress PIN makes the screen look cancelled while SILENTLY sending emergency alert + live location to watchers.
9. FAKE INCOMING CALL: one tap schedules a realistic call screen in N sec (caller name user-chosen).
10. "WHERE ARE YOU?" REQUEST: watcher requests location; shared ONLY when the person taps accept (consent always).
11. NEAREST HELP: during SOS/overdue show nearest police station + hospital (Nearby provider; OSM until Places key) w/ one-tap call/directions.
12. HELPLINES: 999 (national emergency) + 109 (violence against women & children) — VERIFY both from official sources before shipping; RECORD source in report.
13. WATCHERS WITHOUT APP: SMS (when SMS key) or share message w/ EXPIRING link to a minimal live-location WEB page (any browser); link dies when journey ends. **APPROVED exception to web-later.**
14. ROUTINE COMMUTES: scheduled journeys (e.g. weekdays 18:00 office→home) auto-start w/ confirm notification.
15. OPTIONAL ROUTE-DEVIATION alert.
16. WELLNESS CHECK (parents alone): no movement/use for configurable period (e.g. 12h, quiet hours respected) → "Is everything OK?" → no answer → alert children w/ last known location. Opt-in by parent; children can set up w/ parent permission; linked to family care.
17. OFFLINE: queue alerts + retry; SMS fallback when key; via Connected Circle + push (FCM key; polling until).
18. PRIVACY: traveller controls all, stop anytime, trip location history auto-deleted after trip (configurable), never beyond chosen watchers, NO server location after expiry.
19. Bilingual; gallery every state; SCENARIO TESTS: normal trip, late arrival, no response, SOS, duress PIN, low battery, offline, watcher-without-app, wellness check. Ship next APK.

## Partition/reuse: extend safety.py + safety_screen.dart; NEW backend core/logic/safety_journey.py (journey/overdue/geofence/wellness/duress logic) + the web safety page (templates or a static served page under apk_public-style path — approved web exception); NEW app/lib/screens/journey_*.dart + widgets. Hand integrator: models (Journey, SavedPlace, WellnessWatch, DuressPin), endpoints, api, ARB, drawer, circle-watcher + push hooks. Native (foreground service, power-button/shake/tile/widget, FCM) = mark TODO/key-gated; build all logic + in-app paths now.
