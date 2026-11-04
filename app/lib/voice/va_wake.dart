import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../config.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import 'va_native.dart';
import 'va_wake_logic.dart';

/// One model file of the on-device wake word (served by the Assisto server,
/// listed in its manifest: GET /api/v1/voice/config).
class VaWakeFile {
  final String role; // mel | embed | e2e | wake
  final String name;
  final String sha256;
  final int size;
  const VaWakeFile(this.role, this.name, this.sha256, this.size);
}

/// Server-side wake-word configuration (k1-wake). [available] is false until
/// a trained, licence-cleared "Hey Assisto" model is installed on the server
/// ([reason] = 'model_pending' | 'licence_pending'). No keys, no accounts.
class VaWakeConfig {
  final bool available;
  final String reason;
  final String version;
  final String backend; // e2e | oww
  final int windowSamples;
  final int frames;
  final List<VaWakeFile> files;
  final WakeThresholds thresholds;
  const VaWakeConfig({
    this.available = false,
    this.reason = 'model_pending',
    this.version = '',
    this.backend = 'e2e',
    this.windowSamples = 12400,
    this.frames = 16,
    this.files = const [],
    this.thresholds = const WakeThresholds(),
  });

  int get totalBytes => files.fold(0, (a, f) => a + f.size);

  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,80}\.onnx$');
  static final _sha = RegExp(r'^[0-9a-f]{64}$');

  factory VaWakeConfig.fromJson(Map<String, dynamic> j) {
    final w = (j['wake'] is Map) ? (j['wake'] as Map).cast<String, dynamic>() : j;
    final files = <VaWakeFile>[
      for (final f in (w['files'] is List ? w['files'] as List : const []))
        if (f is Map &&
            _name.hasMatch('${f['name']}') &&
            _sha.hasMatch('${f['sha256']}'.toLowerCase()) &&
            const {'mel', 'embed', 'e2e', 'wake'}.contains(f['role']))
          VaWakeFile('${f['role']}', '${f['name']}', '${f['sha256']}'.toLowerCase(),
              f['size'] is int ? f['size'] as int : 0),
    ];
    final roles = files.map((f) => f.role).toSet();
    final complete = roles.containsAll({'wake', 'e2e'}) ||
        roles.containsAll({'wake', 'mel', 'embed'});
    int n(Object? v, int d) => v is int && v > 0 ? v : d;
    return VaWakeConfig(
      available: w['available'] == true && complete,
      reason: '${w['reason'] ?? ''}',
      version: '${w['version'] ?? ''}',
      backend: roles.contains('e2e') ? 'e2e' : 'oww',
      windowSamples: n(w['window_samples'], 12400),
      frames: n(w['frames'], 16),
      files: files,
      thresholds: WakeThresholds.fromJson(w['thresholds']),
    );
  }
}

/// "Hey Assisto" controller. OFF by default; nothing here runs at app
/// launch except [maybeRestart], which only acts (a few seconds after the
/// first frame) when the user had turned it on before.
class VaWake {
  VaWake._();

  /// NO SHOWPIECES (owner rule, round 2 item 4e): the "Hey Assisto" wake word
  /// stays HIDDEN until the wake-word build ships a working engine. The
  /// wake-word branch flips this to `true` (or builds with
  /// `--dart-define=ASSISTO_WAKE_WORD=true`). Even then the settings card only
  /// appears when the engine + server config are really ready on this phone —
  /// never a "coming soon" row.
  ///
  /// wakeword (4 Nov): SHIPPED — on-device openWakeWord engine + our own
  /// licence-cleared model served by the Assisto server. The card still only
  /// shows when the server really serves the model and the native engine is
  /// in this build (`--dart-define=ASSISTO_WAKE_WORD=false` hides it again).
  static const bool shipped =
      bool.fromEnvironment('ASSISTO_WAKE_WORD', defaultValue: true);

  static const prefKey = 'va_wake_on'; // bool, default false
  static const ttsKey = 'va_tts_on'; // bool, default true
  // aivoice: Assisto Voice listens again after reading an answer.
  static const continueKey = 'va_continue_v1'; // bool, default false
  static const disclosureKey = 'va_wake_disclosure_v1'; // bool
  static const levelKey = 'va_wake_level'; // low | normal | high
  static const _cfgCacheKey = 'va_wake_cfg_cache';
  /// wakeword: listen while the phone is locked — OFF until the user says yes.
  static const lockedKey = 'va_wake_locked_ok'; // bool, default false
  static Future<bool> lockedOk() => Settings.getBool(lockedKey, false);
  static Future<void> setLockedOk(bool v) => Settings.setBool(lockedKey, v);

  static Future<bool> wanted() => Settings.getBool(prefKey, false);
  static Future<void> setWanted(bool v) => Settings.setBool(prefKey, v);
  static Future<bool> disclosureAccepted() =>
      Settings.getBool(disclosureKey, false);
  static Future<void> acceptDisclosure() => Settings.setBool(disclosureKey, true);
  static Future<WakeLevel> level() async =>
      WakeLevelX.parse(await Settings.getString(levelKey));
  static Future<void> setLevel(WakeLevel l) => Settings.setString(levelKey, l.key);

  static Future<VaWakeConfig> fetchConfig(ApiClient api) async {
    try {
      final j = await api.getJson('/voice/config');
      unawaited(Settings.setString(_cfgCacheKey, jsonEncode(j)));
      return VaWakeConfig.fromJson(j);
    } catch (_) {
      return cachedConfig();
    }
  }

