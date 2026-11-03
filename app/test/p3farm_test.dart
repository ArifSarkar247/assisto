// p3farm: Farmer mode Help tab (big buttons + Listen), per-crop calendar
// (official sources) and the disease check (AI photo only when a vision key
// is connected; offline symptom picker + 16123 always).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/farmer/farmer_help.dart';
import 'package:assisto/state.dart';
import 'package:assisto/voice/reply_speaker.dart';
import 'package:assisto/widgets/farmer_crop_data.dart';

import 'world_fake.dart';

Widget _app(Widget child, {String lang = 'en', double scale = 1}) =>
    ChangeNotifierProvider<AppState>(
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
        builder: (ctx, c) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: c!),
        home: child,
      ),
    );

String _m(int m) => 'M$m';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('crop data', () {
    test('every month has work and every crop has a valid official source', () {
      for (var m = 1; m <= 12; m++) {
        expect(cropsActiveIn(m), isNotEmpty, reason: 'month $m');
      }
      for (final c in kCropCalendar) {
        for (final x in [...c.sow, ...c.transplant, ...c.harvest]) {
          expect(x, inInclusiveRange(1, 12), reason: c.crop);
        }
        expect(c.sow, isNotEmpty);
        expect(c.harvest, isNotEmpty);
        expect(kFarmSourceUrls[c.source], contains('.gov.bd'));
      }
      for (final ps in kFarmProblems.values) {
        for (final p in ps) {
          expect(kFarmSourceUrls[p.source], contains('.gov.bd'));
        }
      }
      expect(kKrishiCallCentre, '16123');
    });

    test('November: Aman harvest, Boro seedbed, potato sowing', () {
      final nov = {for (final c in cropsActiveIn(11)) c.crop: c.jobsIn(11)};
      expect(nov['aman_rice'], ['harvest']);
      expect(nov['boro_rice'], ['sow']);
      expect(nov['potato'], ['sow']);
      expect(nov.containsKey('jute'), isFalse);
    });
  });

  testWidgets('Help tab: 7 big buttons, khata/calendar switch tabs, Listen speaks',
      (tester) async {
    final opened = <int>[];
    final spoken = <String>[];
    final speaker = ReplySpeaker(
        speak: (text, lang) async {
          spoken.add('$lang:$text');
          return 'ok';
        },
        stop: () async {});
    await tester.pumpWidget(_app(Scaffold(
        body: FarmerHelpTab(
            onOpenTab: opened.add, worldApi: FakeWorldApi(), speaker: speaker))));
    await tester.pumpAndSettle();
    for (final id in ['disease', 'disaster', 'weather', 'market', 'call', 'khata', 'calendar']) {
      await tester.scrollUntilVisible(find.byKey(ValueKey('farm_tile_$id')), 120);
      expect(find.byKey(ValueKey('farm_tile_$id')), findsOneWidget);
    }
    await tester.tap(find.text('My farm khata'));
    await tester.tap(find.text('Crop calendar'));
    expect(opened, [1, 2]);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('farm_tile_calendar')),
        matching: find.byIcon(Icons.volume_up_rounded)));
    await tester.pumpAndSettle();
    expect(spoken.single, startsWith('en:Crop calendar'));
  });

  testWidgets('Market price: honest sheet, no price, DAM site + khata', (tester) async {
    final opened = <int>[];
    await tester.pumpWidget(_app(Scaffold(
        body: FarmerHelpTab(onOpenTab: opened.add, worldApi: FakeWorldApi()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Market price'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('farm_market_dam')), findsOneWidget);
    expect(find.textContaining('৳'), findsNothing);
    await tester.tap(find.text('My farm khata').last);
    await tester.pumpAndSettle();
    expect(opened, [1]);
  });

  testWidgets('Crop calendar section: this-month strip + sources', (tester) async {
    await tester.pumpWidget(_app(Scaffold(
        body: ListView(children: [
      FarmCropCalendarSection(month: 11, monthName: _m),
    ]))));
    await tester.pumpAndSettle();
    expect(find.text('This month — M11'), findsOneWidget);
    expect(find.textContaining('Aman rice: Harvest'), findsOneWidget);
    expect(find.textContaining('BRRI (Rice Research Institute)'), findsWidgets);
    expect(find.byKey(const ValueKey('farm_crop_summer_veg')), findsOneWidget);
  });

  testWidgets('Disease: no vision key -> honest note, symptom picker, 16123 always',
      (tester) async {
    await tester.pumpWidget(_app(FarmDiseaseScreen(worldApi: FakeWorldApi(photoReady: false))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('farm_dz_photo')), findsNothing);
    expect(find.byKey(const ValueKey('farm_dz_photo_off')), findsOneWidget);
    expect(find.byKey(const ValueKey('farm_call_16123')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('farm_dz_group_rice')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('farm_dz_sign_rice_blast')), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('farm_dz_sign_rice_blast')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('farm_dz_result_rice_blast')), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const ValueKey('farm_dz_result_rice_blast')), findsOneWidget);
    expect(find.text('It may be: Blast'), findsOneWidget);
    // switching crop clears the old answer
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('farm_dz_group_potato')), -150,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('farm_dz_group_potato')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('farm_dz_result_rice_blast')), findsNothing);
    expect(find.byKey(const ValueKey('farm_dz_sign_potato_late_blight'), skipOffstage: false),
        findsOneWidget);
  });

  testWidgets('Disease: vision key connected -> photo card shown', (tester) async {
    await tester.pumpWidget(_app(FarmDiseaseScreen(worldApi: FakeWorldApi(photoReady: true))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('farm_dz_photo')), findsOneWidget);
    expect(find.byKey(const ValueKey('farm_dz_photo_off')), findsNothing);
  });

  testWidgets('Disease result in Bangla at 200% font does not overflow', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(
        FarmDiseaseScreen(
            worldApi: FakeWorldApi(lang: 'bn'),
            initialGroup: 'veg',
            initialProblem: 'gourd_fruit_fly'),
        lang: 'bn',
        scale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('farm_dz_result_gourd_fruit_fly')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('farm_dz_result_gourd_fruit_fly')), findsOneWidget);
  });
}
