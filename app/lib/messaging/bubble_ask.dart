import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'msg_native.dart';
import 'msg_prefs.dart';

/// bubbles2 (owner FINAL bubbles order, 3 Nov 01:50) — WHEN to ask the user
/// to turn on floating chat bubbles, and what the phone really allows.
///
/// ANDROID RULES (no app can change them — said honestly in the card and
/// the owner doc):
///  * "All conversations can bubble" is the USER's choice. "Turn on" opens
///    Assisto's exact Bubbles page (Settings.ACTION_APP_NOTIFICATION_BUBBLE_
///    SETTINGS, Android 11+); we re-check on return (getBubblePreference on
///    12+, areBubblesAllowed on 11) and show the success line.
///  * Android 10 and below: no bubbles → the step is skipped silently and
///    messages come as normal notifications.
///  * Some phones block bubbles (Android turns them off on low-RAM / Go
///    phones; some brands remove the page) → an honest line, normal
///    notifications.
///
/// ASK SCHEDULE (point 6): onboarding asks once (right after the Android 13+
/// notification permission). "Later" → ask once more the first time My
/// Circle opens, then once after 3 days, then NEVER again. My Circle
/// settings always has "Turn on". One permission per screen.

/// What the phone allows right now.
enum BubbleReady {
  /// Android 10 or below (or not Android): skip silently.
  unsupported,

  /// "All conversations can bubble" — every My Circle chat floats.
  on,

  /// Only conversations the user picked one by one can bubble.
  selectedOnly,

  /// Bubbles are off for Assisto (the user can turn them on).
  off,

  /// Assisto's notifications are off — bubbles come from notifications.
  notifsOff,

  /// The phone itself blocks bubbles (low-RAM / Go phone, no settings page).
  blocked,

  /// The native side didn't answer (tests, older build).
  unknown,
}

class BubbleStatus {
  const BubbleStatus({
    this.sdk = 0,
    this.pref,
    this.notifs,
    this.lowRam,
    this.page,
    this.phoneOn,
    this.maker = '',
  });

  final int sdk;

  /// 'all' | 'selected' | 'none' | null (unknown).
  final String? pref;
  final bool? notifs;
  final bool? lowRam;

  /// The exact bubble settings page exists on this phone.
  final bool? page;

  /// The phone-wide bubble switch (null = the brand hides it).
  final bool? phoneOn;
  final String maker;

  static int _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
  static bool? _bool(Object? v) => v is bool ? v : null;

  factory BubbleStatus.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const BubbleStatus();
    final pref = m['pref'];
    return BubbleStatus(
      sdk: _int(m['sdk']),
      pref: pref is String ? pref : null,
      notifs: _bool(m['notifs']),
      lowRam: _bool(m['lowRam']),
      page: _bool(m['page']),
      phoneOn: _bool(m['phoneOn']),
      maker: '${m['maker'] ?? ''}',
    );
  }

  /// The one decision (pinned by tests).
  BubbleReady get ready {
    if (sdk == 0) return BubbleReady.unknown;
    if (sdk < 30) return BubbleReady.unsupported;
    if (pref == 'all' && notifs != false) return BubbleReady.on;
    if (lowRam == true || page == false) return BubbleReady.blocked;
    if (notifs == false) return BubbleReady.notifsOff;
    if (pref == 'selected') return BubbleReady.selectedOnly;
    if (pref == 'none') return BubbleReady.off;
    return BubbleReady.unknown;
  }

  /// Worth showing the "Turn on" card at all (an automatic ask).
  bool get askable =>
      ready == BubbleReady.off || ready == BubbleReady.selectedOnly;
}

/// Where an automatic ask could happen.
enum BubbleAskWhere { onboarding, circleOpen }

/// The pure schedule (pinned by tests). [stage]: 0 = never asked,
/// 1 = asked in onboarding, 2 = asked at the first My Circle open,
/// 3 = asked again after 3 days → never again.
class BubbleAskPolicy {
  BubbleAskPolicy._();

  static const Duration again = Duration(days: 3);
  static const int finalStage = 3;

  static bool shouldAsk({
    required BubbleAskWhere where,
    required int stage,
    required DateTime now,
    DateTime? lastAsk,
  }) {
    if (stage >= finalStage) return false;
    if (where == BubbleAskWhere.onboarding) return stage == 0;
    // circleOpen: never asked (an update from an older build, or
    // notifications were off on install day) or "Later" in onboarding →
    // ask at this open
    if (stage <= 1) return true;
    // stage 2: once more, 3 days after the My Circle ask
    final last = lastAsk;
    if (last == null) return true;
    return !now.isBefore(last.add(again));
  }

  /// The stage after an ask was shown here.
  static int after(BubbleAskWhere where, int stage) {
    if (where == BubbleAskWhere.onboarding) return stage < 1 ? 1 : stage;
    return stage <= 1 ? 2 : finalStage;
  }
}

/// Prefs + native glue around [BubbleAskPolicy].
class BubbleAsk {
  BubbleAsk._();

  static const kStage = 'bbl2_ask_stage';
  static const kLastAsk = 'bbl2_ask_last_ms';

  /// Test seams.
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function() readStatus =
      MsgNative.bubbleStatus;
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  static Future<BubbleStatus> status() async {
    try {
      return BubbleStatus.fromMap(await readStatus());
    } catch (_) {
      return const BubbleStatus();
    }
  }

  static Future<SharedPreferences?> _p() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  /// Should the card be shown automatically here, now? False when the app
  /// switch is off, the phone can't bubble, it is already on, or the
  /// schedule says no.
  static Future<bool> due(BubbleAskWhere where) async {
    final p = await _p();
    if (p == null) return false;
    if (!(await MsgPrefs.bubblesOn())) return false;
    final stage = p.getInt(kStage) ?? 0;
    final lastMs = p.getInt(kLastAsk);
    if (!BubbleAskPolicy.shouldAsk(
        where: where,
        stage: stage,
        now: clock(),
        lastAsk: lastMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(lastMs))) {
      return false;
    }
    return (await status()).askable;
  }

  /// Record that the card was shown here (whatever the answer).
  static Future<void> markAsked(BubbleAskWhere where) async {
    final p = await _p();
    if (p == null) return;
    final stage = p.getInt(kStage) ?? 0;
    await p.setInt(kStage, BubbleAskPolicy.after(where, stage));
    await p.setInt(kLastAsk, clock().millisecondsSinceEpoch);
  }

  // ---- in-call overlay (point 4) --------------------------------------------

  /// `c3_call_overlay_until` (epoch ms) — read by BubbleHelper.shouldAttach:
  /// while it is in the future the Assisto call screen is on top and shows
  /// its own in-app bubbles, so no duplicate system bubble is attached. A
  /// time, not a flag: a crash can never leave bubbles off.
  static const kCallOverlayUntil = 'c3_call_overlay_until';
  static const Duration overlayTtl = Duration(seconds: 90);

  static Future<void> setCallOverlay(bool on) async {
    final p = await _p();
    if (p == null) return;
    try {
      if (on) {
        await p.setInt(kCallOverlayUntil,
            clock().add(overlayTtl).millisecondsSinceEpoch);
      } else {
        await p.remove(kCallOverlayUntil);
      }
    } catch (_) {}
  }
}
