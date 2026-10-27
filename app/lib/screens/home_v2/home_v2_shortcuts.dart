import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/badges_bus.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/chatnav.dart';
import '../../widgets/circle_badges.dart';
import '../../widgets/home_quick_buttons.dart';
import 'home_v2_tokens.dart';

/// home_v2 shortcuts: My Circle (pinned, always first) + up to 11 of the
/// user's choice = 12 tiles in a 4-column grid (3 columns at large font).
///
/// Owner default order (26 Oct): Family Care, Safe Journey, Digital Ledger,
/// AI Sales Assistant, CCTV Cameras, Vehicle Tracking, Job Hunter, Phone
/// Security, Prepaid Meter, Budget, Contract Scanner. Each maps to a REAL
/// ChatNav route; a route that is not in [ChatNav.routes] for this user
/// (feature flag off, e.g. CCTV everywhere today, vehicles / anti-theft in
/// Play when the owner hides them) is skipped and the next real feature from
/// [fillPool] takes the slot — never a fake or dead tile. A feature the owner
/// / staff / testers see only as a server PREVIEW counts as off here too, so
/// the owner's home shows exactly what normal users see.
///
/// Users who customised the old home keep exactly their own set (their six,
/// in their order; nothing they did not choose is added). Their choices are
/// stored again under [prefsKey] the first time they press Save.
class HomeV2Shortcuts {
  HomeV2Shortcuts._();

  static const prefsKey = 'home_quick_v2';
  static const max = 11;

  static const ownerOrder = [
    'family',
    'journey',
    'khata',
    'sales_agent',
    'watchman',
    'vehicle_tracking',
    'jobs',
    'lost_stolen',
    'prepaid_meter',
    'budget',
    'contract',
  ];

  /// Next real features, in order, for a skipped default slot.
  static const fillPool = [
    'reminders',
    'money',
    'notes',
    'documents',
    'emergency',
    'scam',
    'subscriptions',
    'tax',
    'contacts',
    'birthdays',
  ];

  /// The owner's 11 with the names and icons of the reference design.
  static final List<QuickShortcut> _owner = [
    QuickShortcut('family', Icons.house_outlined, (t) => t.hv2TileFamily),
    QuickShortcut(
        'journey', Icons.location_on_outlined, (t) => t.journeyHubTitle),
    QuickShortcut('khata', Icons.description_outlined, (t) => t.hv2TileLedger),
    QuickShortcut(
        'sales_agent', Icons.show_chart_rounded, (t) => t.hv2TileSales),
    QuickShortcut('watchman', Icons.videocam_outlined, (t) => t.hv2TileCctv),
    QuickShortcut('vehicle_tracking', Icons.directions_car_outlined,
        (t) => t.hv2TileVehicle),
    QuickShortcut('jobs', Icons.work_outline_rounded, (t) => t.hv2TileJobs),
    QuickShortcut('lost_stolen', Icons.phonelink_lock_outlined,
        (t) => t.hv2TilePhoneSecurity),
    QuickShortcut(
        'prepaid_meter', Icons.electric_meter_outlined, (t) => t.hv2TileMeter),
    // budget-remittance (owner 26 Oct): "Budget" opening the existing budget
    // while the flag is OFF; "Budget and Remittance" opening the new feature
    // once `budget_remittance` is ON (see [openRoute]).
    QuickShortcut('budget', Icons.pie_chart_outline_rounded,
        (t) => remittanceOn ? t.rmtTileTitle : t.budgetTitle),
    QuickShortcut('contract', Icons.policy_outlined, (t) => t.hv2TileContract),
  ];

