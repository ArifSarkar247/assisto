# মালিকের ঠিক-করার আদেশ — ৩ নভেম্বর ০২:৫৫ (আইটেম ১ রক্তদাতা + আইটেম ৩ হোম ও ডিসকভার)
শাখা: `agent/ownerfix` · মাইগ্রেশন: `0140_ownerfix` (লাইভ শেষ মাইগ্রেশন 0139_ledger2-এর পরে; ইন্টিগ্রেটর নম্বর বদলাতে পারেন)।
আইটেম ২ (ট্রেন বিজ্ঞাপন) অন্য এজেন্টের।

## যাচাই টেবিল — দাবি → কোডের প্রমাণ → ঠিক করা হয়েছে?
| # | দাবি (Claim) | কোডের প্রমাণ (Code proof) | অবস্থা |
|---|---|---|---|
| 1 | অ্যাপে রক্তদাতার **দুটো** ফিচার ছিল (Two blood donor features existed) | পুরনো `screens/blood_donor_screen.dart` (flag `blood_donor`, ON) + নতুন `screens/blood/blood_hub_screen.dart` (flag `blood_donors`, OFF) — দুটোই মেনুতে | **ঠিক** — পুরনো পর্দা মুছে ফেলা; মেনুতে শুধু প্যানেল (`sidebar_sections.dart`) |
| 2 | পুরনো দাতারা হারাবে না (Old donors are kept) | `0140_ownerfix.copy_legacy_donors` + `blood_panel.sync_legacy` → নতুন টেবিল `BloodSavedDonor`; ড্রাই-রান `legacy_plan` সংখ্যা দেয়; দুবার চালালেও দ্বিগুণ হয় না; পুরনো সারি রাখা হলো (পরে পরিষ্কার) | **ঠিক** — `tests_ownerfix.MigrationTests` |
| 3 | নতুন ফিচার মালিকের চূড়ান্ত নিয়মে (never hide, available nearest first, waiting by days left, paused shown, exact days, header counts, doctor line) | `blood_panel.search_full/sort_key/list_counts` (আগেই) + "আমার সেভ করা দাতা"-তে একই নিয়ম `blood_rules.saved_status/saved_sort_key` | **ঠিক** — `SavedApiTests`, `ownerfix_test.dart` |
| 4 | সব লিংক এক পর্দায় (home, Discover, emergency hub, menu, search, notifications, chat) | হোম টাইল `blood_panel`; Discover কার্ড `blood_donor`→`blood_panel`; জরুরি হাব `blood_panel`; মেনু/সার্চ এক এন্ট্রি; push `blood_panel` + পুরনো `blood_donor`/`blood` → প্যানেল; চ্যাট "রক্তদাতা/need blood" → `blood_panel` (`screen_synonyms.py`, `chatnav.dart`); পুরনো রুট `blood_donor` → একই প্যানেল। Agent Core-এ রক্তের কোনো টুল ছিল না (খোঁজা হয়েছে) | **ঠিক** |
| 5 | রক্তদাতায় কোনো বিজ্ঞাপন নয় (NO ads) | `'blood'` টোকেন আগেই never-list-এ; এখন প্রতিটি পর্দার নাম আলাদা লেখা (`ad_placements.dart`) + টেস্ট: কোনো blood ফাইলে বিজ্ঞাপন কোড নেই | **ঠিক** — `EntryPointTests.test_no_ads…`, `ownerfix_test.dart` |
| 6 | হোমে Emergency SOS = জরুরি হাব | Discover SOS কার্ড আগেই `emergency_hub`; কিন্তু হোমের **SOS টাইল পুরনো `EmergencyScreen` খুলত** | **ঠিক** — `HomeV2Shortcuts.openRoute('emergency')` → `emergency_hub` (সেভ করা টাইল নড়েনি) |
| 7 | রক্তদাতা SOS-এর ঠিক পাশে; স্পনসর কখনো SOS/রক্তদাতার পাশে নয় | `home_v2_shortcuts.ownerOrder` (emergency → blood_panel); `discover.separate_ads` + `separateDiscoverAds` | আগেই ঠিক ছিল; পুরনো রুট নামও সুরক্ষিত তালিকায় যোগ |
| 8 | Discover: SOS → ট্রেন → লাইভ লোকেশন → গন্তব্য অ্যালার্ম → বাকি | আগে: SOS, ট্রেন, তারপর পুরনো ক্রম ("নিরাপদ যাত্রা" ৫ নম্বরে, গন্তব্য অ্যালার্ম কার্ড **ছিলই না**) | **ঠিক** — মাইগ্রেশনে পুরনো "নিরাপদ যাত্রা" কার্ডের নাম "লাইভ লোকেশন" (মালিক নাম বদলালে ছোঁয়া হয় না), নতুন "গন্তব্য অ্যালার্ম" ও "রক্তদাতা" কার্ড; ব্যক্তিগত-সাজানো এদের পেছনে সরায় না |
| 9 | "সব সেবা" সব দেখায় | `all_services_screen.dart` মেনুর একই উৎস থেকে বানায় (ফ্ল্যাগ মেনে) | আগেই ঠিক; ছবি `home_v2_all_services_ownerfix` |
| 10 | মালিক নিজের কার্ড/বিজ্ঞাপন যোগ ও সাজাতে পারেন (Owner Admin → Discover) | `/owner/discover` (new, edit, toggle, delete, reorder ↑↓/drag) + অ্যাপ API `admin/discover/*` | কাজ করে — টেস্ট: মালিক সাজালে প্রথম কার্ড বদলায়, নতুন কার্ড যোগ হয় (`DiscoverOrderTests`) |
| 11 | মালিক ও টেস্টার লুকানো ফিচার দেখেন; সাধারণ ব্যবহারকারী রক্তদাতা দেখেন শুধু `blood_donors` চালু করলে | `feature_flags.resolve` (superuser/staff/allow-list = preview) | প্রমাণিত — `VisibilityTests` + `ownerfix_test.dart`। **কোনো ফ্ল্যাগের মান বদলানো হয়নি** (`blood_donors` এখনো OFF) |

