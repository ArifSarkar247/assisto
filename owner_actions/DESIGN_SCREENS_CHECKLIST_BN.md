# ডিজাইন V2 — সব স্ক্রিনের চেকলিস্ট

মালিকের আদেশ ১০ নভেম্বর। প্রতিটি ব্যাচের পর আপডেট হয়। ✅ = নতুন ডিজাইনে শেষ (কোন ব্যাচে) · 🎨 = শুধু রং (হোম) · ⬜ = এখনো বাকি।
সব স্ক্রিনে V2 রং/কার্ড/বোতাম থিম থেকে নিজে থেকেই এসেছে (batch 1); নিচের ✅ মানে স্ক্রিনটির লেআউটও নতুন নিয়মে সাজানো।

কেউ নতুন সেশন শুরু করলে: owner_actions/DESIGN_SYSTEM_V2_BN.md পড়ুন, তারপর এই তালিকার প্রথম ⬜ থেকে কাজ ধরুন।

**স্ক্রিন শেষ: ৪২০ / মোট ৪২০**

## ১. হোম (শুধু রং)

- 🎨 রং শুধু — design3-b01 — `screens/elderly_home_screen.dart`
- 🎨 রং শুধু — design3-b01 — `screens/home_screen.dart`
- 🎨 রং শুধু — batch 1 — `screens/home_v2/all_services_screen.dart`
- 🎨 রং শুধু — batch 1 — `screens/home_v2/assisto_chat_screen.dart`
- 🎨 রং শুধু — batch 1 — `screens/home_v2/home_v2_screen.dart`

## ২. রক্তদাতা

- ✅ batch 4 (উৎস কার্ড, ব্যাংক কার্ডে সবুজ কল বোতাম) — `screens/blood/blood_banks_screen.dart`
- ✅ batch 4 (ধাপে ধাপে কার্ড, ৪×২ গ্রুপ গ্রিড) — `screens/blood/blood_donor_setup_screen.dart`
- ✅ build designv2 batch 1 — `screens/blood/blood_hub_screen.dart`
- ✅ batch 3 (খোলা অনুরোধ = লাল হিরো) — `screens/blood/blood_request_detail_screen.dart`
- ✅ batch 4 (ফর্ম: ৪×২ গ্রুপ গ্রিড, কার্ডে ভাগ, লাল পাঠান বোতাম) — `screens/blood/blood_request_form_screen.dart`
- ✅ batch 4 (কার্ডে গোল অ্যাকশন (কল আগে), ৪×২ গ্রিড ফর্মে) — `screens/blood/blood_saved_screen.dart`
- ✅ batch 4 (চ্যাট বাবল, কার্ড ব্যানার, লাল ব্লক নিশ্চিতকরণ) — `screens/blood/blood_thread_screen.dart`
- ✅ batch 4 (এক কার্ডে বার্তা তালিকা, স্কেলেটন) — `screens/blood/blood_threads_screen.dart`
- ✅ batch 4 (হিরো + গোপনীয়তা, দুই বোতাম পাশাপাশি) — `screens/blood/blood_verify_screen.dart`

## ৩. পরিবার (Family)

- ✅ batch 4 (নরম আঁকা আইকন, বড় সবুজ/লাল বোতামে আভা) — `eldercare/are_you_ok_screen.dart`
- ✅ batch 4 (কোড/সম্মতি কার্ডে, বড় লেখা অপরিবর্তিত) — `eldercare/elder_join_screen.dart`
- ✅ batch 4 (এক সারিতে মানুষ বাছাই, সেটিং এক কার্ডে, QR কার্ডে ছায়া) — `eldercare/elder_setup_screen.dart`
- ✅ batch 4 (সতর্কতা = লাল কার্ড, শান্ত কার্ডে সবুজ পালস ডট) — `eldercare/elder_watch_screen.dart`
- ✅ batch 4 (টোকেন রং, কার্ড, বোতামে আভা (জরুরি লেআউট অপরিবর্তিত)) — `family_sos/sos_alarm_screen.dart`
- ✅ batch 4 (টোকেন রং, কার্ড, বোতামে আভা (জরুরি লেআউট অপরিবর্তিত)) — `family_sos/sos_sender_screen.dart`
- ✅ batch 4 (প্রতিটি অংশ আলাদা কার্ড, এক সারির বিরতি চিপ) — `family_v3/brain/fc_brain_settings_screen.dart`
- ✅ batch 2 (সদস্য কার্ড) — `family_v3/family_v3_screen.dart`
- ✅ batch 4 (সক্রিয় SOS = লাল কার্ড, স্কেলেটন, DS বোতাম) — `screens/family_alerts_screen.dart`
- ✅ batch design3-b01 (যত্নকারী অংশ নরম DS হিরো, AA স্ট্যাটাস রং, টাইপ স্কেল) — `screens/family_screen.dart`
- ✅ batch 7 (পর্যালোচনা: DS খালি/ত্রুটি/লোডার, এক সারির ফিল্টার চিপ — নিয়ম মেনে চলে) — `screens/health_timeline_screen.dart`
- ✅ batch 4 (এক সারির টপিক চিপ, জরুরি-চেক কার্ড, স্কেলেটন) — `screens/health_tips_screen.dart`
- ✅ batch design3-b01 (স্কেলেটন লোডার, টাইপ স্কেল) — `screens/kids_watch/kids_watch_screen.dart`
- ✅ batch 4 (চালু = নীল কার্ডে সবুজ ডট, বড় বোতামে আভা) — `screens/kids_watch/school_mode_child_screen.dart`
- ✅ batch 4 (টোকেন রং, কার্ড কোণ ১২) — `screens/medicine_db_screen.dart`
- ✅ batch 4 (সামগ্রিক % = হিরো কার্ড, ওষুধ কার্ড) — `screens/medicine_history_screen.dart`
- ✅ batch 4 (DS কার্ড (সব প্রবাসী স্ক্রিনের শেয়ার্ড কার্ডও)) — `screens/probashi/probashi_family_screen.dart`

## ৪. জরুরি ও SOS

