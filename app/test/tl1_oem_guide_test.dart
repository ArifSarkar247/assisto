// tl1: OEM background guide (detection, steps, honest buttons, show-once
// gate, no clipped text at 360 px / text scale 1.3 + 2.0) and the Test Lab
// Robo targets (Semantics identifiers land on the actionable nodes).
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/battery_guidance_screen.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/language_picker_screen.dart';
import 'package:assisto/screens/login_screen.dart';
import 'package:assisto/services/oem_guide.dart';
import 'package:assisto/state.dart';

import 'fake_api.dart';
import 'fake_c3_msg.dart';
import 'tl1_fakes.dart';

late AppLocalizations en;
late AppLocalizations bn;

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(
      id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, Size size = const Size(360, 800)}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
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
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

SemanticsNode? _byIdentifier(WidgetTester tester, String id) {
  SemanticsNode? hit;
  bool visit(SemanticsNode n) {
    if (n.getSemanticsData().identifier == id) {
      hit = n;
      return false;
    }
    n.visitChildren(visit);
    return hit == null;
  }

  for (final v in tester.binding.renderViews) {
    final root = v.owner?.semanticsOwner?.rootSemanticsNode;
    if (root != null && hit == null) visit(root);
  }
  return hit;
}

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OemGuideGate.resetForTest();
  });

  group('detection + steps', () {
    test('Build.MANUFACTURER / BRAND map to the right family', () {
      expect(detectOemFamily('Xiaomi', 'Redmi'), OemFamily.xiaomi);
      expect(detectOemFamily('Xiaomi', 'POCO'), OemFamily.xiaomi);
      expect(detectOemFamily('realme', 'realme'), OemFamily.realme);
      expect(detectOemFamily('OPPO', 'OPPO'), OemFamily.oppo);
      expect(detectOemFamily('OnePlus', 'OnePlus'), OemFamily.oneplus);
      expect(detectOemFamily('vivo', 'iQOO'), OemFamily.vivo);
      expect(detectOemFamily('samsung', 'samsung'), OemFamily.samsung);
      expect(detectOemFamily('INFINIX MOBILITY LIMITED', 'Infinix'), OemFamily.transsion);
      expect(detectOemFamily('TECNO MOBILE LIMITED', 'TECNO'), OemFamily.transsion);
      expect(detectOemFamily('itel', 'itel'), OemFamily.transsion);
      expect(detectOemFamily('WALTON', 'Walton'), OemFamily.nearStock);
      expect(detectOemFamily('Symphony', 'Symphony'), OemFamily.nearStock);
      expect(detectOemFamily('Google', 'google'), OemFamily.nearStock);
    });

    test('steps per family; background-restricted adds its step first', () {
      expect(oemSteps(OemFamily.nearStock), [OemStepId.batteryOpt]);
      expect(oemSteps(OemFamily.samsung),
          [OemStepId.samsungUnrestricted, OemStepId.oemBattery]);
      expect(oemSteps(OemFamily.oppo).first, OemStepId.autostart);
      expect(oemSteps(OemFamily.xiaomi, bgRestricted: true).first, OemStepId.bgRestricted);
      expect(OemStepId.lockRecent.nativeStep, isNull); // by hand only
    });

    test('relevance: skip when every checkable step is satisfied', () {
      expect(oemGuideRelevant(tl1Phone('walton', ignored: true)), isFalse);
      expect(oemGuideRelevant(tl1Phone('walton', ignored: false)), isTrue);
      // can't tell (null) is never "done"
      expect(oemGuideRelevant(tl1Phone('walton', ignored: null)), isTrue);
      expect(oemGuideRelevant(tl1Phone('walton', ignored: true, restricted: true)), isTrue);
      // autostart can't be checked: always worth showing on OPPO / Xiaomi
      expect(oemGuideRelevant(tl1Phone('oppo', ignored: true)), isTrue);
      expect(oemGuideRelevant(tl1Phone('xiaomi', ignored: true)), isTrue);
    });

    test('device label', () {
      expect(tl1Phone('samsung').label, 'Samsung SM-A155F · Android 14 · One UI 6.1');
      expect(const OemInfo().label, '');
      final m = OemInfo.fromMap({'manufacturer': 'OPPO', 'model': 'X', 'sdkInt': 34,
          'batteryOptIgnored': true, 'bgRestricted': 'junk'});
      expect(m.batteryOptIgnored, isTrue);
      expect(m.bgRestricted, isNull);
    });
  });

  group('screen', () {
    testWidgets('OPPO: open buttons only where a screen resolves; result notes',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 2200));
      final fake = FakeOemNative(tl1Phone('oppo'), avail: tl1Avail('oppo'));
      await tester.pumpWidget(_app(BatteryGuidanceScreen(native: fake),
          size: const Size(360, 2200)));
      await _settle(tester);
      expect(find.text(en.oemGuideYourPhone('OPPO CPH2637 · Android 14 · ColorOS V14.0')),
          findsOneWidget);
      expect(find.text(en.oemStepAutostartOppo), findsOneWidget);
      expect(find.text(en.oemStepOemBatteryOppo), findsOneWidget);
      // autostart + battery list resolve to vendor/list screens -> "Open";
      // the ColorOS battery page only via App info -> "Open App info".
      expect(find.widgetWithText(FilledButton, en.open), findsNWidgets(2));
      expect(find.widgetWithText(FilledButton, en.oemGuideOpenAppInfo), findsOneWidget);
      // lock-in-recents is by hand: honest text, no button
      expect(find.text(en.oemGuideByHand), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, en.oemGuideOpenAppInfo));
      await _settle(tester);
      expect(fake.opened, ['oem_battery']);
      expect(find.text(en.oemGuideOpenedDetails), findsOneWidget);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('nothing resolves -> no dead button, honest by-hand text',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 2200));
      final fake = FakeOemNative(tl1Phone('xiaomi'), avail: const {});
      await tester.pumpWidget(_app(BatteryGuidanceScreen(native: fake),
          size: const Size(360, 2200)));
      await _settle(tester);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.text(en.oemGuideNoScreen), findsNWidgets(3));
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('Samsung with battery unrestricted: step shows Already done',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 1600));
      final fake = FakeOemNative(tl1Phone('samsung', ignored: true), avail: tl1Avail('samsung'));
      await tester.pumpWidget(_app(BatteryGuidanceScreen(native: fake),
          size: const Size(360, 1600)));
      await _settle(tester);
      expect(find.text(en.oemGuideDoneState), findsOneWidget);
      expect(find.text(en.oemStepSleepingTitle), findsOneWidget);
      expect(find.text(en.oemGuideCantCheck), findsOneWidget); // sleeping apps
      expect(find.widgetWithText(FilledButton, en.oemGuideOpenAppInfo), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('Walton all set; manual brand override switches the steps',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 1600));
      final fake = FakeOemNative(tl1Phone('walton', ignored: true), avail: tl1Avail('walton'));
      await tester.pumpWidget(_app(BatteryGuidanceScreen(native: fake),
          size: const Size(360, 1600)));
      await _settle(tester);
      expect(find.text(en.oemGuideAllSet), findsOneWidget);
      await tester.tap(find.text('vivo / iQOO'));
      await _settle(tester);
      expect(find.text(en.oemStepAutostartVivo), findsOneWidget);
      expect(find.text(en.oemGuideAllSet), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('re-checks on resume (back from Settings)', (tester) async {
      final fake = FakeOemNative(tl1Phone('walton', ignored: false), avail: tl1Avail('walton'));
      await tester.pumpWidget(_app(BatteryGuidanceScreen(native: fake)));
      await _settle(tester);
      expect(find.text(en.oemGuideDoneState), findsNothing);
      fake.infoValue = tl1Phone('walton', ignored: true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(find.text(en.oemGuideDoneState), findsOneWidget);
    });

    testWidgets('first run: Done / Later close it', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 2400));
      final fake = FakeOemNative(tl1Phone('vivo'), avail: tl1Avail('vivo'));
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => BatteryGuidanceScreen(firstRun: true, native: fake))),
                    child: const Text('go')),
              )), size: const Size(360, 2400)));
      await tester.tap(find.text('go'));
      await _settle(tester);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('oem-guide-later')), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const Key('oem-guide-later')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('oem-guide-later')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('oem-guide-later')));
      await tester.pumpAndSettle();
      expect(find.byType(BatteryGuidanceScreen), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    for (final lang in ['en', 'bn']) {
      for (final scale in [1.3, 2.0]) {
        for (final phone in ['oppo', 'xiaomi', 'samsung', 'vivo', 'infinix', 'walton']) {
          testWidgets('no overflow: $phone $lang x$scale at 360 px', (tester) async {
            await tester.binding.setSurfaceSize(const Size(360, 800));
            final fake = FakeOemNative(tl1Phone(phone), avail: tl1Avail(phone));
            await tester.pumpWidget(_app(BatteryGuidanceScreen(firstRun: true, native: fake),
                lang: lang, scale: scale));
            await _settle(tester);
            expect(tester.takeException(), isNull);
            // scroll to the bottom: every step + the buttons lay out cleanly
            await tester.scrollUntilVisible(find.byKey(const Key('oem-guide-done')), 300,
                scrollable: find.byType(Scrollable).first);
            await _settle(tester);
            expect(tester.takeException(), isNull);
            expect(find.byKey(const Key('oem-guide-done')), findsOneWidget);
            await tester.binding.setSurfaceSize(null);
          });
        }
      }
    }

    test('bn strings are really Bangla', () {
      expect(bn.oemGuideTitle, isNot(en.oemGuideTitle));
      expect(bn.oemGuideIntro, contains('ব্যাটারি'));
      expect(bn.oemStepLockBody, isNot(en.oemStepLockBody));
    });
  });

  group('show once after login', () {
    Future<void> host(WidgetTester tester) async {
      await tester.pumpWidget(_app(Builder(builder: (ctx) {
        OemGuideGate.schedule(ctx, () => const Text('GUIDE'));
        return const Scaffold(body: Text('ROOT'));
      })));
    }

    testWidgets('Android + relevant -> pushed once, flag saved', (tester) async {
      OemGuideGate.isAndroid = () => true;
      OemGuideGate.delay = const Duration(milliseconds: 10);
      final fake = FakeOemNative(tl1Phone('oppo'));
      OemGuideGate.native = fake;
      await host(tester);
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('GUIDE'), findsOneWidget);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool(OemGuideGate.prefKey), isTrue);
      // rebuilds never schedule again
      OemGuideGate.schedule(tester.element(find.text('GUIDE')), () => const Text('AGAIN'));
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('AGAIN'), findsNothing);
    });

    testWidgets('already seen -> nothing; native never asked', (tester) async {
      SharedPreferences.setMockInitialValues({OemGuideGate.prefKey: true});
      OemGuideGate.isAndroid = () => true;
      OemGuideGate.delay = const Duration(milliseconds: 10);
      final fake = FakeOemNative(tl1Phone('oppo'));
      OemGuideGate.native = fake;
      await host(tester);
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('GUIDE'), findsNothing);
      expect(fake.infoCalls, 0);
    });

    testWidgets('not relevant -> marked seen, not shown', (tester) async {
      OemGuideGate.isAndroid = () => true;
      OemGuideGate.delay = const Duration(milliseconds: 10);
      OemGuideGate.native = FakeOemNative(tl1Phone('walton', ignored: true));
      await host(tester);
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('GUIDE'), findsNothing);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool(OemGuideGate.prefKey), isTrue);
    });

    testWidgets('native unavailable -> not shown, retried next launch', (tester) async {
      OemGuideGate.isAndroid = () => true;
      OemGuideGate.delay = const Duration(milliseconds: 10);
      OemGuideGate.native = FakeOemNative(null);
      await host(tester);
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('GUIDE'), findsNothing);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool(OemGuideGate.prefKey), isNull);
    });

    testWidgets('another screen on top (e.g. a call) -> not shown, retried later',
        (tester) async {
      OemGuideGate.isAndroid = () => true;
      OemGuideGate.delay = const Duration(milliseconds: 10);
      OemGuideGate.native = FakeOemNative(tl1Phone('oppo'));
      await host(tester);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('CALL'))));
      await tester.pumpAndSettle();
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('GUIDE'), findsNothing);
      expect(find.text('CALL'), findsOneWidget);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool(OemGuideGate.prefKey), isNull);
    });

    testWidgets('not Android -> never', (tester) async {
      OemGuideGate.isAndroid = () => false;
      OemGuideGate.delay = const Duration(milliseconds: 10);
      final fake = FakeOemNative(tl1Phone('oppo'));
      OemGuideGate.native = fake;
      await host(tester);
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('GUIDE'), findsNothing);
      expect(fake.infoCalls, 0);
    });
  });

  group('Test Lab Robo targets (Semantics identifier = Android resource-id)', () {
    testWidgets('login fields + button carry their ids on actionable nodes',
        (tester) async {
      final h = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(400, 1000));
      await tester.pumpWidget(_app(const LoginScreen(), size: const Size(400, 1000)));
      await _settle(tester);
      final id = _byIdentifier(tester, 'tl_login_id');
      final pw = _byIdentifier(tester, 'tl_login_password');
      final go = _byIdentifier(tester, 'tl_login_submit');
      expect(id, isNotNull);
      expect(pw, isNotNull);
      expect(go, isNotNull);
      expect(id!.getSemanticsData().flagsCollection.isTextField, isTrue);
      // Flutter offers set-text only on a FOCUSED field, so the Robo script
      // clicks each field before typing into it.
      await tester.showKeyboard(find.byType(TextField).first);
      await _settle(tester);
      expect(_byIdentifier(tester, 'tl_login_id')!.getSemanticsData()
          .hasAction(SemanticsAction.setText), isTrue);
      expect(pw!.getSemanticsData().flagsCollection.isTextField, isTrue);
      expect(go!.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      await tester.binding.setSurfaceSize(null);
      h.dispose();
    });

    testWidgets('chat composer: input takes text, send + call are tappable',
        (tester) async {
      final h = tester.ensureSemantics();
      fakeC3On = true;
      C3Fake.seedRealtime();
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(_app(
          CircleChatScreen(member: C3Fake.member(false), identity: C3Fake.me),
          size: const Size(400, 800)));
      await _settle(tester);
      final input = _byIdentifier(tester, 'tl_chat_input');
      expect(input, isNotNull);
      expect(input!.getSemanticsData().flagsCollection.isTextField, isTrue);
      await tester.showKeyboard(find.byType(TextField).last);
      await _settle(tester);
      expect(_byIdentifier(tester, 'tl_chat_input')!.getSemanticsData()
          .hasAction(SemanticsAction.setText), isTrue);
      // wa-polish2: an empty box shows the Mic (hold to record); Send comes
      // with text — the Robo script types its message before tapping Send.
      await tester.enterText(find.byType(TextField).last, 'robo');
      await _settle(tester);
      for (final k in ['tl_chat_send', 'tl_chat_voice_call']) {
        final n = _byIdentifier(tester, k);
        expect(n, isNotNull, reason: k);
        expect(n!.getSemanticsData().hasAction(SemanticsAction.tap), isTrue, reason: k);
      }
      fakeC3On = false;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await tester.binding.setSurfaceSize(null);
      h.dispose();
    });

    testWidgets('language picker ids are tappable', (tester) async {
      final h = tester.ensureSemantics();
      await tester.pumpWidget(_app(const LanguagePickerScreen()));
      await _settle(tester);
      for (final k in ['tl_lang_en', 'tl_lang_bn', 'tl_lang_continue']) {
        final n = _byIdentifier(tester, k);
        expect(n, isNotNull, reason: k);
        expect(n!.getSemanticsData().hasAction(SemanticsAction.tap), isTrue, reason: k);
      }
      h.dispose();
    });
  });
}
