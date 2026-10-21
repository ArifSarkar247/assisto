import 'package:flutter/material.dart';

import '../screens/money_screen.dart';
import '../screens/money_budget_screen.dart';
import '../screens/money_tax_screen.dart';
import '../screens/money_wrapped_screen.dart';
import '../screens/money_voice_screen.dart';
import '../screens/vault_screen.dart';
import '../screens/family_screen.dart';
import '../screens/emergency_screen.dart';
import '../screens/reminders_screen.dart';
import '../screens/plans_screen.dart';
import '../screens/scam_screen.dart';
import '../screens/safety_screen.dart';
import '../screens/voice_sos_screen.dart';
import '../screens/crm/crm_home_screen.dart';
// module 5 (P13+)
import '../screens/medicine_db_screen.dart';
import '../screens/health_tips_screen.dart';
import '../screens/birthdays_screen.dart';
import '../screens/meetings_screen.dart';
import '../screens/dictionary_screen.dart';
import '../screens/ride_food_screen.dart';
import '../screens/my_vehicles_screen.dart';
import '../screens/vehicle_tracking_screen.dart';
import '../screens/car_mode_screen.dart';
import '../screens/fall_detect_screen.dart';
import '../screens/lost_stolen_screen.dart';
import '../screens/my_lost_phone_screen.dart';
import '../screens/recovery_screen.dart';
import '../screens/phone_safety_screen.dart';
import '../screens/security_screen.dart';
import '../screens/sell_my_phone_screen.dart';
import '../screens/shop_box_screen.dart';
import '../screens/used_phone_check_screen.dart';
import '../screens/owner_analytics_screen.dart';
import '../screens/name_about_screen.dart';
import '../screens/ramadan_screen.dart';
import '../screens/exam_result_screen.dart';
import '../screens/unseen_world_screen.dart';
import '../screens/photo_studio_screen.dart'; // ps1-photo
import '../screens/circle_screen.dart';
import '../screens/messenger/messenger_home_screen.dart';
import '../screens/notification_centre_screen.dart';
import '../screens/legal_screen.dart';
// build-61 wave: remaining modules (every sidebar module is chat-openable)
import '../screens/subscriptions_screen.dart';
import '../screens/finance_screen.dart';
import '../screens/payment_ladder_screen.dart';
import '../screens/notes_todos_screen.dart';
import '../screens/memory_screen.dart';
import '../screens/nominee_screen.dart';
import '../screens/crm_contacts_screen.dart';
import '../screens/agent_studio_screen.dart';
import '../screens/jobs_screen.dart';
import '../screens/cv_builder_screen.dart';
import '../screens/inbox_screen.dart';
import '../screens/guide_screen.dart';
import '../screens/nearby_screen.dart';
import '../screens/watch_feed_screen.dart';
import '../screens/business_screen.dart';
import '../screens/business/bargain_rules_screen.dart';
import '../screens/business/business_plans_screen.dart';
import '../screens/journey_start_screen.dart';
import '../screens/referral_screen.dart';
import '../screens/circle_privacy_screen.dart';
import '../screens/circle_call_history_screen.dart';
// Wave-D batch-4: Action Center, Disaster alerts, Offline & data
import '../screens/action_center_screen.dart';
import '../screens/disaster_alerts_screen.dart';
import '../screens/offline_status_screen.dart';
import '../screens/ai_chat_screen.dart';
// Part 3: native voice assistant
import '../screens/voice_assistant_screen.dart';
import '../screens/voice_assistant_settings_screen.dart';
import '../screens/assisto_chats_screen.dart';

