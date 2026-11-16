# ডিজাইন V2 — সব স্ক্রিনের চেকলিস্ট

মালিকের আদেশ ১০ নভেম্বর। প্রতিটি ব্যাচের পর আপডেট হয়। ✅ = নতুন ডিজাইনে শেষ (কোন ব্যাচে) · 🎨 = শুধু রং (হোম) · ⬜ = এখনো বাকি।
সব স্ক্রিনে V2 রং/কার্ড/বোতাম থিম থেকে নিজে থেকেই এসেছে (batch 1); নিচের ✅ মানে স্ক্রিনটির লেআউটও নতুন নিয়মে সাজানো।

কেউ নতুন সেশন শুরু করলে: owner_actions/DESIGN_SYSTEM_V2_BN.md পড়ুন, তারপর এই তালিকার প্রথম ⬜ থেকে কাজ ধরুন।

**স্ক্রিন শেষ: ৬১ / মোট ৪২০**

## ১. হোম (শুধু রং)

- ⬜ — `screens/elderly_home_screen.dart`
- ⬜ — `screens/home_screen.dart`
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
- ⬜ — `screens/family_screen.dart`
- ⬜ — `screens/health_timeline_screen.dart`
- ✅ batch 4 (এক সারির টপিক চিপ, জরুরি-চেক কার্ড, স্কেলেটন) — `screens/health_tips_screen.dart`
- ⬜ — `screens/kids_watch/kids_watch_screen.dart`
- ✅ batch 4 (চালু = নীল কার্ডে সবুজ ডট, বড় বোতামে আভা) — `screens/kids_watch/school_mode_child_screen.dart`
- ✅ batch 4 (টোকেন রং, কার্ড কোণ ১২) — `screens/medicine_db_screen.dart`
- ✅ batch 4 (সামগ্রিক % = হিরো কার্ড, ওষুধ কার্ড) — `screens/medicine_history_screen.dart`
- ✅ batch 4 (DS কার্ড (সব প্রবাসী স্ক্রিনের শেয়ার্ড কার্ডও)) — `screens/probashi/probashi_family_screen.dart`

## ৪. জরুরি ও SOS

- ✅ batch 7 (পেজ নিয়ম: সতর্কতার পরই জরুরি নম্বর; AA রঙের ব্যানার, DS কার্ড) — `screens/disaster_alerts_screen.dart`
- ✅ batch 5 (পেজ নিয়ম: SOS-এর নিচে এক লাইন, ৯৯৯ আভাসহ, কাছের সাহায্য ৩ টাইল, সারিতে ব্যাখ্যা নেই) — `screens/emergency_hub_screen.dart`
- ✅ batch 7 (SOS আগে (আগেই ছিল), রেখার বদলে ফাঁকা, শিরোনাম হেডার, স্কেলেটন) — `screens/emergency_screen.dart`
- ✅ batch 7 (পেজ নিয়ম: সুরক্ষা → সুইচ কার্ড → ব্যাখ্যা; DS কার্ড) — `screens/fall_detect_screen.dart`
- ⬜ — `screens/journey_sos_screen.dart`
- ✅ batch 7 (পেজ নিয়ম: লম্বা ব্যাখ্যা চেকলিস্টের পরে, স্কেলেটন) — `screens/phone_safety_screen.dart`
- ✅ batch 5 (পেজ নিয়ম: SOS সবার আগে, নিরাপদ যাত্রা হিরো কার্ড, সারিগুলো এক কার্ডে) — `screens/safety_screen.dart`
- ✅ batch 7 (সুরক্ষা চালু = নরম হিরো, প্রতিটি উপায় জীবন্ত কার্ডে) — `screens/sos_triggers_screen.dart`
- ✅ batch 7 (পেজ নিয়ম: সুইচ আগে (হিরো কার্ডে), ব্যাখ্যা পরে) — `screens/voice_sos_screen.dart`

## ৫. নিরাপদ যাত্রা

