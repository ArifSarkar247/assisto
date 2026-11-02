// cctvguard (owner CCTV order G): prefer P2P + LAN (relay candidates held),
// direct / relay path, the 5-minute idle stop, "this month's use" card and
// the Imou/EZVIZ cloud live screen (SD first, HD on tap, honest errors).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/cctvguard/cctv_usage_card.dart';
import 'package:assisto/cctvguard/live_cost.dart';
import 'package:assisto/cctvguard/vendor_live_screen.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/media/video_ctl.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/screens/watchman/watchman_screen.dart';
import 'package:assisto/theme.dart';

import 'cctv1_fakes.dart';
import 'cctvguard_fakes.dart';
import 'fake_api.dart';

Widget _withState(Widget child) {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(value: s, child: child);
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
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

const _relay = 'candidate:1 1 udp 41885439 203.0.113.9 50000 typ relay raddr 0.0.0.0 rport 0';
const _host = 'candidate:2 1 udp 2122260223 192.168.1.20 40000 typ host generation 0';
const _srflx = 'candidate:3 1 udp 1686052607 198.51.100.4 40001 typ srflx raddr 192.168.1.20';

void main() {
  group('LiveCost', () {
    test('relay candidate detection', () {
      expect(LiveCost.isRelayCandidate(_relay), isTrue);
      expect(LiveCost.isRelayCandidate(_host), isFalse);
      expect(LiveCost.isRelayCandidate(_srflx), isFalse);
      expect(LiveCost.isRelayCandidate(null), isFalse);
      expect(LiveCost.isRelayCandidate('typ relayx'), isFalse);
    });

    test('path of the selected pair', () {
      expect(LiveCost.pathOf('host', 'host'), LivePath.lan);
      expect(LiveCost.pathOf('srflx', 'host'), LivePath.direct);
      expect(LiveCost.pathOf('prflx', 'srflx'), LivePath.direct);
      expect(LiveCost.pathOf('host', 'relay'), LivePath.relay);
      expect(LiveCost.pathOf('relay', 'srflx'), LivePath.relay);
      expect(LiveCost.pathOf(null, null), LivePath.unknown);
      expect(LiveCost.parse('lan'), LivePath.lan);
      expect(LiveCost.parse('bogus'), LivePath.unknown);
      expect(LiveCost.mb(2600000), '2.6');
    });

    test('relay candidates are held; a direct path that connects first drops them', () async {
      final sent = <String>[];
      final h = RelayCandidateHold(
          send: (c) => sent.add(c['candidate'] as String), hold: const Duration(milliseconds: 30));
      h.offer({'candidate': _host});
      h.offer({'candidate': _relay});
      h.offer({'candidate': _srflx});
      expect(sent, [_host, _srflx]);
      expect(h.heldCount, 1);
      h.connected();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(sent, [_host, _srflx]); // relay never offered
      h.offer({'candidate': _relay});
      expect(sent.length, 2);
      h.dispose();
    });

    test('relay candidates still go out when nothing direct connects', () async {
      final sent = <String>[];
      final h = RelayCandidateHold(
          send: (c) => sent.add(c['candidate'] as String), hold: const Duration(milliseconds: 30));
      h.offer({'candidate': _relay});
      expect(sent, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sent, [_relay]);
      expect(h.released, isTrue);
      h.offer({'candidate': _relay}); // after release: straight through
      expect(sent.length, 2);
      h.dispose();
    });

    test('zero hold sends everything at once', () {
      final sent = <String>[];
      RelayCandidateHold(send: (c) => sent.add(c['candidate'] as String), hold: Duration.zero)
          .offer({'candidate': _relay});
      expect(sent, [_relay]);
    });

    test('vendor idle stop: 5 minutes, touch resets, touches throttled', () {
      final idle = VendorIdle();
      expect(idle.left, 300);
      for (var i = 0; i < 299; i++) {
        expect(idle.tick(), isFalse);
      }
      final now = DateTime(2026, 11, 3, 10);
      expect(idle.touch(now), isTrue);
      expect(idle.left, 300);
      expect(idle.touch(now.add(const Duration(seconds: 5))), isFalse); // throttled
      expect(idle.touch(now.add(const Duration(seconds: 20))), isTrue);
      for (var i = 0; i < 299; i++) {
        idle.tick();
      }
      expect(idle.tick(), isTrue);
    });
  });

  group('CctvUsageCard', () {
    testWidgets('bn: pool, notice, per-camera lines with Bangla digits', (tester) async {
      await tester.pumpWidget(_app(
          Scaffold(body: CctvUsageCard(load: () async => cgUsage(lang: 'bn'))),
          lang: 'bn'));
      await tester.pump();
      expect(find.text('এই মাসে ব্যবহার'), findsOneWidget);
      expect(find.textContaining('৬০০ MB-এর মধ্যে ৪৮২.৪ MB'), findsOneWidget);
      expect(find.textContaining('রিলের ৮০%'), findsOneWidget);
      expect(find.byKey(const Key('cctvUsageMsg')), findsOneWidget);
      // rows open on tap
      expect(find.textContaining('৪২ মিনিট লাইভ'), findsNothing);
      await tester.tap(find.byKey(const Key('cctvUsageRelay')));
      await tester.pump();
      expect(find.textContaining('৪২ মিনিট লাইভ · রিলে ৪১০.৫ MB · সরাসরি ১২৮০.০ MB'), findsOneWidget);
      expect(find.textContaining('ক্লাউড-লাইভ ১৫ মিনিট · আনুমানিক ৫৭.৬ MB'), findsOneWidget);
      expect(find.textContaining('কোনো সীমা নেই'), findsOneWidget);
    });

    testWidgets('not confirmed: only counted, no warning pill', (tester) async {
      await tester.pumpWidget(_app(Scaffold(
          body: CctvUsageCard(load: () async => cgUsage(enforced: false)))));
      await tester.pump();
      expect(find.textContaining('no limit switched on yet'), findsOneWidget);
      expect(find.textContaining('of relay used'), findsNothing);
    });

    testWidgets('hidden when it cannot load', (tester) async {
      await tester.pumpWidget(_app(Scaffold(
          body: CctvUsageCard(load: () async => throw ApiException('x', 500)))));
      await tester.pump();
      expect(find.byKey(const Key('cctvUsageCard')), findsNothing);
    });

    testWidgets('200% font + dark: no overflow', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 760 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
          Scaffold(body: ListView(children: [
            CctvUsageCard(initiallyOpen: true, load: () async => cgUsage(lang: 'bn')),
          ])),
          lang: 'bn', scale: 2.0, dark: true));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('VendorLiveScreen', () {
    late List<FakeNetCtl> ctls;
    setUp(() {
      ctls = [];
      VideoCtls.networkFactory = (_) async {
        final c = FakeNetCtl();
        ctls.add(c);
        return c;
      };
    });

    testWidgets('SD first, muted, HD on tap re-opens in HD', (tester) async {
      final api = FakeVendorLive();
      await tester.pumpWidget(_app(VendorLiveScreen(cameraId: 11, cameraName: 'Gate', api: api)));
      await tester.pump();
      await tester.pump();
      expect(api.calls.first, 'start:11:sd');
      expect(ctls.single.muted, isTrue);
      expect(find.text('SD (saves data)'), findsOneWidget);
      expect(find.text("Camera maker's cloud"), findsOneWidget);
      expect(find.textContaining('(estimate)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('vendorLiveHd')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(api.calls.where((c) => c.startsWith('end:v1')).length, 1);
      expect(api.calls.last, 'start:11:hd');
      expect(ctls.first.disposed, isTrue);
      expect(find.text('HD (more data)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('vendorLiveStop')));
      await tester.pump();
      await tester.pump();
    });

    testWidgets('stops after 5 minutes without a touch; a touch resets', (tester) async {
      final api = FakeVendorLive();
      await tester.pumpWidget(_app(VendorLiveScreen(cameraId: 11, cameraName: 'Gate', api: api)));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 200));
      await tester.tapAt(const Offset(200, 200));
      await tester.pump();
      expect(api.calls.where((c) => c.startsWith('touch:')).length, 1);
      await tester.pump(const Duration(seconds: 200));
      expect(find.byKey(const Key('vendorLiveStop')), findsOneWidget); // still live
      for (var i = 0; i < 110; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Live stopped because the screen was not touched for a while — this saves data. Watch again any time.'),
          findsOneWidget);
      expect(api.calls.any((c) => c.startsWith('end:v1:')), isTrue);
      expect(find.byKey(const Key('vendorLiveAgain')), findsOneWidget); // never a dead end
    });

    testWidgets('server refusal shown as-is with retry (bn)', (tester) async {
      final api = FakeVendorLive()
        ..failWith = ApiException('একসাথে ২ টির বেশি লাইভ দেখা যায় না। আগে অন্য লাইভটি বন্ধ করুন।', 429);
      await tester.pumpWidget(_app(VendorLiveScreen(cameraId: 11, cameraName: '', api: api), lang: 'bn'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('একসাথে ২ টির বেশি লাইভ'), findsOneWidget);
      expect(find.byKey(const Key('vendorLiveAgain')), findsOneWidget);
      expect(ctls, isEmpty);
    });

    testWidgets('a stream the phone cannot play is honest', (tester) async {
      VideoCtls.networkFactory = (_) async => FakeNetCtl(fail: 'codec');
      final api = FakeVendorLive();
      await tester.pumpWidget(_app(VendorLiveScreen(cameraId: 11, cameraName: 'Gate', api: api)));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining("could not play the camera's live video"), findsOneWidget);
      expect(api.calls.any((c) => c.startsWith('end:v1')), isTrue); // server session closed
    });
  });

  group('Watchman entry', () {
    testWidgets('linked Imou camera shows the cloud live button; usage card injected', (tester) async {
      final src = _LinkedWatchman();
      await tester.pumpWidget(_withState(_app(WatchmanScreen(
          source: src, guide: false, usageLoader: () async => cgUsage()))));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byKey(const ValueKey('wm-vlive-11')), findsWidgets);
      await tester.scrollUntilVisible(find.byKey(const Key('cctvUsageCard')), 200);
      expect(find.text("This month's use"), findsOneWidget);
    });

    testWidgets('unlinked camera: no live button; fake source never hits the network', (tester) async {
      await tester.pumpWidget(_withState(_app(WatchmanScreen(source: FakeWatchman('data'), guide: false))));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byKey(const ValueKey('wm-vlive-11')), findsNothing);
      expect(find.byKey(const Key('cctvUsageCard')), findsNothing);
    });
  });
}

class _LinkedWatchman extends FakeWatchman {
  _LinkedWatchman() : super('data');

  @override
  Future<Map<String, dynamic>> overview() async {
    final d = await super.overview();
    for (final s in (d['sites'] as List)) {
      for (final c in ((s as Map)['cameras_list'] as List)) {
        if ((c as Map)['vendor'] == 'imou') c['cloud_alarms'] = true;
      }
    }
    return d;
  }
}