  static Future<VaWakeConfig> cachedConfig() async {
    try {
      final s = await Settings.getString(_cfgCacheKey);
      if (s == null || s.isEmpty) return const VaWakeConfig();
      return VaWakeConfig.fromJson(
          (jsonDecode(s) as Map).cast<String, dynamic>());
    } catch (_) {
      return const VaWakeConfig();
    }
  }

  static Future<WakeStatus> status() async =>
      WakeStatus.fromNative(await VaNative.wakeStatus());

  /// Download the model files once (a few MB, never in the APK) into app
  /// storage and verify each sha256 on the phone. Returns role -> path, or
  /// null when a download / check failed.
  static Future<Map<String, String>?> ensureModels(VaWakeConfig c,
      {void Function(double)? onProgress}) async {
    if (!c.available) return null;
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/wakeword');
      if (!await dir.exists()) await dir.create(recursive: true);
      final out = <String, String>{};
      var done = 0;
      final total = c.totalBytes == 0 ? 1 : c.totalBytes;
      for (final f in c.files) {
        final file = File('${dir.path}/${f.name}');
        final ok = await file.exists() &&
            (await VaNative.sha256(file.path)) == f.sha256;
        if (!ok) {
          final r = await http
              .get(AppConfig.api('/voice/wake-model/${f.name}'))
              .timeout(const Duration(seconds: 60));
          if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
          final tmp = File('${file.path}.part');
          await tmp.writeAsBytes(r.bodyBytes, flush: true);
          if ((await VaNative.sha256(tmp.path)) != f.sha256) {
            await tmp.delete();
            return null;
          }
          await tmp.rename(file.path);
        }
        out[f.role] = file.path;
        done += f.size;
        onProgress?.call(done / total);
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Native notification / boot texts in the user's language.
  static Map<String, String> texts(AppLocalizations t) => {
        'channel': t.vaWkNotifChannel,
        'title': t.vaWkNotifTitle,
        'body': t.vaWkNotifBody,
        'pausedTitle': t.vaWkNotifPausedTitle,
        'pausedUser': t.vaWkNotifPausedUser,
        'pausedBattery': t.vaWkStatusPausedBattery,
        'pausedSaver': t.vaWkStatusPausedSaver,
        'pausedLocked': t.vaWkStatusPausedLocked,
        'pausedCall': t.vaWkStatusPausedCall,
        'pausedMic': t.vaWkStatusPausedMic,
        'pausedWake': t.vaWkStatusPausedWake,
        'pause': t.vaWkNotifPause,
        'resume': t.vaWkNotifResume,
        'off': t.vaWkNotifOff,
        'resumeTitle': t.vaWkNotifResumeTitle,
        'resumeBody': t.vaWkNotifResumeBody,
        'tapText': t.vaWakeTapToTalk,
      };

  /// The JSON handed to the native service (also checked by tests).
  static String nativeConfig(VaWakeConfig c, Map<String, String> paths,
          WakeLevel level, Map<String, String> texts, {bool lockedOk = false}) =>
      jsonEncode({
        'backend': c.backend,
        'windowSamples': c.windowSamples,
        'frames': c.frames,
        'files': paths,
        'sha256': {for (final f in c.files) f.role: f.sha256},
        'thresholds': c.thresholds.toJson(),
        'level': level.key,
        'lockedOk': lockedOk,
        'texts': texts,
      });

  /// Start listening (Assisto must be on screen). Returns the native result
  /// ('running' | 'engine_missing' | 'error:…') or 'error:download'.
  static Future<String?> start(
      VaWakeConfig c, WakeLevel level, Map<String, String> texts,
      {void Function(double)? onProgress}) async {
    if (!c.available) return 'error:config';
    final paths = await ensureModels(c, onProgress: onProgress);
    if (paths == null) return 'error:download';
    final r = await VaNative.wakeStart(
        nativeConfig(c, paths, level, texts, lockedOk: await lockedOk()));
    if (r == 'running') await setWanted(true);
    return r;
  }

  static Future<void> stop() async {
    await VaNative.wakeStop();
    await setWanted(false);
  }

  // ---- survival: restart when the app opens ---------------------------------

  static bool _busy = false;
  static DateTime? _lastTry;

  /// Called after the first frame and on every resume. If the user left
  /// "Hey Assisto" ON and Android stopped it (OEM kill, reboot, update),
  /// start it again now that Assisto is in the foreground — the only moment
  /// Android allows a microphone service to start. Throttled, guarded,
  /// never requests a permission and never shows UI.
  static Future<void> maybeRestart(BuildContext context) async {
    if (_busy) return;
    final now = DateTime.now();
    if (_lastTry != null &&
        now.difference(_lastTry!) < const Duration(seconds: 30)) {
      return;
    }
    _busy = true;
    _lastTry = now;
    try {
      if (!await wanted()) return;
      await Future.delayed(const Duration(seconds: 3)); // off the cold start
      if (!context.mounted) return;
      final app = context.read<AppState>();
      if (!app.loggedIn) return;
      final st = await status();
      if (st.run == WakeRun.engineMissing || st.run == WakeRun.unknown) return;
      if (st.isOn) return;
      if (!st.wanted && await VaNative.wakeHasNativeChoice()) {
        // turned off from the notification -> respect it
        await setWanted(false);
        return;
      }
      if (!await disclosureAccepted()) return;
      if (!await Permission.microphone.status.isGranted) return;
      if (!context.mounted) return;
      final t = AppLocalizations.of(context);
      final cfg = await fetchConfig(app.api);
      if (!cfg.available) return;
      await start(cfg, await level(), texts(t));
    } catch (_) {
      // never break launch / resume
    } finally {
      _busy = false;
    }
  }
}
