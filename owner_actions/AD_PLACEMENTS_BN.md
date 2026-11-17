# বিজ্ঞাপনের সব জায়গা ও সব স্ক্রিন — তালিকা (adcontrol, মালিকের চূড়ান্ত আদেশ ১০ নভেম্বর ০৩:৪৫)

শাখা `agent/adcontrol`। **কোথায় বদলাবেন:** Owner Admin → **বিজ্ঞাপন নিয়ন্ত্রণ** (`/owner/ad-control`)। প্রতিটি জায়গা চালু/বন্ধ ও ধরন (banner, native, interstitial, rewarded, app open — শুধু যেটা ওই জায়গায় মানায়) বদলানো যায়; নতুন বিল্ড লাগে না — অ্যাপ খোলার সময় ও প্রতিবার ফিরে এলে (৫ মিনিটের পুরনো হলে) নতুন সেটিং পড়ে।

**নিয়ম (সব জায়গায়):** AdMob শুধু **ফ্রি** ব্যবহারকারী — Premium, Plus, Business কখনো নয়; শিশু অ্যাকাউন্টে কখনো নয়। ডিসকভার/ব্র্যান্ড কার্ড (আপনি সরাসরি বিক্রি করেন, "Ad" লেখা) সবাই দেখেন। পূর্ণ পর্দার বিজ্ঞাপন: দুটির মাঝে কমপক্ষে ৩ মিনিট, দিনে সর্বোচ্চ ৬ (আপনি ০–১২ বদলাতে পারেন), প্রথম দিনে নয়। App open: শুধু আগে থেকে লোড থাকলে, অ্যাপ খোলায় কখনো দেরি নয়, প্রথমবার খোলা/লগইন/নোটিফিকেশন থেকে খোলায় নয়। ⚠ = জরুরি/নিরাপত্তা/আস্থার পাতা — ডিফল্ট বন্ধ; চালু করতে গেলে "আপনি কি নিশ্চিত?" সতর্কতা আসে; সার্ভারে পৌঁছাতে না পারলে বন্ধই থাকে।

## ১. প্রতিটি বিজ্ঞাপনের জায়গা (রেজিস্ট্রি — ৭৭ টি)

### হোম, ডিসকভার ও সব সেবা

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| হোম — নেটিভ কার্ড (আগের মতো) | `home` | চালু native | native | `screens/home_screen.dart`, `screens/home_v2/home_v2_screen.dart`, `widgets/home_hero.dart` |
| ডিসকভার — তালিকায় AdMob নেটিভ | `discover_native` | চালু native | native | লাগানো (adwire) — নিচে ৩ দেখুন |
| অ্যাপ খোলার বিজ্ঞাপন | `app_open` | চালু app_open | app_open | `ads/ads_service.dart` (হোমের ওপর, ফিরে আসার সময়) |
| সব সেবা — নেটিভ | `all_services` | চালু native | banner, native | `screens/home_v2/all_services_screen.dart` |
| লেখা পড়া শেষে ফিরে যাওয়ার সময় | `article_after_read` | চালু interstitial | interstitial | `screens/daily_brief_screen.dart`, `screens/unseen_world_screen.dart` |

### মাই সার্কেল ও কল

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| মাই সার্কেল চ্যাট তালিকা — ব্যানার (আগের মতো) | `circle_list` | চালু banner | banner, native | `screens/messenger/messenger_home_screen.dart` |
| কল শেষের রিভিউ কার্ড — নেটিভ | `after_call_review` | চালু native | banner, native | লাগানো (adwire) — নিচে ৩ দেখুন |

### এআই চ্যাট

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| এআই চ্যাট — বিজ্ঞাপন দেখে উত্তর খুলুন | `ai_chat_unlock` | চালু rewarded | rewarded | লাগানো (adwire) — নিচে ৩ দেখুন |

### ফটো স্টুডিও

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| ফটো স্টুডিও — বিজ্ঞাপন দেখে খুলুন | `photo_studio` | চালু rewarded | rewarded | `photo_studio/ps_export.dart` + সার্ভারে টিকিট বন্ধ (`photo_studio_service.py`) |
| ফটো সেভের পর — পূর্ণ পর্দা | `photo_after_save` | চালু interstitial | interstitial | `photo_studio/ps_controller.dart`, `screens/photo_studio_screen.dart` |
| ফটো স্টুডিও শুরুর পাতা — ব্যানার | `photo_gallery` | চালু banner | banner, native | `screens/photo_studio_screen.dart` |

### ল্যাঙ্গুয়েজ পার্টনার

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| ল্যাঙ্গুয়েজ পার্টনার — ব্যানার | `lp_home` | চালু banner | banner, native | `screens/language_partner_screen.dart` |
| ল্যাঙ্গুয়েজ পার্টনার IELTS হাব — ব্যানার | `lp_hub` | চালু banner | banner, native | `screens/lp2/` (lpapp শাখা) |
| ল্যাঙ্গুয়েজ পার্টনার জীবনের পরিস্থিতি তালিকা — ব্যানার | `lp_life` | চালু banner | banner, native | `screens/lp2/` (lpapp শাখা) |
| ল্যাঙ্গুয়েজ পার্টনার শব্দভান্ডার — ব্যানার | `lp_vocab` | চালু banner | banner, native | `screens/lp2/lp_vocab.dart` (lpapp শাখা) |
| পাঠ শেষে — পূর্ণ পর্দা | `lesson_after_finish` | চালু interstitial | interstitial | `screens/language_partner_screen.dart` |
| ল্যাঙ্গুয়েজ পার্টনার — বিজ্ঞাপন দেখে খুলুন | `lp_unlock` | চালু rewarded | rewarded | সার্ভারে টিকিট (`lp_service.py`); অ্যাপের বোতাম — lpapp শাখা |

### পরীক্ষা ও ছাত্র কর্নার

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| পরীক্ষা জমার পর, ফলাফলের আগে — একটি পূর্ণ পর্দা | `exam_after_submit` | চালু interstitial | interstitial | `screens/language_pack_screen.dart` |
| পরীক্ষার ফলাফল পাতা — ব্যানার | `exam` | চালু banner | banner, native | `screens/exam_result_screen.dart` |
| ছাত্র কর্নার অনুশীলনের পর | `student_after_practice` | চালু interstitial | interstitial | `screens/student_corner_screen.dart` |

