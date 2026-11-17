import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// ads-guard (owner 17 Nov): THE central "no ad right now" switch.
///
/// No ad of ANY kind (app open, interstitial, rewarded, native, banner,
/// direct sponsor card) may load or show while:
///  * a safety / call screen is open — each one holds the context with
///    [AdBlockedState] (SOS, Emergency, Safe Journey, Family Care, kids
///    watch, Care Call, Quran, blood donor, call ring / in-call ...);
///  * a call is ringing or going on (the [callProbe], set by AdsService from
///    CallRuntime, and [noteCall]);
///  * for [cooldown] after the last of those ended (a return to the app right
///    after a call or an SOS never gets an app-open ad);
///  * the plan does not allow ads (Premium / Plus / Business —
///    [planAllowsAds] false). Unknown (config not loaded yet) blocks the
///    SDK itself ([sdkAllowed]); screens then follow their own config.
///
/// Every ad path asks [blocked] (AdmobSdk.ensureReady / request, app-open,
/// interstitial, rewarded) and every on-screen ad slot listens to
/// [listenable] and hides itself at once. Pure Dart + Flutter foundation:
/// unit-testable, no plugin.
class AdBlockContext {
  AdBlockContext._();

  /// A return this soon after a call / safety screen ended is still blocked.
  static const cooldown = Duration(minutes: 2);

  static final Map<String, int> _holds = <String, int>{};
  static bool _callActive = false;
  static bool? _planAllowsAds;
  static DateTime? _releasedAt;

  /// Changes whenever [blocked] may have changed (screens, call, plan).
  static final ValueNotifier<int> listenable = ValueNotifier<int>(0);

  /// Is a call ringing / going on right now? (AdsService wires CallRuntime;
  /// an error counts as "yes" — never risk an ad over a call.)
  static bool Function() callProbe = () => false;

  /// Test seam.
  static DateTime Function() clock = DateTime.now;

  /// Called after a purchase / plan change might have happened (AdsService
  /// re-reads /ads/config). Set by AdsService.
  static void Function()? onPlanMaybeChanged;

  static bool _bumpPending = false;

  /// Notify listeners — but never in the middle of a build / unmount (a
  /// safety screen enters in initState and leaves in dispose): then after
  /// this frame, so no "markNeedsBuild during build".
  static void _bump() {
    try {
      final b = SchedulerBinding.instance;
      if (b.schedulerPhase == SchedulerPhase.persistentCallbacks) {
        if (_bumpPending) return;
        _bumpPending = true;
        b.addPostFrameCallback((_) {
          _bumpPending = false;
          listenable.value = listenable.value + 1;
        });
        return;
      }
    } catch (_) {
      // no binding (pure unit test): notify now
    }
    listenable.value = listenable.value + 1;
  }

  /// A safety / call screen opened.
  static void enter(String reason) {
    _holds[reason] = (_holds[reason] ?? 0) + 1;
    _bump();
  }

  /// That screen closed. When the last hold goes, the [cooldown] starts.
  static void leave(String reason) {
    final n = (_holds[reason] ?? 0) - 1;
    if (n <= 0) {
      _holds.remove(reason);
    } else {
      _holds[reason] = n;
    }
    if (_holds.isEmpty) _releasedAt = clock();
    _bump();
  }

  /// The call state changed (ring / answer / hang up).
  static void noteCall(bool active) {
    if (_callActive && !active) _releasedAt = clock();
    _callActive = active;
    _bump();
  }

  /// /ads/config: Free + ads on -> true; paid / minor / ads off -> false;
  /// null = not loaded yet.
  static set planAllowsAds(bool? v) {
    if (_planAllowsAds == v) return;
    _planAllowsAds = v;
    _bump();
  }

  static bool? get planAllowsAds => _planAllowsAds;

  /// A purchase may have changed the plan: stop every ad NOW (until the
  /// fresh config says Free again) and ask for that config.
  static void planMaybeChanged() {
    planAllowsAds = false;
    try {
      onPlanMaybeChanged?.call();
    } catch (_) {}
  }

  static bool _callNow() {
    if (_callActive) return true;
    try {
      return callProbe();
    } catch (_) {
      return true;
    }
  }

  /// Why no ad may show right now ('' = an ad may show). Full-screen ads
  /// (app open, interstitial, rewarded) use this, cooldown included.
  static String reason({DateTime? now}) {
    if (_planAllowsAds == false) return 'plan';
    if (_holds.isNotEmpty) return 'screen:${_holds.keys.first}';
    if (_callNow()) return 'in_call';
    final r = _releasedAt;
    if (r != null && (now ?? clock()).difference(r) < cooldown) {
      return 'cooldown';
    }
    return '';
  }

  static bool get blocked => reason().isNotEmpty;

  /// Inline slots (banner, native): blocked by plan / safety screen / call,
  /// but not by the after-call [cooldown] (a banner on a normal page is fine
  /// a minute after a call; an app-open pop-up is not).
  static bool get blockedNow {
    final r = reason();
    return r.isNotEmpty && r != 'cooldown';
  }

  /// The Mobile Ads SDK may initialise / request: only for a CONFIRMED Free
  /// plan (never before /ads/config said so) and never in a blocked context.
  static bool get sdkAllowed => _planAllowsAds == true && !blockedNow;

  /// The screens holding the context right now (tests / debug).
  static Set<String> get holders => Set.unmodifiable(_holds.keys);

  @visibleForTesting
  static void resetForTest({bool? planAllowsAds = true}) {
    _holds.clear();
    _callActive = false;
    _planAllowsAds = planAllowsAds;
    _releasedAt = null;
    callProbe = () => false;
    clock = DateTime.now;
    onPlanMaybeChanged = null;
    _bumpPending = false;
    listenable.value = listenable.value + 1;
  }
}

/// Mix into the State of every safety / call screen: holds the
/// [AdBlockContext] while the screen is alive (test/ads_block_context_test
/// checks every screen in its list uses it).
mixin AdBlockedState<T extends StatefulWidget> on State<T> {
  String get adBlockReason => T.toString();

  @override
  void initState() {
    super.initState();
    AdBlockContext.enter(adBlockReason);
  }

  @override
  void dispose() {
    AdBlockContext.leave(adBlockReason);
    super.dispose();
  }
}

/// Hides [child] (an ad slot) while [AdBlockContext.blocked].
class AdBlockGate extends StatelessWidget {
  const AdBlockGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: AdBlockContext.listenable,
        builder: (_, __, ___) =>
            AdBlockContext.blockedNow ? const SizedBox.shrink() : child,
      );
}
