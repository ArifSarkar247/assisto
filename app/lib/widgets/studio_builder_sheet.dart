import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'studio_engine.dart';
import 'studio_cards.dart';

/// The WHEN … IF … THEN builder sheet — create or edit one automation.
/// A guided, no-code form (benchmark: Shortcuts / Zapier, kept simple for
/// ordinary users). Returns the edited [Automation] on save, null on cancel.
class StudioBuilderSheet extends StatefulWidget {
  final Automation initial;
  const StudioBuilderSheet({super.key, required this.initial});

  static Future<Automation?> show(BuildContext context, Automation initial) {
    return showModalBottomSheet<Automation>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => StudioBuilderSheet(initial: initial),
    );
  }

  @override
  State<StudioBuilderSheet> createState() => _StudioBuilderSheetState();
}

class _StudioBuilderSheetState extends State<StudioBuilderSheet> {
  late Automation a;
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    a = widget.initial.copy();
    _name = TextEditingController(text: a.name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    a.name = _name.text.trim();
    final problems = StudioEngine.validate(a);
    if (problems.isNotEmpty) {
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_problemText(t, problems.first))));
      return;
    }
    Navigator.of(context).pop(a);
  }

  String _problemText(AppLocalizations t, String key) {
    switch (key) {
      case 'name_required':
        return t.studioErrName;
      case 'trigger_required':
        return t.studioErrTrigger;
      case 'action_required':
        return t.studioErrAction;
      case 'bad_time':
        return t.studioErrTime;
      case 'keyword_required':
        return t.studioErrKeyword;
      case 'event_required':
        return t.studioErrEvent;
      case 'source_required':
        return t.studioErrSource;
    }
    return t.studioErrTrigger;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        builder: (_, controller) => Column(children: [
          const SizedBox(height: Gap.sm),
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Row(children: [
              Expanded(
                child: Text(t.studioBuilderTitle,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
              FilledButton(onPressed: _save, child: Text(t.save)),
            ]),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
              children: [
                TextField(
                  controller: _name,
                  decoration: InputDecoration(labelText: t.studioName),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: Gap.lg),
                _section(t.studioWhen, scheme.primary, Icons.bolt_rounded,
                    onAdd: () => setState(() => a.triggers.add(Trigger()))),
                for (int i = 0; i < a.triggers.length; i++)
                  _TriggerEditor(
                    key: ValueKey('trig$i'),
                    trigger: a.triggers[i],
                    onChanged: () => setState(() {}),
                    onRemove: a.triggers.length > 1
                        ? () => setState(() => a.triggers.removeAt(i))
                        : null,
                  ),
                const SizedBox(height: Gap.lg),
                _section(
                    a.match == 'any' ? t.studioIfAny : t.studioIfAll,
                    Brand.warning,
                    Icons.filter_alt_rounded,
                    trailing: a.conditions.length > 1
                        ? _matchToggle(t)
                        : null,
                    onAdd: () =>
                        setState(() => a.conditions.add(Condition()))),
                if (a.conditions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.sm),
                    child: Text(t.studioIfOptional,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 12.5)),
                  ),
                for (int i = 0; i < a.conditions.length; i++)
                  _ConditionEditor(
                    key: ValueKey('cond$i'),
                    cond: a.conditions[i],
                    onChanged: () => setState(() {}),
                    onRemove: () =>
                        setState(() => a.conditions.removeAt(i)),
                  ),
                const SizedBox(height: Gap.lg),
                _section(t.studioThen, scheme.tertiary, Icons.play_arrow_rounded,
                    onAdd: () =>
                        setState(() => a.actions.add(StudioAction()))),
                for (int i = 0; i < a.actions.length; i++)
                  _ActionEditor(
                    key: ValueKey('act$i'),
                    action: a.actions[i],
                    onChanged: () => setState(() {}),
                    onRemove: a.actions.length > 1
                        ? () => setState(() => a.actions.removeAt(i))
                        : null,
                  ),
                if (a.needsAi) ...[
                  const SizedBox(height: Gap.md),
                  const AiMockBanner(),
                ],
                const SizedBox(height: Gap.xl),
                Text(t.studioPreview,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5)),
                const SizedBox(height: Gap.sm),
                WhenIfThenCard(a: a),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _matchToggle(AppLocalizations t) {
    return TextButton(
      onPressed: () =>
          setState(() => a.match = a.match == 'all' ? 'any' : 'all'),
      child: Text(a.match == 'all' ? t.studioMatchAll : t.studioMatchAny),
    );
  }

  Widget _section(String label, Color tint, IconData icon,
      {required VoidCallback onAdd, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(children: [
        Icon(icon, size: 18, color: tint),
        const SizedBox(width: Gap.sm),
        Text(label,
            style: TextStyle(
                color: tint,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
                fontSize: 13)),
        const Spacer(),
        if (trailing != null) trailing,
        IconButton(
          onPressed: onAdd,
          icon: const Icon(Icons.add_circle_outline_rounded),
          tooltip: AppLocalizations.of(context).add,
        ),
      ]),
    );
  }
}

/// -------------------------------------------------------- trigger editor

class _TriggerEditor extends StatelessWidget {
  final Trigger trigger;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  const _TriggerEditor(
      {super.key,
      required this.trigger,
      required this.onChanged,
      this.onRemove});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _rowCard(
      context,
      onRemove: onRemove,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: Gap.sm, children: [
          for (final ty in triggerTypes)
            ChoiceChip(
              label: Text(triggerTypeLabel(t, ty)),
              selected: trigger.type == ty,
              onSelected: (_) {
                trigger.type = ty;
                onChanged();
              },
            ),
        ]),
        const SizedBox(height: Gap.sm),
        ..._fields(context, t),
      ]),
    );
  }

  List<Widget> _fields(BuildContext context, AppLocalizations t) {
    switch (trigger.type) {
      case 'schedule':
        return [
          Row(children: [
            Expanded(
              child: InkWell(
                onTap: () async {
                  final parts = trigger.at.split(':');
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                        hour: int.tryParse(parts.first) ?? 9,
                        minute: parts.length > 1
                            ? int.tryParse(parts[1]) ?? 0
                            : 0),
                  );
                  if (picked != null) {
                    trigger.at =
                        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
                    onChanged();
                  }
                },
                child: InputDecorator(
                  decoration: InputDecoration(labelText: t.studioFieldTime),
                  child: Text(trigger.at),
                ),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              // db1: transparent Material so the tile's ripple shows on the
              // tinted card (Flutter flagged invisible ink in the tap sweep).
              child: Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(t.studioFieldMonthly, style: const TextStyle(fontSize: 13)),
                  value: trigger.dayOfMonth != null,
                  onChanged: (v) {
                    trigger.dayOfMonth = v ? 1 : null;
                    if (v) trigger.days = [1, 2, 3, 4, 5, 6, 7];
                    onChanged();
                  },
                ),
              ),
            ),
          ]),
          if (trigger.dayOfMonth != null)
            TextFormField(
              initialValue: trigger.dayOfMonth.toString(),
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: t.studioFieldDayOfMonth),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 1 && n <= 31) trigger.dayOfMonth = n;
              },
            )
          else
            _WeekdayPicker(trigger: trigger, onChanged: onChanged),
        ];
      case 'event':
        return [
          DropdownButtonFormField<String>(
            initialValue: trigger.event.isEmpty ? 'lead_created' : trigger.event,
            decoration: InputDecoration(labelText: t.studioFieldEvent),
            items: [
              for (final e in ['lead_created', 'birthday_today', 'bill_due'])
                DropdownMenuItem(value: e, child: Text(eventLabel(t, e))),
            ],
            onChanged: (v) {
              trigger.event = v ?? 'lead_created';
              onChanged();
            },
          ),
        ];
      case 'keyword':
        return [
          TextFormField(
            initialValue: trigger.keywords.join(', '),
            decoration: InputDecoration(
                labelText: t.studioFieldKeywords,
                helperText: t.studioFieldKeywordsHint),
            onChanged: (v) => trigger.keywords = v
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(),
          ),
        ];
      case 'incoming':
        return [
          TextFormField(
            initialValue: trigger.from,
            decoration: InputDecoration(
                labelText: t.studioFieldIncomingFrom,
                helperText: t.studioFieldIncomingHint),
            onChanged: (v) => trigger.from = v.trim(),
          ),
        ];
    }
    return [];
  }
}