### হিসাব ও অর্থ

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| হিসাব ও অর্থ মূল পাতা — নেটিভ কার্ড | `finance_home` | চালু native | banner, native | `screens/money_screen.dart` |
| লেনদেনের তালিকা — প্রতি ১৫–২০ সারিতে নেটিভ | `finance_list` | চালু native | native | `screens/money_screen.dart` |
| রিপোর্ট — নিচে নেটিভ | `finance_reports` | চালু native | banner, native | `screens/money_report_screen.dart` |
| PDF রপ্তানি বা শেয়ারের পর — পূর্ণ পর্দা | `finance_after_export` | চালু interstitial | interstitial | `screens/money_report_screen.dart` |
| মাস শেষের পূর্ণ রিপোর্ট — পূর্ণ পর্দা | `finance_month_report` | চালু interstitial | interstitial | `screens/money_report_screen.dart` |

### মেস

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| মেস — ব্যানার | `mess_home` | চালু banner | banner, native | `screens/mess/mess_ad.dart` (messv2) |
| মেস তালিকা — নেটিভ | `mess_list` | চালু native | native | messv2-এর মেস স্ক্রিন — ইন্টিগ্রেশন b318 |
| মেসের মাস শেষের রিপোর্ট — পূর্ণ পর্দা | `mess_month_report` | চালু interstitial | interstitial | messv2-এর মাস শেষের রিপোর্ট — ইন্টিগ্রেশন b318 (০৩:৪৫ আদেশ আগের সব বিজ্ঞাপন-আদেশ বাতিল করে) |

### নোট, কাজ ও রিমাইন্ডার

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| নোট ও কাজ — ব্যানার | `notes_home` | চালু banner | banner, native | `screens/notes_todos_screen.dart` |
| নোট ও কাজের তালিকা — নেটিভ | `notes_list` | চালু native | native | `screens/notes_todos_screen.dart` |
| রিমাইন্ডার তালিকা — ব্যানার | `reminders_list` | চালু banner | banner, native | `screens/reminders_screen.dart` |
| জন্মদিন — ব্যানার | `birthdays` | চালু banner | banner, native | `screens/birthdays_screen.dart` |
| মিটিং — ব্যানার | `meetings` | চালু banner | banner, native | `screens/meetings_screen.dart` |

### সিটি সার্ভিস ও কাছাকাছি

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| সিটি সার্ভিস খোঁজা ও ফলাফল — ব্যানার | `city_search` | চালু banner | banner, native | `screens/city/city_service_screen.dart` |
| সিটি সার্ভিস ফলাফল — নেটিভ | `city_results` | চালু native | native | `screens/city/city_service_screen.dart` |
| আরও পথ (Google) — বিজ্ঞাপন দেখে | `city_more_routes` | চালু rewarded | rewarded | লাগানো (adwire) — নিচে ৩ দেখুন |
| কাছাকাছি — ব্যানার (আগের মতো) | `nearby` | চালু banner | banner, native | `screens/nearby_screen.dart` |

### ট্রেন ট্র্যাকার

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| ট্রেন খোঁজা — ব্যানার | `train_search` | চালু banner | banner, native | `screens/train/train_tracker_screen.dart` |
| ট্রেনের বিস্তারিত — ব্যানার | `train_detail` | চালু banner | banner, native | `screens/train/train_tracker_screen.dart` |
| ট্রেনের লাইভ অবস্থান — বিজ্ঞাপন দেখে, তারপর ১৫ মিনিট ফ্রি | `train_live_unlock` | চালু rewarded | rewarded | `screens/train/train_tracker_screen.dart` |

### নিরাপত্তা ফিচার

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| নিরাপত্তা ফিচার চালু — একবার বিজ্ঞাপন, তারপর চিরকাল ফ্রি | `security_unlock` | চালু rewarded | rewarded | `widgets/chatnav.dart` |
| প্রতি স্ক্যান বা নম্বর যাচাই — একটি বিজ্ঞাপন | `security_scan` | চালু rewarded | rewarded | `screens/scam_screen.dart`, `screens/used_phone_check_screen.dart` |

### অফার, কুপন ও মার্কেট

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| অফার, কুপন ও মার্কেট — নেটিভ | `offers_list` | চালু native | native | `screens/offers_screens.dart` |
| ক্রেডিট পেতে বিজ্ঞাপন (ব্যবহারকারী নিজে চাইলে) | `credits` | চালু rewarded | rewarded | `widgets/rewarded_ad_sheet.dart`, `screens/credits_screen.dart` |

### কাজ, সিভি ও টুলস

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| সংরক্ষিত — ব্যানার | `saved_items` | চালু banner | banner, native | `screens/saved_items_screen.dart` |
| অভিধান — ব্যানার | `dictionary` | চালু banner | banner, native | `screens/dictionary_screen.dart` |
| চাকরি — ব্যানার | `jobs` | চালু banner | banner, native | `screens/jobs_screen.dart` |
| সিভি বিল্ডার — ব্যানার | `cv_builder` | চালু banner | banner, native | `screens/cv_builder_screen.dart` |
| চুক্তি যাচাই — ব্যানার | `contract` | চালু banner | banner, native | `screens/contract_analyzer_screen.dart` |
| সেবা গাইড — ব্যানার | `guide` | চালু banner | banner, native | `screens/guide_screen.dart` |
| কুইক টুলস — ব্যানার | `quick_tools` | চালু banner | banner, native | `screens/quick_tools_screen.dart` |
| সেটিংস তালিকা — ব্যানার | `settings` | চালু banner | banner, native | `screens/settings_screen.dart` |
| ডকুমেন্ট স্ক্যান সেভের পর | `scan_after_save` | চালু interstitial | interstitial | `screens/contract_analyzer_screen.dart`, `screens/doc_scanner_screen.dart` |
| সিভি ডাউনলোডের পর | `cv_after_download` | চালু interstitial | interstitial | `screens/cv_builder_screen.dart` |
| মক ইন্টারভিউ ফিডব্যাকের পর | `interview_after_feedback` | চালু interstitial | interstitial | `screens/mock_interview_screen.dart` |
| চাকরিতে আবেদনের পর | `job_after_apply` | চালু interstitial | interstitial | **এখনো লাগানো হয়নি** — নিচে ৩ দেখুন |
| ভ্রমণ/অনুষ্ঠান পরিকল্পনা সেভের পর | `plan_after_save` | চালু interstitial | interstitial | `screens/travel_planner_screen.dart`, `screens/wedding_events_screen.dart` |
| খরচ হিসাব/সেবা গাইড শেষে | `estimate_after_finish` | চালু interstitial | interstitial | `screens/cost_estimator_screen.dart`, `screens/guide_screen.dart` |
| কুইক টুল ব্যবহারের পর (দিনে ১ বার) | `quick_tool_exit` | চালু interstitial | interstitial | `screens/quick_tools_screen.dart` |

