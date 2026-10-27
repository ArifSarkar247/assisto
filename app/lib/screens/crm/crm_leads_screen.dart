import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import 'crm_contacts_tab.dart' show CrmUsageBanner;
import '../../plans_v2/upgrade_sheet.dart';
import '../../plans_v2/plans_v2.dart';
import '../../state.dart';
import 'package:provider/provider.dart';
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
  PlansV2State _v2 = PlansV2State.off; // plans-v2: owner's plan for this org

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
    if (mounted) {
      _v2 = await loadPlansV2(context.read<AppState>().api, org: widget.org);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('crm-add-lead'),
        onPressed: () async {
          // plans-v2: Free is view only; a full contact list asks to
          // upgrade — the server refuses too, this just says why up front.
          final lock = _v2.crmLock('crm_write') ?? _v2.contactLock();
          if (lock != null) {
            final up = await UpgradeSheet.show(context, lock);
            if (up == true) _load();
            return;
          }
          final added = await Navigator.push<bool>(context,
              MaterialPageRoute(builder: (_) => CrmLeadFormScreen(org: widget.org)));
          if (added == true) _load();
        },
        icon: Icon(_v2.crmLock('crm_write') != null || _v2.contactLock() != null
            ? Icons.lock_rounded
            : Icons.person_add_alt_rounded),
        label: Text(t.crmAddLead),
      ),
      body: Column(children: [
        if (_v2.on && _v2.contacts != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
            child: CrmUsageBanner(usage: _v2.contacts!, viewOnly: !_v2.crmAllows('crm_write')),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
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
                          icon: Icons.people_outline_rounded,
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
                  maxLines: 2, // long Bangla names were cut at 360 px
                  overflow: TextOverflow.ellipsis)),
          Icon(industryIcon(l['industry']), size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Icon(sourceIcon(l['source']), size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ]),
        subtitle: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: _inlineActions(t, l),
        onTap: () async {
          await Navigator.push(context,
              MaterialPageRoute(
                  builder: (_) => CrmLeadDetailScreen(org: widget.org, leadId: (l['id'] as num).toInt())));
          _load();
        },
      ),
    );
  }

  /// Inline call + WhatsApp buttons so a rep can act from the list without
  /// opening the lead. Launch directly via the shared launchers (same mechanism
  /// as the detail screen). Only shown when the lead has a phone / WhatsApp.
  Widget? _inlineActions(AppLocalizations t, Map<String, dynamic> l) {
    final id = (l['id'] as num?)?.toInt();
    final phone = (l['phone'] ?? '').toString().trim().isNotEmpty
        ? (l['phone']).toString().trim()
        : (l['whatsapp'] ?? '').toString().trim();
    if (id == null || phone.isEmpty) return null;
    final name = (l['name']?.toString().isNotEmpty == true
            ? l['name']
            : (l['company'] ?? t.crmLead))
        .toString();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: t.crmCall,
        icon: const Icon(Icons.call_rounded),
        onPressed: () => crmQuickCall(context, id, phone),
      ),
      IconButton(
        tooltip: t.cWhatsapp,
        icon: const Icon(Icons.chat_rounded),
        onPressed: () async {
          final sent = await crmQuickWhatsApp(context, id, name);
          if (sent) _load();
        },
      ),
    ]);
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
        ? Theme.of(context).colorScheme.error
        : warm
            ? AssistoTokens.of(context).warning
            : scheme.primaryContainer;
    final fg = hot
        ? scheme.onError
        : warm
            ? AssistoTokens.of(context).onWarning
            : scheme.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Text('$score',
          style: AType.labelMedium.copyWith(color: fg, fontWeight: FontWeight.w800)),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => FilterChip(
        label: Text(label),
        selected: on,
        onSelected: (_) => onTap(),
      );
}
