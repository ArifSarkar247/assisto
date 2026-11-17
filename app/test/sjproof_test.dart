// sjproof (Safe Journey V2 proof, owner order 9 Nov): bugs the emulator e2e
// found, pinned. The danger PIN typed in the "I've arrived" PIN box (server
// answer k=1) must look exactly like a normal arrival on this phone while the
// location keeps going to the watchers and 30 s of audio is recorded — before,
// that box stopped the location and recorded nothing. The safe PIN still ends
// tracking. Made-up places only.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/maps/address_resolver.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/safe_journey/sj_danger_audio.dart';
import 'package:assisto/services/journey_tracker.dart';
import 'package:assisto/services/oem_guide.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'sjduring_shots_test.dart' show SjdApi, sjdDuring, sjdTrip;

/// The server's /arrived answers, in order (PIN required first).
class _ArriveApi extends SjdApi {
  _ArriveApi(this.answers) : super('en');
  final List<Object> answers; // Map = 200 body, ApiException = refusal
  final arrivedBodies = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    if (path.endsWith('/arrived')) {
      arrivedBodies.add(body);
      final a = answers.removeAt(0);
      if (a is ApiException) throw a;
      return a as Map<String, dynamic>;
    }
    return super.postJson(path, body);
  }
}

class _Oem implements OemGuideNative {
  const _Oem();
  @override
  Future<OemInfo?> info() async => const OemInfo(
      manufacturer: 'google', brand: 'google', model: 'Pixel', batteryOptIgnored: true,
      bgRestricted: false);
  @override
  Future<OemOpen> available(String step) async => OemOpen.none;
  @override
  Future<OemOpen> open(String step) async => OemOpen.none;
}

/// The phone's GPS (the bus moves on between the last tracked fix and the tap).
double _gpsLat = 23.959;

ApiException _pinRequired() => ApiException('pin required', 400, null, null,
    {'ok': false, 'pin': 'required', 'arrival': 'unusual', 'reason': 'too_early'});

Future<(JourneyTracker, GlobalKey<NavigatorState>)> _pumpLive(WidgetTester t, SjdApi api) async {
  SharedPreferences.setMockInitialValues({});
  Settings.resetForTest();
  await t.binding.setSurfaceSize(const Size(400, 1600));
  addTearDown(() => t.binding.setSurfaceSize(null));
  AddressResolver.debugPhone = (lat, lng, l) async => 'Badda';
  addTearDown(() => AddressResolver.debugPhone = null);
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async => call.method == 'checkPermission' ? 2 : null);
  addTearDown(() => m.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'), null));
  final tr = JourneyTracker(
      useService: false, position: () async => (lat: _gpsLat, lng: 90.426), battery: () async => 64);
  final nav = GlobalKey<NavigatorState>();
  final app = AppState()
    ..api = api
    ..user = AppUser(id: 1, name: 'Me', phone: '01712345678', email: '', autonomyLevel: 2,
        language: 'en')
    ..locale = const Locale('en')
    ..loading = false;
  await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      navigatorKey: nav,
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: const Scaffold(body: SizedBox()),
    ),
  ));
  nav.currentState!.push(MaterialPageRoute(
      builder: (_) => JourneyLiveScreen(journeyId: 5, tracker: tr, oem: const _Oem())));
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return (tr, nav);
}

Future<void> _arriveWithPin(WidgetTester t, String pin) async {
  final btn = find.byKey(const ValueKey('j100_arrived'));
  await t.ensureVisible(btn);
  await t.tap(btn);
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  expect(find.byKey(const ValueKey('j100_pin_field')), findsOneWidget,
      reason: 'an impossible early arrival asks the PIN');
  await t.enterText(find.byKey(const ValueKey('j100_pin_field')), pin);
  await t.tap(find.byKey(const ValueKey('j100_pin_ok')));
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('danger PIN in the Arrived box: same Arrived, location goes on, clip recorded',
      (t) async {
    final clips = <int>[];
    sjRecordDangerClip = (api, id) async => clips.add(id);
    addTearDown(() => sjRecordDangerClip = (a, i) async {});
    final api = _ArriveApi([_pinRequired(), {'ok': true, 'status': 'arrived', 'k': 1}])
      ..active = sjdTrip('en')
      ..during = sjdDuring(state: 'nearly', dist: 90);
    final (tr, _) = await _pumpLive(t, api);
    expect(tr.running, isTrue);
    await _arriveWithPin(t, '1357');
    expect(api.arrivedBodies.last['pin'], '1357');
    expect(find.text(AppLocalizations.of(t.element(find.byType(Scaffold).first))
        .journeyArrivedSafely), findsWidgets);          // looks like a normal arrival
    expect(find.byType(JourneyLiveScreen), findsNothing);
    expect(clips, [5]);                                  // 30 s audio for the watchers
    expect(tr.running, isTrue);                          // the location goes on
    await tr.stop();
  });

  testWidgets('the Arrived tap carries a FRESH fix, not the last tracked one', (t) async {
    // bug found by the e2e: the tap sent the last tracked fix (up to 2 min /
    // ~2 km old on a bus) -> a real arrival looked "far" and asked the PIN
    _gpsLat = 23.78; // tracked at the start
    addTearDown(() => _gpsLat = 23.959);
    final api = _ArriveApi([{'ok': true, 'status': 'arrived'}])
      ..active = sjdTrip('en')
      ..during = sjdDuring(state: 'nearly', dist: 90);
    final (tr, _) = await _pumpLive(t, api);
    expect(tr.value.lastFix?.lat, 23.78);
    _gpsLat = 23.959; // now at the destination
    final btn = find.byKey(const ValueKey('j100_arrived'));
    await t.ensureVisible(btn);
    await t.tap(btn);
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(api.arrivedBodies.single['lat'], 23.959);
    expect(tr.running, isFalse);
  });

  testWidgets('safe PIN in the Arrived box: Arrived, tracking ends, no clip', (t) async {
    final clips = <int>[];
    sjRecordDangerClip = (api, id) async => clips.add(id);
    addTearDown(() => sjRecordDangerClip = (a, i) async {});
    final api = _ArriveApi([
      _pinRequired(),
      {'ok': true, 'status': 'arrived', 'arrival': 'confirmed_pin'},
    ])
      ..active = sjdTrip('en')
      ..during = sjdDuring(state: 'nearly', dist: 90);
    final (tr, _) = await _pumpLive(t, api);
    await _arriveWithPin(t, '2468');
    expect(clips, isEmpty);
    expect(tr.running, isFalse);
    expect(tr.value.status, 'arrived');
  });
}
