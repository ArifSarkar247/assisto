# Google Play Store pack — Assisto (`com.assisto.assisto`)

> Prepared by l1-launch, 2026-10-22. Everything here is written from the real
> code (manifest patch in `.github/workflows/android.yml`, `backend/core/models.py`,
> the purge crons, the AdMob bridge). It is a **draft for the owner**; Play
> Console answers are your legal declaration — read each line before you submit.
> Items marked **[OWNER]** need facts only you know.

Public URLs the Play Console asks for (live once this branch is deployed):

| Field | URL |
|---|---|
| Privacy policy | https://lifeassisto.com/privacy (English: `?lang=en`) |
| Terms of service | https://lifeassisto.com/terms |
| Account / data deletion (Data safety → "Delete account URL") | https://lifeassisto.com/delete-account |
| Website (store listing "Website") — must be the domain that serves app-ads.txt | https://lifeassisto.com |
| app-ads.txt | https://lifeassisto.com/app-ads.txt |
| Contact email (store listing, required) | **[OWNER]** — same as `LEGAL_CONTACT_EMAIL` |

---

## 0. Owner placeholders (fill BEFORE submitting)

The policy pages show "(to be added)" until these environment variables are set
in `backend/.env` on the server (then restart the service). No code change.

| Env var | What |
|---|---|
| `LEGAL_ENTITY_NAME` | Legal name of the business publishing Assisto (must match the Play developer account) |
| `LEGAL_ADDRESS` | Registered postal address (Play also shows it on the listing for organisation accounts) |
| `LEGAL_CONTACT_EMAIL` | Privacy/support email |
| `LEGAL_GRIEVANCE_OFFICER` | Person/role responsible for privacy requests (DPO / grievance officer) |
| `LEGAL_GOVERNING_LAW` | e.g. "the laws of Bangladesh; courts of Dhaka" — confirm with your lawyer |
| `LEGAL_HOSTING` | Where the servers are (provider + country/region) |
| `ADMOB_PUBLISHER_ID` | `pub-XXXXXXXXXXXXXXXX` (or paste the real AdMob App ID / Publisher ID in Owner panel → Integrations → Google AdMob; app-ads.txt picks it up) |

The website footer currently says "Assisto · AXON ERP Software". If that is
the publishing entity, use the same name in `LEGAL_ENTITY_NAME`; if not,
change the footer — the listing, the policy and the site must agree.

---

## 1. Store listing

### App name (max 30)

- English: `Assisto: AI Life Assistant` (26)
- বাংলা: `Assisto: AI জীবন সহকারী` (23)

(Trademark search for "Assisto" is still open — `owner_actions/name_check.md`.)

### Short description (max 80)

<!-- short-en -->
```
Your Bangla-first AI helper for reminders, money, family, safety and business.
```
<!-- short-bn -->
```
রিমাইন্ডার, হিসাব, পরিবার, নিরাপত্তা ও ব্যবসা — বাংলায় আপনার AI সহকারী।
```

### Full description (max 4000)

