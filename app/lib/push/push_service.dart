import '../crypto/key_wiring.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../calls/call_runtime.dart';
import '../notifications.dart';
import '../state.dart';
import '../screens/delete_account_screen.dart';
import '../widgets/chatnav.dart';
import '../screens/circle_call_screen.dart';
import 'incoming_call_screen.dart';
import 'push_api.dart';
import 'push_binding.dart';
import 'push_bridge.dart';
import 'push_notifier.dart';
import 'push_payload.dart';
import '../messaging/badges_bus.dart';
import '../messaging/c3_api.dart';
import '../messaging/chat_opener.dart';
import '../messaging/msg_native.dart';
import '../messaging/msg_notify.dart';
import '../messaging/receipt_ack.dart';
import '../messaging/receipt_bus.dart';
import '../realtime/realtime_channel.dart';

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
    // c2-calls: real-time transport + instant in-app incoming calls.
    try {
      await CallRuntime.instance.start(app, _nav ?? appNavigatorKey,
          pushAvailable: ok);
    } catch (_) {}

    // c3-msg: a bubble / conversation shortcut asked for one chat.
    MsgNative.onOpenChat((key) {
      final c = ChatOpener.parse(key);
      if (c != null) _openChat(c.kind, c.id);
    });
    try {
      final key = await MsgNative.takeLaunchChat();
      final c = ChatOpener.parse(key);
      if (c != null) {
        _openChat(c.kind, c.id);
      }
    } catch (_) {}
  }

  /// c3-msg: app foregrounded (start / resume) — tell the server this device
  /// has fetched (delivered ✓✓ for senders) and resume the realtime channel.
  /// One cheap request; silent on failure.
  void onForegroundChanged(bool fg) {
    try {
      RealtimeChannel.instance.setForeground(fg);
    } catch (_) {}
    if (fg) unawaited(_syncReceipts());
    if (!fg) ReceiptBus.instance.relax(); // x2-ticks: no fast poll in bg
  }

  Future<void> _syncReceipts() async {
    final app = _app;
    if (app == null || !app.loggedIn) return;
    // x2-ticks: acks queued while offline (any isolate) go out first.
    try {
      final tok = app.api.token;
      await ReceiptAck(token: () async => tok).flush();
    } catch (_) {}
    try {
      await app.api.c3ReceiptsSync().timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  ({String kind, int id})? _pendingChat;

  void _openChat(String kind, int id) {
    final app = _app;
    final nav = _nav?.currentState;
    if (app == null || app.loading || !app.loggedIn || nav == null) {
      _pendingChat = (kind: kind, id: id);
      return;
    }
    unawaited(ChatOpener.open(nav, app.api, kind, id));
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
    // c3-msg presence/typing ride the app's ONE real-time loop (c2-calls'
    // PollRealtimeTransport, owned by CallRuntime) + the delivered sync.
    try {
      if (!RealtimeChannel.instance.hasTransport) {
        RealtimeChannel.instance.useTransport(SharedPollTransport(
            CallRuntime.instance.transportFor(app),
            get: (p) => app.api.getJson(p)));
      }
      // b2-badges: `badges.update` on the same loop refreshes the home icons.
      BadgesBus.instance.attach(CallRuntime.instance.transportFor(app).events);
      // x2-ticks: live ticks (receipt.update) + instant delivered acks
      // (msg.new) on the same loop.
      final rt = CallRuntime.instance.transportFor(app);
      ReceiptBus.instance.attach(rt.events,
          ack: () => ReceiptAck(token: () async => app.api.token),
          setFast: rt.setFast);
    } catch (_) {}
    unawaited(_syncReceipts());
    final pc = _pendingChat;
    if (pc != null) {
      _pendingChat = null;
      _openChat(pc.kind, pc.id);
    }
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
  /// [api] carries the signed-out session's token (AppState.logout clears
  /// the shared client first so the login screen shows at once).
  Future<void> onLogout({ApiClient? api}) async {
    final client = api ?? _app?.api;
    final tok = _registeredToken;
    _registeredToken = null;
    if (client != null && tok != null) {
      try {
        await client.pushUnregister(tok).timeout(const Duration(seconds: 6));
      } catch (_) {}
    }
    try {
      await bridge.deleteToken();
    } catch (_) {}
  }

  void _onForeground(Map<String, dynamic> data) {
    // x2-ticks: delivered ✓✓ at once (by message id) — even for the chat
    // that is open on screen; a silent msg_sync ping draws nothing.
    if (kX2AckKinds.contains('${data['kind'] ?? ''}')) {
      final tok = _app?.api.token;
      unawaited(ackPushDelivery(data,
          ack: (tok == null || tok.isEmpty)
              ? null
              : ReceiptAck(token: () async => tok)));
      if ('${data['kind']}' == 'msg_sync') return;
    }
    final p = PushPayload.fromData(data);
    // x1-calls: call-signal nudge -> poll the call queue now (no UI)
    if (p.isCallNudge) {
      CallRuntime.instance.nudge();
      return;
    }
    // e2-keys: silent key plumbing (key_request / key_ready) — nothing drawn.
    if (KeyWiring.instance.onForegroundPush(p.kind, data)) return;
    if (p.isCallCancel) {
      _cancelled.add(p.callId);
      CallRuntime.instance.onPushCancel(p);
    }
    // c2-calls: app open -> the full in-app incoming screen at once (rings
    // natively), not a heads-up notification.
    if (p.isCall) {
      CallRuntime.instance.onPushRing(p);
      return;
    }
    // c3-msg: messages → on-device MessagingStyle (skipped for the chat that
    // is open on screen — it polls and marks seen itself).
    final chat = MsgPushHandler.chatOf(p);
    final app = _app;
    final tok = app?.api.token;
    if (chat != null && tok != null && tok.isNotEmpty) {
      if (MsgActiveChat.isOpen(chat.kind, chat.id)) return;
      final h = MsgPushHandler(
          backend: HttpMsgBackend(tok, lang: p.lang),
          identity: loadStoredIdentity,
          sink: FlnMsgSink());
      unawaited(h.onPush(p).then((ok) {
        if (!ok) unawaited(PushNotifier.show(p));
      }));
      return;
    }
    // Foreground: draw it ourselves (FCM shows nothing while we're open).
    unawaited(PushNotifier.show(p));
  }

  void _onLocalResponse(NotificationResponse r) {
    if (r.actionId == kActionReply || r.actionId == kActionRead) {
      unawaited(handleMsgNotificationAction(r));
      return;
    }
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
    // c3-msg: a message tap opens THAT chat (not just the hub).
    final chat = MsgPushHandler.chatOf(p);
    if (chat != null && action == null) {
      _openChat(chat.kind, chat.id);
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
          'photo_url': p.callerPhoto,
        };
        final kind = p.isVideo ? 'video' : 'voice';
        if (action == PushNotifier.actionAccept) {
          nav.push(MaterialPageRoute(
              builder: (_) => CircleCallScreen(
                  member: member,
                  kind: kind,
                  outgoing: false,
                  callId: int.tryParse(p.callId))));
        } else {
          // plain tap / full-screen launch: ring first, user decides.
          nav.push(MaterialPageRoute(
              builder: (_) => IncomingCallScreen(payload: p)));
        }
        return;
      }
      // dl1: the deletion notice opens the "Cancel deletion" screen (a
      // notice-only route, deliberately not in ChatNav.routes).
      final b = target.chatNavRoute == ChatNav.accountDeleteRoute
          ? (BuildContext _) => const DeleteAccountScreen()
          : ChatNav.routes[target.chatNavRoute];
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