- ✅ batch 7 (পেজ নিয়ম: সতর্কতার পরই জরুরি নম্বর; AA রঙের ব্যানার, DS কার্ড) — `screens/disaster_alerts_screen.dart`
- ✅ batch 5 (পেজ নিয়ম: SOS-এর নিচে এক লাইন, ৯৯৯ আভাসহ, কাছের সাহায্য ৩ টাইল, সারিতে ব্যাখ্যা নেই) — `screens/emergency_hub_screen.dart`
- ✅ batch 7 (SOS আগে (আগেই ছিল), রেখার বদলে ফাঁকা, শিরোনাম হেডার, স্কেলেটন) — `screens/emergency_screen.dart`
- ✅ batch 7 (পেজ নিয়ম: সুরক্ষা → সুইচ কার্ড → ব্যাখ্যা; DS কার্ড) — `screens/fall_detect_screen.dart`
- ✅ batch 7 (পাঠানো অবস্থা = লাল কার্ড, হেল্পলাইন/কাছের সাহায্য DS কার্ডে) — `screens/journey_sos_screen.dart`
- ✅ batch 7 (পেজ নিয়ম: লম্বা ব্যাখ্যা চেকলিস্টের পরে, স্কেলেটন) — `screens/phone_safety_screen.dart`
- ✅ batch 5 (পেজ নিয়ম: SOS সবার আগে, নিরাপদ যাত্রা হিরো কার্ড, সারিগুলো এক কার্ডে) — `screens/safety_screen.dart`
- ✅ batch 7 (সুরক্ষা চালু = নরম হিরো, প্রতিটি উপায় জীবন্ত কার্ডে) — `screens/sos_triggers_screen.dart`
- ✅ batch 7 (পেজ নিয়ম: সুইচ আগে (হিরো কার্ডে), ব্যাখ্যা পরে) — `screens/voice_sos_screen.dart`

## ৫. নিরাপদ যাত্রা

- ✅ batch 7 (আঁকা খালি অবস্থা, DS ত্রুটি, ইতিহাস এক কার্ডে) — `screens/guardian_journey_screen.dart`
- ✅ batch design3-b01 (কল স্টেজ কালো রাখা, টাইপ স্কেল) — `screens/journey_fake_call_screen.dart`
- ✅ batch design3-b05 (ছোট 'এসএমএস পাঠান' লেবেল, বোতাম জোড়া সমান উঁচু) — `screens/journey_live_screen.dart`
- ✅ batch design3-b01 (টাইপ স্কেল, মানচিত্র অপরিবর্তিত) — `screens/journey_map_pick_screen.dart`
- ✅ batch 7 (প্রতিটি অংশ আলাদা DS কার্ডে, স্কেলেটন) — `screens/journey_settings_screen.dart`
- ✅ batch design3-b05 (এক খোঁজার ঘর (ডুপ্লিকেট বোতাম বাদ), শুরু = এক জ্বলজ্বলে DS বোতাম, স্কেলেটন) — `screens/journey_start_screen.dart`
- ✅ batch 5 (DS খালি অবস্থা (সুবিধা+কীভাবে+বড় বোতাম), স্কেলেটন) — `screens/journey_watch_screen.dart`
- ✅ batch design3-b01 (স্কেলেটন, DS ত্রুটি কার্ড + এক রিট্রাই বোতাম) — `screens/safe_journey/sj_child_school_screen.dart`
- ✅ batch 5 (চলমান যাত্রা সবার ওপরে, বাছাই করা মোড = নীল কার্ড, অ্যাকশন টাইল) — `screens/safe_journey/sj_hub_screen.dart`
- ✅ batch 7 (গোপন নোট ও প্রশ্ন-কার্ড DS সারফেসে (AA)) — `screens/safe_journey/sj_private_ask_screen.dart`
- ✅ batch 7 (কতক্ষণ/কাকে — দুই DS কার্ড, শুরু বোতাম শেষে) — `screens/safe_journey/sj_share_screen.dart`
- ✅ batch design3-b01 (যাচাই: DS টোকেন, কোনো কাঁচা রং নেই) — `screens/train/journey_train_pick_screen.dart`

## ৬. সিসিটিভি

