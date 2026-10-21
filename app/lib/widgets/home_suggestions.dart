import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../home_api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'chatnav.dart';

/// HOME "Discover" spotlight (owner-approved home change).
///
/// Replaces the old 4 static prompt cards with an auto-rotating, horizontally
/// swipeable PageView of premium spotlight cards that promote:
///   1. Assisto's OWN features the user hasn't opened yet (personalised,
///      unused-first, via a local "opened features" set in SharedPreferences),
///   2. our other products (Asalify, AXON ERP) clearly marked "Our products",
///   3. for FREE users only, ONE native-style ad slot — AdMob-key-gated. Since
///      the app has no way to learn AdMob is enabled yet (no flag on /me/plan)
///      and the real ad SDK (google_mobile_ads) is NOT a dependency, we show
///      NOTHING there unless the plan response carries an explicit ads flag, in
///      which case we show a labelled "Ad slot (enable AdMob)" placeholder.
///      TODO(ads): wire google_mobile_ads with TEST unit ids in a later build.
///
/// The promo list is a local const default for now; a backend `/home/discover`
/// endpoint will OVERRIDE it later (admin-editable). Personalisation
/// (unused-first ordering) stays client-side.
///
/// Fully crash-guarded: if anything throws, the card simply doesn't render and
/// the home still shows the chat.
///
/// The constructor keeps the previous signature ([onRun], [onReady]) so the
/// host (home_screen) needs no change. [onRun] is kept for backward-compat but
/// is unused — Discover cards navigate / open URLs on their own.
class HomeSuggestions extends StatefulWidget {
  final void Function(HomeSuggestion s)? onRun;
  final void Function(Future<void> Function() refresh)? onReady;

  const HomeSuggestions({super.key, this.onRun, this.onReady});

  @override
  State<HomeSuggestions> createState() => _HomeSuggestionsState();
}

/// How a Discover card behaves when tapped.
enum _DiscoverKind { feature, product, ad }

class _Discover {
  final _DiscoverKind kind;
  final IconData icon;
  final String Function(AppLocalizations t) title;
  final String Function(AppLocalizations t) benefit;

  /// In-app canonical route (feature cards). Must EXIST in [ChatNav.routes].
  final String? route;

  /// External URL (product cards).
  final String? url;

  /// Stable key for the "already opened" personalisation set.
  final String key;

  const _Discover.feature({
    required this.key,
    required this.icon,
    required this.title,
    required this.benefit,
    required this.route,
  })  : kind = _DiscoverKind.feature,
        url = null;

  const _Discover.product({
    required this.key,
    required this.icon,
    required this.title,
    required this.benefit,
    required this.url,
  })  : kind = _DiscoverKind.product,
        route = null;
}

/// LOCAL default spotlight list. A backend `/home/discover` endpoint will
/// override this later (admin-editable). Only routes that exist in
/// [ChatNav.routes] are used (verified: photo_enhance, phone_safety, security,
/// journey, messages, used_phone_check, vehicles, plans). "Remote support" has
/// no route, so it is intentionally omitted.
const List<_Discover> _kDiscover = [
  _Discover.feature(
    key: 'photo_enhance',
    icon: Icons.auto_fix_high_outlined,
    title: _tEnhanceTitle,
    benefit: _tEnhanceBenefit,
    route: 'photo_enhance',
  ),
  _Discover.feature(
    key: 'phone_safety',
    icon: Icons.phonelink_lock_outlined,
    title: _tAntiTheftTitle,
    benefit: _tAntiTheftBenefit,
    route: 'phone_safety',
  ),
  _Discover.feature(
    key: 'journey',
    icon: Icons.near_me_outlined,
    title: _tJourneyTitle,
    benefit: _tJourneyBenefit,
    route: 'journey',
  ),
  _Discover.feature(
    key: 'messages',
    icon: Icons.diversity_3_outlined,
    title: _tCircleTitle,
    benefit: _tCircleBenefit,
    route: 'messages',
  ),
  _Discover.feature(
    key: 'used_phone_check',
    icon: Icons.verified_outlined,
    title: _tUsedPhoneTitle,
    benefit: _tUsedPhoneBenefit,
    route: 'used_phone_check',
  ),
  _Discover.feature(
    key: 'vehicles',
    icon: Icons.directions_car_outlined,
    title: _tVehiclesTitle,
    benefit: _tVehiclesBenefit,
    route: 'vehicles',
  ),
  _Discover.feature(
    key: 'security',
    icon: Icons.security_outlined,
    title: _tSecurityTitle,
    benefit: _tSecurityBenefit,
    route: 'security',
  ),
  _Discover.feature(
    key: 'plans',
    icon: Icons.workspace_premium_outlined,
    title: _tPlansTitle,
    benefit: _tPlansBenefit,
    route: 'plans',
  ),
  // ---- our other products (clearly marked "Our products") ----
  _Discover.product(
    key: 'asalify',
    icon: Icons.storefront_outlined,
    title: _tAsalifyTitle,
    benefit: _tAsalifyBenefit,
    url: 'https://asalify.com',
  ),
  _Discover.product(
    key: 'axon',
    icon: Icons.account_tree_outlined,
    title: _tAxonTitle,
    benefit: _tAxonBenefit,
    url: 'https://axonerpsoftware.com',
  ),
];

