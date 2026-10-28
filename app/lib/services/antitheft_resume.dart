import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import 'antitheft_service.dart';
import 'oem_guide.dart';
import 'intruder_snap.dart'; // at100

/// at-heartbeat (owner 24 Oct) — keep the always-on Lost/Stolen engine alive.
///
/// A Play update (or the OS) can kill the engine's foreground service; before
/// this, nothing brought it back and opening Assisto did not either (only the
/// protection screen did), so the family was told the phone "stopped checking
/// in" while the owner was using it.
///
/// On EVERY app open / resume [onAppOpen] asks the native side to resume:
/// protection ON (the engine still holds its scoped token) -> the service is
/// started again with `rebaseline: false` (the SIM baseline recorded when
/// protection was switched on is compared, never re-recorded) or, if it is
/// running, asked for an immediate check-in. Protection off -> nothing runs.
/// Fire-and-forget, throttled, crash-guarded, never on the launch path (the
/// caller schedules it after the first frame).
///
/// [maybeShowBatteryGuide]: a ONE-TIME battery-optimisation guide (the
/// existing OEM guide screen) when protection is on and Android says Assisto
/// is battery-optimised (Doze / battery savers delay or stop check-ins).
class AntiTheftResume {
  AntiTheftResume._();

  static const guidePrefKey = 'at_battery_guide_seen_v1';

  static bool _busy = false;
  static DateTime? _last;

  @visibleForTesting
  static Duration throttle = const Duration(seconds: 20);

  /// The native call (tests swap it).
  @visibleForTesting
  static Future<bool> Function(Map<String, String> notif) resumeNative =
      (n) => AntiTheftService.resume(notif: n);

  /// The OEM-guide native bridge (tests swap it).
  @visibleForTesting
  static OemGuideNative native = const ChannelOemGuideNative();

  @visibleForTesting
  static void resetForTest() {
    _busy = false;
    _last = null;
  }

  /// Localized texts the engine shows (its notification + the "protection
  /// paused, tap to resume" notification after a restart Android refused).
  static Map<String, String> texts(AppLocalizations tr) => {
        'title': tr.atNotifTitle,
        'body': tr.atNotifBody,
        'off': tr.atNotifOff,
        'resumeTitle': tr.athbResumeTitle,
        'resumeBody': tr.athbResumeBody,
        // grab-guard: the local "Was this you?" heads-up after a grab
        // antitheft2: "Are you OK?" (owner 27 Oct)
        'grabTitle': tr.at2OkTitle,
        'grabBody': tr.at2OkNotifBody,
      };

  /// True when protection is ON and the engine is (now) running.
  static Future<bool> onAppOpen(Map<String, String> notif) async {
    if (_busy) return false;
    final now = DateTime.now();
    if (_last != null && now.difference(_last!) < throttle) return false;
    _busy = true;
    try {
      // at100: the PIN dialogs' "a wrong PIN takes a photo" notice (cached)
      await IntruderSnap.load();
      final ok = await resumeNative(notif);
      _last = DateTime.now();
      return ok;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Push the battery guide ONCE (ever) if Android reports Assisto is
  /// battery-optimised. [stillOk] lets the caller refuse at the last moment
  /// (e.g. another screen is on top). Returns true when it was shown.
  static Future<bool> maybeShowBatteryGuide(
      NavigatorState nav, Widget Function() screen,
      {bool Function()? stillOk}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(guidePrefKey) ?? false) return false;
      final info = await native.info();
      // null = Android can't tell: never nag on a guess.
      if (info == null || info.batteryOptIgnored != false) return false;
      if (!nav.mounted || (stillOk != null && !stillOk())) return false;
      await prefs.setBool(guidePrefKey, true);
      // the first-run OEM guide covers the same steps: don't show it again
      await prefs.setBool(OemGuideGate.prefKey, true);
      unawaited(nav.push(MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'at_battery_guide'),
          builder: (_) => screen())));
      return true;
    } catch (_) {
      return false;
    }
  }
}
