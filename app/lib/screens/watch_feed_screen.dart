import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// Watcher feed (P4): change alerts the server detected (price/rate/news/job…).
class WatchFeedScreen extends StatefulWidget {
  const WatchFeedScreen({super.key});
  @override
  State<WatchFeedScreen> createState() => _WatchFeedScreenState();
}

class _WatchFeedScreenState extends State<WatchFeedScreen> {
  List<dynamic> _hits = [];
  List<Map<String, dynamic>> _watchers = [];
  bool _loading = true, _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final api = context.read<AppState>().api;
      final f = await api.watchFeed();
      _hits = (f['hits'] ?? []) as List;
      _watchers = await api.listItems('watchers');
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addUsdWatcher(AppLocalizations t) async {
    try {
      await context.read<AppState>().api.createItem('watchers', {
        'kind': 'usd_bdt',
        'label': t.usdBdtRate,
        'interval_min': 360,
      });
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fmt = DateFormat('d MMM, h:mm a');
    return Scaffold(
      appBar: AppBar(title: Text(t.watchFeed)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addUsdWatcher(t),
        icon: const Icon(Icons.add_alert_outlined),
        label: Text(t.watchRate),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off, tint: scheme.error,
                  title: t.loadFailed,
                  action: FilledButton.tonalIcon(onPressed: _load,
                      icon: const Icon(Icons.refresh), label: Text(t.retry)))
              : (_hits.isEmpty && _watchers.isEmpty)
                  ? StateMessage(
                      icon: Icons.radar,
                      title: t.noWatchersYet,
                      message: t.priceDropsUsdRateNews)
                  : ListView(padding: const EdgeInsets.all(Gap.md), children: [
                      if (_watchers.isNotEmpty) ...[
                        Text(t.activeWatchers,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: Gap.sm),
                        for (final w in _watchers)
                          Card(child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.visibility_outlined),
                            title: Text(w['label'] ?? w['kind'] ?? ''),
                            subtitle: Text(w['last_value']?.toString() ?? ''),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await context.read<AppState>().api
                                    .deleteItem('watchers', w['id']);
                                _load();
                              }),
                          )),
                        const SizedBox(height: Gap.lg),
                      ],
                      Text(t.changes,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: Gap.sm),
                      if (_hits.isEmpty)
                        Text(t.noChangesYet,
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      for (final h in _hits)
                        Card(child: ListTile(
                          leading: Icon(
                              h['severity'] == 'high'
                                  ? Icons.priority_high
                                  : Icons.notifications_none,
                              color: h['severity'] == 'high' ? scheme.error : scheme.primary),
                          title: Text(h['summary'] ?? ''),
                          subtitle: Text(DateTime.tryParse(h['at'] ?? '') != null
                              ? fmt.format(DateTime.parse(h['at']).toLocal())
                              : ''),
                        )),
                    ]),
    );
  }
}
