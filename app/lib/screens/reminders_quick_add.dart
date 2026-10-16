import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../notifications.dart';
import '../widgets/reminders_nlp.dart';
import 'reminders_screen.dart' show recurrenceLabel;

/// A single-line natural-language quick-add with a live parsed preview.
/// Typing "every friday 8am jumma" shows a preview chip row (time, recurrence)
/// and the cleaned title, then one tap adds the reminder.
class QuickAddBar extends StatefulWidget {
  final Future<void> Function(
      ParsedReminder parsed, String title, Map<String, dynamic>? link) onCommit;
  const QuickAddBar({super.key, required this.onCommit});

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends State<QuickAddBar> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  ParsedReminder? _preview;
  Map<String, dynamic>? _link;

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    if (v.trim().isEmpty) {
      setState(() => _preview = null);
      return;
    }
    setState(() => _preview = parseReminder(v));
  }

  Future<void> _commit() async {
    final text = _c.text.trim();
    if (text.isEmpty) return;
    final p = _preview ?? parseReminder(text);
    final title = p.cleanTitle.isEmpty ? text : p.cleanTitle;
    await widget.onCommit(p, title, _link);
    _c.clear();
    setState(() {
      _preview = null;
      _link = null;
    });
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = _preview;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: Gap.xs),
              Icon(Icons.auto_awesome, size: 20, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: TextField(
                  controller: _c,
                  focusNode: _focus,
                  textInputAction: TextInputAction.done,
                  onChanged: _onChanged,
                  onSubmitted: (_) => _commit(),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    hintText: t.remQuickAddHint,
                  ),
                ),
              ),
              if (_c.text.isNotEmpty)
                FilledButton(
                  onPressed: _commit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  ),
                  child: Text(t.add),
                ),
            ],
          ),
          if (p != null && _c.text.trim().isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _Preview(parsed: p, link: _link, onEditLink: _pickLink),
          ],
        ],
      ),
    );
  }

  Future<void> _pickLink() async {
    final l = await pickLink(context);
    if (l != null) setState(() => _link = l);
  }
}

class _Preview extends StatelessWidget {
  final ParsedReminder parsed;
  final Map<String, dynamic>? link;
  final VoidCallback onEditLink;
  const _Preview(
      {required this.parsed, required this.link, required this.onEditLink});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final chips = <Widget>[];
    if (parsed.dateTime != null) {
      final dt = parsed.dateTime!;
      final label = parsed.dateOnly
          ? DateFormat('d MMM').format(dt)
          : DateFormat('d MMM, h:mm a').format(dt);
      chips.add(_chip(Icons.schedule, label, scheme.primary));
    }
    if (parsed.recurrence != null) {
      chips.add(_chip(
          Icons.repeat, recurrenceLabel(t, parsed.recurrence!), Brand.purple));
    }
    if (link != null) {
      chips.add(_chip(Icons.link, (link!['label'] ?? '').toString(), Brand.blue));
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!parsed.hasSchedule)
            Padding(
              padding: const EdgeInsets.only(left: Gap.xs, bottom: Gap.xs),
              child: Text(t.remNoTimeDetected,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...chips,
              ActionChip(
                avatar: const Icon(Icons.add_link, size: 16),
                label: Text(link == null ? t.remLinkAdd : t.remLinkChange),
                visualDensity: VisualDensity.compact,
                onPressed: onEditLink,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, Color tint) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: tint)),
        ]),
      );
}

// ---------------------------------------------------------------- link picker
/// Pick a linked entity (person / bill / document / event): choose a type, then
/// name it, so a reminder can point at "Mother" or "Electricity bill" with a
/// tappable chip. (The backend keeps the {type,id,label}; id is resolved when
/// the reminder is created from an existing record elsewhere in the app.)
Future<Map<String, dynamic>?> pickLink(BuildContext context) async {
  final t = AppLocalizations.of(context);
  final types = const ['person', 'bill', 'document', 'event'];
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final custom = TextEditingController();
      String type = 'person';
      return StatefulBuilder(builder: (ctx, setS) {
        return Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg,
              Gap.lg + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.remLinkTitle, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.md),
            Wrap(
              spacing: Gap.sm,
              children: [
                for (final ty in types)
                  ChoiceChip(
                    avatar: Icon(_iconFor(ty), size: 16),
                    label: Text(_typeLabel(t, ty)),
                    selected: type == ty,
                    onSelected: (_) => setS(() => type = ty),
                  ),
              ],
            ),
            const SizedBox(height: Gap.md),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: custom,
                  autofocus: true,
                  decoration: InputDecoration(hintText: t.remLinkCustomHint),
                  onSubmitted: (_) {
                    if (custom.text.trim().isEmpty) return;
                    Navigator.pop(ctx,
                        {'type': type, 'id': null, 'label': custom.text.trim()});
                  },
                ),
              ),
              const SizedBox(width: Gap.sm),
              IconButton(
                icon: const Icon(Icons.check),
                onPressed: () {
                  if (custom.text.trim().isEmpty) return;
                  Navigator.pop(ctx,
                      {'type': type, 'id': null, 'label': custom.text.trim()});
                },
              ),
            ]),
          ]),
        );
      });
    },
  );
}

