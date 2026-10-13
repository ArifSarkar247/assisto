import 'package:flutter/material.dart';

import '../screens/money_screen.dart';
import '../screens/vault_screen.dart';
import '../screens/family_screen.dart';
import '../screens/emergency_screen.dart';
import '../screens/reminders_screen.dart';
import '../screens/plans_screen.dart';
import '../screens/scam_screen.dart';
import '../screens/safety_screen.dart';
import '../screens/crm/crm_home_screen.dart';
// module 5 (P13+)
import '../screens/medicine_db_screen.dart';
import '../screens/health_tips_screen.dart';
import '../screens/birthdays_screen.dart';
import '../screens/meetings_screen.dart';
import '../screens/dictionary_screen.dart';
import '../screens/ride_food_screen.dart';
import '../screens/ramadan_screen.dart';
import '../screens/exam_result_screen.dart';
import '../screens/unseen_world_screen.dart';
import '../screens/photo_enhance_screen.dart';
import '../screens/circle_screen.dart';
import '../screens/legal_screen.dart';

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
    'emergency': (_) => const EmergencyScreen(),
    'plans': (_) => const PlansScreen(),
    'scam': (_) => const ScamScreen(),
    'safety': (_) => const SafetyScreen(),
    'crm': (_) => const CrmHomeScreen(),
    // module 5 (P13+)
    'medicine_db': (_) => const MedicineDbScreen(),
    'health_tips': (_) => const HealthTipsScreen(),
    'birthdays': (_) => const BirthdaysScreen(),
    'meetings': (_) => const MeetingsScreen(),
    'dictionary': (_) => const DictionaryScreen(),
    'ride_food': (_) => const RideFoodScreen(),
    'ramadan': (_) => const RamadanScreen(),
    'exam': (_) => const ExamResultScreen(),
    'unseen': (_) => const UnseenWorldScreen(),
    'photo_enhance': (_) => const PhotoEnhanceScreen(),
    'circle': (_) => const CircleScreen(),
    'legal': (_) => const LegalScreen(),
  };

  /// Local ENGLISH subject vocabulary (ASCII only). Mirrors the English tokens
  /// of the backend synonym map so common English open-phrases work offline.
  /// Longest phrase first (see [detectRoute]).
  static const Map<String, List<String>> _synonyms = {
    'money': [
      'my account', 'money', 'finance', 'expense', 'expenses', 'budget',
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
    'circle': ['connected circle', 'circle', 'family chat'],
    'legal': ['legal', 'privacy policy', 'terms', 'policies'],
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
