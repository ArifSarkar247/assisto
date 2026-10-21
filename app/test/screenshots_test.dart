import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/state.dart';
import 'package:assisto/models.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/login_screen.dart';
import 'package:assisto/screens/language_picker_screen.dart';
import 'package:assisto/screens/home_screen.dart';
import 'package:assisto/screens/agent_thread_screen.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';
import 'package:assisto/screens/app_drawer.dart';
import 'package:assisto/screens/ai_chat_screen.dart';
import 'package:assisto/screens/nearby_screen.dart';
import 'package:assisto/screens/used_phone_check_screen.dart';
import 'package:assisto/screens/my_vehicles_screen.dart';
import 'package:assisto/screens/smartwatch_screen.dart';
import 'package:assisto/screens/messenger/messenger_home_screen.dart';
import 'package:assisto/screens/messenger/messenger_settings_screen.dart';
import 'package:assisto/screens/messenger/contact_info_screen.dart';
import 'package:assisto/screens/notification_centre_screen.dart';
import 'package:assisto/screens/messenger/messenger_profile_screen.dart';
import 'package:assisto/screens/messenger/contacts_screen.dart';
import 'package:assisto/screens/camera/camera_permission_gate.dart';
import 'package:assisto/screens/encrypted_backup_screen.dart';
import 'package:assisto/screens/voice_mood_screen.dart';
import 'package:assisto/screens/proactive_ai_screen.dart';
import 'package:assisto/screens/area_community_screen.dart';
import 'package:assisto/screens/doctor_serial_screen.dart';
import 'package:assisto/screens/business/supplier_market_screen.dart';
import 'package:assisto/screens/business/demand_map_screen.dart';
import 'package:assisto/screens/pa/star_deals_screen.dart';
import 'package:assisto/screens/pa/vip_stakeholder_screen.dart';
import 'package:assisto/screens/pa/letters_screen.dart';
import 'package:assisto/screens/pa/expense_voucher_screen.dart';
import 'package:assisto/screens/quick_tools_screen.dart';
import 'package:assisto/screens/daily_brief_screen.dart';
import 'package:assisto/screens/blog_writer_screen.dart';
import 'package:assisto/screens/cv_builder_screen.dart';
import 'package:assisto/screens/doc_scanner_screen.dart';
import 'package:assisto/screens/transcription_screen.dart';
import 'package:assisto/screens/travel_planner_screen.dart';
import 'package:assisto/screens/contract_analyzer_screen.dart';
import 'package:assisto/screens/cost_estimator_screen.dart';
import 'package:assisto/screens/mock_interview_screen.dart';
import 'package:assisto/screens/language_partner_screen.dart';
import 'package:assisto/screens/spending_advice_screen.dart';
import 'package:assisto/screens/price_radar_screen.dart';
import 'package:assisto/screens/health_timeline_screen.dart';
import 'package:assisto/screens/wellness_tracker_screen.dart';
import 'package:assisto/screens/daily_challenges_screen.dart';
import 'package:assisto/screens/saved_items_screen.dart';
import 'package:assisto/screens/kid_school_screen.dart';
import 'package:assisto/screens/fitness_partner_screen.dart';
import 'package:assisto/screens/domestic_staff_screen.dart';
import 'package:assisto/screens/savings_challenge_screen.dart';
import 'package:assisto/screens/security_checkup_screen.dart';
import 'package:assisto/screens/farmer_mode_screen.dart';
import 'package:assisto/screens/trust_page_screen.dart';
import 'package:assisto/screens/blood_donor_screen.dart';
import 'package:assisto/screens/prepaid_meter_screen.dart';
import 'package:assisto/screens/qurbani_screen.dart';
import 'package:assisto/screens/probashi_screen.dart';
import 'package:assisto/screens/student_corner_screen.dart';
import 'package:assisto/screens/wedding_events_screen.dart';
import 'package:assisto/screens/task_manager_screen.dart';
import 'package:assisto/screens/mess_accounting_screen.dart';
import 'package:assisto/screens/expense_split_screen.dart';
import 'package:assisto/screens/samity_screen.dart';
import 'package:assisto/screens/landlord_tenant_screen.dart';
import 'package:assisto/screens/pa/pa_hub_screen.dart';
import 'package:assisto/screens/pa/pa_schedule_screen.dart';
import 'package:assisto/screens/pa/visitor_filter_screen.dart';
import 'package:assisto/screens/pa/liaison_screen.dart';
import 'package:assisto/screens/pa/personal_tasks_screen.dart';
import 'package:assisto/screens/pa/delegate_access_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_privacy_screen.dart';
import 'package:assisto/screens/ai_knowledge_screen.dart';
import 'package:assisto/screens/admin/cost_flags_screen.dart';
import 'package:assisto/screens/admin/server_address_screen.dart';
import 'package:assisto/screens/app_update_screen.dart';
import 'package:assisto/screens/about_screen.dart';
import 'package:assisto/screens/support_center_screen.dart';
import 'package:assisto/screens/social_compose_screen.dart';
import 'package:assisto/screens/messenger/admin_users_screen.dart';
import 'package:assisto/screens/messenger/admin_moderation_screen.dart';
import 'package:assisto/screens/money_voice_screen.dart';
import 'package:assisto/screens/voice_assistant_screen.dart';
import 'package:assisto/screens/voice_assistant_settings_screen.dart';
import 'package:assisto/voice/va_actions.dart';
import 'package:assisto/voice/va_confirm_sheet.dart';
import 'package:assisto/screens/money_wrapped_screen.dart';
import 'package:assisto/screens/money_tax_screen.dart';
import 'package:assisto/screens/money_budget_screen.dart';
import 'package:assisto/screens/offline_status_screen.dart';
import 'package:assisto/screens/disaster_alerts_screen.dart';
import 'package:assisto/screens/action_center_screen.dart';
import 'package:assisto/screens/owner_analytics_screen.dart';
import 'package:assisto/screens/name_about_screen.dart';
import 'package:assisto/screens/password_reset_screen.dart';
import 'package:assisto/screens/safe_arrival_screen.dart';
import 'package:assisto/screens/elderly_home_screen.dart';
import 'package:assisto/screens/payment_ladder_screen.dart';
import 'package:assisto/screens/settings_screen.dart';
import 'package:assisto/screens/in_progress_screen.dart';
import 'package:assisto/screens/money_screen.dart';
import 'package:assisto/screens/vault_screen.dart';
import 'package:assisto/screens/family_screen.dart';
import 'package:assisto/screens/medicine_history_screen.dart';
import 'package:assisto/screens/emergency_screen.dart';
import 'package:assisto/screens/reminders_screen.dart';
import 'package:assisto/screens/notes_todos_screen.dart';
import 'package:assisto/screens/memory_screen.dart';
import 'package:assisto/screens/subscriptions_screen.dart';
import 'package:assisto/screens/plans_screen.dart';
import 'package:assisto/screens/finance_screen.dart';
import 'package:assisto/screens/watch_feed_screen.dart';
import 'package:assisto/screens/jobs_screen.dart';
import 'package:assisto/screens/nominee_screen.dart';
import 'package:assisto/screens/crm_contacts_screen.dart';
import 'package:assisto/screens/crm/crm_today_screen.dart';
import 'package:assisto/screens/crm/crm_leads_screen.dart';
import 'package:assisto/screens/crm/crm_pipeline_screen.dart';
import 'package:assisto/screens/crm/crm_dashboard_screen.dart';
import 'package:assisto/screens/crm/crm_team_screen.dart';
import 'package:assisto/screens/crm/crm_companies_screen.dart';
import 'package:assisto/screens/crm/crm_reports_screen.dart';
import 'package:assisto/screens/crm/crm_lead_detail_screen.dart';
import 'package:assisto/screens/crm/crm_home_screen.dart';
import 'package:assisto/screens/money_import_screen.dart';
import 'package:assisto/screens/crm/crm_proposal_screen.dart';
import 'package:assisto/screens/business/selling_common.dart' show SellRole;
import 'package:assisto/screens/business/sale_void_dialog.dart';
import 'package:assisto/screens/business_screen.dart';
import 'package:assisto/screens/inbox_screen.dart';
import 'package:assisto/screens/guide_screen.dart';
import 'package:assisto/screens/agent_studio_screen.dart';
import 'package:assisto/screens/battery_guidance_screen.dart';
import 'package:assisto/screens/onboarding_screen.dart';
import 'package:assisto/screens/scam_screen.dart';
import 'package:assisto/screens/safety_screen.dart';
import 'package:assisto/screens/health_tips_screen.dart';
import 'package:assisto/screens/medicine_db_screen.dart';
import 'package:assisto/screens/birthdays_screen.dart';
import 'package:assisto/screens/meetings_screen.dart';
import 'package:assisto/screens/dictionary_screen.dart';
import 'package:assisto/screens/ride_food_screen.dart';
import 'package:assisto/screens/ramadan_screen.dart';
import 'package:assisto/screens/exam_result_screen.dart';
import 'package:assisto/screens/circle_screen.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/screens/circle_call_history_screen.dart';
import 'package:assisto/screens/circle_privacy_screen.dart';
import 'package:assisto/screens/circle_search_screen.dart';
import 'package:assisto/screens/referral_screen.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/journey_sos_screen.dart';
import 'package:assisto/screens/journey_settings_screen.dart';
import 'package:assisto/screens/journey_fake_call_screen.dart';
import 'package:assisto/screens/crm/crm_firstrun_screen.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/screens/legal_screen.dart';
import 'package:assisto/screens/photo_enhance_screen.dart';
import 'package:assisto/screens/unseen_world_screen.dart';
import 'package:assisto/screens/shop_box_screen.dart';
import 'package:assisto/screens/business/business_hub_screen.dart';
import 'package:assisto/screens/business/products_screen.dart';
import 'package:assisto/screens/business/khata_screen.dart';
import 'package:assisto/screens/business/cashbox_screen.dart';
import 'package:assisto/screens/business/customers_screen.dart';
import 'package:assisto/screens/business/quick_sell_screen.dart';
import 'package:assisto/screens/business/reports_screen.dart';
import 'package:assisto/screens/business/orders_screen.dart';
import 'package:assisto/screens/business/payments_screen.dart';
import 'package:assisto/screens/money_report_screen.dart';
import 'package:assisto/screens/money_networth_screen.dart';
import 'package:assisto/screens/money_trends_screen.dart';
import 'package:assisto/screens/money_loan_detail_screen.dart';
import 'package:assisto/screens/shop_eod_screen.dart';
import 'package:assisto/screens/shop_live_screen.dart';
import 'package:assisto/screens/shop_box_mode_screen.dart';
import 'package:assisto/screens/shop_camera_settings.dart';

