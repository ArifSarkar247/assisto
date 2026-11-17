// gap-cctv: the CCTV feature-gap lane (owner gap sweep 17 Nov) — one test per
// fixed gap (owner_actions/gaps/cctv_BN.md).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/cctvconnect/cctv_connect_screen.dart';
import 'package:assisto/cctvguard/vendor_live_screen.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/media/video_ctl.dart';
import 'package:assisto/phonecam/phonecam_pair_sheet.dart';
import 'package:assisto/screens/watchman/cctv_act_tiles.dart';
import 'package:assisto/screens/watchman/cctv_escalate.dart';
import 'package:assisto/screens/watchman/cctvx_actions.dart';
import 'package:assisto/screens/watchman/cctv_watch_screen.dart';
import 'package:assisto/theme.dart';

import 'cctvact_fakes.dart' show FakeCctvAct;
import 'cctvconnect_fakes.dart' show FakeCctvConnect;
import 'cctvescalate_fakes.dart' show FakeEscalate;
import 'cctvx_fakes.dart' show FakeCctvx;
import 'cctvteam_fakes.dart' show FakeCctvTeam;
import 'cctvguard_fakes.dart' show FakeVendorLive, FakeNetCtl;
import 'phonecam_shots.dart' show pcFakePair;

class _FailFirstEscalate extends FakeEscalate {
  int n = 0;
  @override
  Future<Map<String, dynamic>> warnClip(int siteId) async {
    if (n++ == 0) throw StateError('offline');
    return super.warnClip(siteId);
  }
}

class _SlowEvidence extends FakeCctvx {
  final gate = Completer<void>();
  int asked = 0;
  @override
  Future<Map<String, dynamic>> evidence(int eventId) async {
    asked++;
    await gate.future;
    return {'created': '2026-11-17T10:00:00+06:00', 'facts': const {}};
  }
}

class _DelTeam extends FakeCctvTeam {
  _DelTeam([super.mode = 'data']);
  final deleted = <int>[];
  @override
  Future<void> watchDelete(int postId) async => deleted.add(postId);
}

/// start() waits until the test lets it answer.
class _SlowVendorLive extends FakeVendorLive {
  final gate = Completer<void>();
  @override
  Future<Map<String, dynamic>> start(int cameraId, {required bool hd}) async {
    await gate.future;
    return super.start(cameraId, hd: hd);
  }
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    MaterialApp(
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
    );

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 1600}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

