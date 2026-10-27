import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../screens/plans_screen.dart';
import '../state.dart';
import '../theme.dart';
import 'ad_placements.dart';
import 'ad_rules.dart';
import 'admob_banner_bridge.dart';
import 'admob_platform.dart';
import 'ads_service.dart';

/// One loaded banner. [view] renders AdMob's own banner view.
abstract class BannerAdHandle {
  double get height;
  Widget view();
  void dispose();
}

abstract class BannerBridge {
  bool get linked;

  /// Load one anchored adaptive banner [width] dp wide. null on no fill /
  /// error / timeout (the slot then takes no space). Never throws.
  Future<BannerAdHandle?> load(String unitId,
      {required double width, required String placement});
}

class NoopBannerBridge implements BannerBridge {
  const NoopBannerBridge();
  @override
  bool get linked => false;
  @override
  Future<BannerAdHandle?> load(String unitId,
          {required double width, required String placement}) async =>
      null;
}

BannerBridge createBannerBridge() =>
    admobSupported() ? AdmobBannerBridge() : const NoopBannerBridge();

/// ONE adaptive anchored banner at the bottom of a normal feature screen
/// (banners-everywhere, owner 26 Oct; first version admob 25 Oct).
///
/// Use as `Scaffold.bottomNavigationBar` (or stack it ABOVE an existing
/// bottom bar in a `Column(mainAxisSize: min)`). Scaffold lays the body and
/// any FAB out above it, so it can never cover content, a button or an input.
///
/// Shows only when [AdPlacements.banner] allows [screen] (central allowlist
/// + token fence + server switch + Free user), while its route is the
/// visible one, the app is in the foreground and no keyboard is open.
/// Before / without a fill — and for Premium / Business — it takes NO space.
/// With a fill: an 8 dp gap, a row with the "Ad" label and a separate
/// "Remove ads" text link (own TalkBack label, 48 dp target, opens the
/// Premium plans), another 8 dp gap, then the banner. Caps: one banner per
/// route ([BannerPacer.claim]); refreshed no faster than every 60 s
/// ([AdConfig.bannerRefresh], floor [AdRules.minBannerRefresh]).
class AdBannerSlot extends StatefulWidget {
  const AdBannerSlot({
    super.key,
    required this.screen,
    this.enabled = true,
    this.bridge,
    this.loadConfig,
  });

  /// The page's ad screen key — must be in [AdPlacements.bannerScreens].
  final String screen;

  /// false hides the banner (and stops refreshing) without unmounting the
  /// slot, e.g. on a non-list tab of a tabbed screen.
  final bool enabled;

  /// Test seams.
  final BannerBridge? bridge;
  final Future<AdConfig> Function()? loadConfig;

  @visibleForTesting
  static BannerBridge? debugBridge;
  @visibleForTesting
  static Future<AdConfig> Function()? debugLoadConfig;

  /// Test / gallery seam for the page the "Remove ads" link opens.
  @visibleForTesting
  static WidgetBuilder? debugPlansBuilder;

  @override
  State<AdBannerSlot> createState() => _AdBannerSlotState();
}

class _AdBannerSlotState extends State<AdBannerSlot> {
  late final BannerBridge _bridge =
      widget.bridge ?? AdBannerSlot.debugBridge ?? createBannerBridge();
  BannerAdHandle? _ad;
  Timer? _timer;
  Object? _route;
  bool _loading = false;
  bool _blocked = false; // refused once: never retried on this mount

  @override
  void initState() {
    super.initState();
    // lazy: nothing ad-related before the page's first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
  }

