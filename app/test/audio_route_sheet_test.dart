// audioroute: the route picker sheet (Kotlin-free widget test) — names,
// tick, 48 dp tap targets, bn/en, TalkBack, 200 % text without clipping.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/audio/audio_route_service.dart';
import 'package:assisto/audio/audio_route_sheet.dart';
import 'package:assisto/l10n/app_localizations.dart';

const _all = [
  AudioRoute.earpiece,
  AudioRoute.speaker,
  AudioRoute.bluetooth,
  AudioRoute.wired,
];

Future<List<AudioRoute>> _pump(WidgetTester tester,
    {String lang = 'en',
    AudioRoute active = AudioRoute.bluetooth,
    String? name = 'AirPods Pro',
    bool denied = false,
    double scale = 1.0}) async {
  final picked = <AudioRoute>[];
  tester.view.physicalSize = const Size(360, 800) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    locale: Locale(lang),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(
          size: const Size(360, 800), textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            child: AudioRouteSheet(
              routes: _all,
              active: active,
              bluetoothName: name,
              bluetoothDenied: denied,
              onPick: picked.add,
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return picked;
}

void main() {
  testWidgets('en: every route, Bluetooth device name, active ticked',
      (tester) async {
    final picked = await _pump(tester);
    for (final r in _all) {
      expect(find.byKey(Key('call-route-${r.name}')), findsOneWidget);
    }
    expect(find.text('AirPods Pro'), findsOneWidget);
    expect(find.text('Bluetooth'), findsOneWidget); // subtitle
    expect(find.text('Wired earphones'), findsOneWidget);
    expect(find.text('Speaker'), findsOneWidget);
    final tick = find.descendant(
        of: find.byKey(const Key('call-route-bluetooth')),
        matching: find.byIcon(Icons.check_rounded));
    expect(tick, findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('call-route-speaker')),
            matching: find.byIcon(Icons.check_rounded)),
        findsNothing);
    await tester.tap(find.byKey(const Key('call-route-wired')));
    expect(picked, [AudioRoute.wired]);
  });

  testWidgets('bn labels', (tester) async {
    final t = await AppLocalizations.delegate.load(const Locale('bn'));
    await _pump(tester, lang: 'bn', name: null, active: AudioRoute.earpiece);
    expect(find.text(t.arRouteSheetTitle), findsOneWidget);
    expect(find.text(t.arRouteEarpiece), findsOneWidget);
    expect(find.text(t.arRouteBluetooth), findsOneWidget);
    expect(find.text(t.arRouteWired), findsOneWidget);
  });

  testWidgets('48 dp targets + labelled for TalkBack', (tester) async {
    final h = tester.ensureSemantics();
    await _pump(tester);
    for (final r in _all) {
      final size = tester.getSize(find.byKey(Key('call-route-${r.name}')));
      expect(size.height, greaterThanOrEqualTo(48), reason: r.name);
    }
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    // the active row is announced as selected
    expect(tester.getSemantics(find.byKey(const Key('call-route-bluetooth'))),
        containsSemantics(isSelected: true));
    h.dispose();
  });

  testWidgets('200 % text: no overflow, names wrap', (tester) async {
    await _pump(tester, scale: 2.0, denied: true);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('call-route-bt-denied')), findsOneWidget);
  });

  testWidgets('permission refused: honest note + settings button',
      (tester) async {
    await _pump(tester, denied: true, active: AudioRoute.earpiece);
    expect(find.textContaining('Nearby devices'), findsOneWidget);
    expect(find.text('Open settings'), findsOneWidget);
  });
}
