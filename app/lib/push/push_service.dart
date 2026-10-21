import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notifications.dart';
import '../state.dart';
import '../widgets/chatnav.dart';
import '../screens/circle_call_screen.dart';
import 'incoming_call_screen.dart';
import 'push_api.dart';
import 'push_binding.dart';
import 'push_bridge.dart';
import 'push_notifier.dart';
import 'push_payload.dart';

/// App-wide navigator, so a tapped push can open a screen from anywhere.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Orchestrates FCM on the UI isolate: lazy init, token registration with the
/// backend, foreground display, tap routing and logout cleanup.
///
/// LAZY + CRASH-GUARDED: [start] is called after the first frame (and is a
/// no-op in startup safe-mode); every step has its own try/catch, so a push
/// failure can never take the app down. Without Firebase in the build
/// ([NoopPushBridge]) only the local-notification parts run.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  PushBridge bridge = createPushBridge();

  AppState? _app;
  GlobalKey<NavigatorState>? _nav;
  bool _started = false;
  String? _registeredToken;
  bool _wasLoggedIn = false;

  /// A tap that arrived before the user/session was ready.
  ({PushPayload payload, String? action})? _pending;

  final _subs = <StreamSubscription<dynamic>>[];

  /// Fires the call_id of every call_cancel we receive (the ringing screen
  /// listens and closes itself).
  final StreamController<String> _cancelled =
      StreamController<String>.broadcast();
  Stream<String> get callCancelled => _cancelled.stream;

  /// Did Firebase initialise in this build? (Settings shows it honestly.)
  final ValueNotifier<bool> available = ValueNotifier<bool>(false);

  static const _permAskedKey = 'push_perm_asked_v1';

  Future<void> start(AppState app,
      {GlobalKey<NavigatorState>? navigatorKey}) async {
    if (_started) return;
    _started = true;
    _app = app;
    _nav = navigatorKey ?? appNavigatorKey;
    _wasLoggedIn = app.loggedIn;

    // 1) Local-notification taps / actions (UI isolate).
    Notifications.onResponse = _onLocalResponse;
    try {
      await PushNotifier.createChannels(_lang());
    } catch (_) {}
    try {
      final launch = await Notifications.launchResponse();
      if (launch != null) _onLocalResponse(launch);
    } catch (_) {}

    // 2) Firebase (key-gated by google-services.json in the build).
    bool ok = false;
    try {
      ok = await bridge.init();
    } catch (_) {
      ok = false;
    }
    available.value = ok;
    if (ok) {
      try {
        _subs.add(bridge.onMessage.listen(_onForeground, onError: (_) {}));
        _subs.add(bridge.onMessageOpenedApp
            .listen((d) => _open(PushPayload.fromData(d), null),
                onError: (_) {}));
        _subs.add(bridge.onTokenRefresh
            .listen((t) => unawaited(_register(t)), onError: (_) {}));
        final initial = await bridge.getInitialMessage();
        if (initial != null) _open(PushPayload.fromData(initial), null);
      } catch (_) {}
    }

    app.addListener(_onAppChanged);
    _onAppChanged();
  }

  String _lang() {
    final l = _app?.locale?.languageCode;
    return l == 'en' ? 'en' : 'bn';
  }

  void _onAppChanged() {
    final app = _app;
    if (app == null) return;
    final now = app.loggedIn;
    if (now && !_wasLoggedIn) _registeredToken = null; // new session
    _wasLoggedIn = now;
    if (!now || app.loading) return;
    unawaited(_register(null));
    unawaited(_maybeAskPermission());
    final p = _pending;
    if (p != null) {
      _pending = null;
      _open(p.payload, p.action);
    }
  }

  Future<void> _register(String? token) async {
    final app = _app;
    if (app == null || !app.loggedIn || !available.value) return;
    try {
      token ??= await bridge.getToken();
      if (token == null || token.isEmpty || token == _registeredToken) return;
      String ver = '';
      try {
        final info = await PackageInfo.fromPlatform();
        ver = '${info.version}+${info.buildNumber}';
      } catch (_) {}
      await app.api.pushRegister(token, appVersion: ver);
      _registeredToken = token;
    } catch (e) {
      if (kDebugMode) debugPrint('push register failed: $e');
    }
  }

  /// Ask for POST_NOTIFICATIONS once per install — after sign-in, a little
  /// after the home screen settled (never on the cold-start path).
  Future<void> _maybeAskPermission() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_permAskedKey) == true) return;
      await Future<void>.delayed(const Duration(seconds: 6));
      if (await Notifications.isEnabled()) {
        await prefs.setBool(_permAskedKey, true);
        return;
      }
      await prefs.setBool(_permAskedKey, true);
      await Notifications.requestPermission();
    } catch (_) {}
  }

  /// Call BEFORE the auth token is cleared so the server stops sending this
  /// account's pushes to this phone.
  Future<void> onLogout() async {
    final app = _app;
    final tok = _registeredToken;
    _registeredToken = null;
    if (app != null && tok != null) {
      try {
        await app.api.pushUnregister(tok).timeout(const Duration(seconds: 6));
      } catch (_) {}
    }
    try {
      await bridge.deleteToken();
    } catch (_) {}
  }

  void _onForeground(Map<String, dynamic> data) {
    final p = PushPayload.fromData(data);
    if (p.isCallCancel) _cancelled.add(p.callId);
    // Foreground: draw it ourselves (FCM shows nothing while we're open).
    // A call rings as a heads-up with Accept/Decline.
    unawaited(PushNotifier.show(p));
  }

  void _onLocalResponse(NotificationResponse r) {
    final p = PushPayload.decode(r.payload);
    if (p == null) return;
    if (r.actionId == PushNotifier.actionDecline) {
      if (p.isCall) {
        unawaited(PushNotifier.declineCall(p.callId, token: _app?.api.token));
        unawaited(PushNotifier.cancelCall(p.callId));
      }
      return;
    }
    _open(p, r.actionId);
  }

  void _open(PushPayload p, String? action) {
    final app = _app;
    if (app == null || app.loading || !app.loggedIn) {
      _pending = (payload: p, action: action);
      return;
    }
    final target = PushRouting.targetFor(p, action: action);
    final nav = _nav?.currentState;
    if (target == null || nav == null) return;
    try {
      if (target.openIncomingCall) {
        unawaited(PushNotifier.cancelCall(p.callId));
        final member = <String, dynamic>{
          'id': int.tryParse(p.chatId),
          'name': p.callerName,
        };
        final kind = p.isVideo ? 'video' : 'voice';
        if (action == PushNotifier.actionAccept) {
          nav.push(MaterialPageRoute(
              builder: (_) => CircleCallScreen(
                  member: member, kind: kind, outgoing: false)));
        } else {
          // plain tap / full-screen launch: ring first, user decides.
          nav.push(MaterialPageRoute(
              builder: (_) => IncomingCallScreen(payload: p)));
        }
        return;
      }
      final b = ChatNav.routes[target.chatNavRoute];
      if (b != null) nav.push(MaterialPageRoute(builder: b));
    } catch (e) {
      if (kDebugMode) debugPrint('push open failed: $e');
    }
  }

  @visibleForTesting
  void resetForTest() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _app?.removeListener(_onAppChanged);
    _app = null;
    _started = false;
    _pending = null;
    _registeredToken = null;
    available.value = false;
    bridge = createPushBridge();
  }
}
