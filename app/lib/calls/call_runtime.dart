import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../push/incoming_call_screen.dart';
import '../push/push_notifier.dart';
import '../push/push_payload.dart';
import '../realtime/realtime_transport.dart';
import '../services/error_kind.dart';
import '../state.dart';
import 'call_controller.dart';
import 'call_keepalive.dart';
import 'call_native.dart';
import 'call_sound_prefs.dart';
import 'call_log.dart';
import 'call_video.dart';

/// b1-calls: a live call that left its screen (minimized inside the app).
class OngoingCall {
  OngoingCall({
    required this.controller,
    required this.member,
    required this.kind,
    this.surface,
  });
  final CallController controller;
  final CallVideoSurface? surface;
  final Map<String, dynamic> member;

  /// how the call started ('voice' | 'video').
  final String kind;
  String get name => '${member['name'] ?? ''}';
}

/// App-wide call runtime (c2-calls): owns the shared real-time transport and
/// shows the in-app incoming-call screen INSTANTLY while Assisto is open
/// (from the real-time queue or a foreground FCM push — whichever is first).
///
/// LAZY: started by PushService after the first frame; the transport polls
/// only while the user is signed in AND the app is in the foreground
/// (paused in background — FCM rings then). Every step is guarded.
class CallRuntime with WidgetsBindingObserver {
  CallRuntime._();
  static final CallRuntime instance = CallRuntime._();

  AppState? _app;
  GlobalKey<NavigatorState>? _nav;
  PollRealtimeTransport? _transport;
  StreamSubscription<RealtimeEvent>? _sub;
  bool _started = false;
  bool _pushAvailable = false;

  /// call ids whose incoming screen is up / were handled (never ring twice).
  final Set<String> _shown = {};

  /// The call this phone is in right now (call screen sets/clears it).
  int? activeCallId;

  final StreamController<String> _ended = StreamController<String>.broadcast();

  /// call_id of every call that ended while ringing here (screen closes).
  Stream<String> get endedCalls => _ended.stream;

  /// The shared transport (created on first use, for the signed-in user).
  ///
  /// ty1: the transport resolves the CURRENT AppState's ApiClient on every
  /// request (not the one it was created with), so a re-bound AppState
  /// ([start] with a new one) or a replaced `app.api` keeps the same event
  /// stream — the chat screens, receipts and badges listening to it never
  /// need to re-subscribe.
  PollRealtimeTransport transportFor(AppState app) {
    _app ??= app;
    final t = _transport ??= PollRealtimeTransport(
        get: (p) => (_app ?? app).api.getJson(p),
        post: (p, b) => (_app ?? app).api.postJson(p, b));
    if (!t.running) unawaited(t.connect());
    return t;
  }

  @visibleForTesting
  AppState? get boundApp => _app;

  Future<void> start(AppState app, GlobalKey<NavigatorState> nav,
      {bool pushAvailable = false}) async {
    final old = _app;
    _app = app;
    _nav = nav;
    _pushAvailable = pushAvailable;
    if (_started) {
      // ty1: a NEW AppState (the reality harness re-boots the app with a
      // fresh one per flow): follow it, or the in-app ring would keep
      // watching the old session's sign-in state.
      if (!identical(old, app)) {
        old?.removeListener(_onApp);
        app.addListener(_onApp);
        _onApp();
      }
      return;
    }
    _started = true;
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (e) {
      callLog('call_runtime#1', e);
    }
    app.addListener(_onApp);
    _onApp();
  }

  void setPushAvailable(bool v) {
    _pushAvailable = v;
    _transport?.idleInterval = Duration(milliseconds: v ? 5000 : 2500);
  }

  void _onApp() {
    final app = _app;
    if (app == null) return;
    if (!app.loggedIn || app.loading) {
      unawaited(_transport?.close());
      return;
    }
    final t = transportFor(app);
    t.idleInterval = Duration(milliseconds: _pushAvailable ? 5000 : 2500);
    _sub ??= t.events.listen(_onEvent, onError: (_) {});
    unawaited(checkIncoming());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final t = _transport;
    if (t == null) return;
    if (s == AppLifecycleState.resumed) {
      t.setPaused(false);
      unawaited(checkIncoming());
    } else if (s == AppLifecycleState.paused ||
        s == AppLifecycleState.detached) {
      // keep polling while a call is live (the call screen keeps it fast)
      if (activeCallId == null) t.setPaused(true);
    }
  }

