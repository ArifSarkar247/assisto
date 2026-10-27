# Competitor research A (read 27 Oct 2026)

Method note: Google Play listing HTML was fetched directly (curl) with hl=en and gl=BD/IN/PK/US; each locale shows ~3 "most relevant" reviews, so each Play URL below = review on that listing (gl in URL). Review dates are the review dates shown on Play. No reviewer names recorded. WebFetch of Play pages is truncated (JS-heavy) so it was not usable; Dhaka Tribune and unstar.app returned 403.
Play URL pattern: https://play.google.com/store/apps/details?id=<pkg>&hl=en&gl=<CC>

## WhatsApp (com.whatsapp, 4.4 stars, 247M reviews, 10B+ installs, read 27 Oct 2026)
Strengths:
- End-to-end encryption valued by users even in 4-star reviews (Play gl=BD review, Sep 2026)
- Users like the new calling UI design (Play gl=BD, 2* review praising design but reporting bug, Aug 2026)
- Default/dominant messaging layer; 61.6% share of IM widgets on BD websites (wmtips.com/technologies/instant-messaging/country/bd, 2026) — proxy, not phone usage
Complaints:
1. Messages stuck pending / delivered minutes late despite working internet — https://play.google.com/store/apps/details?id=com.whatsapp&hl=en&gl=PK — Sep 2026
2. Backup/restore and device switching fragile; chats unrecoverable after factory reset if not logged out, no support — https://play.google.com/store/apps/details?id=com.whatsapp&hl=en&gl=IN — Aug 2026
3. Account put "under review"/banned when linking a second device, no human support — https://play.google.com/store/apps/details?id=com.whatsapp&hl=en&gl=US — Aug 2026 (two separate reviews, Aug 28 + Aug 31 2026)
4. Call UI: Bluetooth audio output can't be switched; large call buttons/"Add contact" touched by cheek, accidentally turns on camera (privacy) — https://play.google.com/store/apps/details?id=com.whatsapp&hl=en&gl=BD and gl=PK — Aug–Sep 2026
5. File share/download fails even on 5G, can't cancel stuck downloads — https://play.google.com/store/apps/details?id=com.whatsapp&hl=en&gl=IN — Sep 2026
6. (Privacy) forced full contact sync on Android — https://play.google.com/store/apps/details?id=com.whatsapp&hl=en&gl=US — Sep 2026
7. (Security, BD) phone numbers of ~3.8M Bangladeshi WhatsApp users reportedly in a leaked 487M-number database sold on hacker forum — https://www.dhakatribune.com/bangladesh/299250/report-over-3.8m-whatsapp-users-data-from (via search snippet; page 403) — Nov 2022
BD-specific insight: Login/OTP account-takeover scams are the main BD-facing risk (account hijack via shared verification code); JustUseApp problem log includes a Bengali-language report of being told to "download official WhatsApp" (i.e., modded WhatsApp clones in use) — https://justuseapp.com/en/app/310633997/whatsapp-messenger/problems — Aug 2025.