- ✅ batch d2-5 (চলতি প্ল্যান = নরম হিরো, জীবন্ত কার্ড, DS বার্তা) — `billing/cctv_plan_screen.dart`
- ✅ batch d2-11 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `bizai/cctv_accuracy_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `cctvconnect/cctv_connect_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `cctvconnect/link_devices_screen.dart`
- ✅ batch d2-11 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `cctvguard/vendor_live_screen.dart`
- ✅ batch d2-7 (জীবন্ত কার্ড, স্কেলেটন) — `phonecam/phone_camera_screen.dart`
- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/camera/camera_preview_edit_screen.dart`
- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/camera/camera_screen.dart`
- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/circle_guardians_screen.dart`
- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/guardian_request_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন, DS ত্রুটি/খালি অবস্থা) — `screens/watchman/activity_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন, DS ত্রুটি/খালি অবস্থা) — `screens/watchman/auto_guard_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন, DS ত্রুটি/খালি অবস্থা) — `screens/watchman/cash_guard_screen.dart`
- ✅ batch d2-13 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/watchman/cctv_alarm_call_screen.dart`
- ✅ batch d2-5 (স্কেলেটন) — `screens/watchman/cctv_grid_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `screens/watchman/cctv_recording_screen.dart`
- ✅ batch d2-7 (জীবন্ত কার্ড, স্কেলেটন) — `screens/watchman/cctv_watch_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন, DS ত্রুটি/খালি অবস্থা) — `screens/watchman/cctvx_guard_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন, DS ত্রুটি/খালি অবস্থা) — `screens/watchman/guard_box_screen.dart`
- ✅ batch d2-2 (জায়গাগুলো আগে, প্ল্যান পরে; জীবন্ত কার্ড, লাইভ বিন্দু) — `screens/watchman/watchman_screen.dart`

## ৭. মাই সার্কেল চ্যাট

- ✅ batch d2-11 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `bizai/shop_chat_screen.dart`
- ✅ batch design3-b01 (সেভ = এক জ্বলজ্বলে DS বোতাম, স্কেলেটন) — `carecall/carecall_new_screen.dart`
- ✅ batch design3-b01 (যাচাই: টোকেন রঙের নরম গ্রেডিয়েন্ট) — `carecall/carecall_ring_screen.dart`
- ✅ batch 5 (DS খালি/ত্রুটি অবস্থা, স্কেলেটন, DS নতুন বোতাম) — `carecall/carecall_screen.dart`
- ✅ batch design3-b01 (যাচাই: কল স্টেজ (গাঢ়) রাখা) — `push/incoming_call_screen.dart`
- ✅ batch 3 (শুরু-কার্ড আগে, সাদা উত্তর-কার্ড) — `screens/ai_chat_screen.dart`
- ✅ batch design3-b01 (যাচাই: DS টোকেন, কাঁচা রং নেই) — `screens/business/khata_chat_screen.dart`
- ✅ batch 5 (DS খালি অবস্থা + কীভাবে, DS ফিল্টার চিপ, স্কেলেটন) — `screens/circle_call_history_screen.dart`
- ✅ batch design3-b01 (যাচাই: DS টোকেন, কাঁচা রং নেই) — `screens/circle_call_info_screen.dart`
- ✅ batch design3-b01 (কল স্টেজ রাখা, টাইপ স্কেল) — `screens/circle_call_screen.dart`
- ✅ batch design3-b01 (চ্যাট খুলতে স্কেলেটন, টাইপ স্কেল) — `screens/circle_chat_screen.dart`
- ✅ batch design3-b01 (টাইপ স্কেল, টোকেন রং) — `screens/circle_extras_broadcast_screen.dart`
- ✅ batch 5 (দুই টুল এক কার্ডে, আইকন-ব্যাজ) — `screens/circle_extras_hub_screen.dart`
- ✅ batch design3-b01 (স্কেলেটন, টাইপ স্কেল) — `screens/circle_extras_scheduled_screen.dart`
- ✅ batch design3-b06 (উপরের ব্যানার স্ক্রিনের এক-তৃতীয়াংশে সীমিত (২× লেখাতেও লেখার ঘর দেখা যায়), স্কেলেটন, টাইপ স্কেল) — `screens/circle_group_chat_screen.dart`
- ✅ batch design3-b01 (স্কেলেটন, AA লাল লেখা, টাইপ স্কেল) — `screens/circle_group_info_screen.dart`
- ✅ batch 5 (গ্রুপগুলো এক কার্ডে, খালি অবস্থায় গ্রুপ বানান বোতাম) — `screens/circle_group_list_screen.dart`
- ✅ batch 5 (প্রতিটি অংশ আলাদা কার্ডে, DS ত্রুটি অবস্থা) — `screens/circle_privacy_screen.dart`
- ✅ batch 5 (DS খালি অবস্থা (যোগ করুন/আবার চেষ্টা), স্কেলেটন, শিরোনাম) — `screens/circle_screen.dart`
- ✅ batch 5 (DS অ্যাভাটার, আঁকা খোঁজ-ইঙ্গিত) — `screens/circle_search_screen.dart`
- ✅ batch design3-b01 (টাইপ স্কেল (স্ট্যাটাস রং ব্যবহারকারীর কনটেন্ট)) — `screens/circle_status_composer_screen.dart`
- ✅ batch design3-b01 (স্কেলেটন, টাইপ স্কেল) — `screens/circle_status_screen.dart`
- ✅ batch design3-b01 (কালো স্টেজ রাখা, টাইপ স্কেল) — `screens/circle_status_viewer_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/admin_moderation_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/admin_users_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/broadcast_lists_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/channel_admin_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/channel_detail_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/channel_list_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/communities_home_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/community_detail_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/community_list_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/community_members_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/community_message_requests_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/community_settings_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/connection_requests_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/contact_info_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/contacts_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/discover_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/linked_devices_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/m3_add_to_circle_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/m3_requests_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/messenger_home_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/messenger_profile_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/messenger_settings_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/moderation_appeal_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/moderation_policy_screen.dart`
- ✅ batch d2-12 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/messenger/msgr_set_account_screen.dart`
- ✅ batch d2-12 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/messenger/msgr_set_calls_screen.dart`
- ✅ batch d2-12 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/messenger/msgr_set_change_number_screen.dart`
- ✅ batch d2-12 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/messenger/msgr_set_chats_screen.dart`
- ✅ batch d2-12 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/messenger/msgr_set_notifications_screen.dart`
- ✅ batch d2-12 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/messenger/msgr_set_privacy_screen.dart`
- ✅ batch d2-12 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/messenger/msgr_set_storage_screen.dart`
- ✅ batch d2-12 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/messenger/msgr_set_twostep_screen.dart`
- ✅ batch d2-14 (মেসেঞ্জার: DS গ্রুপ কার্ড, স্কেলেটন, DS খালি/ত্রুটি অবস্থা) — `screens/messenger/starred_messages_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/call_email_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/train/train_chat_screen.dart`

## ৮. হিসাব ও ফাইন্যান্স

- ✅ batch design3-b01 (টাইপ স্কেল, টোকেন রং) — `billing/refund_screen.dart`
- ✅ batch design3-b01 (যাচাই: DS টোকেন) — `safe_plans/safe_ad_unlock_screen.dart`
- ✅ batch design3-b01 (প্ল্যান হেডার নরম DS হিরো, স্কেলেটন) — `safe_plans/safe_plans_screen.dart`
- ✅ batch 6 (সাইন-ইন, ডিভাইস, হারালে — আলাদা কার্ড; DS ত্রুটি/স্কেলেটন) — `screens/account_security_screen.dart`
- ✅ batch design3-b01 (স্কেলেটন, DS ত্রুটি অবস্থা) — `screens/account_standing_screen.dart`
- ✅ batch d2-11 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/business/acct/acct_audit_screen.dart`
- ✅ batch d2-11 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/business/acct/acct_close_screen.dart`
- ✅ batch d2-11 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/business/acct/acct_entry_screen.dart`
- ✅ batch d2-1 (হিসাবের ধরন জীবন্ত টাইল, টুলগুলো এক গ্রুপ কার্ডে) — `screens/business/acct/acct_home_screen.dart`
- ✅ batch d2-11 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/business/acct/acct_opening_screen.dart`
- ✅ batch d2-11 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/business/acct/acct_reports_screen.dart`
- ✅ batch d2-5 (সুপারিশকৃত প্ল্যান হালকা নীল কার্ডে, AA লেখা, শিরোনাম ভাঙে না) — `screens/business/business_plans_screen.dart`
- ✅ batch design3-b01 (টাইপ স্কেল, টোকেন রং) — `screens/day_planner_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/delete_account_screen.dart`
- ✅ batch 6 (পেজ নিয়ম: টুলগুলোই আগে, গ্রুপ = এক কার্ড, লম্বা ব্যানার বাদ) — `screens/finance_screen.dart`
- ✅ batch d2-5 (DS খালি অবস্থা: ছবি, এক বড় বোতাম, ধাপগুলো) — `screens/mess_accounting_screen.dart`
- ✅ batch design3-b01 (টাইপ স্কেল, ট্যাবুলার সংখ্যা) — `screens/money_budget_screen.dart`
- ✅ batch design3-b01 (টাইপ স্কেল) — `screens/money_import_screen.dart`
- ✅ batch design3-b01 (টাইপ স্কেল) — `screens/money_loan_detail_screen.dart`
- ✅ batch design3-b01 (নিট সম্পদ = DS হিরো + বড় সংখ্যা) — `screens/money_networth_screen.dart`
- ✅ batch design3-b01 (টাইপ স্কেল) — `screens/money_report_screen.dart`
- ✅ batch 3 (হিসাব সারাংশ) — `screens/money_screen.dart`
- ✅ batch design3-b01 (টাইপ স্কেল, AA লাল লেখা) — `screens/money_tax_screen.dart`
- ✅ batch design3-b02 (মাসিক চার্ট হিরো কার্ডে, খাত তালিকা এক DS গ্রুপে, DS রিট্রাই বোতাম) — `screens/money_trends_screen.dart`
- ✅ batch design3-b02 (DS বোতাম (থামান = লাল), খসড়া DS কার্ডে, ব্যস্ত-সেভ, লাইট ফোনে আভা বন্ধ, টাইপ স্কেল) — `screens/money_voice_screen.dart`
- ✅ batch design3-b02 (DS বোতাম (খালি অবস্থায় এক বড় বোতাম), টোকেন রঙের পেজ-ডট) — `screens/money_wrapped_screen.dart`
- ✅ batch 6 (মোট বাকি = হিরো কার্ডে বড় সংখ্যা, DS খালি অবস্থা) — `screens/my_dues_screen.dart`
- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/my_dues_shop_screen.dart`
- ✅ batch design3-b02 (বর্তমান প্ল্যান নরম DS হিরো, নোট/নিরাপত্তা DS কার্ড, প্ল্যান কার্ড DS সারফেস, এক জ্বলজ্বলে কিনুন বোতাম) — `screens/plans_screen.dart`
- ✅ batch design3-b02 (DS বোতাম (বার্ষিক = মূল, মাসিক = দ্বিতীয়), পুল সংখ্যা বড় ও মোটা) — `screens/probashi/probashi_plan_screen.dart`
- ✅ batch design3-b02 (বোঝা-গেল কার্ড ও হিসাব লাইন DS সারফেসে, ব্যস্ত-সেভ DS বোতাম, লাল মুছুন) — `screens/remittance/remit_entry_screen.dart`
- ✅ batch design3-b02 (স্কেলেটন লোডার, রিপোর্ট DS কার্ডে, শেয়ার DS বোতাম, সবুজ পাঠানো-বার্তা) — `screens/remittance/remit_report_screen.dart`
- ✅ batch design3-b02 (খালি মাস = DS খালি অবস্থা (সুবিধা + বড় বোতাম + ধাপ), এন্ট্রি/প্রত্যাশা DS সারফেস, স্কেলেটন, DS বোতাম) — `screens/remittance/remittance_screen.dart`
- ✅ batch design3-b02 (স্বাগত = DS খালি অবস্থা, ট্রিপ/দিন/বাজেট DS কার্ড, বাজেট বেশি হলে লাল কার্ড, DS বোতাম, টাইপ স্কেল) — `screens/travel_planner_screen.dart`

## ৯. খাতা

- ✅ batch 5 (DS ত্রুটি অবস্থা) — `screens/business/khata_entry_screen.dart`
- ✅ batch 3 (খাতা — নরম হিরো, বড় অঙ্ক) — `screens/business/khata_screen.dart`

## ১০. মেস ও ব্যাচেলর

- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `messaging/media/video_player_screen.dart`

## ১১. মাই বিজনেস

- ✅ batch d2-9 (DS কার্ড ও ক্রম) — `bizai/my_shops_screen.dart`
- ✅ batch d2-9 (DS কার্ড ও ক্রম) — `bizai/weekly_report_screen.dart`
- ✅ batch d2-9 (DS কার্ড ও ক্রম) — `bizai/winback_screen.dart`
- ✅ batch d2-9 (DS কার্ড ও ক্রম) — `screens/agent_core/biz_brief_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `screens/booking/booking_biz_screen.dart`
- ✅ batch d2-9 (DS কার্ড ও ক্রম) — `screens/business/ai_assistant_screen.dart`
- ✅ batch d2-9 (DS খালি অবস্থা, বাংলা অঙ্ক) — `screens/business/bargain_rules_screen.dart`
- ✅ batch d2-9 (DS কার্ড ও ক্রম) — `screens/business/bizagent/approvals_screen.dart`
- ✅ batch d2-9 (DS কার্ড ও ক্রম) — `screens/business/bizagent/seller_activity_screen.dart`
- ✅ batch d2-9 (অপেক্ষমাণ উত্তর আগে, এজেন্ট হিরো) — `screens/business/bizagent/seller_agent_screen.dart`
- ✅ batch d2-9 (চ্যাট কার্ড) — `screens/business/bizagent/seller_inbox_screen.dart`
- ✅ batch d2-9 (DS কার্ড ও ক্রম) — `screens/business/bizagent/seller_setup_screen.dart`
- ✅ batch d2-9 (নিট লাভ = নরম হিরো, অংশগুলো DS কার্ডে) — `screens/business/books_screen.dart`
- ✅ batch 3 (মাই বিজনেস হেডার) — `screens/business/business_hub_screen.dart`
- ✅ batch d2-9 (হিরো, ধরন-টাইল বড় হয়) — `screens/business/business_setup_screen.dart`
- ✅ batch d2-9 (প্রত্যাশিত নগদ = হিরো + দিন বদল, নিচে জমা/খরচ) — `screens/business/cashbox_screen.dart`
- ✅ batch d2-9 (গ্রাহক সংখ্যা + বাকি = হিরো, অ্যাভাটার) — `screens/business/customers_screen.dart`
- ✅ batch d2-9 (চাহিদার শীর্ষ পণ্য = হিরো) — `screens/business/demand_map_screen.dart`
- ✅ batch d2-5 (স্কেলেটন) — `screens/business/invoice/invoice_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `screens/business/invoice/invoice_settings_screen.dart`
- ✅ batch d2-2 (নতুন ইনভয়েস বোতাম সবার আগে, অনুচ্ছেদ নেই) — `screens/business/invoice/invoices_screen.dart`
- ✅ batch d2-9 (DS অংশ) — `screens/business/invoice/new_invoice_screen.dart`
- ✅ batch 6 (জীবন্ত অর্ডার কার্ড, DS খালি/ত্রুটি) — `screens/business/orders_screen.dart`
- ✅ batch 6 (জীবন্ত BizCard, DS ত্রুটি অবস্থা, পূর্ণ-চওড়া বোতাম) — `screens/business/payments_screen.dart`
- ✅ batch d2-9 (দ্বিগুণ শিরোনাম নেই, DS চিপ, নাম ভাঙে) — `screens/business/products_screen.dart`
- ✅ batch d2-9 (DS টোস্ট, ফন্টের সাথে গ্রিড বড় হয়) — `screens/business/quick_sell_screen.dart`
- ✅ batch 6 (বিক্রি = নরম হিরো (বড় সংখ্যা), সমান উচ্চতার লাভ/খরচ কার্ড) — `screens/business/reports_screen.dart`
- ✅ batch d2-9 (ব্যালান্স = হিরো) — `screens/business/sms_balance_screen.dart`
- ✅ batch d2-9 (সার্কেল থেকে যোগ = হিরো, DS খালি অবস্থা) — `screens/business/staff_screen.dart`
- ✅ batch d2-9 (DS কার্ড ও ক্রম) — `screens/business/supplier_market_screen.dart`
- ✅ batch d2-9 (চলমান অবস্থা = হিরো) — `screens/business/tagada_send_screen.dart`
- ✅ batch d2-9 (বিজনেস হাবের মোড়ক) — `screens/business_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_aftersale_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_automation_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_bulk_send_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_capture_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_companies_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_company_detail_screen.dart`
- ✅ batch d2-7 (ওজনযুক্ত পূর্বাভাস = নরম হিরো, লেবেল কাটা যায় না) — `screens/crm/crm_dashboard_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_erp_handoff_screen.dart`
- ✅ batch d2-8 (স্বাগতম = নরম হিরো আঁকা ছবিসহ, ত্রুটি = লাল কার্ড) — `screens/crm/crm_firstrun_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_home_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_lead_detail_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_lead_form_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_leads_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_pipeline_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_proposal_advanced_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_proposal_screen.dart`
- ✅ batch d2-7 (পূর্বাভাস = নরম হিরো, লেবেল কাটা যায় না) — `screens/crm/crm_reports_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_team_advanced_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_team_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/crm_today_screen.dart`
- ✅ batch d2-8 (গ্রাহক = নরম হিরো, DS অ্যাভাটার) — `screens/crm/customer_history_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm/customer_list_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/crm_contacts_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/biz_travel_events_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `screens/shop_box_mode_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/shop_box_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/shop_eod_screen.dart`
- ✅ batch d2-10 (DS কার্ড/হিরো, স্কেলেটন, DS খালি অবস্থা, এক জ্বলজ্বলে বোতাম) — `screens/shop_live_screen.dart`