late AppLocalizations en;
late AppLocalizations bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('G1 Guard Box on Linux / Raspberry Pi (Windows never required)', () {
    testWidgets('the pairing sheet offers the Linux box: install line + setup + copy',
        (tester) async {
      _phone(tester);
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
          (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      await tester.pumpWidget(
          _app(const Scaffold(body: PhoneCamPairSheet(load: pcFakePair))));
      await _settle(tester, 3);
      expect(find.text(en.gcvLinuxTitle), findsOneWidget);
      // folded by default: the pairing code stays the first thing seen
      expect(find.byKey(const Key('pcLinuxInstall')), findsNothing);
      await tester.ensureVisible(find.text(en.gcvLinuxTitle));
      await tester.tap(find.text(en.gcvLinuxTitle));
      await _settle(tester, 8);
      expect(find.byKey(const Key('pcLinuxInstall')), findsOneWidget);
      expect(find.byKey(const Key('pcLinuxSetup')), findsOneWidget);
      expect(find.text(kGuardBoxLinuxInstall), findsOneWidget);
      expect(kGuardBoxLinuxInstall, contains('releases/download/guardbox-linux/install.sh'));
      expect(kGuardBoxLinuxInstall, startsWith('curl -fsSL https://'));
      expect(find.textContaining(en.gcvLinuxStep4), findsOneWidget);
      final copy = find.byTooltip(en.gcvLinuxCopy);
      expect(copy, findsNWidgets(2));
      await tester.ensureVisible(copy.first);
      await tester.tap(copy.first);
      await _settle(tester, 3);
      expect(copied, [kGuardBoxLinuxInstall]);
      expect(find.text(en.gcvLinuxCopied), findsOneWidget);
      // every tap target is at least 48 dp
      for (final e in copy.evaluate()) {
        expect(tester.getSize(find.byWidget(e.widget)).height, greaterThanOrEqualTo(48));
      }
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('outside the pairing sheet the last step says where the code is', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
          const Scaffold(body: SingleChildScrollView(child: GuardBoxLinuxSteps(codeAbove: false))),
          lang: 'bn'));
      await tester.tap(find.text(bn.gcvLinuxTitle));
      await _settle(tester, 8);
      expect(find.textContaining(bn.gcvLinuxStep4Where), findsOneWidget);
      expect(find.textContaining('৪. '), findsOneWidget, reason: 'Bangla digits in Bangla');
    });

    test('the wizard no longer says the box must be a Windows PC', () {
      expect(en.gcvGwBoxBody, contains('Raspberry Pi'));
      expect(en.gcvGwBoxBody, contains('Windows is not required'));
      expect(bn.gcvGwBoxBody, contains('Windows বাধ্যতামূলক নয়'));
    });

    for (final lang in ['bn', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('Linux steps at 200% text, open — $lang ${dark ? 'dark' : 'light'}',
            (tester) async {
          _phone(tester, height: 900);
          await tester.pumpWidget(_app(
              const Scaffold(body: SingleChildScrollView(child: GuardBoxLinuxSteps())),
              lang: lang, scale: 2.0, dark: dark));
          final t = lang == 'bn' ? bn : en;
          await tester.tap(find.text(t.gcvLinuxTitle));
          await _settle(tester, 8);
          expect(tester.takeException(), isNull);
          unawaited(Future<void>.value());
        });
      }
    }
  });

  group('G5 live view never keeps streaming after the user leaves', () {
    testWidgets('back while "starting" ends the server session, no player', (tester) async {
      _phone(tester);
      var players = 0;
      final old = VideoCtls.networkFactory;
      VideoCtls.networkFactory = (_) async {
        players++;
        return FakeNetCtl();
      };
      addTearDown(() => VideoCtls.networkFactory = old);
      final api = _SlowVendorLive();
      await tester.pumpWidget(
          _app(VendorLiveScreen(cameraId: 7, cameraName: 'Gate', api: api)));
      await _settle(tester, 2);
      // the user backs out before the server answers
      await tester.pumpWidget(_app(const SizedBox()));
      api.gate.complete();
      await _settle(tester, 4);
      expect(api.calls.first, 'start:7:sd');
      expect(api.calls.where((c) => c.startsWith('end:')).length, 1,
          reason: 'the session is ended, so it never counts against the live limit');
      expect(players, 0, reason: 'no player (no mobile data) after leaving');
    });
  });

  group('G6 pairing sheet: honest offline + plain error text', () {
    testWidgets('offline after the code is shown: offline line + Retry, no endless spinner',
        (tester) async {
      _phone(tester);
      var n = 0;
      Future<Map<String, dynamic>> load() async {
        n++;
        if (n == 1) return pcFakePair();
        throw StateError('SocketException: Failed host lookup');
      }

      await tester.pumpWidget(_app(Scaffold(
          body: PhoneCamPairSheet(load: load, pollEvery: const Duration(milliseconds: 200)))));
      await _settle(tester, 3);
      expect(find.byKey(const Key('pcPairCode')), findsOneWidget);
      expect(find.text(en.pcWaiting), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 250));
      await _settle(tester, 3);
      expect(find.byKey(const Key('pcPairOffline')), findsOneWidget);
      expect(find.text(en.gcvPairOffline), findsOneWidget);
      expect(find.text(en.pcWaiting), findsNothing);
      expect(find.byKey(const Key('pcPairCode')), findsOneWidget, reason: 'the code stays');
      expect(find.textContaining('SocketException'), findsNothing);
    });

    testWidgets('a raw exception is never shown (Bangla screen)', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
          Scaffold(body: PhoneCamPairSheet(load: () async => throw StateError('SocketException: x'))),
          lang: 'bn'));
      await _settle(tester, 3);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(find.text(bn.wmLoadErrorBody), findsOneWidget);
      expect(find.text(bn.retry), findsOneWidget);
    });
  });

  group('G9 own-voice warning: never a dead end', () {
    Map<String, dynamic> act(String role, {bool hasWarn = false}) => {
          'site_id': 1, 'role': role, 'live': {'path': null},
          'play': [{'target': 'box', 'camera_id': null}], 'has_warn': hasWarn,
        };

    testWidgets('owner with no recording: the tile says so and opens the recorder',
        (tester) async {
      _phone(tester);
      final src = FakeCctvAct();
      await tester.pumpWidget(_app(Scaffold(
          body: SingleChildScrollView(
              child: ActTiles(
                  source: src, eventId: 201, act: act('owner'), escalate: FakeEscalate())))));
      await _settle(tester);
      expect(find.text(en.gcvWarnRecordFirst), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cv3-box-warn')));
      await _settle(tester);
      expect(find.text(en.cescWarnTitle), findsOneWidget);
      expect(src.calls.where((c) => c.startsWith('play')), isEmpty,
          reason: 'no "Play?" confirm that ends in "record first"');
    });

    testWidgets('a recorded warning still plays after Yes', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(Scaffold(
          body: SingleChildScrollView(
              child: ActTiles(
                  source: FakeCctvAct(),
                  eventId: 201,
                  act: act('owner', hasWarn: true),
                  escalate: FakeEscalate())))));
      await _settle(tester);
      expect(find.text(en.gcvWarnRecordFirst), findsNothing);
      expect(find.text(en.cv3BoxWarnSub), findsOneWidget);
    });

    testWidgets('warning sheet: load failure is an error with Retry, not "none recorded"',
        (tester) async {
      _phone(tester);
      final esc = _FailFirstEscalate();
      await tester.pumpWidget(
          _app(Scaffold(body: WarnClipSheet(source: esc, siteId: 1))));
      await _settle(tester);
      expect(find.byKey(const ValueKey('gcv-warn-load-failed')), findsOneWidget);
      expect(find.text(en.cescWarnNone), findsNothing);
      await tester.tap(find.text(en.wmRetry));
      await _settle(tester);
      expect(find.text(en.cescWarnNone), findsOneWidget);
    });

    testWidgets('deleting the warning asks first and reports the change', (tester) async {
      _phone(tester);
      final esc = FakeEscalate(hasClip: true);
      final seen = <bool>[];
      await tester.pumpWidget(_app(Scaffold(
          body: WarnClipSheet(source: esc, siteId: 1, onResult: seen.add))));
      await _settle(tester);
      await tester.ensureVisible(find.text(en.cescWarnDelete));
      await tester.tap(find.text(en.cescWarnDelete));
      await _settle(tester);
      expect(find.text(en.gcvWarnDeleteAsk), findsOneWidget);
      await tester.tap(find.text(en.wmCancel));
      await _settle(tester);
      expect(esc.calls.where((c) => c.startsWith('delete')), isEmpty);
      await tester.tap(find.text(en.cescWarnDelete));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('gcv-warn-del-yes')));
      await _settle(tester);
      expect(esc.calls.last, 'delete_clip:1');
      expect(seen, [false], reason: 'a swipe-down still tells the caller');
    });
  });

  group('G10 evidence pack: visible progress, one build at a time', () {
    testWidgets('progress shows while building; a second tap does nothing', (tester) async {
      _phone(tester);
      final src = _SlowEvidence();
      late BuildContext ctx;
      await tester.pumpWidget(_app(Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      }))));
      unawaited(exportEvidenceFlow(ctx, src, 201));
      await _settle(tester);
      await tester.tap(find.text(en.cxEvidenceMake));
      await _settle(tester);
      expect(find.byKey(const ValueKey('gcv-evidence-progress')), findsOneWidget);
      expect(find.text(en.gcvEvidenceMaking), findsOneWidget);
      await exportEvidenceFlow(ctx, src, 201); // the second tap
      await _settle(tester);
      expect(find.text(en.cxEvidenceMake), findsNothing, reason: 'no second confirm');
      src.gate.complete();
      await _settle(tester, 12);
      // no photo / clip here: the honest "nothing to pack" line, progress gone
      expect(find.byKey(const ValueKey('gcv-evidence-progress')), findsNothing);
      expect(find.text(en.cxEvidenceNothing), findsOneWidget);
      expect(src.asked, 1);
      expect(evidenceBuilding, isFalse);
    });
  });

  test('G13 clip expiry text never claims a fixed 24 hours (add-on keeps 7/30 days)', () {
    expect(en.gcvClipExpiredGone, isNot(contains('24')));
    expect(bn.gcvClipExpiredGone, isNot(contains('২৪')));
  });

  group('G14 neighbourhood watch: delete asks first, load error has Retry', () {
    testWidgets('delete my post: Cancel keeps it, Yes removes it', (tester) async {
      _phone(tester, height: 2000);
      final src = _DelTeam();
      await tester.pumpWidget(
          _app(CctvWatchGroupScreen(source: src, groupId: 21, name: 'Road 3 watch')));
      await _settle(tester);
      await tester.ensureVisible(find.text(en.ctmWatchDelete));
      await tester.tap(find.text(en.ctmWatchDelete));
      await _settle(tester);
      expect(find.text(en.gcvWatchDeleteAsk), findsOneWidget);
      await tester.tap(find.text(en.wmCancel));
      await _settle(tester);
      expect(src.deleted, isEmpty);
      await tester.tap(find.text(en.ctmWatchDelete));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('gcv-watch-del-yes')));
      await _settle(tester);
      expect(src.deleted, [32]);
    });

    testWidgets('a failed load offers Retry', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
          CctvWatchGroupScreen(source: _DelTeam('fail'), groupId: 21, name: 'Road 3 watch')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('gcv-watch-retry')), findsOneWidget);
    });
  });

  group('G16 brand-cloud screen on a phone-gateway place is never a dead end', () {
    testWidgets('says it cannot scan the Wi-Fi and shows the Guard Box way', (tester) async {
      _phone(tester, height: 2000);
      await tester.pumpWidget(_app(CctvConnectScreen(
          siteId: 1,
          source: FakeCctvConnect(noProviders: true, noLinks: true),
          lanGateway: false,
          onFindOnWifi: () {})));
      await _settle(tester);
      expect(find.byKey(const Key('ccnPhoneGwNote')), findsOneWidget);
      expect(find.text(en.gcvLinuxTitle), findsOneWidget);
    });

    testWidgets('a PC / Guard Box place keeps the plain Wi-Fi search', (tester) async {
      _phone(tester, height: 2000);
      await tester.pumpWidget(_app(CctvConnectScreen(
          siteId: 1,
          source: FakeCctvConnect(noProviders: true, noLinks: true),
          onFindOnWifi: () {})));
      await _settle(tester);
      expect(find.byKey(const Key('ccnPhoneGwNote')), findsNothing);
    });
  });
}
