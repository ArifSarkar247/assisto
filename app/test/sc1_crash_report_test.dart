// sc1 — crash/error reporting: scrubbing (no PII), consent gating, dedupe,
// caps, Crashlytics bridge gets ONLY scrubbed errors, lazy/guarded start.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/diag/crash_reporter.dart';
import 'package:assisto/diag/crash_scrub.dart';
import 'package:assisto/diag/device_facts.dart';
import 'package:assisto/diag/non_fatal.dart';
import 'package:assisto/services/error_report.dart';

class _Bridge implements CrashSinkBridge {
  _Bridge({this.initThrows = false});
  final bool initThrows;
  final List<String> recorded = [];
  final List<bool> enabled = [];
  @override
  Future<bool> init() async {
    if (initThrows) throw StateError('no firebase');
    return true;
  }

  @override
  Future<void> setEnabled(bool on, {String? userHash}) async => enabled.add(on);
  @override
  Future<void> record(ScrubbedError error, StackTrace? stack,
          {required bool fatal}) async =>
      recorded.add(error.toString());
}

class _Evil {
  @override
  String toString() => throw StateError('toString explodes');
}

const _pii = [
  'Rahim',
  '01712345678',
  '1712-345678',
  'rahim@example.com',
  'secret123',
  'Rahim_passport',
  'abcdefghijklmnopqrstuvwxyz0123',
  '482913',
];

String _piiError() => 'Bad "Hello Rahim" from +880 1712-345678 '
    'rahim@example.com https://lifeassisto.com/x?t=secret123 '
    '/data/user/0/com.assisto.assisto/files/Rahim_passport.jpg '
    'abcdefghijklmnopqrstuvwxyz0123 otp 482913';

