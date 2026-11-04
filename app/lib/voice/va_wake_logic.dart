// k1-wake — pure-Dart logic for "Hey Assisto" (no Flutter, no plugins), so it
// is unit-testable and mirrors the native/CI code exactly:
//  * [WakeDecider]   = OwwEngine.kt WakeDecider = tools/wakeword/ww/detector.py
//  * [WakeLevel]     sensitivity Low / Normal / High -> threshold + patience
//  * [WakeStatus]    parse of the native wakeStatus map
//  * [VaWakeGate]    may the switch turn on? (model + engine + disclosure)
//  * [VaLockPolicy]  which voice actions may run on a LOCKED phone
//
// LANGUAGE GATE: Bangla keywords below are \u escapes (input vocabulary only).

import 'voice_intents.dart';

/// User-facing sensitivity. Low = fewer false wake-ups (higher threshold and
/// two 80 ms frames in a row); High = more responsive / farther away.
enum WakeLevel { low, normal, high }

extension WakeLevelX on WakeLevel {
  String get key => name;

  /// Frames in a row above the threshold before a wake fires.
  int get patience => this == WakeLevel.low ? 2 : 1;

  static WakeLevel parse(String? s) => WakeLevel.values
      .firstWhere((l) => l.name == s, orElse: () => WakeLevel.low); // wakeword: fewest false wakes by default
}

/// Server/CI thresholds per level (picked on validation data by the training
/// pipeline). Defaults are only a fallback; values are clamped to (0, 1)
/// and kept ordered high <= normal <= low.
class WakeThresholds {
  final double low, normal, high;
  const WakeThresholds({this.low = 0.7, this.normal = 0.5, this.high = 0.3});

  factory WakeThresholds.fromJson(Object? j) {
    double v(Object? x, double d) {
      if (x is num && x > 0 && x < 1) return x.toDouble();
      return d;
    }

    final m = j is Map ? j : const {};
    final n = v(m['normal'], 0.5);
    final lo = v(m['low'], 0.7);
    final hi = v(m['high'], 0.3);
    return WakeThresholds(
      normal: n,
      low: lo < n ? n : lo,
      high: hi > n ? n : hi,
    );
  }

  double forLevel(WakeLevel l) => switch (l) {
        WakeLevel.low => low,
        WakeLevel.normal => normal,
        WakeLevel.high => high,
      };

  Map<String, double> toJson() => {'low': low, 'normal': normal, 'high': high};
}

/// Threshold + patience + cooldown. Same cases are pinned in Python
/// (tools/wakeword/tests) and Dart (test/va_wake_logic_test.dart).
class WakeDecider {
  final double threshold;
  final int patience;
  final int cooldownMs;
  int _run = 0;
  int? _last;
  int _t = 0;

  static const frameMs = 80;

  WakeDecider(this.threshold, {this.patience = 1, this.cooldownMs = 2000});

  factory WakeDecider.forLevel(WakeLevel l, WakeThresholds th) =>
      WakeDecider(th.forLevel(l), patience: l.patience);

  void reset() {
    _run = 0;
    _last = null;
    _t = 0;
  }

  /// One classifier score per 80 ms frame; true = wake word heard.
  bool feed(double score, [int? nowMs]) {
    _t = nowMs ?? _t + frameMs;
    _run = score >= threshold ? _run + 1 : 0;
    final last = _last;
    if (_run >= patience && (last == null || _t - last >= cooldownMs)) {
      _last = _t;
      _run = 0;
      return true;
    }
    return false;
  }
}

/// Native `wakeStatus` -> typed state.
enum WakeRun { off, listening, paused, error, engineMissing, unknown }

class WakeStatus {
  final WakeRun run;
  final String reason; // battery | call | mic_busy | user | wake | fgs_blocked | mic_blocked | ...
  final DateTime? pausedUntil;
  final bool wanted;
  final WakeLevel level;
  const WakeStatus(this.run,
      {this.reason = '',
      this.pausedUntil,
      this.wanted = false,
      this.level = WakeLevel.normal});

  static const unknown = WakeStatus(WakeRun.unknown);

  bool get isOn => run == WakeRun.listening || run == WakeRun.paused;

  /// Android stopped it and it needs one tap (honest "turn on again").
  bool get needsRestart =>
      wanted &&
      (run == WakeRun.off ||
          (run == WakeRun.error &&
              (reason == 'fgs_blocked' || reason == 'mic_blocked')));