  void _onEvent(RealtimeEvent e) {
    try {
      if (e.topic == 'call.incoming') {
        onIncoming(e.payload);
      } else if (e.topic == 'call.state') {
        final id = '${e.payload['call_id'] ?? ''}';
        if (e.payload['side'] == 'callee' && e.payload['phase'] == 'ended') {
          _ended.add(id);
          unawaited(PushNotifier.cancelCall(id));
        }
      }
    } catch (e) {
      callLog('call_runtime#2', e);
    }
  }

  /// One-off check (app open / resume) for a call that is ringing for me.
  Future<void> checkIncoming() async {
    final app = _app;
    if (app == null || !app.loggedIn) return;
    try {
      final r = await app.api.getJson('/circle/calls/incoming');
      for (final c in (r['calls'] as List? ?? const [])) {
        if (c is Map) onIncoming(c.cast<String, dynamic>());
      }
    } catch (e) {
      callLog('call_runtime#3', e);
    }
  }

  /// A foreground FCM ring (PushService routes it here instead of drawing a
  /// notification while we are on screen).
  void onPushRing(PushPayload p) => onIncoming({
        'call_id': p.callId,
        'caller_name': p.callerName,
        'caller_photo': p.callerPhoto,
        'caller_id': p.callerId,
        'video': p.isVideo,
        'chat_id': p.chatId,
        'lang': p.lang,
      });

  void onPushCancel(PushPayload p) {
    _ended.add(p.callId);
  }

  /// A ringing screen for [callId] is up (from any path) — never stack a
  /// second one.
  void markShown(String callId) {
    if (callId.isNotEmpty) _shown.add(callId);
  }

  /// x1-calls glare: this phone's own call screen joined call [callId] (the
  /// server merged "both called each other"), so a ringing screen or ring
  /// notification for it must go away — and must never appear later.
  void claim(String callId) {
    if (callId.isEmpty) return;
    _shown.add(callId);
    _ended.add(callId);
    unawaited(PushNotifier.cancelCall(callId));
    unawaited(stopRinging().catchError((_) {}));
  }

  Object? _screenOwner;
  bool Function()? _screenLive;

  /// x1-calls: ONE live call screen at a time. A second screen (double tap
  /// in Contacts / the call log, a stacked route) is refused while the first
  /// one's call is still live; an ENDED screen ("Busy", "Call again") yields.
  bool acquireScreen(Object owner, bool Function() live) {
    final cur = _screenOwner;
    if (cur != null && !identical(cur, owner)) {
      bool busy;
      try {
        busy = _screenLive?.call() ?? false;
      } catch (_) {
        busy = false;
      }
      if (busy) return false;
    }
    _screenOwner = owner;
    _screenLive = live;
    return true;
  }

  void releaseScreen(Object owner) {
    if (identical(_screenOwner, owner)) {
      _screenOwner = null;
      _screenLive = null;
    }
  }

  // ------------------------------------------- b1: minimized (in-app) call
  /// The live call whose screen was minimized (back / "Minimize") while the
  /// user moves around the app. The mini call bar ([CallMiniBarHost]) shows
  /// it; tapping it re-opens the call screen with the SAME controller.
  final ValueNotifier<OngoingCall?> ongoing = ValueNotifier<OngoingCall?>(null);

  /// Opens the call screen for a minimized call (the mini bar's tap). Set by
  /// the call screen library, so this file never imports it.
  void Function(NavigatorState nav, OngoingCall o)? reopenCall;

  /// The call screen hands its live call over (it is about to pop). The call
  /// keeps running; this runtime holds the one-call-screen lock for it.
  void minimize(OngoingCall o) {
    final old = ongoing.value;
    if (old != null && !identical(old, o)) _dropOngoing(old);
    o.controller.addListener(_onOngoing);
    _setOngoing(o);
    acquireScreen(o, () => !o.controller.isEnded);
  }

  /// The call screen takes the minimized call back (null = none / ended).
  OngoingCall? takeOngoing() {
    final o = ongoing.value;
    if (o == null) return null;
    o.controller.removeListener(_onOngoing);
    releaseScreen(o);
    _setOngoing(null);
    return o.controller.isEnded ? null : o;
  }

