import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import '../../plans_v2/upgrade_sheet.dart';
import '../../plans_v2/plans_v2.dart';
import '../../state.dart';
import 'package:provider/provider.dart';
import 'crm_advanced_api.dart';
import '../../widgets/crm_rule_builder.dart';

/// OWNER AUTOMATION RULES (CRM spec #11). The owner builds rules like
/// "proposal sent + no reply in 3 days → create a follow-up task". Rules are
/// OWNER-DEFINED only — nothing runs that the owner did not create, and no rule
/// auto-sends to a customer (actions are create-task / draft / notify only).
/// Evaluated server-side by logic_automation.due_actions.
class CrmAutomationScreen extends StatefulWidget {
  final int org;
  const CrmAutomationScreen({super.key, required this.org});
  @override
  State<CrmAutomationScreen> createState() => _CrmAutomationScreenState();
}

class _CrmAutomationScreenState extends State<CrmAutomationScreen> {
  List<Map<String, dynamic>> _rules = [];
  bool _loading = true;
  CrmError? _error;
  PlansV2State _v2 = PlansV2State.off;

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
      _rules = await CrmAdvApi.of(context).automationRules(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) {
      _v2 = await loadPlansV2(context.read<AppState>().api, org: widget.org);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit(Map<String, dynamic>? existing) async {
    // plans-v2: automation is a Business feature (org owner's plan). The
    // server refuses too; this says why before the form is filled in.
    if (existing == null) {
      final lock = _v2.crmLock('automation');
      if (lock != null) {
        await UpgradeSheet.show(context, lock);
        return;
      }
    }
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CrmRuleBuilder(org: widget.org, existing: existing),
    );
    if (saved == true) _load();
  }

  Future<void> _toggle(Map<String, dynamic> r, bool v) async {
    try {
      await CrmAdvApi.of(context)
          .updateAutomationRule((r['id'] as num).toInt(), {'active': v});
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(CrmError.from(e).textFor(context))));
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.crmDeleteRule),
        content: Text(t.crmDeleteRuleConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CrmAdvApi.of(context).deleteAutomationRule((r['id'] as num).toInt());
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(CrmError.from(e).textFor(context))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.crmAutomation)),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('crm-new-rule'),
        onPressed: () => _edit(null),
        icon: Icon(_v2.crmLock('automation') != null ? Icons.lock_rounded : Icons.add_rounded),
        label: Text(t.crmNewRule),
      ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    if (_rules.isEmpty) {
      return CrmStateView.empty(
        icon: Icons.bolt_rounded,
        title: t.crmNoRules,
        message: t.crmNoRulesHint,
        action: FilledButton.tonalIcon(
            onPressed: () => _edit(null),
            icon: const Icon(Icons.add_rounded),
            label: Text(t.crmNewRule)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          NeedsKeyBanner(t.crmAutomationNote, icon: Icons.verified_user_rounded),
          const SizedBox(height: Gap.sm),
          for (final r in _rules) _ruleCard(t, r),
        ],
      ),
    );
  }

  Widget _ruleCard(AppLocalizations t, Map<String, dynamic> r) {
    final scheme = Theme.of(context).colorScheme;
    final active = r['active'] != false;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.bolt_rounded,
                color: active ? AssistoTokens.of(context).warning : scheme.onSurfaceVariant, size: 20),
            const SizedBox(width: Gap.xs),
            Expanded(
                child: Text(r['name']?.toString() ?? t.crmRule,
                    style: const TextStyle(fontWeight: FontWeight.w800))),
            Switch(value: active, onChanged: (v) => _toggle(r, v)),
          ]),
          const SizedBox(height: Gap.xs),
          _sentence(t, r),
          const SizedBox(height: Gap.xs),
          Row(children: [
            TextButton.icon(
                onPressed: () => _edit(r),
                icon: const Icon(Icons.edit_rounded, size: 16),
                label: Text(t.edit)),
            TextButton.icon(
                onPressed: () => _delete(r),
                icon: Icon(Icons.delete_outline_rounded, size: 16, color: Theme.of(context).colorScheme.error),
                label: Text(t.delete, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ]),
        ]),
      ),
    );
  }

  /// Render the rule as a plain-language "WHEN ... [IF ...] THEN ..." sentence.
  Widget _sentence(AppLocalizations t, Map<String, dynamic> r) {
    final scheme = Theme.of(context).colorScheme;
    final trigger = r['trigger']?.toString() ?? '';
    final delay = (r['delay_days'] as num?)?.toInt() ?? 0;
    final action = (r['action'] as Map?)?.cast<String, dynamic>() ?? {};
    final cond = (r['condition'] as Map?)?.cast<String, dynamic>() ?? {};
    final parts = <String>[
      '${t.crmWhen} ${CrmRuleBuilder.triggerLabel(t, trigger)}',
      if (cond['no_reply'] == true) t.crmAndNoReply,
      if (delay > 0) '${t.crmAfter} $delay${t.crmDaysShort}',
      '${t.crmThen} ${CrmRuleBuilder.actionLabel(t, action['kind']?.toString())}',
    ];
    return Text(parts.join(' · '),
        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4));
  }
}