// Top-level tear-offs so the list above can stay `const`.
String _tEnhanceTitle(AppLocalizations t) => t.discoverEnhanceTitle;
String _tEnhanceBenefit(AppLocalizations t) => t.discoverEnhanceBenefit;
String _tAntiTheftTitle(AppLocalizations t) => t.discoverAntiTheftTitle;
String _tAntiTheftBenefit(AppLocalizations t) => t.discoverAntiTheftBenefit;
String _tJourneyTitle(AppLocalizations t) => t.discoverJourneyTitle;
String _tJourneyBenefit(AppLocalizations t) => t.discoverJourneyBenefit;
String _tCircleTitle(AppLocalizations t) => t.discoverCircleTitle;
String _tCircleBenefit(AppLocalizations t) => t.discoverCircleBenefit;
String _tUsedPhoneTitle(AppLocalizations t) => t.discoverUsedPhoneTitle;
String _tUsedPhoneBenefit(AppLocalizations t) => t.discoverUsedPhoneBenefit;
String _tVehiclesTitle(AppLocalizations t) => t.discoverVehiclesTitle;
String _tVehiclesBenefit(AppLocalizations t) => t.discoverVehiclesBenefit;
String _tSecurityTitle(AppLocalizations t) => t.discoverSecurityTitle;
String _tSecurityBenefit(AppLocalizations t) => t.discoverSecurityBenefit;
String _tPlansTitle(AppLocalizations t) => t.discoverPlansTitle;
String _tPlansBenefit(AppLocalizations t) => t.discoverPlansBenefit;
String _tAsalifyTitle(AppLocalizations t) => t.discoverAsalifyTitle;
String _tAsalifyBenefit(AppLocalizations t) => t.discoverAsalifyBenefit;
String _tAxonTitle(AppLocalizations t) => t.discoverAxonTitle;
String _tAxonBenefit(AppLocalizations t) => t.discoverAxonBenefit;

class _HomeSuggestionsState extends State<HomeSuggestions> {
  static const _openedKey = 'discover_opened_features';

  final _page = PageController(viewportFraction: 0.92);
  final _rotate = ValueNotifier<int>(0);
  Timer? _autoRotate;

  // Ordered cards to show (unused-first; ad injected for free users if gated).
  List<_Discover> _cards = const [];
  // Set of feature keys the user has already opened (unused-first ordering).
  Set<String> _opened = {};
  // True only when the user is on the FREE plan AND an AdMob flag is present.
  bool _showAd = false;
  int _index = 0;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    widget.onReady?.call(_refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _startAutoRotate();
  }

  @override
  void dispose() {
    _autoRotate?.cancel(); // never leave a timer firing after unmount
    _page.dispose();
    _rotate.dispose();
    super.dispose();
  }

