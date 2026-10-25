import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ads/ads_service.dart' show AdsService;
import '../ads/hero_ad.dart';
import '../ads/hero_binding.dart';
import '../ads/sponsor_api.dart';
import '../ads/sponsor_models.dart';
import '../ads/sponsor_widgets.dart' show SponsorHeroCard;
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';

/// HOME HERO slot (h1-home). Shows [fallback] (the logo + "Hi, I'm Assisto"
/// block) by default — instantly, never a spinner — and, for a Free user with
/// the owner's hero flag ON and AdMob linked, swaps it IN THE SAME SLOT for
/// one large native ad with an "Ad" label. See [HeroAdRules] for every rule.
///
/// p2-money: a DIRECT sponsor campaign for the hero (owner-sold, server
/// served, works without AdMob) is shown FIRST in the same slot with a
/// "Sponsored" label; AdMob's native ad only fills the slot when no direct
/// campaign is live (and only once AdMob is linked).
///
/// Crash-guarded: any failure keeps the normal logo block.
class HomeHero extends StatefulWidget {
  const HomeHero({
    super.key,
    required this.fallback,
    this.collapsed = false,
    this.availableHeight,
    this.bridge,
    this.loadConfig,
    this.isHomeVisible,
    this.sponsor,
  });

  /// The normal logo block (no fill / offline / paid / not linked / collapsed).
  final Widget fallback;

  /// True while the chat input has focus -> the ad goes away.
  final bool collapsed;

  /// The height the welcome area really has (null = use the screen height).
  /// The ad box never exceeds it, so the ad is never cut off or pushed under
  /// the input; too little room -> the normal logo block.
  final double? availableHeight;

  /// Injectable for tests / the screenshot gallery.
  final HeroAdBridge? bridge;
  final Future<Map<String, dynamic>> Function()? loadConfig;
  final bool Function()? isHomeVisible;

  /// p2-money: injectable direct-sponsor backend (tests / gallery).
  final SponsorBackend? sponsor;

  /// Screenshot-gallery / test seams for the HomeScreen-hosted hero (which is
  /// built without arguments). Never set in the app.
  @visibleForTesting
  static HeroAdBridge? debugBridge;
  @visibleForTesting
  static Future<Map<String, dynamic>> Function()? debugLoadConfig;

  @visibleForTesting
  static SponsorBackend? debugSponsor;

  @visibleForTesting
  static void debugReset() {
    debugBridge = null;
    debugLoadConfig = null;
    debugSponsor = null;
    _HomeHeroState._cfgCache = null;
    _HomeHeroState._cfgAt = null;
  }

  @override
  State<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends State<HomeHero> with WidgetsBindingObserver {
  static Map<String, dynamic>? _cfgCache;
  static DateTime? _cfgAt;

  late final HeroAdBridge _bridge =
      widget.bridge ?? HomeHero.debugBridge ?? createHeroAdBridge();
  Future<Map<String, dynamic>> Function()? get _injectedConfig =>
      widget.loadConfig ?? HomeHero.debugLoadConfig;
  HeroAdConfig _cfg = HeroAdConfig.none;
  HeroAdHandle? _ad;
  SponsorCreative? _direct; // p2-money
  Timer? _timer;
  DateTime? _lastLoad;
  bool _loading = false;
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // lazy: nothing ad-related before the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didUpdateWidget(covariant HomeHero old) {
    super.didUpdateWidget(old);
    if (widget.collapsed && !old.collapsed) {
      _drop();
    } else if (!widget.collapsed && old.collapsed) {
      _start();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed && _ad == null && _direct == null) _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _disposeAd();
    super.dispose();
  }

  void _disposeAd() {
    try {
      _ad?.dispose();
    } catch (_) {}
    _ad = null;
    _direct = null;
    HomeAdGuard.heroShowing.value = false;
  }

  void _drop() {
    _timer?.cancel();
    _timer = null;
    if (_ad != null || _direct != null) setState(_disposeAd);
  }