  /// Everything pinnable in THIS build for THIS user: the owner's 11 first,
  /// then every old-home shortcut (same flag / medical rules), no duplicates,
  /// only routes that really open ([ChatNav.routes]).
  static List<QuickShortcut> get catalog {
    final routes = ChatNav.routes;
    final out = <QuickShortcut>[];
    final seen = <String>{};
    for (final s in [..._owner, ...HomeQuickButtons.catalog]) {
      if (seen.contains(s.route) ||
          HomeQuickButtons.pinnedAliases.contains(s.route) ||
          !routes.containsKey(s.route) ||
          // owner feedback 27 Oct: a feature the owner / testers see only as
          // a PREVIEW is OFF for home tiles (normal users do not have it);
          // it stays in the sidebar / All Services, marked "Preview".
          FeatureFlags.instance.isPreviewRoute(s.route)) {
        continue;
      }
      seen.add(s.route);
      out.add(s);
    }
    return out;
  }

  /// The Budget tile becomes Budget and Remittance when that flag is on.
  /// (A preview-only remittance keeps the plain Budget tile on home.)
  static bool get remittanceOn =>
      FeatureFlags.instance.homeTileAllowed('remittance') &&
      ChatNav.routes.containsKey('remittance');

  /// Where a tile opens (the Budget tile -> the remittance feature when on).
  static String openRoute(String route) =>
      route == 'budget' && remittanceOn ? 'remittance' : route;

  static QuickShortcut? byRoute(String r, [List<QuickShortcut>? cat]) {
    for (final s in cat ?? catalog) {
      if (s.route == r) return s;
    }
    return null;
  }

  /// The owner default for this user: the 11 in order, skipped ones replaced
  /// from [fillPool].
  static List<String> defaults() {
    final cat = catalog;
    final out = <String>[];
    for (final r in [...ownerOrder, ...fillPool]) {
      if (out.length == max) break;
      if (!out.contains(r) && byRoute(r, cat) != null) out.add(r);
    }
    return out;
  }

  /// Which owner defaults this user does NOT get, and what filled each slot
  /// (for the STATUS / tests).
  static List<String> skippedDefaults() {
    final cat = catalog;
    return [
      for (final r in ownerOrder)
        if (byRoute(r, cat) == null) r
    ];
  }

  /// A saved list, cleaned: only routes that open, no duplicates, never My
  /// Circle (it is pinned), at most [max]. NOT topped up — the user's own set
  /// is exactly what they chose.
  static List<String> sanitize(List<String> saved) {
    final cat = catalog;
    final out = <String>[];
    for (final r in saved) {
      if (out.length == max) break;
      if (!out.contains(r) &&
          !HomeQuickButtons.pinnedAliases.contains(r) &&
          byRoute(r, cat) != null) {
        out.add(r);
      }
    }
    return out;
  }

  static Future<List<String>?> _read(String key) async {
    try {
      final raw = await Settings.getString(key);
      if (raw == null || raw.isEmpty) return null;
      return (jsonDecode(raw) as List).map((e) => '$e').toList();
    } catch (_) {
      return null;
    }
  }

  /// What home shows: the v2 set the user saved, else the six they picked on
  /// the old home, else the owner default. An emptied set (every saved
  /// feature hidden since) falls back to the owner default.
  static Future<List<String>> load() async {
    final own = await _read(prefsKey);
    if (own != null) {
      final s = sanitize(own);
      return s.isEmpty ? defaults() : s;
    }
    final old = await _read(HomeQuickButtons.prefsKey);
    if (old != null) {
      final s = sanitize(old);
      return s.isEmpty ? defaults() : s;
    }
    return defaults();
  }

  static Future<void> save(List<String> routes) =>
      Settings.setString(prefsKey, jsonEncode(sanitize(routes)));
}

/// The SHORTCUTS section: title + ONE Edit button, then the grid.
class HomeV2ShortcutsSection extends StatefulWidget {
  /// Preview/test seed (skips SharedPreferences).
  final List<String>? debugRoutes;
  final CircleBadgeState? debugCircle;
  const HomeV2ShortcutsSection({super.key, this.debugRoutes, this.debugCircle});

  @override
  State<HomeV2ShortcutsSection> createState() => _HomeV2ShortcutsSectionState();
}