## মালিকের সিদ্ধান্ত দরকার (১টি)
* হোমে বিনামূল্যের ব্যবহারকারীর **একটি নেটিভ বিজ্ঞাপন** শর্টকাট-গ্রিডের নিচে বসে। রক্তদাতা চালু হলে SOS + রক্তদাতা গ্রিডের শেষ সারিতে পড়ে — বিজ্ঞাপনটি তার নিচে (মাঝে ফাঁকা জায়গা আছে, কার্ডের পাশে নয়)। চাইলে: SOS/রক্তদাতা গ্রিডের প্রথম সারিতে আনা যায় (হোম ফ্রোজেন, তাই আপনার হুকুম লাগবে)।

## সৎ সীমা
* পুরনো অ্যাপ (আপডেট না করা ফোন) পুরনো তালিকায় **নতুন** দাতা যোগ করলে প্যানেল খুললে সেটা চলে আসে; কিন্তু পুরনো অ্যাপে **পুরনো দাতা বদলালে** সেই বদল আসে না (প্রথম কপিই থাকে)।
* পুরনো ফ্ল্যাগ `blood_donor` (ON) সার্ভারে থাকল — অ্যাপে আর কিছু খোলে না; মান বদলানো হয়নি (আপনার নিয়ম)।
* আসল দুই-ফোন টেস্ট বাকি (নিচে)।

## দুই-ফোনে মালিকের পরীক্ষা (১০ মিনিট)
1. ফোন-ক (মালিক): মেনু → "রক্তদাতা প্যানেল" — একটাই এন্ট্রি, "প্রিভিউ" ট্যাগসহ। "খুঁজুন" ট্যাব → "আমার সেভ করা দাতা" → আগের তালিকার দাতারা আছেন ("আগের তালিকা থেকে")।
2. "দাতা যোগ করুন" → আমার সার্কেল থেকে একজন → গ্রুপ → সেভ। তালিকায়: এখনই-পারবেন আগে, অপেক্ষার দাতা "আর N দিন", বিরতি শেষে।
3. ফোন-খ (সাধারণ ব্যবহারকারী): মেনুতে রক্তদাতা **নেই**, Discover-এ নেই। Owner Admin → Features → `blood_donors` চালু → অ্যাপ আবার খুলুন → মেনু, হোমে SOS-এর পাশে, Discover-এ আছে।
4. হোম → "জরুরি SOS" টাইল → জরুরি হাব খোলে (SOS বোতাম সবার উপরে)।
5. Discover: SOS, ট্রেন, লাইভ লোকেশন, গন্তব্য অ্যালার্ম ক্রমে (ফ্ল্যাগ চালু থাকলে)। Owner Admin → Discover → একটি কার্ড ↑ করুন → অ্যাপে ক্রম বদলায়।
6. চ্যাটে লিখুন "রক্ত লাগবে" → প্যানেল খোলে। কোথাও বিজ্ঞাপন নেই।

## প্রমাণ (CI)
ব্যাকএন্ড: `backend/core/tests_ownerfix.py` · অ্যাপ: `app/test/ownerfix_test.dart` · গ্যালারি ছবি (bn+en, আলো+অন্ধকার): `blood_saved`, `blood_saved_empty`, `blood_hub`, `home_v2_ownerfix`, `home_v2_all_services_ownerfix` (CI artifacts `shots-*`)।