/// open-from-chat configuration (Phase B).
///
/// When the user asks to open a screen in chat — e.g. "show mom's medicines"
/// (or the Bangla equivalent) — the chat NAVIGATES to the matching screen
/// instead of (or in addition to) replying with a card.
///
/// Routing resolves to the SAME canonical `route` strings as the backend's
/// `core/screen_synonyms.py`. Two layers:
///
///   1. BACKEND field (authoritative, bilingual) — the `/agent` response should
///      carry an optional `"route": "<canonical>"` string, computed server-side
///      via `screen_synonyms.resolve(text)` (see integrator spec). This is the
///      primary path and the ONLY one that understands Bangla phrases, because
///      the app's language gate forbids Bangla literals in Dart. Integrator:
///      after a successful `/agent` call, read `resp['route']` and call
///      [ChatNav.push].
///
///   2. LOCAL fast-path (English/ASCII only, offline) — [ChatNav.detectRoute]
///      catches the common English "show X / open X" phrases on-device with
///      zero latency and no AI call. Bangla is intentionally NOT handled here
///      (gate constraint); it falls through to layer 1.
///
/// This file holds routing data + a route→widget map only — no user-facing
/// display strings, so no AppLocalizations and (per the language gate) no
/// Bangla literals.
class ChatNav {
  ChatNav._();

