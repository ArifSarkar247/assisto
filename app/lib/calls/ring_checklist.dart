import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notifications.dart';
import '../services/oem_guide.dart';
import 'call_native.dart';

/// ring-everywhere — "Calls ring setup" checklist (owner 24 Oct: calls must
/// ring like WhatsApp on every phone, also when Assisto is closed).
///
/// One row per thing a phone needs for a closed-app ring, each OK / Missing /
/// Check (Android cannot report it — the user confirms after opening it):
///   notifications   POST_NOTIFICATIONS (Android 13+) / app notifications on
///   callChannel     the "Calls" notification category is not switched off
///   fullScreen      Android 14+ "full screen notifications" (play-fsi)
///   + the tl1 OEM steps for this phone family (services/oem_guide.dart):
///     background restricted, battery optimisation (Samsung: Unrestricted),
///     autostart (Xiaomi/Redmi/POCO, OPPO/realme/OnePlus, vivo,
///     Infinix/Tecno/itel), the vendor battery saver, lock in recents.
///     Walton / Symphony / Nokia / Motorola… are near-stock: battery only.
/// Every Fix opens the matching screen; the native side falls back to the
/// app's own App info page when a vendor screen is missing (never a dead
/// button).
///
/// [attention] drives the warning badge on the drawer's Settings entry and
/// the Settings tile, plus the small banner in My Circle.
enum RingCheckId {
  notifications,
  callChannel,
  fullScreen,
  oemStep,
}

enum RingCheckState { ok, missing, check }

class RingCheckRow {
  const RingCheckRow(this.id, this.state, {this.step});
  final RingCheckId id;
  final RingCheckState state;

  /// The tl1 step for [RingCheckId.oemStep] rows.
  final OemStepId? step;

  /// Stable key (prefs / widget keys).
  String get key => step == null ? id.name : 'oem_${step!.name}';

  @override
  String toString() => '$key:${state.name}';
}

/// What the phone told us. Null = Android can't tell (never counted missing).
class RingFacts {
  const RingFacts({
    this.notifications,
    this.callChannel,
    this.fullScreen,
    this.oem,
    this.confirmed = const {},
  });
  final bool? notifications;
  final bool? callChannel;
  final bool? fullScreen;
  final OemInfo? oem;

  /// Row keys the user marked "I've done it" (steps Android can't check).
  final Set<String> confirmed;
}

/// The checklist rows for [f] (pure — unit tested).
List<RingCheckRow> ringCheckRows(RingFacts f, {OemFamily? family}) {
  RingCheckState known(bool? v) =>
      v == false ? RingCheckState.missing : RingCheckState.ok;
  final rows = <RingCheckRow>[
    RingCheckRow(RingCheckId.notifications, known(f.notifications)),
    if (f.notifications != false)
      RingCheckRow(RingCheckId.callChannel, known(f.callChannel)),
    if ((f.oem?.sdkInt ?? 0) >= 34 || f.fullScreen == false)
      RingCheckRow(RingCheckId.fullScreen, known(f.fullScreen)),
  ];
  final info = f.oem;
  if (info != null) {
    final fam = family ?? info.family;
    for (final s in oemSteps(fam, bgRestricted: info.bgRestricted)) {
      final key = 'oem_${s.name}';
      final RingCheckState st;
      if (s.checkable) {
        st = oemStepDone(s, info) ? RingCheckState.ok : RingCheckState.missing;
      } else {
        st = f.confirmed.contains(key) ? RingCheckState.ok : RingCheckState.check;
      }
      rows.add(RingCheckRow(RingCheckId.oemStep, st, step: s));
    }
  }
  return rows;
}

/// Anything not OK (Missing, or a Check the user has not confirmed yet)?
bool ringNeedsAttention(List<RingCheckRow> rows) =>
    rows.any((r) => r.state != RingCheckState.ok);

/// Native lookups + the Fix actions. Tests pass a fake.
abstract class RingCheckNative {
  Future<bool?> notificationsEnabled();
  Future<bool?> callChannelOk();
  Future<bool?> canFullScreen();
  Future<OemInfo?> oemInfo();

  /// true = a settings screen / prompt was opened.
  Future<bool> fixNotifications();
  Future<bool> fixCallChannel();
  Future<bool> fixFullScreen();
  Future<OemOpen> openOemStep(String nativeStep);
}

class ChannelRingCheckNative implements RingCheckNative {
  const ChannelRingCheckNative({this.oem = const ChannelOemGuideNative()});
  final OemGuideNative oem;

  @override
  Future<bool?> notificationsEnabled() => Notifications.isEnabled();

  @override
  Future<bool?> callChannelOk() => CallNative.callChannelOk();

  @override
  Future<bool?> canFullScreen() => CallNative.canFullScreen();

  @override
  Future<OemInfo?> oemInfo() => oem.info();

