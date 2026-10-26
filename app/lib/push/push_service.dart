import '../crypto/key_wiring.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../alerts_fg.dart';
import '../api.dart';
import '../calls/call_native.dart';
import '../calls/ring_checklist.dart';
import '../calls/call_reply.dart';
import '../calls/call_runtime.dart';
import '../config.dart';
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
import '../ads/app_open_gate.dart' show AppEntry;
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

  /// [realtimeOnly] (ty1): STARTUP SAFE MODE (the previous launch never
  /// reached home) and the reality harness. Firebase, the notification
  /// permission ask and the native bubble/shortcut bridge are skipped, but
  /// the pure-Dart real-time loop still starts — in-app incoming calls,
  /// typing / online and live ticks. Before ty1 safe mode skipped ALL of
  /// this, so a phone whose last launch was killed on the splash could not
  /// ring for a My Circle call for a whole session (owner rule: calls are
  /// never blocked).
  Future<void> start(AppState app,
      {GlobalKey<NavigatorState>? navigatorKey,
      bool realtimeOnly = false}) async {
    if (_started) {
      _rebind(app);
      return;
    }
    _started = true;
    _app = app;
    _nav = navigatorKey ?? appNavigatorKey;
    _wasLoggedIn = app.loggedIn;
    if (realtimeOnly) {
      Notifications.onResponse = _onLocalResponse;
      available.value = false;
      _realtimeOnly = true;
      unawaited(_setPushOk(false));
      app.addListener(_onAppChanged);
      _onAppChanged();
      try {
        await CallRuntime.instance
            .start(app, _nav ?? appNavigatorKey, pushAvailable: false);
      } catch (_) {}
      return;
    }

    // 1) Local-notification taps / actions (UI isolate).
    Notifications.onResponse = _onLocalResponse;
    // ring-everywhere: the native ring's ack needs the API base (no token).
    unawaited(_nativeConfig());
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
    if (!ok) unawaited(_setPushOk(false));
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

  bool _realtimeOnly = false;

  /// ty1: [start] again with a DIFFERENT AppState (the reality harness boots
  /// a fresh one per flow, like closing and reopening the app): follow it.
  /// The shared transport resolves the current session per request, so the
  /// chat screens / receipts / badges keep their subscriptions.
  void _rebind(AppState app) {
    final old = _app;
    if (identical(old, app)) return;
    old?.removeListener(_onAppChanged);
    _app = app;
    _wasLoggedIn = app.loggedIn;
    app.addListener(_onAppChanged);
    _onAppChanged();
    try {
      unawaited(CallRuntime.instance.start(app, _nav ?? appNavigatorKey,
          pushAvailable: available.value));
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
    if (fg && !_realtimeOnly) {
      // ring-everywhere: back online -> calls this phone never got, and a
      // fresh token registration now and then (FCM may rotate it while the
      // app was killed and the plugin could not tell us).
      unawaited(fetchMissedCalls());
      final last = _registeredAt;
      if (last == null ||
          DateTime.now().difference(last) > reRegisterEvery) {
        _registeredToken = null;
        unawaited(_register(null));
      }
    }
  }

  /// ring-everywhere: re-register the FCM token at most this often on resume.
  /// calls95: 6 h (was 12 h) — a token FCM rotated while the app was killed
  /// is picked up the same day; every cold start registers anyway.
  static const reRegisterEvery = Duration(hours: 6);

  /// calls95: the token this install registered last (survives restarts), so
  /// a rotated token REPLACES its old server row instead of leaving a dead
  /// one behind for the ring push to wait on.
  static const lastTokenKey = 'push_last_token_v1';
  DateTime? _registeredAt;
  DateTime? _missedFetchedAt;

  Future<void> _nativeConfig() async {
    try {
      String ver = '';
      try {
        final info = await PackageInfo.fromPlatform();
        ver = '${info.version}+${info.buildNumber}';
      } catch (_) {}
      await CallNative.setNativeConfig(AppConfig.api('/').toString(), ver);
    } catch (_) {}
  }

  /// ring-everywhere: GET circle/calls/missed_pending and draw each
  /// never-delivered missed call ONCE (the server clears what it returns;
  /// the notification id is per caller, so an FCM copy replaces it).
  Future<int> fetchMissedCalls({bool force = false}) async {
    final app = _app;
    if (app == null || !app.loggedIn || app.loading) return 0;
    final last = _missedFetchedAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 60)) {
      return 0;
    }
    _missedFetchedAt = DateTime.now();
    try {
      final r = await app.api
          .missedPending()
          .timeout(const Duration(seconds: 10));
      final items = r['items'];
      if (items is! List) return 0;
      var n = 0;
      for (final it in items) {
        if (it is! Map) continue;
        final p = PushPayload.fromData(it);
        if (!p.isMissedCall) continue;
        await PushNotifier.show(p);
        n++;
      }
      // calls95: rings this phone never got -> the per-brand setup
      // checklist comes back (banner + badge), never a blocking screen.
      if (n > 0) unawaited(RingChecklist.onMissedRing());
      return n;
    } catch (_) {
      return 0;
    }
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

  ({String kind, int id, bool quickReply})? _pendingChat;

  void _openChat(String kind, int id, {bool quickReply = false}) {
    final app = _app;
    final nav = _nav?.currentState;
    if (app == null || app.loading || !app.loggedIn || nav == null) {
      _pendingChat = (kind: kind, id: id, quickReply: quickReply);
      return;
    }
    unawaited(ChatOpener.open(nav, app.api, kind, id, quickReply: quickReply));
  }

  /// call-reply: an incoming call's Reply (native ring, Dart-drawn ring or
  /// the in-app incoming screen). The call is DECLINED exactly like Decline
  /// (server event; the native ring already sent its signed decline ack — a
  /// second decline is a server no-op), the ring is cleared, then that
  /// person's chat opens with the quick-reply sheet. Returns false when this
  /// payload cannot be replied to (group / no chat): it is then a plain
  /// decline.
  bool onCallReply(PushPayload p, {bool decline = true}) {
    AppEntry.mark('call'); // p2-money: never an app-open ad for a call entry
    if (!p.isCall) return false;
    if (decline) {
      unawaited(PushNotifier.declineCall(p.callId, token: _app?.api.token));
    }
    unawaited(PushNotifier.cancelCall(p.callId));
    try {
      unawaited(CallRuntime.instance.stopRinging());
    } catch (_) {}
    final id = CallReply.memberId(p);
    if (id == null) return false;
    _openChat('member', id, quickReply: true);
    return true;
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
    if (!_realtimeOnly) {
      unawaited(_register(null));
      unawaited(_maybeAskPermission());
      unawaited(fetchMissedCalls()); // ring-everywhere (throttled)
    }
    // c3-msg presence/typing ride the app's ONE real-time loop (c2-calls'
    // PollRealtimeTransport, owned by CallRuntime) + the delivered sync.
    try {
      if (!RealtimeChannel.instance.hasTransport) {
        RealtimeChannel.instance.useTransport(SharedPollTransport(
            CallRuntime.instance.transportFor(app),
            get: (p) => (_app ?? app).api.getJson(p)));
      }
      // b2-badges: `badges.update` on the same loop refreshes the home icons.
      BadgesBus.instance.attach(CallRuntime.instance.transportFor(app).events);
      // x2-ticks: live ticks (receipt.update) + instant delivered acks
      // (msg.new) on the same loop.
      final rt = CallRuntime.instance.transportFor(app);
      ReceiptBus.instance.attach(rt.events,
          ack: () => ReceiptAck(token: () async => (_app ?? app).api.token),
          setFast: rt.setFast);
    } catch (_) {}
    unawaited(_syncReceipts());
    final pc = _pendingChat;
    if (pc != null) {
      _pendingChat = null;
      _openChat(pc.kind, pc.id, quickReply: pc.quickReply);
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
      Map<String, Object?>? dev;
      try {
        dev = await CallNative.deviceFacts();
      } catch (_) {}
      String? prev;
      SharedPreferences? prefs;
      try {
        prefs = await SharedPreferences.getInstance();
        prev = prefs.getString(lastTokenKey);
      } catch (_) {}
      final r = await app.api.pushRegister(token,
          appVersion: ver,
          device: dev,
          replaceToken: (prev != null && prev != token) ? prev : null);
      _registeredToken = token;
      _registeredAt = DateTime.now();
      try {
        await prefs?.setString(lastTokenKey, token);
      } catch (_) {}
      await _setPushOk(true);
      // ring-everywhere: the server holds calls this phone never got.
      final pending = r['missed_pending'];
      if (pending is int && pending > 0) {
        unawaited(fetchMissedCalls(force: true));
      }
    } catch (e) {
      await _setPushOk(false);
      if (kDebugMode) debugPrint('push register failed: $e');
    }
  }

  /// at-falsealarm: tells AlertPoller that FCM delivers this account's alerts
  /// on this phone, so it must not show a second (local) copy.
  Future<void> _setPushOk(bool v) async {
    try {
      await Settings.setBool(AlertPoller.pushOkKey, v);
    } catch (_) {}
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
    await _setPushOk(false);
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
    AppEntry.mark('notification'); // p2-money: no app-open ad for this entry
    if (r.actionId == kActionReply || r.actionId == kActionRead) {
      unawaited(handleMsgNotificationAction(r));
      return;
    }
    final p = PushPayload.decode(r.payload);
    if (p == null) return;
    if (r.actionId == CallReply.action) {
      onCallReply(p);
      return;
    }
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
    AppEntry.mark(p.isCall ? 'call' : (p.isSos ? 'sos' : 'notification'));
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
          : ChatNav.builderFor(target.chatNavRoute); // feature-flags
      if (b != null) nav.push(MaterialPageRoute(builder: b));
    } catch (e) {
      if (kDebugMode) debugPrint('push open failed: $e');
    }
  }

  /// call-reply tests: the chat waiting for sign-in / the navigator.
  @visibleForTesting
  ({String kind, int id, bool quickReply})? get pendingChatForTest =>
      _pendingChat;

  /// call-reply tests: a notification tap / action as the plugin delivers it.
  @visibleForTesting
  void localResponseForTest(NotificationResponse r) => _onLocalResponse(r);

  @visibleForTesting
  void resetForTest() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _app?.removeListener(_onAppChanged);
    _app = null;
    _started = false;
    _realtimeOnly = false;
    _pending = null;
    _pendingChat = null;
    _registeredToken = null;
    _registeredAt = null;
    _missedFetchedAt = null;
    available.value = false;
    bridge = createPushBridge();
  }
}
