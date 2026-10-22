import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../push/incoming_call_screen.dart';
import '../push/push_notifier.dart';
import '../push/push_payload.dart';
import '../realtime/realtime_transport.dart';
import '../state.dart';
import 'call_native.dart';
import 'call_sound_prefs.dart';

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
  PollRealtimeTransport transportFor(AppState app) {
    _app ??= app;
    final t = _transport ??= PollRealtimeTransport.forApi(app.api);
    if (!t.running) unawaited(t.connect());
    return t;
  }

  Future<void> start(AppState app, GlobalKey<NavigatorState> nav,
      {bool pushAvailable = false}) async {
    _app = app;
    _nav = nav;
    _pushAvailable = pushAvailable;
    if (_started) return;
    _started = true;
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
    app.addListener(_onApp);
    _onApp();
  }

  void setPushAvailable(bool v) {
    _pushAvailable = v;
    _transport?.idleInterval =
        Duration(milliseconds: v ? 5000 : 2500);
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
    } catch (_) {}
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
    } catch (_) {}
  }

  /// A foreground FCM ring (PushService routes it here instead of drawing a
  /// notification while we are on screen).
  void onPushRing(PushPayload p) => onIncoming({
        'call_id': p.callId,
        'caller_name': p.callerName,
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

  void onIncoming(Map<String, dynamic> row) {
    final id = '${row['call_id'] ?? ''}';
    if (id.isEmpty || _shown.contains(id)) return;
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
      'video': row['video'] == true || row['kind'] == 'video' ? 'true' : 'false',
      'chat_id': '${row['chat_id'] ?? ''}',
      'lang': _app?.locale?.languageCode == 'en' ? 'en' : 'bn',
    });
    try {
      nav.push(MaterialPageRoute(
          builder: (_) => IncomingCallScreen(payload: p, ringInApp: true)));
    } catch (_) {}
  }

  /// In-app ring: the chosen ringtone (phone default when none), respecting
  /// silent / vibrate / Do-Not-Disturb natively; tells the caller we ring.
  Future<void> startRinging(PushPayload p) async {
    unawaited(_event(p.callId, 'ringing'));
    try {
      final uri = await CallSoundPrefs.ringtoneFor(p.chatId);
      await CallNative.startRingtone(uri);
    } catch (_) {}
  }

  Future<void> stopRinging() => CallNative.stopRingtone();

  Future<void> _event(String callId, String event) async {
    final app = _app;
    if (app == null) return;
    try {
      await app.api.postJson('/circle/calls/$callId/event', {'event': event});
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _sub?.cancel();
    _sub = null;
    unawaited(_transport?.close());
    _transport = null;
    _shown.clear();
    activeCallId = null;
    _app?.removeListener(_onApp);
    _app = null;
    _started = false;
  }
}
