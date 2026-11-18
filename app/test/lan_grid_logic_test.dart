// cctv-accuracy: the Wi-Fi live grid rules (lan_grid_logic.dart) and the
// grid screen with a fake decoder (no camera): small tiles = sub stream,
// off-screen tiles = disconnected, one camera opened big = main stream.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/ipcam/ipcam_decoder.dart';
import 'package:assisto/ipcam/lan_grid_logic.dart';
import 'package:assisto/ipcam/lan_grid_screen.dart';
import 'package:assisto/ipcam/rtsp_client.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';

class _NoDecoder implements IpDecoder {
  @override
  Future<bool> available() async => true;
  @override
  Future<String?> open(String m, List<Uint8List> c) async => null;
  @override
  Future<bool> feed(Uint8List au, int ptsUs) async => true;
  @override
  Future<IpFrame?> grab({int gw = 160, int maxW = 640, int quality = 70, int timeoutMs = 3000}) async => null;
  @override
  Future<void> close() async {}
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
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
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    );

List<LanCam> _cams(int n) => [
      for (var i = 1; i <= n; i++)
        LanCam('Cam $i', 'rtsp://u:p@10.0.2.2:18554/cam${i}_sub', 'rtsp://u:p@10.0.2.2:18554/cam${i}_main')
    ];

Future<RtspSession> _unreachable(String url) async =>
    throw const RtspException(RtspFail.unreachable, 'test: no camera');

