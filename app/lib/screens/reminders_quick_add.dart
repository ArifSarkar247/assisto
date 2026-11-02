import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../reminders/exact_alarm_ui.dart' show maybeAskExactAlarms; // remmeter
import '../widgets/reminders_nlp.dart';
import 'reminders_screen.dart' show recurrenceLabel;
import '../widgets/bn_day_periods.dart' show appDateLocale;
import 'package:assisto/widgets/app_sheet.dart';
import '../widgets/rn_bits.dart'; // remnotes
import '../widgets/voice_input.dart' show VoiceDictation, VoiceMicButton;

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
  // remnotes: say it instead of typing (the phone's own speech-to-text)
  final _voice = VoiceDictation();
  String _last = '';
  ParsedReminder? _preview;
  Map<String, dynamic>? _link;

  @override
  void initState() {
    super.initState();
    // dictation writes into the controller without onChanged: keep the
    // preview live for spoken text too
    _c.addListener(() {
      if (_c.text == _last) return;
      _last = _c.text;
      if (mounted) _onChanged(_c.text);
    });
  }

  @override
  void dispose() {
    _voice.dispose();
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
              Icon(Icons.auto_awesome_rounded, size: 20, color: scheme.primary),
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
                    // the example is the point of the hint: show it whole
                    hintMaxLines: 2,
                  ),
                ),
              ),
              if (_c.text.isEmpty)
                VoiceMicButton(voice: _voice, input: _c),
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
          ? DateFormat('d MMM', appDateLocale(context)).format(dt)
          : DateFormat('d MMM, h:mm a', appDateLocale(context)).format(dt);
      chips.add(_chip(Icons.schedule_rounded, label, scheme.primary));
    }
    if (parsed.recurrence != null) {
      chips.add(_chip(
          Icons.repeat_rounded, recurrenceLabel(t, parsed.recurrence!),
          Brand.onTint(context, Brand.purple)));
    }
    if (link != null) {
      chips.add(_chip(Icons.link_rounded, (link!['label'] ?? '').toString(),
          Brand.onTint(context, Brand.blue)));
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
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ),
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...chips,
              ActionChip(
                avatar: const Icon(Icons.add_link_rounded, size: 16),
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
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: Gap.xs),
          Text(label,
              style: AType.bodySmall
                  .copyWith(color: tint, fontFeatures: AFonts.tabular)),
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
  return showAppSheet<Map<String, dynamic>>(
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
            // remnotes: a person comes from My Circle in one tap — never
            // typed twice (typing stays for someone not in the Circle)
            if (type == 'person') ...[
              const SizedBox(height: Gap.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const ValueKey('rn-link-circle'),
                  icon: const Icon(Icons.people_alt_rounded, size: 18),
                  label: Text(t.rnFromCircle),
                  onPressed: () async {
                    final m = await pickCircleMember(ctx, title: t.rnFromCircle);
                    if (m == null || !ctx.mounted) return;
                    Navigator.pop(ctx, {
                      'type': 'person',
                      'id': m['circle_id'],
                      'label': '${m['name'] ?? ''}',
                      'source': 'circle',
                    });
                  },
                ),
              ),
            ],
            const SizedBox(height: Gap.md),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: custom,
                  autofocus: type != 'person',
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
                tooltip: AppLocalizations.of(context).done,
                icon: const Icon(Icons.check_rounded),
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
      return Icons.receipt_long_rounded;
    case 'document':
      return Icons.folder_rounded;
    case 'event':
      return Icons.event_rounded;
    default:
      return Icons.person_outline_rounded;
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

// 0=Mon..6=Sun -> weekday name in the APP's language (2024-01-01 was a
// Monday). remnotes: it printed English names in Bangla mode.
String _weekdayLabel(AppLocalizations t, int wd) {
  final ref = DateTime(2024, 1, 1).add(Duration(days: wd));
  return DateFormat('EEEE', t.localeName).format(ref);
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
                  icon: const Icon(Icons.schedule_rounded, size: 18),
                  label: Text(due == null
                      ? t.remSetTime
                      : (dateOnly
                          ? DateFormat('d MMM', appDateLocale(context)).format(due!)
                          : DateFormat('d MMM, h:mm a', appDateLocale(context)).format(due!))),
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
                    tooltip: AppLocalizations.of(context).f2ClearTime,
                    onPressed: () => setD(() => due = null),
                    icon: const Icon(Icons.clear_rounded)),
            ]),
            const SizedBox(height: Gap.md),
            DropdownButtonFormField<String>(
              initialValue: freq,
              isExpanded: true,
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
                // remnotes: 72 dp clipped the number + arrow (5 px overflow)
                SizedBox(
                  width: 96,
                  child: DropdownButtonFormField<int>(
                    initialValue: interval.clamp(1, 12),
                    isDense: true,
                    isExpanded: true,
                    decoration: const InputDecoration(isDense: true),
                    items: [
                      for (var n = 1; n <= 12; n++)
                        DropdownMenuItem(value: n, child: Text(rnDigits(t, n))),
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
                isExpanded: true,
                initialValue: (weekday ?? ((due?.weekday ?? 1) - 1)).clamp(0, 6),
                decoration: InputDecoration(labelText: t.remOnWeekday),
                items: [
                  for (var wd = 0; wd < 7; wd++)
                    DropdownMenuItem(value: wd, child: Text(_weekdayLabel(t, wd))),
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
                isExpanded: true,
                initialValue: (dom ?? due?.day ?? 1).clamp(1, 31),
                decoration: InputDecoration(labelText: t.remOnDayOfMonth),
                items: [
                  for (var d = 1; d <= 31; d++)
                    DropdownMenuItem(value: d, child: Text(rnDigits(t, d))),
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
                    link == null ? Icons.add_link_rounded : Icons.link_rounded,
                    size: 18),
                label: Text(link == null
                    ? t.remLinkAdd
                    : (link!['label'] ?? '').toString()),
                onPressed: () async {
                  final l = await pickLink(ctx);
                  if (l != null) setD(() => link = l);
                },
                onDeleted: link == null ? null : () => setD(() => link = null),
                deleteIcon: link == null ? null : const Icon(Icons.close_rounded, size: 16),
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
      'recurrence_rule': rule?.toJson() ?? <String, dynamic>{}, // qa1
      'date_only': dateOnly,
      'done': data['done'] ?? false,
      'link': link ?? <String, dynamic>{}, // qa1: never null
    };
    Map<String, dynamic>? lidSource = item;
    if (item == null) {
      lidSource = await app.reminders.add(payload);
    } else {
      await app.reminders.update(item, payload);
    }
    // remmeter: the alarm follows the repo (AppState reconcile); a timed
    // reminder is where we explain + ask for exact "Alarms & reminders".
    if (due != null && lidSource != null && context.mounted) {
      await maybeAskExactAlarms(context);
    }
  }
}
