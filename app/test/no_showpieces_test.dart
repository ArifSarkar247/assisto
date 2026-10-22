// NO SHOWPIECES — permanent owner rule (round 2, item 4):
// nothing in the app may say "arrives in the next update" / "coming soon" for
// a feature the user can tap. Either it really works, or its entry point is
// hidden until it does.
//
// 1) Scans every ARB value (en + bn) for "future promise" phrases. A hit fails
//    unless the key is on the explicit, shrinking allow-list below (each entry
//    names the agent that owns the fix). Adding a key here is a product
//    decision — prefer hiding the entry point.
// 2) Scans Dart UI code for hard-coded English "coming soon" / "next update"
//    string literals.
// 3) Pins the hide-until-shipped switches (wake word, fall detection, plan
//    checkout, My Circle camera send) and checks the hidden UI really is gone.
import 'dart:convert';
import 'dart:io';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/fall_detect_screen.dart';
import 'package:assisto/services/circle_media_gate.dart';
import 'package:assisto/screens/voice_assistant_settings_screen.dart';
import 'package:assisto/voice/va_wake.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// English "we'll ship it later" phrasing.
final _enBanned = RegExp(
  r"next (app )?update|coming soon|\bcoming (in|here|with)\b|\bis coming(?! up)\b|"
  r"\bare coming\b|later update|future update|later version|next version|"
  r"not in this (app )?(build|version)|in this (app )?(build|version)|"
  r"this version can't|\barrives? (in|with|when)\b|will arrive|will come|"
  r"comes? later|comes? after|added soon|available soon|with an update|"
  r"needs? (an|the next) update|once added",
  caseSensitive: false,
);

/// Bangla equivalents (পরের আপডেটে, শিগগির আসছে, এই সংস্করণে …).
final _bnBanned = RegExp(
  r'পরের (অ্যাপ )?আপডেট|পরবর্তী আপডেট|ভবিষ্যতে?র? আপডেট|ভবিষ্যৎ আপডেট|'
  r'শিগগির আসছে|শীঘ্রই এখানে|আপডেটের সাথে আসবে|এই বিল্ডে|'
  r'এই (অ্যাপ )?সংস্করণে|পরে আসবে|পরে যুক্ত হবে|শিগগির একটি',
);

/// Keys still carrying a promise, each owned by a parallel agent / handover.
/// This list must only SHRINK. When the owner fixes a key, delete it here.
const _pendingHandover = {
  // p2-photo (Photo Studio, round 2 item 4a-4c): psEnhanceNotInBuild /
  // psIdentityMissing / psSecureOff were resolved + removed by p2 (Build B).
  'psSinkUnavailable', 'psGateAdsNotLinked',
  // b2-badges (push / notification settings)
  'pushSetDeliveryOffBuild',
};

Map<String, dynamic> _arb(String lang) => (jsonDecode(
        File('lib/l10n/app_$lang.arb').readAsStringSync()) as Map)
    .cast<String, dynamic>();

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

void main() {
  group('ARB copy has no "coming soon" promises', () {
    for (final (lang, rx) in [('en', _enBanned), ('bn', _bnBanned)]) {
      test('$lang values', () {
        final arb = _arb(lang);
        final hits = <String>[];
        arb.forEach((k, v) {
          if (k.startsWith('@') || v is! String) return;
          if (_pendingHandover.contains(k)) return;
          if (rx.hasMatch(v)) hits.add('$k: $v');
        });
        expect(hits, isEmpty,
            reason: 'NO SHOWPIECES: make it work or hide the entry point '
                '(never "next update / coming soon"):\n${hits.join('\n')}');
      });
    }

    test('the phrase filter really catches the classic showpiece lines', () {
      for (final s in [
        'Reading your phonebook arrives in the next update',
        'Coming soon — available once the key is set up.',
        'Not in this app version yet — it arrives with an update.',
        'Coming in a later update.',
        'Reward ads will arrive in a future update.',
      ]) {
        expect(_enBanned.hasMatch(s), isTrue, reason: s);
      }
      for (final s in [
        'ফোনবুক পড়ার সুবিধা আসছে পরের আপডেটে',
        'শিগগির আসছে — ওয়েক-ওয়ার্ড কি সেট হলেই চালু হবে।',
        'পরবর্তী আপডেটে চালু হবে।',
      ]) {
        expect(_bnBanned.hasMatch(s), isTrue, reason: s);
      }
      // honest present-tense copy is fine
      for (final s in ['A birthday is coming up.', 'Upcoming', 'Due soon']) {
        expect(_enBanned.hasMatch(s), isFalse, reason: s);
      }
    });

    test('removed showpiece keys stay removed', () {
      final en = _arb('en');
      for (final k in [
        'c1PhonebookNextUpdateTitle', 'c1PhonebookNextUpdateBody',
        'vaWakeComing', 'vaNeedsUpdate', 'sosHookGated', 'hwIosSoon',
        'plansBillingComingSoon', 'camMediaGatedNote', 'q1ExtrasNotYetTitle',
        'msgAutoDlNotYet', 'lostStolenSmsTriggerSoon', 'wellPhotoSeam',
        'circleExtrasWebAfterMobile', 'h1OnDeviceUnavailable',
        'safetyFallSensorGated',
      ]) {
        expect(en.containsKey(k), isFalse, reason: k);
      }
    });
  });

  test('no hard-coded "coming soon" / "next update" literals in Dart UI', () {
    final lit = RegExp(r'''(['"])[^'"\n]*(coming soon|next update|later update)[^'"\n]*\1''',
        caseSensitive: false);
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.contains('${Platform.pathSeparator}l10n${Platform.pathSeparator}')) {
        continue;
      }
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trimLeft();
        if (l.startsWith('//') || l.startsWith('*') || l.startsWith('///')) {
          continue;
        }
        if (lit.hasMatch(l)) hits.add('${f.path}:${i + 1}: $l');
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  group('hide-until-shipped switches', () {
    test('flags are off until the real engines ship', () {
      expect(VaWake.shipped, isFalse,
          reason: 'the wake-word branch flips this together with the engine');
      expect(FallDetectScreen.engineShipped, isFalse);
      expect(kCircleMediaStorageOn, isFalse);
    });

    testWidgets('voice settings: no "Hey Assisto" card while not shipped',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          _wrap(const VoiceAssistantSettingsScreen(debugStatic: true)));
      await tester.pumpAndSettle();
      final t = AppLocalizations.of(
          tester.element(find.byType(VoiceAssistantSettingsScreen)));
      expect(find.text(t.vaDefTitle), findsOneWidget);
      expect(find.text(t.vaWakeTitle2), findsNothing);
      expect(find.text(t.vaWakeEngineMissing), findsNothing);
    });
  });
}
