/// p2-money: the APP-OPEN gate — pure Dart, unit-tested (test/p2_money_test.dart).
///
/// The server re-checks every rule in `GET /ads/slot?placement=app_open`;
/// this client mirror only avoids a network call when the answer is
/// obviously "no". Owner order:
///  * Free users only; from day N after sign-up (default 2);
///  * at most N a day (default 3) with a minimum gap;
///  * never when the app was opened from a notification / deep link / call /
///    SOS / widget / assistant (that tap may be an SOS, a call or a payment);
///  * never on safety, payment, login or call screens (home only);
///  * skippable after 5 s.
library;

import 'ad_rules.dart';

/// Remembers HOW the app was last brought to the front. Anything external
/// (a notification tap, a deep link, an incoming call, SOS, the home-screen
/// widget, the assistant gesture) blocks the app-open ad for that entry.
class AppEntry {
  AppEntry._();

  static const blockedKinds = {
    'notification', 'deeplink', 'call', 'sos', 'share', 'widget', 'assist',
    // admob (owner 25 Oct)
    'safety_alert', 'alarm', 'reminder', 'native_launch',
  };

  static String _kind = '';
  static DateTime? _at;

  /// admob: "suppress the NEXT app-open" — set by every external entry and
  /// consumed by the next app-open attempt, however late it comes (a cold
  /// start from a notification may reach the ad check after [window]).
  static bool _suppressNext = false;

  /// How long after an external entry the app-open ad stays blocked (the
  /// resume event and the tap's own navigation arrive within this window).
  static const window = Duration(seconds: 20);

  static void mark(String kind, {DateTime? now}) {
    _kind = kind;
    _at = now ?? DateTime.now();
    if (blockedKinds.contains(kind)) _suppressNext = true;
  }

  /// true once after an external entry (then cleared).
  static bool consumeSuppression() {
    final s = _suppressNext;
    _suppressNext = false;
    return s;
  }

  /// The entry kind to report to the server ('' = a normal open).
  static String current({DateTime? now}) {
    final at = _at;
    if (at == null) return '';
    if ((now ?? DateTime.now()).difference(at) > window) return '';
    return _kind;
  }

  static bool blocked({DateTime? now}) =>
      blockedKinds.contains(current(now: now));

  static void reset() {
    _kind = '';
    _at = null;
    _suppressNext = false;
  }
}

/// admob (owner 25 Oct): the session rules around an app-open ad — pure,
/// unit-tested. On top of [AppOpenGate] (plan, caps, gap, day-N, screen):
///  * never on the very first launch of the app, ever;
///  * never in the session right after a sign-in (or sign-up);
///  * never after an external entry (notification, SOS, safety alert, call,
///    alarm, reminder, widget, deep link, assist) — [suppressed];
///  * on a resume, only after the app was in the background >= [minBackground]
///    (a quick app switch is not an "app open");
///  * never while a forbidden screen is on top (only the home root);
///  * never while a call is going on (even minimised to the mini bar).
class AppOpenGuard {
  AppOpenGuard._();

  static AdDecision check({
    required bool firstLaunchEver,
    required bool sessionAfterLogin,
    required bool suppressed,
    required String screen,
    required bool resumed,
    Duration? backgroundFor,
    Duration minBackground = const Duration(seconds: 30),
    bool callActive = false,
  }) {
    if (callActive) return const AdDecision(false, 'in_call');
    if (firstLaunchEver) return const AdDecision(false, 'first_launch');
    if (sessionAfterLogin) return const AdDecision(false, 'after_login');
    if (suppressed) return const AdDecision(false, 'blocked_entry');
    if (screen != 'home' || AdRules.isBlockedScreen(screen)) {
      return const AdDecision(false, 'blocked_screen');
    }
    if (resumed) {
      final min = minBackground < const Duration(seconds: 5)
          ? const Duration(seconds: 5)
          : minBackground;
      if (backgroundFor == null || backgroundFor < min) {
        return const AdDecision(false, 'short_background');
      }
    }
    return AdDecision.ok;
  }
}

class AppOpenGate {
  AppOpenGate._();

  /// The owner's floor for the gap (owner 26 Oct: at most once every 3 h;
  /// server bounds 3 h .. 24 h).
  static const minGap = Duration(hours: 3);

  /// Day 1 = the sign-up (local) day.
  static int dayNumber(DateTime? joined, DateTime now) {
    if (joined == null) return 1;
    final j = DateTime(joined.year, joined.month, joined.day);
    final n = DateTime(now.year, now.month, now.day);
    return n.difference(j).inDays + 1;
  }

  static AdDecision decide({
    required bool loggedIn,
    required bool paid,
    required bool enabled,
    required String screen,
    required String entry,
    required DateTime now,
    DateTime? joined,
    int startDay = 2,
    int dailyCap = 3,
    int shownToday = 0,
    Duration gap = const Duration(hours: 3),
    DateTime? lastShownAt,
  }) {
    if (!loggedIn) return const AdDecision(false, 'logged_out');
    if (paid) return const AdDecision(false, 'paid_plan');
    if (!enabled) return const AdDecision(false, 'disabled');
    if (AppEntry.blockedKinds.contains(entry)) {
      return const AdDecision(false, 'blocked_entry');
    }
    if (screen != 'home' || AdRules.isBlockedScreen(screen)) {
      return const AdDecision(false, 'blocked_screen');
    }
    if (dailyCap <= 0) return const AdDecision(false, 'disabled');
    // unknown sign-up date -> the server decides the day-N rule
    if (joined != null && dayNumber(joined, now) < (startDay < 1 ? 1 : startDay)) {
      return const AdDecision(false, 'too_new');
    }
    if (shownToday >= dailyCap) return const AdDecision(false, 'daily_cap');
    final g = gap < minGap ? minGap : gap;
    if (lastShownAt != null && now.difference(lastShownAt) < g) {
      return const AdDecision(false, 'too_soon');
    }
    return AdDecision.ok;
  }
}

/// The Skip countdown on a full-screen sponsor card: Skip works only after
/// [seconds] (owner: 5 s). Pure so it is unit-testable.
class SkipCountdown {
  SkipCountdown(int seconds) : total = seconds < 5 ? 5 : (seconds > 15 ? 15 : seconds);

  final int total;
  int elapsed = 0;

  int get remaining => (total - elapsed).clamp(0, total);
  bool get canSkip => remaining == 0;

  /// One second passed. Returns true when the state changed.
  bool tick() {
    if (canSkip) return false;
    elapsed++;
    return true;
  }
}
