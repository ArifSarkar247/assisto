// at100 — remote switches, honest delivery, consent gating (Flutter side).
//   * pure rules mirrored from RemoteCommands.kt / views_at_remote.py
//   * RemoteSwitchesCard: offline truth, confirm-before-send, honest phase,
//     trusted contact gating, error + retry, cancel, Find Hub (no wipe)
//   * WatchedPhonesScreen empty / list; push route for trusted contacts
//   * IntruderConsentScreen: every disclosure item, agree / not now, 48 dp
//   * IntruderSnap: photo only when the server says so; PIN notice visible
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/intruder_consent_screen.dart';
import 'package:assisto/screens/watched_phones_screen.dart';
import 'package:assisto/services/antitheft_logic.dart';
import 'package:assisto/services/intruder_snap.dart';
import 'package:assisto/services/security_guard.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/remote_switches_card.dart';

import 'at100_fakes.dart';

Future<AppLocalizations> _pump(WidgetTester tester, Widget child,
    {String lang = 'en', bool dark = false}) async {
  await tester.binding.setSurfaceSize(const Size(400, 1600));
  await tester.pumpWidget(MaterialApp(
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
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byType(Scaffold).first));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('RemoteCommandRules (mirror of RemoteCommands.kt)', () {
    test('runs a known kind once', () {
      expect(RemoteCommandRules.shouldRun('alarm', 5, {}), isTrue);
      expect(RemoteCommandRules.shouldRun('alarm', 5, {5}), isFalse);
      expect(RemoteCommandRules.shouldRun('wipe', 6, {}), isFalse);
      expect(RemoteCommandRules.shouldRun('lock', 0, {}), isFalse);
    });
    test('alarm length is bounded', () {
      expect(RemoteCommandRules.alarmSeconds(0), 60);
      expect(RemoteCommandRules.alarmSeconds(30), 30);
      expect(RemoteCommandRules.alarmSeconds(999), 120);
    });
    test('dedupe ring keeps the last 30', () {
      final l = List<int>.generate(40, (i) => i + 1);
      final d = RemoteCommandRules.decodeDone(RemoteCommandRules.encodeDone(l));
      expect(d.length, 30);
      expect(d.first, 11);
      expect(RemoteCommandRules.decodeDone(''), isEmpty);
      expect(RemoteCommandRules.decodeDone('3,x,4'), [3, 4]);
    });
    test('a switch to an offline phone is never shown as sent', () {
      expect(RemoteCommandRules.phase('sent', phoneOnline: false),
          CmdPhase.waitingOffline);
      expect(RemoteCommandRules.phase('queued', phoneOnline: false),
          CmdPhase.waitingOffline);
      expect(RemoteCommandRules.phase('sent', phoneOnline: true), CmdPhase.sent);
      expect(RemoteCommandRules.phase('delivered', phoneOnline: false),
          CmdPhase.reached);
      expect(RemoteCommandRules.phase('done', phoneOnline: false), CmdPhase.done);
      expect(RemoteCommandRules.phase('expired', phoneOnline: true),
          CmdPhase.expired);
    });
    test('push wake-up follows the background-start rules', () {
      expect(RestartRules.canStart(RestartRules.push, 33, false), isTrue);
      expect(RestartRules.canStart(RestartRules.push, 34, false), isFalse);
      expect(RestartRules.canStart(RestartRules.push, 34, true), isTrue);
      expect(RestartRules.needsTapToResume(RestartRules.push, 34, false), isTrue);
      expect(RestartRules.allowCamera(RestartRules.push), isFalse);
    });
  });

  group('RemoteSwitchesCard', () {
    testWidgets('owner, phone offline: honest truth line + waiting phase',
        (tester) async {
      final t = await _pump(
          tester,
          RemoteSwitchesCard(
              load: () async => at100FakeCommands(bn: false, online: false)));
      expect(find.text(t.at100OfflineTruth), findsOneWidget);
      expect(find.byKey(const Key('at100-presence')), findsOneWidget);
      expect(find.textContaining(t.at100PhWaitingOffline), findsOneWidget);
      expect(find.textContaining(t.at100PhFailed(t.at100FailNoAdmin)),
          findsOneWidget);
      // no erase switch; Find Hub instead
      expect(find.byKey(const Key('at100-findhub')), findsOneWidget);
      expect(find.text(t.at100WipeBody), findsOneWidget);
    });

    testWidgets('alarm asks first, then sends; offline -> honest snack',
        (tester) async {
      final sent = <String>[];
      final t = await _pump(
          tester,
          RemoteSwitchesCard(
            load: () async => at100FakeCommands(bn: false, online: false, empty: true),
            send: (k, {message, contact}) async {
              sent.add(k);
              return {
                'ok': true,
                'command': at100Cmd(20, k, 'queued'),
                'phone': {'online': false}
              };
            },
          ));
      await tester.tap(find.byKey(const Key('at100-alarm')));
      await tester.pumpAndSettle();
      expect(find.text(t.at100AlarmConfirmTitle), findsOneWidget);
      expect(sent, isEmpty); // nothing sent before the confirm
      await tester.tap(find.byKey(const Key('at100-confirm')));
      await tester.pumpAndSettle();
      expect(sent, ['alarm']);
      expect(find.text(t.at100SentOffline), findsOneWidget);
    });

    testWidgets('lock-screen message needs text', (tester) async {
      final sent = <String>[];
      final t = await _pump(
          tester,
          RemoteSwitchesCard(
            load: () async => at100FakeCommands(bn: false, empty: true),
            send: (k, {message, contact}) async {
              sent.add('$k:$message:$contact');
              return {'ok': true, 'phone': {'online': true}};
            },
          ));
      await tester.tap(find.byKey(const Key('at100-message')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('at100-msg-send')));
      await tester.pumpAndSettle();
      expect(find.text(t.at100MsgNeeded), findsOneWidget);
      expect(sent, isEmpty);
      await tester.enterText(find.byKey(const Key('at100-msg')), 'Please call');
      await tester.enterText(find.byKey(const Key('at100-contact')), '01711');
      await tester.tap(find.byKey(const Key('at100-msg-send')));
      await tester.pumpAndSettle();
      expect(sent, ['message:Please call:01711']);
      expect(find.text(t.at100SentOnline), findsOneWidget);
    });

    testWidgets('trusted contact: only lost mode until the phone is active',
        (tester) async {
      final t = await _pump(
          tester,
          RemoteSwitchesCard(
              load: () async => at100FakeCommands(
                  bn: false, trusted: true, empty: true, active: false)));
      FilledButton b(String k) =>
          tester.widget<FilledButton>(find.byKey(Key('at100-$k')));
      expect(b('lost_mode').onPressed, isNotNull);
      expect(b('alarm').onPressed, isNull);
      expect(b('lock').onPressed, isNull);
      expect(find.text(t.at100NeedActive), findsOneWidget);
      expect(find.text(t.at100Subtitle('Arif')), findsOneWidget);
    });

    testWidgets('server refusals are explained', (tester) async {
      final t = await _pump(
          tester,
          RemoteSwitchesCard(
            load: () async => at100FakeCommands(bn: false, empty: true),
            send: (k, {message, contact}) async =>
                {'ok': false, 'reason': 'rate_limited', '_status': 429},
          ));
      await tester.tap(find.byKey(const Key('at100-lock')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('at100-confirm')));
      await tester.pumpAndSettle();
      expect(find.text(t.at100ErrRate), findsOneWidget);
    });

    testWidgets('load error -> retry', (tester) async {
      var n = 0;
      final t = await _pump(
          tester,
          RemoteSwitchesCard(load: () async {
            n++;
            if (n == 1) throw Exception('offline');
            return at100FakeCommands(bn: false, empty: true);
          }));
      expect(find.text(t.at100LoadFailed), findsOneWidget);
      await tester.tap(find.byKey(const Key('at100-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('at100-empty')), findsOneWidget);
    });

    testWidgets('a waiting switch can be cancelled', (tester) async {
      final cancelled = <int>[];
      await _pump(
          tester,
          RemoteSwitchesCard(
            load: () async => {
              ...at100FakeCommands(bn: false, online: false, empty: true),
              'commands': [at100Cmd(31, 'alarm', 'queued')],
            },
            cancel: (id) async {
              cancelled.add(id);
              return {'ok': true};
            },
          ));
      await tester.tap(find.byKey(const Key('at100-cancel-31')));
      await tester.pumpAndSettle();
      expect(cancelled, [31]);
    });

    testWidgets('bn + dark renders, buttons are 48 dp', (tester) async {
      final t = await _pump(
          tester, RemoteSwitchesCard(load: () async => at100FakeCommands(bn: true)),
          lang: 'bn', dark: true);
      expect(find.text(t.at100Title), findsOneWidget);
      for (final k in ['lost_mode', 'alarm', 'lock', 'message', 'alarm_stop']) {
        final sz = tester.getSize(find.byKey(Key('at100-$k')));
        expect(sz.height, greaterThanOrEqualTo(48), reason: k);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('WatchedPhonesScreen', () {
    testWidgets('empty state is honest', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: WatchedPhonesScreen(load: () async => {'watching': <Map>[]}),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('at100-watch-empty')), findsOneWidget);
    });

    testWidgets('list shows each phone with an honest status', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: WatchedPhonesScreen(
            load: () async => {'watching': at100FakeWatching(false)}),
      ));
      await tester.pumpAndSettle();
      final t = AppLocalizations.of(tester.element(find.byType(Scaffold).first));
      expect(find.byKey(const Key('at100-watch-7')), findsOneWidget);
      expect(find.byKey(const Key('at100-watch-9')), findsOneWidget);
      expect(find.textContaining(t.at100WatchLostBadge), findsOneWidget);
    });

    test('a trusted contact\'s alert opens the watched phones', () {
      final p = PushPayload.fromData(
          {'kind': 'family_alert', 'route': 'security/watch-phone'});
      expect(PushRouting.targetFor(p)!.chatNavRoute, 'watched_phones');
    });
  });

  group('intruder photo consent', () {
    testWidgets('consent screen states every item; agree / not now',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      bool? got;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
            builder: (ctx) => Scaffold(
                  body: TextButton(
                      onPressed: () async =>
                          got = await IntruderConsentScreen.ask(ctx),
                      child: const Text('go')),
                )),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      final t = AppLocalizations.of(
          tester.element(find.byType(IntruderConsentScreen)));
      for (final s in [
        t.at100IcWhat, t.at100IcWhen, t.at100IcNotice, t.at100IcWhere,
        t.at100IcWho, t.at100IcKeep, t.at100IcDelete, t.at100IcLaw,
      ]) {
        await tester.scrollUntilVisible(find.text(s), 120,
            scrollable: find.byType(Scrollable).first);
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(tester.getSize(find.byKey(const Key('at100-ic-agree'))).height,
          greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const Key('at100-ic-no')));
      await tester.pumpAndSettle();
      expect(got, isFalse);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('at100-ic-agree')));
      await tester.pumpAndSettle();
      expect(got, isTrue);
      expect(IntruderConsentScreen.consentVersion, 1); // == server version
    });

    test('a photo is taken only when the server says so', () async {
      var n = 0;
      IntruderSnap.snapOverride = () async {
        n++;
        return true;
      };
      expect(IntruderSnap.after({'ok': false, 'reason': 'bad_pin'}), isFalse);
      expect(IntruderSnap.after({'ok': false, 'intruder_snap': false}), isFalse);
      expect(IntruderSnap.after(null), isFalse);
      expect(IntruderSnap.after({'ok': false, 'intruder_snap': true}), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(n, 1);
      IntruderSnap.snapOverride = null;
    });

    testWidgets('the PIN box says so while the photo is on (never covert)',
        (tester) async {
      Future<void> open(bool armed) async {
        IntruderSnap.debugSetArmed(armed);
        await tester.pumpWidget(MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Builder(
              builder: (ctx) => Scaffold(
                    body: TextButton(
                        onPressed: () => const SecurityGuard()
                            .askPin(ctx, AppLocalizations.of(ctx)),
                        child: const Text('pin')),
                  )),
        ));
        await tester.tap(find.text('pin'));
        await tester.pumpAndSettle();
      }

      await open(false);
      expect(find.byKey(const Key('at100-pin-notice')), findsNothing);
      await open(true);
      expect(find.byKey(const Key('at100-pin-notice')), findsOneWidget);
      IntruderSnap.debugSetArmed(false);
    });
  });
}
