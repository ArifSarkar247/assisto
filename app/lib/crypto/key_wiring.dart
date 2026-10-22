import 'dart:async';

import 'package:flutter/widgets.dart';

import '../api.dart';
import '../calls/call_runtime.dart';
import '../messaging/outbox.dart';
import '../state.dart';
import 'key_service.dart';

/// e2-keys — glue between AppState and the key plumbing. Called ONCE from
/// main.dart after the first frame (guarded; never on the cold-start path):
///   * publishes the public key at app start and at every login;
///   * publishes again on any My Circle accept (ApiClient.onRequestAccepted);
///   * listens for `key.published` on the shared real-time loop and starts
///     the outbox (flush on key arrival / resume / retry timer).
/// Everything is try/catch-wrapped: a failure here can never take the app
/// down, and none of it is ever shown to the user.
class KeyWiring with WidgetsBindingObserver {
  KeyWiring._();
  static final KeyWiring instance = KeyWiring._();

  bool _started = false;
  AppState? _app;
  StreamSubscription<dynamic>? _rtSub;
  Object? _outboxFor;

  void start(AppState app) {
    if (_started) return;
    _started = true;
    _app = app;
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
    ApiClient.onRequestAccepted = () {
      final a = _app;
      if (a == null || !a.loggedIn) return;
      unawaited(KeyService.instance.onRequestAccepted(a.api.postJson));
    };
    KeyService.instance.attach(
      isReady: () => app.loggedIn && !app.loading,
      userId: () => app.user?.id,
      post: () => app.api.postJson,
      listen: (cb) => app.addListener(() {
        cb();
        _maybeStartOutbox();
      }),
    );
    _maybeStartOutbox();
  }

  void _maybeStartOutbox() {
    final app = _app;
    if (app == null) return;
    try {
      if (!app.loggedIn || app.loading) {
        _outboxFor = null;
        return;
      }
      final uid = app.user?.id;
      if (uid == null || uid == _outboxFor) return;
      _outboxFor = uid;
      // key.published rides the app's ONE real-time loop (c2-calls).
      _rtSub?.cancel();
      try {
        _rtSub = CallRuntime.instance.transportFor(app).events.listen(
            (e) => KeyService.instance.onRealtime(e.topic, e.payload),
            onError: (_) {});
      } catch (_) {}
      Outbox.instance.start(
        transport: FnOutboxTransport(
            get: (p) => app.api.getJson(p),
            post: (p, b) => app.api.postJson(p, b)),
        identity: () async {
          try {
            return await KeyService.instance.identity();
          } catch (_) {
            return null;
          }
        },
        keyEvents: KeyService.instance.keyEvents.stream,
      );
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(Outbox.instance.kick());
    }
  }

  /// Silent FCM data push while the app is OPEN (push_service foreground).
  /// Returns true when the payload was a key kind (nothing is drawn).
  bool onForegroundPush(String kind, Map<String, dynamic> data) {
    try {
      if (kind == 'key_request') {
        final a = _app;
        if (a != null && a.loggedIn) {
          unawaited(KeyService.instance.onKeyRequest(a.api.postJson));
        } else {
          unawaited(KeyService.publishFromBackground());
        }
        return true;
      }
      if (kind == 'key_ready') {
        final id = int.tryParse('${data['chat_id'] ?? ''}');
        KeyService.instance.keyEvents
            .add({'chat': 'member:${id ?? 0}', 'push': true});
        unawaited(Outbox.instance.kick(onlyChat: id));
        return true;
      }
    } catch (_) {}
    return false;
  }
}

/// Background isolate (FCM handler): true when handled (draw nothing).
Future<bool> handleKeyPushInBackground(Map<String, dynamic> data) async {
  final kind = '${data['kind'] ?? ''}';
  try {
    if (kind == 'key_request') {
      await KeyService.publishFromBackground();
      return true;
    }
    if (kind == 'key_ready') {
      await Outbox.flushFromBackground(
          chatId: int.tryParse('${data['chat_id'] ?? ''}'));
      return true;
    }
  } catch (_) {
    return kind == 'key_request' || kind == 'key_ready';
  }
  return false;
}
