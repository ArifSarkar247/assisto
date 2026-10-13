import 'package:flutter/material.dart';
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

  Future<void> _addUsdWatcher(String Function(String, String) t) async {
    try {
      await context.read<AppState>().api.createItem('watchers', {
        'kind': 'usd_bdt',
        'label': t('USD/BDT রেট', 'USD/BDT rate'),
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
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    String t(String bn, String e) => en ? e : bn;
    final scheme = Theme.of(context).colorScheme;
    final fmt = DateFormat('d MMM, h:mm a');
    return Scaffold(
      appBar: AppBar(title: Text(t('ওয়াচ ফিড', 'Watch feed'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addUsdWatcher(t),
        icon: const Icon(Icons.add_alert_outlined),
        label: Text(t('রেট ওয়াচ', 'Watch rate')),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off, tint: scheme.error,
                  title: t('লোড করা গেল না', "Couldn't load"),
                  action: FilledButton.tonalIcon(onPressed: _load,
                      icon: const Icon(Icons.refresh), label: Text(t('আবার', 'Retry'))))
              : (_hits.isEmpty && _watchers.isEmpty)
                  ? StateMessage(
                      icon: Icons.radar,
                      title: t('কোনো ওয়াচার নেই', 'No watchers yet'),
                      message: t('দাম কমা, USD রেট, খবর — পরিবর্তন হলে জানাব।',
                          'Price drops, USD rate, news — I alert you on change.'))
                  : ListView(padding: const EdgeInsets.all(Gap.md), children: [
                      if (_watchers.isNotEmpty) ...[
                        Text(t('সক্রিয় ওয়াচার', 'Active watchers'),
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
                      Text(t('পরিবর্তন', 'Changes'),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: Gap.sm),
                      if (_hits.isEmpty)
                        Text(t('এখনো কোনো পরিবর্তন নেই।', 'No changes yet.'),
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