import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/push/push_settings_screen.dart';
import 'fake_api.dart';

class _NoNet extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? c) => _DeadClient();
}

class _DeadClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw const SocketException('network disabled in screenshot tests');
}

final _outDir = Platform.environment['ASSISTO_SHOT_DIR'] ?? '/home/ubuntu/assisto/screenshots';
// Large-font QA pass: ASSISTO_SHOT_SCALE=1.5 renders with that text scale and
// suffixes files with `_xl` (Premium QA: no clipping at large font).
final _textScale = double.tryParse(Platform.environment['ASSISTO_SHOT_SCALE'] ?? '') ?? 1.0;
final _scaleSuffix = _textScale == 1.0 ? '' : '_xl';

Future<void> _loadFont(String family, String path) async {
  final loader = FontLoader(family);
  loader.addFont(File(path).readAsBytes().then((b) => ByteData.view(b.buffer)));
  await loader.load();
}

AppState _stub({required String lang, FakeMode mode = FakeMode.data}) {
  final s = AppState();
  s.api = FakeApi(mode: mode, lang: lang);
  s.user = AppUser(
      id: 1,
      name: lang == 'bn' ? 'আরিফ' : 'Arif',
      phone: '01712345678',
      email: '',
      autonomyLevel: 2,
      language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  final bn = lang == 'bn';
  if (mode == FakeMode.data) {
    s.reminders.items = [
      {'localId': 'r1', 'serverId': 1, 'pendingOp': 'none', 'data': {'title': bn ? 'বিদ্যুৎ বিল দিন' : 'Pay electricity bill', 'due_at': '2026-10-14T10:00:00', 'done': false, 'recurrence': 'none'}},
      {'localId': 'r2', 'serverId': 2, 'pendingOp': 'none', 'data': {'title': bn ? 'ডাক্তার অ্যাপয়েন্টমেন্ট' : 'Doctor appointment', 'due_at': '2026-10-16T17:30:00', 'done': false, 'recurrence': 'none'}},
    ];
    s.notes.items = [
      {'localId': 'n1', 'serverId': 3, 'pendingOp': 'none', 'data': {'title': bn ? 'বাজারের লিস্ট' : 'Market list', 'body': bn ? 'চাল, ডাল, তেল, ডিম' : 'Rice, lentils, oil, eggs', 'pinned': true}},
    ];
    s.todos.items = [
      {'localId': 't1', 'serverId': 4, 'pendingOp': 'none', 'data': {'title': bn ? 'পাসপোর্ট রিনিউ' : 'Renew passport', 'done': false, 'due_at': null}},
      {'localId': 't2', 'serverId': 5, 'pendingOp': 'none', 'data': {'title': bn ? 'গাড়ির কাগজ' : 'Car papers', 'done': true, 'due_at': null}},
    ];
    s.memory = [
      MemoryItem(localId: 'm1', title: bn ? 'বাসার ওয়াইফাই পাসওয়ার্ড: ***' : 'Home wifi password: ***', category: bn ? 'ব্যক্তিগত' : 'Personal', detail: '', source: 'manual', needsReview: false, updatedAt: DateTime(2026, 10, 10), pendingOp: 'none'),
      MemoryItem(localId: 'm2', title: bn ? 'গাড়ির ইন্স্যুরেন্স নভেম্বরে শেষ' : 'Car insurance ends in November', category: bn ? 'গুরুত্বপূর্ণ' : 'Important', detail: '', source: 'ai', needsReview: true, updatedAt: DateTime(2026, 10, 12), pendingOp: 'none'),
    ];
  }
  return s;
}

List<Map<String, dynamic>> _chat(String lang) {
  final bn = lang == 'bn';
  return [
    {'user': true, 'text': bn ? '৫০০ টাকা খরচ খাবার' : '500 taka food expense'},
    {'user': false, 'text': bn ? 'খরচ লিখে রেখেছি।' : 'Logged your expense.', 'cards': [
      {'type': 'expense', 'title': '৳500 ${bn ? 'খাবার' : 'Food'}', 'subtitle': bn ? 'ক্যাশ' : 'Cash', 'model': 'txn', 'id': 1, 'undo': true}
    ]},
    {'user': true, 'text': bn ? 'কাল সকাল ৮টায় ওষুধ মনে করিয়ে দিও' : 'Remind me medicine tomorrow 8am'},
    {'user': false, 'text': bn ? 'রিমাইন্ডার সেট করেছি।' : 'Reminder set.', 'cards': [
      {'type': 'reminder', 'title': bn ? 'ওষুধ' : 'Medicine', 'subtitle': bn ? 'কাল ৮:০০' : 'Tomorrow 8:00', 'model': 'reminder', 'id': 2, 'undo': true}
    ]},
    {'user': true, 'text': bn ? 'রহিম ভাইকে ২০০০ টাকা bKash পাঠাও' : 'Send 2000 taka to Rahim via bKash'},
    {'user': false, 'text': bn ? 'এটা বাইরের কাজ — আপনার অনুমোদন লাগবে:' : 'This is an external action — needs your approval:', 'cards': [
      {'type': 'approval', 'title': bn ? 'bKash: রহিম — ৳2,000' : 'bKash: Rahim — ৳2,000', 'subtitle': bn ? 'অটোনমি: অনুমোদন নিয়ে। পাঠানোর আগে নিশ্চিত করুন।' : 'Autonomy: ask first. Confirm before sending.'}
    ]},
  ];
}

// Minimal E2E identity + circle member literals for build-61 chat/call/search.
final IdentityKeyPair _identity = SoftwareE2E().generateIdentity();

Map<String, dynamic> _circleMember(String lang) => {
      'id': 1,
      'name': lang == 'bn' ? 'Ammu' : 'Mom',
      'phone': '01710000000',
      'status': 'accepted',
      'relation': 'mother',
      'public_key': _identity.publicKeyB64,
    };

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Screens like SafetyScreen/EmergencyScreen read SharedPreferences in
    // initState; provide an in-memory store so the gallery renders them.
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _NoNet();
    await _loadFont('NotoSansBengali', 'assets/fonts/NotoSansBengali.ttf');
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons = '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(icons).existsSync()) await _loadFont('MaterialIcons', icons);
    Directory(_outDir).createSync(recursive: true);
  });

  // name -> (builder, mode, fullMatrix)
  final specs = <String, ({Widget Function(String) build, FakeMode mode, bool full})>{
    'login': (build: (_) => const LoginScreen(), mode: FakeMode.data, full: true),
    'language_picker': (build: (_) => const LanguagePickerScreen(), mode: FakeMode.data, full: true),
    'home_welcome': (build: (_) => const HomeScreen(), mode: FakeMode.data, full: true),
    'notification_centre': (build: (_) => const NotificationCentreScreen(), mode: FakeMode.data, full: true),
    'msgr_profile': (build: (_) => const MessengerProfileScreen(), mode: FakeMode.data, full: true),
    'contacts': (build: (_) => const ContactsScreen(), mode: FakeMode.data, full: true),
    'cam_perm_ask': (build: (_) => CameraPermissionScreen(denied: false, onPrimary: () {}), mode: FakeMode.data, full: true),
    'cam_perm_denied': (build: (_) => CameraPermissionScreen(denied: true, onPrimary: () {}), mode: FakeMode.data, full: true),
    'home_top': (build: (_) => const HomeScreen(), mode: FakeMode.data, full: true),
    'enc_backup': (build: (_) => const EncryptedBackupScreen(), mode: FakeMode.data, full: true),
    'mood': (build: (_) => const VoiceMoodScreen(), mode: FakeMode.data, full: true),
    'proactive': (build: (_) => const ProactiveAiScreen(), mode: FakeMode.data, full: true),
    'area': (build: (_) => const AreaCommunityScreen(), mode: FakeMode.data, full: true),
    'doctor': (build: (_) => const DoctorSerialScreen(), mode: FakeMode.data, full: true),
    'supplier': (build: (_) => const SupplierMarketScreen(), mode: FakeMode.data, full: true),
    'demand': (build: (_) => const DemandMapScreen(), mode: FakeMode.data, full: true),
    'pa_star_deals': (build: (_) => const StarDealsScreen(), mode: FakeMode.data, full: true),
    'pa_vip': (build: (_) => const VipStakeholderScreen(), mode: FakeMode.data, full: true),
    'pa_letters': (build: (_) => const LettersScreen(), mode: FakeMode.data, full: true),
    'pa_voucher': (build: (_) => const ExpenseVoucherScreen(), mode: FakeMode.data, full: true),
    'quick_tools': (build: (_) => const QuickToolsScreen(), mode: FakeMode.data, full: true),
    'daily_brief': (build: (_) => const DailyBriefScreen(), mode: FakeMode.data, full: true),
    'blog': (build: (_) => const BlogWriterScreen(), mode: FakeMode.data, full: true),
    'cv_builder': (build: (_) => const CvBuilderScreen(), mode: FakeMode.data, full: true),
    'doc_scan': (build: (_) => const DocScannerScreen(), mode: FakeMode.data, full: true),
    'transcribe': (build: (_) => const TranscriptionScreen(), mode: FakeMode.data, full: true),
    'travel': (build: (_) => const TravelPlannerScreen(), mode: FakeMode.data, full: true),
    'contract': (build: (_) => const ContractAnalyzerScreen(), mode: FakeMode.data, full: true),
    'cost_est': (build: (_) => const CostEstimatorScreen(), mode: FakeMode.data, full: true),
    'mock_iv': (build: (_) => const MockInterviewScreen(), mode: FakeMode.data, full: true),
    'lang_partner': (build: (_) => const LanguagePartnerScreen(), mode: FakeMode.data, full: true),
    'spending': (build: (_) => const SpendingAdviceScreen(), mode: FakeMode.data, full: true),
    'price_radar': (build: (_) => const PriceRadarScreen(), mode: FakeMode.data, full: true),
    'health_tl': (build: (_) => const HealthTimelineScreen(), mode: FakeMode.data, full: true),
    'wellness': (build: (_) => const WellnessTrackerScreen(), mode: FakeMode.data, full: true),
    'challenges': (build: (_) => const DailyChallengesScreen(), mode: FakeMode.data, full: true),
    'saved': (build: (_) => const SavedItemsScreen(), mode: FakeMode.data, full: true),
    'kid': (build: (_) => const KidSchoolScreen(), mode: FakeMode.data, full: true),
    'fitness': (build: (_) => const FitnessPartnerScreen(), mode: FakeMode.data, full: true),
    'staff': (build: (_) => const DomesticStaffScreen(), mode: FakeMode.data, full: true),
    'savings': (build: (_) => const SavingsChallengeScreen(), mode: FakeMode.data, full: true),
    'security': (build: (_) => const SecurityCheckupScreen(), mode: FakeMode.data, full: true),
    'farmer': (build: (_) => const FarmerModeScreen(), mode: FakeMode.data, full: true),
    'trust': (build: (_) => const TrustPageScreen(), mode: FakeMode.data, full: true),
    'blood': (build: (_) => const BloodDonorScreen(), mode: FakeMode.data, full: true),
    'meter': (build: (_) => const PrepaidMeterScreen(), mode: FakeMode.data, full: true),
    'qurbani': (build: (_) => const QurbaniScreen(), mode: FakeMode.data, full: true),
    'probashi': (build: (_) => const ProbashiScreen(), mode: FakeMode.data, full: true),
    'student': (build: (_) => const StudentCornerScreen(), mode: FakeMode.data, full: true),
    'wedding': (build: (_) => const WeddingEventsScreen(), mode: FakeMode.data, full: true),
    'task_mgr': (build: (_) => const TaskManagerScreen(), mode: FakeMode.data, full: true),
    'mess_acct': (build: (_) => const MessAccountingScreen(), mode: FakeMode.data, full: true),
    'expense_split': (build: (_) => const ExpenseSplitScreen(), mode: FakeMode.data, full: true),
    'samity': (build: (_) => const SamityScreen(), mode: FakeMode.data, full: true),
    'landlord': (build: (_) => const LandlordTenantScreen(), mode: FakeMode.data, full: true),
    'pa_hub': (build: (_) => const PaHubScreen(), mode: FakeMode.data, full: true),
    'pa_schedule': (build: (_) => const PaScheduleScreen(), mode: FakeMode.data, full: true),
    'pa_visitor': (build: (_) => const VisitorFilterScreen(), mode: FakeMode.data, full: true),
    'pa_liaison': (build: (_) => const LiaisonScreen(), mode: FakeMode.data, full: true),
    'pa_tasks': (build: (_) => const PersonalTasksScreen(), mode: FakeMode.data, full: true),
    'pa_delegate': (build: (_) => const DelegateAccessScreen(), mode: FakeMode.data, full: true),
    'msg_privacy': (build: (_) => const MsgrSetMessagePrivacyScreen(), mode: FakeMode.data, full: true),
    'ai_knowledge': (build: (_) => const AiKnowledgeScreen(), mode: FakeMode.data, full: true),
    'cost_flags': (build: (_) => const CostFlagsScreen(), mode: FakeMode.data, full: true),
    'server_addr': (build: (_) => const ServerAddressScreen(), mode: FakeMode.data, full: true),
    'app_update': (build: (_) => const AppUpdateScreen(), mode: FakeMode.data, full: true),
    'about': (build: (_) => const AboutScreen(), mode: FakeMode.data, full: true),
    'support_center': (build: (_) => const SupportCenterScreen(), mode: FakeMode.data, full: true),
    'social': (build: (_) => const SocialComposeScreen(), mode: FakeMode.data, full: true),
    'admin_users': (build: (_) => const AdminUsersScreen(), mode: FakeMode.data, full: true),
    'admin_mod': (build: (_) => const AdminModerationScreen(), mode: FakeMode.data, full: true),
    'money_budget': (build: (_) => const MoneyBudgetScreen(), mode: FakeMode.data, full: true),
    'money_tax': (build: (_) => const MoneyTaxScreen(), mode: FakeMode.data, full: true),
    'money_wrapped': (build: (_) => const MoneyWrappedScreen(), mode: FakeMode.data, full: true),
    'money_voice': (build: (_) => const MoneyVoiceScreen(), mode: FakeMode.data, full: true),
    // Part 3 (a3-voice): Assisto Voice — welcome, live listening, result
    // cards, the outgoing-action confirm sheet, and the settings card.
    'voice_assistant': (build: (_) => const VoiceAssistantScreen(autoListen: false), mode: FakeMode.data, full: true),
    'voice_listening': (build: (l) => VoiceAssistantScreen(autoListen: false, debugListening: true, debugPartial: l == 'bn' ? 'আম্মুকে ফোন দাও' : 'Call Ammu'), mode: FakeMode.data, full: true),
    'voice_results': (build: (_) => Builder(builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      return VoiceAssistantScreen(autoListen: false, debugTurns: [
        VaTurn(t.vaExReminder, VaOutcome(t.vaReminderSet(t.vaReminderDefault, t.vaTomorrowAt('5:00')), icon: Icons.notifications_active_outlined, title: t.vaReminderDefault, subtitle: t.vaTomorrowAt('5:00'), buttons: [VaButton(t.vaUndo, Icons.undo, () async {})])),
        VaTurn(t.vaExExpense, VaOutcome(t.vaExpenseLogged('৳500', t.vaCatGroceries), icon: Icons.receipt_long_outlined, title: '৳500', subtitle: t.vaCatGroceries, buttons: [VaButton(t.vaUndo, Icons.undo, () async {})])),
        VaTurn(t.vaExTorch, VaOutcome(t.vaTorchOn, icon: Icons.flashlight_on, buttons: [VaButton(t.vaTurnOff, Icons.flashlight_off, () async {})])),
      ]);
    }), mode: FakeMode.data, full: true),
    'voice_confirm': (build: (l) => Builder(builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      return Scaffold(body: Align(alignment: Alignment.bottomCenter, child: Material(
        elevation: 6, borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        color: Theme.of(ctx).colorScheme.surfaceContainerLow,
        child: Padding(padding: const EdgeInsets.only(top: 24), child: VaConfirmSheet(
          icon: Icons.call, title: t.vaConfirmCallTitle(l == 'bn' ? 'আম্মু' : 'Ammu'),
          choices: const [{'name': 'Ammu', 'phone': '01711-000000'}, {'name': 'Ammu (office)', 'phone': '01811-000000'}],
          confirmLabel: t.vaCallNow, debugListening: true)))));
    }), mode: FakeMode.data, full: true),
    'voice_sos_confirm': (build: (_) => Builder(builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      return Scaffold(body: Align(alignment: Alignment.bottomCenter, child: Material(
        elevation: 6, borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        color: Theme.of(ctx).colorScheme.surfaceContainerLow,
        child: Padding(padding: const EdgeInsets.only(top: 24), child: VaConfirmSheet(
          icon: Icons.sos, title: t.vaConfirmSosTitle, detail: t.vaConfirmSosBody,
          confirmLabel: t.vaSendSos, danger: true)))));
    }), mode: FakeMode.data, full: true),
    'voice_settings': (build: (_) => const VoiceAssistantSettingsScreen(debugStatic: true), mode: FakeMode.data, full: true),
    'voice_settings_bottom': (build: (_) => const VoiceAssistantSettingsScreen(debugStatic: true), mode: FakeMode.data, full: true),
    'action_center': (build: (_) => const ActionCenterScreen(), mode: FakeMode.data, full: true),
    'disaster_alerts': (build: (_) => const DisasterAlertsScreen(), mode: FakeMode.data, full: true),
    'offline_status': (build: (_) => const OfflineStatusScreen(), mode: FakeMode.data, full: true),
    'safe_arrival': (build: (_) => const SafeArrivalScreen(), mode: FakeMode.data, full: true),
    'password_reset': (build: (_) => const PasswordResetScreen(), mode: FakeMode.data, full: true),
    'name_about': (build: (_) => const NameAboutScreen(), mode: FakeMode.data, full: true),
    'owner_analytics': (build: (_) => const OwnerAnalyticsScreen(), mode: FakeMode.data, full: true),
    'payment_ladder': (build: (_) => const PaymentLadderScreen(), mode: FakeMode.data, full: true),
    'elderly_home': (build: (_) => const ElderlyHomeScreen(), mode: FakeMode.data, full: true),
    'chat': (build: (l) => Scaffold(appBar: AppBar(title: const Text('Assisto')), body: AgentThreadScreen(debugSeed: _chat(l))), mode: FakeMode.data, full: true),
    'chat_voice': (build: (l) => Scaffold(appBar: AppBar(title: const Text('Assisto')), body: AgentThreadScreen(debugSeed: const [], debugListening: true)), mode: FakeMode.data, full: true),
    'drawer': (build: (_) => Scaffold(body: Row(children: [AppDrawer(onNewChat: () {})])), mode: FakeMode.data, full: true),
    'home_chat_restored': (build: (_) => Scaffold(appBar: AppBar(title: const Text('Assisto')), body: Column(children: [const HomeQuickBar(compact: true, debugRoutes: HomeQuickButtons.defaults), Expanded(child: AgentThreadScreen(sessionId: '11'))])), mode: FakeMode.data, full: true),
    'quick_grid': (build: (_) => const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: HomeQuickBar(debugRoutes: HomeQuickButtons.defaults))), mode: FakeMode.data, full: true),
    // owner default (from /admin/pricing) applied for a not-yet-customized user
    'quick_grid_owner': (build: (_) => const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: HomeQuickBar(debugRoutes: ['emergency', 'money', 'reminders', 'scam', 'nearby', 'notes']))), mode: FakeMode.data, full: true),
    'quick_picker': (build: (_) => const Scaffold(body: QuickButtonsPicker(current: HomeQuickButtons.defaults)), mode: FakeMode.data, full: true),
    'drawer_bottom': (build: (_) => Scaffold(body: Row(children: [AppDrawer(onNewChat: () {})])), mode: FakeMode.data, full: true),
    'messenger': (build: (_) => const MessengerHomeScreen(), mode: FakeMode.data, full: true),
    'messenger_settings': (build: (_) => const MessengerSettingsScreen(), mode: FakeMode.data, full: true),
    'contact_info': (build: (l) => ContactInfoScreen(member: _circleMember(l)), mode: FakeMode.data, full: true),
    'messenger_menu': (build: (_) => const MessengerHomeScreen(), mode: FakeMode.data, full: true),
    'circle_chat_menu': (build: (l) => CircleChatScreen(member: _circleMember(l), identity: _identity), mode: FakeMode.data, full: true),
    'money': (build: (_) => const MoneyScreen(), mode: FakeMode.data, full: true),
    'vault': (build: (_) => const VaultScreen(previewUnlocked: true), mode: FakeMode.data, full: true),
    'family': (build: (_) => const FamilyScreen(), mode: FakeMode.data, full: true),
    'medicine_history': (build: (_) => const MedicineHistoryScreen(member: 'self'), mode: FakeMode.data, full: true),
    'emergency': (build: (_) => const EmergencyScreen(), mode: FakeMode.data, full: true),
    'reminders': (build: (_) => const RemindersScreen(), mode: FakeMode.data, full: true),
    'notes_tasks': (build: (_) => const NotesTodosScreen(), mode: FakeMode.data, full: true),
    'memory': (build: (_) => const MemoryScreen(), mode: FakeMode.data, full: true),
    'subscriptions': (build: (_) => const SubscriptionsScreen(), mode: FakeMode.data, full: true),
    'connected_apps': (build: (_) => SourcesScreen(), mode: FakeMode.data, full: true),
    'in_progress': (build: (_) => const InProgressScreen(), mode: FakeMode.data, full: true),
    'settings': (build: (_) => const SettingsScreen(), mode: FakeMode.data, full: true),
    'plans': (build: (_) => const PlansScreen(), mode: FakeMode.data, full: true),
    // a6 push: Settings → Notifications & calls + the ringing screen.
    'push_settings': (build: (_) => const PushSettingsScreen(probe: false), mode: FakeMode.data, full: true),
    'incoming_call': (build: (_) => IncomingCallScreen(payload: PushPayload({'kind': 'call', 'call_id': '7', 'chat_id': '3', 'caller_name': 'Ayesha Rahman', 'video': 'true', 'title': 'Ayesha Rahman'})), mode: FakeMode.data, full: true),
    'finance': (build: (_) => const FinanceScreen(), mode: FakeMode.data, full: true),
    'watch_feed': (build: (_) => const WatchFeedScreen(), mode: FakeMode.data, full: true),
    'jobs': (build: (_) => const JobsScreen(), mode: FakeMode.data, full: true),
    'nominee': (build: (_) => const NomineeScreen(), mode: FakeMode.data, full: true),
    'scam': (build: (_) => const ScamScreen(), mode: FakeMode.data, full: true),
    'safety': (build: (_) => const SafetyScreen(), mode: FakeMode.data, full: true),
    'crm_contacts': (build: (_) => const CrmContactsScreen(), mode: FakeMode.data, full: true),
    'crm_today': (build: (_) => Scaffold(appBar: AppBar(title: const Text('CRM')), body: const CrmTodayScreen(org: 1)), mode: FakeMode.data, full: true),
    'crm_leads': (build: (_) => Scaffold(appBar: AppBar(title: const Text('CRM')), body: const CrmLeadsScreen(org: 1)), mode: FakeMode.data, full: true),
    'crm_pipeline': (build: (_) => Scaffold(appBar: AppBar(title: const Text('CRM')), body: const CrmPipelineScreen(org: 1)), mode: FakeMode.data, full: true),
    'crm_dashboard': (build: (_) => Scaffold(appBar: AppBar(title: const Text('CRM')), body: const CrmDashboardScreen(org: 1)), mode: FakeMode.data, full: true),
    'crm_team': (build: (_) => Scaffold(appBar: AppBar(title: const Text('CRM')), body: const CrmTeamScreen(org: 1)), mode: FakeMode.data, full: true),
    'business': (build: (_) => const BusinessScreen(), mode: FakeMode.data, full: true),
    'inbox': (build: (_) => const InboxScreen(), mode: FakeMode.data, full: true),
    'guide': (build: (_) => const GuideScreen(), mode: FakeMode.data, full: true),
    'agent_studio': (build: (_) => const AgentStudioScreen(), mode: FakeMode.data, full: true),
    'battery_guidance': (build: (_) => const BatteryGuidanceScreen(), mode: FakeMode.data, full: true),
    'onboarding': (build: (_) => OnboardingScreen(onDone: () {}), mode: FakeMode.data, full: true),
    'support': (build: (_) => const SupportScreen(), mode: FakeMode.data, full: true),
    // module 5 (P13+)
    'health_tips': (build: (_) => const HealthTipsScreen(), mode: FakeMode.data, full: true),
    'medicine_db': (build: (_) => const MedicineDbScreen(), mode: FakeMode.data, full: true),
    'birthdays': (build: (_) => const BirthdaysScreen(), mode: FakeMode.data, full: true),
    'meetings': (build: (_) => const MeetingsScreen(), mode: FakeMode.data, full: true),
    'dictionary': (build: (_) => const DictionaryScreen(), mode: FakeMode.data, full: true),
    'ride_food': (build: (_) => const RideFoodScreen(), mode: FakeMode.data, full: true),
    'ramadan': (build: (_) => const RamadanScreen(), mode: FakeMode.data, full: true),
    'exam': (build: (_) => const ExamResultScreen(), mode: FakeMode.data, full: true),
    'circle': (build: (_) => const CircleScreen(), mode: FakeMode.data, full: true),
    // build-61: Connected Circle chat/call/privacy + Safe Journey + referral + CRM first-run
    'circle_chat': (build: (l) => CircleChatScreen(member: _circleMember(l), identity: _identity), mode: FakeMode.data, full: true),
    'circle_call': (build: (l) => CircleCallScreen(member: _circleMember(l), kind: 'voice'), mode: FakeMode.data, full: true),
    'circle_call_history': (build: (_) => const CircleCallHistoryScreen(), mode: FakeMode.data, full: true),
    'circle_privacy': (build: (_) => const CirclePrivacyScreen(), mode: FakeMode.data, full: true),
    'circle_search': (build: (l) => CircleSearchScreen(members: [_circleMember(l)], identity: _identity), mode: FakeMode.data, full: true),
    'referral': (build: (_) => const ReferralScreen(), mode: FakeMode.data, full: true),
    'journey_start': (build: (_) => const JourneyStartScreen(), mode: FakeMode.data, full: true),
    'journey_live': (build: (_) => const JourneyLiveScreen(journeyId: 1), mode: FakeMode.data, full: true),
    'journey_sos': (build: (_) => const JourneySosScreen(journeyId: 1), mode: FakeMode.data, full: true),
    'journey_settings': (build: (_) => const JourneySettingsScreen(), mode: FakeMode.data, full: true),
    'journey_fake_call': (build: (l) => JourneyFakeCallScreen(caller: l == 'bn' ? 'Ammu' : 'Mom'), mode: FakeMode.data, full: true),
    // Wrap in Scaffold (as the real host CrmHomeScreen does) so the interactive
    // Material widgets have a Material ancestor — without it the gallery shot
    // degrades to the framework's "no Material" gray/tofu blocks.
    'crm_firstrun': (build: (_) => Scaffold(body: CrmFirstRunScreen(onReady: () async {})), mode: FakeMode.data, full: true),
    'crm_firstrun_join': (build: (_) => Scaffold(body: CrmFirstRunScreen(onReady: () async {}, previewJoin: true)), mode: FakeMode.data, full: true),
    'legal': (build: (_) => const LegalScreen(), mode: FakeMode.data, full: true),
    'photo_enhance': (build: (_) => const PhotoEnhanceScreen(), mode: FakeMode.data, full: true),
    // ---- a1 Premium QA: screens that had no gallery shot ----
    'ai_chat': (build: (_) => const AiChatScreen(), mode: FakeMode.data, full: true),
    'nearby': (build: (_) => const NearbyScreen(), mode: FakeMode.data, full: true),
    'used_phone_check': (build: (_) => const UsedPhoneCheckScreen(), mode: FakeMode.data, full: true),
    'vehicles': (build: (_) => const MyVehiclesScreen(), mode: FakeMode.data, full: true),
    'smartwatch': (build: (_) => const SmartwatchScreen(), mode: FakeMode.data, full: true),
    'unseen': (build: (_) => const UnseenWorldScreen(), mode: FakeMode.data, full: true),
    // a2-cctv Premium QA (Business + Money)
    'biz_hub': (build: (_) => const BusinessHubScreen(), mode: FakeMode.data, full: true),
    'biz_products': (build: (_) => const ProductsScreen(businessId: 1), mode: FakeMode.data, full: true),
    'biz_khata': (build: (l) => KhataScreen(business: {'id': 1, 'name': l == 'bn' ? 'আমার দোকান' : 'My Shop', 'role': 'owner'}), mode: FakeMode.data, full: true),
    'biz_cashbox': (build: (l) => CashboxScreen(business: {'id': 1, 'name': l == 'bn' ? 'আমার দোকান' : 'My Shop', 'role': 'owner'}), mode: FakeMode.data, full: true),
    'biz_customers': (build: (_) => const CustomersScreen(businessId: 1), mode: FakeMode.data, full: true),
    'biz_quick_sell': (build: (_) => const QuickSellScreen(businessId: 1), mode: FakeMode.data, full: true),
    'biz_reports': (build: (_) => const ReportsScreen(businessId: 1), mode: FakeMode.data, full: true),
    'biz_orders': (build: (_) => const OrdersScreen(), mode: FakeMode.data, full: true),
    'biz_payments': (build: (_) => const PaymentsScreen(), mode: FakeMode.data, full: true),
    'money_report': (build: (_) => const MoneyReportScreen(), mode: FakeMode.data, full: true),
    'money_networth': (build: (_) => const MoneyNetWorthScreen(), mode: FakeMode.data, full: true),
    'money_trends': (build: (_) => const MoneyTrendsScreen(), mode: FakeMode.data, full: true),
    'money_loan_detail': (build: (l) => MoneyLoanDetailScreen(item: {'localId': 'l1', 'serverId': 1, 'data': {'id': 1, 'kind': 'given', 'person': l == 'bn' ? 'রহিম' : 'Rahim', 'amount': '2000', 'paid': '500'}}), mode: FakeMode.data, full: true),
    'biz_products_empty': (build: (_) => const ProductsScreen(businessId: 1), mode: FakeMode.empty, full: false),
    'biz_khata_error': (build: (l) => KhataScreen(business: const {'id': 1, 'name': 'X', 'role': 'owner'}), mode: FakeMode.fail, full: false),
    'biz_reports_loading': (build: (_) => const ReportsScreen(businessId: 1), mode: FakeMode.slow, full: false),
    // a2-cctv Premium QA batch 2
    'crm_home': (build: (_) => const CrmHomeScreen(previewOrg: 1), mode: FakeMode.data, full: true),
    'crm_companies': (build: (_) => Scaffold(appBar: AppBar(title: const Text('CRM')), body: const CrmCompaniesScreen(org: 1)), mode: FakeMode.data, full: true),
    'crm_reports': (build: (_) => Scaffold(appBar: AppBar(title: const Text('CRM')), body: const CrmReportsScreen(org: 1)), mode: FakeMode.data, full: true),
    'crm_lead_detail': (build: (_) => const CrmLeadDetailScreen(org: 1, leadId: 1), mode: FakeMode.data, full: true),
    'biz_order_detail': (build: (_) => const OrderDetailScreen(orderId: 101), mode: FakeMode.data, full: true),
    'money_import': (build: (_) => const MoneyImportScreen(), mode: FakeMode.data, full: true),
    'shop_cameras': (build: (_) => const ShopBoxScreen(initialTab: 1), mode: FakeMode.data, full: true),
    'shop_alerts': (build: (_) => const ShopBoxScreen(initialTab: 2), mode: FakeMode.data, full: true),
    'shop_report': (build: (_) => const ShopBoxScreen(initialTab: 3), mode: FakeMode.data, full: true),
    'crm_leads_empty': (build: (_) => Scaffold(appBar: AppBar(title: const Text('CRM')), body: const CrmLeadsScreen(org: 1)), mode: FakeMode.empty, full: false),
    'biz_orders_error': (build: (_) => const OrdersScreen(), mode: FakeMode.fail, full: false),
    // a2-cctv Premium QA batch 3 (data stubs + sheets/dialogs)
    'money_wrapped_data': (build: (_) => const MoneyWrappedScreen(), mode: FakeMode.data, full: true),
    'money_wrapped_thin': (build: (_) => const MoneyWrappedScreen(), mode: FakeMode.empty, full: false),
    'crm_lead_full': (build: (_) => const CrmLeadDetailScreen(org: 1, leadId: 1), mode: FakeMode.data, full: true),
    'crm_proposal': (build: (l) => CrmProposalScreen(org: 1, lead: {'id': 1, 'name': l == 'bn' ? 'করিম গার্মেন্টস' : 'Karim Garments', 'company': 'Karim Garments Ltd'}), mode: FakeMode.data, full: true),
    'sheet_product_new': (build: (_) => const Scaffold(body: SafeArea(child: ProductEditSheet(businessId: 1, role: SellRole('owner')))), mode: FakeMode.data, full: true),
    'sheet_product_edit': (build: (l) => Scaffold(body: SafeArea(child: ProductEditSheet(businessId: 1, role: const SellRole('owner'), product: {'id': 1, 'name': l == 'bn' ? 'পাঞ্জাবি' : 'Panjabi', 'category': l == 'bn' ? 'পোশাক' : 'Clothing', 'sku': 'PJ-01', 'barcode': '', 'description': '', 'variants': [{'key': '__base__', 'size': '', 'colour': '', 'sell_price': 120000, 'cost_price': 80000, 'min_price': 100000, 'stock': 8, 'barcode': '', 'low_stock_at': 3}]}))), mode: FakeMode.data, full: true),
    'sheet_product_staff': (build: (_) => const Scaffold(body: SafeArea(child: ProductEditSheet(businessId: 1, role: SellRole('staff')))), mode: FakeMode.data, full: false),
    'sheet_customer_new': (build: (_) => const Scaffold(body: SafeArea(child: CustomerEditSheet(businessId: 1))), mode: FakeMode.data, full: true),
    'sheet_customer_edit': (build: (l) => Scaffold(body: SafeArea(child: CustomerEditSheet(businessId: 1, customer: {'id': 1, 'name': l == 'bn' ? 'নাদিয়া' : 'Nadia', 'phone': '01712345678', 'area': l == 'bn' ? 'মিরপুর' : 'Mirpur', 'address': '', 'notes': '', 'vip': true}))), mode: FakeMode.data, full: true),
    'sheet_khata_due': (build: (l) => Scaffold(body: SafeArea(child: khataEntrySheetPreview({'id': 1, 'name': 'X', 'role': 'owner'}))), mode: FakeMode.data, full: true),
    'sheet_khata_payment': (build: (l) => Scaffold(body: SafeArea(child: khataEntrySheetPreview({'id': 1, 'name': 'X', 'role': 'owner'}, isDue: false))), mode: FakeMode.data, full: true),
    'dialog_sale_void': (build: (_) => const Scaffold(body: Center(child: SaleVoidDialog())), mode: FakeMode.data, full: true),
    // a2-cctv: Shop Box (CCTV Part 4) — Business plan stubbed in FakeApi
    'shop_box': (build: (_) => const ShopBoxScreen(), mode: FakeMode.data, full: true),
    'shop_eod': (build: (_) => const ShopEodScreen(siteId: 1), mode: FakeMode.data, full: true),
    'shop_live_offline': (build: (l) => ShopLiveScreen(cameraId: 1, cameraName: l == 'bn' ? 'ক্যাশ কাউন্টার' : 'Cash counter'), mode: FakeMode.data, full: true),
    'shop_mode_pair': (build: (_) => const ShopBoxModeScreen(), mode: FakeMode.data, full: true),
    'shop_mode_paired': (build: (l) => ShopBoxModeScreen(preview: (token: 'demo', cameraId: 1, site: l == 'bn' ? 'মিরপুর শাখা' : 'Mirpur branch', camera: l == 'bn' ? 'ক্যাশ কাউন্টার' : 'Cash counter')), mode: FakeMode.data, full: true),
    'shop_cam_settings': (build: (l) => Scaffold(body: SafeArea(child: ShopCameraSettingsSheet(camera: {'id': 1, 'name': l == 'bn' ? 'ক্যাশ কাউন্টার' : 'Cash counter', 'enabled': true, 'online': false, 'last_seen': '2026-10-21T03:10:00Z', 'restricted_zone': true, 'hours': {'open': '09:00', 'close': '22:00'}, 'camera_token': 'demo-cam-token-xyz'}))), mode: FakeMode.data, full: true),
    // state variants (single representative each)
    'subscriptions_empty': (build: (_) => const SubscriptionsScreen(), mode: FakeMode.empty, full: false),
    'subscriptions_loading': (build: (_) => const SubscriptionsScreen(), mode: FakeMode.slow, full: false),
    'subscriptions_error': (build: (_) => const SubscriptionsScreen(), mode: FakeMode.fail, full: false),
    'vault_empty': (build: (_) => const VaultScreen(previewUnlocked: true), mode: FakeMode.empty, full: false),
    'vault_error': (build: (_) => const VaultScreen(previewUnlocked: true), mode: FakeMode.fail, full: false),
  };

  Future<void> shoot(WidgetTester tester, String name, String lang,
      Brightness brightness, Widget screen, FakeMode mode) async {
    // Real elevation shadows (flutter_test draws them as solid black outlines
    // by default, which looks like a bug in review shots). Restored below.
    debugDisableShadows = false;
    FakeApi.planSlug = name.startsWith('shop_') ? 'business' : 'premium';
    final tall = name.endsWith('_bottom');
    await tester.binding.setSurfaceSize(Size(360, tall ? 1800 : 800));
    final key = GlobalKey();
    final app = _stub(lang: lang, mode: mode);
    final mode2 = brightness == Brightness.light ? ThemeMode.light : ThemeMode.dark;
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<Updater>(create: (_) => Updater()),
      ],
      child: RepaintBoundary(
        key: key,
        child: MediaQuery(
          data: MediaQueryData(size: Size(360, tall ? 1800 : 800), textScaler: TextScaler.linear(_textScale)),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: Locale(lang),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: AssistoTheme.light,
            darkTheme: AssistoTheme.dark,
            themeMode: mode2,
            home: Builder(builder: (_) => screen),
          ),
        ),
      ),
    ));
    await tester.runAsync(() async {
      for (final el in find.byType(Image).evaluate()) {
        final img = el.widget as Image;
        await precacheImage(img.image, el)
            .timeout(const Duration(seconds: 5), onTimeout: () {});
      }
      await Future.delayed(const Duration(milliseconds: 250));
    });
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    if (name.endsWith('_menu')) {
      try {
        final mv = find.byIcon(Icons.more_vert);
        if (mv.evaluate().isNotEmpty) { await tester.tap(mv.first); await tester.pumpAndSettle(const Duration(milliseconds: 300)); }
      } catch (_) {}
    }
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image =
        await tester.runAsync(() => boundary.toImage(pixelRatio: 2.0)) as ui.Image;
    final bytes =
        await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
    File('$_outDir/${name}_${lang}_${brightness == Brightness.light ? 'light' : 'dark'}$_scaleSuffix.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
    // Drain any pending "slow load" timer so the test tears down cleanly.
    // _slow() schedules a fake-async Future.delayed(1200ms) at pumpWidget time,
    // so we must advance the fake clock (not real async) to fire it.
    if (mode == FakeMode.slow) {
      await tester.pump(const Duration(milliseconds: 1400));
      await tester.pump();
    }
    debugDisableShadows = true;
  }

  final onlyEnv = Platform.environment['ASSISTO_SHOT_ONLY'];
  final only = (onlyEnv == null || onlyEnv.isEmpty) ? null : onlyEnv.split(',').toSet();
  specs.forEach((name, spec) {
    if (only != null && !only.contains(name)) return;
    final langs = ['bn', 'en'];
    final brights = [Brightness.light, Brightness.dark];
    for (final lang in langs) {
      for (final b in brights) {
        if (!spec.full && !(lang == 'en' && b == Brightness.light) &&
            !(lang == 'bn' && b == Brightness.dark)) {
          continue; // variants: only en-light + bn-dark
        }
        testWidgets('shot $name $lang ${b.name}', (tester) async {
          await shoot(tester, name, lang, b, spec.build(lang), spec.mode);
        });
      }
    }
  });
}
