// cctvalerts (W3 smart alert types): the per-camera switches screen against a
// fake server — honest "Not on this camera" (switch disabled), a switch saves,
// a failed save reverts with a message, a failed load has a working retry,
// Bangla digits, 200% text + dark with no overflow, the entry tile on the
// zones screen, and alert rows that say WHAT happened.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/watchman/camera_alert_types.dart';
import 'package:assisto/screens/watchman/watchman_widgets.dart';
import 'package:assisto/screens/watchman/watchman_zones.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cctv1_fakes.dart';
import 'cctvalerts_fakes.dart';
import 'fake_api.dart';

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MaterialApp(
        key: UniqueKey(),
        locale: Locale(lang),
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

SwitchListTile _tile(WidgetTester tester, String label) => tester.widget<SwitchListTile>(
    find.ancestor(of: find.text(label), matching: find.byType(SwitchListTile)));

void main() {
  testWidgets('honest support: unsupported type is disabled + says so; a switch saves',
      (tester) async {
    final src = FakeAlertTypes('hik');
    await tester.pumpWidget(_app(CameraAlertTypesScreen(cameraId: 5, cameraName: 'Shop door', source: src)));
    await _settle(tester);
    expect(find.text('Alert types — Shop door'), findsOneWidget);
    expect(find.text('Not on this camera'), findsOneWidget);
    expect(_tile(tester, 'Animal (dog / cat)').onChanged, isNull);
    expect(_tile(tester, 'Animal (dog / cat)').value, isFalse);
    expect(find.textContaining('Line crossings today: 14'), findsOneWidget);
    expect(find.textContaining('your guard schedule'), findsOneWidget);
    expect(find.textContaining('No AI'), findsOneWidget);
    // sound is off by default; turn it on
    expect(_tile(tester, 'Loud sound').value, isFalse);
    await tester.tap(find.text('Loud sound'));
    await _settle(tester);
    expect(src.saved.single['sound'], isTrue);
    expect(_tile(tester, 'Loud sound').value, isTrue);
  });

  testWidgets('a failed save reverts the switch and says why', (tester) async {
    final src = FakeAlertTypes('savefail');
    await tester.pumpWidget(_app(CameraAlertTypesScreen(cameraId: 5, cameraName: 'Shop door', source: src)));
    await _settle(tester);
    await tester.tap(find.text('Person'));
    await _settle(tester);
    expect(src.saved, hasLength(1));
    expect(_tile(tester, 'Person').value, isTrue); // back to what the server has
    expect(find.text('Could not save. Check the internet and try again.'), findsOneWidget);
  });

  testWidgets('load error has a working retry', (tester) async {
    await tester.pumpWidget(_app(CameraAlertTypesScreen(
        cameraId: 5, cameraName: 'Shop door', source: FakeAlertTypes('fail'))));
    await _settle(tester);
    expect(find.textContaining('Could not load the alert types'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await _settle(tester);
    expect(find.text('Person'), findsOneWidget);
  });

  testWidgets('Bangla: digits, honest note, SD problem shown', (tester) async {
    await tester.pumpWidget(_app(
        CameraAlertTypesScreen(cameraId: 6, cameraName: 'গেট', source: FakeAlertTypes('imou', lang: 'bn')),
        lang: 'bn'));
    await _settle(tester);
    expect(find.text('সতর্কতার ধরন — গেট'), findsOneWidget);
    expect(find.textContaining('আজ রেখা পার: ১৪ বার'), findsOneWidget);
    expect(find.textContaining('ক → খ ৯'), findsOneWidget);
    expect(find.text('SD কার্ডে সমস্যা'), findsWidgets);
    final hik = FakeAlertTypes('hik', lang: 'bn');
    await tester.pumpWidget(_app(CameraAlertTypesScreen(cameraId: 5, cameraName: 'দরজা', source: hik), lang: 'bn'));
    await _settle(tester);
    expect(find.text('এই ক্যামেরায় নেই'), findsOneWidget);
  });

  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('200% text, $lang, dark=$dark: no overflow, 48dp rows', (tester) async {
        tester.view.physicalSize = const Size(1080, 2340);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_app(
            CameraAlertTypesScreen(cameraId: 6, cameraName: 'Gate', source: FakeAlertTypes('imou', lang: lang)),
            lang: lang, scale: 2.0, dark: dark));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(SwitchListTile).first).height,
            greaterThanOrEqualTo(48));
        await tester.drag(find.byType(ListView), const Offset(0, -3000));
        await _settle(tester);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the zones screen opens the alert types', (tester) async {
    await tester.pumpWidget(_app(WatchmanZonesScreen(
        source: FakeWatchman(), camera: FakeWatchman.cameraRow())));
    await _settle(tester, 20);
    await tester.scrollUntilVisible(find.text('Alert types'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Alert types'), findsOneWidget);
    expect(find.byType(CameraAlertTypesTile), findsOneWidget);
  });

  testWidgets('alert rows say what happened (server words first)', (tester) async {
    late AppLocalizations t;
    await tester.pumpWidget(_app(Builder(builder: (ctx) {
      t = AppLocalizations.of(ctx);
      return const SizedBox();
    })));
    expect(wmEventWhatOf(t, {'type': 'camera_alarm', 'what': 'A vehicle was seen'}), 'A vehicle was seen');
    expect(wmEventWhatOf(t, {'type': 'camera_health'}), 'Camera problem');
    expect(wmEventWhatOf(t, {'type': 'loitering', 'what': null}), 'Someone stayed over 2 minutes at night');
  });
}
