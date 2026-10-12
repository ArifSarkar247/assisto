import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:workmanager/workmanager.dart';

import 'config.dart';
import 'notifications.dart';

/// Family / proactive alerts WITHOUT Firebase.
///
/// WorkManager wakes a background isolate roughly hourly, reads the saved
/// login token, asks the backend what's urgent (/alerts), and raises a local
/// notification for anything high-severity (e.g. a medicine missed, a document
/// about to expire). Everything is wrapped so a failure is silent and never
/// disturbs the user. No external action is ever taken here — read-only.
const String familyPollTask = 'assisto-family-poll';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      const secure = FlutterSecureStorage();
      final token = await secure.read(key: 'token');
      if (token == null) return true; // logged out — nothing to do
      final r = await http
          .get(AppConfig.api('/alerts'),
              headers: {'Authorization': 'Token $token'})
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return true;
      final alerts = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
      await Notifications.init();
      var id = 9000;
      for (final a in alerts) {
        if (a['severity'] == 'high') {
          await Notifications.show(id++, 'Assisto', (a['text'] ?? '').toString());
        }
      }
      return true;
    } catch (_) {
      return true; // never fail loudly
    }
  });
}

class Background {
  static bool _started = false;

  /// Call once the user is logged in.
  static Future<void> start() async {
    if (_started) return;
    try {
      await Workmanager().initialize(callbackDispatcher);
      await Workmanager().registerPeriodicTask(
        familyPollTask,
        familyPollTask,
        frequency: const Duration(hours: 1),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
      );
      _started = true;
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await Workmanager().cancelByUniqueName(familyPollTask);
    } catch (_) {}
    _started = false;
  }
}
