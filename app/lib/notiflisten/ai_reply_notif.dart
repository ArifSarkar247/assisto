import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../config.dart';
import '../feature_flags.dart';
import '../l10n/app_localizations.dart';
import 'ai_reply_notif_rules.dart';

/// ai-reply-notif — SUGGESTED REPLIES IN NOTIFICATIONS (owner order 17 Nov, part A).
///
/// A message from a chat app the user switched on -> the native listener
/// (reused callmoney AssistoNotifListener, its OWN gate in AiReplyCore) asks
/// the server for 2–3 short replies and shows OUR companion notification.
/// Only the user's tap sends, through the chat app's own reply action.
///
/// Gate, all required (tested): server flag [flag] + the AI-reply consent
/// ([AiReplyNotifPrefs.consent], separate from callmoney's) + the master
/// switch + at least one app + Android Notification access. The callmoney
/// consent NEVER opens this feature.
class AiReplyNotifPrefs {
  AiReplyNotifPrefs._();
  static const on = 'arn_on';
  static const apps = 'arn_apps';
  static const consent = 'arn_consent_v1'; // ISO time the user agreed
  static const tokenExp = 'arn_token_exp'; // ISO expiry of the native token
}

/// What the native side reports.
class AiReplyNativeStatus {
  final bool available; // native code exists on this phone/build
  final bool granted; // Android Notification access is on for Assisto
  final bool on; // native gate is open (flag + consent + master)
  final List<String> apps;
  final bool hasToken;
  final int noCreditCount; // replies skipped for no credits since last unlock
  final Set<String> installedPackages;
  const AiReplyNativeStatus({
    this.available = false,
    this.granted = false,
    this.on = false,
    this.apps = const [],
    this.hasToken = false,
    this.noCreditCount = 0,
    this.installedPackages = const {},
  });
}

abstract class AiReplyNotifBridge {
  Future<AiReplyNativeStatus> status();
  Future<void> configure({
    required bool on,
    required bool flag,
    required String consent,
    required List<String> apps,
    String? token, // null = keep, '' = drop
    String? api,
    required Map<String, String> strings,
  });
  Future<void> clearNoCredit();
  Future<void> openAccessSettings();
}

class AiReplyNotifChannel implements AiReplyNotifBridge {
  static const _ch = MethodChannel('com.assisto/notif_listen');

  /// The bridge every screen uses; tests swap in a fake.
  static AiReplyNotifBridge instance = AiReplyNotifChannel();

  bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<AiReplyNativeStatus> status() async {
    if (!_android) return const AiReplyNativeStatus();
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('aiStatus');
      if (m == null) return const AiReplyNativeStatus();
      return AiReplyNativeStatus(
        available: true,
        granted: m['granted'] == true,
        on: m['on'] == true,
        apps: [for (final a in (m['apps'] as List? ?? const [])) '$a'],
        hasToken: m['hasToken'] == true,
        noCreditCount: (m['noCreditN'] as num?)?.toInt() ?? 0,
        installedPackages: {for (final a in (m['installed'] as List? ?? const [])) '$a'},
      );
    } catch (_) {
      return const AiReplyNativeStatus(); // an older build without the method
    }
  }

  @override
  Future<void> configure({
    required bool on,
    required bool flag,
    required String consent,
    required List<String> apps,
    String? token,
    String? api,
    required Map<String, String> strings,
  }) async {
    if (!_android) return;
    try {
      await _ch.invokeMethod('setAiReply', {
        'on': on,
        'flag': flag,
        'consent': consent,
        'apps': apps,
        'token': token,
        'api': api,
        'strings': strings,
      });
    } catch (_) {} // best-effort: no native side -> nothing can be read anyway
  }

  @override
  Future<void> clearNoCredit() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod('aiClearNoCredit');
    } catch (_) {} // best-effort: the counter is only a hint for the unlock card
  }

  @override
  Future<void> openAccessSettings() async {
    try {
      await _ch.invokeMethod('openAccessSettings');
    } catch (_) {} // best-effort: the screen explains the Settings path
  }
}

/// Lane ai-reply-core endpoints (contract agreed via the lead, 17 Nov).
extension AiReplyNotifApi on ApiClient {
  /// POST /ai/reply/notif-token -> {ok, token, expires_at} | {ok:false, reason}.
  Future<Map<String, dynamic>> aiReplyNotifToken() => postJsonRaw('/ai/reply/notif-token');

  /// DELETE /ai/reply/notif-token (turn off).
  Future<Map<String, dynamic>> aiReplyNotifTokenRevoke() => deleteJson('/ai/reply/notif-token');

  /// GET /ai/reply/notif-state -> {free_left, unlock_ad_placement}.
  Future<Map<String, dynamic>> aiReplyNotifState() => getJson('/ai/reply/notif-state');
}

class AiReplyNotifService {
  AiReplyNotifService._();

  static const flag = 'ai_reply_notif';
  static const adPlacement = 'ai_reply_unlock';
  static AiReplyNotifBridge get bridge => AiReplyNotifChannel.instance;

