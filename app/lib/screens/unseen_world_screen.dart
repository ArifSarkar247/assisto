import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';

/// Unseen World — travel companion (launch gap F). Shows lesser-known
/// destinations in Bangladesh with practical tips, sourced from the owner's
/// unseenbangladesh.com plus open data (attributed in the UI). Content is
/// real only; nothing is fabricated.
class UnseenWorldScreen extends StatefulWidget {
  const UnseenWorldScreen({super.key});
  @override
  State<UnseenWorldScreen> createState() => _UnseenWorldScreenState();
}

class _UnseenWorldScreenState extends State<UnseenWorldScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _error = false;

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
      _data = await context.read<AppState>().api.unseenCompanion();
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.unseenTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.cloud_off, size: 40),
                  const SizedBox(height: 8),
                  Text(t.unseenOffline),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                      onPressed: _load, child: Text(t.retry)),
                ]))
              : _content(t, scheme),
    );
  }

  Widget _content(AppLocalizations t, ColorScheme scheme) {
    final dests =
        (_data?['destinations'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final tips = (_data?['tips'] as List?)?.cast<String>() ?? [];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            const Icon(Icons.travel_explore_outlined),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_data?['attribution'] as String? ?? '',
                  style: const TextStyle(fontSize: 12)),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Text(t.unseenDestinations,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 6),
        for (final d in dests)
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(d['name'] ?? '',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(d['region'] ?? ''),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              children: [
                _row(t.unseenBestSeason, d['best_season']),
                const SizedBox(height: 6),
                _row(t.unseenTip, d['tip']),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('${t.unseenSource}: ${d['source'] ?? ''}',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Text(t.unseenTravelTips,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 6),
        for (final tip in tips)
          ListTile(
            dense: true,
            leading: const Icon(Icons.check_circle_outline, size: 20),
            title: Text(tip, style: const TextStyle(fontSize: 13)),
          ),
      ],
    );
  }

  Widget _row(String label, String? body) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
      const SizedBox(height: 2),
      Text(body ?? '', style: const TextStyle(fontSize: 13)),
    ]);
  }
}
