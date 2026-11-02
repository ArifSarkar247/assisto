// cctvveh — owner checklist sweep of the two launch features (CCTV #1,
// Vehicle tracking #2):
//   * FIRST-RUN SETUP TIMED: the "add camera" journey (empty watchman → place
//     → gateway code → camera found on Wi-Fi → 4-step check OK) and the "add
//     tracker" journey (empty list → IMEI/brand/SIM → the setup SMS → first
//     location) are driven tap by tap; every user action is charged on a
//     published touch keystroke-level model (below). Targets: CCTV < 2 min,
//     vehicle < 3 min of USER time (machine waits — the gateway check, the
//     tracker's first fix — are reported separately, never hidden).
//   * people come from My Circle in one tap (watchman viewers, drivers);
//   * honest empty states (benefit + big button + how-to), no fake ticks,
//     no dead taps (waiting tracker), Sinotrack id inferred, 200% + dark.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/my_vehicles_screen.dart';
import 'package:assisto/screens/vehicle_drivers_screen.dart';
import 'package:assisto/screens/vehicle_tracking_screen.dart';
import 'package:assisto/screens/watchman/cash_guard_screen.dart';
import 'package:assisto/screens/watchman/cctvx_inbox.dart';
import 'package:assisto/screens/watchman/watchman_add_camera.dart';
import 'package:assisto/screens/watchman/watchman_alerts.dart';
import 'package:assisto/screens/watchman/watchman_screen.dart';
import 'package:assisto/screens/watchman/watchman_viewers.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/cv_empty.dart';

import 'cashguard_fakes.dart';
import 'cctv1_fakes.dart';
import 'cctvx_fakes.dart';
import 'fake_api.dart';

// ------------------------------------------------------------- user clock
/// Touch keystroke-level model (Card, Moran & Newell KLM, adapted for
/// phones in the touch-KLM literature): a mental step ≈ 1.2 s, a tap ≈ 0.3 s,
/// thumb typing ≈ 0.5 s a character. We round UP on purpose:
///   read a new screen      3.0 s   (glance at the title + the button)
///   tap a button           1.5 s   (find it + tap)
///   choose among options   2.5 s   (read the options + tap one)
///   type N characters      1.5 s + 0.5 s × N   (focus the field + type)
///   send one SMS           4.5 s   (tap "Send SMS", tap send, come back)
class UserClock {
  double seconds = 0;
  int taps = 0, typed = 0, screens = 0;
  final List<String> log = [];
  void read(String what) {
    seconds += 3.0;
    screens++;
    log.add('read $what');
  }

  void tap(String what) {
    seconds += 1.5;
    taps++;
    log.add('tap $what');
  }

  void choose(String what) {
    seconds += 2.5;
    taps++;
    log.add('choose $what');
  }

  void type(String what, String text) {
    seconds += 1.5 + 0.5 * text.length;
    typed += text.length;
    log.add('type $what (${text.length})');
  }

  void sms(String what) {
    seconds += 4.5;
    taps += 2;
    log.add('sms $what');
  }

  String summary(String name) =>
      '$name: ${seconds.toStringAsFixed(1)} s of user steps · $taps taps · $typed characters · '
      '$screens screens — ${log.join(' → ')}';
}

