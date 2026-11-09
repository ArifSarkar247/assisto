// k1-wake — Settings → Assisto Voice → "Hey Assisto": the prominent
// disclosure is shown before the first enable (and only then), "Not now"
// leaves it OFF, sensitivity is saved, the OEM guide opens, and the card
// renders in Bangla at 360 px with large text without overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/voice_assistant_settings_screen.dart';
import 'package:assisto/screens/wake_disclosure_screen.dart';
import 'package:assisto/screens/wake_oem_guide_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/voice/va_wake.dart';
import 'package:assisto/voice/va_wake_logic.dart';

Future<void> _pump(WidgetTester tester, Widget home,
    {String lang = 'en', double scale = 1.0, ThemeData? theme}) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>(
    create: (_) => AppState(),
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: theme ?? AssistoTheme.light,
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    ),
  ));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder _wakeSwitch() => find.byKey(const Key('va-wake-switch'));

Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 250, scrollable: find.byType(Scrollable).first);
  await _settle(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
  });

  testWidgets('disclosure before first enable; Not now keeps it off', (tester) async {
    await _pump(tester, const VoiceAssistantSettingsScreen(debugStatic: true));
    final t = _t(tester);
    await _scrollTo(tester, _wakeSwitch());
    expect(tester.widget<Switch>(_wakeSwitch()).value, isFalse);

    await tester.tap(_wakeSwitch());
    await _settle(tester);
    expect(find.byType(WakeDisclosureScreen), findsOneWidget);
    expect(find.text(t.vaWkDiscLead), findsOneWidget);
    await tester.tap(find.text(t.vaWkDiscNo));
    await _settle(tester);
    expect(find.byType(WakeDisclosureScreen), findsNothing);
    expect(await VaWake.disclosureAccepted(), isFalse);
    expect(tester.widget<Switch>(_wakeSwitch()).value, isFalse);

    await tester.tap(_wakeSwitch());
    await _settle(tester);
    await tester.tap(find.text(t.vaWkDiscAgree));
    await _settle(tester);
    expect(await VaWake.disclosureAccepted(), isTrue);
    expect(tester.widget<Switch>(_wakeSwitch()).value, isTrue);
    expect(find.text(t.vaWkStatusListening), findsOneWidget);
    expect(find.text(t.vaWkPause1h), findsOneWidget);
  });

  testWidgets('disclosure is not shown again once accepted', (tester) async {
    SharedPreferences.setMockInitialValues({'va_wake_disclosure_v1': true});
    Settings.resetForTest();
    await _pump(tester, const VoiceAssistantSettingsScreen(debugStatic: true));
    await _scrollTo(tester, _wakeSwitch());
    await tester.tap(_wakeSwitch());
    await _settle(tester);
    expect(find.byType(WakeDisclosureScreen), findsNothing);
    expect(tester.widget<Switch>(_wakeSwitch()).value, isTrue);
  });

  // wakeword: never listens on a locked phone without consent
  testWidgets('locked-phone listening is OFF until the user turns it on', (tester) async {
    await _pump(tester, const VoiceAssistantSettingsScreen(debugStatic: true));
    final sw = find.byKey(const Key('va-wake-locked'));
    await _scrollTo(tester, sw);
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    expect(await VaWake.lockedOk(), isFalse);
    await tester.tap(sw);
    await _settle(tester);
    expect(await VaWake.lockedOk(), isTrue);
    expect(tester.widget<SwitchListTile>(sw).value, isTrue);
  });

  testWidgets('default sensitivity is Low (fewest false wakes)', (tester) async {
    expect(await VaWake.level(), WakeLevel.low);
    await _pump(tester, const VoiceAssistantSettingsScreen(debugStatic: true));
    final t = _t(tester);
    await _scrollTo(tester, find.text(t.vaWkSensLowSub));
    expect(find.text(t.vaWkSensLowSub), findsOneWidget);
  });

  testWidgets('sensitivity is saved', (tester) async {
    await _pump(tester, const VoiceAssistantSettingsScreen(debugStatic: true));
    final t = _t(tester);
    final high = find.text(t.vaWkSensHigh);
    await _scrollTo(tester, high);
    await tester.tap(high);
    await _settle(tester);
    expect(await VaWake.level(), WakeLevel.high);
    expect(find.text(t.vaWkSensHighSub), findsOneWidget);
  });

  testWidgets('paused-by-user shows Resume and the time', (tester) async {
    await _pump(
        tester,
        VoiceAssistantSettingsScreen(
            debugStatic: true,
            debugWake: WakeStatus(WakeRun.paused,
                reason: 'user',
                wanted: true,
                pausedUntil: DateTime(2026, 10, 22, 15, 30))));
    final t = _t(tester);
    await _scrollTo(tester, find.text(t.vaWkResume));
    expect(find.text(t.vaWkResume), findsOneWidget);
    expect(find.textContaining('3:30'), findsOneWidget);
  });

  testWidgets('OEM guide opens with the maker first', (tester) async {
    await _pump(tester, const WakeOemGuideScreen(debugMaker: 'Xiaomi'));
    final t = _t(tester);
    expect(find.text(t.vaOemYourPhone('Xiaomi')), findsOneWidget);
    expect(find.text(t.vaOemOpenAutostart), findsOneWidget);
    expect(oemFamilyOf('realme'), OemFamily.oppo);
    expect(oemFamilyOf('samsung'), OemFamily.samsung);
    expect(oemFamilyOf('Google'), OemFamily.other);
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('no overflow at 360 px, large text, dark ($lang)', (tester) async {
      await _pump(
          tester,
          const VoiceAssistantSettingsScreen(
              debugStatic: true,
              debugWake: WakeStatus(WakeRun.listening, wanted: true)),
          lang: lang,
          scale: 1.3,
          theme: AssistoTheme.dark);
      for (var i = 0; i < 6; i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -500));
        await _settle(tester);
      }
      expect(tester.takeException(), isNull);
      await _pump(tester, const WakeDisclosureScreen(), lang: lang, scale: 1.3);
      expect(tester.takeException(), isNull);
      await _pump(tester, const WakeOemGuideScreen(debugMaker: 'realme'),
          lang: lang, scale: 1.3);
      expect(tester.takeException(), isNull);
    });
  }
}
