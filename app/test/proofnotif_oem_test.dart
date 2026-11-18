// proof-notif: the "allow background / autostart" help on the two phone
// families where closed-app reminders and pushes fail most in Bangladesh —
// ColorOS (realme, e.g. the owner's Realme 9i) and Xiaomi (MIUI / HyperOS).
// The brand-worded steps must show, and every "Open" button must really call
// the native vendor screen (no dead end).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/battery_guidance_screen.dart';
import 'package:assisto/services/oem_guide.dart';
import 'package:assisto/state.dart';

import 'fake_api.dart';
import 'tl1_fakes.dart';

Widget _app(Widget home, String lang) {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(
      id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(360, 2400)),
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OemGuideGate.resetForTest();
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('realme (ColorOS): autostart + battery steps, Open reaches the vendor screen ($lang)',
        (tester) async {
      final t = await AppLocalizations.delegate.load(Locale(lang));
      await tester.binding.setSurfaceSize(const Size(360, 2400));
      final fake = FakeOemNative(tl1Phone('realme'), avail: tl1Avail('realme'));
      await tester.pumpWidget(_app(BatteryGuidanceScreen(native: fake), lang));
      await _settle(tester);
      expect(tl1Phone('realme').family, OemFamily.realme);
      expect(find.text(t.oemStepAutostartRealme), findsOneWidget);
      expect(find.text(t.oemStepOemBatteryOppo), findsOneWidget); // ColorOS battery page
      expect(find.text(t.oemGuideByHand), findsOneWidget); // lock in recents: honest, no button
      final open = find.widgetWithText(FilledButton, t.open);
      expect(open, findsWidgets);
      await tester.tap(open.first);
      await _settle(tester);
      expect(fake.opened, ['autostart'], reason: 'first step = ColorOS auto-launch list');
      await tester.binding.setSurfaceSize(null);
    });
  }

  testWidgets('Xiaomi (MIUI / HyperOS): autostart + battery saver steps; Open works',
      (tester) async {
    final t = await AppLocalizations.delegate.load(const Locale('bn'));
    await tester.binding.setSurfaceSize(const Size(360, 2400));
    final fake = FakeOemNative(tl1Phone('xiaomi'), avail: tl1Avail('xiaomi'));
    await tester.pumpWidget(_app(BatteryGuidanceScreen(native: fake), 'bn'));
    await _settle(tester);
    expect(find.text(t.oemStepAutostartXiaomi), findsOneWidget);
    expect(find.text(t.oemStepOemBatteryXiaomi), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, t.open).first);
    await _settle(tester);
    expect(fake.opened, ['autostart']);
    await tester.binding.setSurfaceSize(null);
  });
}
