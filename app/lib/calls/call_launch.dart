import 'dart:async';

import 'package:flutter/material.dart';

import '../ads/app_open_gate.dart' show AppEntry;
import '../push/incoming_call_screen.dart';
import '../push/push_payload.dart';
import '../screens/circle_call_screen.dart';
import 'call_log.dart';
import 'call_runtime.dart';

/// calls-a (owner 27 Oct): "Accept must open the in-call screen directly in
/// one smooth step".
///
/// Every way a ringing call can be opened ends HERE, and here only:
///
/// | entry          | how it arrives                                   |
/// |----------------|--------------------------------------------------|
/// | cold accept    | initial route from MainActivity.getInitialRoute  |
/// | cold open      | (tap / full-screen intent, incl. lock screen)    |
/// | warm accept    | native "callLaunch" (MainActivity.onNewIntent)   |
/// | warm open      |   or flutter_local_notifications' response       |
/// | in-app accept  | the ringing screen's own Accept                  |
///
/// Rules (each one fixes a part of the owner's "home, then half-dark
/// 'Call ended' split screen, then it connects"):
///  * the FIRST Flutter frame of a cold call launch is the call screen
///    (Accept) or the ringing screen (tap / full-screen) — the home is built
///    underneath but never painted;
///  * ONE screen per call id: the same Accept delivered twice (native +
///    notification plugin, or the server still listing the call as ringing
///    on resume) never stacks a second call / ringing screen — the stacked
///    ringing screen was what showed "Call ended" when the call was answered;
///  * call routes switch INSTANTLY (no zoom transition and no snapshot), so a
///    window that is still waking / resizing over the lock screen can never
///    show a half-drawn frame;
///  * the call starts as soon as the session token is read — it no longer
///    waits for the profile sync or for push start-up (2-7 s).
class CallLaunch {
  CallLaunch({required this.action, required this.payload});

  /// 'accept' (answer now) | 'open' (show the ringing screen).
  final String action;
  final PushPayload payload;

  bool get accept => action == actionAccept;
  String get callId => payload.callId;

  static const String route = '/assisto_call';
  static const String actionAccept = 'accept';
  static const String actionOpen = 'open';

  /// The route MainActivity.getInitialRoute builds (CallLaunch.kt).
  static CallLaunch? parseRoute(String? name) {
    try {
      if (name == null || !name.startsWith(route)) return null;
      final q = name.indexOf('?');
      if (q < 0 || name.substring(0, q) != route) return null;
      final args = Uri.splitQueryString(name.substring(q + 1));
      return fromParts(args['a'], args['p']);
    } catch (e) {
      callLog('call_launch#1', e);
      return null;
    }
  }

  /// action + payload JSON (the native warm launch / the route's parts).
  static CallLaunch? fromParts(String? action, String? payloadJson) {
    final p = PushPayload.decode(payloadJson);
    if (p == null || !p.isCall || p.callId.isEmpty) return null;
    final a = action == actionAccept ? actionAccept : actionOpen;
    return CallLaunch(action: a, payload: p);
  }

  /// Test seam: the route string exactly as CallLaunch.kt builds it
  /// (URLEncoder: space -> '+', everything else %XX).
  @visibleForTesting
  static String routeFor(String action, Map<String, String> data) {
    String enc(String s) => Uri.encodeQueryComponent(s);
    final p = PushPayload(data);
    return '$route?a=$action&id=${enc(p.callId)}&p=${enc(p.encode())}';
  }

  /// The member map the call screen wants, from the push payload.
  Map<String, dynamic> get member => {
        'id': int.tryParse(payload.chatId),
        'name': payload.callerName,
        'photo_url': payload.callerPhoto,
      };
}

/// A call / ringing route that appears and goes WITHOUT a transition (no
/// zoom, no snapshot) — calls-a, the half-drawn frame fix.
Route<T> instantCallRoute<T>(WidgetBuilder builder, {String? name}) =>
    PageRouteBuilder<T>(
      settings: RouteSettings(name: name),
      opaque: true,
      allowSnapshotting: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, _, __) => builder(context),
    );

/// How a call screen was reached (logs + tests).
enum CallEntry { coldAccept, coldOpen, warmAccept, warmOpen, inAppAccept }

class CallLaunchRouter {
  CallLaunchRouter._();
  static final CallLaunchRouter instance = CallLaunchRouter._();

  static const String acceptRouteName = 'call_accept';
  static const String ringRouteName = 'call_ringing';

  /// call id -> 1 (ringing screen shown) | 2 (answered / call screen up).
  final Map<String, int> _level = {};

  /// Ringing screens on screen right now: call id -> their own Accept.
  final Map<String, VoidCallback> _ringing = {};

  /// Every routing decision (newest last) — tests + the CI ring-proof log.
  final List<String> decisions = [];

  GlobalKey<NavigatorState>? _nav;