  /// Canonical route -> screen builder. Keep the route keys in lock-step with
  /// `core/screen_synonyms.py` SCREEN_SYNONYMS.
  static final Map<String, WidgetBuilder> routes = {
    'money': (_) => const MoneyScreen(),
    'documents': (_) => const VaultScreen(),
    'family': (_) => const FamilyScreen(),
    'reminders': (_) => const RemindersScreen(),
    'vehicles': (_) => const MyVehiclesScreen(),
    'vehicle_tracking': (_) => const VehicleTrackingScreen(), // v1-vehicle
    'car_mode': (_) => const CarModeScreen(), // v1-vehicle
    'emergency': (_) => const EmergencyScreen(),
    'plans': (_) => const PlansScreen(),
    'scam': (_) => const ScamScreen(),
    'safety': (_) => const SafetyScreen(),
    'voice_sos': (_) => const VoiceSosScreen(),
    'crm': (_) => const CrmHomeScreen(),
    // module 5 (P13+)
    'medicine_db': (_) => const MedicineDbScreen(),
    'health_tips': (_) => const HealthTipsScreen(),
    'birthdays': (_) => const BirthdaysScreen(),
    'meetings': (_) => const MeetingsScreen(),
    'dictionary': (_) => const DictionaryScreen(),
    'ride_food': (_) => const RideFoodScreen(),
    'fall_detect': (_) => const FallDetectScreen(),
    'lost_stolen': (_) => const LostStolenScreen(),
    // Anti-theft Batch 5: "My lost phone" (server view + lost-mode) and the
    // Recovery help toolkit (GD draft / SP letter / evidence / stations).
    // Recovery is also reachable from inside My lost phone and Lost/Stolen.
    'my_lost_phone': (_) => const MyLostPhoneScreen(),
    'recovery': (_) => const RecoveryScreen(),
    'phone_safety': (_) => const PhoneSafetyScreen(),
    // Section 8: Stolen-while-unlocked protection hub.
    'security': (_) => const SecurityScreen(),
    // Anti-theft Batch 4: used-phone registry check + sell/transfer flow.
    // (Report-stolen lives inside both screens, so it needs no route of its own.)
    'used_phone_check': (_) => const UsedPhoneCheckScreen(),
    'sell_phone': (_) => const SellMyPhoneScreen(),
    // Part 4: Shop Box / CCTV loss-prevention (Business tier, signals-only).
    'shop_box': (_) => const ShopBoxScreen(),
    'analytics': (_) => const OwnerAnalyticsScreen(),
    'name_about': (_) => const NameAboutScreen(),
    'ramadan': (_) => const RamadanScreen(),
    'exam': (_) => const ExamResultScreen(),
    'unseen': (_) => const UnseenWorldScreen(),
    // The old enhance tool is gone (owner order): its key stays because saved
    // home buttons, Discover cards and chat commands use it — it now opens
    // Photo Studio, so every save goes through the same ad/credit rule.
    'photo_enhance': (_) => const PhotoStudioScreen(),
    'photo_studio': (_) => const PhotoStudioScreen(), // ps1-photo
    'circle': (_) => const CircleScreen(),
    // Messenger hub (Step 3): Chats · Updates · Communities · Calls.
    'messages': (_) => const MessengerHomeScreen(),
    'notifications': (_) => const NotificationCentreScreen(),
    // M2: Groups + Status live inside the Circle hub (they need the loaded
    // on-device identity + members-with-public_key), so chat-open lands there.
    'groups': (_) => const CircleScreen(),
    'status': (_) => const CircleScreen(),
    'legal': (_) => const LegalScreen(),
    // build-61 wave: remaining modules
    'subscriptions': (_) => const SubscriptionsScreen(),
    'finance': (_) => const FinanceScreen(),
    'payment_ladder': (_) => const PaymentLadderScreen(),
    'notes': (_) => const NotesTodosScreen(),
    'memory': (_) => const MemoryScreen(),
    'nominee': (_) => const NomineeScreen(),
    'contacts': (_) => const CrmContactsScreen(),
    'agent_studio': (_) => const AgentStudioScreen(),
    'jobs': (_) => const JobsScreen(),
    'cv': (_) => const CvBuilderScreen(),
    'resume': (_) => const CvBuilderScreen(),
    'inbox': (_) => const InboxScreen(),
    'guide': (_) => const GuideScreen(),
    'nearby': (_) => const NearbyScreen(),
    'watch_feed': (_) => const WatchFeedScreen(),
    'business': (_) => const BusinessScreen(),
    // Business orphans now reachable: per-product bargaining rules (Premium)
    // and the Free-vs-Premium plans comparison. Also in the Business Hub.
    'bargain_rules': (_) => const BargainRulesScreen(),
    'business_plans': (_) => const BusinessPlansScreen(),
    'journey': (_) => const JourneyStartScreen(),
    'referral': (_) => const ReferralScreen(),
    'circle_privacy': (_) => const CirclePrivacyScreen(),
    'circle_calls': (_) => const CircleCallHistoryScreen(),
    // Wave-D batch-4: Action Center (transparency/audit), Disaster alerts,
    // Offline & data. Each is also reachable from Settings / the sidebar, so
    // none is a dead screen.
    'action_center': (_) => const ActionCenterScreen(),
    'disaster': (_) => const DisasterAlertsScreen(),
    'offline': (_) => const OfflineStatusScreen(),
    // Wave-D batch-5 (money/reminders): advanced Budget, Tax & Zakat, Monthly
    // Wrapped recap, and Money-by-voice. Each is also in the My Account sidebar
    // group, so none is a dead screen.
    'budget': (_) => const MoneyBudgetScreen(),
    'tax': (_) => const MoneyTaxScreen(),
    'wrapped': (_) => const MoneyWrappedScreen(),
    'money_voice': (_) => const MoneyVoiceScreen(),
    // Part 3: Assisto AI — opens the chats page (New chat + every saved home
    // and AI chat), the same page as the sidebar "Assisto AI" entry.
    // Chat-openable via 'ai'/'chat'/'assistant' synonyms.
    'ai_chat': (_) => const AssistoChatsScreen(),
    // Part 3: Assisto Voice (hands-free assistant) + its settings card
    // (default-assistant setup, wake word, spoken replies).
    'voice_assistant': (_) => const VoiceAssistantScreen(),
    'voice_settings': (_) => const VoiceAssistantSettingsScreen(),
  };

