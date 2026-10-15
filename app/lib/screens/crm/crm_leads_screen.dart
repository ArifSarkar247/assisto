import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import 'crm_lead_detail_screen.dart';
import 'crm_lead_form_screen.dart';

/// Leads list (CRM_SPEC): score badge, industry, company size, source icon,
/// stage, last contact; filters + search.
class CrmLeadsScreen extends StatefulWidget {
  final int org;
  const CrmLeadsScreen({super.key, required this.org});
  @override
  State<CrmLeadsScreen> createState() => _CrmLeadsScreenState();
}

class _CrmLeadsScreenState extends State<CrmLeadsScreen> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;
  CrmError? _error;
  String _q = '';
  String? _priority, _industry;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _list = await CrmApi.of(context)
          .leads(widget.org, priority: _priority, industry: _industry, q: _q);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final added = await Navigator.push<bool>(context,
              MaterialPageRoute(builder: (_) => CrmLeadFormScreen(org: widget.org)));
          if (added == true) _load();
        },
        icon: const Icon(Icons.person_add_alt),
        label: Text(t.crmAddLead),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: t.search,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.pill)),
            ),
            onSubmitted: (v) {
              _q = v.trim();
              _load();
            },
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            children: [
              _chip(t.crmFilterHigh, _priority == 'high', () {
                _priority = _priority == 'high' ? null : 'high';
                _load();
              }),
              const SizedBox(width: Gap.xs),
              _chip(t.crmIndRmg, _industry == 'rmg', () {
                _industry = _industry == 'rmg' ? null : 'rmg';
                _load();
              }),
              const SizedBox(width: Gap.xs),
              _chip(t.crmIndPharma, _industry == 'pharma', () {
                _industry = _industry == 'pharma' ? null : 'pharma';
                _load();
              }),
              const SizedBox(width: Gap.xs),
              _chip(t.crmIndRetail, _industry == 'retail', () {
                _industry = _industry == 'retail' ? null : 'retail';
                _load();
              }),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const CrmStateView.loading()
              : _error != null
                  ? CrmStateView.error(
                      error: _error!, title: t.loadFailed, onRetry: _load)
                  : _list.isEmpty
                      ? CrmStateView.empty(
                          icon: Icons.people_outline,
                          title: t.crmNoLeads,
                          message: t.crmNoLeadsHint)
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView(
                            padding: const EdgeInsets.all(Gap.md),
                            children: [for (final l in _list) _leadTile(t, l)],
                          ),
                        ),
        ),
      ]),
    );
  }

  Widget _leadTile(AppLocalizations t, Map<String, dynamic> l) {
    final size = (l['company_size'] as num?)?.toInt() ?? 0;
    final sub = [
      if ((l['company'] ?? '').toString().isNotEmpty) l['company'],
      l['industry_display'],
      if (size > 0) '$size ${t.crmHeadcount}',
      l['status_display'],
    ].where((e) => (e ?? '').toString().isNotEmpty).join(' · ');
    return Card(
      child: ListTile(
        leading: _scoreBadge((l['score'] as num?)?.toInt() ?? 0),
        title: Row(children: [
          Expanded(
              child: Text(
                  l['name']?.toString().isNotEmpty == true ? l['name'] : (l['company'] ?? t.crmLead),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis)),
          Icon(industryIcon(l['industry']), size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Icon(sourceIcon(l['source']), size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ]),
        subtitle: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
        onTap: () async {
          await Navigator.push(context,
              MaterialPageRoute(
                  builder: (_) => CrmLeadDetailScreen(org: widget.org, leadId: (l['id'] as num).toInt())));
          _load();
        },
      ),
    );
  }

  /// High-contrast score badge. The shared [ScoreBadge] renders low scores as
  /// grey-on-grey (surfaceContainerHighest + onSurfaceVariant) which fails
  /// contrast in both themes; here low scores use the theme's primaryContainer
  /// / onPrimaryContainer pair for a legible tinted chip, while hot/warm keep
  /// the familiar red/amber-on-white semantics.
  Widget _scoreBadge(int score) {
    final scheme = Theme.of(context).colorScheme;
    final hot = score >= 90;
    final warm = score >= 60;
    final bg = hot
        ? Brand.danger
        : warm
            ? Brand.warning
            : scheme.primaryContainer;
    final fg = (hot || warm) ? Colors.white : scheme.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text('$score',
          style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 12)),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => FilterChip(
        label: Text(label),
        selected: on,
        onSelected: (_) => onTap(),
      );
}
