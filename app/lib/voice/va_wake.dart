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
  /// One or more https keyword files ("Hey Assisto", "Hi Assisto").
  final List<String> keywordUrls;
  final double sensitivity;
  const VaWakeConfig({
    this.available = false,
    this.accessKey = '',
    this.keywordUrls = const [],
    this.sensitivity = 0.6,
  });

  factory VaWakeConfig.fromJson(Map<String, dynamic> j) {
    final w = (j['wake'] is Map) ? (j['wake'] as Map).cast<String, dynamic>() : j;
    final s = w['sensitivity'];
    return VaWakeConfig(
      available: w['available'] == true,
      accessKey: (w['access_key'] ?? '').toString(),
      keywordUrls: [
        ...((w['keyword_urls'] is List) ? (w['keyword_urls'] as List) : const [])
            .map((e) => '$e'),
        if (w['keyword_urls'] is! List)
          ...(w['keyword_url'] ?? '').toString().split(','),
      ].map((e) => e.trim()).where((e) => e.startsWith('https://')).toList(),
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
  static Future<String?> keywordFile(String url, int n) async {
    if (!url.startsWith('https://')) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/assisto_wake_$n.ppn');
      final tag = File('${dir.path}/assisto_wake_$n.url');
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
    if (!c.available || c.accessKey.isEmpty || c.keywordUrls.isEmpty) {
      return 'error:config';
    }
    final paths = <String>[];
    for (var i = 0; i < c.keywordUrls.length && i < 4; i++) {
      final p = await keywordFile(c.keywordUrls[i], i);
      if (p == null) return 'error:download';
      paths.add(p);
    }
    return VaNative.wakeStart(
      accessKey: c.accessKey,
      keywordPath: paths.join('|'),
      sensitivity: c.sensitivity,
      title: title,
      body: body,
      stopLabel: stopLabel,
      tapText: tapText,
    );
  }
}
