import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../ads/hero_ad.dart' show HomeAdGuard;
import '../discover_api.dart';
import '../home_api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'chatnav.dart';
import '../services/action_feedback.dart'; // db1
import '../screens/home_v2/home_v2_tokens.dart'; // home_v2

/// HOME "Discover" spotlight — an auto-rotating, swipeable PageView of
/// spotlight cards.
///
/// SERVER-DRIVEN (d1-discover): cards come from `GET /discover/cards`, managed
/// by the owner in Settings -> Discover manager. The server decides who sees
/// what (plan, audience, dates, min build; sponsored cards reach every plan,
/// AdMob cards only Free users). The app:
///   * shows the LAST server set from cache first (works offline),
///   * refreshes from the server in the background and re-caches,
///   * uses the built-in list below ONLY on first run (no cache, no network),
///   * labels "Our products" / "Sponsored" by card type (not editable),
///   * picks the bn/en copy by the user's UI language,
///   * opens in-app routes via [ChatNav] or https links externally,
///   * records impressions + taps fire-and-forget (never blocks the UI),
///   * renders NOTHING for ADMOB cards: AdMob is not linked in the app yet.
///
/// Personalisation stays client-side: feature cards the user already opened
/// move behind unopened ones, inside the feature slots only (sponsored and
/// product cards keep the position the owner gave them).
///
/// Only used on the home screen (never on SOS / family-alert / safety
/// screens). Fully crash-guarded: if anything throws, nothing renders and the
/// home still shows the chat.
///
/// The constructor keeps the previous signature ([onRun], [onReady]) so the
/// host (home_screen) needs no change. [onRun] is unused.
class HomeSuggestions extends StatefulWidget {
  final void Function(HomeSuggestion s)? onRun;
  final void Function(Future<void> Function() refresh)? onReady;

  /// home_v2: the owner's restyle (slim gradient cards, glass icon box,
  /// white round arrow, next card peeking, dots beside the title). Data,
  /// cache, rotation, swipe, labels and impression/click tracking are the
  /// SAME code path as the old home.
  final bool v2;

  const HomeSuggestions({super.key, this.onRun, this.onReady, this.v2 = false});

  /// SharedPreferences key holding the last server card set (JSON list).
  static const cacheKey = 'discover_cards_cache_v1';

  @override
  State<HomeSuggestions> createState() => _HomeSuggestionsState();
}

/// FIRST-RUN fallback only (no cache and no network yet). Mirrors the server
/// seed (migrations 0049 + 0056) so the first launch looks the same either way.
const List<DiscoverItem> kDiscoverFallback = [
  DiscoverItem(
      key: 'photo_enhance',
      type: DiscoverItem.feature,
      icon: 'auto_fix_high',
      route: 'photo_enhance',
      tTitle: _tEnhanceTitle,
      tDesc: _tEnhanceBenefit),
  DiscoverItem(
      key: 'phone_safety',
      type: DiscoverItem.feature,
      icon: 'phonelink_lock',
      route: 'phone_safety',
      tTitle: _tAntiTheftTitle,
      tDesc: _tAntiTheftBenefit),
  DiscoverItem(
      key: 'journey',
      type: DiscoverItem.feature,
      icon: 'near_me',
      route: 'journey',
      tTitle: _tJourneyTitle,
      tDesc: _tJourneyBenefit),
  DiscoverItem(
      key: 'messages',
      type: DiscoverItem.feature,
      icon: 'diversity_3',
      route: 'messages',
      tTitle: _tCircleTitle,
      tDesc: _tCircleBenefit),
  DiscoverItem(
      key: 'used_phone_check',
      type: DiscoverItem.feature,
      icon: 'verified',
      route: 'used_phone_check',
      tTitle: _tUsedPhoneTitle,
      tDesc: _tUsedPhoneBenefit),
  DiscoverItem(
      key: 'vehicles',
      type: DiscoverItem.feature,
      icon: 'directions_car',
      route: 'vehicles',
      tTitle: _tVehiclesTitle,
      tDesc: _tVehiclesBenefit),
  DiscoverItem(
      key: 'security',
      type: DiscoverItem.feature,
      icon: 'security',
      route: 'security',
      tTitle: _tSecurityTitle,
      tDesc: _tSecurityBenefit),
  DiscoverItem(
      key: 'plans',
      type: DiscoverItem.feature,
      icon: 'workspace_premium',
      route: 'plans',
      tTitle: _tPlansTitle,
      tDesc: _tPlansBenefit),
  DiscoverItem(
      key: 'asalify',
      type: DiscoverItem.ourProduct,
      icon: 'storefront',
      url: 'https://asalify.com',
      tTitle: _tAsalifyTitle,
      tDesc: _tAsalifyBenefit),
  DiscoverItem(
      key: 'axon',
      type: DiscoverItem.ourProduct,
      icon: 'account_tree',
      url: 'https://axonerpsoftware.com',
      tTitle: _tAxonTitle,
      tDesc: _tAxonBenefit),
];