- ⬜ — `screens/guardian_journey_screen.dart`
- ⬜ — `screens/journey_fake_call_screen.dart`
- ⬜ — `screens/journey_live_screen.dart`
- ⬜ — `screens/journey_map_pick_screen.dart`
- ⬜ — `screens/journey_settings_screen.dart`
- ⬜ — `screens/journey_start_screen.dart`
- ✅ batch 5 (DS খালি অবস্থা (সুবিধা+কীভাবে+বড় বোতাম), স্কেলেটন) — `screens/journey_watch_screen.dart`
- ⬜ — `screens/safe_journey/sj_child_school_screen.dart`
- ✅ batch 5 (চলমান যাত্রা সবার ওপরে, বাছাই করা মোড = নীল কার্ড, অ্যাকশন টাইল) — `screens/safe_journey/sj_hub_screen.dart`
- ⬜ — `screens/safe_journey/sj_private_ask_screen.dart`
- ⬜ — `screens/safe_journey/sj_share_screen.dart`
- ⬜ — `screens/train/journey_train_pick_screen.dart`

## ৬. সিসিটিভি

- ⬜ — `billing/cctv_plan_screen.dart`
- ⬜ — `bizai/cctv_accuracy_screen.dart`
- ⬜ — `cctvconnect/cctv_connect_screen.dart`
- ⬜ — `cctvconnect/link_devices_screen.dart`
- ⬜ — `cctvguard/vendor_live_screen.dart`
- ⬜ — `phonecam/phone_camera_screen.dart`
- ⬜ — `screens/camera/camera_preview_edit_screen.dart`
- ⬜ — `screens/camera/camera_screen.dart`
- ⬜ — `screens/circle_guardians_screen.dart`
- ⬜ — `screens/guardian_request_screen.dart`
- ⬜ — `screens/watchman/activity_screen.dart`
- ⬜ — `screens/watchman/auto_guard_screen.dart`
- ⬜ — `screens/watchman/cash_guard_screen.dart`
- ⬜ — `screens/watchman/cctv_alarm_call_screen.dart`
- ⬜ — `screens/watchman/cctv_grid_screen.dart`
- ⬜ — `screens/watchman/cctv_recording_screen.dart`
- ⬜ — `screens/watchman/cctv_watch_screen.dart`
- ⬜ — `screens/watchman/cctvx_guard_screen.dart`
- ⬜ — `screens/watchman/guard_box_screen.dart`
- ⬜ — `screens/watchman/watchman_screen.dart`

## ৭. মাই সার্কেল চ্যাট

