// healthfit (owner decision 27 Oct): health & fitness stay SHOWN in Play as
// "Health and Fitness" only — never medical. This gate checks:
//  1. no medical-claim words (bn + en) in the ARB values used by the four
//     screens (Water/sleep/food, Fitness partner, Smartwatch & fitness, Mood &
//     energy journal) nor in their source literals;
//  2. the "not medical advice" strip is VISIBLE on every one of those screens,
//     in bn and en, at 200% font, with no overflow;
//  3. the mood screen is a wellness journal + relaxation: the low-trend card
//     is a neutral 999 safety line (no helpline / counselling), the breathing
//     break runs and stops;
//  4. least privilege: the CI manifest requests ONLY the four Health Connect
//     READ permissions the Smartwatch screen actually reads, and no
//     ACTIVITY_RECOGNITION.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/fitness_partner_screen.dart';
import 'package:assisto/screens/smartwatch_screen.dart';
import 'package:assisto/screens/voice_mood_screen.dart';
import 'package:assisto/screens/wellness_tracker_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/health_disclaimer_bar.dart';

import 'fake_api.dart';

const _screens = {
  'wellness': 'lib/screens/wellness_tracker_screen.dart',
  'fitness': 'lib/screens/fitness_partner_screen.dart',
  'smartwatch': 'lib/screens/smartwatch_screen.dart',
  'voice_mood': 'lib/screens/voice_mood_screen.dart',
  'disclaimer': 'lib/widgets/health_disclaimer_bar.dart',
};

// Medical-claim words (mirrors backend/core/tests_healthfit.py). The
// disclaimer itself is allowed and stripped before scanning.
final _bannedEn = RegExp(
    r'\b(diagnos\w*|treat(?:ment|ments|s|ing)?|therap\w*|cure[sd]?|dos(?:e|es|age)|'
    r'disease\w*|clinical\w*|doctor-approved|mental[- ]health|depression|anxiety|'
    r'disorder\w*|prescri\w*|medication\w*|symptom\w*|counsell?ing|helpline)\b',
    caseSensitive: false);
// Bangla words as code points (lang_gate: no Bangla in Dart sources):
// rog, chikitsa, therapy, dose, matra, oshudh, manosik shastho, bishonnota,
// udbeg, niramoy, prescription, uposorgo, lokkhon, counselling, helpline.
final _bannedBn = [
  [0x09B0, 0x09CB, 0x0997],
  [0x099A, 0x09BF, 0x0995, 0x09BF, 0x09CE, 0x09B8, 0x09BE],
  [0x09A5, 0x09C7, 0x09B0, 0x09BE, 0x09AA, 0x09BF],
  [0x09A1, 0x09CB, 0x099C],
  [0x09AE, 0x09BE, 0x09A4, 0x09CD, 0x09B0, 0x09BE],
  [0x0993, 0x09B7, 0x09C1, 0x09A7],
  [0x09AE, 0x09BE, 0x09A8, 0x09B8, 0x09BF, 0x0995, 0x0020, 0x09B8, 0x09CD,
   0x09AC, 0x09BE, 0x09B8, 0x09CD, 0x09A5, 0x09CD, 0x09AF],
  [0x09AC, 0x09BF, 0x09B7, 0x09A3, 0x09CD, 0x09A3, 0x09A4, 0x09BE],
  [0x0989, 0x09A6, 0x09CD, 0x09AC, 0x09C7, 0x0997],
  [0x09A8, 0x09BF, 0x09B0, 0x09BE, 0x09AE, 0x09AF, 0x09BC],
  [0x09AA, 0x09CD, 0x09B0, 0x09C7, 0x09B8, 0x0995, 0x09CD, 0x09B0, 0x09BF,
   0x09AA, 0x09B6, 0x09A8],
  [0x0989, 0x09AA, 0x09B8, 0x09B0, 0x09CD, 0x0997],
  [0x09B2, 0x0995, 0x09CD, 0x09B7, 0x09A3],
  [0x0995, 0x09BE, 0x0989, 0x09A8, 0x09CD, 0x09B8, 0x09C7, 0x09B2, 0x09BF,
   0x0982],
  [0x09B9, 0x09C7, 0x09B2, 0x09CD, 0x09AA, 0x09B2, 0x09BE, 0x0987, 0x09A8],
].map(String.fromCharCodes).toList();
// "chikitsa-poramorsho noy" / "chikitsa poramorsho noy" (the disclaimer).
final _allowedBn = [
  String.fromCharCodes([0x099A, 0x09BF, 0x0995, 0x09BF, 0x09CE, 0x09B8, 0x09BE,
    0x002D, 0x09AA, 0x09B0, 0x09BE, 0x09AE, 0x09B0, 0x09CD, 0x09B6, 0x0020,
    0x09A8, 0x09AF, 0x09BC]),
  String.fromCharCodes([0x099A, 0x09BF, 0x0995, 0x09BF, 0x09CE, 0x09B8, 0x09BE,
    0x0020, 0x09AA, 0x09B0, 0x09BE, 0x09AE, 0x09B0, 0x09CD, 0x09B6, 0x0020,
    0x09A8, 0x09AF, 0x09BC]),
];
final _allowedEn =
    RegExp(r'not (?:a )?medical advice|no medical advice', caseSensitive: false);

