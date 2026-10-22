import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'config.dart';

class UpdateInfo {
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String notes;
  UpdateInfo(this.versionCode, this.versionName, this.apkUrl, this.notes);
}

/// Asks the backend if a newer APK exists and can download + launch its install.
class Updater extends ChangeNotifier {
  UpdateInfo? available;
  bool downloading = false;
  double progress = 0;
  String? error;

  Future<void> check() async {
    if (AppConfig.playStore) return; // l1-launch: Play builds update via Play only
    try {
      final r = await http
          .get(AppConfig.api('/app/latest'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final latest = (j['version_code'] ?? 0) as int;
      final apk = (j['apk_url'] ?? '') as String;
      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      if (latest > current && apk.isNotEmpty) {
        available = UpdateInfo(latest, (j['version_name'] ?? '') as String, apk,
            (j['notes'] ?? '') as String);
        notifyListeners();
      }
    } catch (_) {
      // offline / not reachable — ignore quietly
    }
  }

  void dismiss() {
    available = null;
    notifyListeners();
  }

  Future<void> downloadAndInstall() async {
    final info = available;
    if (info == null || downloading) return;
    downloading = true;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      final resp =
          await http.Client().send(http.Request('GET', Uri.parse(info.apkUrl)));
      final total = resp.contentLength ?? 0;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/assisto-update.apk');
      final sink = file.openWrite();
      int received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          progress = received / total;
          notifyListeners();
        }
      }
      await sink.close();
      // Launches the Android package installer (needs REQUEST_INSTALL_PACKAGES).
      await OpenFilex.open(file.path,
          type: 'application/vnd.android.package-archive');
    } catch (e) {
      error = e.toString();
    } finally {
      downloading = false;
      notifyListeners();
    }
  }
}
