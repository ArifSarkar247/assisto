import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import '../state.dart';
import 'va_native.dart';

/// Server-side wake-word configuration (owner's Integrations page →
/// "Picovoice wake word"). Key-gated: [available] is false until the owner
/// saves an AccessKey + a "Hey Assisto" keyword file URL.
class VaWakeConfig {
  final bool available;
  final String accessKey;
  final String keywordUrl;
  final double sensitivity;
  const VaWakeConfig({
    this.available = false,
    this.accessKey = '',
    this.keywordUrl = '',
    this.sensitivity = 0.6,
  });

  factory VaWakeConfig.fromJson(Map<String, dynamic> j) {
    final w = (j['wake'] is Map) ? (j['wake'] as Map).cast<String, dynamic>() : j;
    final s = w['sensitivity'];
    return VaWakeConfig(
      available: w['available'] == true,
      accessKey: (w['access_key'] ?? '').toString(),
      keywordUrl: (w['keyword_url'] ?? '').toString(),
      sensitivity: s is num ? s.toDouble().clamp(0.1, 0.95) : 0.6,
    );
  }
}

/// Wake-word state machine for the settings toggle. OFF by default; nothing
/// here runs at app launch.
class VaWake {
  VaWake._();

  static const prefKey = 'va_wake_on'; // bool, default false
  static const ttsKey = 'va_tts_on'; // bool, default true

  static Future<bool> wanted() => Settings.getBool(prefKey, false);
  static Future<void> setWanted(bool v) => Settings.setBool(prefKey, v);

  static Future<VaWakeConfig> fetchConfig(ApiClient api) async {
    try {
      return VaWakeConfig.fromJson(await api.getJson('/voice/config'));
    } catch (_) {
      return const VaWakeConfig();
    }
  }

  /// Download the keyword file once (a few KB) into app storage. Never
  /// bundled in the APK. Returns the local path or null.
  static Future<String?> keywordFile(String url) async {
    if (!url.startsWith('https://')) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/hey_assisto.ppn');
      final tag = File('${dir.path}/hey_assisto.url');
      if (await f.exists() &&
          await tag.exists() &&
          (await tag.readAsString()) == url &&
          await f.length() > 0) {
        return f.path;
      }
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      await f.writeAsBytes(r.bodyBytes, flush: true);
      await tag.writeAsString(url, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// Start listening. Returns the native status string
  /// ('running' | 'engine_missing' | 'error:…' | null when native missing).
  static Future<String?> start(VaWakeConfig c,
      {required String title,
      required String body,
      required String stopLabel,
      required String tapText}) async {
    if (!c.available || c.accessKey.isEmpty) return 'error:config';
    final path = await keywordFile(c.keywordUrl);
    if (path == null) return 'error:download';
    return VaNative.wakeStart(
      accessKey: c.accessKey,
      keywordPath: path,
      sensitivity: c.sensitivity,
      title: title,
      body: body,
      stopLabel: stopLabel,
      tapText: tapText,
    );
  }
}