class _WeekdayPicker extends StatefulWidget {
  final Trigger trigger;
  final VoidCallback onChanged;
  const _WeekdayPicker({required this.trigger, required this.onChanged});
  @override
  State<_WeekdayPicker> createState() => _WeekdayPickerState();
}

class _WeekdayPickerState extends State<_WeekdayPicker> {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final labels = [
      t.studioDayMon,
      t.studioDayTue,
      t.studioDayWed,
      t.studioDayThu,
      t.studioDayFri,
      t.studioDaySat,
      t.studioDaySun,
    ];
    return Wrap(spacing: Gap.xs, children: [
      for (int d = 1; d <= 7; d++)
        FilterChip(
          label: Text(labels[d - 1]),
          selected: widget.trigger.days.contains(d),
          onSelected: (sel) {
            setState(() {
              if (sel) {
                if (!widget.trigger.days.contains(d)) widget.trigger.days.add(d);
              } else if (widget.trigger.days.length > 1) {
                widget.trigger.days.remove(d);
              }
              widget.trigger.days.sort();
            });
            widget.onChanged();
          },
        ),
    ]);
  }
}

/// -------------------------------------------------------- condition editor

class _ConditionEditor extends StatelessWidget {
  final Condition cond;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  const _ConditionEditor(
      {super.key,
      required this.cond,
      required this.onChanged,
      required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _rowCard(
      context,
      onRemove: onRemove,
      child: Row(children: [
        Expanded(
          flex: 3,
          child: TextFormField(
            initialValue: cond.field,
            decoration: InputDecoration(labelText: t.studioCondField),
            onChanged: (v) => cond.field = v.trim(),
          ),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            initialValue: cond.op,
            decoration: InputDecoration(labelText: t.studioCondOp),
            items: [
              for (final op in conditionOps)
                DropdownMenuItem(value: op, child: Text(opLabel(t, op))),
            ],
            onChanged: (v) {
              cond.op = v ?? '==';
              onChanged();
            },
          ),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          flex: 3,
          child: TextFormField(
            initialValue: cond.value,
            decoration: InputDecoration(labelText: t.studioCondValue),
            onChanged: (v) => cond.value = v.trim(),
          ),
        ),
      ]),
    );
  }
}