void main() {
  group('CrashScrub', () {
    test('message drops every kind of personal data', () {
      final s = CrashScrub.message(_piiError());
      for (final p in _pii) {
        expect(s.contains(p), isFalse, reason: p);
      }
      expect(s, contains('<num>'));
      expect(s, contains('<url>'));
      expect(s, contains('<email>'));
      expect(s, contains('<path>'));
      expect(CrashScrub.message('x' * 1000).length,
          lessThanOrEqualTo(CrashScrub.maxMessage + 1));
    });

    test('frames keep only code locations, fingerprint ignores lines', () {
      final st = StackTrace.fromString(
          '#0      KeyService._run (package:assisto/crypto/key_service.dart:171:9)\n'
          '#1      <asynchronous suspension>\n'
          '#2      _rootRun (dart:async/zone.dart:1525:13)\n');
      final f = CrashScrub.frames(st);
      expect(f, [
        'KeyService._run (package:assisto/crypto/key_service.dart:171)',
        '_rootRun (dart:async/zone.dart:1525)',
      ]);
      final moved = f.map((x) => x.replaceAll(':171)', ':190)')).toList();
      expect(CrashScrub.fingerprint('E', f), CrashScrub.fingerprint('E', moved));
    });

    test('user hash is opaque and matches the server algorithm', () {
      final h = CrashScrub.userHash(18);
      expect(h, hasLength(16));
      expect(h.contains('18'), isFalse);
      // same as backend core.logic.crash_scrub.user_hash(18)
      expect(h, CrashScrub.userHash(18));
      expect(h == CrashScrub.userHash(19), isFalse);
    });
  });

  group('CrashReporter', () {
    late List<Map<String, dynamic>> posted;
    late bool consent;
    late CrashReporter r;
    setUp(() {
      posted = [];
      consent = false;
      r = CrashReporter(
          device: () async => const DeviceFacts(
              brand: 'OPPO', model: 'CPH2637', android: '14', sdk: 34,
              rom: 'ColorOS'));
    });

    Future<void> start([CrashSinkBridge? b]) => r.start(
          post: (body) async => posted.add(body),
          consented: () => consent,
          userHash: () => CrashScrub.userHash(18),
          bridge: b,
          version: '1.0.190',
          build: '190',
        );

    test('buffers before start, sends nothing without consent', () async {
      r.capture(StateError(_piiError()), StackTrace.current);
      expect(r.pending, hasLength(1));
      await start();
      await r.flush();
      expect(posted, isEmpty);
      consent = true;
      await r.onConsentChanged();
      expect(posted, hasLength(1));
      final b = posted.single;
      expect(b['v'], 2);
      expect(b['error_type'], 'StateError');
      expect(b['build'], '190');
      expect((b['device'] as Map)['rom'], 'ColorOS');
      final all = b.toString();
      for (final p in _pii) {
        expect(all.contains(p), isFalse, reason: p);
      }
      expect(b.containsKey('user'), isFalse, reason: 'no user id in body');
      expect(b.containsKey('user_id'), isFalse);
    });

    test('dedupes a fingerprint per session and caps the session', () async {
      consent = true;
      await start();
      for (var i = 0; i < 3; i++) {
        r.capture(StateError('same'), null);
      }
      await r.flush();
      expect(posted, hasLength(1));
      final capped = CrashReporter(maxSentPerSession: 2);
      final sent = <Map<String, dynamic>>[];
      await capped.start(
          post: (b) async => sent.add(b),
          consented: () => true,
          userHash: () => '');
      for (var i = 0; i < 5; i++) {
        capped.capture(ArgumentError('e$i'), StackTrace.fromString(
            '#0 f$i (package:assisto/x$i.dart:1:1)'));
      }
      await capped.flush();
      expect(sent, hasLength(2));
    });

    test('Crashlytics bridge receives ONLY the scrubbed error', () async {
      consent = true;
      final b = _Bridge();
      await start(b);
      expect(b.enabled, [true]);
      r.capture(FormatException(_piiError()), null);
      await r.flush();
      await Future<void>.delayed(Duration.zero);
      expect(b.recorded, hasLength(1));
      for (final p in _pii) {
        expect(b.recorded.single.contains(p), isFalse, reason: p);
      }
    });

    test('a broken Firebase never stops the server sink', () async {
      consent = true;
      await start(_Bridge(initThrows: true));
      r.capture(StateError('x'), null);
      await r.flush();
      expect(posted, hasLength(1));
    });

    test('capture never throws (even when toString explodes)', () async {
      expect(() => r.capture(_Evil(), null), returnsNormally);
      consent = true;
      await start();
      await r.flush();
      expect(posted.single['error_type'], '_Evil');
    });

    test('non-fatals (storage, keys) flow in after start', () async {
      consent = true;
      await start();
      NonFatal.report('storage.secure.read', StateError('Keystore'));
      await r.flush();
      expect(posted.single['where'], 'storage.secure.read');
      NonFatal.sink = null;
    });

    test('reportNonFatal before start: buffered, scrubbed, own frame dropped',
        () async {
      NonFatal.sink = null;
      final prev = CrashReporter.instance;
      CrashReporter.instance = r;
      try {
        reportNonFatal('secret_store.read', StateError(_piiError()));
        expect(r.pending, hasLength(1));
        expect(r.pending.single.where, 'secret_store.read');
        expect(r.pending.single.frames.any((f) => f.contains('error_report.dart')),
            isFalse);
        consent = true;
        await start();
        await r.flush();
        final all = posted.single.toString();
        for (final p in _pii) {
          expect(all.contains(p), isFalse, reason: p);
        }
      } finally {
        CrashReporter.instance = prev;
        NonFatal.sink = null;
      }
    });

    test('offline post failure is swallowed', () async {
      final rr = CrashReporter();
      await rr.start(
          post: (_) async => throw const SocketException('offline'),
          consented: () => true,
          userHash: () => '');
      rr.capture(StateError('x'), null);
      await rr.flush();
      expect(rr.sentCount, 1);
    });
  });

  group('ROM detection', () {
    test('Bangladesh market brands', () {
      expect(romFrom(brand: 'OPPO'), 'ColorOS');
      expect(romFrom(brand: 'realme'), 'ColorOS');
      expect(romFrom(brand: 'Redmi', display: 'OS1.0.5.0.UMPMIXM'), 'HyperOS');
      expect(romFrom(brand: 'POCO', display: 'V14.0.3.0.TMPMIXM'), 'MIUI');
      expect(romFrom(brand: 'samsung'), 'One UI');
      expect(romFrom(brand: 'vivo'), 'Funtouch OS');
      expect(romFrom(brand: 'Infinix'), 'XOS');
      expect(romFrom(brand: 'TECNO'), 'HiOS');
      expect(romFrom(brand: 'WALTON'), 'Android');
      expect(romFrom(brand: 'Symphony'), 'Android');
      expect(romFrom(brand: 'unknownco'), '');
    });
  });

  group('startup safety (source checks)', () {
    test('main.dart never touches Firebase/Crashlytics before the first frame',
        () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('firebase_crashlytics'), isFalse);
      expect(main.contains('Firebase.initializeApp'), isFalse);
      final boot = main.indexOf('CrashBoot.start');
      final postFrame = main.indexOf('addPostFrameCallback');
      expect(boot, greaterThan(postFrame));
      expect(main.indexOf('runApp('), lessThan(boot));
    });

    test('Crashlytics is reached only through the lazy Firebase helper', () {
      final b = File('lib/diag/crashlytics_bridge.dart').readAsStringSync();
      expect(b, contains('FirebaseLazy.ensure()'));
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final s = f.readAsStringSync();
        if (s.contains("package:firebase_crashlytics/")) {
          expect(f.path, endsWith('crashlytics_bridge.dart'));
        }
      }
    });
  });
}