- ⬜ — `bizai/shop_chat_screen.dart`
- ⬜ — `carecall/carecall_new_screen.dart`
- ⬜ — `carecall/carecall_ring_screen.dart`
- ✅ batch 5 (DS খালি/ত্রুটি অবস্থা, স্কেলেটন, DS নতুন বোতাম) — `carecall/carecall_screen.dart`
- ⬜ — `push/incoming_call_screen.dart`
- ✅ batch 3 (শুরু-কার্ড আগে, সাদা উত্তর-কার্ড) — `screens/ai_chat_screen.dart`
- ⬜ — `screens/business/khata_chat_screen.dart`
- ✅ batch 5 (DS খালি অবস্থা + কীভাবে, DS ফিল্টার চিপ, স্কেলেটন) — `screens/circle_call_history_screen.dart`
- ⬜ — `screens/circle_call_info_screen.dart`
- ⬜ — `screens/circle_call_screen.dart`
- ⬜ — `screens/circle_chat_screen.dart`
- ⬜ — `screens/circle_extras_broadcast_screen.dart`
- ✅ batch 5 (দুই টুল এক কার্ডে, আইকন-ব্যাজ) — `screens/circle_extras_hub_screen.dart`
- ⬜ — `screens/circle_extras_scheduled_screen.dart`
- ⬜ — `screens/circle_group_chat_screen.dart`
- ⬜ — `screens/circle_group_info_screen.dart`
- ✅ batch 5 (গ্রুপগুলো এক কার্ডে, খালি অবস্থায় গ্রুপ বানান বোতাম) — `screens/circle_group_list_screen.dart`
- ✅ batch 5 (প্রতিটি অংশ আলাদা কার্ডে, DS ত্রুটি অবস্থা) — `screens/circle_privacy_screen.dart`
- ✅ batch 5 (DS খালি অবস্থা (যোগ করুন/আবার চেষ্টা), স্কেলেটন, শিরোনাম) — `screens/circle_screen.dart`
- ✅ batch 5 (DS অ্যাভাটার, আঁকা খোঁজ-ইঙ্গিত) — `screens/circle_search_screen.dart`
- ⬜ — `screens/circle_status_composer_screen.dart`
- ⬜ — `screens/circle_status_screen.dart`
- ⬜ — `screens/circle_status_viewer_screen.dart`
- ⬜ — `screens/messenger/admin_moderation_screen.dart`
- ⬜ — `screens/messenger/admin_users_screen.dart`
- ⬜ — `screens/messenger/broadcast_lists_screen.dart`
- ⬜ — `screens/messenger/channel_admin_screen.dart`
- ⬜ — `screens/messenger/channel_detail_screen.dart`
- ⬜ — `screens/messenger/channel_list_screen.dart`
- ⬜ — `screens/messenger/communities_home_screen.dart`
- ⬜ — `screens/messenger/community_detail_screen.dart`
- ⬜ — `screens/messenger/community_list_screen.dart`
- ⬜ — `screens/messenger/community_members_screen.dart`
- ⬜ — `screens/messenger/community_message_requests_screen.dart`
- ⬜ — `screens/messenger/community_settings_screen.dart`
- ⬜ — `screens/messenger/connection_requests_screen.dart`
- ⬜ — `screens/messenger/contact_info_screen.dart`
- ⬜ — `screens/messenger/contacts_screen.dart`
- ⬜ — `screens/messenger/discover_screen.dart`
- ⬜ — `screens/messenger/linked_devices_screen.dart`
- ⬜ — `screens/messenger/m3_add_to_circle_screen.dart`
- ⬜ — `screens/messenger/m3_requests_screen.dart`
- ⬜ — `screens/messenger/messenger_home_screen.dart`
- ⬜ — `screens/messenger/messenger_profile_screen.dart`
- ⬜ — `screens/messenger/messenger_settings_screen.dart`
- ⬜ — `screens/messenger/moderation_appeal_screen.dart`
- ⬜ — `screens/messenger/moderation_policy_screen.dart`
- ⬜ — `screens/messenger/msgr_set_account_screen.dart`
- ⬜ — `screens/messenger/msgr_set_calls_screen.dart`
- ⬜ — `screens/messenger/msgr_set_change_number_screen.dart`
- ⬜ — `screens/messenger/msgr_set_chats_screen.dart`
- ⬜ — `screens/messenger/msgr_set_notifications_screen.dart`
- ⬜ — `screens/messenger/msgr_set_privacy_screen.dart`
- ⬜ — `screens/messenger/msgr_set_storage_screen.dart`
- ⬜ — `screens/messenger/msgr_set_twostep_screen.dart`
- ⬜ — `screens/messenger/starred_messages_screen.dart`
- ⬜ — `screens/pa/call_email_screen.dart`
- ⬜ — `screens/train/train_chat_screen.dart`

## ৮. হিসাব ও ফাইন্যান্স