class _HomeV2ShortcutsSectionState extends State<HomeV2ShortcutsSection> {
  late List<String> _routes = widget.debugRoutes != null
      ? HomeV2Shortcuts.sanitize(widget.debugRoutes!)
      : HomeV2Shortcuts.defaults();

  @override
  void initState() {
    super.initState();
    if (widget.debugRoutes == null) _load();
  }

  Future<void> _load() async {
    final r = await HomeV2Shortcuts.load();
    if (mounted) setState(() => _routes = r);
  }

  Future<void> _edit() async {
    HapticFeedback.selectionClick();
    final cat = HomeV2Shortcuts.catalog;
    final picked = await showQuickButtonsPicker(context, _routes,
        resetTo: HomeV2Shortcuts.defaults(),
        max: HomeV2Shortcuts.max,
        catalog: cat,
        lookup: (r) => HomeV2Shortcuts.byRoute(r, cat),
        title: (t) => t.hv2PickTitle,
        hint: (t, n) => t.hv2PickHint(circleBadgeLabel(n, t.localeName)),
        requireFull: false);
    if (picked == null || !mounted) return;
    setState(() => _routes = HomeV2Shortcuts.sanitize(picked));
    await HomeV2Shortcuts.save(_routes);
  }

  Future<void> _openCircle() async {
    const r = HomeQuickButtons.pinnedRoute;
    final b = ChatNav.routes[r];
    if (b == null) {
      ChatNav.push(context, r); // hidden -> the friendly notice
      return;
    }
    await Navigator.push(context,
        MaterialPageRoute(builder: b, settings: const RouteSettings(name: r)));
    BadgesBus.instance.poke(); // back on home: re-fetch the counts
  }

  Widget _circle(Widget Function(BuildContext, CircleBadgeState) builder) {
    final seed = widget.debugCircle;
    if (seed != null) return Builder(builder: (c) => builder(c, seed));
    return ValueListenableBuilder<CircleBadgeState>(
      valueListenable: CircleBadges.instance.state,
      builder: (c, v, _) => builder(c, v),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = HomeV2Palette.of(context);
    final cat = HomeV2Shortcuts.catalog;
    final items = [
      for (final r in _routes) HomeV2Shortcuts.byRoute(r, cat),
    ].whereType<QuickShortcut>().toList();
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final cols = scale > HV2.threeColumnScale ? 3 : 4;
    final circleVisible =
        ChatNav.routes.containsKey(HomeQuickButtons.pinnedRoute);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(t.quickTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: HV2.sectionTitleSize,
                    fontWeight: FontWeight.w700,
                    color: p.sectionTitle)),
          ),
        ),
        _EditChip(onTap: _edit),
      ]),
      const SizedBox(height: HV2.sectionGap - 10),
      HV2Grid(
        columns: cols,
        children: [
          if (circleVisible)
            _circle((c, b) => HomeV2Tile(
                  key: const ValueKey('hv2_tile_circle'),
                  route: HomeQuickButtons.pinnedRoute,
                  icon: Icons.diversity_3,
                  label: t.sidebarMyCircle,
                  subtitle: t.hv2CircleSub,
                  semanticsLabel: t.hv2CircleA11y,
                  pinned: true,
                  unread: b.unread,
                  missed: b.missed,
                  onTap: _openCircle,
                  onLongPress: _edit,
                )),
          for (final s in items)
            HomeV2Tile(
              key: ValueKey('hv2_tile_${s.route}'),
              route: s.route,
              icon: s.icon,
              label: s.label(t),
              onTap: () =>
                  ChatNav.push(context, HomeV2Shortcuts.openRoute(s.route)),
              onLongPress: _edit,
            ),
        ],
      ),
    ]);
  }
}

