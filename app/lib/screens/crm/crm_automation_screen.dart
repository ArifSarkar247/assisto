import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import '../../theme.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import '../../plans_v2/upgrade_sheet.dart';
import '../../plans_v2/plans_v2.dart';
import '../../state.dart';
import 'package:provider/provider.dart';
import 'crm_advanced_api.dart';
import '../../widgets/crm_rule_builder.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../../feature_flags.dart' show FeatureFlags;
import '../retention/retention_screen.dart';

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
    final saved = await showAppSheet<bool>(
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
        scrollable: true, // insets: 200% text / keyboard
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
      // empty: the state's own big button is the one action (no second FAB)
      floatingActionButton: !_loading && _error == null && _rules.isEmpty
          ? null
          : FloatingActionButton.extended(
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
    final link = _customerMsgsLink(t);
    if (_rules.isEmpty && link != null) {
      return ListView(padding: const EdgeInsets.all(Gap.md), children: [
        link,
        const SizedBox(height: Gap.md),
        DsEmptyState(
          icon: Icons.bolt_rounded,
          title: t.crmNoRules,
          benefit: t.crmNoRulesHint,
          actionKey: const Key('crm-new-rule'),
          actionLabel: t.crmNewRule,
          onAction: () => _edit(null),
        ),
      ]);
    }
    if (_rules.isEmpty) {
      return ListView(padding: const EdgeInsets.all(Gap.md), children: [
        DsEmptyState(
          icon: Icons.bolt_rounded,
          title: t.crmNoRules,
          benefit: t.crmNoRulesHint,
          actionKey: const Key('crm-new-rule'),
          actionLabel: t.crmNewRule,
          onAction: () => _edit(null),
        ),
      ]);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          // the rules first (what runs), the customer-messages link and the
          // safety note after
          for (final r in _rules)
            Padding(padding: const EdgeInsets.only(bottom: Gap.sm), child: _ruleCard(t, r)),
          if (link != null) link,
          NeedsKeyBanner(t.crmAutomationNote, icon: Icons.verified_user_rounded),
        ],
      ),
    );
  }

  /// crmauto: the customer-facing automations (reorder, after-delivery
  /// feedback, quote follow-up, win-back...) live in retention automation —
  /// one tap from here, shown only when that feature is on for this user.
  Widget? _customerMsgsLink(AppLocalizations t) {
    if (!FeatureFlags.instance.isOn('retention_auto')) return null;
    final ds = Theme.of(context).colorScheme.ds;
    return DsCard(
      padding: EdgeInsets.zero,
      child: DsListRow(
        key: const Key('crm-customer-msgs'),
        leading: DsAvatar(size: 40, child: Icon(Icons.autorenew_rounded, size: 20, color: ds.primaryInk)),
        title: t.crmAutoCustomerMsgsTitle,
        subtitle: t.crmAutoCustomerMsgsBody,
        trailing: Icon(Icons.chevron_right_rounded, color: ds.muted),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RetentionScreen())),
      ),
    );
  }

  Widget _ruleCard(AppLocalizations t, Map<String, dynamic> r) {
    final scheme = Theme.of(context).colorScheme;
    final active = r['active'] != false;
    return DsCard(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            DsAvatar(
                size: 36,
                color: active ? AssistoTokens.of(context).warning : scheme.ds.muted,
                child: Icon(Icons.bolt_rounded, size: 18,
                    color: active
                        ? Brand.onTint(context, AssistoTokens.of(context).warning)
                        : scheme.ds.muted)),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(r['name']?.toString() ?? t.crmRule,
                    style: AType.bodyLarge.copyWith(color: scheme.ds.text, fontWeight: FontWeight.w800))),
            Switch(value: active, onChanged: (v) => _toggle(r, v)),
          ]),
          const SizedBox(height: Gap.xs),
          _sentence(t, r),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.xs, children: [
            TextButton.icon(
                onPressed: () => _edit(r),
                icon: const Icon(Icons.edit_rounded, size: 16),
                label: Text(t.edit)),
            TextButton.icon(
                onPressed: () => _delete(r),
                icon: Icon(Icons.delete_outline_rounded, size: 16, color: scheme.ds.dangerInk),
                label: Text(t.delete, style: AType.bodyMedium.copyWith(color: scheme.ds.dangerInk))),
          ]),
        ]),
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
      if (delay > 0)
        '${t.crmAfter} ${localDigits('$delay', Localizations.localeOf(context).languageCode)}${t.crmDaysShort}',
      '${t.crmThen} ${CrmRuleBuilder.actionLabel(t, action['kind']?.toString())}',
    ];
    return Text(parts.join(' · '),
        style: AType.bodyMedium.copyWith(color: scheme.ds.muted, height: 1.4));
  }
}