void main() {
  group('lan grid rules', () {
    test('a DVR config gives one camera per channel: sub stream for tiles, main for big', () {
      const c = LanGridConfig(brand: 'dahua', host: '192.168.1.64', user: 'admin', pass: 'p@ss', channels: 4);
      final cams = c.cams();
      expect(cams, hasLength(4));
      expect(cams[2].sub, contains('channel=3&subtype=1'));
      expect(cams[2].main, contains('channel=3&subtype=0'));
      expect(cams[0].singleStream, isFalse);
      const h = LanGridConfig(brand: 'hikvision', host: '10.0.0.9:8554', user: 'admin', pass: 'x', channels: 9);
      expect(h.cams()[8].sub, endsWith('/Streaming/Channels/902'));
      expect(h.cams()[8].main, endsWith('/Streaming/Channels/901'));
      expect(const LanGridConfig(brand: 'dahua', host: ' ').cams(), isEmpty);
    });

    test('pasted links: "main | sub" or one link (same stream), junk skipped, at most 16', () {
      final c = LanGridConfig(brand: 'rtsp', lines: [
        'rtsp://a:b@1.2.3.4/main | rtsp://a:b@1.2.3.4/sub',
        '',
        'not a link',
        'rtsp://a:b@1.2.3.5/only',
        for (var i = 0; i < 30; i++) 'rtsp://x:y@1.1.1.$i/s',
      ]);
      final cams = c.cams(name: (n) => 'C$n');
      expect(cams, hasLength(LanGridConfig.maxCams));
      expect(cams[0].sub, endsWith('/sub'));
      expect(cams[0].main, endsWith('/main'));
      expect(cams[1].singleStream, isTrue);
      expect(cams[1].name, 'C2');
    });

    test('config round-trips through storage JSON; bad JSON = ask again', () {
      const c = LanGridConfig(brand: 'imou', host: 'h', user: 'u', pass: 'p', channels: 8, lines: ['a']);
      final back = LanGridConfig.fromJson('{"v":1,"brand":"imou","host":"h","user":"u","pass":"p","channels":8,"lines":["a"]}')!;
      expect(back.toJson(), c.toJson());
      expect(LanGridConfig.fromJson('{"v":9}'), isNull);
      expect(LanGridConfig.fromJson('nope'), isNull);
      expect(LanGridConfig.fromJson(null), isNull);
    });

    test('visible share of a tile', () {
      expect(visibleFraction(top: 0, height: 100, viewTop: 0, viewHeight: 500), 1);
      expect(visibleFraction(top: 450, height: 100, viewTop: 0, viewHeight: 500), 0.5);
      expect(visibleFraction(top: 600, height: 100, viewTop: 0, viewHeight: 500), 0);
      expect(visibleFraction(top: 0, height: 100, viewTop: 150, viewHeight: 500), 0);
      expect(visibleFraction(top: 0, height: 0, viewTop: 0, viewHeight: 500), 0);
    });

    test('small visible tile = SUB; off screen / app in background = OFF; opened big or tablet = MAIN', () {
      expect(wantQuality(visibleFrac: 1, tileWidth: 170), GridQuality.sub);
      expect(wantQuality(visibleFrac: 0.05, tileWidth: 170), GridQuality.off);
      expect(wantQuality(visibleFrac: 1, tileWidth: 170, appActive: false), GridQuality.off);
      expect(wantQuality(visibleFrac: 0, tileWidth: 170, focused: true), GridQuality.main);
      expect(wantQuality(visibleFrac: 1, tileWidth: 700), GridQuality.main);
    });

    test('off-screen grace: a quick scroll past does not reconnect; 2 s away = cut', () {
      final g = OffGrace();
      final t0 = DateTime(2026, 11, 18, 10);
      expect(g.apply(GridQuality.off, GridQuality.sub, t0), GridQuality.sub);
      expect(g.apply(GridQuality.off, GridQuality.sub, t0.add(const Duration(seconds: 1))), GridQuality.sub);
      expect(g.apply(GridQuality.sub, GridQuality.sub, t0.add(const Duration(milliseconds: 1500))), GridQuality.sub);
      expect(g.apply(GridQuality.off, GridQuality.sub, t0.add(const Duration(seconds: 2))), GridQuality.sub,
          reason: 'the grace restarted when it came back');
      expect(g.apply(GridQuality.off, GridQuality.sub, t0.add(const Duration(seconds: 4))), GridQuality.off);
      expect(g.apply(GridQuality.off, GridQuality.off, t0.add(const Duration(seconds: 5))), GridQuality.off);
    });

    test('picture rate and size budget: 4-up 6 fps, 9-up 3 fps, big 10 fps; tile-sized pictures', () {
      expect(tileFps(GridQuality.sub, 4), 6);
      expect(tileFps(GridQuality.sub, 9), 3);
      expect(tileFps(GridQuality.main, 1), 10);
      expect(tileFps(GridQuality.off, 9), 0);
      expect(grabWidth(GridQuality.sub, 170, 2.0), 340);
      expect(grabWidth(GridQuality.sub, 500, 3.0), 640, reason: 'a small tile never asks more than 640');
      expect(grabWidth(GridQuality.main, 400, 3.5), 1280);
      expect(grabWidth(GridQuality.sub, 40, 1.0), 160);
      expect(grabWidth(GridQuality.sub, 171, 1.0) % 2, 0);
    });

    test('meter: fps and kilobytes a minute over the window', () {
      final m = TileMeter();
      final t0 = DateTime(2026, 11, 18, 10);
      for (var i = 0; i <= 30; i++) {
        final t = t0.add(Duration(milliseconds: 333 * i));
        m.frame(t);
        m.bytes(i * 10 * 1024, t); // 10 KB per picture
      }
      final now = t0.add(const Duration(seconds: 10));
      expect(m.fps(now), closeTo(3.0, 0.2));
      expect(m.kbPerMin(now), closeTo(10 * 3 * 60, 60));
      expect(TileMeter().kbPerMin(now), 0);
    });
  });

  group('lan grid screen (fake decoder, no camera)', () {
    void phone(WidgetTester tester, {double height = 800}) {
      tester.view.physicalSize = Size(360 * 2, height * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
    }

    Future<void> done(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }

    testWidgets('9 cameras in 2 columns: visible tiles on SUB, off-screen tiles cut after 2 s; 3x3 = all on SUB',
        (tester) async {
      phone(tester, height: 500);
      final key = GlobalKey<LanGridScreenState>();
      await tester.pumpWidget(_app(LanGridScreen(
          key: key, cams: _cams(9), cols: 2, decoderFor: (_) => _NoDecoder(), opener: _unreachable)));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 3));
      final tiles = tester.widgetList<LanTile>(find.byType(LanTile, skipOffstage: false)).toList();
      expect(tiles, isNotEmpty);
      // a 360 x 500 phone, 2 columns (a row = ~101 px): rows 1-4 show, camera 9's row does not
      final feeds = [for (final t in tiles) t.feed];
      expect(feeds.first.quality, GridQuality.sub);
      final st = key.currentState!;
      // the screen's own feeds (built tiles may be fewer than 9)
      final q = [for (var i = 0; i < 9; i++) st.debugQuality(i)];
      expect(q.where((x) => x == GridQuality.sub).length, inInclusiveRange(4, 8));
      expect(q.last, GridQuality.off, reason: 'camera 9 is below the screen: no data');
      // switch to 3 x 3: every tile fits -> all on the small stream
      await tester.tap(find.byKey(const ValueKey('lvg-cols')));
      await tester.pump(const Duration(seconds: 1));
      expect([for (var i = 0; i < 9; i++) st.debugQuality(i)], everyElement(GridQuality.sub));
      expect(find.text(AppLocalizations.of(st.context).lvgLost), findsWidgets,
          reason: 'no camera on this network: the honest "no picture" text');
      await done(tester);
    });

    testWidgets('app to background: every camera disconnected at once; back: reconnected', (tester) async {
      phone(tester);
      final key = GlobalKey<LanGridScreenState>();
      await tester.pumpWidget(_app(LanGridScreen(
          key: key, cams: _cams(4), decoderFor: (_) => _NoDecoder(), opener: _unreachable)));
      await tester.pump(const Duration(seconds: 1));
      final st = key.currentState!;
      expect([for (var i = 0; i < 4; i++) st.debugQuality(i)], everyElement(GridQuality.sub));
      st.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 100));
      expect([for (var i = 0; i < 4; i++) st.debugQuality(i)], everyElement(GridQuality.off));
      st.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 600));
      expect([for (var i = 0; i < 4; i++) st.debugQuality(i)], everyElement(GridQuality.sub));
      await done(tester);
    });

    testWidgets('tap a camera: it opens big on the MAIN stream and the grid tiles go off', (tester) async {
      phone(tester);
      final key = GlobalKey<LanGridScreenState>();
      await tester.pumpWidget(_app(LanGridScreen(
          key: key, cams: _cams(4), decoderFor: (_) => _NoDecoder(), opener: _unreachable)));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const ValueKey('lvg-tile-grid1')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      final big = tester.widget<LanBigView>(find.byType(LanBigView));
      expect(big.feed.quality, GridQuality.main);
      expect(big.feed.cam.name, 'Cam 2');
      final st = key.currentState!;
      expect([for (var i = 0; i < 4; i++) st.debugQuality(i)], everyElement(GridQuality.off));
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect([for (var i = 0; i < 4; i++) st.debugQuality(i)], everyElement(GridQuality.sub));
      await done(tester);
    });

    testWidgets('set-up form: needs an address; nothing typed = an honest message', (tester) async {
      phone(tester, height: 1400);
      await tester.pumpWidget(_app(const LanGridScreen()));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('lvg-host')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lvg-save')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(lookupAppLocalizations(const Locale('en')).lvgNeedAddress), findsOneWidget);
      await done(tester);
    });

    for (final dark in [false, true]) {
      for (final lang in ['en', 'bn']) {
        testWidgets('200% text, $lang, dark=$dark: form and 3x3 grid have no overflow', (tester) async {
          phone(tester);
          await tester.pumpWidget(_app(const LanGridScreen(), lang: lang, scale: 2.0, dark: dark));
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(_app(
              LanGridScreen(cams: _cams(9), cols: 3, decoderFor: (_) => _NoDecoder(), opener: _unreachable),
              lang: lang,
              scale: 2.0,
              dark: dark));
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull);
          await done(tester);
        });
      }
    }
  });
}