// Top-level tear-offs so the fallback entries can stay `const`.
// b2-badges: the card opens Photo Studio, so it is named Photo Studio
// (server seed renamed by migration 0056).
String _tEnhanceTitle(AppLocalizations t) => t.b2PhotoStudioTitle;
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

/// Parse a cached / server card list. Unknown shapes are skipped.
List<DiscoverItem> parseDiscoverItems(Object? raw) {
  if (raw is! List) return const [];
  final out = <DiscoverItem>[];
  for (final e in raw) {
    if (e is Map) {
      try {
        out.add(DiscoverItem.fromJson(e.cast<String, dynamic>()));
      } catch (_) {}
    }
  }
  return out;
}

/// Cards this app build can actually render: ADMOB renders nothing (AdMob is
/// not linked in the app yet), in-app routes must exist in [ChatNav.routes],
/// external links must be https.
///
/// h1-home: when AdMob is linked, an ADMOB card may only render while the home
/// hero is NOT showing a native ad ([HomeAdGuard.heroShowing]) — one AdMob ad
/// on home at a time. Today it never renders either way.
List<DiscoverItem> renderableDiscover(List<DiscoverItem> items) =>
    items.where((c) {
      if (c.isAdmob) return false;
      if (c.route.isNotEmpty) return ChatNav.routes.containsKey(c.route);
      return c.url.startsWith('https://');
    }).toList();

class _HomeSuggestionsState extends State<HomeSuggestions> {
  static const _openedKey = 'discover_opened_features';
  static int? _buildNumber; // resolved once per process
  static bool _buildResolved = false;

  late final _page = PageController(
      viewportFraction: widget.v2
          ? (HV2.discoverMainW + HV2.discoverPeekGap) /
              (HV2.skylineW - 2 * HV2.pagePad)
          : 0.92);
  final _rotate = ValueNotifier<int>(0);
  Timer? _autoRotate;

  /// Source list (server / cache / fallback) before personalisation; null
  /// until the first load decided which source to use.
  List<DiscoverItem>? _source;
  List<DiscoverItem> _cards = const [];
  Set<String> _opened = {};
  final Set<int> _impressed = {};
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

  Future<int?> _appBuild() async {
    if (_buildResolved) return _buildNumber;
    try {
      final info = await PackageInfo.fromPlatform();
      _buildNumber = int.tryParse(info.buildNumber);
    } catch (_) {
      _buildNumber = null; // unknown -> the server hides min-build cards
    }
    _buildResolved = true;
    return _buildNumber;
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    // 1) opened-set (best-effort).
    try {
      final raw = await Settings.getString(_openedKey);
      _opened = (raw == null || raw.isEmpty)
          ? <String>{}
          : raw.split(',').where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      _opened = {};
    }
    // 2) first load: the last server set from cache, else the fallback.
    if (_source == null) {
      List<DiscoverItem>? cached;
      try {
        final raw = await Settings.getString(HomeSuggestions.cacheKey);
        if (raw != null) cached = parseDiscoverItems(jsonDecode(raw));
      } catch (_) {
        cached = null;
      }
      _source = cached ?? kDiscoverFallback;
      _rebuild();
    }
    // 3) server (best-effort; offline keeps what is already shown).
    if (!mounted) return;
    try {
      final app = context.read<AppState>();
      if (!app.loggedIn) return;
      final build = await _appBuild();
      final j = await app.api.discoverCards(
          build: build, heroAd: HomeAdGuard.heroShowing.value);
      final raw = j['cards'];
      if (raw is! List) return;
      final items = parseDiscoverItems(raw);
      _source = items;
      try {
        await Settings.setString(HomeSuggestions.cacheKey,
            jsonEncode([for (final c in items) c.toJson()]));
      } catch (_) {}
      _rebuild();
    } catch (_) {/* offline / server down — keep cache or fallback */}
  }