  bool _homeVisible() {
    try {
      final f = widget.isHomeVisible;
      if (f != null) return f();
      return ModalRoute.of(context)?.isCurrent ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<HeroAdConfig> _config() async {
    try {
      final fresh = _cfgAt != null &&
          DateTime.now().difference(_cfgAt!) < const Duration(minutes: 30);
      if (!fresh || _injectedConfig != null) {
        final load = _injectedConfig ??
            () => context.read<AppState>().api.getJson('/ads/config');
        _cfgCache = await load();
        _cfgAt = DateTime.now();
      }
      return HeroAdConfig.fromJson(_cfgCache);
    } catch (_) {
      return HeroAdConfig.none; // offline -> normal logo block
    }
  }

  /// The ad box height: the room the slot really has minus the "Ad" label
  /// row, capped at 340 (AdMob medium template).
  double _slotHeight() {
    final avail = widget.availableHeight ?? MediaQuery.of(context).size.height * 0.42;
    return (avail - _labelRow).clamp(0.0, 340.0);
  }

  static const double _labelRow = 28;

  HeroDecision _decide({bool direct = false}) {
    bool loggedIn;
    try {
      loggedIn = context.read<AppState>().loggedIn;
    } catch (_) {
      loggedIn = _injectedConfig != null; // gallery/tests inject config
    }
    return HeroAdRules.decide(
      config: _cfg,
      screen: _homeVisible() ? 'home' : 'unknown',
      loggedIn: loggedIn,
      collapsed: widget.collapsed,
      chatStarted: false, // the thread unmounts this slot once a chat starts
      linked: direct || _bridge.linked,
      slotHeight: _slotHeight(),
    );
  }

  SponsorBackend? get _sponsor {
    try {
      return widget.sponsor ??
          HomeHero.debugSponsor ??
          ApiSponsorBackend(context.read<AppState>().api);
    } catch (_) {
      return null;
    }
  }

  /// p2-money: direct sponsor first. true = the slot is handled (direct
  /// creative shown, or the server said nothing may fill it).
  Future<bool> _tryDirect() async {
    if (!_decide(direct: true).allowed) return false;
    final b = _sponsor;
    if (b == null) return false;
    try {
      final s = await b.slot('hero');
      if (!mounted || widget.collapsed || !_decide(direct: true).allowed) {
        return true;
      }
      if (s.isDirect) {
        _lastLoad = DateTime.now();
        setState(() {
          _disposeAdOnly();
          _direct = s.creative;
        });
        HomeAdGuard.heroShowing.value = true;
        unawaited(b.event(s.creative!.token, 'impression'));
        return true;
      }
      // 'admob' -> let AdMob fill; 'none' (no fill / blocked) -> AdMob may
      // still try when linked (the server only says admob when it is).
      return !s.isAdmob && !_bridge.linked;
    } catch (_) {
      return false; // offline / old server -> the AdMob path decides
    }
  }

  void _disposeAdOnly() {
    try {
      _ad?.dispose();
    } catch (_) {}
    _ad = null;
  }

  Future<void> _start() async {
    if (!mounted || _loading || widget.collapsed) return;
    // AdMob minimum refresh also applies to re-showing after a collapse
    if (_lastLoad != null &&
        DateTime.now().difference(_lastLoad!) < HeroAdRules.refreshEvery(_cfg)) {
      _schedule();
      return;
    }
    _loading = true;
    try {
      _cfg = await _config();
      if (!mounted) return;
      if (await _tryDirect()) return;
      if (!mounted || !_decide().allowed) return;
      final unit = _cfg.unit(
          builtAppId: AdsService.builtAppId, testMode: AdsService.testMode);
      if (unit == null) return;
      _lastLoad = DateTime.now();
      final ad = await _bridge
          .load(unit, startMuted: AdSound.startMuted(AdFormat.heroNative,
              heroStartMuted: _cfg.startMuted))
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
      if (!mounted || widget.collapsed || !_decide().allowed) {
        try {
          ad?.dispose();
        } catch (_) {}
        return;
      }
      if (ad != null) {
        final old = _ad;
        setState(() {
          _ad = ad;
          _direct = null;
        });
        HomeAdGuard.heroShowing.value = true;
        try {
          old?.dispose();
        } catch (_) {}
      }
    } catch (_) {
      // never let an ad problem reach the UI
    } finally {
      _loading = false;
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!mounted || widget.collapsed || !_cfg.enabled) return;
    _timer = Timer(HeroAdRules.refreshEvery(_cfg), () {
      if (!mounted) return;
      // refresh only while home is really on screen and the app is in front
      if (_resumed && _homeVisible() && !widget.collapsed) {
        _lastLoad = null;
        _start();
      } else {
        _schedule();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    final direct = _direct;
    final room = _slotHeight() >= HeroAdRules.minSlotHeight;
    final child = (direct != null && !widget.collapsed && room)
        ? KeyedSubtree(
            key: const ValueKey('hero-sponsor'),
            child: SponsorHeroCard(
                creative: direct,
                height: _slotHeight(),
                onClick: () => unawaited(_sponsor?.event(direct.token, 'click'))))
        : (ad == null || widget.collapsed || !room)
        ? KeyedSubtree(key: const ValueKey('hero-logo'), child: widget.fallback)
        : HeroAdFrame(
            key: const ValueKey('hero-ad'),
            height: _slotHeight(),
            hasVideo: ad.hasVideo,
            startMuted: _cfg.startMuted,
            child: ad.view());
    // Only the CURRENT child is laid out (the old one is dropped at once), so
    // the ad and the logo block never overlap, not even mid-fade.
    return AnimatedSwitcher(
      duration: Motion.base,
      layoutBuilder: (current, previous) => current ?? const SizedBox.shrink(),
      child: child,
    );
  }
}

/// The frame around a native ad: an "Ad" label row OUTSIDE the ad view (so it
/// never covers ad content) and a fixed-height box so the ad can never grow
/// into the chat or the input.
class HeroAdFrame extends StatelessWidget {
  const HeroAdFrame({
    super.key,
    required this.height,
    required this.child,
    this.hasVideo = false,
    this.startMuted = true,
  });
  final double height;
  final Widget child;
  final bool hasVideo;
  final bool startMuted;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: t.h1HeroAdSemantics,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Text(t.h1AdLabel,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.onTertiaryContainer)),
          ),
          if (hasVideo && startMuted) ...[
            const SizedBox(width: Gap.sm),
            Icon(Icons.volume_off_rounded, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(t.h1HeroMutedHint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
          ],
        ]),
        const SizedBox(height: Gap.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: SizedBox(height: height, child: child),
        ),
      ]),
    );
  }
}
