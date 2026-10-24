// at-falsealarm — the owner's own SIM was reported as a theft "SIM change"
// 2 s after switching Always-on protection on, and the alert came twice.
//   * SIM baseline rules (Dart mirror of SimBaseline.kt + the engine's
//     receiver/debounce pipeline): single + dual SIM;
//   * AlertPoller shows no local copy when FCM push works (push_ok);
//   * the "It was me" button shows only while frozen / a theft signal is
//     active, and it needs the Security PIN before calling the server;
//   * the protection screen asks the engine to be quiet (no snatch) while
//     visible, and turning protection on passes rebaseline: true.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/alerts_fg.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/always_on_protection_screen.dart';
import 'package:assisto/services/antitheft_logic.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/false_alarm_button.dart';

import 'fake_api.dart';

const _channel = MethodChannel('com.assisto/antitheft');

class _FrozenApi extends FakeApi {
  _FrozenApi() : super(mode: FakeMode.data, lang: 'en');
  final posted = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final r = await super.getJson(path);
    if (path == '/security/engine/state') {
      return {...r, 'frozen': true, 'theft_signal': true};
    }
    return r;
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    posted.add(path);
    if (path == '/security/engine/false-alarm') {
      return {'ok': true, 'cleared': 1, 'frozen': false, '_status': 200};
    }
    return super.postJsonRaw(path, body);
  }
}

class _EnableApi extends FakeApi {
  _EnableApi() : super(mode: FakeMode.empty, lang: 'en');

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path == '/security/engine/enable') {
      return {'ok': true, 'engine_token': 'tok', 'config': {}, '_status': 200};
    }
    return {'ok': false, '_status': 404};
  }
}