  /// Local ENGLISH subject vocabulary (ASCII only). Mirrors the English tokens
  /// of the backend synonym map so common English open-phrases work offline.
  /// Longest phrase first (see [detectRoute]).
  static const Map<String, List<String>> _synonyms = {
    'money': [
      'my account', 'account', 'money', 'finance', 'expense', 'expenses',
      'wallet',
    ],
    'documents': ['documents', 'docs', 'vault', 'papers', 'files'],
    'family': [
      "mom's medicine", "dad's medicine", 'family care', 'family',
      'medicines', 'medicine',
    ],
    'reminders': ['reminders', 'reminder', 'remind me'],
    'emergency': ['emergency', 'sos', 'help'],
    'plans': ['plans', 'plan', 'premium', 'upgrade', 'subscribe', 'pricing'],
    'scam': ['scam check', 'scam', 'fraud'],
    'safety': ['safe arrival', 'safety', 'check-in', 'checkin'],
    'voice_sos': [
      'hands-free sos', 'hands free sos', 'voice sos', 'wake phrase',
      'voice emergency',
    ],
    'crm': ['sales crm', 'pipeline', 'leads', 'crm'],
    // module 5 (P13+)
    'medicine_db': ['medicine database', 'drug lookup', 'medicine info'],
    'health_tips': ['health tips', 'health tip'],
    'birthdays': ['birthdays', 'birthday', 'anniversary', 'memorable days'],
    'meetings': ['meetings', 'meeting', 'appointments', 'appointment'],
    'dictionary': ['dictionary', 'word meaning', 'translate word'],
    'ride_food': ['ride', 'food', 'uber', 'pathao', 'foodpanda'],
    'ramadan': ['ramadan', 'sehri', 'iftar', 'prayer times'],
    'exam': ['exam result', 'result', 'exam'],
    'unseen': ['unseen bangladesh', 'travel', 'destinations', 'tourism'],
    'photo_enhance': ['enhance photo', 'photo enhance', 'improve photo'],
    'photo_studio': ['photo studio', 'edit photo', 'photo editor', 'change background', 'passport photo', 'ai photo'],
    'security': ['security', 'stolen while unlocked', 'anti-theft ownership',
        'protect my phone', 'theft protection', 'disarm protection',
        'security pin'],
    'used_phone_check': ['used phone check', 'used phone', 'second hand phone',
        'secondhand phone', 'check imei', 'imei check', 'buy used phone',
        'check used phone'],
    'sell_phone': ['sell my phone', 'sell phone', 'transfer phone',
        'phone transfer', 'sale receipt', 'report stolen', 'report my phone',
        'mark recovered'],
    // Anti-theft Batch 5.
    'my_lost_phone': ['my lost phone', 'lost phone', 'find my phone',
        'track my phone', 'where is my phone', 'lost mode', 'locate my phone'],
    'recovery': ['recovery help', 'recover phone', 'gd draft',
        'general diary', 'police station', 'sp letter', 'get my phone back'],
    'circle': ['connected circle', 'circle', 'family chat'],
    'messages': ['messages', 'messenger', 'chats', 'direct message', 'dm'],
    'groups': ['groups', 'group chat', 'group'],
    'status': ['status', 'story', 'stories', 'status updates'],
    'legal': ['legal', 'privacy policy', 'terms', 'policies'],
    // build-61 wave: remaining modules
    'subscriptions': ['subscriptions', 'subscription', 'recurring'],
    'finance': ['finance tools', 'loan', 'savings', 'calculator'],
    'payment_ladder': ['payment ladder', 'ladder', 'collection', 'auto-pay',
        'tagada'],
    'notes': ['notes', 'tasks', 'to-do', 'todo', 'note'],
    'memory': ['memory', 'ai knows', 'remember'],
    'nominee': ['nominee access', 'nominee', 'inheritance'],
    'contacts': ['contacts', 'contact', 'phonebook'],
    'agent_studio': ['agent studio', 'agent', 'automation'],
    'jobs': ['job hunter', 'jobs', 'career'],
    'cv': ['cv', 'resume', 'bio data', 'biodata', 'curriculum vitae', 'build cv', 'make resume'],
    'inbox': ['ai inbox', 'inbox', 'mail'],
    'guide': ['government service', 'service guide', 'guide'],
    'nearby': ['nearby', 'around me', 'places nearby'],
    'watch_feed': ['watch feed', 'alerts feed', 'watch alerts'],
    'business': ['business', 'shop', 'store', 'orders'],
    'bargain_rules': ['bargaining rules', 'bargain rules', 'bargaining',
        'bargain', 'price floor', 'minimum price', 'discount rules',
        'negotiation rules'],
    'business_plans': ['business plans', 'business plan', 'free vs premium',
        'upgrade business', 'premium business', 'plan comparison'],
    'journey': ['safe journey', 'journey', 'track me', 'live location'],
    'referral': ['referral', 'refer', 'points', 'invite friend'],
    'circle_privacy': ['circle privacy', 'privacy controls', 'block'],
    'circle_calls': ['call history', 'call log', 'circle calls'],
    // Wave-D batch-4
    'action_center': ['action center', 'action centre', 'audit log', 'audit',
        'what did you do', 'approvals', 'pending actions'],
    'disaster': ['disaster alerts', 'disaster', 'cyclone', 'flood', 'warning',
        'weather warning', 'earthquake'],
    'offline': ['offline', 'offline data', 'cache', 'data usage', 'clear cache'],
    // Wave-D batch-5 (money/reminders)
    'budget': ['budget', 'spending plan', 'spending limit', 'monthly budget'],
    'tax': ['tax and zakat', 'tax & zakat', 'tax', 'zakat', 'income tax',
        'nisab'],
    'wrapped': ['money wrapped', 'wrapped', 'monthly recap', 'money recap',
        'year in money'],
    'money_voice': ['money by voice', 'money voice', 'voice expense',
        'speak expense', 'log by voice'],
    // Part 3: Assisto AI full chat. ASCII synonyms only (the gate forbids
    // Bangla literals in .dart); Bangla phrases resolve via the backend
    // screen_synonyms `route` field (layer 1), not this local fast-path.
    'ai_chat': ['assisto ai', 'ai chat', 'assistant', 'ai assistant', 'chat',
        'ai'],
    // Part 3: Assisto Voice. Longer phrases than 'assistant' so they win.
    'voice_assistant': ['voice assistant', 'assisto voice', 'hey assisto',
        'talk to assisto', 'voice mode', 'hands free'],
    'voice_settings': ['default assistant', 'digital assistant',
        'wake word', 'voice settings', 'assistant settings'],
  };