### জরুরি, নিরাপত্তা ও আস্থা (ডিফল্ট বন্ধ)

| জায়গা | key | ডিফল্ট | যে ধরন বেছে নেওয়া যায় | কোডে কোথায় |
|---|---|---|---|---|
| ⚠ SOS ও জরুরি | `sos` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ চলমান সেফ জার্নি ও এর সতর্কতা | `safe_journey_active` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ ফ্যামিলি কেয়ার (বয়স্কদের সহজ হোমসহ) | `family_care` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ রক্তদাতা (সব পাতা) | `blood_donor` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ কেয়ার কল | `care_call` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ কুরআন ও কুরআন শিখি | `quran` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ শিশুদের অ্যাকাউন্ট | `child_accounts` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ চ্যাটের ভেতরে ও কলের সময় | `chats_calls` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ রিমাইন্ডার অ্যালার্ম বাজার মুহূর্ত | `reminder_alarm` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ হারানো ফোন (লস্ট মোড) | `lost_mode` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ পেমেন্টের পাতা | `payment` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ প্রথমবার খোলা ও লগইন | `first_launch_login` | বন্ধ banner | banner, native, interstitial, app_open | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ সময় ধরা পরীক্ষা, লিসেনিং অডিও, স্পিকিং রেকর্ডিং চলাকালে | `timed_test` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ সার্টিফিকেট | `certificates` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ হিসাব/খাতায় এন্ট্রি যোগ বা সম্পাদনার ফর্ম | `finance_forms` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ খোলা এআই চ্যাট (কথোপকথনের ভেতরে) | `ai_chat_open` | বন্ধ banner | banner, native | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ সিটি সার্ভিস নেভিগেশন ও গন্তব্য অ্যালার্ম | `city_navigation` | বন্ধ banner | banner, native, interstitial | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |
| ⚠ আত্মীয়ের চলমান ট্রেন যাত্রা দেখা | `train_family_watch` | বন্ধ banner | banner, native, rewarded | — (নিয়ম/বন্ধ; কোডে কোনো বিজ্ঞাপন নেই) |

## ৩. যা এখনো লাগানো হয়নি (সৎ তালিকা)

**দুই ফোনে মালিকের পরীক্ষা (adwire):** (১) ফ্রি ফোনে এআই-র ক্রেডিট শেষ → "N টি বিজ্ঞাপন দেখুন" সারি আছে; Owner Admin-এ `ai_chat_unlock` বন্ধ করুন → অ্যাপ খুলে আবার দেখুন, সারি নেই; প্রিমিয়াম ফোনে কখনো নেই। (২) দুই ফোনে My Circle কল ১০ সেকেন্ডের বেশি → রেটিং দিন → ফ্রি ফোনে নেটিভ কার্ড, প্রিমিয়ামে নেই; ৫ সেকেন্ডের কল/মিসড কল/Care Call-এ কখনো নেই। (৩) সিটি সার্ভিসে রুট খুঁজুন → নিচে "আরও রুট (Google)" → ফ্রি ফোনে ছোট বিজ্ঞাপন, তারপর Google রুট; প্রিমিয়ামে সরাসরি রুট। (৪) হোম ডিসকভারে AdMob কার্ড; `discover_native` বন্ধ করলে চলে যায়।

| key | কেন বাকি | কে/কখন |
|---|---|---|
| ~~`discover_native`~~ | **লাগানো (adwire)**: ডিসকভারের AdMob জায়গা এখন রেজিস্ট্রির `discover_native` সুইচ পড়ে; সার্ভার সুইচ না পাঠালে (পুরনো সার্ভার) রেজিস্ট্রির ডিফল্ট চালু, সুইচ-তালিকায় key না থাকলে বন্ধ; ধরন native না হলে বিজ্ঞাপন নেই | — |
| ~~`after_call_review`~~ | **লাগানো (adwire)**: কল শেষের রেটিং-সারির নিচে নেটিভ কার্ড; রেটিং দিলে পাতা বিজ্ঞাপন লোড/ব্যর্থ হওয়া পর্যন্ত খোলা থাকে (দেখালে ৮ সেকেন্ড)। কখনো নয়: SOS/জরুরি/শিশুর জরুরি শোনা/Care Call কল, ১০ সেকেন্ডের কম, মিসড/প্রত্যাখ্যাত/ব্যস্ত/কেটে যাওয়া কল | — |
| ~~`city_more_routes`~~ | **লাগানো (adwire)**: সিটি সার্ভিসের ফলাফলে "আরও রুট (Google)" বোতাম; ফ্রি: ১টি পুরস্কার-বিজ্ঞাপন = ১টি Google ট্রানজিট অনুরোধ; প্রিমিয়াম/প্লাস: বিজ্ঞাপন ছাড়াই; Google বাজেট শেষ হলে বোতামই দেখায় না (কোনো সীমা-বার্তা নেই) | — |
| ~~`ai_chat_unlock`~~ | **লাগানো (adwire)**: এআই চ্যাটের "N টি বিজ্ঞাপন দেখে ১ টি উত্তর" শিট এই key-তে চলে; সার্ভার টিকিট দেওয়ার আগে সুইচ আবার দেখে (বন্ধ থাকলে "এখানে এখন কোনো বিজ্ঞাপন নেই") | — |
| `job_after_apply` | পুরনো (২ নভেম্বর) জায়গা; চাকরির আবেদনের নিশ্চিত-পাতা এখনো নেই | চাকরি অংশ |

## ২. অ্যাপের প্রতিটি স্ক্রিন — কোথায় বিজ্ঞাপন আছে

মেনু/চ্যাট থেকে খোলা যায় এমন রুট: ১২৩ টি; স্ক্রিন ফাইল: ৪৩৪ টি। "—" = এই স্ক্রিনে কোনো AdMob বিজ্ঞাপন নেই (রেজিস্ট্রির বাইরে কোনো স্ক্রিন বিজ্ঞাপন দেখাতে পারে না — CI পরীক্ষা `adcontrol_test`).

### ২ক. মেনু রুট → স্ক্রিন

