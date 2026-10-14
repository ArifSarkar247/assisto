import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'studio_engine.dart';

/// Agent Studio presentation atoms + the token→label localisation.
/// Zero Bangla literals: every human string is an l10n getter; engine tokens
/// (type names, ops, event ids) map to getters here.

/// -------- token → localised label helpers (bilingual via l10n)

String triggerTypeLabel(AppLocalizations t, String type) {
  switch (type) {
    case 'schedule':
      return t.studioTrigSchedule;
    case 'event':
      return t.studioTrigEvent;
    case 'keyword':
      return t.studioTrigKeyword;
    case 'incoming':
      return t.studioTrigIncoming;
  }
  return type;
}

String actionTypeLabel(AppLocalizations t, String type) {
  switch (type) {
    case 'remind':
      return t.studioActRemind;
    case 'message':
      return t.studioActMessage;
    case 'log':
      return t.studioActLog;
    case 'summarize':
      return t.studioActSummarize;
    case 'tool':
      return t.studioActTool;
  }
  return type;
}

String opLabel(AppLocalizations t, String op) {
  switch (op) {
    case '==':
      return t.studioOpEq;
    case '!=':
      return t.studioOpNe;
    case '>':
      return '>';
    case '>=':
      return '≥';
    case '<':
      return '<';
    case '<=':
      return '≤';
    case 'contains':
      return t.studioOpContains;
  }
  return op;
}

String eventLabel(AppLocalizations t, String event) {
  switch (event) {
    case 'lead_created':
      return t.studioEvtLeadCreated;
    case 'birthday_today':
      return t.studioEvtBirthday;
    case 'bill_due':
      return t.studioEvtBillDue;
  }
  return event.isEmpty ? t.studioEvtAny : event;
}

/// Template name/action-text seeds carry an l10n KEY string; resolve it.
String resolveSeed(AppLocalizations t, String key) {
  switch (key) {
    case 'studioTplBill':
      return t.studioTplBill;
    case 'studioTplSummary':
      return t.studioTplSummary;
    case 'studioTplFollowup':
      return t.studioTplFollowup;
    case 'studioTplBirthday':
      return t.studioTplBirthday;
    case 'studioTplBillText':
      return t.studioTplBillText;
    case 'studioTplFollowupText':
      return t.studioTplFollowupText;
    case 'studioTplBirthdayText':
      return t.studioTplBirthdayText;
  }
  return key;
}

String triggerPhrase(AppLocalizations t, Trigger tr) {
  switch (tr.type) {
    case 'schedule':
      final dom = tr.dayOfMonth;
      if (dom != null) {
        return t.studioWhenMonthly(dom.toString(), tr.at);
      }
      if (tr.days.length == 7) return t.studioWhenDaily(tr.at);
      return t.studioWhenOnDays(tr.at);
    case 'event':
      return eventLabel(t, tr.event);
    case 'keyword':
      return t.studioWhenKeyword(tr.keywords.join(', '));
    case 'incoming':
      return t.studioWhenIncoming(tr.from);
  }
  return tr.type;
}

/// -------- the readable WHEN … IF … THEN reader

class WhenIfThenCard extends StatelessWidget {
  final Automation a;
  const WhenIfThenCard({super.key, required this.a});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget clause(String label, Color tint, List<Widget> rows) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    color: tint,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    letterSpacing: 0.4)),
            const SizedBox(height: Gap.xs),
            ...rows,
            const SizedBox(height: Gap.md),
          ],
        );
    Widget line(String s) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 6, right: Gap.sm),
              child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant, shape: BoxShape.circle)),
            ),
            Expanded(
                child: Text(s,
                    style: TextStyle(color: scheme.onSurface, height: 1.4))),
          ]),
        );

    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        clause(t.studioWhen, scheme.primary,
            [for (final tr in a.triggers) line(triggerPhrase(t, tr))]),
        if (a.conditions.isNotEmpty)
          clause(
              a.match == 'any' ? t.studioIfAny : t.studioIfAll,
              Brand.warning,
              [
                for (final c in a.conditions)
                  line('${c.field} ${opLabel(t, c.op)} ${c.value}')
              ]),
        clause(t.studioThen, scheme.tertiary, [
          for (final ac in a.actions)
            line(ac.aiRequired
                ? '${actionTypeLabel(t, ac.type)}  ·  ${t.studioAiTag}'
                : actionTypeLabel(t, ac.type))
        ]),
      ]),
    );
  }
}

/// -------- automation list tile (enable toggle, status, needs-ai dot)

class AutomationTile extends StatelessWidget {
  final Automation a;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;
  const AutomationTile(
      {super.key,
      required this.a,
      required this.onToggle,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final summary = a.triggers.isEmpty
        ? ''
        : triggerPhrase(t, a.triggers.first);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Gap.lg, vertical: Gap.md),
          child: Row(children: [
            Container(
              height: 42,
              width: 42,
              decoration: BoxDecoration(
                gradient: a.enabled ? Brand.gradient : null,
                color: a.enabled ? null : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Icon(Icons.bolt_rounded,
                  color: a.enabled ? Colors.white : scheme.onSurfaceVariant),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12.5,
                            height: 1.3)),
                    if (a.needsAi) ...[
                      const SizedBox(height: Gap.xs),
                      _tag(context, t.studioAiTag, scheme.tertiary),
                    ],
                  ]),
            ),
            const SizedBox(width: Gap.sm),
            Switch(
                value: a.enabled,
                onChanged: onToggle),
          ]),
        ),
      ),
    );
  }

  Widget _tag(BuildContext c, String s, Color tint) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
        decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(s,
            style: TextStyle(
                color: tint, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}

/// -------- template gallery card

class TemplateCard extends StatelessWidget {
  final Automation tpl;
  final IconData icon;
  final VoidCallback onUse;
  const TemplateCard(
      {super.key, required this.tpl, required this.icon, required this.onUse});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              height: 40,
              width: 40,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Icon(icon, color: scheme.primary),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
                child: Text(resolveSeed(t, tpl.name),
                    style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: Gap.md),
          Text(tpl.triggers.isEmpty ? '' : triggerPhrase(t, tpl.triggers.first),
              style: TextStyle(
                  color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.3)),
          const SizedBox(height: Gap.md),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: onUse,
              icon: const Icon(Icons.add, size: 18),
              label: Text(t.studioUseTemplate),
            ),
          ),
        ]),
      ),
    );
  }
}

/// -------- run-history tile

class RunHistoryTile extends StatelessWidget {
  final RunEntry e;
  const RunHistoryTile({super.key, required this.e});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final when = DateTime.tryParse(e.at);
    final whenStr = when == null
        ? e.at
        : '${when.year}-${_2(when.month)}-${_2(when.day)} '
            '${_2(when.hour)}:${_2(when.minute)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(e.manual ? Icons.play_circle_outline : Icons.schedule,
            size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(whenStr,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 2),
            Text(
                '${e.manual ? t.studioRunManual : t.studioRunScheduled}'
                '${e.usedAiMock ? '  ·  ${t.studioAiMockTag}' : ''}',
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }

  String _2(int n) => n < 10 ? '0$n' : '$n';
}

/// -------- honest AI banner (key-gated, mocked preview)

class AiMockBanner extends StatelessWidget {
  const AiMockBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.auto_awesome,
            size: 18, color: scheme.onTertiaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(t.studioAiMockNote,
              style: TextStyle(
                  color: scheme.onTertiaryContainer, fontSize: 12.5, height: 1.4)),
        ),
      ]),
    );
  }
}
