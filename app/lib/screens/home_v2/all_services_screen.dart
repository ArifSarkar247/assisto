import 'package:flutter/material.dart';

import '../../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/chatnav.dart';
import '../../widgets/sidebar_sections.dart';
import 'home_v2_shortcuts.dart' show HV2Grid, HomeV2Tile;
import 'home_v2_tokens.dart';

/// ALL SERVICES (home_v2 bottom bar): the full feature catalogue, built from
/// the SAME source as the sidebar ([SidebarSections]) so it is complete and
/// flag-aware (a hidden feature is in neither), plus My Circle and Assisto AI
/// first. Search matches names and the sidebar synonyms.
class AllServicesScreen extends StatefulWidget {
  /// Opens the Assisto AI chat (the home owns that screen).
  final VoidCallback? onOpenChat;
  const AllServicesScreen({super.key, this.onOpenChat});

  @override
  State<AllServicesScreen> createState() => _AllServicesScreenState();
}

class _AllServicesScreenState extends State<AllServicesScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = HomeV2Palette.of(context);
    final sections = SidebarSections.filter(t, _q);
    final q = _q.trim().toLowerCase();
    final core = <(String, IconData, String, VoidCallback)>[
      if (ChatNav.routes.containsKey('circle'))
        ('circle', Icons.diversity_3, t.sidebarMyCircle,
            () => ChatNav.push(context, 'circle')),
      ('ai_chat', Icons.auto_awesome_outlined, t.aichatTitle,
          widget.onOpenChat ?? () => ChatNav.push(context, 'ai_chat')),
    ].where((c) => q.isEmpty || c.$3.toLowerCase().contains(q)).toList();
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final cols = scale > HV2.threeColumnScale ? 3 : 4;

    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(0, Gap.lg, 0, Gap.sm),
          child: Semantics(
            header: true,
            child: Text(text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: HV2.sectionTitleSize,
                    fontWeight: FontWeight.w700,
                    color: p.sectionTitle)),
          ),
        );

    final slivers = <Widget>[
      if (core.isNotEmpty) ...[
        SliverToBoxAdapter(child: header(t.hv2AllCore)),
        SliverToBoxAdapter(
          child: HV2Grid(columns: cols, children: [
            for (final c in core)
              HomeV2Tile(
                  key: ValueKey('all_${c.$1}'),
                  route: c.$1,
                  icon: c.$2,
                  label: c.$3,
                  onTap: c.$4),
          ]),
        ),
      ],
      for (final s in sections) ...[
        SliverToBoxAdapter(child: header(s.title(t))),
        SliverToBoxAdapter(
          child: HV2Grid(columns: cols, children: [
            for (var i = 0; i < s.items.length; i++)
              HomeV2Tile(
                key: ValueKey('all_${s.id}_$i'),
                route: '${s.id}_$i',
                icon: s.items[i].icon,
                label: s.items[i].label(t),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute(builder: s.items[i].builder)),
              ),
          ]),
        ),
      ],
      if (core.isEmpty && sections.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: Gap.xxl),
            child: Text(t.hv2AllEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.navInk)),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: Gap.xl)),
    ];

    return Scaffold(
      // banners-everywhere (owner 26 Oct): one bottom banner, Free only
      bottomNavigationBar: const AdBannerSlot(screen: 'all_services'),
      backgroundColor: p.body,
      appBar: AppBar(
          title: Text(t.hv2NavAll,
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              HV2.pagePad, Gap.sm, HV2.pagePad, 0),
          child: TextField(
            key: const ValueKey('all_search'),
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: t.search,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md)),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: HV2.pagePad),
            child: CustomScrollView(slivers: slivers),
          ),
        ),
      ]),
    );
  }
}