| রুট | স্ক্রিন | বিজ্ঞাপন |
|---|---|---|
| `money` | MoneyScreen | finance_home, finance_list |
| `documents` | VaultScreen | — |
| `family` | FamilyEntry | — |
| `family_alerts` | FamilyAlertsScreen | — |
| `carecall` | CareCallScreen | — |
| `elder_watch` | ElderWatchScreen | — |
| `reminders` | RemindersScreen | reminders_list |
| `vehicles` | MyVehiclesScreen | — |
| `vehicle_tracking` | VehicleTrackingScreen | — |
| `car_mode` | CarModeScreen | — |
| `kids_watch` | KidsWatchScreen | — |
| `train_tracker` | TrainTrackerScreen | train_detail, train_live_unlock, train_search |
| `dest_alarm` | DestAlarmScreen | — |
| `school_mode` | SchoolModeChildScreen | — |
| `missing_alert` | MissingHubScreen | — |
| `blood_panel` | BloodHubScreen | — |
| `blood_donor` | BloodHubScreen | — |
| `kid_audio` | KidAudioScreen | — |
| `emergency` | EmergencyScreen | — |
| `emergency_hub` | EmergencyHubScreen | — |
| `plans` | PlansScreen | — |
| `offers` | OffersFeedScreen | offers_list |
| `scam` | ScamScreen | security_scan + security_unlock (একবার) |
| `safety` | SafetyScreen | — |
| `voice_sos` | VoiceSosScreen | — |
| `crm` | CrmHomeScreen | — |
| `medicine_db` | MedicineDbScreen | — |
| `health_tips` | HealthTipsScreen | — |
| `birthdays` | BirthdaysScreen | birthdays |
| `meetings` | MeetingsScreen | meetings |
| `dictionary` | DictionaryScreen | dictionary |
| `ride_food` | RideFoodScreen | — |
| `fall_detect` | FallDetectScreen | — |
| `lost_stolen` | LostStolenScreen | — |
| `my_lost_phone` | MyLostPhoneScreen | — |
| `watched_phones` | WatchedPhonesScreen | — |
| `recovery` | RecoveryScreen | — |
| `phone_safety` | PhoneSafetyScreen | — + security_unlock (একবার) |
| `security` | SecurityScreen | — + security_unlock (একবার) |
| `used_phone_check` | UsedPhoneCheckScreen | security_scan |
| `sell_phone` | SellMyPhoneScreen | — + security_unlock (একবার) |
| `shop_box` | ShopBoxScreen | — |
| `watchman` | WatchmanScreen | — |
| `watchman_inbox` | GuardInboxScreen | — |
| `watchman_sos_live` | SosLiveScreen | — |
| `booking` | BookingBizScreen | — |
| `my_bookings` | MyBookingsScreen | — |
| `retention_auto` | RetentionScreen | — |
| `retention_inbox` | RetentionInboxScreen | — |
| `marketing_engine` | MktEngineScreen | — |
| `biz_daily` | BizDailyScreen | — |
| `analytics` | OwnerAnalyticsScreen | — |
| `name_about` | NameAboutScreen | — |
| `ramadan` | RamadanScreen | — |
| `quran` | QuranScreen | — |
| `quran_learn` | QuranLearnScreen | — |
| `exam` | ExamResultScreen | exam |
| `task_manager` | TaskManagerScreen | — |
| `day_planner` | DayPlannerScreen | — |
| `unseen` | UnseenWorldScreen | article_after_read |
| `daily_today` | WorldTodayScreen | — |
| `photo_enhance` | PhotoStudioScreen | photo_after_save, photo_gallery |
| `photo_studio` | PhotoStudioScreen | photo_after_save, photo_gallery |
| `circle` | MessengerHomeScreen | circle_list |
| `circle_add` | MessengerHomeScreen | circle_list |
| `messages` | MessengerHomeScreen | circle_list |
| `channels` | MessengerHomeScreen | circle_list |
| `communities` | MessengerHomeScreen | circle_list |
| `notifications` | NotificationCentreScreen | — |
| `groups` | CircleScreen | — |
| `status` | CircleScreen | — |
| `legal` | LegalScreen | — |
| `subscriptions` | SubscriptionsScreen | — |
| `finance` | FinanceScreen | — |
| `payment_ladder` | PaymentLadderScreen | — |
| `notes` | NotesTodosScreen | notes_home, notes_list |
| `memory` | MemoryScreen | — |
| `nominee` | NomineeScreen | — |
| `contacts` | CrmContactsScreen | — |
| `agent_core` | AgentCoreScreen | — |
| `agent_approvals` | AgentApprovalsScreen | — |
| `jobs` | JobsScreen | jobs |
| `cv` | CvBuilderScreen | cv_after_download, cv_builder |
| `resume` | CvBuilderScreen | cv_after_download, cv_builder |
| `inbox` | InboxScreen | — |
| `guide` | GuideScreen | estimate_after_finish, guide |
| `nearby` | NearbyScreen | nearby |
| `city` | CityServiceScreen | city_results, city_search |
| `watch_feed` | WatchFeedScreen | — |
| `account_standing` | AccountStandingScreen | — |
| `business` | BusinessScreen | — |
| `bargain_rules` | BargainRulesScreen | — |
| `business_plans` | BusinessPlansScreen | — |
| `journey` | SafeJourneyHubScreen | — |
| `journey_watch` | JourneyWatchScreen | — |
| `journey_settings` | JourneySettingsScreen | — |
| `journey_requests` | GuardianJourneyScreen | — |
| `guardians` | CircleGuardiansScreen | — |
| `referral` | ReferralScreen | — |
| `circle_privacy` | CirclePrivacyScreen | — |
| `circle_calls` | CircleCallHistoryScreen | — |
| `action_center` | ActionCenterScreen | — |
| `disaster` | DisasterAlertsScreen | — |
| `offline` | OfflineStatusScreen | — |
| `budget` | MoneyBudgetScreen | — |
| `remittance` | RemittanceScreen | — |
| `probashi_plan` | ProbashiPlanScreen | — |
| `market` | MarketScreen | — |
| `safe_plans` | SafePlansScreen | — |
| `tax` | MoneyTaxScreen | — |
| `wrapped` | MoneyWrappedScreen | — |
| `money_voice` | MoneyVoiceScreen | — |
| `ai_chat` | AssistoChatsScreen | — |
| `voice_assistant` | VoiceAssistantScreen | — |
| `voice_settings` | VoiceAssistantSettingsScreen | — |
| `feedback` | FeedbackScreen | — |
| `khata` | KhataEntryScreen | — |
| `books` | BooksScreen | — |
| `acct` | AcctHomeScreen | — |
| `sales_agent` | SellerAgentScreen | — |
| `prepaid_meter` | PrepaidMeterScreen | — |
| `contract` | ContractAnalyzerScreen | contract, scan_after_save |
| `my_dues` | MyDuesScreen | — |

