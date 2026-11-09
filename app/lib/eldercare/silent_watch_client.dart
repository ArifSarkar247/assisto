import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../l10n/app_localizations.dart';
import 'are_you_ok_screen.dart';
import 'silent_watch_api.dart';
import 'silent_watch_brain.dart';
import 'silent_watch_native.dart';

/// fcelder — the Dart side of Silent Watch on the ELDER's phone.
///
///  * [configure] after the elder's spoken YES: keeps the config locally and
///    arms the native alarms with the brain's table + the one alert token.
///  * [onResume] on every app open: the elder used the phone (a sign of
///    life, unless an "Are you OK?" is ringing — then the Are-you-OK screen
///    opens instead), and once a day the brain re-learns the normal day from
///    the native on-phone log and re-arms.
///  * [noteActivity] from Easy Home buttons / Care Call answers (any
///    isolate: a SharedPreferences stamp the native side reads + the channel).
///  * [iAmOk] — the one tap that stops everything.
///
/// Nothing here sends activity to the server; only "I am OK" (to stop an
/// alert the family may already have) is sent.
class SilentWatchClient {
  SilentWatchClient._();

  static const kEnabled = 'sw_enabled';
  static const kCfg = 'sw_cfg';
  static const kLearnedDay = 'sw_learned_day';
  static const kDartActivity = 'sw_dart_activity_ms';
  static const kDaysLearned = 'sw_days_learned';

  static SilentWatchNative native = ChannelSilentWatchNative();

  /// Test hook: the opener for the Are-you-OK screen (set by main wiring).
  static Future<void> Function(BuildContext context)? openAreYouOk;

  static Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isOn() async => (await _prefs())?.getBool(kEnabled) ?? false;

  static Future<SwConfig> config() async {
    try {
      final s = (await _prefs())?.getString(kCfg);
      if (s == null) return const SwConfig();
      return SwConfig.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return const SwConfig();
    }
  }

  static Future<int> daysLearned() async => (await _prefs())?.getInt(kDaysLearned) ?? 0;

  static AppLocalizations _t(String lang) {
    try {
      return lookupAppLocalizations(Locale(lang == 'en' ? 'en' : 'bn'));
    } catch (_) {
      return lookupAppLocalizations(const Locale('en'));
    }
  }

  static Map<String, dynamic> _texts(String lang) {
    final t = _t(lang);
    return {
      'title': t.fceAskTitle,
      'body': t.fceAskBody,
      'ok_label': t.fceImOk,
      'told_body': t.fceToldBody,
      'channel_name': t.fceChannelName,
    };
  }

  static List<DateTime> _log(Map<String, dynamic>? st) {
    final raw = st?['log'];
    if (raw is! List) return const [];
    return [
      for (final m in raw)
        if (m is num) DateTime.fromMillisecondsSinceEpoch(m.toInt() * 60000)
    ];
  }

  /// Arms (or re-arms) the native side. [token] only right after setup /
  /// a token rotation; otherwise the native side keeps the one it has.
  static Future<bool> arm({required SwConfig cfg, String? token, String lang = 'bn'}) async {
    final now = clock.now();
    final st = await native.state();
    final learned = SilentWatchBrain.learn(_log(st), now, cfg);
    final ok = await native.arm({
      'enabled': true,
      'table': learned.tableMin,
      'day_start': cfg.dayStartMin,
      'day_end': cfg.dayEndMin,
      if (token != null) 'token': token,
      'api_base': '${AppConfig.apiBase}${AppConfig.apiPrefix}/',
      ..._texts(lang),
    });
    final p = await _prefs();
    await p?.setInt(kDaysLearned, learned.daysLearned);
    await p?.setString(kLearnedDay, _day(now));
    return ok;
  }

  static String _day(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// After the elder's YES (setup by a child) or a settings change.
  static Future<void> configure(SilentWatchApi api, Map<String, dynamic> cfgJson,
      {String? token, String lang = 'bn'}) async {
    final p = await _prefs();
    final enabled = cfgJson['enabled'] == true;
    await p?.setString(kCfg, jsonEncode(cfgJson));
    await p?.setBool(kEnabled, enabled);
    if (!enabled) {
      await native.disarm();
      return;
    }
    await arm(cfg: SwConfig.fromJson(cfgJson), token: token, lang: lang);
  }

  /// A sign of life from Dart (Easy Home tap, Care Call answered, app open).
  /// Safe in any isolate: the stamp is read by the native side on its next
  /// check even when the channel is not reachable.
  static Future<void> noteActivity() async {
    try {
      final p = await _prefs();
      if (p == null || !(p.getBool(kEnabled) ?? false)) return;
      await p.setInt(kDartActivity, clock.now().millisecondsSinceEpoch);
    } catch (_) {
      // best-effort: guarded so a failure never blocks the elder's tap
    }
    unawaited(native.noteActivity());
  }

  /// "I am OK": stops the ringing on the phone and any family alert.
  static Future<void> iAmOk(SilentWatchApi? api) async {
    try {
      final p = await _prefs();
      await p?.setInt(kDartActivity, clock.now().millisecondsSinceEpoch);
    } catch (_) {
      // best-effort: guarded so a failure never blocks the elder's tap
    }
    await native.ok();
    if (api != null) {
      try {
        await api.ok();
      } catch (_) {
        // offline: the native side retries with its token on the next check
      }
    }
  }

  static DateTime? _lastServerCheck;

  /// Is an "Are you OK?" waiting for this elder (ringing here, or the server
  /// asked after a missed Care Call)?
  static Future<bool> askPending(SilentWatchApi? api) async {
    final st = await native.state();
    if (st != null && (st['stage'] is num) && (st['stage'] as num) > 0) return true;
    if (api == null) return false;
    final now = clock.now();
    if (_lastServerCheck != null && now.difference(_lastServerCheck!) < const Duration(minutes: 2)) {
      return false;
    }
    _lastServerCheck = now;
    try {
      final r = await api.status();
      final a = (r['mine'] as Map?)?['alert'] as Map?;
      return a != null && (a['status'] == 'asking' || a['status'] == 'open');
    } catch (_) {
      return false;
    }
  }

  /// Every app open / resume (main.dart). Never throws, never blocks.
  static Future<void> onResume(SilentWatchApi? api, {BuildContext? context, String lang = 'bn'}) async {
    try {
      if (!await isOn()) return;
      if (await askPending(api)) {
        final open = openAreYouOk ?? AreYouOkScreen.open;
        if (context != null && context.mounted) await open(context);
        return;
      }
      await noteActivity();
      final p = await _prefs();
      final st = await native.state();
      final lost = st != null && st['enabled'] != true;
      if (p?.getString(kLearnedDay) != _day(clock.now()) || lost) {
        String? token;
        if (lost && api != null) {
          try {
            token = await api.newToken(); // reinstall / new phone: a fresh token
          } catch (_) {
      // best-effort: guarded so a failure never blocks the elder's tap
    }
        }
        await arm(cfg: await config(), token: token, lang: lang);
      }
    } catch (_) {
      // best-effort: guarded so a failure never blocks the elder's tap
    }
  }
}