class _AlertsApi extends FakeApi {
  _AlertsApi() : super(mode: FakeMode.data, lang: 'en');
  @override
  Future<List<Map<String, dynamic>>> alertsList() async => [
        {'severity': 'high', 'text': 'SIM change on Arif\'s phone'},
        {'severity': 'low', 'text': 'fyi'},
      ];
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

Widget _app(FakeApi api, Widget home, {String lang = 'en'}) =>
    ChangeNotifierProvider<AppState>.value(
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
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _a = 's1:47001'; // owner's GP SIM (subId 1)
const _b = 's2:47003'; // owner's Banglalink SIM (subId 2)
const _thief = 's7:47002';

void main() {
  group('SIM baseline rules', () {
    test('slot identity: absent, transitional, API 29+, API 26-28', () {
      expect(SimBaselineRules.slotIdentity(1, [], null), '');
      expect(SimBaselineRules.slotIdentity(6, [1], '47001'), isNull); // NOT_READY
      expect(SimBaselineRules.slotIdentity(0, null, '47001'), isNull); // UNKNOWN
      expect(SimBaselineRules.slotIdentity(2, [1], '47001'), isNull); // PIN
      expect(SimBaselineRules.slotIdentity(5, [], '47001'), isNull); // no sub yet
      expect(SimBaselineRules.slotIdentity(5, [-1, 3], '47001'), 's3:47001');
      expect(SimBaselineRules.slotIdentity(10, [3], ''), 's3:?');
      expect(SimBaselineRules.slotIdentity(5, null, '47001'), 'op:47001');
      expect(SimBaselineRules.slotIdentity(5, null, ''), isNull);
      expect(SimBaselineRules.snapshot(['', _a]), {_a});
      expect(SimBaselineRules.snapshot([_a, null]), isNull);
      expect(SimBaselineRules.decode(SimBaselineRules.encode({_b, _a})),
          {_a, _b});
      expect(SimBaselineRules.decode(''), <String>{});
    });

    test('single SIM: same -> none, remove -> removed, reinsert own -> none, '
        'foreign -> inserted', () {
      final base = {_a};
      expect(SimBaselineRules.evaluate(base, base, {_a}), isNull);
      expect(SimBaselineRules.evaluate(base, base, <String>{}), 'removed');
      expect(SimBaselineRules.evaluate(base, <String>{}, {_a}), isNull);
      expect(SimBaselineRules.evaluate(base, <String>{}, {_thief}), 'inserted');
      // the same foreign SIM is reported once, not on every re-check
      expect(SimBaselineRules.evaluate(base, {_thief}, {_thief}), isNull);
    });

    test('dual SIM: same -> none, swap one -> inserted, remove one -> removed',
        () {
      final base = {_a, _b};
      expect(SimBaselineRules.evaluate(base, base, {_b, _a}), isNull);
      expect(SimBaselineRules.evaluate(base, base, {_a, _thief}), 'inserted');
      expect(SimBaselineRules.evaluate(base, base, {_a}), 'removed');
      expect(SimBaselineRules.evaluate(base, {_a}, {_a, _b}), isNull);
    });

    test('engine pipeline: arming is a silent baseline, sticky ignored', () {
      final e = SimEngineModel()..armRebaseline();
      e.onBroadcast(initialSticky: true); // the bug: current state at register
      e.debounceFired([_a]);
      expect(e.alerts, isEmpty);
      expect(e.base, _a);
      // a later sticky (service restart) is still ignored, nothing pending
      e.onBroadcast(initialSticky: true);
      e.debounceFired([_thief]);
      expect(e.alerts, isEmpty);
    });

    test('engine pipeline: NOT_READY -> READY -> LOADED debounced, no alert',
        () {
      final e = SimEngineModel()..armRebaseline();
      e.debounceFired([_a]);
      e.onBroadcast(); // NOT_READY
      e.onBroadcast(); // READY
      e.onBroadcast(); // LOADED
      e.debounceFired([null]); // still unreadable -> retried, never guessed
      e.debounceFired([_a]);
      expect(e.alerts, isEmpty);
    });

    test('engine pipeline: dual-SIM swap / remove / reinsert own', () {
      final e = SimEngineModel()..armRebaseline();
      e.debounceFired([_a, _b]);
      e.onBroadcast();
      e.debounceFired([_a, '']); // slot 2 pulled
      e.onBroadcast();
      e.debounceFired([_a, _b]); // owner puts it back
      e.onBroadcast();
      e.debounceFired([_a, _thief]); // a foreign SIM
      expect(e.alerts, ['removed', 'inserted']);
    });

    test('relaunch re-arm compares to the stored baseline (no re-baseline)',
        () {
      final e = SimEngineModel()..armRebaseline();
      e.debounceFired([_a]);
      e.serviceStart(); // app relaunched, same SIM
      e.debounceFired([_a]);
      expect(e.alerts, isEmpty);
      e.serviceStart(); // swapped while the engine was down
      e.debounceFired([_thief]);
      expect(e.alerts, ['inserted']);
      // switching protection on again re-baselines silently
      e.armRebaseline();
      e.debounceFired([_thief]);
      expect(e.alerts, ['inserted']);
    });

    test('reinstall (no baseline stored) records silently', () {
      final e = SimEngineModel()..serviceStart();
      e.debounceFired([_b]);
      expect(e.alerts, isEmpty);
      expect(e.base, _b);
    });
  });

  group('AlertPoller', () {
    late List<String> shown;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Settings.resetForTest();
      shown = [];
      AlertPoller.show = (id, t, b) async => shown.add(b);
    });

    test('push not working -> one local notification for a new high alert',
        () async {
      await AlertPoller.poll(_AlertsApi());
      expect(shown, ["SIM change on Arif's phone"]);
      await AlertPoller.poll(_AlertsApi()); // seen: never twice
      expect(shown.length, 1);
    });

    test('push_ok -> no local copy, but the seen-set is still updated',
        () async {
      await Settings.setBool(AlertPoller.pushOkKey, true);
      await AlertPoller.poll(_AlertsApi());
      expect(shown, isEmpty);
      expect(await Settings.getString('alert_seen'),
          "SIM change on Arif's phone");
      // push later breaks: the already-seen alert is still not repeated
      await Settings.setBool(AlertPoller.pushOkKey, false);
      await AlertPoller.poll(_AlertsApi());
      expect(shown, isEmpty);
    });
  });