### ২খ. সব স্ক্রিন ফাইল

| ফাইল | বিজ্ঞাপন (registry key) |
|---|---|
| `eldercare/are_you_ok_screen.dart` | — |
| `eldercare/elder_join_screen.dart` | — |
| `eldercare/elder_setup_screen.dart` | — |
| `eldercare/elder_watch_screen.dart` | — |
| `billing/cctv_plan_screen.dart` | — |
| `billing/refund_screen.dart` | — |
| `push/incoming_call_screen.dart` | — |
| `push/push_settings_screen.dart` | — |
| `widgets/chatnav.dart` | security_unlock |
| `widgets/home_hero.dart` | home |
| `cctvconnect/cctv_connect_screen.dart` | — |
| `cctvconnect/link_devices_screen.dart` | — |
| `photo_studio/ps_controller.dart` | photo_after_save |
| `quran_learn/quran_learn_screen.dart` | — |
| `notiflisten/callmoney_screens.dart` | — |
| `growth/invite_screen.dart` | — |
| `vault/vault_e2e_screen.dart` | — |
| `vault/vault_recovery_screen.dart` | — |
| `vault/vault_security_screen.dart` | — |
| `screens/about_screen.dart` | — |
| `screens/accessibility_mode_screen.dart` | — |
| `screens/account_recovery_screens.dart` | — |
| `screens/account_security_screen.dart` | — |
| `screens/account_standing_screen.dart` | — |
| `screens/action_center_screen.dart` | — |
| `screens/agent_studio_screen.dart` | — |
| `screens/agent_thread_screen.dart` | — |
| `screens/ai_chat_screen.dart` | — |
| `screens/ai_knowledge_screen.dart` | — |
| `screens/always_on_protection_screen.dart` | — |
| `screens/app_update_screen.dart` | — |
| `screens/area_community_screen.dart` | — |
| `screens/assisto_chats_screen.dart` | — |
| `screens/battery_guidance_screen.dart` | — |
| `screens/birthdays_screen.dart` | birthdays |
| `screens/blog_writer_screen.dart` | — |
| `screens/business_screen.dart` | — |
| `screens/car_mode_screen.dart` | — |
| `screens/circle_call_history_screen.dart` | — |
| `screens/circle_call_info_screen.dart` | — |
| `screens/circle_call_screen.dart` | — |
| `screens/circle_chat_screen.dart` | — |
| `screens/circle_extras_broadcast_screen.dart` | — |
| `screens/circle_extras_hub_screen.dart` | — |
| `screens/circle_extras_scheduled_screen.dart` | — |
| `screens/circle_group_chat_screen.dart` | — |
| `screens/circle_group_info_screen.dart` | — |
| `screens/circle_group_list_screen.dart` | — |
| `screens/circle_guardians_screen.dart` | — |
| `screens/circle_privacy_screen.dart` | — |
| `screens/circle_screen.dart` | — |
| `screens/circle_search_screen.dart` | — |
| `screens/circle_status_composer_screen.dart` | — |
| `screens/circle_status_screen.dart` | — |
| `screens/circle_status_viewer_screen.dart` | — |
| `screens/contract_analyzer_screen.dart` | contract, scan_after_save |
| `screens/cost_estimator_screen.dart` | estimate_after_finish |
| `screens/credits_screen.dart` | — |
| `screens/crm_contacts_screen.dart` | — |
| `screens/cv_builder_screen.dart` | cv_after_download, cv_builder |
| `screens/daily_brief_screen.dart` | article_after_read |
| `screens/daily_challenges_screen.dart` | — |
| `screens/daily_tools_screen.dart` | — |
| `screens/day_planner_screen.dart` | — |
| `screens/delete_account_screen.dart` | — |
| `screens/deletion_grace_screen.dart` | — |
| `screens/dictionary_screen.dart` | dictionary |
| `screens/disaster_alerts_screen.dart` | — |
| `screens/doc_scanner_screen.dart` | scan_after_save |
| `screens/doctor_serial_screen.dart` | — |
| `screens/domestic_staff_screen.dart` | — |
| `screens/e2_restore_screen.dart` | — |
| `screens/elderly_home_screen.dart` | — |
| `screens/emergency_hub_screen.dart` | — |
| `screens/emergency_screen.dart` | — |
| `screens/encrypted_backup_screen.dart` | — |
| `screens/exam_result_screen.dart` | exam |
| `screens/expense_split_screen.dart` | — |
| `screens/fall_detect_screen.dart` | — |
| `screens/family_alerts_screen.dart` | — |
| `screens/family_screen.dart` | — |
| `screens/farmer_mode_screen.dart` | — |
| `screens/finance_screen.dart` | — |
| `screens/fitness_partner_screen.dart` | — |
| `screens/fleet_dashboard_screen.dart` | — |
| `screens/food_calories_screen.dart` | — |
| `screens/guardian_journey_screen.dart` | — |
| `screens/guardian_request_screen.dart` | — |
| `screens/guide_screen.dart` | estimate_after_finish, guide |
| `screens/health_timeline_screen.dart` | — |
| `screens/health_tips_screen.dart` | — |
| `screens/home_screen.dart` | home |
| `screens/ielts_screen.dart` | — |
| `screens/in_progress_screen.dart` | — |
| `screens/inbox_screen.dart` | — |
| `screens/intruder_consent_screen.dart` | — |
| `screens/jobs_screen.dart` | jobs |
| `screens/journey_fake_call_screen.dart` | — |
| `screens/journey_live_screen.dart` | — |
| `screens/journey_map_pick_screen.dart` | — |
| `screens/journey_settings_screen.dart` | — |
| `screens/journey_sos_screen.dart` | — |
| `screens/journey_start_screen.dart` | — |
| `screens/journey_watch_screen.dart` | — |
| `screens/kid_school_screen.dart` | — |
| `screens/landlord_tenant_screen.dart` | — |
| `screens/language_pack_screen.dart` | exam_after_submit |
| `screens/language_partner_screen.dart` | lesson_after_finish, lp_home |
| `screens/language_picker_screen.dart` | — |
| `screens/learn_cert_screen.dart` | — |
| `screens/legal_screen.dart` | — |
| `screens/login_screen.dart` | — |
| `screens/lost_stolen_screen.dart` | — |
| `screens/medicine_db_screen.dart` | — |
| `screens/medicine_history_screen.dart` | — |
| `screens/meetings_screen.dart` | meetings |
| `screens/memory_screen.dart` | — |
| `screens/mess_accounting_screen.dart` | — (messv2-এর নতুন মেস স্ক্রিন এর জায়গা নিয়েছে) |
| `screens/mock_interview_screen.dart` | interview_after_feedback |
| `screens/money_budget_screen.dart` | — |
| `screens/money_import_screen.dart` | — |
| `screens/money_loan_detail_screen.dart` | — |
| `screens/money_networth_screen.dart` | — |
| `screens/money_report_screen.dart` | finance_after_export, finance_month_report, finance_reports |
| `screens/money_screen.dart` | finance_home, finance_list |
| `screens/money_tax_screen.dart` | — |
| `screens/money_trends_screen.dart` | — |
| `screens/money_voice_screen.dart` | — |
| `screens/money_wrapped_screen.dart` | — |
| `screens/my_dues_screen.dart` | — |
| `screens/my_dues_shop_screen.dart` | — |
| `screens/my_lost_phone_screen.dart` | — |
| `screens/my_vehicles_screen.dart` | — |
| `screens/name_about_screen.dart` | — |
| `screens/nearby_screen.dart` | nearby |
| `screens/nominee_screen.dart` | — |
| `screens/notes_todos_screen.dart` | notes_home, notes_list |
| `screens/notification_centre_screen.dart` | — |
| `screens/offers_screens.dart` | offers_list |
| `screens/offline_status_screen.dart` | — |
| `screens/onboarding_screen.dart` | — |
| `screens/owner_analytics_screen.dart` | — |
| `screens/password_reset_confirm_screen.dart` | — |
| `screens/password_reset_screen.dart` | — |
| `screens/payment_ladder_screen.dart` | — |
| `screens/phone_safety_screen.dart` | — |
| `screens/photo_edit_screens.dart` | — |
| `screens/photo_studio_screen.dart` | photo_after_save, photo_gallery |
| `screens/plans_screen.dart` | — |
| `screens/prepaid_meter_screen.dart` | — |
| `screens/price_radar_screen.dart` | — |
| `screens/proactive_ai_screen.dart` | — |
| `screens/probashi_screen.dart` | — |
| `screens/quick_tools_screen.dart` | quick_tool_exit, quick_tools |
| `screens/quran_screen.dart` | — |
| `screens/qurbani_screen.dart` | — |
| `screens/ramadan_screen.dart` | — |
| `screens/recovery_screen.dart` | — |
| `screens/referral_screen.dart` | — |
| `screens/reminders_screen.dart` | reminders_list |
| `screens/report_stolen_screen.dart` | — |
| `screens/ride_food_screen.dart` | — |
| `screens/ring_checklist_screen.dart` | — |
| `screens/safe_arrival_screen.dart` | — |
| `screens/safety_screen.dart` | — |
| `screens/samity_screen.dart` | — |
| `screens/saved_items_screen.dart` | saved_items |
| `screens/savings_challenge_screen.dart` | — |
| `screens/scam_screen.dart` | security_scan |
| `screens/security_checkup_screen.dart` | — |
| `screens/security_screen.dart` | — |
| `screens/sell_my_phone_screen.dart` | — |
| `screens/settings_screen.dart` | settings |
| `screens/shop_box_mode_screen.dart` | — |
| `screens/shop_box_screen.dart` | — |
| `screens/shop_eod_screen.dart` | — |
| `screens/shop_live_screen.dart` | — |
| `screens/smartwatch_screen.dart` | — |
| `screens/social_compose_screen.dart` | — |
| `screens/sos_triggers_screen.dart` | — |
| `screens/spending_advice_screen.dart` | — |
| `screens/student_corner_screen.dart` | student_after_practice |
| `screens/subscriptions_screen.dart` | — |
| `screens/support_center_screen.dart` | — |
| `screens/task_manager_screen.dart` | — |
| `screens/transcription_screen.dart` | — |
| `screens/travel_planner_screen.dart` | plan_after_save |
| `screens/trust_page_screen.dart` | — |
| `screens/unseen_world_screen.dart` | article_after_read |
| `screens/used_phone_check_screen.dart` | security_scan |
| `screens/vault_screen.dart` | — |
| `screens/vehicle_drivers_screen.dart` | — |
| `screens/vehicle_fence_editor_screen.dart` | — |
| `screens/vehicle_obd_screen.dart` | — |
| `screens/vehicle_report_screen.dart` | — |
| `screens/vehicle_tracker_screen.dart` | — |
| `screens/vehicle_tracker_settings_screen.dart` | — |
| `screens/vehicle_tracking_screen.dart` | — |
| `screens/voice_assistant_screen.dart` | — |
| `screens/voice_assistant_settings_screen.dart` | — |
| `screens/voice_mood_screen.dart` | — |
| `screens/voice_sos_screen.dart` | — |
| `screens/wake_disclosure_screen.dart` | — |
| `screens/wake_oem_guide_screen.dart` | — |
| `screens/watch_feed_screen.dart` | — |
| `screens/watched_phones_screen.dart` | — |
| `screens/web_photo_link_screen.dart` | — |
| `screens/wedding_events_screen.dart` | plan_after_save |
| `screens/wellness_tracker_screen.dart` | — |
| `screens/mktengine/mkt_engine_screen.dart` | — |
| `screens/kids_watch/kids_watch_screen.dart` | — |
| `screens/kids_watch/school_mode_child_screen.dart` | — |
| `screens/retention/retention_screen.dart` | — |
| `screens/blood/blood_banks_screen.dart` | — |
| `screens/blood/blood_donor_setup_screen.dart` | — |
| `screens/blood/blood_hub_screen.dart` | — |
| `screens/blood/blood_request_detail_screen.dart` | — |
| `screens/blood/blood_request_form_screen.dart` | — |
| `screens/blood/blood_saved_screen.dart` | — |
| `screens/blood/blood_thread_screen.dart` | — |
| `screens/blood/blood_threads_screen.dart` | — |
| `screens/blood/blood_verify_screen.dart` | — |
| `screens/train/dest_alarm_screen.dart` | — |
| `screens/train/journey_train_pick_screen.dart` | — |
| `screens/train/train_chat_screen.dart` | — |
| `screens/train/train_tracker_screen.dart` | train_detail, train_live_unlock, train_search |
| `screens/train/trip_recorder_screen.dart` | — |
| `screens/world/world_ask_screen.dart` | — |
| `screens/world/world_guide_hub_screen.dart` | — |
| `screens/world/world_hub_screen.dart` | — |
| `screens/world/world_jobs_screen.dart` | — |
| `screens/world/world_mcq_screen.dart` | — |
| `screens/world/world_today_screen.dart` | — |
| `screens/admin/cost_flags_screen.dart` | — |
| `screens/admin/discover_manager_screen.dart` | — |
| `screens/admin/owner_pnl_screen.dart` | — |
| `screens/admin/server_address_screen.dart` | — |
| `screens/pa/biz_travel_events_screen.dart` | — |
| `screens/pa/board_pack_screen.dart` | — |
| `screens/pa/call_email_screen.dart` | — |
| `screens/pa/delegate_access_screen.dart` | — |
| `screens/pa/dept_update_screen.dart` | — |
| `screens/pa/expense_voucher_screen.dart` | — |
| `screens/pa/filing_screen.dart` | — |
| `screens/pa/letters_screen.dart` | — |
| `screens/pa/liaison_screen.dart` | — |
| `screens/pa/lifestyle_screen.dart` | — |
| `screens/pa/meeting_minutes_screen.dart` | — |
| `screens/pa/pa_hub_screen.dart` | — |
| `screens/pa/pa_meeting_brief_screen.dart` | — |
| `screens/pa/pa_schedule_screen.dart` | — |
| `screens/pa/pa_travel_screen.dart` | — |
| `screens/pa/personal_tasks_screen.dart` | — |
| `screens/pa/pr_press_screen.dart` | — |
| `screens/pa/project_tracking_screen.dart` | — |
| `screens/pa/ps_today_screen.dart` | — |
| `screens/pa/research_prep_screen.dart` | — |
| `screens/pa/shoot_logistics_screen.dart` | — |
| `screens/pa/social_inbox_screen.dart` | — |
| `screens/pa/star_deals_screen.dart` | — |
| `screens/pa/vip_stakeholder_screen.dart` | — |
| `screens/pa/visitor_filter_screen.dart` | — |
| `screens/booking/booking_biz_screen.dart` | — |
| `screens/booking/booking_detail_screen.dart` | — |
| `screens/booking/booking_setup_screen.dart` | — |
| `screens/booking/my_bookings_screen.dart` | — |
| `screens/missing/missing_detail_screen.dart` | — |
| `screens/missing/missing_hub_screen.dart` | — |
| `screens/missing/missing_optin_screen.dart` | — |
| `screens/missing/missing_post_screen.dart` | — |
| `screens/missing/missing_thread_screen.dart` | — |
| `screens/kid_audio/kid_audio_screen.dart` | — |
| `screens/market/market_need_screen.dart` | — |
| `screens/market/market_screen.dart` | — |
| `screens/business/ai_assistant_screen.dart` | — |
| `screens/business/bargain_rules_screen.dart` | — |
| `screens/business/books_screen.dart` | — |
| `screens/business/business_hub_screen.dart` | — |
| `screens/business/business_plans_screen.dart` | — |
| `screens/business/business_setup_screen.dart` | — |
| `screens/business/cashbox_screen.dart` | — |
| `screens/business/customers_screen.dart` | — |
| `screens/business/demand_map_screen.dart` | — |
| `screens/business/khata_chat_screen.dart` | — |
| `screens/business/khata_entry_screen.dart` | — |
| `screens/business/khata_screen.dart` | — |
| `screens/business/orders_screen.dart` | — |
| `screens/business/payments_screen.dart` | — |
| `screens/business/products_screen.dart` | — |
| `screens/business/quick_sell_screen.dart` | — |
| `screens/business/reports_screen.dart` | — |
| `screens/business/sms_balance_screen.dart` | — |
| `screens/business/staff_screen.dart` | — |
| `screens/business/supplier_market_screen.dart` | — |
| `screens/business/tagada_send_screen.dart` | — |
| `screens/business/bizagent/agent_g1_screens.dart` | — |
| `screens/business/bizagent/approvals_screen.dart` | — |
| `screens/business/bizagent/seller_activity_screen.dart` | — |
| `screens/business/bizagent/seller_agent_screen.dart` | — |
| `screens/business/bizagent/seller_inbox_screen.dart` | — |
| `screens/business/bizagent/seller_setup_screen.dart` | — |
| `screens/business/invoice/invoice_screen.dart` | — |
| `screens/business/invoice/invoice_settings_screen.dart` | — |
| `screens/business/invoice/invoices_screen.dart` | — |
| `screens/business/invoice/new_invoice_screen.dart` | — |
| `screens/business/acct/acct_audit_screen.dart` | — |
| `screens/business/acct/acct_close_screen.dart` | — |
| `screens/business/acct/acct_entry_screen.dart` | — |
| `screens/business/acct/acct_home_screen.dart` | — |
| `screens/business/acct/acct_opening_screen.dart` | — |
| `screens/business/acct/acct_reports_screen.dart` | — |
| `screens/safe_journey/sj_child_school_screen.dart` | — |
| `screens/safe_journey/sj_hub_screen.dart` | — |
| `screens/safe_journey/sj_private_ask_screen.dart` | — |
| `screens/safe_journey/sj_share_screen.dart` | — |
| `screens/city/city_around_screen.dart` | — |
| `screens/city/city_directory_screen.dart` | — |
| `screens/city/city_metro_screen.dart` | — |
| `screens/city/city_reports_screen.dart` | — |
| `screens/city/city_service_screen.dart` | city_results, city_search |
| `screens/city/city_women_screen.dart` | — |
| `screens/agent_core/agent_approvals_screen.dart` | — |
| `screens/agent_core/agent_core_screen.dart` | — |
| `screens/agent_core/agent_history_screen.dart` | — |
| `screens/agent_core/biz_brief_screen.dart` | — |
| `screens/agent_core/life_graph_screen.dart` | — |
| `screens/probashi/probashi_family_screen.dart` | — |
| `screens/probashi/probashi_plan_screen.dart` | — |
| `screens/probashi/probashi_pool_screen.dart` | — |
| `screens/probashi/probashi_reports_screen.dart` | — |
| `screens/career/cv_export_screen.dart` | — |
| `screens/career/interview_role_screen.dart` | — |
| `screens/career/job_find_screen.dart` | — |
| `screens/otp/email_verify_screen.dart` | — |
| `screens/otp/otp_login_screen.dart` | — |
| `screens/otp/otp_verify_screen.dart` | — |
| `screens/camera/camera_preview_edit_screen.dart` | — |
| `screens/camera/camera_screen.dart` | — |
| `screens/crm/crm_aftersale_screen.dart` | — |
| `screens/crm/crm_automation_screen.dart` | — |
| `screens/crm/crm_bulk_send_screen.dart` | — |
| `screens/crm/crm_capture_screen.dart` | — |
| `screens/crm/crm_companies_screen.dart` | — |
| `screens/crm/crm_company_detail_screen.dart` | — |
| `screens/crm/crm_dashboard_screen.dart` | — |
| `screens/crm/crm_erp_handoff_screen.dart` | — |
| `screens/crm/crm_firstrun_screen.dart` | — |
| `screens/crm/crm_home_screen.dart` | — |
| `screens/crm/crm_lead_detail_screen.dart` | — |
| `screens/crm/crm_lead_form_screen.dart` | — |
| `screens/crm/crm_leads_screen.dart` | — |
| `screens/crm/crm_pipeline_screen.dart` | — |
| `screens/crm/crm_proposal_advanced_screen.dart` | — |
| `screens/crm/crm_proposal_screen.dart` | — |
| `screens/crm/crm_reports_screen.dart` | — |
| `screens/crm/crm_team_advanced_screen.dart` | — |
| `screens/crm/crm_team_screen.dart` | — |
| `screens/crm/crm_today_screen.dart` | — |
| `screens/crm/customer_history_screen.dart` | — |
| `screens/crm/customer_list_screen.dart` | — |
| `screens/crm/shop_quote_screens.dart` | — |
| `screens/messenger/admin_moderation_screen.dart` | — |
| `screens/messenger/admin_users_screen.dart` | — |
| `screens/messenger/broadcast_lists_screen.dart` | — |
| `screens/messenger/channel_admin_screen.dart` | — |
| `screens/messenger/channel_detail_screen.dart` | — |
| `screens/messenger/channel_list_screen.dart` | — |
| `screens/messenger/communities_home_screen.dart` | — |
| `screens/messenger/community_detail_screen.dart` | — |
| `screens/messenger/community_list_screen.dart` | — |
| `screens/messenger/community_members_screen.dart` | — |
| `screens/messenger/community_message_requests_screen.dart` | — |
| `screens/messenger/community_settings_screen.dart` | — |
| `screens/messenger/connection_requests_screen.dart` | — |
| `screens/messenger/contact_info_screen.dart` | — |
| `screens/messenger/contacts_screen.dart` | — |
| `screens/messenger/discover_screen.dart` | — |
| `screens/messenger/linked_devices_screen.dart` | — |
| `screens/messenger/m3_add_to_circle_screen.dart` | — |
| `screens/messenger/m3_requests_screen.dart` | — |
| `screens/messenger/messenger_home_screen.dart` | circle_list |
| `screens/messenger/messenger_profile_screen.dart` | — |
| `screens/messenger/messenger_settings_screen.dart` | — |
| `screens/messenger/moderation_appeal_screen.dart` | — |
| `screens/messenger/moderation_policy_screen.dart` | — |
| `screens/messenger/msgr_set_account_screen.dart` | — |
| `screens/messenger/msgr_set_calls_screen.dart` | — |
| `screens/messenger/msgr_set_change_number_screen.dart` | — |
| `screens/messenger/msgr_set_chats_screen.dart` | — |
| `screens/messenger/msgr_set_notifications_screen.dart` | — |
| `screens/messenger/msgr_set_privacy_screen.dart` | — |
| `screens/messenger/msgr_set_storage_screen.dart` | — |
| `screens/messenger/msgr_set_twostep_screen.dart` | — |
| `screens/messenger/starred_messages_screen.dart` | — |
| `screens/remittance/remit_entry_screen.dart` | — |
| `screens/remittance/remit_report_screen.dart` | — |
| `screens/remittance/remittance_screen.dart` | — |
| `screens/home_v2/all_services_screen.dart` | all_services |
| `screens/home_v2/assisto_chat_screen.dart` | — |
| `screens/home_v2/home_v2_screen.dart` | home |
| `screens/watchman/activity_screen.dart` | — |
| `screens/watchman/auto_guard_screen.dart` | — |
| `screens/watchman/cash_guard_screen.dart` | — |
| `screens/watchman/cctv_act_screens.dart` | — |
| `screens/watchman/cctv_alarm_call_screen.dart` | — |
| `screens/watchman/cctv_grid_screen.dart` | — |
| `screens/watchman/cctv_installer_screens.dart` | — |
| `screens/watchman/cctv_recording_screen.dart` | — |
| `screens/watchman/cctv_team_screens.dart` | — |
| `screens/watchman/cctv_watch_screen.dart` | — |
| `screens/watchman/cctvx_guard_screen.dart` | — |
| `screens/watchman/guard_box_screen.dart` | — |
| `screens/watchman/watchman_screen.dart` | — |
| `messaging/media/video_player_screen.dart` | — |
| `family_sos/sos_alarm_screen.dart` | — |
| `family_sos/sos_sender_screen.dart` | — |
| `bizai/biz_daily_screen.dart` | — |
| `bizai/cctv_accuracy_screen.dart` | — |
| `bizai/my_shops_screen.dart` | — |
| `bizai/shop_chat_screen.dart` | — |
| `bizai/weekly_report_screen.dart` | — |
| `bizai/winback_screen.dart` | — |
| `safe_plans/safe_ad_unlock_screen.dart` | — |
| `safe_plans/safe_plans_screen.dart` | — |
| `phonecam/phone_camera_screen.dart` | — |
| `phonecam/phonecam_timeline_screen.dart` | — |
| `ipcam/ipcam_guard_screen.dart` | — |
| `cctvguard/vendor_live_screen.dart` | — |
| `carecall/carecall_new_screen.dart` | — |
| `carecall/carecall_ring_screen.dart` | — |
| `carecall/carecall_screen.dart` | — |
| `family_v3/family_v3_screen.dart` | — |
| `family_v3/brain/fc_brain_settings_screen.dart` | — |
| `invite/invite_join_screen.dart` | — |
