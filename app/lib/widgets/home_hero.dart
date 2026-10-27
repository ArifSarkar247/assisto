import 'dart:async';

import 'package:clock/clock.dart';
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
import 'chatnav.dart';

/// HOME HERO slot (h1-home). Shows [fallback] (the logo + "Hi, I'm Assisto"
/// block) by default — instantly, never a spinner — and, for a Free user with
/// the owner's hero flag ON and AdMob linked, swaps it IN THE SAME SLOT for
/// one native ad with an "Ad" label. See [HeroAdRules] for every rule.
///
/// Owner feedback 27 Oct: compact (default, both homes; server
/// `home_native_size` can switch to "large" without a build) = AdMob's SMALL
/// native template, 90-110 dp, never a large media view; a separate
/// "Remove ads" link outside the ad opens the Premium plans; reload at most
/// once per 60 s (server `hero_refresh_sec`, never below 60) and ONLY while
/// home is the visible route and the app is resumed — no timer runs in the
/// background; at most `native_daily_cap` (20) impressions a day.
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
    this.gapWhenShown = 0,
    this.compact,
    this.onRemoveAds,
  });

  /// Force the card size (tests / gallery). null (the app) = the server's
  /// `home_native_size` from the cached /ads/config: "compact" (default,
  /// also with no config yet or an unknown value) or "large".
  final bool? compact;

  /// "Remove ads" link (null = open the Premium plans, ChatNav 'plans').
  final VoidCallback? onRemoveAds;

  /// home_v2: space above the ad / sponsor card, only while one is shown
  /// (nothing at all when the slot is empty).
  final double gapWhenShown;

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
  bool _capHit = false;

  /// Compact (SMALL template) unless forced, or the server says "large".
  bool get _compact =>
      widget.compact ?? (_cfg.size == HeroAdSize.compact);

  /// While home is covered by another screen the refresh timer only peeks
  /// this often (no load) until home is visible again.
  static const _visiblePoll = Duration(seconds: 5);

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
    if (!_resumed) {
      // background: no timer, no load
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_ad == null && _direct == null) {
      _start();
    } else {
      _schedule();
    }
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
          clock.now().difference(_cfgAt!) < const Duration(minutes: 30);
      if (!fresh || _injectedConfig != null) {
        final load = _injectedConfig ??
            () => context.read<AppState>().api.getJson('/ads/config');
        _cfgCache = await load();
        _cfgAt = clock.now();
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
    // compact: the card sizes itself (ad box <= 110 dp); only the room counts
    if (_compact) return avail;
    return (avail - _labelRow).clamp(0.0, 340.0);
  }

  double get _minRoom =>
      _compact ? HeroAdRules.compactMinRoom : HeroAdRules.minSlotHeight;

  /// Direct sponsor card height in the compact slot.
  static const double _compactSponsorH = 180;

  HeroAdLook _look() {
    final scheme = Theme.of(context).colorScheme;
    return HeroAdLook(
      background: scheme.surfaceContainerLow,
      headline: scheme.onSurface,
      body: scheme.onSurfaceVariant,
      ctaBackground: scheme.primary,
      ctaText: scheme.onPrimary,
      textScale: MediaQuery.textScalerOf(context).scale(1),
    );
  }

  void _openPlans() {
    final f = widget.onRemoveAds;
    if (f != null) {
      f();
      return;
    }
    ChatNav.push(context, 'plans');
  }

  // label + Remove-ads row (48 dp tap target) + the 8 dp gap to the ad
  static const double _labelRow = 56;

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
      minHeight: _minRoom,
      capReached: !direct && _capHit,
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
        _lastLoad = clock.now();
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
    if (!mounted || _loading || widget.collapsed || !_resumed) return;
    // AdMob minimum refresh also applies to re-showing after a collapse
    if (_lastLoad != null &&
        clock.now().difference(_lastLoad!) < HeroAdRules.refreshEvery(_cfg)) {
      _schedule();
      return;
    }
    _loading = true;
    try {
      _cfg = await _config(); // cached 30 min
      if (!mounted) return;
      // covered by another screen: no attempt (the timer peeks again)
      if (!_homeVisible()) return;
      // every attempt (direct sponsor, AdMob, cap / no-fill) counts: at most
      // one per refresh interval, never a request storm
      _lastLoad = clock.now();
      if (await _tryDirect()) return;
      _capHit = await HeroDailyCap.reached(_cfg.dailyCap);
      if (!mounted || !_decide().allowed) return;
      final unit = _cfg.unit(
          builtAppId: AdsService.builtAppId, testMode: AdsService.testMode);
      if (unit == null) return;
      _lastLoad = clock.now();
      final ad = await _bridge
          .load(unit,
              startMuted: AdSound.startMuted(AdFormat.heroNative,
                  heroStartMuted: _cfg.startMuted),
              look: _look(),
              size: _compact ? HeroAdSize.compact : HeroAdSize.large)
          // admob: the SDK starts only once the launch settled (~8 s), so
          // the first load may wait for it; the logo block shows meanwhile
          .timeout(const Duration(seconds: 45), onTimeout: () => null);
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

  /// Time left until the next reload may happen (>= 0).
  Duration _untilDue() {
    final last = _lastLoad;
    if (last == null) return Duration.zero;
    final left =
        HeroAdRules.refreshEvery(_cfg) - clock.now().difference(last);
    return left.isNegative ? Duration.zero : left;
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    // no timer in the background, while collapsed, or with ads off
    if (!mounted || widget.collapsed || !_cfg.enabled || !_resumed) return;
    final due = _untilDue();
    _timer = Timer(due == Duration.zero ? _visiblePoll : due, _tick);
  }

  void _tick() {
    _timer = null;
    if (!mounted || !_resumed || widget.collapsed) return;
    // reload only while home is really on screen and the app is in front;
    // covered by another screen -> peek again shortly, never load
    if (!_homeVisible()) {
      _timer = Timer(_visiblePoll, _tick);
      return;
    }
    if (_untilDue() > Duration.zero) {
      _schedule();
      return;
    }
    _start();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    final direct = _direct;
    final room = _slotHeight() >= _minRoom;
    final compact = _compact;
    final child = (direct != null && !widget.collapsed && room)
        ? KeyedSubtree(
            key: const ValueKey('hero-sponsor'),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SponsorHeroCard(
                      creative: direct,
                      height: compact
                          ? (_slotHeight() < _compactSponsorH
                              ? _slotHeight()
                              : _compactSponsorH)
                          : _slotHeight(),
                      onClick: () =>
                          unawaited(_sponsor?.event(direct.token, 'click'))),
                  if (compact)
                    Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: RemoveAdsLink(onTap: _openPlans)),
                ]))
        : (ad == null || widget.collapsed || !room)
        ? KeyedSubtree(key: const ValueKey('hero-logo'), child: widget.fallback)
        : compact
        ? CompactAdFrame(
            key: const ValueKey('hero-ad'),
            onRemoveAds: _openPlans,
            child: ad.view())
        : HeroAdFrame(
            key: const ValueKey('hero-ad'),
            height: _slotHeight(),
            hasVideo: ad.hasVideo,
            startMuted: _cfg.startMuted,
            onRemoveAds: _openPlans,
            child: ad.view());
    final gap = widget.gapWhenShown;
    final shown = gap > 0 && child.key != const ValueKey('hero-logo');
    // Only the CURRENT child is laid out (the old one is dropped at once), so
    // the ad and the logo block never overlap, not even mid-fade.
    return AnimatedSwitcher(
      duration: Motion.base,
      layoutBuilder: (current, previous) => current ?? const SizedBox.shrink(),
      child: shown
          ? KeyedSubtree(
              key: ValueKey('gap-${child.key}'),
              child: Padding(padding: EdgeInsets.only(top: gap), child: child))
          : child,
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
    this.onRemoveAds,
  });
  final double height;
  final Widget child;
  final bool hasVideo;
  final bool startMuted;

  /// The separate "Remove ads" link in the label row (outside the ad).
  final VoidCallback? onRemoveAds;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            key: const ValueKey('hero-ad-label'),
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
          const SizedBox(width: Gap.sm),
          if (onRemoveAds != null)
            Flexible(
                child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: RemoveAdsLink(onTap: onRemoveAds!)))
          else
            const Spacer(),
        ]),
        SizedBox(height: onRemoveAds != null ? CompactAdFrame.gap : Gap.xs),
        Semantics(
          container: true,
          label: t.h1HeroAdSemantics,
          child: ClipRRect(
            key: const ValueKey('hero-ad-box'),
            borderRadius: BorderRadius.circular(Radii.md),
            child: SizedBox(height: height, child: child),
          ),
        ),
      ]);
  }
}

