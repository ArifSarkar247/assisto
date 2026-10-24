import 'package:flutter/foundation.dart';

import 'api.dart';
import 'state.dart';
import 'notifications.dart';

/// Realme/ColorOS-safe family & proactive alerts WITHOUT background services.
///
/// WorkManager is removed (it crashed on launch and background exec is throttled
/// on these phones anyway). Instead we poll `/alerts` whenever the app opens or
/// returns to the foreground, and raise a local notification for anything new
/// and high-severity. Deduped so the same alert never nags twice.
///
/// at-falsealarm: when FCM push is working on this phone ([pushOkKey], set by
/// PushService after a successful registration) the server ALREADY pushed
/// every high alert, so the poller only updates its seen-set and shows
/// nothing — the owner is never alerted twice for the same event. Local
/// notifications are the fallback only for phones where push is not working.
class AlertPoller {
  static bool _busy = false;

  /// Settings key: true while this phone has a working FCM registration.
  static const pushOkKey = 'push_ok';

  /// Swappable for tests.
  @visibleForTesting
  static Future<void> Function(int id, String title, String body) show =
      Notifications.show;

  static Future<void> poll(ApiClient api) async {
    if (_busy || api.token == null) return;
    _busy = true;
    try {
      final alerts = await api.alertsList();
      final high = alerts.where((a) => a['severity'] == 'high').toList();
      final seen =
          (await Settings.getString('alert_seen') ?? '').split('|').toSet();
      final pushOk = await Settings.getBool(pushOkKey, false);
      final current = <String>{};
      var id = 9100;
      for (final a in high) {
        final sig = (a['text'] ?? '').toString();
        if (sig.isEmpty) continue;
        current.add(sig);
        if (!seen.contains(sig) && !pushOk) {
          await show(id++, 'Assisto', sig);
        }
      }
      // Remember only what's currently active, so a cleared-then-returning
      // alert can notify again later.
      await Settings.setString('alert_seen', current.join('|'));
    } catch (_) {
      // offline / server down — try again next resume
    } finally {
      _busy = false;
    }
  }
}