  /// English verbs marking an explicit "open the screen" intent, so a plain
  /// "I spent 500 on medicine" is NOT hijacked into opening the family screen.
  static const List<String> _openVerbs = [
    'show', 'open', 'go to', 'take me to', 'view', 'see my', 'see ',
  ];

  /// Flattened (phrase -> route), longest phrase first.
  static final List<MapEntry<String, String>> _index = () {
    final list = <MapEntry<String, String>>[];
    _synonyms.forEach((route, words) {
      for (final w in words) {
        list.add(MapEntry(w, route));
      }
    });
    list.sort((a, b) => b.key.length.compareTo(a.key.length));
    return list;
  }();

  /// Returns a canonical route if [text] looks like an English "open this
  /// screen" request, else null. Requires BOTH an open-verb AND a known subject
  /// so normal data-entry chat is never intercepted. Bangla returns null here
  /// by design (handled by the backend `route` field).
  static String? detectRoute(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final t = text.toLowerCase();
    final hasVerb = _openVerbs.any((v) => t.contains(v));
    if (!hasVerb) return null;
    for (final e in _index) {
      if (e.key.isNotEmpty && t.contains(e.key)) return e.value;
    }
    return null;
  }

  /// Push the screen for a canonical [route]. Returns true if a screen existed.
  static bool push(BuildContext context, String? route) {
    final b = route == null ? null : routes[route];
    if (b == null) return false;
    Navigator.push(context, MaterialPageRoute(builder: b));
    return true;
  }
}
