import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'probashi_source.dart';
import 'probashi_widgets.dart';

/// probashi-plan: monthly family reports (built by the server on the 1st;
/// each member's section appears only with that member's consent).
class ProbashiReportsScreen extends StatefulWidget {
  final ProbashiSource source;
  const ProbashiReportsScreen({super.key, required this.source});

  @override
  State<ProbashiReportsScreen> createState() => _ProbashiReportsScreenState();
}

class _ProbashiReportsScreenState extends State<ProbashiReportsScreen> {
  bool _loading = true;
  Object? _err;
  List<Map<String, dynamic>> _rows = const [];

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
      _rows = await widget.source.reports();
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  String _month(BuildContext context, String m) => pbsNum(context, m);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.pbsReportsTitle)),
      body: (_loading || _err != null)
          ? PbsStateView(loading: _loading, error: _err, onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(children: [
                if (_rows.isEmpty)
                  Padding(
                    key: const ValueKey('pbs-reports-empty'),
                    padding: const EdgeInsets.all(24),
                    child: Text(t.pbsReportsEmpty, textAlign: TextAlign.center),
                  ),
                for (final r in _rows)
                  ListTile(
                    key: ValueKey('pbs-report-${r['id']}'),
                    minVerticalPadding: 12,
                    leading: Icon(r['read'] == true ? Icons.drafts_rounded : Icons.mark_email_unread_rounded),
                    title: Text(t.pbsReportOf(_month(context, '${r['month']}'))),
                    subtitle: r['read'] == true ? null : Text(t.pbsUnread),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      await Navigator.push(context,
                          MaterialPageRoute(builder: (_) => ProbashiReportView(report: r, source: widget.source)));
                      _load();
                    },
                  ),
              ]),
            ),
    );
  }
}

class ProbashiReportView extends StatefulWidget {
  final Map<String, dynamic> report;
  final ProbashiSource source;
  const ProbashiReportView({super.key, required this.report, required this.source});

  @override
  State<ProbashiReportView> createState() => _ProbashiReportViewState();
}

class _ProbashiReportViewState extends State<ProbashiReportView> {
  @override
  void initState() {
    super.initState();
    if (widget.report['read'] != true) {
      widget.source.markRead(widget.report['id'] as int).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = widget.report;
    final sections = [for (final x in (r['sections'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
    final pool = (r['pool'] as Map?)?.cast<String, dynamic>();
    return Scaffold(
      appBar: AppBar(title: Text(t.pbsReportOf(pbsNum(context, '${r['month']}')))),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        if (sections.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(t.pbsReportNoSections, textAlign: TextAlign.center),
          ),
        for (final s in sections)
          PbsCard(
            title: '${(s['member'] as Map?)?['name'] ?? ''}',
            icon: Icons.person_rounded,
            children: [
              if ((s['lines'] as List? ?? const []).isEmpty) Text(t.pbsReportNothingShared),
              for (final l in (s['lines'] as List? ?? const []))
                Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('$l')),
            ],
          ),
        if (pool != null)
          PbsCard(title: t.pbsPoolTitle, icon: Icons.savings_rounded, children: [
            for (final p in (pool['per_member'] as List? ?? const []))
              Text(t.pbsPoolUsedBy('${(p as Map)['name']}', pbsNum(context, p['used'] ?? 0))),
          ]),
      ]),
    );
  }
}
