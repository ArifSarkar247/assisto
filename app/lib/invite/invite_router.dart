import 'dart:async';

import 'package:flutter/material.dart';

import '../growth/growth_api.dart';
import '../growth/install_ping.dart';
import '../push/push_service.dart' show appNavigatorKey;
import '../state.dart';
import 'invite_join_screen.dart';
import 'invite_link.dart';

/// invite-join — the glue between where a code arrives and what the root
/// shows. ONE path decides the screen (no double pushes):
///  * signed out + pending code -> the root shows [InviteJoinScreen] instead
///    of the login screen (and instead of the first-run language gate: the
///    join screen carries its own language switch);
///  * signed in + pending code  -> [InviteJoinScreen] pushed once on top.
/// A warm App Link ("/i/<CODE>" via onGenerateRoute) only records the code and
/// returns a route that removes itself at once.
class InviteRouter {
  InviteRouter._();

  static String? _pushed;
  static bool _refClaimTried = false;
  static bool _started = false;

  /// MaterialApp.onGenerateRoute hook. null = not ours.
  static Route<dynamic>? route(RouteSettings s) {
    final n = s.name ?? '';
    if (!n.startsWith('/i/')) return null;
    if (!PendingInvite.takeLink(n)) return null;
    return PageRouteBuilder<void>(
      settings: s,
      opaque: false,
      pageBuilder: (ctx, _, __) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final nav = Navigator.maybeOf(ctx);
          if (nav != null && nav.canPop()) nav.pop();
        });
        return const SizedBox.shrink();
      },
    );
  }

  /// Root initState (after the first frame): cold-start URL, the code saved
  /// by an earlier launch, then (once per install) the Play Install Referrer. All guarded; never blocks the first frame.
  static void start(String defaultRouteName) {
    if (_started) return;
    _started = true;
    if (!defaultRouteName.startsWith('/')) PendingInvite.takeLink(defaultRouteName);
    unawaited(PendingInvite.load());
    // Shortly after the first frame (never on the cold-start path); Play
    // usually answers in well under a second, so a fresh install switches
    // from the language screen to "Join X's circle" almost at once.
    Timer(const Duration(milliseconds: 300), () {
      unawaited(PendingInvite.readReferrerOnce());
    });
  }

  /// Signed-out root: the join screen when a code is waiting, else null.
  static Widget? signedOutRoot() {
    final c = PendingInvite.code.value;
    if (c == null) return null;
    return InviteJoinScreen(
        key: ValueKey('ij-root-$c'), code: c, via: PendingInvite.via, asRoot: true);
  }

  /// The join screen already handles [code] (sign-up in progress).
  static void markHandled(String code) => _pushed = code;

  /// Signed-in: push the one-tap join once per code; back = "not now".
  static void maybePushSignedIn(AppState app) {
    final c = PendingInvite.code.value;
    if (c == null || !app.loggedIn || _pushed == c) return;
    _pushed = c;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final nav = appNavigatorKey.currentState;
      if (nav == null) return;
      await nav.push(MaterialPageRoute<void>(
          builder: (_) => InviteJoinScreen(code: c, via: PendingInvite.via)));
      if (PendingInvite.code.value == c) await PendingInvite.clear();
    });
  }

  /// A p5 referral code that came by /i/<REF> or the referrer: claim it once
  /// after sign-in (the server applies every referral rule).
  static void maybeClaimReferral(AppState app) {
    final r = PendingInvite.referral;
    if (r == null || !app.loggedIn || _refClaimTried) return;
    _refClaimTried = true;
    unawaited(() async {
      try {
        final dev = await InstallPing.installId();
        await app.api.growthClaim(r, deviceId: dev);
      } catch (_) {} // best-effort: background referral claim
      await PendingInvite.clearReferral();
    }());
  }
}