<!-- full-en -->
```
Assisto is a personal assistant built for Bangladesh. Speak or type in Bangla or English — Assisto remembers, reminds and keeps your life in order. You live your life; remembering is Assisto's job.

EVERYTHING IN ONE CHAT
• Say "500 taka food expense" or "remind me about medicine at 8am tomorrow" — Assisto logs it and shows a card you can undo.
• Anything that leaves the app (a call, a message, a payment note) always asks for your OK first.

REMINDERS, NOTES AND TASKS
• Reminders that ring on time, notes, to-do lists and a memory of the small things that matter.
• Birthdays, bills, subscriptions and document expiry dates — reminded before they are due.

MONEY, CLEARLY
• Income, expenses, budgets, loans and savings goals at a glance.
• Monthly trends and net worth. Assisto never holds or moves your money — it is your own ledger.

FAMILY CARE
• Medicine schedules for parents and children, dose history and "please check" alerts for family.
• An emergency card with blood group, allergies and medicines.

SAFETY
• One-tap SOS that alerts your trusted contacts with your location.
• Safe Journey: the people you choose can follow your trip until you arrive.
• Optional hands-free voice SOS and a fake call to get out of uncomfortable situations.
• Anti-theft for your phone: remote lock and alerts if it is lost (you switch it on; you can switch it off any time).

DOCUMENT VAULT AND PHOTO STUDIO
• Keep passport, NID and licence details with expiry reminders.
• Make passport and visa size photos in the right size.

MESSAGING AND CALLS
• Chat and call your circle. Personal and group text messages are end-to-end encrypted.

ASSISTO VOICE
• "Call Mom", "set an alarm for 6:30", "500 taka groceries" — by voice, with confirmation before any call.

FOR SHOPS AND SMALL BUSINESSES
• Digital khata (dues and payables), quick selling, cashbox, products, customers and reports.
• Turn an old phone into a shop camera with alerts (Shop Box).
• Car OBD readings over Bluetooth and GPS vehicle tracking with your own tracker.

SMARTWATCH AND FITNESS
• See your steps, heart rate and sleep from Health Connect. This data stays on your phone.

PRIVACY FIRST
• We never sell your data.
• Every permission is asked only when you use the feature that needs it, and is explained in our privacy policy.
• Delete your account and all data from Settings at any time, or request it at lifeassisto.com/delete-account.

PLANS
• Free plan with optional, non-personalised ads (never on SOS, safety, payment or call screens). Paid plans remove app-open ads and add more AI credits.

Assisto is for people aged 18 and over. It does not give medical, legal or financial advice, and it is not a replacement for emergency services — in an emergency call 999.

Privacy policy: https://lifeassisto.com/privacy
```
<!-- full-bn -->
```
Assisto — বাংলাদেশের জন্য তৈরি আপনার ব্যক্তিগত সহকারী। বাংলা বা ইংরেজিতে বলুন বা লিখুন — Assisto মনে রাখে, সময়মতো মনে করিয়ে দেয়, জীবন গুছিয়ে রাখে। জীবন আপনি চালান, মনে রাখার দায়িত্ব আমার।

সব কাজ এক চ্যাটে
• বলুন "৫০০ টাকা খরচ খাবার" বা "কাল সকাল ৮টায় ওষুধ মনে করিয়ে দিও" — Assisto লিখে রাখে এবং একটি কার্ড দেখায়, চাইলে ফিরিয়ে নিতে পারেন।
• অ্যাপের বাইরের কোনো কাজ (কল, মেসেজ, পেমেন্টের নোট) করার আগে সবসময় আপনার অনুমতি নেয়।

রিমাইন্ডার, নোট ও কাজ
• সময়মতো বাজা রিমাইন্ডার, নোট, কাজের তালিকা, আর ছোট ছোট জরুরি কথা মনে রাখার মেমরি।
• জন্মদিন, বিল, সাবস্ক্রিপশন ও কাগজপত্রের মেয়াদ — শেষ হওয়ার আগেই মনে করিয়ে দেয়।

পরিষ্কার হিসাব
• আয়, খরচ, বাজেট, ধার ও সঞ্চয়ের লক্ষ্য এক নজরে।
• মাসভিত্তিক প্রবণতা ও নিট সম্পদ। Assisto কখনো আপনার টাকা রাখে বা পাঠায় না — এটি শুধু আপনার নিজের খাতা।

পরিবারের যত্ন
• বাবা-মা ও সন্তানদের ওষুধের সময়সূচি, ডোজের ইতিহাস এবং পরিবারকে "একটু দেখে নিন" সতর্কবার্তা।
• রক্তের গ্রুপ, অ্যালার্জি ও ওষুধসহ জরুরি তথ্য কার্ড।

নিরাপত্তা
• এক চাপে SOS — আপনার বিশ্বস্ত মানুষদের কাছে লোকেশনসহ সতর্কবার্তা যায়।
• নিরাপদ যাত্রা: আপনি যাদের বেছে নেন, তারা পৌঁছানো পর্যন্ত আপনার যাত্রা দেখতে পান।
• ঐচ্ছিক হ্যান্ডস-ফ্রি ভয়েস SOS, আর অস্বস্তিকর পরিস্থিতি থেকে বের হতে নকল কল।
• ফোনের চুরি-সুরক্ষা: হারালে দূর থেকে লক ও সতর্কবার্তা (আপনি চালু করেন, যেকোনো সময় বন্ধ করতে পারেন)।

ডকুমেন্ট ভল্ট ও ফটো স্টুডিও
• পাসপোর্ট, NID, লাইসেন্সের তথ্য রাখুন, মেয়াদ শেষের আগে রিমাইন্ডার পান।
• সঠিক মাপে পাসপোর্ট ও ভিসা ছবি বানান।

মেসেজ ও কল
• আপনার সার্কেলের সাথে চ্যাট ও কল। ব্যক্তিগত ও গ্রুপ চ্যাটের লেখা বার্তা end-to-end এনক্রিপ্টেড।

Assisto ভয়েস
• "আম্মুকে ফোন দাও", "সকাল ৬:৩০-এ অ্যালার্ম দাও", "৫০০ টাকা বাজার খরচ" — কণ্ঠেই, যেকোনো কলের আগে নিশ্চিতকরণসহ।

দোকান ও ছোট ব্যবসার জন্য
• ডিজিটাল খাতা (বাকি ও দেনা), দ্রুত বিক্রি, ক্যাশবক্স, পণ্য, গ্রাহক ও রিপোর্ট।
• পুরনো ফোন দিয়েই সতর্কবার্তাসহ দোকানের ক্যামেরা (Shop Box)।
• ব্লুটুথে গাড়ির OBD রিডিং এবং নিজের GPS ট্র্যাকার দিয়ে গাড়ি ট্র্যাকিং।

স্মার্টওয়াচ ও ফিটনেস
• Health Connect থেকে আপনার ধাপ, হার্ট রেট ও ঘুম দেখুন। এই তথ্য আপনার ফোনেই থাকে।

গোপনীয়তা আগে
• আমরা কখনো আপনার ডেটা বিক্রি করি না।
• প্রতিটি অনুমতি চাওয়া হয় শুধু যখন সেই ফিচার ব্যবহার করেন, এবং গোপনীয়তা নীতিতে কারণসহ ব্যাখ্যা করা আছে।
• সেটিংস থেকে যেকোনো সময় অ্যাকাউন্ট ও সব ডেটা মুছুন, অথবা lifeassisto.com/delete-account থেকে অনুরোধ করুন।

প্ল্যান
• ফ্রি প্ল্যানে ঐচ্ছিক, নন-পার্সোনালাইজড বিজ্ঞাপন (SOS, নিরাপত্তা, পেমেন্ট বা কলের স্ক্রিনে কখনো নয়)। পেইড প্ল্যানে অ্যাপ খোলার বিজ্ঞাপন নেই, AI ক্রেডিট বেশি।

Assisto ১৮ বছর বা তার বেশি বয়সীদের জন্য। এটি চিকিৎসা, আইনি বা আর্থিক পরামর্শ দেয় না এবং জরুরি সেবার বিকল্প নয় — জরুরি প্রয়োজনে ৯৯৯-এ কল করুন।

গোপনীয়তা নীতি: https://lifeassisto.com/privacy
```