/// The shortcut grid (CSS grid of the reference): [columns] equal columns,
/// [HV2.gridGap] gaps, and every ROW as tall as its tallest tile (a 2-line
/// label makes only its own row taller, like the reference's last row).
class HV2Grid extends StatelessWidget {
  final int columns;
  final List<Widget> children;
  const HV2Grid({super.key, required this.columns, required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cell = (c.maxWidth - HV2.gridGap * (columns - 1)) / columns;
      final rows = <Widget>[];
      for (var i = 0; i < children.length; i += columns) {
        final cells = <Widget>[];
        for (var k = 0; k < columns; k++) {
          if (k > 0) cells.add(const SizedBox(width: HV2.gridGap));
          final n = i + k;
          cells.add(Expanded(
              child: n < children.length ? children[n] : const SizedBox()));
        }
        if (rows.isNotEmpty) rows.add(const SizedBox(height: HV2.gridGap));
        rows.add(IntrinsicHeight(
          child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch, children: cells),
        ));
      }
      return HV2CellWidth(
        width: cell,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
      );
    });
  }
}

/// The grid cell width, for labels deciding one line vs two (a
/// LayoutBuilder cannot live inside the rows' IntrinsicHeight).
class HV2CellWidth extends InheritedWidget {
  final double width;
  const HV2CellWidth({super.key, required this.width, required super.child});

  static double? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HV2CellWidth>()?.width;

  @override
  bool updateShouldNotify(HV2CellWidth old) => old.width != width;
}