- ⬜ — `billing/refund_screen.dart`
- ⬜ — `safe_plans/safe_ad_unlock_screen.dart`
- ⬜ — `safe_plans/safe_plans_screen.dart`
- ✅ batch 6 (সাইন-ইন, ডিভাইস, হারালে — আলাদা কার্ড; DS ত্রুটি/স্কেলেটন) — `screens/account_security_screen.dart`
- ⬜ — `screens/account_standing_screen.dart`
- ⬜ — `screens/business/acct/acct_audit_screen.dart`
- ⬜ — `screens/business/acct/acct_close_screen.dart`
- ⬜ — `screens/business/acct/acct_entry_screen.dart`
- ⬜ — `screens/business/acct/acct_home_screen.dart`
- ⬜ — `screens/business/acct/acct_opening_screen.dart`
- ⬜ — `screens/business/acct/acct_reports_screen.dart`
- ⬜ — `screens/business/business_plans_screen.dart`
- ⬜ — `screens/day_planner_screen.dart`
- ⬜ — `screens/delete_account_screen.dart`
- ✅ batch 6 (পেজ নিয়ম: টুলগুলোই আগে, গ্রুপ = এক কার্ড, লম্বা ব্যানার বাদ) — `screens/finance_screen.dart`
- ⬜ — `screens/mess_accounting_screen.dart`
- ⬜ — `screens/money_budget_screen.dart`
- ⬜ — `screens/money_import_screen.dart`
- ⬜ — `screens/money_loan_detail_screen.dart`
- ⬜ — `screens/money_networth_screen.dart`
- ⬜ — `screens/money_report_screen.dart`
- ✅ batch 3 (হিসাব সারাংশ) — `screens/money_screen.dart`
- ⬜ — `screens/money_tax_screen.dart`
- ⬜ — `screens/money_trends_screen.dart`
- ⬜ — `screens/money_voice_screen.dart`
- ⬜ — `screens/money_wrapped_screen.dart`
- ✅ batch 6 (মোট বাকি = হিরো কার্ডে বড় সংখ্যা, DS খালি অবস্থা) — `screens/my_dues_screen.dart`
- ⬜ — `screens/my_dues_shop_screen.dart`
- ⬜ — `screens/plans_screen.dart`
- ⬜ — `screens/probashi/probashi_plan_screen.dart`
- ⬜ — `screens/remittance/remit_entry_screen.dart`
- ⬜ — `screens/remittance/remit_report_screen.dart`
- ⬜ — `screens/remittance/remittance_screen.dart`
- ⬜ — `screens/travel_planner_screen.dart`

## ৯. খাতা

- ✅ batch 5 (DS ত্রুটি অবস্থা) — `screens/business/khata_entry_screen.dart`
- ✅ batch 3 (খাতা — নরম হিরো, বড় অঙ্ক) — `screens/business/khata_screen.dart`

## ১০. মেস ও ব্যাচেলর

- ⬜ — `messaging/media/video_player_screen.dart`

## ১১. মাই বিজনেস

