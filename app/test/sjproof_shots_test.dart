// sjproof: the Safe Journey V2 states the gallery did not have yet (bn/en x
// light/dark + Bangla 200% text): the traveller's live screen while Moving /
// Stopped (minutes) / Off route, and the destination alarm RINGING (loud,
// "I'm awake"). Writes PNGs to $ASSISTO_SHOT_DIR only when set; otherwise
// renders every state (no exception, no overflow). Made-up places only.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/maps/address_resolver.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/train/dest_alarm_screen.dart';
import 'package:assisto/services/journey_tracker.dart';
import 'package:assisto/services/oem_guide.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/train/dest_alarm_math.dart';
import 'package:assisto/train/dest_alarm_service.dart';
import 'package:assisto/train/dest_alarm_sound.dart';

import 'app_fonts.dart';
import 'sjduring_shots_test.dart' show SjdApi, sjdDuring, sjdTrip;

final _out = Platform.environment['ASSISTO_SHOT_DIR'];

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

class _Quiet implements DestAlarmSound {
  @override
  Future<bool> start({required bool sound, required bool vibrate}) async => true;
  @override
  Future<bool> speak(String text, String lang) async => true;
  @override
  Future<bool> playClip(String path) async => true;
  @override
  Future<bool> vibrateOnce() async => true;
  @override
  Future<void> stop() async {}
}

JourneyTracker? _tracker;
DestAlarmController? _alarm;

Widget _live() {
  _tracker = JourneyTracker(
      useService: false, position: () async => (lat: 23.80, lng: 90.42), battery: () async => 64);
  return JourneyLiveScreen(journeyId: 5, tracker: _tracker, oem: const _Oem());
}

Widget _ringing(String lang) {
  final bn = lang == 'bn';
  final c = DestAlarmController(
      position: () async => const DestFix(23.8950, 90.4100, accuracy: 10),
      battery: () async => 70,
      sound: _Quiet(),
      useService: false);
  _alarm = c;
  DestAlarmController.I = c;
  unawaited(c.start(
      DestPlan(
          mode: TransportMode.longBus,
          target: DestTarget(bn ? 'চন্দ্রা' : 'Chandra', 23.9000, 90.4100),
          setM: 2000),
      DestAlarmTexts(
          distance: (m) => '${(m / 1000).toStringAsFixed(1)} km',
          notifTitle: 'Alarm',
          notifText: '',
          stop: 'Stop',
          lang: lang,
          spoken: (s, d) => s,
          ready: (s, d) => s)));
  return const DestAlarmScreen();
}

typedef _Spec = ({SjdApi Function(String l) api, Widget Function(String l) screen, bool pushed, Size size});

final Map<String, _Spec> _specs = {
  'sjp_live_moving': (
    api: (l) => SjdApi(l)
      ..active = sjdTrip(l)
      ..during = sjdDuring(state: 'moving', dist: 12400),
    screen: (_) => _live(),
    pushed: true,
    size: const Size(360, 1500)
  ),
  'sjp_live_stopped': (
    api: (l) => SjdApi(l)
      ..active = sjdTrip(l)
      ..during = sjdDuring(state: 'stopped', dist: 9100),
    screen: (_) => _live(),
    pushed: true,
    size: const Size(360, 1500)
  ),
  'sjp_live_off_route': (
    api: (l) => SjdApi(l)
      ..active = sjdTrip(l)
      ..during = sjdDuring(state: 'off_route', dist: 7300),
    screen: (_) => _live(),
    pushed: true,
    size: const Size(360, 1500)
  ),
  'sjp_alarm_ringing': (
    api: (l) => SjdApi(l),
    screen: _ringing,
    pushed: false,
    size: const Size(360, 1100)
  ),
};

Future<void> _shoot(WidgetTester tester, String name, _Spec spec, String lang, Brightness b,
    double scale) async {
  SharedPreferences.setMockInitialValues({});
  Settings.resetForTest();
  DestAlarmScreen.debugStations = const [];
  DestAlarmScreen.debugBusStops = const [];
  DestAlarmScreen.debugMetro = const [];
  final keepAlarm = DestAlarmController.I;
  addTearDown(() {
    DestAlarmScreen.debugStations = null;
    DestAlarmScreen.debugBusStops = null;
    DestAlarmScreen.debugMetro = null;
    DestAlarmController.I = keepAlarm;
  });
  AddressResolver.debugPhone = (lat, lng, l) async => l == 'bn' ? 'বাড্ডা' : 'Badda';
  addTearDown(() => AddressResolver.debugPhone = null);
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async => call.method == 'checkPermission' ? 2 : null);
  addTearDown(() => m.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'), null));
  await tester.binding.setSurfaceSize(spec.size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final nav = GlobalKey<NavigatorState>();
  final key = GlobalKey();
  final app = AppState()
    ..api = spec.api(lang)
    ..user = AppUser(
        id: 1, name: 'Me', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: RepaintBoundary(
      key: key,
      child: MaterialApp(
        navigatorKey: nav,
        debugShowCheckedModeBanner: false,
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        darkTheme: AssistoTheme.dark,
        themeMode: b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
        builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: spec.pushed ? const Scaffold(body: SizedBox()) : spec.screen(lang),
      ),
    ),
  ));
  if (spec.pushed) {
    unawaited(nav.currentState!.push(MaterialPageRoute(builder: (_) => spec.screen(lang))));
  }
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  final err = tester.takeException();
  if (name == 'sjp_alarm_ringing') {
    expect(_alarm?.value.phase, DestAlarmPhase.ringing, reason: 'the alarm must be ringing');
  }
  if (_out != null) {
    final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await tester.runAsync(() => rb.toImage(pixelRatio: 2)) as ui.Image;
    final bytes = await tester.runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
    Directory(_out!).createSync(recursive: true);
    final tag = scale > 1 ? '_x2' : '';
    File('$_out/${name}_${lang}_${b.name}$tag.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    img.dispose();
  }
  await _tracker?.stop();
  _tracker = null;
  await _alarm?.stop();
  _alarm = null;
  await tester.pumpWidget(const SizedBox());
  expect(err, isNull);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await loadAppFonts();
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final l = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.view(b.buffer)));
      await l.load();
    }
  });
  for (final e in _specs.entries) {
    for (final lang in ['bn', 'en']) {
      for (final b in [Brightness.light, Brightness.dark]) {
        testWidgets('shot ${e.key} $lang ${b.name}',
            (tester) => _shoot(tester, e.key, e.value, lang, b, 1.0));
      }
    }
    testWidgets('shot ${e.key} bn light 200% text',
        (tester) => _shoot(tester, e.key, e.value, 'bn', Brightness.light, 2.0));
  }
}
