import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'probashi_source.dart';
import 'probashi_widgets.dart';

/// probashi-plan: the shared pool this month — per member used / limit and
/// every spend (who, what, when). AI credits, never money.
class ProbashiPoolScreen extends StatefulWidget {
  final ProbashiSource source;
  const ProbashiPoolScreen({super.key, required this.source});

  @override
  State<ProbashiPoolScreen> createState() => _ProbashiPoolScreenState();
}

class _ProbashiPoolScreenState extends State<ProbashiPoolScreen> {
  bool _loading = true;
  Object? _err;
  Map<String, dynamic> _d = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      _d = await widget.source.pool();
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.pbsWhoSpent)),
      body: (_loading || _err != null)
          ? PbsStateView(loading: _loading, error: _err, onRetry: _load)
          : RefreshIndicator(onRefresh: _load, child: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    final per = [for (final x in (_d['per_member'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
    final rows = [for (final x in (_d['rows'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      PbsCard(title: t.pbsPoolTitle, icon: Icons.savings_rounded, children: [
        Text(t.pbsPoolLeftShort(pbsNum(context, _d['left'] ?? 0)),
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (per.isEmpty) Text(t.pbsNoSeats),
        for (final p in per)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${(p['member'] as Map?)?['name'] ?? ''}'),
              Text(t.pbsUsedOfCap(pbsNum(context, p['used'] ?? 0), pbsNum(context, p['cap'] ?? 0)),
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: ((p['cap'] as num?) ?? 0) <= 0
                    ? 0
                    : (((p['used'] as num?) ?? 0) / (p['cap'] as num)).clamp(0, 1).toDouble(),
                semanticsLabel: t.pbsUsedOfCap(pbsNum(context, p['used'] ?? 0), pbsNum(context, p['cap'] ?? 0)),
              ),
            ]),
          ),
      ]),
      PbsCard(title: t.pbsLedgerTitle, icon: Icons.receipt_long_rounded, children: [
        if (rows.isEmpty) Text(t.pbsLedgerEmpty, key: const ValueKey('pbs-ledger-empty')),
        for (final r in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${r['who']} · ${r['what']}'),
            subtitle: Text(pbsDate(context, r['at'])),
            trailing: Text(
              (r['kind'] == 'return' ? '+' : '') + pbsNum(context, r['delta'] ?? 0),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
      ]),
    ]);
  }
}