  @override
  Future<bool> fixNotifications() async {
    if (await Notifications.requestPermission()) return true;
    // permanently denied: the runtime prompt can't show -> app settings
    await Notifications.openSettings();
    return true;
  }

  @override
  Future<bool> fixCallChannel() async {
    await Notifications.openSettings();
    return true;
  }

  @override
  Future<bool> fixFullScreen() async {
    if (await CallNative.openFullScreenSettings()) return true;
    return await oem.open('app_details') != OemOpen.none;
  }

  @override
  Future<OemOpen> openOemStep(String nativeStep) => oem.open(nativeStep);
}

class RingChecklist {
  RingChecklist._();

  static const confirmedKey = 'ring_check_confirmed_v1';
  static const seenKey = 'ring_check_seen_v1';
  static const bannerHiddenUntilKey = 'ring_check_banner_until_v1';
  static const bannerSnooze = Duration(days: 7);

  /// true when something is missing (badge + banner). Starts false: nothing
  /// is ever shown before a real check ran.
  static final ValueNotifier<bool> attention = ValueNotifier<bool>(false);

  @visibleForTesting
  static RingCheckNative native = const ChannelRingCheckNative();

  @visibleForTesting
  static bool Function() isAndroid = () => !kIsWeb && Platform.isAndroid;

  static Future<Set<String>> confirmed() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getStringList(confirmedKey) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> setConfirmed(String key, bool on) async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = (p.getStringList(confirmedKey) ?? const <String>[]).toSet();
      on ? s.add(key) : s.remove(key);
      await p.setStringList(confirmedKey, s.toList()..sort());
    } catch (_) {}
  }

  static Future<RingFacts> facts({RingCheckNative? using}) async {
    final n = using ?? native;
    Future<T?> safe<T>(Future<T?> Function() f) async {
      try {
        return await f().timeout(const Duration(seconds: 4));
      } catch (_) {
        return null;
      }
    }

    return RingFacts(
      notifications: await safe(n.notificationsEnabled),
      callChannel: await safe(n.callChannelOk),
      fullScreen: await safe(n.canFullScreen),
      oem: await safe(n.oemInfo),
      confirmed: await confirmed(),
    );
  }

  /// Re-check and publish [attention]. Android only; never throws.
  static Future<List<RingCheckRow>> refresh({RingCheckNative? using}) async {
    try {
      if (!isAndroid()) {
        attention.value = false;
        return const [];
      }
      final f = await facts(using: using);
      // can't read the phone at all -> no badge (never nag blindly)
      if (f.oem == null && f.notifications == null) {
        attention.value = false;
        return const [];
      }
      final rows = ringCheckRows(f);
      attention.value = ringNeedsAttention(rows);
      return rows;
    } catch (_) {
      return const [];
    }
  }

  /// My Circle banner: attention AND not snoozed ("Later" hides it 7 days).
  static Future<bool> bannerAllowed({DateTime? now}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final until = p.getInt(bannerHiddenUntilKey) ?? 0;
      return (now ?? DateTime.now()).millisecondsSinceEpoch >= until;
    } catch (_) {
      return true;
    }
  }

  static Future<void> snoozeBanner({DateTime? now}) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(bannerHiddenUntilKey,
          (now ?? DateTime.now()).add(bannerSnooze).millisecondsSinceEpoch);
    } catch (_) {}
  }
}

/// "Show once after login" (replaces the tl1 OEM-guide gate: the checklist
/// contains those steps plus notifications / full-screen). Called from the
/// root route AFTER login + onboarding, never from the home screen; waits a
/// few seconds, pushes the checklist only when something is missing and the
/// root route is still on top (never over a ringing call).
class RingCheckGate {
  static bool _scheduled = false;

  @visibleForTesting
  static Duration delay = const Duration(seconds: 4);
  @visibleForTesting
  static void resetForTest() => _scheduled = false;

  static void schedule(BuildContext context, Widget Function() screen) {
    if (_scheduled) return;
    _scheduled = true;
    bool android;
    try {
      android = RingChecklist.isAndroid();
    } catch (_) {
      android = false;
    }
    if (!android) return;
    final nav = Navigator.maybeOf(context);
    if (nav == null) return;
    final route = ModalRoute.of(context);
    unawaited(Future<void>.delayed(delay, () async {
      try {
        final rows = await RingChecklist.refresh();
        if (rows.isEmpty) return; // couldn't check: try next launch
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool(RingChecklist.seenKey) ?? false) return;
        if (!nav.mounted || (route != null && !route.isCurrent)) return;
        await prefs.setBool(RingChecklist.seenKey, true);
        // the tl1 guide's once-flag too: its steps are inside the checklist
        await prefs.setBool(OemGuideGate.prefKey, true);
        if (!ringNeedsAttention(rows)) return;
        await nav.push(MaterialPageRoute(
            settings: const RouteSettings(name: 'ring_check_first_run'),
            builder: (_) => screen()));
      } catch (_) {}
    }));
  }
}