  factory WakeStatus.fromNative(Object? raw) {
    if (raw is! Map) return unknown;
    final s = '${raw['state'] ?? ''}';
    final run = switch (s) {
      'listening' => WakeRun.listening,
      'paused' => WakeRun.paused,
      'stopped' => WakeRun.off,
      'error' => WakeRun.error,
      'engine_missing' => WakeRun.engineMissing,
      _ => WakeRun.unknown,
    };
    final until = raw['pausedUntil'];
    return WakeStatus(run,
        reason: '${raw['reason'] ?? ''}',
        pausedUntil: until is int && until > 0
            ? DateTime.fromMillisecondsSinceEpoch(until)
            : null,
        wanted: raw['wanted'] == true,
        level: WakeLevelX.parse('${raw['level'] ?? ''}'));
  }
}

/// Whether the "Hey Assisto" switch may turn ON, and what to show instead.
enum WakeBlock { none, modelPending, licencePending, engineMissing, needsDisclosure }

class VaWakeGate {
  VaWakeGate._();

  /// Order matters: never show the disclosure for something that cannot run.
  static WakeBlock check({
    required bool modelAvailable,
    required String serverReason,
    required bool engineBundled,
    required bool disclosureAccepted,
  }) {
    if (!modelAvailable) {
      return serverReason == 'licence_pending'
          ? WakeBlock.licencePending
          : WakeBlock.modelPending;
    }
    if (!engineBundled) return WakeBlock.engineMissing;
    if (!disclosureAccepted) return WakeBlock.needsDisclosure;
    return WakeBlock.none;
  }
}

/// Locked-phone rules (owner order): HARMLESS actions run straight away
/// (music, time, weather, alarm, timer, torch, SOS); PERSONAL ones (calls,
/// messages, contacts, apps, maps/location, the user's data via the agent)
/// ask Android to unlock first.
class VaLockPolicy {
  VaLockPolicy._();

  static const _harmless = {
    VaAction.torchOn,
    VaAction.torchOff,
    VaAction.sos,
    VaAction.alarm,
    VaAction.timer,
    VaAction.youtube, // "play <song>" (music)
  };

  static bool needsUnlock(VaIntent i) {
    if (_harmless.contains(i.action)) return false;
    if (i.action == VaAction.unknown) return !isHarmlessQuery(i.raw);
    return true;
  }

  // time / date / weather questions (en, Banglish, bn)
  static const _askWords = [
    'time', 'weather', 'temperature', 'forecast', 'rain', 'what day',
    'date today', "today's date", 'koyta baje', 'kotay baje', 'kota baje',
    'somoy koto', 'abohawa', 'aboh awa', 'abhawa', 'brishti', 'tapmatra',
    'aj ki bar', 'ajke ki bar',
    '\u0995\u09af\u09bc\u099f\u09be \u09ac\u09be\u099c\u09c7', // koyta baje
    '\u0995\u099f\u09be \u09ac\u09be\u099c\u09c7', // kota baje
    '\u09b8\u09ae\u09af\u09bc', // somoy
    '\u0986\u09ac\u09b9\u09be\u0993\u09af\u09bc\u09be', // abohawa
    '\u09ac\u09c3\u09b7\u09cd\u099f\u09bf', // brishti
    '\u09a4\u09be\u09aa\u09ae\u09be\u09a4\u09cd\u09b0\u09be', // tapmatra
    '\u0986\u099c \u0995\u09bf \u09ac\u09be\u09b0', // aj ki bar
    '\u0986\u099c\u0995\u09c7 \u0995\u09c0 \u09ac\u09be\u09b0', // ajke ki bar
    '\u09a4\u09be\u09b0\u09bf\u0996', // tarikh
  ];

  // anything that points at the user's own data stays behind the unlock
  static const _personalWords = [
    'my ', 'mine', 'message', 'sms', 'call', 'contact', 'number', 'remind',
    'note', 'balance', 'account', 'password', 'photo', 'amar', 'amake',
    'meeting', 'calendar', 'schedule', 'appointment',
    '\u0986\u09ae\u09be\u09b0', // amar
    '\u09ae\u09c7\u09b8\u09c7\u099c', // message
    '\u09ab\u09cb\u09a8', // phone
    '\u0995\u09b2', // call
    '\u09a8\u09ae\u09cd\u09ac\u09b0', // number
    '\u099f\u09be\u0995\u09be', // taka (money)
  ];

  static bool isHarmlessQuery(String raw) {
    final s = ' ${raw.toLowerCase().replaceAll('\u09df', '\u09af\u09bc')} ';
    if (s.trim().isEmpty) return false;
    if (_personalWords.any(s.contains)) return false;
    return _askWords.any(s.contains);
  }
}
