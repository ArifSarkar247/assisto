// b6-antitheft — widget tests for the always-on protection screen:
//   * honest states (ON card + limits text, OFF card),
//   * the disable flow asks for the Security PIN (Section 8),
//   * the engine timeline renders events with honest "late" labelling,
//   * no native plugin is required (the channel is mocked; a missing channel
//     is handled gracefully).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/always_on_protection_screen.dart';
import 'package:assisto/screens/intruder_consent_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

const _channel = MethodChannel('com.assisto/antitheft');

void _mockNative({bool running = false}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    switch (call.method) {
      case 'capabilities':
        return {'sdk': 33, 'brand': 'realme', 'canCamera': true,
                'cameraPermission': false, 'canReadSimNumber': false};
      case 'isRunning':
        return running;
      case 'start':
        return true;
      default:
        return null;
    }
  });
}

AppState _state(FakeApi api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'Me', phone: '+8801700000000', email: '',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Future<void> _pump(WidgetTester tester, Widget home, FakeApi api,
    {String lang = 'en'}) async {
  await tester.binding.setSurfaceSize(const Size(400, 900));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: _state(api, lang),
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: home,
    ),
  ));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('ON state shows the protection-on card and honest limits',
      (tester) async {
    _mockNative(running: true);
    await _pump(tester, const AlwaysOnProtectionScreen(),
        FakeApi(mode: FakeMode.data, lang: 'en'));
    final t = AppLocalizations.of(
        tester.element(find.byType(AlwaysOnProtectionScreen)));
    expect(find.text(t.atStateOn), findsOneWidget);
    // a turn-off control is offered when protection is on
    expect(find.text(t.atTurnOff), findsWidgets);
    // scroll down and confirm the honest-limits card is present
    await tester.dragUntilVisible(
      find.text(t.atLimitsTitle),
      find.byType(Scrollable).first,
      const Offset(0, -300),
    );
    expect(find.text(t.atLimitsTitle), findsOneWidget);
  });

  testWidgets('degraded state when server says ON but native not running',
      (tester) async {
    _mockNative(running: false); // engine not running
    await _pump(tester, const AlwaysOnProtectionScreen(),
        FakeApi(mode: FakeMode.data, lang: 'en'));
    final t = AppLocalizations.of(
        tester.element(find.byType(AlwaysOnProtectionScreen)));
    expect(find.text(t.atStateDegraded), findsOneWidget);
  });

  testWidgets('OFF state shows a Turn on button', (tester) async {
    _mockNative();
    await _pump(tester, const AlwaysOnProtectionScreen(),
        FakeApi(mode: FakeMode.empty, lang: 'en'));
    final t = AppLocalizations.of(
        tester.element(find.byType(AlwaysOnProtectionScreen)));
    expect(find.text(t.atStateOff), findsOneWidget);
    expect(find.text(t.atTurnOn), findsOneWidget);
  });

  testWidgets('disable asks to confirm and then for the Security PIN',
      (tester) async {
    _mockNative(running: true);
    await _pump(tester, const AlwaysOnProtectionScreen(),
        FakeApi(mode: FakeMode.data, lang: 'en'));
    final t = AppLocalizations.of(
        tester.element(find.byType(AlwaysOnProtectionScreen)));
    // tap the turn-off button in the status card
    await tester.tap(find.widgetWithText(OutlinedButton, t.atTurnOff));
    await tester.pumpAndSettle();
    // confirmation dialog
    expect(find.text(t.atDisableTitle), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, t.atTurnOff));
    await tester.pumpAndSettle();
    // Security PIN prompt (Section 8) — a text field asking for the PIN
    expect(find.byType(TextField), findsWidgets);
  });

  testWidgets('intruder photo is opt-in: off by default, disclosure first',
      (tester) async {
    _mockNative(running: true);
    final api = FakeApi(mode: FakeMode.data, lang: 'en');
    await _pump(tester, const AlwaysOnProtectionScreen(), api);
    final t = AppLocalizations.of(
        tester.element(find.byType(AlwaysOnProtectionScreen)));
    final tile = find.widgetWithText(SwitchListTile, t.atOptIntruder);
    await tester.dragUntilVisible(
        tile, find.byType(Scrollable).first, const Offset(0, -200));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.tap(find.descendant(of: tile, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    // at100: the full consent screen BEFORE any permission / PIN prompt
    expect(find.byType(IntruderConsentScreen), findsOneWidget);
    expect(find.text(t.at100IcAgree), findsOneWidget);
    await tester.tap(find.byKey(const Key('at100-ic-no')));
    await tester.pumpAndSettle();
    // cancelled: nothing changed, no PIN prompt
    expect(find.byType(IntruderConsentScreen), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });

  testWidgets('no front camera: the intruder switch is disabled and says why',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'capabilities') return {'sdk': 33, 'canCamera': false};
      if (call.method == 'isRunning') return true;
      return null;
    });
    await _pump(tester, const AlwaysOnProtectionScreen(),
        FakeApi(mode: FakeMode.data, lang: 'en'));
    final t = AppLocalizations.of(
        tester.element(find.byType(AlwaysOnProtectionScreen)));
    final tile = find.widgetWithText(SwitchListTile, t.atOptIntruder);
    await tester.dragUntilVisible(
        tile, find.byType(Scrollable).first, const Offset(0, -200));
    expect(tester.widget<SwitchListTile>(tile).onChanged, isNull);
    expect(find.text(t.atOptIntruderBlocked), findsOneWidget);
  });

  testWidgets('timeline renders events with an honest late label',
      (tester) async {
    _mockNative();
    await _pump(tester, const AntiTheftTimelineScreen(),
        FakeApi(mode: FakeMode.data, lang: 'en'));
    final t = AppLocalizations.of(
        tester.element(find.byType(AntiTheftTimelineScreen)));
    expect(find.text(t.atKindSim), findsOneWidget);
    expect(find.text(t.atKindOffline), findsOneWidget);
    // the offline event in the fake is late → its subtitle uses atLateAt
    expect(
        find.byWidgetPredicate((w) =>
            w is Text && (w.data ?? '').startsWith('Happened at')),
        findsWidgets);
  });

  testWidgets('empty timeline shows the honest no-events state', (tester) async {
    _mockNative();
    await _pump(tester, const AntiTheftTimelineScreen(),
        FakeApi(mode: FakeMode.empty, lang: 'en'));
    final t = AppLocalizations.of(
        tester.element(find.byType(AntiTheftTimelineScreen)));
    expect(find.text(t.atNoEvents), findsOneWidget);
  });
}
