// cctv100: paste the camera label's QR text instead of typing the serial and
// the safety code. Parser shapes + the real button on the Imou link form.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/l10n/app_localizations_en.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/watchman/camera_label.dart';
import 'package:assisto/screens/watchman/watchman_add_camera.dart';
import 'package:assisto/state.dart';

import 'cctv1_fakes.dart';
import 'fake_api.dart';

final en = AppLocalizationsEn();

Widget _app(Widget home, String lang) {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
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
  );
}

void _clipboard(WidgetTester tester, String? text) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
      (call) async {
    if (call.method == 'Clipboard.getData') {
      return text == null ? null : <String, dynamic>{'text': text};
    }
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('parseCameraLabel', () {
    test('Imou / Dahua key-value QR', () {
      final l = parseCameraLabel('{SN:7J0A8B9CPAZ1234,DT:IPC-A22EP,SC:L2C3D4,NC:SL}')!;
      expect([l.serial, l.code, l.model], ['7J0A8B9CPAZ1234', 'L2C3D4', 'IPC-A22EP']);
    });
    test('older Lechange sticker uses RC', () {
      final l = parseCameraLabel('SN:5g0abc1234567;RC:abcdef')!;
      expect([l.serial, l.code], ['5G0ABC1234567', 'abcdef']);
    });
    test('line form (serial, verification code, model)', () {
      final l = parseCameraLabel('BD1234567\nABCDEF\nCS-C6N-A0-1C2WFR')!;
      expect([l.serial, l.code, l.model], ['BD1234567', 'ABCDEF', 'CS-C6N-A0-1C2WFR']);
    });
    test('serial only', () {
      final l = parseCameraLabel(' 7J0A8B9CPAZ1234 ')!;
      expect([l.serial, l.code], ['7J0A8B9CPAZ1234', '']);
    });
    test('not a label: nothing invented', () {
      expect(parseCameraLabel(''), isNull);
      expect(parseCameraLabel(null), isNull);
      expect(parseCameraLabel('https://www.imoulife.com/download'), isNull);
      expect(parseCameraLabel('hello world'), isNull);
      expect(parseCameraLabel('x' * 500), isNull);
    });
  });

  Future<void> openImou(WidgetTester tester) async {
    tester.view.physicalSize = const Size(720, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(
        WatchmanAddCameraScreen(
            source: FakeWatchman(),
            site: const {'id': 1, 'gateway': 'phone'},
            limits: const {},
            credits: 0,
            imouCloud: true),
        'en'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Imou'));
    await tester.pumpAndSettle();
  }

  testWidgets('paste label QR fills serial + safety code', (tester) async {
    _clipboard(tester, '{SN:7J0A8B9CPAZ1234,DT:IPC-A22EP,SC:L2C3D4,NC:SL}');
    await openImou(tester);
    final btn = find.byKey(const Key('wmPasteLabel'));
    expect(btn, findsOneWidget);
    expect(tester.getSize(btn).height, greaterThanOrEqualTo(48));
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(find.text('7J0A8B9CPAZ1234'), findsOneWidget);
    expect(find.text('L2C3D4'), findsOneWidget);
    expect(find.text(en.wmPasteLabelBoth), findsOneWidget);
  });

  testWidgets('nothing usable copied: honest how-to, fields untouched', (tester) async {
    _clipboard(tester, 'hello');
    await openImou(tester);
    await tester.tap(find.byKey(const Key('wmPasteLabel')));
    await tester.pumpAndSettle();
    expect(find.text(en.wmPasteLabelNone), findsOneWidget);
    expect(find.text('hello'), findsNothing);
  });
}
