// vehicle-e2e (18 Nov): app-side fixes found by the ST-906 emulator E2E.
//  * engine cut refused while MOVING -> the refusal is shown in full with the
//    server's safe option "Cut once it stops" (when_stopped); "Not now" sends
//    nothing more; a held cut shows "waiting for the vehicle to stop";
//  * an expired hold (never stopped) says so instead of a bare "expired";
//  * the route trail / trips refresh while the screen stays open (they were
//    loaded once, so a driving car's trail froze).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/vehicle_tracker_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

class _Api extends ApiClient {
  _Api() : super.detached('t');
  final List<Map<String, dynamic>> posted = [];
  int routeGets = 0;
  bool moving = true;
  List<Map<String, dynamic>> commands = [];

  Map<String, dynamic> tracker() => {
        'id': 7,
        'name': 'Dhaka Car',
        'protocol': 'h02',
        'state': 'paired',
        'online': true,
        'is_owner': true,
        'engine_cut_enabled': true,
        'relay_cut': false,
        'ignition': true,
        'access': {'view': true, 'command': true, 'manage': true},
        'last_seen_at': DateTime.now().toUtc().toIso8601String(),
        'live': {'lat': 23.7525, 'lng': 90.3815, 'speed_kmh': moving ? 42 : 0, 'course': 90,
                 'moving': moving, 'at': DateTime.now().toUtc().toIso8601String(), 'fix_age_s': 2},
        'settings': {'geofences': [], 'routes': [], 'speed_limit_kmh': 60,
                     'alert_prefs': {'silent_min': 30}},
      };

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/vehicle/config') return {'map': {}};
    if (path.contains('/route')) {
      routeGets++;
      return {'points': [], 'trips': [], 'stops': [], 'total_km': 0.0, 'moving_s': 0,
              'max_speed_kmh': 0};
    }
    if (path.endsWith('/commands')) return {'commands': commands};
    if (path.startsWith('/vehicle/trackers/7')) return tracker();
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posted.add({'path': path, ...body});
    if (path == '/vehicle/trackers/7/commands') {
      if (moving && body['when_stopped'] != true) {
        throw ApiException('moving', 409, null, 'moving',
            {'reason': 'moving', 'ok': false, 'max_speed_kmh': 5});
      }
      return {'ok': true, 'confirm_token': 'tok', 'wait_stop': body['when_stopped'] == true,
              'command': {'id': 31, 'kind': 'engine_cut', 'state': 'awaiting_confirm'}};
    }
    if (path == '/vehicle/commands/31/confirm') {
      final row = {'id': 31, 'kind': 'engine_cut', 'state': 'queued', 'wait_stop': true,
                   'hold_max_min': 30, 'held_reason': 'moving',
                   'created_at': DateTime.now().toUtc().toIso8601String()};
      commands = [row];
      return {'ok': true, 'command': row};
    }
    return {'ok': true};
  }
}