/// -------------------------------------------------------- action editor

class _ActionEditor extends StatelessWidget {
  final StudioAction action;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  const _ActionEditor(
      {super.key,
      required this.action,
      required this.onChanged,
      this.onRemove});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _rowCard(
      context,
      onRemove: onRemove,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: Gap.sm, children: [
          for (final ty in actionTypes)
            ChoiceChip(
              label: Text(actionTypeLabel(t, ty)),
              selected: action.type == ty,
              onSelected: (_) {
                action.type = ty;
                onChanged();
              },
            ),
        ]),
        const SizedBox(height: Gap.sm),
        if (action.type == 'remind' ||
            action.type == 'message' ||
            action.type == 'log')
          TextFormField(
            initialValue: action.text,
            decoration: InputDecoration(labelText: t.studioActText),
            onChanged: (v) => action.text = v,
          ),
        if (action.type == 'tool')
          TextFormField(
            initialValue: action.tool,
            decoration: InputDecoration(
                labelText: t.studioActTool, helperText: t.studioActToolHint),
            onChanged: (v) => action.tool = v.trim(),
          ),
        if (action.type == 'summarize')
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(t.studioAiTag,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.tertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }
}

/// shared card chrome for an editable row with a remove button
Widget _rowCard(BuildContext context,
    {required Widget child, VoidCallback? onRemove}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    margin: const EdgeInsets.only(bottom: Gap.sm),
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.xs, Gap.md),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Radii.md),
      border: Border.all(color: scheme.outlineVariant),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: child),
      if (onRemove != null)
        IconButton(
          onPressed: onRemove,
          icon: Icon(Icons.close_rounded, size: 18, color: scheme.onSurfaceVariant),
          tooltip: AppLocalizations.of(context).delete,
        ),
    ]),
  );
}