IconData _iconFor(String? type) {
  switch (type) {
    case 'bill':
      return Icons.receipt_long_outlined;
    case 'document':
      return Icons.folder_outlined;
    case 'event':
      return Icons.event_outlined;
    default:
      return Icons.person_outline;
  }
}

String _typeLabel(AppLocalizations t, String? type) {
  switch (type) {
    case 'bill':
      return t.remLinkTypeBill;
    case 'document':
      return t.remLinkTypeDocument;
    case 'event':
      return t.remLinkTypeEvent;
    default:
      return t.remLinkTypePerson;
  }
}

// unit word for the "every N <unit>" interval control.
String _intervalUnit(AppLocalizations t, String freq) {
  switch (freq) {
    case 'daily':
      return t.remUnitDays;
    case 'weekly':
      return t.remUnitWeeks;
    case 'monthly':
      return t.remUnitMonths;
    case 'yearly':
      return t.remUnitYears;
    default:
      return '';
  }
}

// 0=Mon..6=Sun -> locale weekday name (2024-01-01 was a Monday).
String _weekdayLabel(int wd) {
  final ref = DateTime(2024, 1, 1).add(Duration(days: wd));
  return DateFormat('EEEE').format(ref);
}

// ---------------------------------------------------------------- full editor
/// The structured create/edit dialog (recurrence picker, date/time, link).
Future<void> editReminder(BuildContext context,
    {Map<String, dynamic>? item}) async {
  final app = context.read<AppState>();
  final data = (item?['data'] as Map<String, dynamic>?) ?? {};
  final title = TextEditingController(text: data['title'] ?? '');
  final notes = TextEditingController(text: data['notes'] ?? '');
  DateTime? due = data['due_at'] != null
      ? DateTime.tryParse(data['due_at'])?.toLocal()
      : null;
  bool dateOnly = data['date_only'] == true;
  // recurrence
  RecurrenceRule? rule;
  final raw = data['recurrence_rule'];
  if (raw is Map) {
    rule = RecurrenceRule(
      freq: (raw['freq'] ?? 'daily') as String,
      interval: (raw['interval'] ?? 1) as int,
      weekday: raw['weekday'] as int?,
      dayOfMonth: raw['day_of_month'] as int?,
      month: raw['month'] as int?,
      time: raw['time'] as String?,
    );
  } else if ((data['recurrence'] ?? 'none') != 'none') {
    rule = RecurrenceRule(freq: data['recurrence'] as String);
  }
  Map<String, dynamic>? link =
      data['link'] is Map ? Map<String, dynamic>.from(data['link']) : null;

  final t = AppLocalizations.of(context);

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      String freq = rule?.freq ?? 'none';
      int interval = rule?.interval ?? 1;
      if (interval < 1) interval = 1;
      int? weekday = rule?.weekday;
      int? dom = rule?.dayOfMonth;
      // rebuild the recurrence rule from the current picker state.
      void rebuildRule() {
        if (freq == 'none') {
          rule = null;
          return;
        }
        final tod = due != null
            ? '${due!.hour.toString().padLeft(2, '0')}:${due!.minute.toString().padLeft(2, '0')}'
            : null;
        rule = RecurrenceRule(
          freq: freq,
          interval: interval,
          weekday: freq == 'weekly' ? (weekday ?? ((due?.weekday ?? 1) - 1)) : null,
          dayOfMonth: freq == 'monthly' ? (dom ?? due?.day ?? 1) : null,
          month: freq == 'yearly' ? due?.month : null,
          time: tod,
        );
      }

      return AlertDialog(
        title: Text(item == null ? t.remNewReminder : t.remEditReminder),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: title,
                autofocus: item == null,
                decoration: InputDecoration(labelText: t.remWhatToRemind)),
            const SizedBox(height: Gap.md),
            TextField(
                controller: notes,
                maxLines: 2,
                decoration: InputDecoration(labelText: t.remNotesOptional)),
            const SizedBox(height: Gap.md),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.schedule, size: 18),
                  label: Text(due == null
                      ? t.remSetTime
                      : (dateOnly
                          ? DateFormat('d MMM').format(due!)
                          : DateFormat('d MMM, h:mm a').format(due!))),
                  onPressed: () async {
                    final d = await showDatePicker(
                        context: ctx,
                        initialDate: due ?? DateTime.now(),
                        firstDate:
                            DateTime.now().subtract(const Duration(days: 1)),
                        lastDate:
                            DateTime.now().add(const Duration(days: 3650)));
                    if (d == null) return;
                    final tm = await showTimePicker(
                        context: ctx,
                        initialTime:
                            TimeOfDay.fromDateTime(due ?? DateTime.now()));
                    setD(() {
                      dateOnly = tm == null;
                      due = DateTime(
                          d.year, d.month, d.day, tm?.hour ?? 9, tm?.minute ?? 0);
                    });
                  },
                ),
              ),
              if (due != null)
                IconButton(
                    onPressed: () => setD(() => due = null),
                    icon: const Icon(Icons.clear)),
            ]),
            const SizedBox(height: Gap.md),
            DropdownButtonFormField<String>(
              initialValue: freq,
              decoration: InputDecoration(labelText: t.remRecurrence),
              items: [
                DropdownMenuItem(value: 'none', child: Text(t.remRecurNone)),
                DropdownMenuItem(value: 'daily', child: Text(t.remRecurDaily)),
                DropdownMenuItem(value: 'weekly', child: Text(t.remRecurWeekly)),
                DropdownMenuItem(value: 'monthly', child: Text(t.remRecurMonthly)),
                DropdownMenuItem(value: 'yearly', child: Text(t.remRecurYearly)),
              ],
              onChanged: (v) => setD(() {
                freq = v ?? 'none';
                rebuildRule();
              }),
            ),
            // "Repeat every N <unit>" interval control (all recurring freqs).
            if (freq != 'none') ...[
              const SizedBox(height: Gap.sm),
              Row(children: [
                Text(t.remEveryLabel),
                const SizedBox(width: Gap.sm),
                SizedBox(
                  width: 72,
                  child: DropdownButtonFormField<int>(
                    initialValue: interval.clamp(1, 12),
                    isDense: true,
                    decoration: const InputDecoration(isDense: true),
                    items: [
                      for (var n = 1; n <= 12; n++)
                        DropdownMenuItem(value: n, child: Text('$n')),
                    ],
                    onChanged: (v) => setD(() {
                      interval = v ?? 1;
                      rebuildRule();
                    }),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Flexible(child: Text(_intervalUnit(t, freq))),
              ]),
            ],
            // weekly: which weekday
            if (freq == 'weekly') ...[
              const SizedBox(height: Gap.sm),
              DropdownButtonFormField<int>(
                initialValue: (weekday ?? ((due?.weekday ?? 1) - 1)).clamp(0, 6),
                decoration: InputDecoration(labelText: t.remOnWeekday),
                items: [
                  for (var wd = 0; wd < 7; wd++)
                    DropdownMenuItem(value: wd, child: Text(_weekdayLabel(wd))),
                ],
                onChanged: (v) => setD(() {
                  weekday = v;
                  rebuildRule();
                }),
              ),
            ],
            // monthly: which day of month
            if (freq == 'monthly') ...[
              const SizedBox(height: Gap.sm),
              DropdownButtonFormField<int>(
                initialValue: (dom ?? due?.day ?? 1).clamp(1, 31),
                decoration: InputDecoration(labelText: t.remOnDayOfMonth),
                items: [
                  for (var d = 1; d <= 31; d++)
                    DropdownMenuItem(value: d, child: Text('$d')),
                ],
                onChanged: (v) => setD(() {
                  dom = v;
                  rebuildRule();
                }),
              ),
            ],
            const SizedBox(height: Gap.md),
            Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                avatar: Icon(
                    link == null ? Icons.add_link : Icons.link,
                    size: 18),
                label: Text(link == null
                    ? t.remLinkAdd
                    : (link!['label'] ?? '').toString()),
                onPressed: () async {
                  final l = await pickLink(ctx);
                  if (l != null) setD(() => link = l);
                },
                onDeleted: link == null ? null : () => setD(() => link = null),
                deleteIcon: link == null ? null : const Icon(Icons.close, size: 16),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
        ],
      );
    }),
  );

  if (saved == true && title.text.trim().isNotEmpty) {
    final payload = <String, dynamic>{
      'title': title.text.trim(),
      'notes': notes.text.trim(),
      'due_at': due?.toUtc().toIso8601String(),
      'recurrence': rule?.freq ?? 'none',
      'recurrence_rule': rule?.toJson(),
      'date_only': dateOnly,
      'done': data['done'] ?? false,
      'link': link,
    };
    Map<String, dynamic>? lidSource = item;
    if (item == null) {
      lidSource = await app.reminders.add(payload);
    } else {
      await app.reminders.update(item, payload);
    }
    final lid = lidSource?['localId'];
    if (due != null && lid != null) {
      Notifications.schedule(lid, title.text.trim(), notes.text.trim(), due!);
    }
  }
}