  // Auto-rotate every ~6s via a CANCELABLE periodic timer (cancelled in dispose
  // so it can never fire / setState after the widget is gone — and no timer is
  // left pending in widget tests).
  void _startAutoRotate() {
    _autoRotate = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || _cards.isEmpty) return;
      try {
        final next = (_index + 1) % _cards.length;
        if (_page.hasClients) {
          _page.animateToPage(next,
              duration: Motion.base, curve: Curves.easeInOut);
        }
      } catch (_) {}
    });
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    // 1) load opened-set (best-effort).
    try {
      final raw = await Settings.getString(_openedKey);
      _opened = (raw == null || raw.isEmpty)
          ? <String>{}
          : raw.split(',').where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      _opened = {};
    }
    // 2) learn plan + ad gating (best-effort; default: NO ad).
    var free = false;
    var admobEnabled = false;
    try {
      final app = context.read<AppState>();
      if (app.loggedIn) {
        final p = await app.api.plan();
        final slug = (p['plan'] ?? p['id'] ?? '').toString().toLowerCase();
        free = slug.isEmpty || slug == 'free';
        // Honest AdMob gate: only if the backend explicitly says ads/admob are
        // enabled. Absent → false → NO ad slot. (Real SDK is a later build.)
        admobEnabled = p['admob'] == true ||
            p['ads_enabled'] == true ||
            p['ads'] == true;
      }
    } catch (_) {/* offline / no plan — treat as not-free, no ad */}
    _showAd = free && admobEnabled;
    _rebuild();
  }

  void _rebuild() {
    // Personalise: features NOT yet opened first, then opened ones, then
    // product cards last. Keep relative order within each bucket.
    final features = _kDiscover
        .where((c) => c.kind == _DiscoverKind.feature)
        .toList();
    final products =
        _kDiscover.where((c) => c.kind == _DiscoverKind.product).toList();
    final unused = features.where((c) => !_opened.contains(c.key)).toList();
    final used = features.where((c) => _opened.contains(c.key)).toList();
    final list = <_Discover>[...unused, ...used, ...products];
    if (!mounted) return;
    setState(() {
      _cards = list;
      _index = _index.clamp(0, list.isEmpty ? 0 : list.length - 1);
    });
  }

  Future<void> _markOpened(String key) async {
    if (_opened.contains(key)) return;
    _opened = {..._opened, key};
    try {
      await Settings.setString(_openedKey, _opened.join(','));
    } catch (_) {}
  }

  Future<void> _tap(_Discover c) async {
    switch (c.kind) {
      case _DiscoverKind.feature:
        await _markOpened(c.key);
        if (c.route != null) ChatNav.push(context, c.route);
        break;
      case _DiscoverKind.product:
        if (c.url != null) {
          try {
            await launchUrl(Uri.parse(c.url!),
                mode: LaunchMode.externalApplication);
          } catch (_) {}
        }
        break;
      case _DiscoverKind.ad:
        break; // placeholder slot — no action
    }
  }

  @override
  Widget build(BuildContext context) {
    // Crash guard: any failure → render nothing, chat stays.
    try {
      return _build();
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  Widget _build() {
    final scheme = Theme.of(context).colorScheme;
    if (_cards.isEmpty) return const SizedBox.shrink();

    // Inject ONE ad placeholder (free + admob-enabled only). Never for
    // premium/business, never when AdMob is absent.
    final display = <Widget>[
      for (final c in _cards) _card(c),
      if (_showAd) _adCard(),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xs, 0, 0, Gap.sm),
          child: Text(
            t.discoverTitle,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
        SizedBox(
          // grows with the user's font size (large-font QA: no clipping)
          height: math.max(
              112.0, 40 + 70 * MediaQuery.textScalerOf(context).scale(1)),
          child: PageView(
            controller: _page,
            onPageChanged: (i) {
              _index = i;
              _rotate.value = i;
            },
            children: display,
          ),
        ),
        const SizedBox(height: Gap.sm),
        _dots(display.length, scheme),
      ],
    );
  }

  Widget _dots(int count, ColorScheme scheme) {
    return ValueListenableBuilder<int>(
      valueListenable: _rotate,
      builder: (_, active, __) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: Motion.fast,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == active ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == active
                    ? scheme.primary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
            ),
        ],
      ),
    );
  }

  Widget _shell({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
      child: child,
    );
  }

  Widget _card(_Discover c) {
    final scheme = Theme.of(context).colorScheme;
    final isProduct = c.kind == _DiscoverKind.product;
    return _shell(
      child: Material(
        borderRadius: BorderRadius.circular(Radii.md),
        clipBehavior: Clip.antiAlias,
        color: scheme.surfaceContainerHighest,
        child: InkWell(
          onTap: () => _tap(c),
          child: Container(
            decoration: BoxDecoration(
              gradient: isProduct
                  ? null
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        scheme.primary.withValues(alpha: 0.14),
                        scheme.tertiary.withValues(alpha: 0.10),
                      ],
                    ),
            ),
            padding: const EdgeInsets.all(Gap.lg),
            child: Row(children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Icon(c.icon, color: scheme.primary, size: 24),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isProduct) ...[
                      _badge(t.discoverOurProducts, scheme.tertiary),
                      const SizedBox(height: Gap.xs),
                    ],
                    Text(
                      c.title(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      c.benefit(t),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                          height: 1.3),
                    ),
                  ],
                ),
              ),
              Icon(isProduct ? Icons.open_in_new : Icons.north_east,
                  size: 16, color: scheme.onSurfaceVariant),
            ]),
          ),
        ),
      ),
    );
  }

  // Free + AdMob-enabled placeholder. The real google_mobile_ads SDK is NOT a
  // dependency yet, so this is a clearly-labelled placeholder only.
  // TODO(ads): render a native AdMob ad (TEST unit ids) once the SDK is added.
  Widget _adCard() {
    final scheme = Theme.of(context).colorScheme;
    return _shell(
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
              style: BorderStyle.solid),
        ),
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(children: [
          Icon(Icons.campaign_outlined,
              size: 28, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _badge(t.discoverAdBadge, scheme.secondary),
                const SizedBox(height: Gap.xs),
                Text(t.discoverAdPlaceholder,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                        height: 1.3)),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(Radii.xs),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 10, fontWeight: FontWeight.w800),
      ),
    );
  }
}