## ১২. এআই চ্যাট

- ✅ batch d2-16 (DS হিরো/কার্ড, স্কেলেটন, এক জ্বলজ্বলে বোতাম) — `screens/agent_core/agent_approvals_screen.dart`
- ✅ batch d2-16 (DS হিরো/কার্ড, স্কেলেটন, এক জ্বলজ্বলে বোতাম) — `screens/agent_core/agent_core_screen.dart`
- ✅ batch d2-16 (DS হিরো/কার্ড, স্কেলেটন, এক জ্বলজ্বলে বোতাম) — `screens/agent_core/agent_history_screen.dart`
- ✅ batch d2-16 (DS হিরো/কার্ড, স্কেলেটন, এক জ্বলজ্বলে বোতাম) — `screens/agent_core/life_graph_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/agent_studio_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/agent_thread_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/voice_assistant_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/voice_assistant_settings_screen.dart`

## ১৩. ল্যাঙ্গুয়েজ পার্টনার

- ✅ batch d2-7 (জীবন্ত কার্ড, স্কেলেটন) — `screens/language_pack_screen.dart`
- ✅ batch d2-2 (আজকের লক্ষ্য = নরম হিরো, জীবন্ত কার্ড) — `screens/language_partner_screen.dart`
- ✅ batch d2-8 (ভাষা = জীবন্ত কার্ড, বাছাই করা = নীল সীমানা, বড় চালিয়ে যান বোতাম) — `screens/language_picker_screen.dart`