  /// ON only when it is on for everyone or this user previews it.
  static bool flagOn() => FeatureFlags.instance.isOn(flag);

  /// Strings the native companion notification shows (ARB, never Kotlin).
  static Map<String, String> nativeStrings(AppLocalizations t) => {
        'channel': t.arnChannel,
        'title': t.arnNotifTitle,
        'sub': t.arnNotifSub,
        'own': t.arnWriteMyself,
        'sent': t.arnNotifSent,
        'fail': t.arnNotifFail,
      };

  static Future<({bool on, List<String> apps, String consent})> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (
        on: p.getBool(AiReplyNotifPrefs.on) ?? false,
        apps: p.getStringList(AiReplyNotifPrefs.apps) ?? const <String>[],
        consent: p.getString(AiReplyNotifPrefs.consent) ?? '',
      );
    } catch (_) {
      return (on: false, apps: const <String>[], consent: '');
    }
  }

  static Future<bool> hasConsent() async => (await load()).consent.isNotEmpty;

  static Future<void> recordConsent(bool agreed) async {
    final p = await SharedPreferences.getInstance();
    if (agreed) {
      await p.setString(AiReplyNotifPrefs.consent, DateTime.now().toUtc().toIso8601String());
    } else {
      await p.remove(AiReplyNotifPrefs.consent);
    }
  }

  static bool _tokenFresh(SharedPreferences p) {
    final exp = DateTime.tryParse(p.getString(AiReplyNotifPrefs.tokenExp) ?? '');
    return exp != null && exp.difference(DateTime.now()).inHours > 24;
  }

  /// Saves the switches and hands them to the native gate. ON needs: flag +
  /// consent + master + >=1 app. A fresh scoped token is fetched when needed.
  /// Turning OFF (or losing the flag) drops the token and every card.
  static Future<({bool on, List<String> apps})> apply(
    AppLocalizations t, {
    required bool on,
    required List<String> apps,
    ApiClient? api,
  }) async {
    final p = await SharedPreferences.getInstance();
    final consent = p.getString(AiReplyNotifPrefs.consent) ?? '';
    final f = flagOn();
    final clean = [for (final s in AiReplyRules.slugs) if (apps.contains(s)) s];
    final want = on && consent.isNotEmpty; // the user's choice survives a flag pause
    final live = want && f;
    await p.setBool(AiReplyNotifPrefs.on, want);
    await p.setStringList(AiReplyNotifPrefs.apps, clean);
    String? token;
    if (!live || clean.isEmpty) {
      token = '';
      final had = p.getString(AiReplyNotifPrefs.tokenExp) != null;
      await p.remove(AiReplyNotifPrefs.tokenExp);
      if (had && api != null) {
        try {
          await api.aiReplyNotifTokenRevoke(); // the server forgets it at once
        } catch (_) {} // offline: the token still dies at its expiry
      }
    } else if (api != null && !_tokenFresh(p)) {
      try {
        final r = await api.aiReplyNotifToken();
        if (r['ok'] == true && '${r['token'] ?? ''}'.isNotEmpty) {
          token = '${r['token']}';
          await p.setString(AiReplyNotifPrefs.tokenExp,
              '${r['expires_at'] ?? DateTime.now().add(const Duration(days: 7)).toUtc().toIso8601String()}');
        } else if (r['_status'] == 403) {
          token = ''; // flag off / child account on the server: stays quiet
        }
      } catch (_) {
        // offline: the last token (if any) keeps working until it expires
      }
    }
    await bridge.configure(
      on: live,
      flag: f,
      consent: live ? consent : '',
      apps: live ? clean : const [],
      token: token,
      api: AppConfig.api('/').toString(),
      strings: nativeStrings(t),
    );
    return (on: live, apps: clean);
  }

  /// Turns everything off (master switch, sign-out, flag gone).
  static Future<void> turnOff(AppLocalizations t) async {
    final s = await load();
    await apply(t, on: false, apps: s.apps);
  }

  /// Sign-out: the scoped token + every card go, the switch turns OFF.
  static Future<void> signOut() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(AiReplyNotifPrefs.on, false);
      await p.remove(AiReplyNotifPrefs.tokenExp);
      await bridge.configure(
          on: false, flag: flagOn(), consent: '', apps: const [], token: '', strings: const {});
    } catch (_) {} // best-effort: sign-out must never block
  }

  static bool _busy = false;

  /// App open / resume: mirror the flag, refresh the token, stop when the
  /// flag is gone. Cheap + guarded; never runs native work at launch.
  static Future<void> onResume(ApiClient api, AppLocalizations t) async {
    if (_busy) return;
    _busy = true;
    try {
      final s = await load();
      if (!s.on) return; // never turned on: nothing to do, nothing touched
      await apply(t, on: flagOn(), apps: s.apps, api: api);
    } catch (_) {
      // best-effort: a resume check must never disturb the app
    } finally {
      _busy = false;
    }
  }
}