  /// The call / ringing route a cold start opened with (first-frame log).
  Route<dynamic>? coldRoute;

  /// main.dart: the app navigator (pure Dart, before the first frame).
  void attach(GlobalKey<NavigatorState> nav) => _nav = nav;

  /// Was a screen for [callId] already shown at [action]'s level or higher?
  /// Claims it otherwise. One Accept per call; Accept after "open" wins.
  bool claim(String callId, String action) {
    if (callId.isEmpty) return false;
    final lvl = action == CallLaunch.actionAccept ? 2 : 1;
    if ((_level[callId] ?? 0) >= lvl) return false;
    _level[callId] = lvl;
    // never let the in-app ring (real-time queue / resume check) stack a
    // ringing screen over this one
    CallRuntime.instance.markShown(callId);
    return true;
  }

  bool handled(String callId) => (_level[callId] ?? 0) > 0;
  bool answered(String callId) => (_level[callId] ?? 0) >= 2;

  /// IncomingCallScreen registers its Accept while it is up.
  void registerRinging(String callId, VoidCallback accept) =>
      _ringing[callId] = accept;
  void unregisterRinging(String callId, VoidCallback accept) {
    if (_ringing[callId] == accept) _ringing.remove(callId); // tear-offs: ==
  }

  void _log(CallEntry e, CallLaunch l, String result) {
    final line = 'CALL_ENTRY entry=${e.name} action=${l.action} '
        'id=${l.callId} result=$result';
    decisions.add(line);
    if (decisions.length > 40) decisions.removeAt(0);
    debugPrint(line); // the CI ring-proof greps this (release logcat too)
  }

  /// The screen for [l] (call screen for Accept, ringing screen otherwise).
  Route<void> routeFor(CallLaunch l) {
    if (l.accept) {
      return instantCallRoute<void>(
          (_) => CircleCallScreen(
                member: l.member,
                kind: l.payload.isVideo ? 'video' : 'voice',
                outgoing: false,
                callId: int.tryParse(l.callId),
              ),
          name: acceptRouteName);
    }
    return instantCallRoute<void>((_) => IncomingCallScreen(payload: l.payload),
        name: ringRouteName);
  }

  /// MaterialApp.onGenerateRoute for the cold-start route; null = not ours.
  Route<dynamic>? onGenerateRoute(RouteSettings s) {
    final l = CallLaunch.parseRoute(s.name);
    if (l == null) return null;
    AppEntry.mark('call'); // never an app-open ad for a call entry
    final e = l.accept ? CallEntry.coldAccept : CallEntry.coldOpen;
    if (!claim(l.callId, l.action)) {
      _log(e, l, 'duplicate');
      return null; // the Navigator falls back to home only
    }
    _log(e, l, l.accept ? 'first=call' : 'first=ringing');
    final r = routeFor(l);
    coldRoute = r;
    return r;
  }

  /// A launch while the app is running (native onNewIntent, the notification
  /// plugin's response, Telecom answer). Returns true when it was handled
  /// here (a duplicate counts as handled: nothing else may open it).
  bool openWarm(CallLaunch l, {NavigatorState? nav}) {
    AppEntry.mark('call');
    final e = l.accept ? CallEntry.warmAccept : CallEntry.warmOpen;
    final n = nav ?? _nav?.currentState;
    if (n == null) {
      _log(e, l, 'no_navigator');
      return false;
    }
    if (!claim(l.callId, l.action)) {
      _log(e, l, 'duplicate');
      return true;
    }
    // the ringing screen of THIS call is up: its own Accept (it replaces
    // itself with the call screen — never two screens)
    final ring = _ringing[l.callId];
    if (l.accept && ring != null) {
      _log(e, l, 'ringing_screen_accept');
      try {
        ring();
      } catch (err) {
        callLog('call_launch#2', err);
      }
      return true;
    }
    try {
      unawaited(n.push(routeFor(l)));
      _log(e, l, l.accept ? 'top=call' : 'top=ringing');
    } catch (err) {
      callLog('call_launch#3', err);
      _log(e, l, 'push_failed');
    }
    return true;
  }

  /// Native "callLaunch" {action, call_id, payload}.
  void onNative(Map<dynamic, dynamic>? args) {
    final l = CallLaunch.fromParts('${args?['action'] ?? ''}',
        args?['payload'] == null ? null : '${args!['payload']}');
    if (l != null) openWarm(l);
  }

  /// The in-app ringing screen's Accept (foreground / after "open").
  void noteInAppAccept(PushPayload p) {
    final l = CallLaunch(action: CallLaunch.actionAccept, payload: p);
    claim(l.callId, l.action);
    _log(CallEntry.inAppAccept, l, 'top=call');
  }

  @visibleForTesting
  void resetForTest() {
    _level.clear();
    _ringing.clear();
    decisions.clear();
    _nav = null;
    coldRoute = null;
  }
}