  void _rebuild() {
    final list = renderableDiscover(_source ?? const []);
    // Feature slots get unopened-first ordering; other slots stay put.
    final features = list.where((c) => c.type == DiscoverItem.feature).toList();
    final reordered = [
      ...features.where((c) => !_opened.contains(c.key)),
      ...features.where((c) => _opened.contains(c.key)),
    ];
    var fi = 0;
    final out = [
      for (final c in list)
        if (c.type == DiscoverItem.feature) reordered[fi++] else c,
    ];
    if (!mounted) return;
    setState(() {
      _cards = out;
      _index = _index.clamp(0, out.isEmpty ? 0 : out.length - 1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _impression(_index));
  }

  void _track(DiscoverItem c, String event) {
    final id = c.id;
    if (id == null || !mounted) return;
    try {
      final api = context.read<AppState>().api;
      // fire-and-forget: never awaited, never surfaces an error
      unawaited(api.discoverTrack(id, event).then((_) {}, onError: (_) {}));
    } catch (_) {}
  }

  void _impression(int i) {
    if (!mounted || i < 0 || i >= _cards.length) return;
    final c = _cards[i];
    final id = c.id;
    if (id == null || _impressed.contains(id)) return;
    _impressed.add(id);
    _track(c, 'impression');
  }

  Future<void> _markOpened(String key) async {
    if (_opened.contains(key)) return;
    _opened = {..._opened, key};
    try {
      await Settings.setString(_openedKey, _opened.join(','));
    } catch (_) {}
  }

  Future<void> _tap(DiscoverItem c) async {
    _track(c, 'click');
    if (c.route.isNotEmpty) {
      if (c.type == DiscoverItem.feature) await _markOpened(c.key);
      if (mounted) ChatNav.push(context, c.route);
      return;
    }
    if (c.url.startsWith('https://')) {
      try {
        await launchUrl(Uri.parse(c.url), mode: LaunchMode.externalApplication);
      } catch (e) {
        showActionFailed(context, 'discover.openUrl', e, open: true); // db1
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Crash guard: any failure → render nothing, chat stays.
    try {
      return _buildBody();
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  Widget _buildBody() {
    final scheme = Theme.of(context).colorScheme;
    if (_cards.isEmpty) return const SizedBox.shrink();
    if (widget.v2) return _buildV2();
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
              _impression(i);
            },
            children: [
              for (final c in _cards)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                  child: DiscoverCardTile(item: c, onTap: () => _tap(c)),
                ),
            ],
          ),
        ),
        const SizedBox(height: Gap.sm),
        _dots(_cards.length, scheme),
      ],
    );
  }