  group('It was me button', () {
    test('shouldShow only for frozen / theft signal', () {
      expect(FalseAlarmButton.shouldShow({}), isFalse);
      expect(FalseAlarmButton.shouldShow({'frozen': false}), isFalse);
      expect(FalseAlarmButton.shouldShow({'frozen': true}), isTrue);
      expect(FalseAlarmButton.shouldShow({'theft_signal': true}), isTrue);
      final fut = DateTime.now().add(const Duration(hours: 3)).toIso8601String();
      final past =
          DateTime.now().subtract(const Duration(hours: 3)).toIso8601String();
      expect(FalseAlarmButton.shouldShow({'frozen_until': fut}), isTrue);
      expect(FalseAlarmButton.shouldShow({'frozen_until': past}), isFalse);
      expect(FalseAlarmButton.shouldShow({'frozen_until': null}), isFalse);
    });

    testWidgets('needs the PIN: cancelled PIN never calls the server',
        (tester) async {
      final sent = <String>[];
      var asked = 0;
      await tester.pumpWidget(_app(
          FakeApi(lang: 'en'),
          Scaffold(
            body: FalseAlarmButton(
              askPin: (_) async {
                asked++;
                return null;
              },
              send: (p) async {
                sent.add(p);
                return {'ok': true, 'cleared': 1, 'frozen': false};
              },
            ),
          )));
      await tester.tap(find.byKey(const Key('atfa-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('atfa-confirm')));
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(sent, isEmpty);
    });

    testWidgets('PIN given -> server called with it, host reloads',
        (tester) async {
      final sent = <String>[];
      var cleared = 0;
      await tester.pumpWidget(_app(
          FakeApi(lang: 'en'),
          Scaffold(
            body: FalseAlarmButton(
              askPin: (_) async => '2468',
              send: (p) async {
                sent.add(p);
                return {'ok': true, 'cleared': 1, 'frozen': false};
              },
              onCleared: () => cleared++,
            ),
          )));
      await tester.tap(find.byKey(const Key('atfa-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('atfa-confirm')));
      await tester.pumpAndSettle();
      expect(sent, ['2468']);
      expect(cleared, 1);
      final t = AppLocalizations.of(tester.element(find.byType(Scaffold)));
      expect(find.text(t.atfaCleared), findsOneWidget);
    });

    testWidgets('wrong PIN -> bad PIN message, no reload', (tester) async {
      var cleared = 0;
      await tester.pumpWidget(_app(
          FakeApi(lang: 'en'),
          Scaffold(
            body: FalseAlarmButton(
              askPin: (_) async => '0000',
              send: (p) async =>
                  {'ok': false, 'reason': 'bad_pin', '_status': 403},
              onCleared: () => cleared++,
            ),
          )));
      await tester.tap(find.byKey(const Key('atfa-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('atfa-confirm')));
      await tester.pumpAndSettle();
      expect(cleared, 0);
      final t = AppLocalizations.of(tester.element(find.byType(Scaffold)));
      expect(find.text(t.securityBadPin), findsOneWidget);
    });
  });

  group('Always-on protection screen', () {
    late List<MethodCall> calls;
    setUp(() {
      calls = [];
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'capabilities':
            return {'sdk': 33, 'brand': 'realme'};
          case 'isRunning':
            return true;
          default:
            return null;
        }
      });
    });
    tearDown(() {
      final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(_channel, null);
      m.setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/permissions/methods'), null);
    });

    testWidgets('quiet while visible, off on dispose; It-was-me when frozen',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(
          _app(_FrozenApi(), const AlwaysOnProtectionScreen()));
      await _settle(tester);
      expect(
          calls.where((c) => c.method == 'setQuiet').map((c) => c.arguments),
          [
            {'on': true}
          ]);
      expect(find.byKey(const Key('atfa-button')), findsOneWidget);
      await tester.pumpWidget(_app(_FrozenApi(), const SizedBox()));
      await _settle(tester);
      expect(calls.where((c) => c.method == 'setQuiet').last.arguments,
          {'on': false});
    });

    testWidgets('turning protection on passes rebaseline: true',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(_app(_EnableApi(), const AlwaysOnProtectionScreen()));
      await _settle(tester);
      final t = AppLocalizations.of(
          tester.element(find.byType(AlwaysOnProtectionScreen)));
      // the location-permission ask in _enable (permission_handler)
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('flutter.baseflow.com/permissions/methods'),
              (call) async => call.method == 'requestPermissions'
                  ? <int, int>{for (final p in (call.arguments as List)) p as int: 1}
                  : 1);
      await tester.tap(find.text(t.atTurnOn));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '2468');
      await tester.tap(find.text(t.securityContinue));
      await _settle(tester);
      final start = calls.where((c) => c.method == 'start').toList();
      expect(start, hasLength(1));
      expect((start.single.arguments as Map)['rebaseline'], isTrue);
      // the relaunch re-arm path (flush) never carries a rebaseline
      expect(calls.where((c) => c.method == 'flush').every(
          (c) => c.arguments == null), isTrue);
    });

    testWidgets('no It-was-me button when not frozen', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(_app(FakeApi(mode: FakeMode.data, lang: 'en'),
          const AlwaysOnProtectionScreen()));
      await _settle(tester);
      expect(find.byKey(const Key('atfa-button')), findsNothing);
    });

    testWidgets('pausing the app ends quiet, resuming restores it',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(_app(FakeApi(mode: FakeMode.data, lang: 'en'),
          const AlwaysOnProtectionScreen()));
      await _settle(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _settle(tester);
      expect(calls.where((c) => c.method == 'setQuiet').last.arguments,
          {'on': false});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(calls.where((c) => c.method == 'setQuiet').last.arguments,
          {'on': true});
    });
  });
}
