import 'dart:async';

/// The seam between Assisto's push logic and the Firebase SDK.
///
/// Everything above this interface (routing, notifications, token
/// registration, settings UI) is plain Dart and unit-tested. The real
/// implementation is `firebase_push_bridge.dart` (needs the firebase_core +
/// firebase_messaging pubspec entries from `.phaseB/proposals/a6-leftovers.md`);
/// until it is bound in `push_binding.dart`, [NoopPushBridge] keeps push
/// silently off — the app behaves exactly as before (foreground polling).
abstract class PushBridge {
  /// Initialise Firebase + messaging. Returns false (never throws) when
  /// Firebase isn't configured in this build (no google-services.json).
  Future<bool> init();

  /// The FCM registration token, or null.
  Future<String?> getToken();

  /// Drop the token (logout) so this install stops receiving pushes.
  Future<void> deleteToken();

  Stream<String> get onTokenRefresh;

  /// Data of messages received while the app is in the FOREGROUND.
  Stream<Map<String, dynamic>> get onMessage;

  /// Data of a system-tray notification the user tapped while the app was in
  /// the background (FCM drew it from the `notification` block).
  Stream<Map<String, dynamic>> get onMessageOpenedApp;

  /// Data of the notification that cold-started the app, if any.
  Future<Map<String, dynamic>?> getInitialMessage();

  /// True once [init] succeeded.
  bool get available;
}

class NoopPushBridge implements PushBridge {
  const NoopPushBridge();

  @override
  Future<bool> init() async => false;
  @override
  Future<String?> getToken() async => null;
  @override
  Future<void> deleteToken() async {}
  @override
  Stream<String> get onTokenRefresh => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get onMessage => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get onMessageOpenedApp => const Stream.empty();
  @override
  Future<Map<String, dynamic>?> getInitialMessage() async => null;
  @override
  bool get available => false;
}