Character counts (checked with a script, Play counts characters not bytes):
short-en 78, short-bn 72, full-en 2,790, full-bn 2,663 — all within limits
(re-count if you edit: the text between the ``` fences).

### Category, tags, contact
- Category: **Productivity** (alternative: Lifestyle).
- Tags (pick up to 5 in Console): Personal assistant, Reminders, Budget, Family safety, Small business.
- Email: **[OWNER]**. Website: https://lifeassisto.com. Phone (optional): **[OWNER]**.

### Graphics — `owner_actions/play_store/`
| Asset | Spec (Play) | File |
|---|---|---|
| App icon | 512×512 PNG, 32-bit | export from `app/assets/icon/icon.png` (1024²) — resize to 512 |
| Feature graphic | 1024×500 JPG/24-bit PNG, no alpha | `feature_graphic_en.png`, `feature_graphic_bn.png` |
| Phone screenshots | 2–8 per language, 9:16, each side 320–3840 px | 8 × `phone_<lang>_<n>_<screen>.png` (1080×1920) |

The 8 screenshots (same order in both languages; real app screens from the
gallery test `app/test/screenshots_test.dart` with demo data, light theme,
framed on the brand gradient with a caption):

1. `home_welcome` — home with shortcuts and urgent items — "Your AI assistant — everything in one place"
2. `chat` — natural-language logging with undo cards and an approval card
3. `money` — Account & Finance summary
4. `voice_assistant` — Assisto Voice suggestions
5. `safety` — Safe Journey, SOS, voice SOS, safe-arrival check-in
6. `family` — today's medicines for family members
7. `biz_hub` — Business: khata, selling, cashbox, reports
8. `shop_cameras` — Shop Box cameras

Rebuild them any time: run the gallery test into a folder
(`ASSISTO_SHOT_DIR=/tmp/shots ASSISTO_SHOT_ONLY=home_welcome,chat,money,voice_assistant,safety,family,biz_hub,shop_cameras flutter test test/screenshots_test.dart`)
then `~/assisto/.venv/bin/python owner_actions/play_store/make_graphics.py /tmp/shots`.
Note: the money demo shows net worth ৳0 next to a ৳20,800 balance (fake data
in `app/test/fake_api.dart`); fix the fake data if a reviewer might find it odd.

---

## 2. Content rating (IARC questionnaire)

Category: **"All other app types"** (utility/productivity/communication — not a game).

| Question | Answer | Why |
|---|---|---|
| Violence, blood, gore | No | — |
| Sexual content / nudity | No | — |
| Profanity / crude humour | No | — |
| Drugs, alcohol, tobacco | No | Medicine reminders are health records, not drug use/promotion |
| Gambling / simulated gambling | No | — |
| Fear / horror | No | — |
| Does the app let users interact or exchange content? | **Yes** | Messenger, groups, channels, communities |
| Does it share the user's location with other users? | **Yes** | SOS, Safe Journey, circle |
| Can users buy digital goods? | **Yes** | Paid plans / credit packs (answer Yes once purchases are live) |
| Unrestricted web access / browser | No | Links open the phone's own browser |
| Is it a news app / gambling / social casino | No | — |

Expected result: a low age rating (e.g. "Everyone"/"PEGI 3") with interactive
elements "Users interact, Shares location, In-app purchases". The final rating
is whatever IARC returns.

---

## 3. Target audience & content

- Target age groups: **18 and over only**. Not designed for children; no child-appealing characters/themes. Do not opt into "Designed for Families".
- "Could the app unintentionally appeal to children?" → No.
- News app: No. COVID-19 app: No. Government app: No. Financial features: it is a personal ledger — it does **not** offer loans, payments or money transfer (answer the "Financial features" form accordingly: personal finance management only).
- Health apps declaration (required because of Health Connect): select **Fitness / activity tracking** and **Medication reminders**; not a medical device; no diagnosis.

## 4. Ads declaration

**"Does your app contain ads?" → Yes.** Two reasons:
1. Discover shows owner-sold **"Sponsored"** cards on every plan (always labelled).
2. Google AdMob on the Free plan once the AdMob proposal (`.phaseB/proposals/a6-leftovers-admob.md`) ships.

Even before AdMob ships, (1) alone means "Yes". Ads are never shown on SOS,
safety, payment, sign-in or call screens (enforced in `app/lib/ads/ad_rules.dart`).

**Advertising ID** (App content → Advertising ID): once google_mobile_ads is in
the build it adds `com.google.android.gms.permission.AD_ID` → answer **Yes**,
purposes: Advertising, Analytics (Google's), Fraud prevention. Before that
build: No.

---

## 5. Data safety form

General answers:
- Does the app collect or share any of the required user data types? **Yes**
- Is all user data encrypted in transit? **Yes** (HTTPS/TLS everywhere; WebRTC calls are encrypted; TURN is our own server)
- Do you provide a way for users to request deletion? **Yes** — in-app (Settings → Delete my account…) and https://lifeassisto.com/delete-account
- Independent security review: No. Families policy: not applicable (18+).

Not declared because they never leave the phone (Play exempts on-device-only
processing): Health Connect fitness data, wake-word audio, chat encryption keys.
Audio: not collected — the app has no audio upload today (voice typing uses the
phone's own speech service; calls are never recorded). If a voice-note or
server transcription feature ships later, add "Audio — Voice or sound recordings".
End-to-end encrypted personal/group text messages are also exempt (we cannot read them).

| Data type (Play category) | Collected | Shared | Ephemeral | Required / optional | Purposes |
|---|---|---|---|---|---|
| **Location — Approximate** | Yes | Yes* (AdMob, from IP) | No | Optional | App functionality (SOS, Safe Journey, nearby); *Advertising/Fraud prevention via AdMob |
| **Location — Precise** | Yes | No | No | Optional | App functionality (SOS, Safe Journey, anti-theft, trusted places, vehicle tracking) |
| Personal info — Name | Yes | No | No | Required | Account management, App functionality |
| Personal info — Email address | Yes | No | No | Optional (phone or email) | Account management |
| Personal info — Phone number | Yes | No** | No | Optional (phone or email) | Account management, Fraud prevention/security (OTP) |
| Personal info — User IDs | Yes | No | No | Required | Account management |
| Personal info — Other info (family members, emergency card) | Yes | No | No | Optional | App functionality |
| Financial info — Purchase history | Yes | No | No | Optional | Account management (plans/credits) |
| Financial info — Other financial info (ledger, budgets, loans you type) | Yes | No | No | Optional | App functionality |
| Health and fitness — Health info (prescriptions, medicines, dose logs you type) | Yes | No | No | Optional | App functionality |
| Messages — Other in-app messages (channels, communities, business inbox; NOT the E2E chats) | Yes | No | No | Optional | App functionality |
| Photos and videos — Photos / Videos | Yes | No | No | Optional | App functionality (vault, profile, status, Photo Studio, intruder photo, shop snapshots) |
| Files and docs | Yes | No | No | Optional | App functionality (vault) |
| Contacts | Yes | No | No | Optional | App functionality (personal CRM contacts you add; phonebook matching sends only salted hashes, non-users never stored) |
| App activity — App interactions | Yes | No | No | Optional (consent) | Analytics |
| App activity — Other user-generated content (notes, reminders, posts) | Yes | No | No | Required to use those features | App functionality |
| App info and performance — Crash logs | Yes | No | No | Required | App functionality (stability) |
| App info and performance — Diagnostics (app version, platform) | Yes | No | No | Required | App functionality |
| Device or other IDs (push token; Advertising ID via AdMob) | Yes | Yes* (AdMob) | No | Required (push) | App functionality, Developer communications (push); *Advertising, Fraud prevention |

\* Only once the AdMob build ships. Check Google's own
"Google Mobile Ads SDK — data disclosure" page when you fill this; declaring
more than the SDK needs is allowed, declaring less is a policy violation.
\** Phone numbers go to the SMS gateway only to deliver OTP/SMS on your behalf
(a service provider), which Play does not count as "sharing".

AI features: text/images go to AI providers (Anthropic, OpenAI, Google Gemini,
Replicate) as **service providers** processing on our behalf, so they are
"collected", not "shared", for the data types above.

---

## 6. Sensitive permissions — Play Console declarations & justifications

Each line matches `https://lifeassisto.com/privacy#permissions`.

| Permission | Console form? | Justification to paste |
|---|---|---|
| `USE_FULL_SCREEN_INTENT` | **Yes** (App content → Full-screen intent) | "Assisto has voice and video calling between family members. Full-screen intent is used only to show the incoming-call screen when the phone is locked, so the call can be answered. It is never used for ads or other notifications." Category: **Calling**. |
| `FOREGROUND_SERVICE_MICROPHONE` | **Yes** (App content → Foreground service permissions) | "Hands-free voice SOS and the optional 'Hey Assisto' wake word: the user switches it on; a persistent notification with Stop is shown while the microphone listens for the SOS phrase with the screen off. Wake-word audio is processed on device." Provide a short video: Settings → voice SOS → on → notification visible → Stop. |
| `FOREGROUND_SERVICE_LOCATION` | **Yes** (same form) | "During an active SOS started by the user, the foreground service sends the user's location to their trusted contacts until the SOS ends; a persistent notification is shown." |
| Health Connect reads (`READ_STEPS`, `READ_HEART_RATE`, `READ_SLEEP`, `READ_ACTIVE_CALORIES_BURNED`) | **Yes** (Health Connect permissions declaration + Health apps form) | "Shown only on the Smartwatch & Fitness screen as today's and 7-day summaries. Read-only, never uploaded to our servers, never used for ads, never shared." Needs proposal C (privacy-policy activity) in the build. |
| `ACTIVITY_RECOGNITION` | No form | Used with Health Connect step data. |
| `READ_CONTACTS` | No form (not restricted) — prominent disclosure required (built: Contacts screen explanation before the OS prompt) | "Find which contacts use Assisto. Numbers are hashed on the device; only hashes are sent; non-users are never stored; read-only." |
| `CALL_PHONE` | No form (not in the restricted call-log/SMS group) | "Places a call only after the user asks Assisto Voice to call someone and confirms." |
| Device admin (`BIND_DEVICE_ADMIN`, policies force-lock, limit-password, reset-password, watch-login) | No form; reviewed under the Device and Network Abuse / Permissions policy | "Anti-theft: lock a lost phone remotely, require a screen lock, detect wrong unlock attempts. User enables it on Android's consent screen; no wipe; can be deactivated in Settings → Security → Device admin apps." See proposal D.1 — consider dropping the deprecated password policies. |
| `BLUETOOTH_CONNECT` (+ legacy ≤ Android 11) | No form | "Connects to the user's already-paired ELM327 OBD-II car dongle. No scanning, no location from Bluetooth." |
| `CAMERA`, `RECORD_AUDIO`, location, photos/videos | No form | See privacy policy. No `ACCESS_BACKGROUND_LOCATION` is requested, so no background-location declaration is needed. |
| `BIND_VOICE_INTERACTION` | No form | Optional default-assistant role chosen by the user in Android settings. |
| `REQUEST_INSTALL_PACKAGES` | Would need a declaration and would very likely be refused | **Removed from the Play build** (proposal A). The website APK keeps it for its own updater. |
| `SET_ALARM`, `VIBRATE`, `WAKE_LOCK`, `RECEIVE_BOOT_COMPLETED`, network | No form | Normal permissions. |

Also in App content: **Government apps** No · **Financial features**: personal
finance tracking only · **Health**: see §3 · **Data safety**: §5 · **Ads**: §4 ·
**Target audience**: §3 · **Privacy policy**: URL above.

---

## 6b. app-ads.txt (AdMob)

- Served at https://lifeassisto.com/app-ads.txt by Django (no file to upload).
- Source of the publisher ID, first match wins: env `ADMOB_PUBLISHER_ID` →
  Owner panel → Integrations → Google AdMob → "Publisher ID" → derived from the
  saved real AdMob App ID (`ca-app-pub-XXXXXXXXXXXXXXXX~…` → `pub-XXXXXXXXXXXXXXXX`).
  You can paste the bare `pub-…`, the `ca-app-pub-…` form or the whole line.
  Google's public test publisher is never served.
- Once set, the file is exactly:
  `google.com, pub-XXXXXXXXXXXXXXXX, DIRECT, f08c47fec0942fa0`
- Until set, it is a valid file with comment lines only (`# …not configured
  yet`). That authorises no seller — honest. AdMob will show the app as
  "app-ads.txt: not verified / no matching entry" until you set the ID; ads can
  still serve meanwhile, but unverified inventory may get less demand.
- AdMob crawls the **developer website from the Play listing** (root domain),
  so the listing's Website must be `https://lifeassisto.com`. After setting the
  ID, AdMob → Apps → your app → app-ads.txt → "Check for updates" (it re-crawls
  within about a day).
- `robots.txt` does not block `/app-ads.txt`; `/sitemap.xml` lists the policy pages.

---

## 7. Before you press "Send for review"

1. Deploy this branch; set the §0 env vars; open the three URLs in a phone browser (bn + en).
2. Apply `.phaseB/proposals/l1-launch.md` A (+ C), get one green CI run, download `assisto-aab`.
3. Do Play App Signing (owner_actions/PLAY_APP_SIGNING.md).
4. Upload the AAB to **Internal testing** first; install from Play on the Realme 9i; check: opens, sign-in, notifications prompt, Settings shows no "Update" tile, About says "updates through Google Play", Settings → Legal → Privacy → "Read the full version on lifeassisto.com" opens the site.
5. Decide EEA/UK distribution (proposal D.5 — UMP consent is not built).
6. Fill §2–§6, then promote to Production.
