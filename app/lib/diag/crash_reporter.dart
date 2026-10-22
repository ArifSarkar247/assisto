import 'dart:async';

import 'package:flutter/foundation.dart';

import 'crash_scrub.dart';
import 'device_facts.dart';
import 'non_fatal.dart';

/// sc1 — crash + error reporting.
///
/// Two sinks, both fed ONLY scrubbed data (see [CrashScrub]):
///   1. Firebase Crashlytics ([CrashSinkBridge], lib/diag/crashlytics_bridge.dart)
///      — native crash capture + the Firebase console.
///   2. OUR server, POST /client/crash-report (structured v2 body) — what the
///      Owner Admin → Reports → App errors page shows (Crashlytics data cannot
///      be pulled into our panel without a BigQuery export).
///
/// Startup safety: [CrashReporter.capture] is a pure in-memory call that is
/// safe from the very first line of main(); errors before [start] are only
/// buffered. [start] runs after the first frame (main.dart), is guarded and
/// time-boxed, and touches Firebase only when not in safe mode.
///
/// Consent: nothing leaves the phone until [consented] says the user is
/// signed in and past onboarding (the privacy policy discloses crash
/// reports). Before that, buffered reports stay in memory and are dropped on
/// exit.
abstract class CrashSinkBridge {
  Future<bool> init();
  Future<void> setEnabled(bool on, {String? userHash});
  Future<void> record(ScrubbedError error, StackTrace? stack,
      {required bool fatal});
}

typedef CrashPost = Future<void> Function(Map<String, dynamic> body);

class CrashReport {
  CrashReport({
    required this.type,
    required this.message,
    required this.frames,
    required this.fatal,
    required this.where,
    this.stack,
  }) : fingerprint = CrashScrub.fingerprint(type, frames);

  final String type;
  final String message; // scrubbed
  final List<String> frames;
  final bool fatal;
  final String where;
  final String fingerprint;
  final StackTrace? stack;

  Map<String, dynamic> toJson() => {
        'error_type': type,
        'message': message,
        'frames': frames,
        'fatal': fatal,
        'where': where,
        'fingerprint': fingerprint,
      };

  static CrashReport from(Object error, StackTrace? stack,
      {bool fatal = false, String where = ''}) {
    final type = CrashScrub.errorType(error);
    var raw = '';
    try {
      raw = '$error';
    } catch (_) {}
    // drop a leading "Type: " so the message holds only the detail
    if (raw.startsWith('$type: ')) raw = raw.substring(type.length + 2);
    return CrashReport(
      type: type,
      message: CrashScrub.message(raw),
      frames: CrashScrub.frames(stack),
      fatal: fatal,
      where: where.length > 40 ? where.substring(0, 40) : where,
      stack: stack,
    );
  }
}

class CrashReporter {
  CrashReporter({
    this.maxBuffer = 20,
    this.maxSentPerSession = 25,
    Future<DeviceFacts> Function()? device,
  }) : _device = device ?? DeviceFacts.read;

  static CrashReporter instance = CrashReporter();

  final int maxBuffer;
  final int maxSentPerSession;
  final Future<DeviceFacts> Function() _device;

  CrashSinkBridge? _bridge;
  CrashPost? _post;
  bool Function() _consented = () => false;
  String Function() _userHash = () => '';
  String version = '';
  String build = '';

  final List<CrashReport> _buffer = [];
  final Set<String> _sentFingerprints = {};
  int _sent = 0;
  bool _started = false;
  bool _bridgeOn = false;
  bool _flushing = false;

  /// Reports waiting for consent / start (tests).
  List<CrashReport> get pending => List.unmodifiable(_buffer);
  int get sentCount => _sent;

  /// Record an error (non-fatal unless [fatal]). Safe anywhere, never throws,
  /// never blocks: work happens in [flush].
  void capture(Object error, StackTrace? stack,
      {bool fatal = false, String where = ''}) {
    try {
      final r = CrashReport.from(error, stack, fatal: fatal, where: where);
      // one copy of each fingerprint per session is enough
      if (_buffer.any((b) => b.fingerprint == r.fingerprint) ||
          _sentFingerprints.contains(r.fingerprint)) {
        return;
      }
      if (_buffer.length >= maxBuffer) _buffer.removeAt(0);
      _buffer.add(r);
      if (_started) unawaited(flush());
    } catch (_) {}
  }

  /// After the first frame. [post] sends one body to /client/crash-report;
  /// [consented] = signed in AND past onboarding; [userHash] = opaque id.
  Future<void> start({
    required CrashPost post,
    required bool Function() consented,
    required String Function() userHash,
    CrashSinkBridge? bridge,
    String version = '',
    String build = '',
  }) async {
    try {
      _post = post;
      _consented = consented;
      _userHash = userHash;
      this.version = version;
      this.build = build;
      _bridge = bridge;
      _started = true;
      // storage / key plumbing non-fatals land here from now on
      NonFatal.sink = (where, e, st) => capture(e, st, where: where);
      if (bridge != null) {
        try {
          _bridgeOn = await bridge.init().timeout(const Duration(seconds: 20));
        } catch (_) {
          _bridgeOn = false;
        }
      }
      await onConsentChanged();
    } catch (_) {}
  }

  bool _lastConsent = false;

  /// Call when sign-in / onboarding state may have changed.
  Future<void> onConsentChanged() async {
    try {
      final c = _consented();
      if (c != _lastConsent) {
        _lastConsent = c;
        if (_bridgeOn) {
          await _bridge!.setEnabled(c, userHash: c ? _userHash() : null);
        }
      }
      if (c) await flush();
    } catch (_) {}
  }

  /// Send buffered reports (when started + consented). Never throws.
  Future<void> flush() {
    // one flush at a time; a caller during a flush waits for that one
    return _flushRun ??= _flush().whenComplete(() => _flushRun = null);
  }

  Future<void>? _flushRun;

  Future<void> _flush() async {
    if (_flushing || !_started) return;
    final post = _post;
    if (post == null) return;
    bool ok;
    try {
      ok = _consented();
    } catch (_) {
      ok = false;
    }
    if (!ok) return;
    _flushing = true;
    try {
      DeviceFacts dev;
      try {
        dev = await _device();
      } catch (_) {
        dev = const DeviceFacts();
      }
      while (_buffer.isNotEmpty) {
        final r = _buffer.removeAt(0);
        if (_sent >= maxSentPerSession) {
          _buffer.clear();
          break;
        }
        if (!_sentFingerprints.add(r.fingerprint)) continue;
        _sent++;
        if (_bridgeOn) {
          unawaited(_bridge!
              .record(ScrubbedError(r.type, r.message), r.stack, fatal: r.fatal)
              .catchError((_) {}));
        }
        try {
          await post({
            'v': 2,
            ...r.toJson(),
            'version': version,
            'build': build,
            'device': dev.toJson(),
            'platform': defaultTargetPlatform.name,
          }).timeout(const Duration(seconds: 15));
        } catch (_) {
          // offline: not retried (the same error will happen again and be
          // reported next session) — never pile up work on a sick phone
        }
      }
    } finally {
      _flushing = false;
    }
  }
}
