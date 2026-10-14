import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../screens/crm/crm_common.dart';
import '../screens/crm/crm_advanced_api.dart';

/// Builder sheet for ONE owner automation rule (CRM spec #11), in the shape
/// logic_automation expects: {trigger, condition, delay_days, action}. The UI
/// reads as a sentence: WHEN <trigger> [+ no reply] [after N days] THEN
/// <action>. Only owner-chosen triggers/actions exist; nothing auto-sends.
class CrmRuleBuilder extends StatefulWidget {
  final int org;
  final Map<String, dynamic>? existing;
  const CrmRuleBuilder({super.key, required this.org, this.existing});

  // Trigger / action codes mirror logic_automation.KNOWN_TRIGGERS / _ACTIONS.
  static const triggers = [
    'lead_created',
    'proposal_sent',
    'deal_stage_changed',
    'deal_won',
    'deal_lost',
    'no_activity',
    'task_overdue',
  ];
  static const actions = ['create_task', 'create_followup', 'notify', 'draft_message'];

  static String triggerLabel(AppLocalizations t, String? code) {
    switch (code) {
      case 'lead_created':
        return t.crmTrigLeadCreated;
      case 'proposal_sent':
        return t.crmTrigProposalSent;
      case 'deal_stage_changed':
        return t.crmTrigStageChanged;
      case 'deal_won':
        return t.crmTrigDealWon;
      case 'deal_lost':
        return t.crmTrigDealLost;
      case 'no_activity':
        return t.crmTrigNoActivity;
      case 'task_overdue':
        return t.crmTrigTaskOverdue;
      default:
        return code ?? '';
    }
  }

  static String actionLabel(AppLocalizations t, String? code) {
    switch (code) {
      case 'create_task':
        return t.crmActCreateTask;
      case 'create_followup':
        return t.crmActCreateFollowup;
      case 'notify':
        return t.crmActNotify;
      case 'draft_message':
        return t.crmActDraftMessage;
      default:
        return code ?? '';
    }
  }

  @override
  State<CrmRuleBuilder> createState() => _CrmRuleBuilderState();
}

class _CrmRuleBuilderState extends State<CrmRuleBuilder> {
  late final TextEditingController _name;
  late final TextEditingController _subject;
  late final TextEditingController _delay;
  late String _trigger;
  late String _action;
  bool _noReply = false;
  bool _saving = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?['name']?.toString() ?? '');
    _trigger = e?['trigger']?.toString() ?? CrmRuleBuilder.triggers.first;
    _delay = TextEditingController(
        text: e?['delay_days'] != null ? '${e!['delay_days']}' : '0');
    final cond = (e?['condition'] as Map?)?.cast<String, dynamic>() ?? {};
    _noReply = cond['no_reply'] == true;
    final action = (e?['action'] as Map?)?.cast<String, dynamic>() ?? {};
    _action = action['kind']?.toString() ?? CrmRuleBuilder.actions.first;
    _subject = TextEditingController(text: action['subject']?.toString() ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _subject.dispose();
    _delay.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _err = null;
    });
    final body = {
      'org': widget.org,
      'name': _name.text.trim(),
      'trigger': _trigger,
      'condition': {if (_noReply) 'no_reply': true},
      'delay_days': int.tryParse(_delay.text.trim()) ?? 0,
      'action': {'kind': _action, 'subject': _subject.text.trim()},
      'active': true,
    };
    try {
      final api = CrmAdvApi.of(context);
      final id = (widget.existing?['id'] as num?)?.toInt();
      if (id != null) {
        await api.updateAutomationRule(id, body);
      } else {
        await api.saveAutomationRule(body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _err = CrmError.from(e).message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.md,
          right: Gap.md,
          top: Gap.md,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.md),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.existing == null ? t.crmNewRule : t.crmEditRule,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _name,
            decoration: InputDecoration(
                labelText: t.crmRuleName, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          // WHEN
          _label(t.crmWhen),
          DropdownButtonFormField<String>(
            initialValue: _trigger,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: [
              for (final c in CrmRuleBuilder.triggers)
                DropdownMenuItem(value: c, child: Text(CrmRuleBuilder.triggerLabel(t, c))),
            ],
            onChanged: (v) => setState(() => _trigger = v ?? _trigger),
          ),
          // IF (condition)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _noReply,
            onChanged: (v) => setState(() => _noReply = v),
            title: Text(t.crmCondNoReply),
            subtitle: Text(t.crmCondNoReplyHint),
          ),
          // DELAY
          TextField(
            controller: _delay,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: t.crmDelayDays,
                helperText: t.crmDelayDaysHint,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          // THEN (action)
          _label(t.crmThen),
          DropdownButtonFormField<String>(
            initialValue: _action,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: [
              for (final c in CrmRuleBuilder.actions)
                DropdownMenuItem(value: c, child: Text(CrmRuleBuilder.actionLabel(t, c))),
            ],
            onChanged: (v) => setState(() => _action = v ?? _action),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _subject,
            decoration: InputDecoration(
                labelText: t.crmActionSubject,
                helperText: t.crmActionSubjectHint,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          Container(
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(children: [
              Icon(Icons.info_outline, size: 16, color: scheme.onSecondaryContainer),
              const SizedBox(width: Gap.xs),
              Expanded(
                  child: Text(t.crmNoAutoSendNote,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSecondaryContainer))),
            ]),
          ),
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
      ),
    );
  }

  Widget _label(String s) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(s,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        ),
      );
}