## ১৪. কুরআন

- ✅ batch 6 (শান্ত: আজকের লক্ষ্য = নরম হিরো, স্কেলেটন) — `quran_learn/quran_learn_screen.dart`
- ✅ batch 6 (শান্ত: পড়া চালিয়ে যান = নরম হিরো, সূরা এক কার্ডে, আভা নেই) — `screens/quran_screen.dart`

## ১৫. সেটিংস

- ✅ batch 5 (অনুমতি বন্ধ থাকলে সেটাই সবার ওপরে, রঙিন আইকন-ব্যাজ কার্ড) — `push/push_settings_screen.dart`
- ✅ batch 2 (গ্রুপ কার্ড) — `screens/settings_screen.dart`
- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/vehicle_tracker_settings_screen.dart`

## ১৬. বাকি সব স্ক্রিন

- ✅ batch design3-b02 (কোড কার্ড নরম DS হিরো (বড় কোড), শেয়ার = এক জ্বলজ্বলে বোতাম, পরিসংখ্যান বড় সংখ্যা, DS ত্রুটি অবস্থা, স্কেলেটন) — `growth/invite_screen.dart`
- ✅ batch design3-b02 (আমন্ত্রণকারী হিরো কার্ডে, DS বড় বোতাম (ব্যস্ত অবস্থা), সমস্যা/অফলাইন = DS অবস্থা কার্ড) — `invite/invite_join_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `phonecam/phonecam_timeline_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/about_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/accessibility_mode_screen.dart`
- ✅ batch design3-b02 (খালি/ত্রুটি = DS অবস্থা কার্ড, স্কেলেটন লোডার, DS রিট্রাই) — `screens/action_center_screen.dart`
- ✅ batch d2-16 (DS হিরো/কার্ড, স্কেলেটন, এক জ্বলজ্বলে বোতাম) — `screens/admin/cost_flags_screen.dart`
- ✅ batch d2-16 (DS হিরো/কার্ড, স্কেলেটন, এক জ্বলজ্বলে বোতাম) — `screens/admin/discover_manager_screen.dart`
- ✅ batch d2-16 (DS হিরো/কার্ড, স্কেলেটন, এক জ্বলজ্বলে বোতাম) — `screens/admin/owner_pnl_screen.dart`
- ✅ batch d2-16 (DS হিরো/কার্ড, স্কেলেটন, এক জ্বলজ্বলে বোতাম) — `screens/admin/server_address_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/ai_knowledge_screen.dart`
- ✅ batch design3-b02 (সব কার্ড DS সারফেস, স্কেলেটন, DS ত্রুটি কার্ড, চালু = মূল বোতাম, বন্ধ নিশ্চিতকরণ লাল) — `screens/always_on_protection_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/app_update_screen.dart`
- ✅ batch design3-b02 (নোটিশ কার্ড DS, DS বোতাম, মুছুন লাল, টাইপ স্কেল) — `screens/area_community_screen.dart`
- ✅ batch design3-b02 (নতুন চ্যাট DS বড় বোতাম, খালি/ত্রুটি DS অবস্থা কার্ড, স্কেলেটন) — `screens/assisto_chats_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/battery_guidance_screen.dart`
- ✅ batch design3-b02 (খালি = DS খালি অবস্থা (কন্টাক্ট থেকে আনুন), DS ত্রুটি কার্ড, স্কেলেটন) — `screens/birthdays_screen.dart`
- ✅ batch design3-b02 (শেয়ার = মূল DS বোতাম, কপি/সেভ দ্বিতীয়, খসড়া DS কার্ড, টাইপ স্কেল) — `screens/blog_writer_screen.dart`
- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/booking/booking_detail_screen.dart`
- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/booking/booking_setup_screen.dart`
- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/booking/my_bookings_screen.dart`
- ✅ batch design3-b02 (লাইভ/সতর্কতা/সেটিং DS কার্ড (সতর্কতা লাল), DS বোতাম, টাইপ স্কেল) — `screens/car_mode_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/career/cv_export_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/career/interview_role_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/career/job_find_screen.dart`
- ✅ batch d2-7 (জীবন্ত কার্ড, স্কেলেটন) — `screens/city/city_around_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `screens/city/city_directory_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `screens/city/city_metro_screen.dart`
- ✅ batch d2-7 (জীবন্ত কার্ড, স্কেলেটন) — `screens/city/city_reports_screen.dart`
- ✅ batch d2-2 (শহর = নরম হিরো, টাইলে রঙিন আইকন-ব্যাজ) — `screens/city/city_service_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `screens/city/city_women_screen.dart`
- ✅ batch design3-b02 (বিশ্লেষণ = মূল DS বোতাম, সেভ দ্বিতীয়, সংরক্ষিত DS কার্ড, টাইপ স্কেল) — `screens/contract_analyzer_screen.dart`
- ✅ batch design3-b02 (DS বোতাম (টেমপ্লেট/যোগ দ্বিতীয়), সংরক্ষিত DS কার্ড, টাইপ স্কেল) — `screens/cost_estimator_screen.dart`
- ✅ batch 5 (জীবন্ত কার্ড, সতর্কতা = লাল কার্ড, বড় সংখ্যা ঘন) — `screens/credits_screen.dart`
- ✅ batch design3-b02 (PDF = এক মূল বোতাম, প্রিভিউ/প্রোফাইল দ্বিতীয়, অংশ DS কার্ডে) — `screens/cv_builder_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/daily_brief_screen.dart`
- ✅ batch design3-b02 (চ্যালেঞ্জ ও লিডারবোর্ড DS কার্ড, DS রিট্রাই) — `screens/daily_challenges_screen.dart`
- ✅ batch design3-b02 (টুল সারি DS কার্ড, DS বোতাম, টাইপ স্কেল) — `screens/daily_tools_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/deletion_grace_screen.dart`
- ✅ batch design3-b02 (স্কেলেটন লোডার, টোকেন রং (ধূসর বাদ), টাইপ স্কেল) — `screens/dictionary_screen.dart`
- ✅ batch design3-b02 (নথি তালিকা DS কার্ড, খালি অবস্থায় এক বড় বোতাম, DS বোতাম, টাইপ স্কেল) — `screens/doc_scanner_screen.dart`
- ✅ batch design3-b02 (অ্যাপয়েন্টমেন্ট DS কার্ড, DS বোতাম, মুছুন লাল) — `screens/doctor_serial_screen.dart`
- ✅ batch design3-b02 (কর্মী কার্ড DS, DS বোতাম (সেভ মূল, বাতিল দ্বিতীয়), মুছুন লাল) — `screens/domestic_staff_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/e2_restore_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/encrypted_backup_screen.dart`
- ✅ batch design3-b02 (নজর রাখুন = ব্যস্ত-অবস্থার DS বোতাম, থামান লাল, কার্ড DS) — `screens/exam_result_screen.dart`
- ✅ batch design3-b02 (ভাগাভাগি/খরচ DS কার্ড, DS বোতাম, মুছুন লাল, খালি অবস্থায় যোগ বোতাম) — `screens/expense_split_screen.dart`
- ✅ batch design3-b02 (সব কার্ড DS সারফেস (বড়-লেখার সবুজ বোতাম কৃষকদের জন্য অপরিবর্তিত)) — `screens/farmer_mode_screen.dart`
- ✅ batch design3-b02 (লক্ষ্য/ব্যায়াম DS কার্ড, DS বোতাম, টাইপ স্কেল) — `screens/fitness_partner_screen.dart`
- ✅ batch design3-b02 (গাড়ি তালিকা DS কার্ড, সতর্কতা লাল কার্ড, DS বোতাম) — `screens/fleet_dashboard_screen.dart`
- ✅ batch design3-b03 (খালি অবস্থা নরম হিরো + এক জ্বলজ্বলে বোতাম, DS কার্ড, DS ত্রুটি কার্ড, টাইপ স্কেল) — `screens/food_calories_screen.dart`
- ✅ batch design3-b03 (অফলাইন ফিতা DS স্ট্রিপ, টোকেন ব্যবধান) — `screens/guide_screen.dart`
- ✅ batch design3-b03 (১৩টি কার্ড DS কার্ডে, টাইপ স্কেল (২২টি কাঁচা স্টাইল সরানো)) — `screens/ielts_screen.dart`
- ✅ batch design3-b03 (DS কার্ড সারি, টাইপ স্কেল) — `screens/in_progress_screen.dart`
- ✅ batch design3-b03 (খালি ও ত্রুটি অবস্থা DS ছবি-কার্ডে, আবার চেষ্টা বোতাম) — `screens/inbox_screen.dart`
- ✅ batch design3-b03 (সম্মতি বোতাম এক জ্বলজ্বলে DS বোতাম, DS আইন কার্ড) — `screens/intruder_consent_screen.dart`
- ✅ batch design3-b03 (খালি অবস্থায় এক জ্বলজ্বলে যোগ বোতাম, টাইপ স্কেল) — `screens/jobs_screen.dart`
- ✅ batch design3-b03 (স্কেলেটন লোডার, DS ত্রুটি কার্ড, DS কার্ড) — `screens/kid_audio/kid_audio_screen.dart`
- ✅ batch design3-b03 (DS কার্ড, টাইপ স্কেল) — `screens/kid_school_screen.dart`
- ✅ batch design3-b03 (মাসের সারাংশ নরম DS হিরো (গাঢ় গ্রেডিয়েন্ট বাদ), টোকেন রং) — `screens/landlord_tenant_screen.dart`
- ✅ batch design3-b03 (DS কার্ড, টাইপ স্কেল (সার্টিফিকেট ফ্রেম অপরিবর্তিত)) — `screens/learn_cert_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/legal_screen.dart`
- ✅ batch design3-b03 (প্রথম চালু: শুধু টাইপ স্কেল (হালকা থিম বোতাম অপরিবর্তিত)) — `screens/login_screen.dart`
- ✅ batch design3-b03 (স্কেলেটন লোডার, ৯টি কার্ড DS কার্ডে) — `screens/lost_stolen_screen.dart`
- ✅ batch d2-7 (জীবন্ত কার্ড, স্কেলেটন) — `screens/market/market_need_screen.dart`
- ✅ batch d2-5 (জীবন্ত কার্ড, স্কেলেটন) — `screens/market/market_screen.dart`
- ✅ batch design3-b03 (স্কেলেটন, DS খালি অবস্থা (প্রথম মিটিং যোগ), DS ত্রুটি কার্ড, ধূসর রং টোকেনে) — `screens/meetings_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/memory_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/missing/missing_detail_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/missing/missing_hub_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/missing/missing_optin_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/missing/missing_post_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/missing/missing_thread_screen.dart`
- ✅ batch d2-12 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/mktengine/mkt_engine_screen.dart`
- ✅ batch design3-b03 (৮টি কার্ড DS কার্ডে, টাইপ স্কেল) — `screens/mock_interview_screen.dart`
- ✅ batch design3-b03 (স্কেলেটন, DS ত্রুটি কার্ড, ১০টি কার্ড DS কার্ডে) — `screens/my_lost_phone_screen.dart`
- ✅ batch design3-b03 (DS কার্ড, টাইপ স্কেল) — `screens/my_vehicles_screen.dart`
- ✅ batch design3-b03 (নাম নরম DS হিরোতে (গ্রেডিয়েন্ট বাদ), টাইপ স্কেল) — `screens/name_about_screen.dart`
- ✅ batch design3-b03 (DS কার্ড, টাইপ স্কেল) — `screens/nearby_screen.dart`
- ✅ batch design3-b03 (খালি অবস্থায় এক জ্বলজ্বলে যোগ বোতাম, টাইপ স্কেল) — `screens/nominee_screen.dart`
- ✅ batch design3-b03 (টাইপ স্কেল (নোটের নিজস্ব রং অপরিবর্তিত)) — `screens/notes_todos_screen.dart`
- ✅ batch 5 (জীবন্ত কার্ড, না-পড়া = নীলচে + ডট, এক সারির ফিল্টার চিপ) — `screens/notification_centre_screen.dart`
- ✅ batch design3-b03 (স্কেলেটন লোডার, DS কার্ড) — `screens/offline_status_screen.dart`
- ✅ batch design3-b03 (প্রথম চালু: DS ইমপোর্ট, হালকা থিম অপরিবর্তিত) — `screens/onboarding_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/otp/email_verify_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/otp/otp_login_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/otp/otp_verify_screen.dart`
- ✅ batch design3-b03 (শিরোনাম নরম DS হিরো (গ্রেডিয়েন্ট বাদ), টাইপ স্কেল) — `screens/owner_analytics_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/board_pack_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/delegate_access_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/dept_update_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/expense_voucher_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/filing_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/letters_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/liaison_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/lifestyle_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/meeting_minutes_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/pa_hub_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/pa_meeting_brief_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/pa_schedule_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/pa_travel_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/personal_tasks_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/pr_press_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/project_tracking_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/ps_today_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/research_prep_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/shoot_logistics_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/social_inbox_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/star_deals_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/vip_stakeholder_screen.dart`
- ✅ batch d2-15 (পার্সোনাল সেক্রেটারি: হিরো + DS গ্রুপ কার্ড, এক জ্বলজ্বলে বোতাম) — `screens/pa/visitor_filter_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/password_reset_confirm_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/password_reset_screen.dart`
- ✅ batch design3-b03 (খালি অবস্থায় এক জ্বলজ্বলে যোগ বোতাম, টাইপ স্কেল) — `screens/payment_ladder_screen.dart`
- ✅ batch d2-2 (তিন-রঙা ব্লকের বদলে নরম হিরো, প্রতিটি অংশ জীবন্ত কার্ড) — `screens/photo_studio_screen.dart`
- ✅ batch design3-b03 (DS কার্ড, টাইপ স্কেল) — `screens/prepaid_meter_screen.dart`
- ✅ batch design3-b03 (DS কার্ড, টাইপ স্কেল) — `screens/price_radar_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/proactive_ai_screen.dart`
- ✅ batch design3-b03 (বাকি টাকা বড় মোটা সংখ্যা, টোকেন ব্যবধান) — `screens/probashi/probashi_pool_screen.dart`
- ✅ batch design3-b03 (খালি অবস্থা DS কার্ডে, টোকেন ব্যবধান) — `screens/probashi/probashi_reports_screen.dart`
- ✅ batch design3-b03 (৭টি কার্ড DS কার্ডে, টাইপ স্কেল) — `screens/probashi_screen.dart`
- ✅ batch design3-b03 (DS কার্ড, টাইপ স্কেল) — `screens/quick_tools_screen.dart`
- ✅ batch design3-b03 (৮টি কার্ড DS কার্ডে, টাইপ স্কেল) — `screens/qurbani_screen.dart`
- ✅ batch design3-b04 (শান্ত DS কার্ডে নামাজের সময়, স্কেলেটন লোডার, টোকেন রং (আভা নেই)) — `screens/ramadan_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/recovery_screen.dart`
- ✅ batch design3-b04 (আমন্ত্রণ = একমাত্র জ্বলজ্বলে বোতাম, DS ত্রুটি/খালি অবস্থা, DS কার্ড) — `screens/referral_screen.dart`
- ✅ batch 5 (জীবন্ত কার্ড, মিস হওয়া = লাল কার্ড) — `screens/reminders_screen.dart`
- ✅ batch design3-b04 (ভূমিকা DS হিরোতে, থিম ইনপুট, লাল DS রিপোর্ট বোতাম (ব্যস্ত অবস্থা)) — `screens/report_stolen_screen.dart`
- ✅ batch design3-b04 (স্বাগত = DS খালি অবস্থা, অটোমেশন DS কার্ড, টুল এক DS গ্রুপে, স্কেলেটন) — `screens/retention/retention_screen.dart`
- ✅ batch design3-b04 (নিরাপত্তা কার্ড আগে, ব্যাখ্যা নোট শেষে, থিম ইনপুট) — `screens/ride_food_screen.dart`
- ✅ batch design3-b04 (সারাংশ DS হিরো, প্রতিটি সারি DS কার্ড, স্কেলেটন, ব্যানার লাল DS কার্ড) — `screens/ring_checklist_screen.dart`
- ✅ batch design3-b04 (DS অফলাইন স্ট্রিপ, রুটিন/ইতিহাস DS গ্রুপে, স্কেলেটন, টোকেন রং) — `screens/safe_arrival_screen.dart`
- ✅ batch design3-b04 (সংগ্রহ = নরম DS হিরো + বড় সংখ্যা, DS খালি/ত্রুটি, পেআউট DS কার্ড) — `screens/samity_screen.dart`
- ✅ batch design3-b04 (DS খালি/ফলাফল-নেই/ত্রুটি অবস্থা, ট্যাগ চিপ বড় ফন্টে কাটে না (FadeChipRow), DS কার্ড, থিম ইনপুট) — `screens/saved_items_screen.dart`
- ✅ batch design3-b04 (জমা = নরম DS হিরো + বড় সংখ্যা, DS কার্ড, DS খালি/ত্রুটি অবস্থা) — `screens/savings_challenge_screen.dart`
- ✅ batch design3-b04 (ভূমিকা DS হিরো, এক জ্বলজ্বলে যাচাই বোতাম, ত্রুটি লাল DS কার্ড, লাইব্রেরি DS কার্ড + স্কেলেটন) — `screens/scam_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/security_checkup_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/security_screen.dart`
- ✅ batch design3-b04 (অগ্রগতি হিরো (ধাপ গণনা + বার), সব অংশ DS কার্ড, রসিদ DS গ্রুপে, এক জ্বলজ্বলে বোতাম) — `screens/sell_my_phone_screen.dart`
- ✅ batch design3-b04 (সংযোগ/ইনস্টল/ডেটা-নেই/ত্রুটি = DS খালি অবস্থা, মেট্রিক DS কার্ড) — `screens/smartwatch_screen.dart`
- ✅ batch design3-b04 (এক জ্বলজ্বলে বোতাম (তৈরি → শেয়ার), কপি/সেভ মোড়ানো সারি, DS খালি/ত্রুটি, থিম ইনপুট) — `screens/social_compose_screen.dart`
- ✅ batch design3-b04 (DS খালি/ত্রুটি অবস্থা, সব কার্ড DS (সফল = সবুজ টোন), থিম ইনপুট, টাইপ স্কেল) — `screens/spending_advice_screen.dart`
- ✅ batch design3-b04 (CGPA = নরম DS হিরো, সব কার্ড DS, DS খালি/ত্রুটি অবস্থা, টাইপ স্কেল) — `screens/student_corner_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/subscriptions_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/support_center_screen.dart`
- ✅ batch design3-b04 (স্বাগত = DS খালি অবস্থা, প্রজেক্ট/টাস্ক DS কার্ড, DS বোতাম, অফলাইন রং টোকেন) — `screens/task_manager_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/train/dest_alarm_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/train/train_tracker_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/train/trip_recorder_screen.dart`
- ✅ batch design3-b04 (প্রথমবার = DS খালি অবস্থা (এক বোতাম), পরিসংখ্যান/নোট DS কার্ড, DS ত্রুটি) — `screens/transcription_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/trust_page_screen.dart`
- ✅ batch design3-b04 (কিছু-না-পাওয়া/ইচ্ছাতালিকা = DS খালি অবস্থা, জায়গা DS কার্ড) — `screens/unseen_world_screen.dart`
- ✅ batch design3-b04 (এক জ্বলজ্বলে যাচাই বোতাম (ব্যস্ত অবস্থা), টেম্পার সতর্কতা লাল DS কার্ড, তথ্য কার্ড DS) — `screens/used_phone_check_screen.dart`
- ✅ batch design3-b04 (DS খালি/ত্রুটি, স্কেলেটন, E2E/অফলাইন DS কার্ড, মেয়াদ ব্যাজ টোকেন রং) — `screens/vault_screen.dart`
- ✅ batch design3-b04 (চালক তালিকা DS কার্ড, DS ত্রুটি অবস্থা, স্কেলেটন, টাইপ স্কেল) — `screens/vehicle_drivers_screen.dart`
- ✅ batch design3-b04 (DS সেভ বোতাম, স্কেলেটন লোডার) — `screens/vehicle_fence_editor_screen.dart`
- ✅ batch design3-b04 (সমস্যা কোড DS কার্ড (গুরুতর = লাল টোন), DS পড়ুন বোতাম (ব্যস্ত), গরম সতর্কতা DS বর্ডার) — `screens/vehicle_obd_screen.dart`
- ✅ batch design3-b04 (ড্রাইভিং স্কোর = নরম DS হিরো সবার আগে, DS খালি/ত্রুটি অবস্থা) — `screens/vehicle_report_screen.dart`
- ✅ batch design3-b04 (ট্র্যাকার DS কার্ড, ইঞ্জিন বন্ধ = লাল DS বোতাম, বাকি বোতাম সেকেন্ডারি, DS ত্রুটি) — `screens/vehicle_tracker_screen.dart`
- ✅ batch design3-b04 (ট্র্যাকার/তথ্য DS কার্ড, DS জোড়া বোতাম (ব্যস্ত), DS ত্রুটি অবস্থা) — `screens/vehicle_tracking_screen.dart`
- ✅ batch design3-b04 (সম্মতি = এক জ্বলজ্বলে বোতাম, DS কার্ড, মুড বাছাই টোকেন রং, DS ত্রুটি) — `screens/voice_mood_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/wake_disclosure_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/wake_oem_guide_screen.dart`
- ✅ batch design3-b04 (সব ঠিক / ত্রুটি = DS খালি অবস্থা (রেট সতর্কতা বোতাম), টাইপ স্কেল) — `screens/watch_feed_screen.dart`
- ✅ batch design3-b04 (স্কেলেটন, DS ত্রুটি (আবার চেষ্টা), DS খালি অবস্থা, ফোন DS কার্ড) — `screens/watched_phones_screen.dart`
- ✅ batch d2-11 (DS গ্রুপ কার্ড, স্কেলেটন, টোকেন রং, DS বোতাম) — `screens/web_photo_link_screen.dart`
- ✅ batch design3-b04 (কাউন্টডাউন = নরম DS হিরো, সব অংশ DS কার্ড, DS খালি/ত্রুটি অবস্থা) — `screens/wedding_events_screen.dart`
- ✅ batch design3-b04 (DS কার্ড, DS খালি/ত্রুটি অবস্থা, টাইপ স্কেল) — `screens/wellness_tracker_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/world/world_ask_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/world/world_guide_hub_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/world/world_hub_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/world/world_jobs_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/world/world_mcq_screen.dart`
- ✅ batch d2-15 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `screens/world/world_today_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `vault/vault_e2e_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `vault/vault_recovery_screen.dart`
- ✅ batch d2-16 (নরম DS হিরো, ফ্ল্যাট কার্ড, স্কেলেটন, টাইপ স্কেল) — `vault/vault_security_screen.dart`