  @override
  void didUpdateWidget(AdBannerSlot old) {
    super.didUpdateWidget(old);
    if (widget.enabled && !old.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    final r = _route;
    if (r != null) BannerPacer.release(r, this);
    _drop();
    super.dispose();
  }

  void _drop() {
    try {
      _ad?.dispose();
    } catch (_) {}
    _ad = null;
  }

  Future<AdConfig> _config() async {
    final f = widget.loadConfig ?? AdBannerSlot.debugLoadConfig;
    if (f != null) return f();
    final app = context.read<AppState>();
    return AdsService.instance.configFor(app);
  }

  bool _loggedIn() {
    try {
      return context.read<AppState>().loggedIn;
    } catch (_) {
      // tests / gallery inject the config
      return widget.loadConfig != null || AdBannerSlot.debugLoadConfig != null;
    }
  }

  /// Visible route, app in the foreground, no keyboard, slot enabled.
  bool _showable() {
    if (!mounted || !widget.enabled) return false;
    try {
      final life = WidgetsBinding.instance.lifecycleState;
      if (life != null && life != AppLifecycleState.resumed) return false;
      if (MediaQuery.viewInsetsOf(context).bottom > 0) return false;
      return ModalRoute.of(context)?.isCurrent ?? true;
    } catch (_) {
      return false;
    }
  }

  /// [paced]: the timer itself already waited out the refresh gap.
  void _schedule(Duration d, {bool paced = false}) {
    _timer?.cancel();
    if (!mounted || _blocked) return;
    _timer = Timer(d, () => _tick(paced: paced));
  }

  /// Load (first time) or refresh (every >= 60 s). Never throws.
  Future<void> _tick({bool paced = false}) async {
    if (!mounted || _loading || _blocked || !widget.enabled) return;
    _loading = true;
    try {
      if (!_bridge.linked) {
        _blocked = true;
        return;
      }
      // re-read every tick: an upgrade to Premium removes the banner at
      // the next refresh at the latest (AdsService caches the config)
      final cfg = await _config();
      if (!mounted) return;
      final d = AdPlacements.banner(widget.screen, cfg, loggedIn: _loggedIn());
      if (!d.allowed) {
        _blocked = true;
        if (_ad != null) setState(_drop);
        return;
      }
      // one banner per route: a second slot on the same page stays empty
      final Object route = ModalRoute.of(context) ??
          context.findRootAncestorStateOfType<NavigatorState>() ??
          this;
      if (!BannerPacer.claim(route, this)) {
        assert(() {
          debugPrint('AdBannerSlot: a second banner on one screen was refused');
          return true;
        }());
        _blocked = true;
        return;
      }
      _route = route;
      final s = widget.screen.trim().toLowerCase();
      if (!_showable()) {
        _schedule(const Duration(seconds: 5));
        return;
      }
      if (!paced) {
        // e.g. the screen was re-opened: still keep its 60 s gap
        final wait = BannerPacer.wait(s, DateTime.now(), cfg.bannerRefresh);
        if (wait > Duration.zero) {
          _schedule(wait, paced: true);
          return;
        }
      }
      final unit = cfg.unitFor(AdKind.banner, builtAppId: AdsService.builtAppId);
      if (unit == null) return;
      final width = MediaQuery.sizeOf(context).width;
      BannerPacer.markLoaded(s, DateTime.now());
      final ad = await _bridge
          .load(unit, width: width, placement: 'banner_$s')
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
      if (!mounted) {
        try {
          ad?.dispose();
        } catch (_) {}
        return;
      }
      if (ad != null) {
        final old = _ad;
        setState(() => _ad = ad);
        // the old AdWidget leaves the tree in this frame: dispose after it
        if (old != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              old.dispose();
            } catch (_) {}
          });
        }
      }
      _schedule(
          cfg.bannerRefresh < AdRules.minBannerRefresh
              ? AdRules.minBannerRefresh
              : cfg.bannerRefresh,
          paced: true);
    } catch (_) {
      // an ad problem never reaches the page
    } finally {
      _loading = false;
    }
  }

  void _openPlans() {
    final b = AdBannerSlot.debugPlansBuilder ?? (_) => const PlansScreen();
    Navigator.of(context).push(MaterialPageRoute(builder: b));
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    // never next to an open keyboard; hidden tab = no banner
    if (ad == null ||
        !widget.enabled ||
        MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Material(
        color: scheme.surface,
        child: Column(
          key: const ValueKey('ad-banner-slot'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // >= 8 dp from the page's content / FAB above
            Divider(height: Gap.sm, thickness: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
              child: Row(children: [
                Semantics(
                  label: t.h1HeroAdSemantics,
                  excludeSemantics: true,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
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
                ),
                const SizedBox(width: Gap.sm),
                // the Remove-ads link is OUTSIDE the AdWidget, with its own
                // TalkBack label and a 48 dp target
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Semantics(
                    button: true,
                    label: t.adBannerRemoveAdsHint,
                    excludeSemantics: true,
                    child: TextButton(
                      key: const ValueKey('ad-banner-remove'),
                      onPressed: _openPlans,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        tapTargetSize: MaterialTapTargetSize.padded,
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                        foregroundColor: scheme.primary,
                      ),
                      child: Text(t.adBannerRemoveAds,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.underline)),
                    ),
                  ),
                  ),
                ),
              ]),
            ),
            // >= 8 dp between the link and the ad itself
            const SizedBox(height: Gap.sm),
            Semantics(
              container: true,
              label: t.h1HeroAdSemantics,
              child: SizedBox(
                  key: const ValueKey('ad-banner-view'),
                  height: ad.height,
                  width: double.infinity,
                  child: ad.view()),
            ),
            // >= 8 dp from a tab bar / system controls below
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    );
  }
}