List<String> medicalClaims(String text) {
  var t = text.replaceAll(_allowedEn, ' ');
  for (final a in _allowedBn) {
    t = t.replaceAll(a, ' ');
  }
  return [
    ..._bannedEn.allMatches(t).map((m) => m.group(0)!),
    for (final w in _bannedBn)
      if (t.contains(w)) w,
  ];
}

Map<String, dynamic> _arb(String lang) =>
    jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
        as Map<String, dynamic>;

/// Every AppLocalizations getter a source file uses (tr.x / t.x).
Set<String> _keysUsed(String src, Map<String, dynamic> en) => {
      for (final m in RegExp(r'\b(?:tr|t)\.([a-zA-Z0-9_]+)').allMatches(src))
        if (en.containsKey(m.group(1))) m.group(1)!,
    };

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(
      id: 1, name: 'Rahim', phone: '01712345678', email: '',
      autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MaterialApp(
        key: UniqueKey(),
        locale: Locale(lang),
        theme: AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 3, 780 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

String _iso(DateTime d) => d.toIso8601String().split('T').first;

/// Opted-in mood journal with five persistently low days (shows the support
/// card) — on-device SharedPreferences only.
Map<String, Object> _lowMoodPrefs() {
  final now = DateTime.now();
  final logs = [
    for (var i = 5; i >= 1; i--)
      {
        'id': 1000 + i,
        'mood': 'low',
        'energy': 1,
        'date': _iso(now.subtract(Duration(days: i))),
      }
  ];
  return {'mood_optin_v1': true, 'mood_logs_v1': jsonEncode(logs)};
}

void main() {
  late Map<String, dynamic> en;
  late Map<String, dynamic> bn;
  setUpAll(() {
    en = _arb('en');
    bn = _arb('bn');
  });

  group('wording: no medical claims', () {
    test('scanner catches banned words and allows the disclaimer', () {
      expect(medicalClaims('Diagnosis and treatment plan'), isNotEmpty);
      expect(medicalClaims('Take one dose daily'), isNotEmpty);
      expect(medicalClaims('This is not medical advice.'), isEmpty);
      expect(medicalClaims(bn['hfNotMedicalAdvice'] as String), isEmpty);
      expect(medicalClaims(en['hfNotMedicalAdvice'] as String), isEmpty);
      // the old mood copy would fail
      expect(medicalClaims(en['moodHelplineBody'] as String), isNotEmpty);
      expect(medicalClaims(bn['moodHelplineBody'] as String), isNotEmpty);
    });

    for (final e in _screens.entries) {
      test('${e.key}: ARB values (bn + en) used by the screen', () {
        final src = File(e.value).readAsStringSync();
        final keys = _keysUsed(src, en);
        expect(keys, isNotEmpty);
        final bad = <String>[];
        for (final k in keys) {
          for (final lang in [en, bn]) {
            final v = lang[k];
            if (v is String && medicalClaims(v).isNotEmpty) {
              bad.add('$k: ${medicalClaims(v)} in "$v"');
            }
          }
        }
        expect(bad, isEmpty, reason: bad.join('\n'));
      });

      test('${e.key}: string literals in the source', () {
        // strip comments (doc comments may explain what the screen is NOT)
        final src = File(e.value)
            .readAsStringSync()
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        final lits = RegExp(r"'([^'\n]*)'").allMatches(src).map((m) => m.group(1)!);
        final bad = [for (final l in lits) if (medicalClaims(l).isNotEmpty) l];
        expect(bad, isEmpty, reason: bad.join('\n'));
      });
    }

    test('mood screen never uses the old helpline / mental-health copy', () {
      final src = File('lib/screens/voice_mood_screen.dart').readAsStringSync();
      for (final k in [
        'moodHelplineTitle', 'moodHelplineBody', 'moodSafetyNote,',
        'moodOptInPoint4,', 'moodTitle,', 'medical_services',
      ]) {
        expect(src.contains(k), isFalse, reason: k);
      }
      expect(src.contains("'tel:999'"), isTrue);
    });
  });

  group('not-medical-advice strip is visible (bn/en, 200% font)', () {
    final cases = <String, Widget Function()>{
      'wellness': () => const WellnessTrackerScreen(),
      'fitness': () => const FitnessPartnerScreen(),
      'smartwatch': () => const SmartwatchScreen(),
      'mood (opt-in gate)': () => const VoiceMoodScreen(),
      'mood (journal)': () => const VoiceMoodScreen(),
    };
    for (final c in cases.entries) {
      for (final lang in ['bn', 'en']) {
        testWidgets('${c.key} · $lang', (tester) async {
          SharedPreferences.setMockInitialValues(
              c.key == 'mood (journal)' ? _lowMoodPrefs() : {});
          _phone(tester);
          await tester.pumpWidget(_app(c.value(), lang: lang, scale: 2.0));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          final bar = find.byKey(HealthDisclaimerBar.barKey);
          expect(bar, findsOneWidget);
          final text = (lang == 'bn' ? bn : en)['hfNotMedicalAdvice'] as String;
          final t = find.text(text);
          expect(t, findsOneWidget);
          // on screen (not scrolled away, not hidden in a menu)
          final r = tester.getRect(t);
          expect(r.top >= 0 && r.bottom <= 780, isTrue, reason: '$r');
        });
      }
    }
  });

  group('mood & energy = wellness journal + relaxation', () {
    testWidgets('low trend shows the neutral 999 line, never a helpline',
        (tester) async {
      SharedPreferences.setMockInitialValues(_lowMoodPrefs());
      _phone(tester);
      await tester.pumpWidget(_app(const VoiceMoodScreen(), lang: 'en'));
      await _settle(tester);
      final card = find.byKey(const Key('mood-support-card'));
      await tester.scrollUntilVisible(card, 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(en['moodSupportBody'] as String), findsOneWidget);
      expect(find.text(en['moodCall999'] as String), findsOneWidget);
      expect(find.textContaining('08000011122'), findsNothing);
      expect(find.text(en['moodJournalTitle'] as String), findsOneWidget);
    });

    testWidgets('one-minute breathing starts and stops', (tester) async {
      SharedPreferences.setMockInitialValues(_lowMoodPrefs());
      _phone(tester);
      await tester.pumpWidget(_app(const VoiceMoodScreen(), lang: 'en'));
      await _settle(tester);
      final start = find.text(en['moodBreathStart'] as String);
      await tester.scrollUntilVisible(start, 200,
          scrollable: find.byType(Scrollable).first);
      // bring the whole card above the FAB / viewport edge before tapping
      await tester.ensureVisible(find.byKey(const Key('mood-breathing-card')));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(start);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(en['moodBreathIn'] as String), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text(en['moodBreathOut'] as String), findsOneWidget);
      await tester.tap(find.text(en['moodBreathStop'] as String));
      await tester.pump(const Duration(seconds: 5));
      expect(find.text(en['moodBreathIn'] as String), findsNothing);
      expect(start, findsOneWidget);
    });
  });

  group('Health Connect: least privilege', () {
    const justified = {
      'READ_STEPS',
      'READ_HEART_RATE',
      'READ_SLEEP',
      'READ_ACTIVE_CALORIES_BURNED',
    };
    // HealthDataType read by the Smartwatch screen -> Health Connect permission
    const typeToPerm = {
      'STEPS': 'READ_STEPS',
      'HEART_RATE': 'READ_HEART_RATE',
      'SLEEP_ASLEEP': 'READ_SLEEP',
      'ACTIVE_ENERGY_BURNED': 'READ_ACTIVE_CALORIES_BURNED',
    };

    test('CI manifest requests only the justified Health Connect reads', () {
      final ci = File('../.github/workflows/android.yml').readAsStringSync();
      final requested = RegExp(
              r'uses-permission android:name="android\.permission\.([A-Za-z_.]+)"(?![^>]*tools:node="remove")')
          .allMatches(ci)
          .map((m) => m.group(1)!)
          .toSet();
      final health = {
        for (final p in requested)
          if (p.startsWith('health.')) p.substring('health.'.length),
      };
      expect(health, justified);
      expect(health.every((p) => p.startsWith('READ_')), isTrue,
          reason: 'never write to Health Connect');
      expect(requested.contains('ACTIVITY_RECOGNITION'), isFalse);
      expect(
          ci.contains(
              'android.permission.ACTIVITY_RECOGNITION" tools:node="remove"'),
          isTrue);
      // Health Connect rationale / privacy-policy entry stays wired
      expect(ci.contains('androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE'),
          isTrue);
    });

    test('the Smartwatch screen reads exactly those types, read-only', () {
      final src = File('lib/screens/smartwatch_screen.dart').readAsStringSync();
      final block = RegExp(r'const List<HealthDataType> _types = \[(.*?)\];',
              dotAll: true)
          .firstMatch(src)!
          .group(1)!;
      final types = RegExp(r'HealthDataType\.([A-Z_]+)')
          .allMatches(block)
          .map((m) => m.group(1)!)
          .toSet();
      expect(types.map((t) => typeToPerm[t]).toSet(), justified);
      expect(src.contains('HealthDataAccess.WRITE'), isFalse);
      expect(src.contains('HealthDataAccess.READ_WRITE'), isFalse);
      expect(src.contains('Permission.activityRecognition'), isFalse);
    });
  });
}
