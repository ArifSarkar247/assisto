import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../calls/call_runtime.dart';
import '../messaging/media/media_outbox.dart';
import '../messaging/outbox.dart';
import '../push/push_service.dart' show appNavigatorKey;
import '../screens/e2_restore_screen.dart';
import '../state.dart';
import 'history_reshare.dart';
import 'identity_vault.dart';
import 'key_backup.dart';
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

  bool _hooks = false;

  /// e2e-recover: wire key backup / restore gate / history re-share to the
  /// app's ApiClient. Synchronous + cheap (no I/O); called right after the
  /// first frame, BEFORE any sign-in can create a key, and again by [start].
  void installRecoveryHooks(AppState app) {
    if (_hooks) return;
    _hooks = true;
    try {
      final kb = KeyBackupService.instance;
      kb.get = (p) => app.api.getJson(p);
      kb.post = (p, b) async {
        final r = await app.api.postJsonRaw(p, b);
        final st = (r['_status'] as num?)?.toInt() ?? 0;
        if (st >= 200 && st < 300) return r;
        throw BackupHttpError(st, r);
      };
      kb.presenter = (meta) async {
        final nav = appNavigatorKey.currentState;
        if (nav == null) return;
        await nav.push<bool>(MaterialPageRoute(
            builder: (_) => E2RestoreScreen(service: kb, meta: meta)));
      };
      final v = IdentityVault.instance;
      v.beforeCreate = () => app.api.token == null ? Future.value() : kb.gate();
      v.onNewKey = (_) => unawaited(kb.backupNow());
      final hr = HistoryReshare.instance;
      hr.get = (p) => app.api.getJson(p);
      hr.post = (p, b) => app.api.postJson(p, b);
    } catch (_) {}
  }

  /// e2e-recover: re-share chat history my contacts' phones asked for
  /// (their key changed / they could not open a message). Background,
  /// throttled, guarded.
  void _serveReshare({bool force = false}) {
    final a = _app;
    if (a == null || !a.loggedIn || a.loading) return;
    unawaited(HistoryReshare.instance.serve(force: force));
  }

  void start(AppState app) {
    if (_started) return;
    _started = true;
    _app = app;
    installRecoveryHooks(app);
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
        _rtSub = CallRuntime.instance.transportFor(app).events.listen((e) {
          KeyService.instance.onRealtime(e.topic, e.payload);
          _onRecoveryEvent(e.topic, e.payload);
        }, onError: (_) {});
      } catch (_) {}
      // e2e-recover: serve waiting re-share requests a little after start.
      unawaited(Future<void>.delayed(
          const Duration(seconds: 12), () => _serveReshare(force: true)));
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
      // md1: queued photo / voice / document sends resume after a restart
      // (prefs read only; nothing native here).
      MediaOutbox.instance.identity = () async {
        try {
          return await KeyService.instance.identity();
        } catch (_) {
          return null;
        }
      };
      unawaited(MediaOutbox.instance.kick());
    } catch (_) {}
  }

  void _onRecoveryEvent(String topic, Map<String, dynamic> payload) {
    try {
      if (topic == 'e2.resend') _serveReshare(force: true);
      if (topic == 'e2.copies') {
        KeyService.instance.keyEvents
            .add({'chat': '${payload['chat'] ?? ''}', 'copies': true});
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _serveReshare();
      unawaited(Outbox.instance.kick());
      if (MediaOutbox.instance.identity != null) {
        unawaited(MediaOutbox.instance.kick()); // md1
      }
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
      if (kind == 'e2_resend') {
        _serveReshare(force: true);
        return true;
      }
      if (kind == 'key_ready') {
        final id = int.tryParse('${data['chat_id'] ?? ''}');
        KeyService.instance.keyEvents
            .add({'chat': 'member:${id ?? 0}', 'push': true});
        unawaited(Outbox.instance.kick(onlyChat: id));
        if (MediaOutbox.instance.identity != null) {
          unawaited(MediaOutbox.instance.kick()); // md1: media waits on keys too
        }
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
    // e2e-recover: re-share needs the full chat context; it runs when the
    // app is next opened. Nothing is drawn.
    if (kind == 'e2_resend') return true;
    if (kind == 'key_ready') {
      await Outbox.flushFromBackground(
          chatId: int.tryParse('${data['chat_id'] ?? ''}'));
      return true;
    }
  } catch (_) {
    return kind == 'key_request' || kind == 'key_ready' || kind == 'e2_resend';
  }
  return false;
}
