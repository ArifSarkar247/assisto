import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../world/world_api.dart';
import '../../world/world_widgets.dart';
import '../jobs_screen.dart';

/// p4-world JOBS HUB: the official / well-known job portals as link-out cards
/// (government, bank, private, overseas, NGO). We never copy or scrape a job
/// post. Job-type alerts appear ONLY when a lawful feed is connected (the
/// Careerjet publisher API) and are capped by the server (1 a day by default).
class WorldJobsScreen extends StatefulWidget {
  const WorldJobsScreen({super.key, this.api});
  final WorldApi? api;

  @override
  State<WorldJobsScreen> createState() => _WorldJobsScreenState();
}

class _WorldJobsScreenState extends State<WorldJobsScreen> {
  late final WorldApi api = widget.api ?? ApiWorldApi(context.read<AppState>().api);
  Map<String, dynamic>? _d;
  bool _loading = true;
  bool _error = false;
  String _cat = '';
  bool _alerts = false;
  List<String> _types = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final lang = uwLang(context);
    setState(() {
      _loading = _d == null;
      _error = false;
    });
    Map<String, dynamic>? j;
    try {
      j = await api.jobs().timeout(const Duration(seconds: 20));
      if (worldStatus(j) != 200) j = null;
      if (j != null) await WorldCache.save('jobs', lang, j);
    } catch (_) {
      j = null;
    }
    j ??= await WorldCache.read('jobs', lang);
    if (!mounted) return;
    final prefs = worldMap(j?['prefs']);
    setState(() {
      _d = j;
      _error = j == null;
      _loading = false;
      _alerts = prefs['job_alerts'] == true;
      _types = (prefs['job_types'] is List)
          ? (prefs['job_types'] as List).map((e) => '$e').toList()
          : <String>[];
    });
  }

  Future<void> _savePrefs() async {
    final t = AppLocalizations.of(context);
    try {
      final r = await api
          .savePrefs({'job_alerts': _alerts, 'job_types': _types})
          .timeout(const Duration(seconds: 20));
      if (worldStatus(r) != 200) throw StateError('status');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.uwSaved)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.uwSaveFailed)));
      }
    }
  }

  IconData _catIcon(String c) => switch (c) {
        'govt' => Icons.account_balance_outlined,
        'bank' => Icons.savings_outlined,
        'overseas' => Icons.flight_takeoff,
        'ngo' => Icons.volunteer_activism_outlined,
        _ => Icons.business_center_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.uwJobsTitle)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.loadFailed,
                  message: t.uwOffline,
                  action: FilledButton.tonalIcon(
                      onPressed: _load, icon: const Icon(Icons.refresh), label: Text(t.retry)))
              : _body(t, scheme),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    final d = _d!;
    final cats = worldList(d['categories']);
    final portals = worldList(d['portals'])
        .where((p) => _cat.isEmpty || p['cat'] == _cat)
        .toList();
    final types = worldList(d['types']);
    final alertsReady = d['alerts_ready'] == true;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
        children: [
          UwNote(icon: Icons.shield_outlined, text: '${d['safety'] ?? ''}', warn: true),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            ChoiceChip(
                label: Text(t.uwAll),
                selected: _cat.isEmpty,
                onSelected: (_) => setState(() => _cat = '')),
            for (final c in cats)
              ChoiceChip(
                avatar: Icon(_catIcon('${c['id']}'), size: 18),
                label: Text('${c['name']}'),
                selected: _cat == c['id'],
                onSelected: (_) => setState(() => _cat = _cat == c['id'] ? '' : '${c['id']}'),
              ),
          ]),
          const SizedBox(height: Gap.md),
          for (final p in portals)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.sm, Gap.xs),
                leading: Icon(_catIcon('${p['cat']}'), color: scheme.primary),
                title: Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${p['desc']}\n${Uri.tryParse('${p['url']}')?.host.replaceFirst('www.', '') ?? ''}'),
                isThreeLine: true,
                trailing: Icon(Icons.open_in_new, color: scheme.primary),
                onTap: () => uwOpen(context, '${p['url']}'),
              ),
            ),
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const JobsScreen())),
            icon: const Icon(Icons.checklist_rtl),
            label: Text(t.uwTrackApplications),
          ),
          if (alertsReady) ...[
            UwHeader(t.uwJobAlerts),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.uwJobAlertsOn),
              subtitle: Text(t.uwJobAlertsCap),
              value: _alerts,
              onChanged: (v) => setState(() => _alerts = v),
            ),
            Text(t.uwJobTypesPick, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              for (final ty in types)
                FilterChip(
                  label: Text('${ty['name']}'),
                  selected: _types.contains(ty['id']),
                  onSelected: (v) => setState(() {
                    final id = '${ty['id']}';
                    if (v && !_types.contains(id) && _types.length < 5) {
                      _types.add(id);
                    } else if (!v) {
                      _types.remove(id);
                    }
                  }),
                ),
            ]),
            const SizedBox(height: Gap.md),
            FilledButton(onPressed: _savePrefs, child: Text(t.uwSave)),
          ],
          const SizedBox(height: Gap.lg),
          Text('${d['feeds_note'] ?? ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          Text(t.uwReviewedOn(uwWhen(context, '${d['reviewed'] ?? ''}', time: false)),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
