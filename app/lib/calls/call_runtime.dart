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
import 'call_launch.dart'; // calls-a
import 'call_keepalive.dart';
import 'call_native.dart';
import 'call_pip.dart'; // callpip
import '../l10n/app_localizations.dart';
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
    _observe();
    app.addListener(_onApp);
    _onApp();
  }

  /// calls-a: main.dart hands over the app navigator BEFORE the first frame
  /// (pure Dart), so the return-to-call bar / floating video work even before
  /// push start-up (2-7 s after launch) called [start].
  void attachNavigator(GlobalKey<NavigatorState> nav) {
    if (_nav?.currentState == null) _nav = nav;
  }

  /// calls-a: a call is going on — full screen, minimized to the bar /
  /// floating window, or still connecting. Ads never show while true.
  bool get callActive {
    if (ongoing.value != null || activeCallId != null) return true;
    try {
      return _screenLive?.call() ?? false;
    } catch (_) {
      return true;
    }
  }

  void setPushAvailable(bool v) {
    _pushAvailable = v;
    _applyCadence(_transport);
  }

  /// circle2 cadence (see PollRealtimeTransport): 2.5 s while a My Circle
  /// screen is visible; elsewhere in the app 10 s when FCM is live (rings and
  /// messages come by push, and a foreground push polls at once via
  /// [nudge]); without FCM the poll is the only in-app ring path -> 2.5 s.
  static const quietWithPush = Duration(seconds: 10);

  void _applyCadence(PollRealtimeTransport? t) {
    if (t == null) return;
    t.idleInterval = const Duration(milliseconds: 2500);
    t.quietInterval = _pushAvailable ? quietWithPush : null;
  }

  void _onApp() {
    final app = _app;
    if (app == null) return;
    if (!app.loggedIn || app.loading) {
      unawaited(_transport?.close());
      return;
    }
    final t = transportFor(app);
    _applyCadence(t);
    _sub ??= t.events.listen(_onEvent, onError: (_) {});
    unawaited(checkIncoming());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    _cameraForLifecycle(s); // callpip
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
    if (o.controller.callId != null) activeCallId ??= o.controller.callId;
    if (identical(_screenCall, o.controller)) {
      _screenCall = null;
      _screenSurface = null;
    }
    _observe();
    _watchSize(o.surface);
    _syncPip(o);
    _watchPip();
  }

  // ------------------------------------- calls-a: system PiP while minimized
  bool _pipWatched = false;

  /// A minimized LIVE video call still shrinks into Android picture-in-
  /// picture when the user leaves Assisto (Home / Recents) — before calls-a
  /// minimizing switched auto-PiP off.
  void _syncPip(OngoingCall o) => syncPip();

  void _watchPip() {
    if (_pipWatched) return;
    _pipWatched = true;
    CallNative.inPip.addListener(_onPipChanged);
  }

  bool _wasInPip = false;

  /// The user tapped the system PiP window back to full size: open the full
  /// call (WhatsApp does the same). Closing the PiP (its X) leaves the app
  /// in the background instead — lifecycle not resumed — and the call goes
  /// on with its notification.
  void _onPipChanged() {
    // callpip: the PiP window was closed (X) — the activity is no longer
    // visible: the camera pauses (no lifecycle event follows it)
    _cameraForLifecycle(
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed);
    final now = CallNative.inPip.value;
    final was = _wasInPip;
    _wasInPip = now;
    if (!was || now) return;
    Timer(const Duration(milliseconds: 350), () {
      try {
        final o = ongoing.value;
        if (o == null || o.controller.isEnded) return;
        final st = WidgetsBinding.instance.lifecycleState;
        if (st == AppLifecycleState.resumed) restoreOngoing();
      } catch (e) {
        callLog('call_runtime#10', e);
      }
    });
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
  /// [from]: the tapped widget's context — used only when no app navigator
  /// is attached (a screen that hosts the bar below its own Navigator).
  void restoreOngoing([BuildContext? from]) {
    final o = ongoing.value;
    NavigatorState? nav = _nav?.currentState;
    if (nav == null && from != null && from.mounted) {
      nav = Navigator.maybeOf(from);
    }
    if (o == null || nav == null) return;
    if (o.controller.isEnded) {
      // calls-a: never re-open a stale "Call ended" screen
      _dropOngoing(o);
      return;
    }
    try {
      reopenCall?.call(nav, o);
    } catch (e) {
      callLog('call_runtime#8', e);
    }
  }

  void _onOngoing() {
    final o = ongoing.value;
    if (o == null) return;
    if (!o.controller.isEnded) {
      _syncPip(o); // voice <-> video while minimized
      return;
    }
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
    syncPip(); // callpip: off (or the next live call's state)
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

  // ------------------------------------- callpip: leaving the call screen
  // Owner phone test 2 Nov: "Back / Home / Facebook during a video call
  // makes the video disappear". The call screen and a minimized call both
  // register their live call here; this runtime keeps Android's PiP state,
  // the background-camera pause and Back on the last screen right for it.
  // Decisions: call_pip.dart (CI-tested); native only executes.

  CallController? _screenCall;
  CallVideoSurface? _screenSurface;
  bool _observing = false;
  Listenable? _sizeSrc;

  /// The live call right now: minimized, or owned by the open call screen.
  CallController? get currentCall {
    final o = ongoing.value;
    if (o != null && !o.controller.isEnded) return o.controller;
    final c = _screenCall;
    return c == null || c.isEnded ? null : c;
  }

  CallVideoSurface? get _currentSurface {
    final o = ongoing.value;
    if (o != null && !o.controller.isEnded) return o.surface;
    return _screenSurface;
  }

  /// The call screen OWNS [c] (call placed / accepted / taken back).
  void bindScreenCall(CallController c, CallVideoSurface? s) {
    if (!identical(_screenCall, c) || !identical(_screenSurface, s)) {
      _screenCall = c;
      _screenSurface = s;
      _watchSize(s);
    }
    _observe();
    _watchPip();
    syncPip();
  }

  /// The call screen let go of [c] (closed, or handed it to the mini bar).
  void unbindScreenCall(CallController c) {
    if (!identical(_screenCall, c)) return;
    _screenCall = null;
    _screenSurface = null;
    syncPip();
  }

  void _observe() {
    if (!_observing) {
      _observing = true;
      try {
        WidgetsBinding.instance.addObserver(this);
      } catch (e) {
        _observing = false;
        callLog('call_runtime#1', e);
      }
    }
    CallNative.onPipAction ??= onPipAction;
    CallNative.onCallReturn ??= onCallReturn;
  }

  void _watchSize(CallVideoSurface? s) {
    final Object? any = s;
    final Listenable? src =
        any is VideoSizeSource ? any.remoteSizeChanges : null;
    if (identical(src, _sizeSrc)) return;
    _sizeSrc?.removeListener(syncPip);
    _sizeSrc = src;
    src?.addListener(syncPip);
  }

  Map<String, String>? _pipLabels() {
    try {
      final ctx = _nav?.currentContext;
      if (ctx == null) return null;
      final t = Localizations.of<AppLocalizations>(ctx, AppLocalizations);
      if (t == null) return null;
      return {
        'mute:0': t.callpipMute,
        'mute:1': t.callpipUnmute,
        'camera:1': t.callpipCameraOff,
        'camera:0': t.callpipCameraOn,
        'end:0': t.callpipEnd,
      };
    } catch (_) {
      return null;
    }
  }

  /// The PiP state for the current call (sent only when it changed).
  void syncPip() {
    try {
      final c = currentCall;
      final s = _currentSurface;
      final Object? any = s;
      final VideoSizeSource? size = any is VideoSizeSource ? any : null;
      final st = c == null
          ? PipState.off
          : pipStateFor(
              videoOn: c.videoOn,
              live: c.isLive,
              ended: c.isEnded,
              muted: c.muted,
              cameraOn: c.cameraOn,
              remoteW: size?.remoteVideoWidth,
              remoteH: size?.remoteVideoHeight);
      unawaited(CallNative.setPip(st, labels: _pipLabels()));
      // the call ended (or became voice) while Android showed the PiP
      // window: close it like WhatsApp — Assisto goes to the background
      if (!st.auto && CallNative.inPip.value && (c == null || c.isEnded)) {
        unawaited(CallNative.leaveApp(pip: false));
      }
    } catch (e) {
      callLog('call_runtime#11', e);
    }
  }

  /// A button inside the PiP window.
  @visibleForTesting
  void onPipAction(String id) {
    final c = currentCall;
    if (c == null) return;
    switch (id) {
      case 'mute':
        unawaited(c.toggleMute());
        break;
      case 'camera':
        unawaited(c.toggleCamera());
        break;
      case 'end':
        unawaited(c.hangup());
        break;
    }
  }

  /// "Return to call" on the ongoing-call notification: a minimized call
  /// opens full screen (a call screen already on top simply shows).
  @visibleForTesting
  void onCallReturn() {
    if (ongoing.value != null) restoreOngoing();
  }

  void _cameraForLifecycle(AppLifecycleState s) {
    try {
      final c = currentCall;
      if (c == null) return;
      final inPip = CallNative.inPip.value;
      if (shouldPauseCameraBg(
          state: s,
          inPip: inPip,
          videoOn: c.videoOn,
          cameraOn: c.cameraOn,
          live: c.isLive)) {
        unawaited(c.setBackgroundCameraPause(true));
      } else if (shouldResumeCameraBg(
          state: s, inPip: inPip, pausedBg: c.cameraPausedBg)) {
        unawaited(c.setBackgroundCameraPause(false));
      }
    } catch (e) {
      callLog('call_runtime#12', e);
    }
  }

  /// Back on Assisto's LAST screen during a call. Flutter would finish the
  /// activity (and the call with the engine): instead PiP for a live video
  /// call, else Assisto goes to the background. Runs after the app's
  /// Navigator (registered later), so any screen that can go back still
  /// does.
  @override
  Future<bool> didPopRoute() async {
    try {
      final c = currentCall;
      final act = rootBackAction(
          callActive: c != null || callActive,
          videoLive: c != null &&
              wantAutoPip(videoOn: c.videoOn, live: c.isLive, ended: c.isEnded));
      if (act == RootBackAction.none) return false;
      final nav = _nav?.currentState;
      if (nav != null && nav.canPop()) return false;
      await CallNative.leaveApp(pip: act == RootBackAction.pip);
      return true;
    } catch (e) {
      callLog('call_runtime#13', e);
      return false;
    }
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
    // calls-a: opened from the notification / full-screen intent already
    if (CallLaunchRouter.instance.handled(id)) return;
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
    CallLaunchRouter.instance.claim(id, CallLaunch.actionOpen);
    try {
      nav.push(instantCallRoute<void>(
          (_) => IncomingCallScreen(payload: p, ringInApp: true),
          name: CallLaunchRouter.ringRouteName));
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
    if (_pipWatched) CallNative.inPip.removeListener(_onPipChanged);
    _pipWatched = false;
    _screenCall = null;
    _screenSurface = null;
    _sizeSrc?.removeListener(syncPip);
    _sizeSrc = null;
    if (_observing) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
      _observing = false;
    }
    CallNative.onPipAction = null;
    CallNative.onCallReturn = null;
    CallNative.resetPipForTest();
    _wasInPip = false;
    _screenOwner = null;
    _screenLive = null;
    _app?.removeListener(_onApp);
    _app = null;
    _started = false;
  }
}
