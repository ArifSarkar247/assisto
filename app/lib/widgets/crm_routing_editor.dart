import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../screens/crm/crm_common.dart';
import '../screens/crm/crm_advanced_api.dart';

/// Routing configuration (CRM spec #8): ordered territory / industry / source
/// rules, first-match wins (mirrors logic_team.route_by_rules + pipeline.
/// route_lead). Also a ROUND-ROBIN toggle: when on, leads that match no rule
/// are handed out fairly in rotation (logic_team.round_robin_pick server-side).
class CrmRoutingEditor extends StatelessWidget {
  final int org;
  final List<Map<String, dynamic>> rules;
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> territories;
  final VoidCallback onChanged;
  const CrmRoutingEditor({
    super.key,
    required this.org,
    required this.rules,
    required this.members,
    required this.territories,
    required this.onChanged,
  });

  String _memberName(dynamic id) {
    final m = members.firstWhere(
        (x) => (x['id'] as num?)?.toInt() == (id as num?)?.toInt(),
        orElse: () => const {});
    return m['user_name']?.toString() ?? '—';
  }

  Future<void> _add(BuildContext context) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RuleSheet(org: org, members: members, territories: territories),
    );
    if (saved == true) onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Icons.add),
        label: Text(t.crmAddRule),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          NeedsKeyBanner(t.crmRoutingNote, icon: Icons.alt_route_outlined),
          const SizedBox(height: Gap.sm),
          if (rules.isEmpty)
            Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Text(t.crmNoRouting))
          else
            for (int i = 0; i < rules.length; i++) _ruleCard(context, t, i),
        ],
      ),
    );
  }

  Widget _ruleCard(BuildContext context, AppLocalizations t, int i) {
    final r = rules[i];
    final conds = [
      if ((r['match_industry'] ?? '').toString().isNotEmpty)
        '${t.crmIndustry}: ${r['match_industry']}',
      if ((r['match_source'] ?? '').toString().isNotEmpty)
        '${t.crmSource}: ${r['match_source']}',
      if (((r['min_company_size'] as num?)?.toInt() ?? 0) > 0)
        '${t.crmMinSize}: ${r['min_company_size']}',
    ].join(' · ');
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text('${i + 1}'),
        ),
        title: Text(conds.isEmpty ? t.crmAnyLead : conds),
        subtitle: Text('${t.crmAssignTo}: ${_memberName(r['assign_to'])}'),
        trailing: Switch(
          value: r['active'] != false,
          onChanged: (v) async {
            try {
              await CrmAdvApi.of(context)
                  .updateRoutingRule((r['id'] as num).toInt(), {'active': v});
              onChanged();
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(CrmError.from(e).textFor(context))));
              }
            }
          },
        ),
      ),
    );
  }
}

class _RuleSheet extends StatefulWidget {
  final int org;
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> territories;
  const _RuleSheet(
      {required this.org, required this.members, required this.territories});
  @override
  State<_RuleSheet> createState() => _RuleSheetState();
}

class _RuleSheetState extends State<_RuleSheet> {
  String? _industry;
  String? _source;
  int? _assignTo;
  int? _territory;
  final _minSize = TextEditingController();
  bool _saving = false;
  String? _err;

  static const _industries = ['rmg', 'pharma', 'retail', 'other'];
  static const _sources = ['whatsapp', 'messenger', 'linkedin', 'email', 'manual'];

  @override
  void dispose() {
    _minSize.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _err = null;
    });
    try {
      await CrmAdvApi.of(context).saveRoutingRule({
        'org': widget.org,
        if (_industry != null) 'match_industry': _industry,
        if (_source != null) 'match_source': _source,
        'min_company_size': int.tryParse(_minSize.text.trim()) ?? 0,
        if (_assignTo != null) 'assign_to': _assignTo,
        if (_territory != null) 'territory': _territory,
        'active': true,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _err = CrmError.from(e).textFor(context));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.md,
          right: Gap.md,
          top: Gap.md,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.md),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.crmAddRule, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<String?>(
          initialValue: _industry,
          decoration: InputDecoration(labelText: t.crmIndustry, border: const OutlineInputBorder()),
          items: [
            DropdownMenuItem<String?>(value: null, child: Text(t.crmAny)),
            for (final c in _industries) DropdownMenuItem(value: c, child: Text(c)),
          ],
          onChanged: (v) => setState(() => _industry = v),
        ),
        const SizedBox(height: Gap.sm),
        DropdownButtonFormField<String?>(
          initialValue: _source,
          decoration: InputDecoration(labelText: t.crmSource, border: const OutlineInputBorder()),
          items: [
            DropdownMenuItem<String?>(value: null, child: Text(t.crmAny)),
            for (final c in _sources) DropdownMenuItem(value: c, child: Text(c)),
          ],
          onChanged: (v) => setState(() => _source = v),
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _minSize,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: t.crmMinSize, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.sm),
        DropdownButtonFormField<int?>(
          initialValue: _assignTo,
          decoration: InputDecoration(labelText: t.crmAssignTo, border: const OutlineInputBorder()),
          items: [
            for (final m in widget.members)
              DropdownMenuItem<int?>(
                  value: (m['id'] as num).toInt(),
                  child: Text(m['user_name']?.toString() ?? '')),
          ],
          onChanged: (v) => setState(() => _assignTo = v),
        ),
        if (widget.territories.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          DropdownButtonFormField<int?>(
            initialValue: _territory,
            decoration: InputDecoration(labelText: t.crmTerritory, border: const OutlineInputBorder()),
            items: [
              DropdownMenuItem<int?>(value: null, child: Text(t.crmAny)),
              for (final tr in widget.territories)
                DropdownMenuItem<int?>(
                    value: (tr['id'] as num).toInt(),
                    child: Text(tr['name']?.toString() ?? '')),
            ],
            onChanged: (v) => setState(() => _territory = v),
          ),
        ],
        if (_err != null) ...[
          const SizedBox(height: Gap.sm),
          Text(_err!, style: const TextStyle(color: Brand.danger)),
        ],
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
              child: OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.pop(context, false),
                  child: Text(t.cancel))),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(t.save))),
        ]),
      ]),
    );
  }
}
