import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import '../messaging/receipt_ack.dart';
import '../crypto/key_wiring.dart';
import 'firebase_lazy.dart';
import 'push_bridge.dart';
import 'push_notifier.dart';
import 'push_payload.dart';
import 'family_alert_receipt.dart'; // family100

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
      // sc1: shared single-flight lazy init (push + crash reporting)
      if (!await FirebaseLazy.ensure()) throw StateError('no firebase');
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
  // x2-ticks: DELIVERED ✓✓ first — by message id, with the stored token,
  // queued if offline — so a failed pull / decrypt / draw can never leave
  // the sender on ✓. A silent `msg_sync` ping (muted chat) stops here.
  try {
    if (await ackPushDelivery(message.data)) return;
  } catch (_) {}
  // family100: an SOS / family alert reached this phone -> receipt (sender
  // sees "received"; delivery time is measured). Never blocks drawing it.
  unawaited(ackFamilyAlertReceipt(message.data));
  try {
    final p = PushPayload.fromData(message.data);
    // e2-keys: a SILENT key push — publish our public key / flush the outbox
    // in this isolate, and draw nothing.
    if (await handleKeyPushInBackground(message.data)) return;
    // c3-msg: a message push is data-only — pull the ciphertext window
    // (= delivered ✓✓ ack), decrypt ON THIS DEVICE and draw the
    // MessagingStyle conversation. Any failure falls back to the plain
    // title/body notification so a message is never lost.
    if (p.kind == 'message' && message.notification == null) {
      if (await PushNotifier.showMessageFromBackground(message.data)) return;
    }
    if (p.isDataOnly || message.notification == null) {
      await PushNotifier.showFromBackground(message.data);
    }
  } catch (_) {}
}
