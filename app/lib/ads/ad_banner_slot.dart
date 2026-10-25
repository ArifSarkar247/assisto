import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
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

/// A banner at the bottom of a SAFE list page (admob, owner 25 Oct).
///
/// Shows only when [AdPlacements.banner] allows [screen] (central allowlist
/// + server switch + Free user) and only while its page is the visible
/// route. Before / without a fill it takes NO space (no empty box, no
/// spinner); with one it shows a clear localized "Ad" label (h1AdLabel) above the
/// banner. Any failure: nothing. Use as `Scaffold.bottomNavigationBar`.
class AdBannerSlot extends StatefulWidget {
  const AdBannerSlot({super.key, required this.screen, this.bridge, this.loadConfig});

  /// The page's ad screen name — must be in [AdPlacements.bannerScreens].
  final String screen;

  /// Test seams.
  final BannerBridge? bridge;
  final Future<AdConfig> Function()? loadConfig;

  @visibleForTesting
  static BannerBridge? debugBridge;
  @visibleForTesting
  static Future<AdConfig> Function()? debugLoadConfig;

  @override
  State<AdBannerSlot> createState() => _AdBannerSlotState();
}

class _AdBannerSlotState extends State<AdBannerSlot> {
  late final BannerBridge _bridge =
      widget.bridge ?? AdBannerSlot.debugBridge ?? createBannerBridge();
  BannerAdHandle? _ad;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // lazy: nothing ad-related before the page's first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    try {
      _ad?.dispose();
    } catch (_) {}
    _ad = null;
    super.dispose();
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

  bool _visible() {
    try {
      return ModalRoute.of(context)?.isCurrent ?? true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _start() async {
    if (_started || !mounted) return;
    _started = true;
    try {
      if (!_bridge.linked) return;
      final cfg = await _config();
      if (!mounted) return;
      final d = AdPlacements.banner(widget.screen, cfg, loggedIn: _loggedIn());
      if (!d.allowed || !_visible()) return;
      final unit = cfg.unitFor(AdKind.banner, builtAppId: AdsService.builtAppId);
      if (unit == null) return;
      final width = MediaQuery.of(context).size.width;
      final ad = await _bridge
          .load(unit, width: width, placement: 'banner_${widget.screen}')
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
      if (!mounted) {
        try {
          ad?.dispose();
        } catch (_) {}
        return;
      }
      if (ad != null) setState(() => _ad = ad);
    } catch (_) {
      // an ad problem never reaches the page
    }
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (ad == null) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Semantics(
        container: true,
        label: t.h1HeroAdSemantics,
        child: Column(
          key: const ValueKey('ad-banner-slot'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, 2),
              child: Container(
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
            ),
            SizedBox(height: ad.height, width: double.infinity, child: ad.view()),
          ],
        ),
      ),
    );
  }
}