- ⬜ — `bizai/my_shops_screen.dart`
- ⬜ — `bizai/weekly_report_screen.dart`
- ⬜ — `bizai/winback_screen.dart`
- ⬜ — `screens/agent_core/biz_brief_screen.dart`
- ⬜ — `screens/booking/booking_biz_screen.dart`
- ⬜ — `screens/business/ai_assistant_screen.dart`
- ⬜ — `screens/business/bargain_rules_screen.dart`
- ⬜ — `screens/business/bizagent/approvals_screen.dart`
- ⬜ — `screens/business/bizagent/seller_activity_screen.dart`
- ⬜ — `screens/business/bizagent/seller_agent_screen.dart`
- ⬜ — `screens/business/bizagent/seller_inbox_screen.dart`
- ⬜ — `screens/business/bizagent/seller_setup_screen.dart`
- ⬜ — `screens/business/books_screen.dart`
- ✅ batch 3 (মাই বিজনেস হেডার) — `screens/business/business_hub_screen.dart`
- ⬜ — `screens/business/business_setup_screen.dart`
- ⬜ — `screens/business/cashbox_screen.dart`
- ⬜ — `screens/business/customers_screen.dart`
- ⬜ — `screens/business/demand_map_screen.dart`
- ⬜ — `screens/business/invoice/invoice_screen.dart`
- ⬜ — `screens/business/invoice/invoice_settings_screen.dart`
- ⬜ — `screens/business/invoice/invoices_screen.dart`
- ⬜ — `screens/business/invoice/new_invoice_screen.dart`
- ✅ batch 6 (জীবন্ত অর্ডার কার্ড, DS খালি/ত্রুটি) — `screens/business/orders_screen.dart`
- ✅ batch 6 (জীবন্ত BizCard, DS ত্রুটি অবস্থা, পূর্ণ-চওড়া বোতাম) — `screens/business/payments_screen.dart`
- ⬜ — `screens/business/products_screen.dart`
- ⬜ — `screens/business/quick_sell_screen.dart`
- ✅ batch 6 (বিক্রি = নরম হিরো (বড় সংখ্যা), সমান উচ্চতার লাভ/খরচ কার্ড) — `screens/business/reports_screen.dart`
- ⬜ — `screens/business/sms_balance_screen.dart`
- ⬜ — `screens/business/staff_screen.dart`
- ⬜ — `screens/business/supplier_market_screen.dart`
- ⬜ — `screens/business/tagada_send_screen.dart`
- ⬜ — `screens/business_screen.dart`
- ⬜ — `screens/crm/crm_aftersale_screen.dart`
- ⬜ — `screens/crm/crm_automation_screen.dart`
- ⬜ — `screens/crm/crm_bulk_send_screen.dart`
- ⬜ — `screens/crm/crm_capture_screen.dart`
- ⬜ — `screens/crm/crm_companies_screen.dart`
- ⬜ — `screens/crm/crm_company_detail_screen.dart`
- ⬜ — `screens/crm/crm_dashboard_screen.dart`
- ⬜ — `screens/crm/crm_erp_handoff_screen.dart`
- ⬜ — `screens/crm/crm_firstrun_screen.dart`
- ⬜ — `screens/crm/crm_home_screen.dart`
- ⬜ — `screens/crm/crm_lead_detail_screen.dart`
- ⬜ — `screens/crm/crm_lead_form_screen.dart`
- ⬜ — `screens/crm/crm_leads_screen.dart`
- ⬜ — `screens/crm/crm_pipeline_screen.dart`
- ⬜ — `screens/crm/crm_proposal_advanced_screen.dart`
- ⬜ — `screens/crm/crm_proposal_screen.dart`
- ⬜ — `screens/crm/crm_reports_screen.dart`
- ⬜ — `screens/crm/crm_team_advanced_screen.dart`
- ⬜ — `screens/crm/crm_team_screen.dart`
- ⬜ — `screens/crm/crm_today_screen.dart`
- ⬜ — `screens/crm/customer_history_screen.dart`
- ⬜ — `screens/crm/customer_list_screen.dart`
- ⬜ — `screens/crm_contacts_screen.dart`
- ⬜ — `screens/pa/biz_travel_events_screen.dart`
- ⬜ — `screens/shop_box_mode_screen.dart`
- ⬜ — `screens/shop_box_screen.dart`
- ⬜ — `screens/shop_eod_screen.dart`
- ⬜ — `screens/shop_live_screen.dart`

## ১২. এআই চ্যাট

- ⬜ — `screens/agent_core/agent_approvals_screen.dart`
- ⬜ — `screens/agent_core/agent_core_screen.dart`
- ⬜ — `screens/agent_core/agent_history_screen.dart`
- ⬜ — `screens/agent_core/life_graph_screen.dart`
- ⬜ — `screens/agent_studio_screen.dart`
- ⬜ — `screens/agent_thread_screen.dart`
- ⬜ — `screens/voice_assistant_screen.dart`
- ⬜ — `screens/voice_assistant_settings_screen.dart`

## ১৩. ল্যাঙ্গুয়েজ পার্টনার

- ⬜ — `screens/language_pack_screen.dart`
- ⬜ — `screens/language_partner_screen.dart`
- ⬜ — `screens/language_picker_screen.dart`

## ১৪. কুরআন

- ✅ batch 6 (শান্ত: আজকের লক্ষ্য = নরম হিরো, স্কেলেটন) — `quran_learn/quran_learn_screen.dart`
- ✅ batch 6 (শান্ত: পড়া চালিয়ে যান = নরম হিরো, সূরা এক কার্ডে, আভা নেই) — `screens/quran_screen.dart`