  // home_v2 layout: title + dots on one row, then the slim peeking cards.
  Widget _buildV2() {
    final p = HomeV2Palette.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(t.discoverTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: HV2.sectionTitleSize,
                      fontWeight: FontWeight.w700,
                      color: p.sectionTitle)),
            ),
          ),
          ExcludeSemantics(child: _dotsV2(_cards.length, p)),
        ]),
        const SizedBox(height: HV2.sectionGap),
        LayoutBuilder(builder: (context, box) => SizedBox(
          height: _v2Height(box.maxWidth, scale),
          child: PageView(
            controller: _page,
            padEnds: false,
            clipBehavior: Clip.none,
            onPageChanged: (i) {
              _index = i;
              _rotate.value = i;
              _impression(i);
            },
            children: [
              for (final c in _cards)
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                      end: HV2.discoverPeekGap),
                  child: DiscoverCardV2(item: c, onTap: () => _tap(c)),
                ),
            ],
          ),
        )),
      ],
    );
  }

  /// Card height for this width + font: the reference 98 dp, or taller when
  /// the longest card's title + description need more room (large font) —
  /// measured, so no card ever cuts its text off.
  double _v2Height(double width, double scale) {
    final base = HV2.discoverHeight(1);
    if (scale <= 1.0) return base;
    try {
      final cardW = width * _page.viewportFraction - HV2.discoverPeekGap;
      final textW = cardW -
          2 * HV2.discoverPadH -
          HV2.glassBox -
          2 * HV2.discoverInnerGap -
          HV2.goBtn;
      if (textW <= 40) return HV2.discoverHeight(scale);
      final lang =
          Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';
      final scaler = MediaQuery.textScalerOf(context);
      final dts = DefaultTextStyle.of(context).style;
      double h(String s, TextStyle st) {
        final tp = TextPainter(
            text: TextSpan(text: s, style: dts.merge(st)),
            textDirection: Directionality.of(context),
            textScaler: scaler)
          ..layout(maxWidth: textW);
        final v = tp.height;
        tp.dispose();
        return v;
      }
      var need = 0.0;
      for (final c in _cards) {
        final badge = c.isProduct || c.isSponsored ? 10 * 1.5 * scale + 4 : 0;
        final v = badge +
            h(c.title(t, lang), DiscoverCardV2.titleStyle) +
            h(c.description(t, lang), DiscoverCardV2.descStyle);
        if (v > need) need = v;
      }
      final full = need + 2 * HV2.discoverPadV + 6;
      return full > base ? full : base;
    } catch (_) {
      return HV2.discoverHeight(scale);
    }
  }

  Widget _dotsV2(int count, HomeV2Palette p) {
    return ValueListenableBuilder<int>(
      valueListenable: _rotate,
      builder: (_, active, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: Motion.fast,
              margin: EdgeInsetsDirectional.only(
                  start: i == 0 ? 0 : HV2.dotGap),
              width: i == active ? HV2.dotOn : HV2.dot,
              height: HV2.dot,
              decoration: BoxDecoration(
                color: i == active ? p.dotOn : p.dotOff,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
            ),
        ],
      ),
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
}

/// One Discover spotlight card. Public so the owner's Discover manager can
/// preview a card exactly as users will see it.
class DiscoverCardTile extends StatelessWidget {
  final DiscoverItem item;
  final VoidCallback? onTap;

  const DiscoverCardTile({super.key, required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang =
        Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';
    final scheme = Theme.of(context).colorScheme;
    final plain = item.isProduct || item.isSponsored;
    final img = item.absoluteImageUrl;
    final iconBox = Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Icon(item.iconData, color: scheme.primary, size: 24),
    );
    return Material(
      borderRadius: BorderRadius.circular(Radii.md),
      clipBehavior: Clip.antiAlias,
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            gradient: plain
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
            if (img != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(Radii.sm),
                child: Image.network(
                  img,
                  width: 46,
                  height: 46,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => iconBox,
                ),
              )
            else
              iconBox,
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (item.isProduct) ...[
                    _badge(t.discoverOurProducts, scheme.tertiary),
                    const SizedBox(height: Gap.xs),
                  ] else if (item.isSponsored) ...[
                    _badge(t.discoverSponsored, scheme.secondary),
                    const SizedBox(height: Gap.xs),
                  ],
                  Text(
                    item.title(t, lang),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.description(t, lang),
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
            Icon(item.isExternal ? Icons.open_in_new_rounded : Icons.north_east_rounded,
                size: 16, color: scheme.onSurfaceVariant),
          ]),
        ),
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

/// home_v2 Discover card (owner reference .card): ~98 dp tall (grows with the
/// font), its own premium gradient, a glass icon box, title + 2-line
/// description and a white round arrow button. "Our products" / "Sponsored"
/// keep their labels (glass pill above the title).
class DiscoverCardV2 extends StatelessWidget {
  final DiscoverItem item;
  final VoidCallback? onTap;
  const DiscoverCardV2({super.key, required this.item, this.onTap});