/// The COMPACT native card (owner feedback 27 Oct): one row above the ad
/// with our localized "Ad" label (left) and the "Remove ads" link (right),
/// then 8 dp of space, then the ad box — AdMob's SMALL template, 90-110 dp
/// ([HeroAdRules.compactAdHeight]). The link is OUTSIDE the ad view and its
/// own TalkBack button, so it is never read as part of the ad and a tap on
/// it can never land on the ad (AdMob native policy; no close / X on the ad).
class CompactAdFrame extends StatelessWidget {
  const CompactAdFrame(
      {super.key, required this.child, required this.onRemoveAds});
  final Widget child;
  final VoidCallback onRemoveAds;

  /// Space between the link row and the ad (no tap target overlaps the ad).
  static const double gap = Gap.sm;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Container(
            key: const ValueKey('hero-ad-label'),
            padding:
                const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Text(t.h1AdLabel,
                maxLines: 1,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.onTertiaryContainer)),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: RemoveAdsLink(onTap: onRemoveAds))),
        ]),
        const SizedBox(height: gap),
        LayoutBuilder(builder: (context, c) {
          final h = HeroAdRules.compactAdHeight(c.maxWidth);
          return Semantics(
            container: true,
            label: t.h1HeroAdSemantics,
            child: ClipRRect(
              key: const ValueKey('hero-ad-box'),
              borderRadius: BorderRadius.circular(Radii.md),
              child: SizedBox(height: h, child: child),
            ),
          );
        }),
      ],
    );
  }
}

/// "Remove ads" — a small text link (48 dp tap target) that opens the
/// Premium plans. Never inside an ad view; its own screen-reader button.
class RemoveAdsLink extends StatelessWidget {
  const RemoveAdsLink({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      key: const ValueKey('hero-remove-ads'),
      // its own TalkBack node, never merged into the ad / label
      container: true,
      button: true,
      label: t.hv2RemoveAdsA11y,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.workspace_premium_outlined,
                    size: 16, color: scheme.primary),
                const SizedBox(width: Gap.xs),
                Flexible(
                  child: Text(t.hv2RemoveAds,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: scheme.primary,
                          color: scheme.primary)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
