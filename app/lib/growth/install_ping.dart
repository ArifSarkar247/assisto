import 'dart:math';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state.dart';
import 'growth_api.dart';

/// p5-growth: the anonymous "first app open" marker for the owner funnel.
///
/// A random install id is made once and kept in SharedPreferences (it is gone
/// after an uninstall / clear-data, so a reinstall counts as a new install).
/// It is sent ONCE without an account, and ONCE more after the user is signed
/// in (so the server can tell installs that became accounts). The server keeps
/// only a hash. Pure Dart + HTTP, called seconds after the first frame, every
/// step guarded: it can never block or crash the launch. No native plugin, no
/// startup ContentProvider, no background work.
class InstallPing {
  static const _kId = 'p5_install_id';
  static const _kSent = 'p5_install_sent';
  static const _kLinked = 'p5_install_linked';
  static bool _running = false;

  /// The stable per-install id (also used as the device id for invite claims).
  static Future<String> installId() async {
    final p = await SharedPreferences.getInstance();
    var id = p.getString(_kId) ?? '';
    if (id.length < 16) {
      final r = Random.secure();
      id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      await p.setString(_kId, id);
    }
    return id;
  }

  static Future<void> run(AppState state) async {
    if (_running) return;
    _running = true;
    try {
      final p = await SharedPreferences.getInstance();
      final sent = p.getBool(_kSent) ?? false;
      final linked = p.getBool(_kLinked) ?? false;
      final signedIn = state.api.token != null;
      if (sent && (linked || !signedIn)) return;
      final id = await installId();
      String ver = '';
      try {
        final info = await PackageInfo.fromPlatform()
            .timeout(const Duration(seconds: 3));
        ver = '${info.version}+${info.buildNumber}';
      } catch (_) {}
      final r = await state.api
          .growthInstall(id, appVersion: ver)
          .timeout(const Duration(seconds: 10));
      if (r['_status'] == 200) {
        await p.setBool(_kSent, true);
        if (signedIn) await p.setBool(_kLinked, true);
      }
    } catch (_) {
      // offline / server down: try again on a later launch
    } finally {
      _running = false;
    }
  }
}