  /// Changing [ongoing] rebuilds the app-wide bar: never during a build
  /// (a call screen takes its call back in initState) — then after it.
  void _setOngoing(OngoingCall? o) {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        // only if nothing newer was set meanwhile
        if (o == null || !o.controller.isEnded) ongoing.value = o;
      });
    } else {
      ongoing.value = o;
    }
  }

  /// Mini bar tap: back to the full call screen.
  void restoreOngoing() {
    final o = ongoing.value;
    final nav = _nav?.currentState;
    if (o == null || nav == null) return;
    try {
      reopenCall?.call(nav, o);
    } catch (e) {
      callLog('call_runtime#8', e);
    }
  }

  void _onOngoing() {
    final o = ongoing.value;
    if (o == null || !o.controller.isEnded) return;
    _dropOngoing(o);
  }

  /// The minimized call ended (other side hung up, network lost, red button
  /// on the bar): release everything the screen would have released.
  void _dropOngoing(OngoingCall o) {
    o.controller.removeListener(_onOngoing);
    releaseScreen(o);
    if (identical(ongoing.value, o)) _setOngoing(null);
    if (activeCallId != null && activeCallId == o.controller.callId) {
      activeCallId = null;
    }
    unawaited(CallKeepAlive.stop());
    unawaited(CallNative.keepScreenOn(false));
    unawaited(CallNative.setAutoPip(false));
    final c = o.controller;
    // let the end tone play, then free the controller
    Timer(const Duration(seconds: 2), () {
      try {
        c.dispose();
      } catch (e) {
        callLog('call_runtime#9', e);
      }
    });
  }

  /// FCM "call_signal" nudge (x1-calls): poll the real-time queue NOW.
  void nudge() {
    try {
      unawaited(_transport?.reconnect());
    } catch (e) {
      callLog('call_runtime#7', e);
    }
  }

  void onIncoming(Map<String, dynamic> row) {
    final id = '${row['call_id'] ?? ''}';
    if (id.isEmpty || _shown.contains(id)) return;
    if (activeCallId != null && '$activeCallId' == id) return; // in it already
    final nav = _nav?.currentState;
    if (nav == null) return;
    _shown.add(id);
    if (activeCallId != null && '$activeCallId' != id) {
      // already in a call: the newcomer hears "busy" (WhatsApp-style
      // call-waiting is a follow-up).
      unawaited(_event(id, 'busy'));
      return;
    }
    final p = PushPayload.fromData({
      'kind': 'call',
      'call_id': id,
      'caller_name': '${row['caller_name'] ?? ''}',
      'caller_photo': '${row['caller_photo'] ?? ''}',
      'caller_id': '${row['caller_id'] ?? ''}',
      'video':
          row['video'] == true || row['kind'] == 'video' ? 'true' : 'false',
      'chat_id': '${row['chat_id'] ?? ''}',
      'lang': _app?.locale?.languageCode == 'en' ? 'en' : 'bn',
    });
    try {
      nav.push(MaterialPageRoute(
          builder: (_) => IncomingCallScreen(payload: p, ringInApp: true)));
    } catch (e) {
      callLog('call_runtime#4', e);
    }
  }

  /// In-app ring: the chosen ringtone (phone default when none), respecting
  /// silent / vibrate / Do-Not-Disturb natively; tells the caller we ring.
  Future<void> startRinging(PushPayload p) async {
    // calls-presence: retried — a lost ack let the server end the call as
    // "offline" at 20 s while this phone rang ("rang, then dropped").
    unawaited(_event(p.callId, 'ringing', tries: 3));
    try {
      final uri = await CallSoundPrefs.ringtoneFor(p.chatId);
      await CallNative.startRingtone(uri);
    } catch (e) {
      callLog('call_runtime#5', e);
    }
  }

  Future<void> stopRinging() => CallNative.stopRingtone();

  Future<void> _event(String callId, String event, {int tries = 1}) async {
    for (var i = 0; i < tries; i++) {
      final app = _app;
      if (app == null) return;
      try {
        await app.api.postJson('/circle/calls/$callId/event', {'event': event});
        return;
      } catch (e) {
        callLog('call_runtime#6', e);
        // a 4xx (call over / not mine) is final
        if (failKindOf(e) == FailKind.refused) return;
      }
      if (i + 1 < tries) {
        await Future<void>.delayed(Duration(milliseconds: 1500 * (i + 1)));
      }
    }
  }

  @visibleForTesting
  void resetForTest() {
    _sub?.cancel();
    _sub = null;
    unawaited(_transport?.close());
    _transport = null;
    _shown.clear();
    activeCallId = null;
    ongoing.value = null;
    _screenOwner = null;
    _screenLive = null;
    _app?.removeListener(_onApp);
    _app = null;
    _started = false;
  }
}