  static const titleStyle = TextStyle(
      color: HomeV2Palette.onColor,
      fontSize: HV2.discoverTitle,
      height: 1.3,
      fontWeight: FontWeight.w700);
  static const descStyle = TextStyle(
      color: HomeV2Palette.discoverSub,
      fontSize: HV2.discoverDesc,
      height: 1.4);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang =
        Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';
    final p = HomeV2Palette.of(context);
    final colors = HomeV2Palette.discoverGradient(item.key);
    final (begin, end) = HV2.cssAngle(HV2.discoverAngleDeg);
    final radius = BorderRadius.circular(HV2.discoverRadius);
    final img = item.absoluteImageUrl;
    final title = item.title(t, lang);
    final desc = item.description(t, lang);
    final badge = item.isProduct
        ? t.discoverOurProducts
        : item.isSponsored
            ? t.discoverSponsored
            : null;
    final icon = Icon(item.iconData,
        color: HomeV2Palette.onColor, size: HV2.glassIcon);
    // normal font: the reference's 1 + 2 lines; large font: the card is
    // measured tall enough for the whole text (home_suggestions _v2Height)
    final big = MediaQuery.textScalerOf(context).scale(1) > 1.0;
    return Semantics(
      button: true,
      label: [if (badge != null) badge, title, desc].join('. '),
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
              begin: begin, end: end, colors: colors, stops: const [0, 0.6, 1]),
          boxShadow: [
            BoxShadow(
                color: p.discoverShadow,
                blurRadius: 22,
                offset: const Offset(0, 10)),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('discover_v2_${item.key}'),
            borderRadius: radius,
            onTap: onTap,
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(children: [
                const Positioned(
                  right: -40,
                  top: -60,
                  child: _Blob(size: HV2.blobDiscover),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: HV2.discoverPadH, vertical: HV2.discoverPadV),
                  child: Row(children: [
                    Container(
                      width: HV2.glassBox,
                      height: HV2.glassBox,
                      decoration: BoxDecoration(
                        color: HomeV2Palette.glass,
                        borderRadius: BorderRadius.circular(HV2.glassRadius),
                        border: Border.all(color: HomeV2Palette.glassBorder),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: img != null
                          ? Image.network(img,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Center(child: icon))
                          : Center(child: icon),
                    ),
                    const SizedBox(width: HV2.discoverInnerGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (badge != null)
                            Container(
                              margin: const EdgeInsets.only(bottom: 2),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: HomeV2Palette.glass,
                                borderRadius: BorderRadius.circular(Radii.xs),
                              ),
                              child: Text(badge,
                                  maxLines: 1,
                                  style: const TextStyle(
                                      color: HomeV2Palette.onColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800)),
                            ),
                          Text(title,
                              maxLines: big ? 4 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: titleStyle),
                          Text(desc,
                              maxLines: big ? 8 : (badge == null ? 2 : 1),
                              overflow: TextOverflow.ellipsis,
                              style: descStyle),
                        ],
                      ),
                    ),
                    const SizedBox(width: HV2.discoverInnerGap),
                    Container(
                      width: HV2.goBtn,
                      height: HV2.goBtn,
                      decoration: const BoxDecoration(
                          color: HomeV2Palette.onColor, shape: BoxShape.circle),
                      child: Icon(
                          item.isExternal
                              ? Icons.open_in_new_rounded
                              : Icons.chevron_right_rounded,
                          size: HV2.goIcon,
                          color: colors.first),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  final double size;
  const _Blob({required this.size});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
            color: HomeV2Palette.blob, shape: BoxShape.circle),
      );
}