/// The "Edit" chip: 32 dp pill (reference) inside a 48 dp touch target.
class _EditChip extends StatelessWidget {
  final VoidCallback onTap;
  const _EditChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = HomeV2Palette.of(context);
    return Semantics(
      button: true,
      label: t.hv2EditA11y,
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('hv2_edit'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Center(
            widthFactor: 1,
            child: Container(
              constraints: const BoxConstraints(minHeight: HV2.chipH),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: p.chip,
                borderRadius: BorderRadius.circular(Radii.pill),
                border: Border.all(color: p.chipBorder),
                boxShadow: [
                  BoxShadow(
                      color: p.tileShadow,
                      blurRadius: 3,
                      offset: const Offset(0, 1)),
                ],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.edit_outlined, size: HV2.chipIcon, color: p.chipInk),
                const SizedBox(width: 5),
                Text(t.hv2Edit,
                    maxLines: 1,
                    style: TextStyle(
                        fontSize: HV2.chipFont,
                        fontWeight: FontWeight.w600,
                        color: p.chipInk)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// One shortcut card: white rounded card, gradient "app icon" squircle with
/// a top gloss, label under it. The pinned My Circle tile has the indigo
/// border + tint, the unread count pill and the missed-call dot.
class HomeV2Tile extends StatelessWidget {
  final String route;
  final IconData icon;
  final String label;

  /// One line under the title (only the pinned My Circle tile uses it).
  final String? subtitle;

  /// Screen-reader name when it differs from [label] (e.g. "My Circle,
  /// chat and call"); the unread / missed parts are added after it.
  final String? semanticsLabel;
  final bool pinned;
  final int unread;
  final bool missed;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const HomeV2Tile({
    super.key,
    required this.route,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.semanticsLabel,
    this.onLongPress,
    this.pinned = false,
    this.unread = 0,
    this.missed = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = HomeV2Palette.of(context);
    final (begin, end) = HV2.cssAngle(HV2.tileAngleDeg);
    final g = HomeV2Palette.tileGradient(route);
    final radius = BorderRadius.circular(HV2.tileRadius);
    final count = circleBadgeLabel(unread, t.localeName);
    final a11y = [
      semanticsLabel ?? label,
      if (unread > 0) t.hcUnread(count),
      if (missed) t.hcMissed,
    ].join('. ');
    final squircle = Container(
      width: HV2.squircle,
      height: HV2.squircle,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HV2.squircleRadius),
        gradient: LinearGradient(begin: begin, end: end, colors: g),
      ),
      child: Stack(children: [
        // .gi::before — the top-half gloss
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: HV2.squircle / 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(HV2.squircleRadius)),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [HomeV2Palette.gloss, HomeV2Palette.glossEnd],
              ),
            ),
          ),
        ),
        Center(
            child: Icon(icon,
                size: HV2.squircleIcon, color: HomeV2Palette.onColor)),
      ]),
    );
    return Semantics(
      button: true,
      label: a11y,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: HV2.tileMinH),
        decoration: BoxDecoration(
          borderRadius: radius,
          color: pinned ? null : p.tile,
          gradient: pinned
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [p.pinTop, p.tile],
                  stops: const [0, 0.7])
              : null,
          border: Border.all(
              color: pinned ? p.pinBorder : p.tileBorder,
              width: pinned ? 1.5 : 1),
          boxShadow: [
            BoxShadow(
                color: p.tileShadow,
                blurRadius: 12,
                offset: const Offset(0, 4)),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            onLongPress: onLongPress,
            child: Stack(clipBehavior: Clip.none, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(HV2.tilePadSide,
                    HV2.tilePadTop, HV2.tilePadSide, HV2.tilePadBottom),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Stack(clipBehavior: Clip.none, children: [
                          squircle,
                          if (missed)
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: Container(
                                key: const ValueKey('hv2_missed_dot'),
                                width: HV2.missedDot,
                                height: HV2.missedDot,
                                decoration: BoxDecoration(
                                  color: HomeV2Palette.missedDot,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: p.missedRing, width: 2),
                                ),
                              ),
                            ),
                        ]),
                      ),
                      const SizedBox(height: HV2.tileInnerGap),
                      MediaQuery.withClampedTextScaling(
                        maxScaleFactor: HV2.tileLabelMaxScale,
                        child: _TileLabel(
                            label: label,
                            style: TextStyle(
                                fontSize: HV2.tileLabel,
                                height: HV2.tileLabelHeight,
                                fontWeight: FontWeight.w600,
                                color: p.tileLabel)),
                      ),
                      if (subtitle != null)
                        MediaQuery.withClampedTextScaling(
                          maxScaleFactor: HV2.tileLabelMaxScale,
                          child: Text(subtitle!,
                              key: const ValueKey('hv2_tile_subtitle'),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: HV2.tileSub,
                                  height: 1.15,
                                  fontWeight: FontWeight.w600,
                                  color: p.circleSub)),
                        ),
                    ]),
              ),
              if (unread > 0)
                Positioned(
                  top: 5,
                  right: 5,
                  child: Container(
                    key: const ValueKey('hv2_unread'),
                    constraints: const BoxConstraints(
                        minWidth: HV2.countPillH, minHeight: HV2.countPillH),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: HomeV2Palette.countPill,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.3,
                      child: Text(count,
                          style: const TextStyle(
                              color: HomeV2Palette.onColor,
                              fontSize: 11,
                              height: 1.1,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A tile label: one line like the reference when it nearly fits (shrunk at
/// most to [HV2.labelFitMin] of its size, only at normal font sizes), else
/// two centred lines. Never clipped.
class _TileLabel extends StatelessWidget {
  final String label;
  final TextStyle style;
  const _TileLabel({required this.label, required this.style});

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final dir = Directionality.of(context);
    final style2 = DefaultTextStyle.of(context).style.merge(style);
    final cell = HV2CellWidth.of(context);
    Widget two() => Text(label,
        maxLines: 2,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: style);
    if (cell == null) return two();
    // tile side padding + border
    final maxWidth = cell - 2 * HV2.tilePadSide - 3;
    {
      final tp = TextPainter(
          text: TextSpan(text: label, style: style2),
          textDirection: dir,
          textScaler: scaler,
          maxLines: 1)
        ..layout();
      final w = tp.width;
      tp.dispose();
      final fits = w <= maxWidth;
      final nearly =
          scaler.scale(1) <= 1.15 && w * HV2.labelFitMin <= maxWidth;
      if (fits || nearly) {
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label, maxLines: 1, style: style),
        );
      }
      return two();
    }
  }
}
