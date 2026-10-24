import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'config.dart';
import 'growth/install_ping.dart';

/// own-device (owner 24 Oct): the stable id of THIS install, sent on every API
/// request as `X-Device-Id` and handed to the native anti-theft engine so its
/// ingest carries the same id. The server can then tell "a request from the
/// protected phone itself" (it is alive -> resolve a went-dark alert) from a
/// request from another phone or the web.
///
/// It is a one-way hash of the random p5 install id (SharedPreferences) —
/// never a hardware id (no ANDROID_ID / IMEI), gone after uninstall /
/// clear-data. Loading is guarded (no timers) and never throws; until it is loaded the
/// header is simply absent.
class DeviceId {
  static Future<String>? _loading;

  /// The id once loaded (also mirrored into [AppConfig.deviceId]).
  static String? get current => AppConfig.deviceId;

  /// sha256("assisto-device:" + installId), first 32 hex chars.
  static String derive(String installId) =>
      sha256.convert(utf8.encode('assisto-device:$installId'))
          .toString()
          .substring(0, 32);

  /// The id if already loaded, else '' — and starts loading it in the
  /// background (never blocks a caller, e.g. the native engine bridge).
  static String now() {
    final have = AppConfig.deviceId;
    if (have != null && have.isNotEmpty) return have;
    unawaited(get());
    return '';
  }

  /// Load (once) and return the id; '' on any error. Never throws.
  static Future<String> get() {
    final have = AppConfig.deviceId;
    if (have != null && have.isNotEmpty) return Future.value(have);
    return _loading ??= _load();
  }

  static Future<String> _load() async {
    try {
      final raw = await InstallPing.installId();
      if (raw.isEmpty) return '';
      final id = derive(raw);
      AppConfig.deviceId = id;
      return id;
    } catch (_) {
      return '';
    } finally {
      _loading = null;
    }
  }
}