AppState _state(ApiClient api) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, ApiClient api) => ChangeNotifierProvider<AppState>.value(
      value: _state(api),
      child: MaterialApp(
        locale: const Locale('en'),
        theme: AssistoTheme.light,
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

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 3, 5000 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  late AppLocalizations en;
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  Future<void> waitFor(WidgetTester tester, Finder f, String what) async {
    for (var i = 0; i < 100 && f.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(f, findsWidgets, reason: what);
  }

  Future<void> askCut(WidgetTester tester) async {
    // no biometrics on the test "device": the Security PIN is the gate
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/local_auth'), (call) async => false);
    final cutBtn = find.byKey(const ValueKey('veh-cut'));
    await tester.ensureVisible(cutBtn);
    await tester.pump();
    await tester.tap(cutBtn);
    final dlgCut = find.descendant(of: find.byType(AlertDialog), matching: find.text(en.vehCutCta));
    await waitFor(tester, dlgCut, 'confirm dialog');
    await tester.tap(dlgCut);
    final pin = find.descendant(of: find.byType(AlertDialog), matching: find.byType(EditableText));
    await waitFor(tester, pin, 'Security PIN dialog');
    await tester.enterText(pin.first, '2468');
    await tester.pump();
    await tester.tap(find.text(en.securityContinue));
    await _settle(tester, 20);
  }

  testWidgets('moving: refused in full, "Not now" sends nothing more', (tester) async {
    _phone(tester);
    final api = _Api();
    await tester.pumpWidget(_app(const VehicleTrackerScreen(trackerId: 7), api));
    await _settle(tester, 12);
    await askCut(tester);
    await waitFor(tester, find.byKey(const ValueKey('veh-refused-moving')), 'refusal dialog');
    expect(find.text(en.vehErrMoving), findsOneWidget);
    expect(find.text(en.vehHoldTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('veh-hold-no')));
    await _settle(tester, 12);
    final sends = api.posted.where((p) => p['path'] == '/vehicle/trackers/7/commands').toList();
    expect(sends.length, 1);
    expect(sends.single.containsKey('when_stopped'), isFalse);
    expect(find.text(en.v100CutNotSent), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('moving: "Cut once it stops" holds the cut (when_stopped) and says so',
      (tester) async {
    _phone(tester);
    final api = _Api();
    await tester.pumpWidget(_app(const VehicleTrackerScreen(trackerId: 7), api));
    await _settle(tester, 12);
    await askCut(tester);
    await waitFor(tester, find.byKey(const ValueKey('veh-hold-yes')), 'hold offer');
    await tester.tap(find.byKey(const ValueKey('veh-hold-yes')));
    await _settle(tester, 12);
    final fin = find.byKey(const ValueKey('veh-cut-final'));
    await waitFor(tester, fin, 'final confirmation');
    await tester.tap(fin);
    await _settle(tester, 20);
    final sends = api.posted.where((p) => p['path'] == '/vehicle/trackers/7/commands').toList();
    expect(sends.length, 2);
    expect(sends.last['when_stopped'], isTrue);
    expect(api.posted.any((p) => p['path'] == '/vehicle/commands/31/confirm'), isTrue);
    expect(find.text(en.vehHoldQueued('30')), findsOneWidget);
    expect(find.textContaining(en.vehCmdStHeld('30')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an expired hold says the vehicle never stopped', (tester) async {
    _phone(tester);
    final api = _Api()
      ..moving = false
      ..commands = [
        {'id': 30, 'kind': 'engine_cut', 'state': 'expired', 'fail_reason': 'never_stopped',
         'created_at': DateTime.now().toUtc().toIso8601String()}
      ];
    await tester.pumpWidget(_app(const VehicleTrackerScreen(trackerId: 7), api));
    await _settle(tester, 12);
    expect(find.textContaining(en.vehCmdStNeverStopped), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the trail refreshes while the screen stays open and the car moves', (tester) async {
    _phone(tester);
    final api = _Api();
    await tester.pumpWidget(_app(const VehicleTrackerScreen(trackerId: 7), api));
    await _settle(tester, 12);
    expect(api.routeGets, 1);
    // first poll at 20 s (the screen opened with no data yet), then every
    // 8 s while moving; the 3rd poll refreshes the trail
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 9));
      await _settle(tester);
    }
    expect(api.routeGets, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
  });

  test('routeDue: on start / stop / ignition, every 3rd poll while moving', () {
    Map<String, dynamic> t(bool mv, {bool ign = true}) => {
          'ignition': ign,
          'live': {'moving': mv}
        };
    expect(vehRouteDue(null, t(true), 1), isTrue);
    expect(vehRouteDue(t(false), t(true), 1), isTrue);
    expect(vehRouteDue(t(true), t(false), 1), isTrue);
    expect(vehRouteDue(t(false), t(false, ign: false), 1), isTrue);
    expect(vehRouteDue(t(true), t(true), 1), isFalse);
    expect(vehRouteDue(t(true), t(true), 3), isTrue);
    expect(vehRouteDue(t(false), t(false), 3), isFalse);
  });
}
