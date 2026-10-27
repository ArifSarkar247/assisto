import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/offline_banner.dart';
import 'agent_core_source.dart';
import 'agent_core_widgets.dart';
import 'agent_run_panel.dart';

/// agent-core WP-APP: run history — the user's last 20 agent tasks (server
/// list, newest first). Tap one to see its steps, result, sources and cost.
class AgentHistoryScreen extends StatefulWidget {
  final AgentCoreSource? source;
  final AcTools? tools;
  const AgentHistoryScreen({super.key, this.source, this.tools});

  @override
  State<AgentHistoryScreen> createState() => _AgentHistoryScreenState();
}

class _AgentHistoryScreenState extends State<AgentHistoryScreen> {
  late final AgentCoreSource _src = widget.source ??
      ApiAgentCoreSource(Provider.of<AppState>(context, listen: false).api);
  List<AcRun>? _runs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await _src.runs();
      if (!mounted) return;
      setState(() {
        _error = null;
        _runs = [
          for (final r in (j['runs'] as List? ?? const []))
            if (r is Map<String, dynamic>) AcRun.fromJson(r),
        ];
      });
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final runs = _runs;
    Widget body;
    if (runs == null && _error == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (runs == null) {
      body = Center(
          child: AcMessage(
              icon: Icons.cloud_off_rounded,
              body: (_error ?? '').isNotEmpty ? _error! : t.acErrorLoad,
              action: t.acRetry,
              onAction: () {
                setState(() => _error = null);
                _load();
              }));
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: [
          const OfflineBanner(),
          if (runs.isEmpty) AcMessage(icon: Icons.history_rounded, body: t.acHistoryEmpty),
          for (final r in runs)
            ListTile(
              key: ValueKey('ac_hist_${r.id}'),
              minVerticalPadding: Gap.md,
              leading: Icon(acStateIcon(r.state), color: acStateColor(s, r.state)),
              title: Text(r.goal, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text([
                acRunStateLabel(t, r.state),
                acTime(context, r.createdAt),
                t.acStepCredits(acNum(context, r.credits)),
              ].where((x) => x.isNotEmpty).join(' · ')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AgentRunScreen(
                        source: _src, runId: r.id, initial: r, tools: widget.tools)));
                _load();
              },
            ),
        ]),
      );
    }
    return Scaffold(appBar: AppBar(title: Text(t.acHistory)), body: SafeArea(child: body));
  }
}

/// One past run: loads its full detail (steps / audit trail) and shows it.
class AgentRunScreen extends StatefulWidget {
  final AgentCoreSource source;
  final int runId;
  final AcRun? initial;
  final AcTools? tools;
  const AgentRunScreen(
      {super.key, required this.source, required this.runId, this.initial, this.tools});

  @override
  State<AgentRunScreen> createState() => _AgentRunScreenState();
}

class _AgentRunScreenState extends State<AgentRunScreen> {
  AcRun? _run;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await widget.source.run(widget.runId);
      if (mounted) setState(() => _run = AcRun.fromJson(j));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _run;
    return Scaffold(
      appBar: AppBar(title: Text(t.acTitle)),
      body: SafeArea(
        child: r == null
            ? Center(
                child: _failed
                    ? AcMessage(
                        icon: Icons.cloud_off_rounded,
                        body: t.acErrorLoad,
                        action: t.acRetry,
                        onAction: () {
                          setState(() => _failed = false);
                          _load();
                        })
                    : const CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                const OfflineBanner(),
                AcRunPanel(source: widget.source, run: r, tools: widget.tools),
              ]),
      ),
    );
  }
}
