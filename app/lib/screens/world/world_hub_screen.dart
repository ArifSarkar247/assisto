import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../world/world_api.dart';
import 'world_ask_screen.dart';
import 'world_guide_hub_screen.dart';
import 'world_jobs_screen.dart';
import 'world_today_screen.dart';

/// p4-world UNSEEN WORLD — "everything in one place": Ask anything (live web
/// answers with sources, shown ONLY when the owner connected a search key),
/// Today cards, Jobs, and the Expats / Students / Farmers / Government /
/// Health hubs. Every tile works with voice (mic in, read-aloud out).
class WorldHubScreen extends StatefulWidget {
  const WorldHubScreen({super.key, this.api});
  final WorldApi? api;

  @override
  State<WorldHubScreen> createState() => _WorldHubScreenState();
}

class _WorldHubScreenState extends State<WorldHubScreen> {
  late final WorldApi api = widget.api ?? ApiWorldApi(context.read<AppState>().api);
  bool _searchReady = false;
  int _credits = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await api.config().timeout(const Duration(seconds: 15));
      if (!mounted || worldStatus(c) != 200) return;
      setState(() {
        _searchReady = c['search_ready'] == true;
        _credits = (c['web_answer_credits'] as num?)?.toInt() ?? 0;
      });
    } catch (_) {
      // offline: the key-gated tile simply stays hidden
    }
  }

  void _go(Widget w) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tiles = <_Tile>[
      if (_searchReady)
        _Tile(Icons.travel_explore, t.uwAskTitle, t.uwAskTileSub,
            () => _go(WorldAskScreen(api: api, credits: _credits))),
      _Tile(Icons.wb_sunny_outlined, t.uwTodayTitle, t.uwTodayTileSub,
          () => _go(WorldTodayScreen(api: api))),
      _Tile(Icons.work_outline, t.uwJobsTitle, t.uwJobsTileSub,
          () => _go(WorldJobsScreen(api: api))),
      _Tile(Icons.flight_takeoff, t.uwHubExpat, t.uwHubExpatSub,
          () => _go(WorldGuideHubScreen(hubId: 'expat', api: api))),
      _Tile(Icons.school_outlined, t.uwHubStudents, t.uwHubStudentsSub,
          () => _go(WorldGuideHubScreen(hubId: 'students', api: api))),
      _Tile(Icons.grass_outlined, t.uwHubFarmers, t.uwHubFarmersSub,
          () => _go(WorldGuideHubScreen(hubId: 'farmers', api: api))),
      _Tile(Icons.account_balance_outlined, t.uwHubGov, t.uwHubGovSub,
          () => _go(WorldGuideHubScreen(hubId: 'gov', api: api))),
      _Tile(Icons.health_and_safety_outlined, t.uwHubHealth, t.uwHubHealthSub,
          () => _go(WorldGuideHubScreen(hubId: 'health', api: api))),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(t.uwTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
          children: [
            Text(t.uwIntro,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
            const SizedBox(height: Gap.md),
            for (final tile in tiles)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Card(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: Gap.lg, vertical: Gap.xs),
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      foregroundColor: scheme.onPrimaryContainer,
                      child: Icon(tile.icon),
                    ),
                    title: Text(tile.title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(tile.sub),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: tile.onTap,
                  ),
                ),
              ),
            const SizedBox(height: Gap.sm),
            Row(children: [
              Icon(Icons.mic_none, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(t.uwVoiceHint,
                      style: TextStyle(color: scheme.onSurfaceVariant))),
            ]),
          ],
        ),
      ),
    );
  }
}

class _Tile {
  const _Tile(this.icon, this.title, this.sub, this.onTap);
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;
}
