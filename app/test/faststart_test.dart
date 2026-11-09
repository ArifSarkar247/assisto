// faststart (owner 10 Nov 00:55, "open like WhatsApp"): guards that keep
// the cold start light, plus the on-phone picture cache and Low-data mode.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/calls/call_data_prefs.dart';
import 'package:assisto/perf/disk_image.dart';
import 'package:assisto/perf/low_data.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('cold-start guard (nothing heavy before the first frame)', () {
    test('main(): no heavy SDK / network / await before runApp', () {
      final s = _src('lib/main.dart');
      final start = s.indexOf('void main()');
      final end = s.indexOf('runApp(', start);
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final pre = s.substring(start, end);
      for (final banned in [
        'Firebase',
        'MobileAds',
        'AdsService.instance.start',
        'PushService.instance.start',
        'Notifications.init',
        'HomeWidgetService',
        'VaWake',
        'GoogleMap',
        'Onnx',
        'CrashBoot',
        'FeatureFlags.instance.refresh',
        'await ',
        'Future.delayed',
        'Future<void>.delayed',
      ]) {
        expect(pre.contains(banned), isFalse,
            reason: '"$banned" before runApp() delays the first frame');
      }
    });

    test('heavy inits stay deferred after the first frame', () {
      final s = _src('lib/main.dart');
      final post = s.indexOf('addPostFrameCallback((_) async {');
      expect(post, greaterThan(0));
      for (final deferred in [
        'Notifications.init',
        'PushService.instance.start',
        'HomeWidgetService.init',
        'CrashBoot.start',
      ]) {
        final i = s.indexOf(deferred);
        expect(i, greaterThan(post), reason: '$deferred must run after the first frame');
      }
      // the ads SDK waits for the launch to settle and never runs at launch
      final ads = _src('lib/ads/ads_service.dart');
      expect(ads.contains('Duration(seconds: 8)'), isTrue);
    });

    test('app-open ad: shown only when already loaded (no load-then-show)', () {
      final b = _src('lib/ads/admob_ads_bridge.dart');
      final i = b.indexOf('Future<bool> showAppOpen(');
      final j = b.indexOf('Future<bool> showInterstitial(');
      final body = b.substring(i, j);
      expect(body.contains('AppOpenAd.load'), isFalse,
          reason: 'showAppOpen must never wait for a network load');
      expect(body.contains('preloadAppOpen'), isTrue);
      expect(b.contains('appOpenMaxAge'), isTrue);
    });

    test('no artificial splash delay', () {
      final s = _src('lib/main.dart');
      expect(s.contains('FlutterNativeSplash.preserve'), isFalse);
    });
  });

  group('DiskImageCache', () {
    late Directory tmp;
    late int fetches;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fs_img');
      fetches = 0;
      DiskImageCache.resetForTest();
      LowDataMode.resetForTest();
      DiskImageCache.dirProvider = () async => tmp;
      DiskImageCache.fetch = (url) async {
        fetches++;
        return Uint8List.fromList([1, 2, 3, fetches]);
      };
    });
    tearDown(() async {
      DiskImageCache.resetForTest();
      LowDataMode.resetForTest();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('downloads once, then serves from the phone (works offline)', () async {
      const url = 'https://example.test/a.png';
      final a = await DiskImageCache.bytes(url);
      expect(fetches, 1);
      // let the background save finish
      await Future<void>.delayed(const Duration(milliseconds: 50));
      DiskImageCache.fetch = (_) async => throw const SocketException('offline');
      final b = await DiskImageCache.bytes(url);
      expect(b, a);
      expect(File('${tmp.path}/${DiskImageCache.fileName(url)}').existsSync(), isTrue);
    });

    test('Low-data mode: no new download for optional pictures', () async {
      LowDataMode.on.value = true;
      await expectLater(
          DiskImageCache.bytes('https://example.test/b.png'), throwsStateError);
      expect(fetches, 0);
      // a required picture still loads
      await DiskImageCache.bytes('https://example.test/c.png', optional: false);
      expect(fetches, 1);
    });

    test('prune keeps at most maxFiles pictures', () async {
      for (var i = 0; i < DiskImageCache.maxFiles + 5; i++) {
        File('${tmp.path}/$i.img').writeAsBytesSync([i % 250]);
      }
      await DiskImageCache.prune(tmp);
      final left = tmp.listSync().where((e) => e.path.endsWith('.img')).length;
      expect(left, DiskImageCache.maxFiles);
    });

    test('provider equality by url', () {
      expect(const DiskCachedImage('u'), const DiskCachedImage('u'));
      expect(const DiskCachedImage('u') == const DiskCachedImage('v'), isFalse);
    });
  });

  group('LowDataMode', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      LowDataMode.resetForTest();
    });

    test('off by default; the switch is stored and turns low-data calls on',
        () async {
      await LowDataMode.load();
      expect(LowDataMode.on.value, isFalse);
      await LowDataMode.set(true);
      expect(LowDataMode.on.value, isTrue);
      expect(await CallDataPrefs.lowData(), isTrue);
      LowDataMode.resetForTest();
      await LowDataMode.load();
      expect(LowDataMode.on.value, isTrue);
    });
  });
}