// ------------------------------------------------------------- harness
AppState _state(ApiClient api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(Widget home, {ApiClient? api, String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(api ?? FakeApi(), lang),
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

void _phone(WidgetTester tester, {double height = 2000}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _settle(tester);
}

final _circleRows = <Map<String, dynamic>>[
  {'circle_id': 1, 'name': 'Mother', 'relation': 'mother', 'phone': '01710000000'},
  {'circle_id': 2, 'name': 'Rafi', 'relation': 'brother', 'phone': '01810000000'},
];

/// A vehicle API: an empty tracker list until a tracker is paired.
class _VehApi extends FakeApi {
  final List<Map<String, dynamic>> posted = [];
  List<Map<String, dynamic>> trackers = [];
  String state = 'pending';
  bool hasFix = false;
  String protocol = 'gt06';
  List<Map<String, dynamic>> drivers = [];

  Map<String, dynamic> tracker() => {
        'id': 9,
        'name': 'Bike',
        'imei': '359339077003915',
        'protocol': protocol,
        'state': state,
        'online': state == 'paired',
        'is_owner': true,
        'pair_expires_at': DateTime.now().toUtc().add(const Duration(minutes: 9)).toIso8601String(),
        'live': hasFix ? {'lat': 23.78, 'lng': 90.41, 'speed_kmh': 0, 'moving': false} : null,
      };

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/vehicle/trackers') return {'trackers': trackers, 'month_credits': 50};
    if (path == '/vehicle/maintenance') return {'due': []};
    if (path.startsWith('/vehicle/setup-guide')) {
      return {
        'protocol': protocol, 'id_hint': protocol == 'h02' ? 'id_10' : '', 'reply_ok': 'OK',
        'steps': [
          {'sms': 'APN,internet#', 'what': 'apn'},
          {'sms': 'SERVER,0,16.4.105.173,5023,0#', 'what': 'server'},
          {'sms': 'GPRSON,1#', 'what': 'gprs_on'},
        ],
      };
    }
    if (path.startsWith('/vehicle/trackers/')) return tracker();
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    if (path == '/vehicle/trackers') {
      posted.add(body);
      protocol = '${body['protocol']}' == 'auto' ? 'gt06' : '${body['protocol']}';
      return {'ok': true, 'tracker': tracker()};
    }
    return super.postJson(path, body);
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async {
    if (path == 'vehicle/drivers') return drivers;
    if (path == 'vehicle/records') return [];
    return super.listItems(path);
  }
}

late AppLocalizations en;
late AppLocalizations bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cvCircleLoaderOverride = (_) async => _circleRows;
  });
  tearDown(() => cvCircleLoaderOverride = null);

  // ------------------------------------------------------------ CCTV
  testWidgets('TIMED: add a camera from zero — under 2 minutes of user steps', (tester) async {
    _phone(tester, height: 2400);
    final src = FakeWatchman('empty');
    final clock = UserClock();
    await tester.pumpWidget(_app(WatchmanScreen(source: src)));
    await _settle(tester);
    clock.read('welcome (guide + under-2-min promise)');
    expect(find.text(en.cvvWelcomeBody), findsOneWidget);
    await _tap(tester, find.text(en.wmStartSetup));
    clock.tap('start setup');

    clock.read('step 1 — home or shop (home is chosen)');
    await _tap(tester, find.text(en.wmNext));
    clock.tap('next');

    clock.read('step 2 — gateway');
    await _tap(tester, find.text(en.wmGwPc));
    clock.choose('my own computer');
    await _tap(tester, find.text(en.wmNext));
    clock.tap('next');

    clock.read('step 3 — name (pre-filled)');
    final nameField = tester.widget<TextField>(find.byType(TextField));
    expect(nameField.controller!.text, en.wmKindHome, reason: 'no typing needed');
    await _tap(tester, find.text(en.wmCreatePlace));
    await _settle(tester, 20);
    clock.tap('create place');
    expect(src.calls, contains('setup:home:pc'));

    clock.read('pairing sheet (code + QR)');
    expect(find.text('PAIR-CODE-FAKE-1'), findsOneWidget);
    clock.type('the code on the PC (Shop Box program)', 'PAIR-CODE-FAKE-1');
    await _tap(tester, find.byKey(const ValueKey('wm-pair-next')));
    await _settle(tester, 20);
    clock.tap('next: add a camera');

    clock.read('pick the brand');
    expect(find.byType(WatchmanAddCameraScreen), findsOneWidget);
    await _tap(tester, find.text('Hikvision'));
    await _settle(tester, 20);
    clock.choose('Hikvision');
    // the Wi-Fi search ran by itself and filled the one camera it found
    expect(src.calls, contains('discover'));
    final host = tester.widget<TextField>(find.widgetWithText(TextField, en.wmCamIp));
    expect(host.controller!.text, '192.168.1.20', reason: 'address filled, nothing typed');

    clock.read('camera form');
    await tester.enterText(find.widgetWithText(TextField, en.wmSecretPassword), 'Shop12345');
    clock.type('camera password', 'Shop12345');
    await _tap(tester, find.text(en.wmRunCheck));
    clock.tap('run the check');
    // machine time: the gateway runs the 4-step check (polled every 3 s)
    await tester.pump(const Duration(seconds: 4));
    await _settle(tester, 20);
    expect(find.text(en.wmResultOk), findsOneWidget);
    clock.read('result: works');

    // ignore: avoid_print
    print('SETUP_TIMING ${clock.summary('CCTV add camera')}');
    expect(clock.seconds, lessThan(120), reason: clock.summary('CCTV'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('place without a camera: benefit + big Add camera + 3 how-to steps', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(WatchmanScreen(source: FakeWatchman('nocam'), guide: false)));
    await _settle(tester);
    expect(find.text(en.cvvNoCamTitle), findsOneWidget);
    expect(find.text(en.cvvNoCamBenefit), findsOneWidget);
    expect(find.text(en.cvvNoCamStep3), findsOneWidget);
    // exactly one "Add camera" (the big one) — not a second outlined copy
    expect(find.text(en.wmAddCamera), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('cv-empty-primary')));
    expect(find.byType(WatchmanAddCameraScreen), findsOneWidget);
  });

  testWidgets('empty alerts: honest wording with/without a camera + first step', (tester) async {
    _phone(tester);
    var setup = 0;
    await tester.pumpWidget(_app(WatchmanAlertsScreen(
        source: FakeWatchman('empty'), siteId: 1, owner: true, hasCamera: false, onSetup: () => setup++)));
    await _settle(tester);
    expect(find.text(en.cvvAlertsEmptyNoCam), findsOneWidget);
    expect(find.text(en.cvvAlertsStep1), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('cv-empty-primary')));
    expect(setup, 1);
    // a family viewer sees no setup button and no how-to
    await tester.pumpWidget(_app(WatchmanAlertsScreen(source: FakeWatchman('empty'), siteId: 1, owner: false)));
    await _settle(tester);
    expect(find.byKey(const ValueKey('cv-empty-primary')), findsNothing);
    expect(find.text(en.cvvAlertsStep1), findsNothing);
  });

  testWidgets('family viewer picked from My Circle in one tap (number from Circle)', (tester) async {
    _phone(tester);
    final src = FakeWatchman('empty');
    await tester.pumpWidget(_app(WatchmanViewersScreen(source: src, siteId: 1)));
    await _settle(tester);
    expect(find.text(en.cvvViewersEmptyBenefit), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('cv-empty-primary')));
    expect(find.text('Mother'), findsOneWidget);
    await _tap(tester, find.text('Mother'));
    expect(src.calls, contains('addViewer:01710000000'));
    expect(find.text(en.cvvViewerAdded('Mother')), findsOneWidget);
  });

  testWidgets('Circle empty: the picker offers "Add someone to My Circle"', (tester) async {
    _phone(tester);
    cvCircleLoaderOverride = (_) async => [];
    await tester.pumpWidget(_app(WatchmanViewersScreen(source: FakeWatchman('empty'), siteId: 1)));
    await _settle(tester);
    await _tap(tester, find.byKey(const ValueKey('cv-empty-primary')));
    expect(find.text(en.cvvCircleEmptyTitle), findsOneWidget);
    expect(find.text(en.cvvOpenMyCircle), findsOneWidget);
  });

  testWidgets('cash guard checklist tells the truth (no fake ticks)', (tester) async {
    _phone(tester);
    var add = 0;
    await tester.pumpWidget(_app(CashGuardScreen(
        source: FakeCashGuard('nocam'), siteId: 1, onAddCamera: () => add++)));
    await _settle(tester);
    expect(find.text(en.cvvCgStepCameraNone), findsOneWidget);
    expect(find.text(en.cgSetupStepCamera), findsNothing);
    await _tap(tester, find.widgetWithText(TextButton, en.wmAddCamera));
    expect(add, 1);
    // a camera with a drawn cash zone → both ticks are real
    final cam = FakeWatchman.cameraRow()
      ..['zone_config'] = {
        'v': 2,
        'zones': [
          {'id': 'c', 'type': 'cash', 'points': [[0.1, 0.1], [0.3, 0.1], [0.3, 0.3]]}
        ]
      };
    await tester.pumpWidget(_app(CashGuardScreen(
        source: FakeCashGuard(), siteId: 1, cameras: [cam], onDrawZone: () {})));
    await _settle(tester);
    expect(find.text(en.cgSetupStepCamera), findsOneWidget);
    expect(find.text(en.cvvCgStepZoneDone), findsOneWidget);
    expect(find.text(en.cgSetupStepZone), findsNothing);
  });

  testWidgets('inbox empty explains how alerts arrive', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(GuardInboxScreen(source: FakeCctvx('empty'), cash: FakeCashGuard())));
    await _settle(tester);
    expect(find.text(en.cvvInboxEmptyBenefit), findsOneWidget);
    expect(find.text(en.cvvInboxStep2), findsOneWidget);
  });

  // ------------------------------------------------------------ vehicle
  testWidgets('TIMED: add a tracker from zero — under 3 minutes of user steps', (tester) async {
    _phone(tester, height: 3000);
    final api = _VehApi();
    final clock = UserClock();
    await tester.pumpWidget(_app(const VehicleTrackingScreen(), api: api));
    await _settle(tester);
    clock.read('empty list (benefit + how-to)');
    expect(find.text(en.cvvVehEmptyBody), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing, reason: 'one CTA when empty');
    await _tap(tester, find.byKey(const ValueKey('cv-empty-primary')));
    clock.tap('pair tracker');

    clock.read('pair form');
    await tester.enterText(find.widgetWithText(TextField, en.vehImeiLabel), '359339077003915');
    clock.type('IMEI from the label', '359339077003915');
    await _tap(tester, find.byKey(const ValueKey('veh-brand-concox')));
    clock.choose('brand on the box');
    await _tap(tester, find.text('Grameenphone'));
    clock.choose('SIM operator');
    await tester.enterText(find.widgetWithText(TextField, en.v100SimLabel), '01711222333');
    clock.type('tracker SIM number', '01711222333');
    await _tap(tester, find.byKey(const ValueKey('veh-pair-submit')));
    await _settle(tester, 20);
    clock.tap('start pairing');
    expect(api.posted.single['protocol'], 'gt06');

    clock.read('setup SMS steps');
    expect(find.text(en.v100SetupSendSms), findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      await _tap(tester, find.text(en.v100SetupSendSms).at(i));
      clock.sms('setup SMS ${i + 1}');
    }
    // machine time: the tracker dials in and sends its first fix
    api
      ..state = 'paired'
      ..hasFix = true;
    await tester.pump(const Duration(seconds: 5));
    await _settle(tester, 20);
    expect(find.text(en.v100SetupFirstFix), findsOneWidget);
    clock.read('connected — first location');

    // ignore: avoid_print
    print('SETUP_TIMING ${clock.summary('Vehicle add tracker')}');
    expect(clock.seconds, lessThan(180), reason: clock.summary('Vehicle'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a 10-digit id with brand unknown is taken as Sinotrack (no "bad IMEI")', (tester) async {
    _phone(tester, height: 3000);
    final api = _VehApi();
    await tester.pumpWidget(_app(const VehicleTrackingScreen(), api: api));
    await _settle(tester);
    await _tap(tester, find.byKey(const ValueKey('cv-empty-primary')));
    await tester.enterText(find.widgetWithText(TextField, en.vehImeiLabel), '8160528336');
    await _tap(tester, find.byKey(const ValueKey('veh-pair-submit')));
    await _settle(tester, 20);
    expect(find.text(en.vehErrBadImei), findsNothing);
    expect(api.posted.single['protocol'], 'h02');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a waiting tracker is no longer a dead tap — it reopens the SMS steps', (tester) async {
    _phone(tester, height: 3000);
    final api = _VehApi();
    api.trackers = [api.tracker()];
    await tester.pumpWidget(_app(const VehicleTrackingScreen(), api: api));
    await _settle(tester);
    expect(find.text(en.cvvVehPendingTap), findsOneWidget);
    await _tap(tester, find.text(en.cvvVehPendingTap));
    await _settle(tester, 20);
    expect(find.text(en.v100SetupWaiting), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('driver picked from My Circle fills name + number', (tester) async {
    _phone(tester);
    final api = _VehApi();
    await tester.pumpWidget(_app(const VehicleDriversScreen(), api: api));
    await _settle(tester);
    expect(find.text(en.cvvDriversEmptyBenefit), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('cv-empty-primary')));
    await _tap(tester, find.byKey(const ValueKey('veh-driver-circle')));
    await _tap(tester, find.text('Rafi'));
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields[0].controller!.text, 'Rafi');
    expect(fields[1].controller!.text, '01810000000');
  });

  // ------------------------------------------------------------ 200% / dark / bn
  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('new empty states at 200% — $lang ${dark ? 'dark' : 'light'}', (tester) async {
        _phone(tester, height: 800);
        final screens = <Widget>[
          WatchmanScreen(source: FakeWatchman('nocam'), guide: false),
          WatchmanViewersScreen(source: FakeWatchman('empty'), siteId: 1),
          WatchmanAlertsScreen(source: FakeWatchman('empty'), siteId: 1, owner: true, onSetup: () {}),
          GuardInboxScreen(source: FakeCctvx('empty'), cash: FakeCashGuard()),
          CashGuardScreen(source: FakeCashGuard('nocam'), siteId: 1, onAddCamera: () {}),
          const VehicleTrackingScreen(),
          const VehicleDriversScreen(),
          const MyVehiclesScreen(),
        ];
        for (final w in screens) {
          await tester.pumpWidget(_app(w, api: _VehApi(), lang: lang, scale: 2.0, dark: dark));
          await _settle(tester, 8);
          final err = tester.takeException();
          expect(err, isNull, reason: '${w.runtimeType} ($lang, 2.0x): $err');
        }
        // Bangla digits in the how-to numbering
        if (lang == 'bn') {
          await tester.pumpWidget(_app(const VehicleTrackingScreen(), api: _VehApi(), lang: 'bn'));
          await _settle(tester);
          expect(find.text('১'), findsWidgets);
          expect(find.text(bn.cvvVehStep1), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