## ১৫. সেটিংস

- ✅ batch 5 (অনুমতি বন্ধ থাকলে সেটাই সবার ওপরে, রঙিন আইকন-ব্যাজ কার্ড) — `push/push_settings_screen.dart`
- ✅ batch 2 (গ্রুপ কার্ড) — `screens/settings_screen.dart`
- ⬜ — `screens/vehicle_tracker_settings_screen.dart`

## ১৬. বাকি সব স্ক্রিন

- ⬜ — `growth/invite_screen.dart`
- ⬜ — `invite/invite_join_screen.dart`
- ⬜ — `phonecam/phonecam_timeline_screen.dart`
- ⬜ — `screens/about_screen.dart`
- ⬜ — `screens/accessibility_mode_screen.dart`
- ⬜ — `screens/action_center_screen.dart`
- ⬜ — `screens/admin/cost_flags_screen.dart`
- ⬜ — `screens/admin/discover_manager_screen.dart`
- ⬜ — `screens/admin/owner_pnl_screen.dart`
- ⬜ — `screens/admin/server_address_screen.dart`
- ⬜ — `screens/ai_knowledge_screen.dart`
- ⬜ — `screens/always_on_protection_screen.dart`
- ⬜ — `screens/app_update_screen.dart`
- ⬜ — `screens/area_community_screen.dart`
- ⬜ — `screens/assisto_chats_screen.dart`
- ⬜ — `screens/battery_guidance_screen.dart`
- ⬜ — `screens/birthdays_screen.dart`
- ⬜ — `screens/blog_writer_screen.dart`
- ⬜ — `screens/booking/booking_detail_screen.dart`
- ⬜ — `screens/booking/booking_setup_screen.dart`
- ⬜ — `screens/booking/my_bookings_screen.dart`
- ⬜ — `screens/car_mode_screen.dart`
- ⬜ — `screens/career/cv_export_screen.dart`
- ⬜ — `screens/career/interview_role_screen.dart`
- ⬜ — `screens/career/job_find_screen.dart`
- ⬜ — `screens/city/city_around_screen.dart`
- ⬜ — `screens/city/city_directory_screen.dart`
- ⬜ — `screens/city/city_metro_screen.dart`
- ⬜ — `screens/city/city_reports_screen.dart`
- ⬜ — `screens/city/city_service_screen.dart`
- ⬜ — `screens/city/city_women_screen.dart`
- ⬜ — `screens/contract_analyzer_screen.dart`
- ⬜ — `screens/cost_estimator_screen.dart`
- ✅ batch 5 (জীবন্ত কার্ড, সতর্কতা = লাল কার্ড, বড় সংখ্যা ঘন) — `screens/credits_screen.dart`
- ⬜ — `screens/cv_builder_screen.dart`
- ⬜ — `screens/daily_brief_screen.dart`
- ⬜ — `screens/daily_challenges_screen.dart`
- ⬜ — `screens/daily_tools_screen.dart`
- ⬜ — `screens/deletion_grace_screen.dart`
- ⬜ — `screens/dictionary_screen.dart`
- ⬜ — `screens/doc_scanner_screen.dart`
- ⬜ — `screens/doctor_serial_screen.dart`
- ⬜ — `screens/domestic_staff_screen.dart`
- ⬜ — `screens/e2_restore_screen.dart`
- ⬜ — `screens/encrypted_backup_screen.dart`
- ⬜ — `screens/exam_result_screen.dart`
- ⬜ — `screens/expense_split_screen.dart`
- ⬜ — `screens/farmer_mode_screen.dart`
- ⬜ — `screens/fitness_partner_screen.dart`
- ⬜ — `screens/fleet_dashboard_screen.dart`
- ⬜ — `screens/food_calories_screen.dart`
- ⬜ — `screens/guide_screen.dart`
- ⬜ — `screens/ielts_screen.dart`
- ⬜ — `screens/in_progress_screen.dart`
- ⬜ — `screens/inbox_screen.dart`
- ⬜ — `screens/intruder_consent_screen.dart`
- ⬜ — `screens/jobs_screen.dart`
- ⬜ — `screens/kid_audio/kid_audio_screen.dart`
- ⬜ — `screens/kid_school_screen.dart`
- ⬜ — `screens/landlord_tenant_screen.dart`
- ⬜ — `screens/learn_cert_screen.dart`
- ⬜ — `screens/legal_screen.dart`
- ⬜ — `screens/login_screen.dart`
- ⬜ — `screens/lost_stolen_screen.dart`
- ⬜ — `screens/market/market_need_screen.dart`
- ⬜ — `screens/market/market_screen.dart`
- ⬜ — `screens/meetings_screen.dart`
- ⬜ — `screens/memory_screen.dart`
- ⬜ — `screens/missing/missing_detail_screen.dart`
- ⬜ — `screens/missing/missing_hub_screen.dart`
- ⬜ — `screens/missing/missing_optin_screen.dart`
- ⬜ — `screens/missing/missing_post_screen.dart`
- ⬜ — `screens/missing/missing_thread_screen.dart`
- ⬜ — `screens/mktengine/mkt_engine_screen.dart`
- ⬜ — `screens/mock_interview_screen.dart`
- ⬜ — `screens/my_lost_phone_screen.dart`
- ⬜ — `screens/my_vehicles_screen.dart`
- ⬜ — `screens/name_about_screen.dart`
- ⬜ — `screens/nearby_screen.dart`
- ⬜ — `screens/nominee_screen.dart`
- ⬜ — `screens/notes_todos_screen.dart`
- ✅ batch 5 (জীবন্ত কার্ড, না-পড়া = নীলচে + ডট, এক সারির ফিল্টার চিপ) — `screens/notification_centre_screen.dart`
- ⬜ — `screens/offline_status_screen.dart`
- ⬜ — `screens/onboarding_screen.dart`
- ⬜ — `screens/otp/email_verify_screen.dart`
- ⬜ — `screens/otp/otp_login_screen.dart`
- ⬜ — `screens/otp/otp_verify_screen.dart`
- ⬜ — `screens/owner_analytics_screen.dart`
- ⬜ — `screens/pa/board_pack_screen.dart`
- ⬜ — `screens/pa/delegate_access_screen.dart`
- ⬜ — `screens/pa/dept_update_screen.dart`
- ⬜ — `screens/pa/expense_voucher_screen.dart`
- ⬜ — `screens/pa/filing_screen.dart`
- ⬜ — `screens/pa/letters_screen.dart`
- ⬜ — `screens/pa/liaison_screen.dart`
- ⬜ — `screens/pa/lifestyle_screen.dart`
- ⬜ — `screens/pa/meeting_minutes_screen.dart`
- ⬜ — `screens/pa/pa_hub_screen.dart`
- ⬜ — `screens/pa/pa_meeting_brief_screen.dart`
- ⬜ — `screens/pa/pa_schedule_screen.dart`
- ⬜ — `screens/pa/pa_travel_screen.dart`
- ⬜ — `screens/pa/personal_tasks_screen.dart`
- ⬜ — `screens/pa/pr_press_screen.dart`
- ⬜ — `screens/pa/project_tracking_screen.dart`
- ⬜ — `screens/pa/ps_today_screen.dart`
- ⬜ — `screens/pa/research_prep_screen.dart`
- ⬜ — `screens/pa/shoot_logistics_screen.dart`
- ⬜ — `screens/pa/social_inbox_screen.dart`
- ⬜ — `screens/pa/star_deals_screen.dart`
- ⬜ — `screens/pa/vip_stakeholder_screen.dart`
- ⬜ — `screens/pa/visitor_filter_screen.dart`
- ⬜ — `screens/password_reset_confirm_screen.dart`
- ⬜ — `screens/password_reset_screen.dart`
- ⬜ — `screens/payment_ladder_screen.dart`
- ⬜ — `screens/photo_studio_screen.dart`
- ⬜ — `screens/prepaid_meter_screen.dart`
- ⬜ — `screens/price_radar_screen.dart`
- ⬜ — `screens/proactive_ai_screen.dart`
- ⬜ — `screens/probashi/probashi_pool_screen.dart`
- ⬜ — `screens/probashi/probashi_reports_screen.dart`
- ⬜ — `screens/probashi_screen.dart`
- ⬜ — `screens/quick_tools_screen.dart`
- ⬜ — `screens/qurbani_screen.dart`
- ⬜ — `screens/ramadan_screen.dart`
- ⬜ — `screens/recovery_screen.dart`
- ⬜ — `screens/referral_screen.dart`
- ✅ batch 5 (জীবন্ত কার্ড, মিস হওয়া = লাল কার্ড) — `screens/reminders_screen.dart`
- ⬜ — `screens/report_stolen_screen.dart`
- ⬜ — `screens/retention/retention_screen.dart`
- ⬜ — `screens/ride_food_screen.dart`
- ⬜ — `screens/ring_checklist_screen.dart`
- ⬜ — `screens/safe_arrival_screen.dart`
- ⬜ — `screens/samity_screen.dart`
- ⬜ — `screens/saved_items_screen.dart`
- ⬜ — `screens/savings_challenge_screen.dart`
- ⬜ — `screens/scam_screen.dart`
- ⬜ — `screens/security_checkup_screen.dart`
- ⬜ — `screens/security_screen.dart`
- ⬜ — `screens/sell_my_phone_screen.dart`
- ⬜ — `screens/smartwatch_screen.dart`
- ⬜ — `screens/social_compose_screen.dart`
- ⬜ — `screens/spending_advice_screen.dart`
- ⬜ — `screens/student_corner_screen.dart`
- ⬜ — `screens/subscriptions_screen.dart`
- ⬜ — `screens/support_center_screen.dart`
- ⬜ — `screens/task_manager_screen.dart`
- ⬜ — `screens/train/dest_alarm_screen.dart`
- ⬜ — `screens/train/train_tracker_screen.dart`
- ⬜ — `screens/train/trip_recorder_screen.dart`
- ⬜ — `screens/transcription_screen.dart`
- ⬜ — `screens/trust_page_screen.dart`
- ⬜ — `screens/unseen_world_screen.dart`
- ⬜ — `screens/used_phone_check_screen.dart`
- ⬜ — `screens/vault_screen.dart`
- ⬜ — `screens/vehicle_drivers_screen.dart`
- ⬜ — `screens/vehicle_fence_editor_screen.dart`
- ⬜ — `screens/vehicle_obd_screen.dart`
- ⬜ — `screens/vehicle_report_screen.dart`
- ⬜ — `screens/vehicle_tracker_screen.dart`
- ⬜ — `screens/vehicle_tracking_screen.dart`
- ⬜ — `screens/voice_mood_screen.dart`
- ⬜ — `screens/wake_disclosure_screen.dart`
- ⬜ — `screens/wake_oem_guide_screen.dart`
- ⬜ — `screens/watch_feed_screen.dart`
- ⬜ — `screens/watched_phones_screen.dart`
- ⬜ — `screens/web_photo_link_screen.dart`
- ⬜ — `screens/wedding_events_screen.dart`
- ⬜ — `screens/wellness_tracker_screen.dart`
- ⬜ — `screens/world/world_ask_screen.dart`
- ⬜ — `screens/world/world_guide_hub_screen.dart`
- ⬜ — `screens/world/world_hub_screen.dart`
- ⬜ — `screens/world/world_jobs_screen.dart`
- ⬜ — `screens/world/world_mcq_screen.dart`
- ⬜ — `screens/world/world_today_screen.dart`
- ⬜ — `vault/vault_e2e_screen.dart`
- ⬜ — `vault/vault_recovery_screen.dart`
- ⬜ — `vault/vault_security_screen.dart`
