import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import 'push_bridge.dart';
import 'push_notifier.dart';
import 'push_payload.dart';

/// Firebase-backed [PushBridge].
///
/// KEY-GATED: Firebase is configured by `google-services.json`, which CI
/// decodes from the GOOGLE_SERVICES_JSON_B64 secret and the
/// com.google.gms.google-services Gradle plugin turns into string resources.
/// Without the secret those resources don't exist, [Firebase.initializeApp]
/// throws, we catch it, and push stays silently off.
///
/// LAZY: nothing here runs at launch — PushService calls [init] after the
/// first frame. The auto-init FirebaseInitProvider is removed in the manifest
/// (ColorOS startup-provider crash history); the native
/// `push/AssistoFcmService.kt` initialises Firebase itself when a push
/// arrives with the app closed.
class FirebasePushBridge implements PushBridge {
  bool _ok = false;

  @override
  bool get available => _ok;

  @override
  Future<bool> init() async {
    if (_ok) return true;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      FirebaseMessaging.onBackgroundMessage(assistoFcmBackgroundHandler);
      // We draw foreground notifications ourselves (PushNotifier), so FCM must
      // not ALSO show its own heads-up for notification messages.
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
              alert: false, badge: false, sound: false);
      _ok = true;
    } catch (e) {
      if (kDebugMode) debugPrint('push: Firebase not configured ($e)');
      _ok = false;
    }
    return _ok;
  }

  @override
  Future<String?> getToken() async {
    if (!_ok) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> deleteToken() async {
    if (!_ok) return;
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  @override
  Stream<String> get onTokenRefresh =>
      _ok ? FirebaseMessaging.instance.onTokenRefresh : const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onMessage => _ok
      ? FirebaseMessaging.onMessage.map((m) => _withNotification(m))
      : const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get onMessageOpenedApp => _ok
      ? FirebaseMessaging.onMessageOpenedApp.map((m) => _withNotification(m))
      : const Stream.empty();

  @override
  Future<Map<String, dynamic>?> getInitialMessage() async {
    if (!_ok) return null;
    try {
      final m = await FirebaseMessaging.instance.getInitialMessage();
      return m == null ? null : _withNotification(m);
    } catch (_) {
      return null;
    }
  }
}

/// The data map, with title/body filled from the `notification` block when the
/// data copy is missing (the backend sends both; this is belt and braces).
Map<String, dynamic> _withNotification(RemoteMessage m) {
  final d = Map<String, dynamic>.from(m.data);
  final n = m.notification;
  if (n != null) {
    d.putIfAbsent('title', () => n.title ?? '');
    d.putIfAbsent('body', () => n.body ?? '');
  }
  return d;
}

/// FCM message while the app is in the background or killed. Runs in its own
/// isolate. Notification messages (message / reminder / alerts) are already
/// drawn by the system tray from their `notification` block, so we only draw
/// the DATA-ONLY kinds: call (full-screen ring), call_cancel (dismiss) and SOS.
@pragma('vm:entry-point')
Future<void> assistoFcmBackgroundHandler(RemoteMessage message) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (_) {}
  try {
    final p = PushPayload.fromData(message.data);
    if (p.isDataOnly || message.notification == null) {
      await PushNotifier.showFromBackground(message.data);
    }
  } catch (_) {}
}