## imo (com.imo.android.imoim, 4.3 stars, 9.09M reviews, 1B+ installs, read 27 Oct 2026)
Strengths:
- Cheap international voice/video calls; GSMA case study: "one of the most popular apps in Bangladesh" for calling relatives, esp. wives/rural relatives of migrant workers (https://www.gsma.com/solutions-and-impact/connectivity-for-good/mobile-for-development/wp-content/uploads/2023/02/Robi-Axiata-imo-Pack.pdf, Feb 2023)
- Telco-bundled: Robi sells imo-only data packs via USSD, ~1.2M customers buy a pack monthly (same GSMA PDF)
- Audio calls praised as "the best" even by unhappy reviewers (Play gl=BD review, May 2023)
Complaints:
1. Far too many ads (recurring across BD/IN/PK listings) — https://play.google.com/store/apps/details?id=com.imo.android.imoim&hl=en&gl=PK — Aug 2024 & Sep 2026
2. Stuck on "Connecting...", slow to open, call screen won't close after hang-up — https://play.google.com/store/apps/details?id=com.imo.android.imoim&hl=en&gl=IN — Jul/Sep 2026
3. Video calls freeze with "Connection unstable", must redial 3–5 times — https://play.google.com/store/apps/details?id=com.imo.android.imoim&hl=en&gl=IN — Sep 2026
4. Photos sent blurry, can't send videos over ~2 min — https://play.google.com/store/apps/details?id=com.imo.android.imoim&hl=en&gl=BD — May 2023
5. Unwanted "inappropriate" chat groups/notifications keep appearing even after blocking — https://play.google.com/store/apps/details?id=com.imo.android.imoim&hl=en&gl=IN — Mar 2024
6. (Privacy) accidental one-tap voice recording that kept recording when locked and got sent — https://play.google.com/store/apps/details?id=com.imo.android.imoim&hl=en&gl=GB — Apr 2023
BD-specific insight: imo self-reports restricting 628,000 BD accounts and banning 179,000 devices for hacking/harassment/fraud Jan–Sep 2024 (sponsored-style article) — https://en.prothomalo.com/science-technology/social-media/s0eckcbxpe — 2024. Fraud/harassment is a known BD problem on the platform.

## Facebook Messenger (com.facebook.orca, 4.4 stars, 115M reviews, 5B+ installs, read 27 Oct 2026)
Strengths:
- Huge BD reach: ~68.7M Messenger users in Bangladesh (Meta ad-audience estimate) — https://napoleoncat.com/stats/messenger-users-in-bangladesh/ — Sep 2026
- Free calls/chat tied to Facebook identity (no phone-number sharing needed)
- Media/notes/stories features users actively engage with (implied by complaints about notes)
Complaints:
1. Notifications missing or arriving minutes late (recurring) — https://play.google.com/store/apps/details?id=com.facebook.orca&hl=en&gl=US — May 2025; gl=BD — Jun 2026
2. App opens to black screen, messages visible only in notification — https://play.google.com/store/apps/details?id=com.facebook.orca&hl=en&gl=BD — Sep 2026
3. Search of old conversations/shared media broken and laggy after update — https://play.google.com/store/apps/details?id=com.facebook.orca&hl=en&gl=BD — Apr 2025
4. Forced end-to-end "sync"/secure storage setup to see chat history (privacy/consent friction) — https://play.google.com/store/apps/details?id=com.facebook.orca&hl=en&gl=IN — Apr 2026
5. Hidden contacts' notes/online status keep reappearing — https://play.google.com/store/apps/details?id=com.facebook.orca&hl=en&gl=BD — Jun 2026
BD-specific insight: Messenger is effectively the BD default for chat among Facebook users (68.7M est.); notification reliability is the key failure that matters on low-end/OEM-throttled phones.

## Telegram (org.telegram.messenger, 4.0 stars, 17.3M reviews, 1B+ installs, read 27 Oct 2026)
Strengths:
- Channels for one-way broadcast + groups (Play gl=US 5* review, Sep 2026)
- Edit/delete sent messages, vanishing media (Play gl=US, Aug 2026)
- Works on low-end devices (Kindle Fire user, Sep 2026)
Complaints:
1. Spam/unwanted messages; "who can message me" privacy control is Premium-only — https://play.google.com/store/apps/details?id=org.telegram.messenger&hl=en&gl=BD — Dec 2024
2. Bots everywhere; phone numbers exposed via bots; feels unsafe — https://play.google.com/store/apps/details?id=org.telegram.messenger&hl=en&gl=BD — Feb 2026
3. Stuck on "Connecting…/Updating…", calls stuck "Loading"; account recovery SMS refused as "too expensive" — https://play.google.com/store/apps/details?id=org.telegram.messenger&hl=en&gl=IN — Aug 2026
BD-specific insight: Telegram ~12% of IM widgets on BD websites (wmtips, 2026) — niche vs WhatsApp/Messenger; popular for channels/groups.

## Life360 (com.life360.android.safetymapd, 4.7 stars, 2.49M reviews, 100M+ installs, read 27 Oct 2026)
Strengths:
- Category leader for family circles: live map, place arrivals/departures, driving reports (Play listing)
- Crash detection/roadside/SOS in paid tiers ($4.99–$19.99/mo reported) (greenmatters.com/family/why-life360-is-bad, date not shown)
- High rating (4.7) despite complaints — strong onboarding & brand trust
Complaints:
1. Location stale/frozen for hours, or accurate only to ~half a mile — https://play.google.com/store/apps/details?id=com.life360.android.safetymapd&hl=en&gl=BD — Oct 2025; also blank map/loses connection (gl=US) — Apr 2025
2. False "left/arrived home" alerts overnight and inflated driving speeds (kids get blamed) — https://play.google.com/store/apps/details?id=com.life360.android.safetymapd&hl=en&gl=BD — Apr 2026
3. Bloat: pop-ups every login, promo "mail" inbox, can't choose notification types — https://play.google.com/store/apps/details?id=com.life360.android.safetymapd&hl=en&gl=BD — Oct 2025
4. Battery drain — ranked most common complaint (23% of 1–3 star reviews) across family-location apps in a third-party review analysis; 65/146 recent negative reviews about late/frozen/wrong location (Aug 2026) — https://unstar.app/blog/life360-find-my-google-glympse-find-my-kids-family-location-apps-ranked-2026 (search snippet; page 403) — 2026
5. Privacy: sold precise location data of families/kids to data brokers (The Markup investigation) — https://www.businessinsider.nl/popular-safety-app-life360-is-reportedly-selling-the-precise-location-data-of-millions-of-kids-and-their-families/ — Dec 2021
6. Billing: charged after cancelling; couldn't reach support in roadside emergency — https://ie.trustpilot.com/review/life360.com — date not shown
BD-specific insight: Background location is killed by OEM battery optimisers (MIUI/EMUI cited) — vendor guidance says exclude from battery optimisation and never force-quit; this is exactly the Realme/Xiaomi/Oppo/Vivo problem in BD. Paid tiers priced in USD — unaffordable for most BD families.

## Google Family Link (com.google.android.apps.kids.familylink, 4.6 stars, 5.47M reviews, 100M+ installs, read 27 Oct 2026)
Strengths:
- Free, built into Google accounts; app approval, screen-time limits, device lock (Play gl=BD 3* review appreciates control, Oct 2025)
- Location of child's device + ring device
- Peace of mind for parents (same review)
Complaints:
1. Update broke screen time, lock, find/beep and GPS — https://play.google.com/store/apps/details?id=com.google.android.apps.kids.familylink&hl=en&gl=BD — Apr 2025
2. Location arrival/leave alerts missed or fired falsely during the night — https://play.google.com/store/apps/details?id=com.google.android.apps.kids.familylink&hl=en&gl=BD — Sep 2025
3. "Ask to download" approval bypassed; child installs apps anyway — same URL — Sep 2025; kids bypass via OEM "Dual Apps/App Cloning", secure folders — https://www.bitdefender.com/en-us/blog/hotforsecurity/family-link-bypass-android-2025 — 2025
4. Locked child device can only call, not text parent — safety risk when out — https://play.google.com/store/apps/details?id=com.google.android.apps.kids.familylink&hl=en&gl=US — Jul 2026; bug blocking kids' outgoing calls — https://www.androidauthority.com/google-family-link-bug-3663231/ — date not shown (2026 per URL id)
5. Inflexible: bonus time only "forever", no per-app time-of-day windows; persistent notification; can't remove supervision without wiping profile — gl=BD Oct 2025; gl=US Aug–Sep 2026
BD-specific insight: Xiaomi background-kill anecdote (Maps killed after 3h on child's Xiaomi) — https://www.airdroid.com/location-tracking/google-maps-location-is-wrong/ — date not shown (vendor source). OEM skins common in BD (Xiaomi/Realme/Oppo) both kill location and offer clone-app bypasses.

## Anti-theft: Google Find Hub (formerly Find My Device) (com.google.android.apps.adm, 4.5 stars, 1.69M reviews, 1B+ installs, read 27 Oct 2026)
Strengths:
- Free remote ring/lock with message/erase (Play gl=BD 5* review, Aug 2026)
- Offline finding network; Pixel 8+ findable for hours when powered off (https://support.google.com/android/answer/3265955, current)
- Pre-installed on most Android phones
Complaints:
1. Locations don't refresh; stale for days — https://play.google.com/store/apps/details?id=com.google.android.apps.adm&hl=en&gl=BD — Jun 2025
2. Locating triggers "Your device is being located by Google" notice on the lost phone — alerts the thief — https://play.google.com/store/apps/details?id=com.google.android.apps.adm&hl=en&gl=IN — Sep 2026
3. No precise nearby/walking-direction finder; ring sometimes fires 30 min late — gl=IN — Sep 2026 / Aug 2019
4. Undismissable notification-permission banner; can't add earbuds anymore — gl=US — Aug 2026
5. Useless after factory reset; powered-off finding only on supported (Pixel) phones and needs BT+location on beforehand (Google support page + guides) — https://support.google.com/android/answer/3265955 — current
BD-specific insight: Most BD phones are not Pixels, so "find when off" mostly doesn't apply; thieves power off/reset — matches Prey complaint below.

## Anti-theft third party: Prey (com.prey, 4.4 stars, 62K reviews, 5M+ installs) + Cerberus + "Anti-theft alarm" (com.ralok.antitheftalarm, 4.2, 5M+, last updated Jan 2020)
Strengths:
- Prey: recovered phones/laptop, remote lock/disable, cross-device (Play gl=BD 5* review, Jun 2024)
- Prey: thief photos via remote camera (same review)
- Anti-theft alarm: motion/charger-unplug alarm is simple and popular (5M+ installs)
Complaints:
1. Thief just switches phone off → Prey useless (Find Hub has BT offline tracking) — https://play.google.com/store/apps/details?id=com.prey&hl=en&gl=BD — Aug 2026
2. Prey silently stopped tracking for months; login stuck on error — https://play.google.com/store/apps/details?id=com.prey&hl=en&gl=US — Feb 2020
3. Remote photo shutter sound reveals the app (must pre-disable; some carriers forbid) — https://play.google.com/store/apps/details?id=com.prey&hl=en&gl=BD — Jun 2024
4. Cerberus revoked paid "lifetime" licences (after 8 years) → trust collapse; still cited in 2024–2025 reviews of its other app — https://www.androidpolice.com/2019/12/21/cerberus-paid-lifetime-license-expiration — Dec 2019; https://play.google.com/store/apps/details?id=com.lsdroid.cerberus.persona2&hl=en&gl=BD — Jul 2024 & Dec 2025 (main Cerberus Play listing com.lsdroid.cerberus not found on Play)
5. Anti-theft alarm: motion alarm stops working after a few minutes / only triggers when screen on (Samsung S23U) — https://play.google.com/store/apps/details?id=com.ralok.antitheftalarm&hl=en&gl=BD — Mar 2020, Aug 2025
Note: Prey listing contains spam 5* reviews advertising "hackers" for spouse spying (Jul 2026) — review spam/stalkerware association is a trust risk for this category.
BD-specific insight: Anti-theft apps that need the phone powered on + online are defeated by the standard BD snatch pattern (switch off, SIM out, reset).

## Ride-share safety: Pathao (com.pathao.user, 3.5 stars, 116K reviews, 10M+ installs) + Uber (com.ubercab, 4.8, 20.3M reviews, 1B+) — read 27 Oct 2026
Strengths:
- Pathao "Safety" menu + emergency helpline 13301; Uber SOS → 999 or safety team, audio recording, 4-digit PIN, trip sharing — https://en.prothomalo.com/lifestyle/travel/brlnnkfd6t — Aug 2025
- Pathao: driver document checks, helmets, live location sharing, in-app 999 button (company statement) — https://www.tbsnews.net/opinion/taking-issues-ride-sharing-services-prioritise-safety — Nov 2019
- Uber 24x7 safety helpline in BD; Uber+Pathao joint safety campaign (verified driver/vehicle details, insured rides) — https://www.uber.com/en-BD/newsroom/uber-and-pathao-join-hands-to-raise-the-bar-for-a-safer-rideshare-industry — Jul 2022
Complaints:
1. Complaints ignored/slow support; Pathao support's only fix is "reinstall"; points deducted, no reply for days — https://play.google.com/store/apps/details?id=com.pathao.user&hl=en&gl=BD — Jun 2026; gl=IN — Aug 2026; TBS — Nov 2019
2. Off-app ("offline") trips + cash demands with threats; linked to 2019 killing of a bike rider on an offline trip — TBS Nov 2019; Prothom Alo Aug 2025
3. Harassment/assault by drivers (Uber BD), BRTA threatened action — https://thefinancialexpress.com.bd/trade/how-uber-losing-its-credibility-in-bangladesh-as-a-hassle-free-service-1664276222 — Sep 2022
4. Fare shock: price raised after booking/at completion (Pathao +30% if "2 min over" undisclosed time; Uber price jumps) — Pathao gl=BD Jun 2026; Uber gl=IN Sep 2026
5. Notification spam: ~30 promo pushes/day, can't disable — https://play.google.com/store/apps/details?id=com.pathao.user&hl=en&gl=IN — Aug 2026
6. Regulator gap: 999/police-control-room signalling required by 2018 guidelines but stalled — https://www.thedailystar.net/frontpage/news/ride-hailing-services-key-guidelines-gathering-dust-1658548 — Nov 2018
BD-specific insight: Pathao's 3.5 rating is far below Uber's 4.8; BD users' safety risk is concentrated in late-night rides, off-app trips and cash disputes — a family "safe journey" share that works outside any ride app fills this gap.

## Personal safety app: bSafe (com.bipper.app.bsafe, 4.0 stars, 8.86K reviews, 1M+ installs, last updated Nov 2025, read 27 Oct 2026)
Strengths:
- SOS + live tracking + "follow me" for walks (Play gl=BD 1* review describing use, Jan 2020)
- Voice-activated SOS
- Good-looking UI (gl=BD 2* review, May 2026)
Complaints:
1. Paywall: "free" but basic features need expensive subscription — https://play.google.com/store/apps/details?id=com.bipper.app.bsafe&hl=en&gl=BD — Nov 2019; gl=US — Nov 2020
2. Crashes when voice permission granted; tracking wrong when revoked — gl=BD — Jan 2020
3. "App isn't responding" freezes; map puts user in the Atlantic Ocean — gl=BD — May 2026
4. Phone number/email not recognised at signup (paste fails) — gl=BD — Nov 2019
BD-specific insight: BD Police "Shurokkha" safety app rated 2.5/5 (34 ratings) on App Store — https://apps.apple.com/us/app/-/id1485526522 — date not shown (search snippet); DMP said no complaints yet received through safety apps — https://www.dhakatribune.com/bangladesh/377086/can-technology-offer-a-hope-against-soaring-sexual — date not shown (search snippet). Local govt/NGO safety apps exist (Bachao, HELP, Eagle BD Police) but have low adoption/ratings.

## Imou Life (com.mm.android.smartlifeiot, 4.5 stars, 335K reviews, 10M+ installs, read 27 Oct 2026)
Strengths:
- Cheap Wi-Fi cams with good image quality; motion detection works when online (Play gl=US reviews praise camera, 2022)
- Ran reliably for years for some users (gl=BD review: 3 years on Ranger 2, Aug 2026)
- Works great on Wi-Fi (gl=IN, Sep 2026)
Complaints:
1. Poor on mobile data: keeps buffering even on 5G; repeated "playing on cellular" pop-up — https://play.google.com/store/apps/details?id=com.mm.android.smartlifeiot&hl=en&gl=IN — Sep 2026
2. Notifications stop / live view fails after update; must toggle mobile data — https://play.google.com/store/apps/details?id=com.mm.android.smartlifeiot&hl=en&gl=BD — Aug 2026
3. Login fails with "unknown error" (region issue) → camera useless — gl=BD — Sep 2026
4. Live view capped ("You have been viewing for a long time") — gl=PK — Feb 2021; streaming freezes at 0 KB/s, repeated re-login — gl=US — May/Aug 2022
5. Camera drops off phone hotspot every few hours; desktop login verification email never arrives → pushed to paid cloud — gl=IN — May 2023 / Jan 2025
BD-specific insight: Imou has ~35 listings on Bikroy vs 170 Hikvision, 119 Dahua, 53 EZVIZ — https://bikroy.com/security-and-surveillance/eufy — date not shown (ad counts, not sales). Many BD homes run cams on hotspot/mobile data → the cellular weakness matters.

## Hik-Connect (com.connect.enduser, 4.7 stars, 3.54M reviews, 50M+ installs, read 27 Oct 2026)
Strengths:
- HD images/video, snapshots; works on phones and TVs (Play gl=BD 5*, Sep 2026)
- Default app for the most widely sold CCTV/DVR brand (Hikvision 170 ads on Bikroy, highest)
- Multi-camera grid live view
Complaints:
1. Slow/laggy live view after updates; "Connecting device to streaming server failed"/"streaming timed out" — https://play.google.com/store/apps/details?id=com.connect.enduser&hl=en&gl=BD — May 2025; gl=IN — Jun 2025
2. Playback painful: hours to load, no jump-to-time, freezes at >1x speed — gl=IN — Feb/Jul 2025; gl=US — Jul 2025
3. "Number of devices / streaming channels exceeded" errors for a single user — gl=IN & gl=US — Jul 2025
4. Doorbell/intercom notification arrives seconds late, app slow to open → missed visitors — gl=BD — Aug 2026
5. Security: 2017 cloud auth flaw allowed feed viewing/account takeover — https://portswigger.net/daily-swig/from-hikvision-to-hackvision-critical-vulnerability-patched-in-cctv-cloud-service — 2017; 2026 advisory CVE-2026-32683 (data transmission risk, app < V6.11.80) — https://www.hikvision.com/uk/support/cybersecurity/security-advisory/security-vulnerability-in-cloud-function-modules-of-some-hikvisi/ — May 2026
BD-specific insight: BD prices: Hikvision/Dahua IP cams ~৳2,400–3,900 — https://www.bdstall.com/cctv-camera/wifi-cc-camera/2/ — 2026 listing. Memory-hungry app (gl=IN, Feb 2025) hurts low-RAM phones.

## EZVIZ (com.ezviz, 4.7 stars, 452K reviews, 10M+ installs, read 27 Oct 2026)
Strengths:
- Straightforward setup and crisp image initially (gl=IN 2* review, Dec 2025)
- Affordable in BD: H6c 3MP PTZ ~৳2,200, C6CN ~৳2,500 — https://www.bdstall.com/cctv-camera/wifi-cc-camera/3/ — 2026
- Good overall device+app experience for smart locks/doorbells (gl=PK 3*, Apr 2026)
Complaints:
1. App pushes subscription ads; disabling ads in settings doesn't work — https://play.google.com/store/apps/details?id=com.ezviz&hl=en&gl=BD — Jul 2026
2. SD-card formatting never completes → no recording for months — gl=BD — Aug 2026
3. Can't change Wi-Fi after router change; no contact/help page in app — gl=BD — Aug 2026
4. "Upper limit of sign-in" lockouts / duplicate terminals after update — gl=IN — Jan 2024
5. Motion alerts triggered by leaf shadows; poor playback controls (no speed/scrub) — gl=US — Dec 2019
BD-specific insight: Competes on price with generic V380 Wi-Fi cams (~৳1,000–3,000, incl. 4G-SIM models) heavily listed in BD — bdstall 2026.

## Tracksolid Pro (Jimi IoT; com.jimi.tuqiang.tracksolidpro, 4.7 stars, 5.32K reviews, 1M+ installs, read 27 Oct 2026) + BD variant "TSP for Bengal" (com.jimi.tracksolidpro.bengal, 4.3, 113 reviews, 10K+)
Strengths:
- Live tracking + remote fuel/engine cut via app/SMS works reliably once wired (gl=BD 4*, Aug 2026)
- Geofence, playback, alerts, reports (App Store listing)
- Sold white-labelled in BD ("TSP for Bengal"): users feel safer, check car anytime (BD 5*, Aug 2025)
Complaints:
1. False geofence-exit alerts; playback broken; can't edit address — https://play.google.com/store/apps/details?id=com.jimi.tuqiang.tracksolidpro&hl=en&gl=BD — Sep 2026
2. (BD) Signal lost every ~2 months, GPS stops; bike body opened repeatedly for repairs — https://play.google.com/store/apps/details?id=com.jimi.tracksolidpro.bengal&hl=en&gl=BD — Jul 2025
3. No auto-follow map; must keep tapping to follow moving vehicle — gl=BD — Aug 2026
4. Billing: charged for 4 devices using 1; refund never came; renewal impossible and no support reply — https://apps.apple.com/us/app/-/id1515254986 — Jun 2024, Feb 2024
5. Live updates/audio unstable; basic install instructions — App Store Sep (year not shown); Play gl=BD Aug 2026
BD-specific insight: From 1 Aug 2026 approved GPS trackers mandatory for (non-private) vehicles in BD — https://meatechwatch.com/2026/07/27/locomotepro-launches-in-bangladesh-as-the-1-august-gps-mandate-arrives/ (search snippet; page 403) — Jul 2026. Typical BD pricing: Prohori ৳4,999 device + ৳450/month — https://www.rokomari.com/electronics/379023/prohori-gps-tracker-lite-package — date not shown; GP older ৳11,000 + ৳700/mo — https://www.thedailystar.net/online/devices-can-track-stolen-cars-1467487 — date not shown (likely ~2017).

## BD vehicle tracking service apps: Robi Vehicle Tracking (bd.com.robi.vts, 4.1, 258 reviews, 10K+) / Robi Vehicle Tracker RVT (com.bondstein.app.rvt, 4.2, 87, 1K+) / Track My Vehicle TMV by Bondstein/Finder (com.bondstein.app.tmv, 4.2, 138, 10K+) / Banglalink Vehicle Tracker (com.bondstein.app.bvt, 4.5, 30, 1K+) — read 27 Oct 2026
Strengths:
- Telco-backed trust (Robi/Banglalink) and local support (Bondstein = Finder white-label)
- "Best vehicle tracking app in Bangladesh", track car from mobile — https://play.google.com/store/apps/details?id=com.bondstein.app.tmv&hl=en&gl=BD — Aug 2026
- BTRC-licensed local providers (Finder/Bondstein, Falcons etc.)
Complaints:
1. Car untracked for a week; customer care couldn't fix despite many calls ("local apps are much better") — https://play.google.com/store/apps/details?id=bd.com.robi.vts&hl=en&gl=BD — Mar 2026
2. Helpline listens 10+ times but never fixes device problems — same URL — Nov 2019
3. Fails exactly when needed; very poor network — https://play.google.com/store/apps/details?id=com.bondstein.app.rvt&hl=en&gl=BD — Sep 2026
4. In-app calendar dates/days mismatched — same RVT URL — Jul 2026
5. No direction-of-travel indicator; persistent banner covers map; TMV: no sign-up path, login only — bd.com.robi.vts Nov 2019; com.bondstein.app.tmv Aug 2026
BD-specific insight: BD tracker apps have tiny install bases (1K–10K) and few reviews; the hardware is mostly Chinese GT06/Concox-class with white-label apps — UX and support quality are the weak points, not features.
