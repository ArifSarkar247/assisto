// cctvescalate (owner CCTV order 3 Nov, C3-C6): the CCTV alarm call page and
// its routing from the call push, 999 (asks first, never automatic) + the
// police card, light / recorded-warning tiles with confirm-before-sound,
// the honest capability table, the warning recorder, guard settings
// (address + "then an Assisto call"), 200 % text in bn / en, light + dark.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/calls/call_launch.dart';
import 'package:assisto/cctvx/warn_recorder.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/watchman/cctv_alarm_call_screen.dart';
import 'package:assisto/screens/watchman/cctv_escalate.dart';
import 'package:assisto/screens/watchman/cctvx_actions.dart';
import 'package:assisto/screens/watchman/cctvx_guard_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cashguard_fakes.dart';
import 'cctvescalate_fakes.dart';
import 'cctvescalate_shots.dart';
import 'cctvx_fakes.dart';
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

void _phone(WidgetTester tester, {double height = 1600}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

class _FakeRecorder implements WarnRecorder {
  bool started = false;
  @override
  Future<bool> start() async => started = true;
  @override
  Future<String?> stop() async => '/tmp/warning.wav';
  @override
  Future<Uint8List?> read(String path) async => Uint8List.fromList(List.filled(44, 1));
}

late AppLocalizations en;
late AppLocalizations bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });

  group('alarm call (C3)', () {
    test('payload: a CCTV alarm ring is a call with an event id', () {
      final p = kFakeAlarmCall();
      expect(p.isCall, isTrue);
      expect(p.isCctvAlarmCall, isTrue);
      expect(p.cctvEventId, 201);
      final plain = PushPayload.fromData({'kind': 'call', 'call_id': '55'});
      expect(plain.isCctvAlarmCall, isFalse);
      final notCall = PushPayload.fromData({'kind': 'shop_alert', 'cctv_event_id': '3'});
      expect(notCall.cctvEventId, isNull);
    });

    testWidgets('call launch (tap AND Accept) opens the alarm page, never a voice line',
        (tester) async {
      _phone(tester);
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: _state(),
        child: MaterialApp(
          navigatorKey: key,
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const Scaffold(body: Text('home')),
        ),
      ));
      final raw = jsonEncode(kFakeAlarmCall('en').data);
      for (final a in [CallLaunch.actionAccept, CallLaunch.actionOpen]) {
        final l = CallLaunch.fromParts(a, raw)!;
        final r = CallLaunchRouter.instance.routeFor(l);
        expect(r.settings.name, CallLaunchRouter.ringRouteName);
        key.currentState!.push(r);
        await _settle(tester);
        expect(find.byType(CctvAlarmCallScreen), findsOneWidget);
        expect(find.text(en.cescCallOpen), findsOneWidget);
        expect(find.text('Rahim Store — Door'), findsOneWidget);
        key.currentState!.pop();
        await _settle(tester);
      }
    });

    testWidgets('open the alert -> the event id; not now -> just closes', (tester) async {
      _phone(tester);
      int? opened;
      await tester.pumpWidget(_app(CctvAlarmCallScreen(
          payload: kFakeAlarmCall('en'), onOpen: (_, id) => opened = id)));
      await _settle(tester);
      expect(find.text(en.cescCallKicker), findsOneWidget);
      expect(find.text(en.cescCallNoPhoto), findsOneWidget);
      expect(find.text(en.cescCallStopsNote), findsOneWidget);
      await tester.tap(find.text(en.cescCallOpen));
      await _settle(tester);
      expect(opened, 201);
      expect(tester.takeException(), isNull);
    });
  });

  group('999 + police card (C4)', () {
    testWidgets('asks first with the honest note, then the card', (tester) async {
      _phone(tester, height: 2000);
      await tester.pumpWidget(_app(Scaffold(
          body: AlertActionsSheet(
              source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(),
              escalate: FakeEscalate(), preview: escalateActions()))));
      await _settle(tester);
      expect(find.text(en.cesc999Tile), findsOneWidget);
      await tester.tap(find.text(en.cesc999Tile));
      await _settle(tester);
      expect(find.text(en.cescNoAutoPolice), findsOneWidget);
      expect(en.cescNoAutoPolice, contains('does not call the police'));
      await tester.tap(find.text(en.cxCancel));
      await _settle(tester);
      expect(find.text(en.cescCardTitle), findsNothing);     // cancelled: nothing
      await tester.tap(find.text(en.cesc999Tile));
      await _settle(tester);
      await tester.tap(find.text(en.cescOpenDialer));
      await _settle(tester, 20);
      expect(find.text(en.cescCardTitle), findsOneWidget);
      expect(find.textContaining('House 12, Road 3'), findsOneWidget);
      expect(find.text(en.cescCardShare), findsOneWidget);
      expect(find.text(en.cescShareWarn), findsOneWidget);
      expect(find.textContaining('theft'), findsNothing);
    });

    testWidgets('no address -> the honest how-to', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(Scaffold(
          body: PoliceCardSheet(
              source: FakeCctvx(), police: {...kFakePolice, 'address_missing': true})),
          lang: 'bn'));
      await _settle(tester);
      expect(find.text(bn.cescAddressMissing), findsOneWidget);
      expect(find.textContaining('০৩/১১/২০২৬'), findsOneWidget);
    });
  });

  group('deterrence (C5 / C6)', () {
    testWidgets('light: confirm first, then the call', (tester) async {
      _phone(tester, height: 2000);
      final esc = FakeEscalate();
      await tester.pumpWidget(_app(Scaffold(
          body: AlertActionsSheet(
              source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(),
              escalate: esc, preview: escalateActions()))));
      await _settle(tester);
      expect(find.text(en.cescLightSub('30')), findsOneWidget);
      expect(find.text(en.cescVoice), findsNothing);          // not on this camera
      await tester.tap(find.text(en.cescLight));
      await _settle(tester);
      expect(find.text(en.cescConfirmLight), findsOneWidget);
      await tester.tap(find.text(en.cxCancel));
      await _settle(tester);
      expect(esc.calls, isEmpty);
      await tester.tap(find.text(en.cescLight));
      await _settle(tester);
      await tester.tap(find.text(en.cescDoIt));
      await _settle(tester);
      expect(esc.calls, ['deter:201:light:11']);
      expect(find.text(en.cescLightOn), findsOneWidget);
    });

    testWidgets('voice on an EZVIZ camera with a recorded clip', (tester) async {
      _phone(tester, height: 2000);
      final esc = FakeEscalate(hasClip: true);
      await tester.pumpWidget(_app(Scaffold(
          body: AlertActionsSheet(
              source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(),
              escalate: esc, preview: escalateActions(deter: kFakeDeterEzviz)))));
      await _settle(tester);
      expect(find.text(en.cescLight), findsNothing);
      await tester.tap(find.text(en.cescVoice));
      await _settle(tester);
      expect(find.text(en.cescConfirmVoice), findsOneWidget);
      await tester.tap(find.text(en.cescDoIt));
      await _settle(tester);
      expect(esc.calls, ['deter:201:voice:12']);
    });

    testWidgets('capability table: honest rows incl. two-way talk', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(Scaffold(body: CapabilityTable(rows: deterRows(kFakeDeter, 'en')))));
      await _settle(tester);
      expect(find.text(en.cescFeatTalk), findsOneWidget);
      expect(find.textContaining('only inside their own app SDK'), findsOneWidget);
      expect(find.textContaining('not on this camera'), findsOneWidget);
      expect(find.text(en.cescFeatYes), findsNWidgets(2));
    });

    testWidgets('warning recorder: record, keep (uploads), honest privacy line', (tester) async {
      _phone(tester, height: 2000);
      final esc = FakeEscalate();
      final rec = _FakeRecorder();
      warnRecorderFactory = () => rec;
      warnMicGranted = () async => true;
      addTearDown(() {
        warnRecorderFactory = PluginWarnRecorder.new;
      });
      await tester.pumpWidget(_app(Scaffold(body: WarnClipSheet(source: esc, siteId: 1))));
      await _settle(tester);
      expect(find.text(en.cescWarnNone), findsOneWidget);
      expect(find.text(en.cescWarnPrivacy), findsOneWidget);
      await tester.tap(find.text(en.cescWarnRecord));
      await _settle(tester);
      expect(rec.started, isTrue);
      await tester.tap(find.text(en.cescWarnStop('0')));
      await _settle(tester);
      expect(find.text(en.cescWarnSave), findsOneWidget);
      await tester.tap(find.text(en.cescWarnSave));
      await _settle(tester);
      expect(esc.calls.last, 'save_clip:1:44');
      expect(find.textContaining('6'), findsWidgets);
    });
  });

  group('guard settings', () {
    testWidgets('address saved + the call switch with the chain', (tester) async {
      _phone(tester, height: 3200);
      final src = FakeCctvx();
      await tester.pumpWidget(_app(GuardSettingsScreen(source: src, siteId: 1)));
      await _settle(tester);
      expect(find.text(en.cescCallSwitch), findsOneWidget);
      await tester.tap(find.text(en.cescCallSwitch));
      await _settle(tester);
      expect(src.saved.last, {'escalate_call': false});
      await tester.enterText(find.byType(TextField).last, 'House 12, Road 3, Mirpur');
      await tester.tap(find.widgetWithText(FilledButton, en.cxSave).last);
      await _settle(tester);
      expect(src.saved.last, {'address': 'House 12, Road 3, Mirpur'});
      expect(find.text(en.cescAddressSaved), findsOneWidget);
    });
  });

  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('cctvescalate screens at 200% text — $lang ${dark ? 'dark' : 'light'}',
          (tester) async {
        _phone(tester, height: 800);
        for (final e in cctvescalateShots.entries) {
          await tester.pumpWidget(_app(e.value(lang), lang: lang, scale: 2.0, dark: dark));
          await _settle(tester, 8);
          final err = tester.takeException();
          expect(err, isNull, reason: '${e.key} ($lang, 2.0x): $err');
        }
      });
    }
  }
}
