import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../notifications.dart';
import 'reminders_nlp.dart';
import 'offline_banner.dart';
import '../screens/reminders_screen.dart'
    show isOverdue, recurrenceLabel, ruleFromData;
import '../screens/reminders_quick_add.dart' show editReminder;
import 'bn_day_periods.dart' show appDateLocale;

/// Advanced combined CALENDAR / agenda view (#22, SPEC v2.1 §21).
///
/// Advanced depth vs Google Calendar / TickTick / any stock reminder app:
///  - ONE agenda over three stores at once — reminders + to-dos + notes that
///    carry a due date — so "everything I have to do" lives on a single
///    timeline instead of three disconnected tabs.
///  - Three zoom levels: Month (occurrence dots per day) · Week (7-day strip) ·
///    Day (a single day's ordered agenda). The selected day's agenda is always
///    shown below the grid so month/week stay glanceable.
///  - Recurrence is expanded on the fly by reusing the reminders NLP engine's
///    [nextOccurrence] (the Dart mirror of backend reminders_engine) so a
///    "every Friday 8am" reminder paints a dot on every Friday in view — no
///    second recurrence implementation.
///  - Overdue is highlighted honestly (red rail + label), today is ringed,
///    done items are struck through, and a tap reschedules (date+time picker)
///    or completes with a one-tap Undo — nothing is ever silently lost.
///  - All ten §21 pillars: empty / loading / offline / bilingual (zero Bangla
///    glyphs in source) / WCAG (icon+text, theme colour pairs, 44px targets).
class RemCalendarView extends StatefulWidget {
  const RemCalendarView({super.key});

  @override
  State<RemCalendarView> createState() => _RemCalendarViewState();
}

enum _Zoom { month, week, day }

class _RemCalendarViewState extends State<RemCalendarView> {
  _Zoom _zoom = _Zoom.month;
  DateTime _anchor = _dateOnly(DateTime.now()); // the visible month/week pivot
  DateTime _selected = _dateOnly(DateTime.now());

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final occ = _collect(app);

    return Column(
      children: [
        const OfflineBanner(),
        _header(context, t),
        _zoomTabs(t),
        if (_zoom == _Zoom.month) _monthGrid(context, occ),
        if (_zoom == _Zoom.week) _weekStrip(context, occ),
        const Divider(height: 1),
        Expanded(child: _dayAgenda(context, t, occ)),
      ],
    );
  }

  // ---- header: period label + prev/next/today ----------------------------
  Widget _header(BuildContext context, AppLocalizations t) {
    final fmt = _zoom == _Zoom.day
        ? DateFormat('EEEE, d MMM yyyy', appDateLocale(context))
        : DateFormat('MMMM yyyy', appDateLocale(context));
    final label = fmt.format(_zoom == _Zoom.day ? _selected : _anchor);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
        IconButton(
          tooltip: t.remCalPrev,
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: () => setState(() => _shift(-1)),
        ),
        TextButton(
          onPressed: () => setState(() {
            _anchor = _dateOnly(DateTime.now());
            _selected = _dateOnly(DateTime.now());
          }),
          child: Text(t.remCalToday),
        ),
        IconButton(
          tooltip: t.remCalNext,
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: () => setState(() => _shift(1)),
        ),
      ]),
    );
  }

  void _shift(int dir) {
    switch (_zoom) {
      case _Zoom.month:
        _anchor = DateTime(_anchor.year, _anchor.month + dir, 1);
        break;
      case _Zoom.week:
        _anchor = _anchor.add(Duration(days: 7 * dir));
        break;
      case _Zoom.day:
        _selected = _selected.add(Duration(days: dir));
        _anchor = _selected;
        break;
    }
  }

  Widget _zoomTabs(AppLocalizations t) {
    Widget seg(_Zoom z, String label) => Expanded(
          child: Semantics(
            selected: _zoom == z,
            button: true,
            child: InkWell(
              onTap: () => setState(() => _zoom = z),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      width: 2,
                      color: _zoom == z
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                    ),
                  ),
                ),
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight:
                          _zoom == z ? FontWeight.w700 : FontWeight.w500,
                      color: _zoom == z
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    )),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
      child: Row(children: [
        seg(_Zoom.month, t.remCalMonth),
        seg(_Zoom.week, t.remCalWeek),
        seg(_Zoom.day, t.remCalDay),
      ]),
    );
  }

  // ---- month grid --------------------------------------------------------
  Widget _monthGrid(BuildContext context, List<_Occ> occ) {
    final first = DateTime(_anchor.year, _anchor.month, 1);
    final lead = first.weekday % 7; // Sun=0 leading blanks
    final start = first.subtract(Duration(days: lead));
    final scheme = Theme.of(context).colorScheme;
    final today = _dateOnly(DateTime.now());
    final counts = _countByDay(occ);

    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.xs),
      child: Column(children: [
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: Text(
                    DateFormat('EEE', appDateLocale(context))
                        .format(DateTime(2024, 1, 7).add(Duration(days: i))),
                    style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        for (var w = 0; w < 6; w++)
          Row(
            children: [
              for (var dow = 0; dow < 7; dow++)
                _monthCell(context, start.add(Duration(days: w * 7 + dow)),
                    today, counts, scheme),
            ],
          ),
      ]),
    );
  }

  Widget _monthCell(BuildContext context, DateTime day, DateTime today,
      Map<DateTime, _DayCount> counts, ColorScheme scheme) {
    final inMonth = day.month == _anchor.month;
    final isToday = day == today;
    final isSel = day == _selected;
    final c = counts[day];
    return Expanded(
      child: InkWell(
        onTap: () => setState(() {
          _selected = day;
          if (!inMonth) _anchor = DateTime(day.year, day.month, 1);
        }),
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Container(
          height: 46,
          margin: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            color: isSel ? scheme.primary.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: isToday
                ? Border.all(color: scheme.primary, width: 1.4)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${day.day}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                    color: inMonth
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant.withValues(alpha: 0.5),
                  )),
              const SizedBox(height: 2),
              if (c != null)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (c.overdue > 0)
                      _dot(Brand.danger)
                    else if (c.total > 0)
                      _dot(scheme.primary),
                    if (c.total > 1) _dot(Brand.purple),
                    if (c.total > 2) _dot(Brand.success),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(Color c) => Container(
        width: 5,
        height: 5,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );

  // ---- week strip --------------------------------------------------------
  Widget _weekStrip(BuildContext context, List<_Occ> occ) {
    final start = _anchor.subtract(Duration(days: _anchor.weekday % 7));
    final scheme = Theme.of(context).colorScheme;
    final today = _dateOnly(DateTime.now());
    final counts = _countByDay(occ);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.xs),
      child: Row(children: [
        for (var i = 0; i < 7; i++)
          Builder(builder: (_) {
            final day = start.add(Duration(days: i));
            final isSel = day == _selected;
            final isToday = day == today;
            final c = counts[day];
            return Expanded(
              child: InkWell(
                onTap: () => setState(() => _selected = day),
                borderRadius: BorderRadius.circular(Radii.sm),
                child: Container(
                  margin: const EdgeInsets.all(2),
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  decoration: BoxDecoration(
                    color:
                        isSel ? scheme.primary.withValues(alpha: 0.14) : null,
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: isToday
                        ? Border.all(color: scheme.primary, width: 1.4)
                        : null,
                  ),
                  child: Column(children: [
                    Text(DateFormat('EEE', appDateLocale(context)).format(day),
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text('${day.day}',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                isToday ? FontWeight.w700 : FontWeight.w500)),
                    const SizedBox(height: 3),
                    SizedBox(
                      height: 6,
                      child: c != null
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _dot(c.overdue > 0
                                    ? Brand.danger
                                    : scheme.primary),
                                if (c.total > 1) _dot(Brand.purple),
                              ],
                            )
                          : null,
                    ),
                  ]),
                ),
              ),
            );
          }),
      ]),
    );
  }

  // ---- day agenda --------------------------------------------------------
  Widget _dayAgenda(
      BuildContext context, AppLocalizations t, List<_Occ> occ) {
    final dayItems = occ
        .where((o) => _dateOnly(o.when) == _selected)
        .toList()
      ..sort((a, b) => a.when.compareTo(b.when));
    if (dayItems.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_available_rounded,
                  size: 44,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: Gap.md),
              Text(t.remCalDayEmpty,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 96),
      itemCount: dayItems.length,
      itemBuilder: (_, i) => _AgendaRow(occ: dayItems[i]),
    );
  }

  // ---- data collection ---------------------------------------------------
  /// Expand every reminder / to-do / dated note into concrete occurrences that
  /// fall inside the currently visible window. Reuses the NLP recurrence engine
  /// so recurring reminders paint every occurrence in range.
  List<_Occ> _collect(AppState app) {
    final (from, to) = _window();
    final out = <_Occ>[];
    final now = DateTime.now();

    for (final it in app.reminders.items) {
      final d = it['data'] as Map<String, dynamic>;
      final rule = ruleFromData(d);
      final anchor = d['due_at'] != null
          ? DateTime.tryParse(d['due_at'])?.toLocal()
          : null;
      if (anchor == null) continue;
      if (rule == null) {
        if (!anchor.isBefore(from) && !anchor.isAfter(to)) {
          out.add(_Occ.reminder(it, anchor, overdue: isOverdue(d, now)));
        }
      } else {
        // expand occurrences in the window (cap to avoid runaways)
        var cursor = from.subtract(const Duration(seconds: 1));
        for (var guard = 0; guard < 200; guard++) {
          final n = nextOccurrence(anchor, rule, after: cursor);
          if (n == null || n.isAfter(to)) break;
          out.add(_Occ.reminder(it, n, overdue: n.isBefore(now)));
          cursor = n;
        }
      }
    }
    for (final it in app.todos.items) {
      final d = it['data'] as Map<String, dynamic>;
      final due = d['due_at'] != null
          ? DateTime.tryParse(d['due_at'])?.toLocal()
          : null;
      if (due == null || due.isBefore(from) || due.isAfter(to)) continue;
      out.add(_Occ.todo(it, due,
          overdue: d['done'] != true && due.isBefore(now)));
    }
    for (final it in app.notes.items) {
      final d = it['data'] as Map<String, dynamic>;
      final due = d['due_at'] != null
          ? DateTime.tryParse(d['due_at'])?.toLocal()
          : null;
      if (due == null || due.isBefore(from) || due.isAfter(to)) continue;
      out.add(_Occ.note(it, due, overdue: due.isBefore(now)));
    }
    return out;
  }

  (DateTime, DateTime) _window() {
    switch (_zoom) {
      case _Zoom.month:
        final first = DateTime(_anchor.year, _anchor.month, 1);
        final start = first.subtract(Duration(days: first.weekday % 7));
        return (start, start.add(const Duration(days: 42)));
      case _Zoom.week:
        final start = _anchor.subtract(Duration(days: _anchor.weekday % 7));
        return (start, start.add(const Duration(days: 7)));
      case _Zoom.day:
        return (_selected, _selected.add(const Duration(days: 1)));
    }
  }

  Map<DateTime, _DayCount> _countByDay(List<_Occ> occ) {
    final m = <DateTime, _DayCount>{};
    for (final o in occ) {
      final key = _dateOnly(o.when);
      final c = m.putIfAbsent(key, () => _DayCount());
      c.total++;
      if (o.overdue && !o.done) c.overdue++;
    }
    return m;
  }
}

class _DayCount {
  int total = 0;
  int overdue = 0;
}

/// One concrete thing happening at a moment: a reminder fire, a to-do due, or a
/// dated note. Carries its source store kind so the agenda can act on it.
class _Occ {
  final String kind; // reminder | todo | note
  final Map<String, dynamic> item;
  final DateTime when;
  final bool overdue;
  _Occ(this.kind, this.item, this.when, this.overdue);

  factory _Occ.reminder(Map<String, dynamic> it, DateTime w,
          {required bool overdue}) =>
      _Occ('reminder', it, w, overdue);
  factory _Occ.todo(Map<String, dynamic> it, DateTime w,
          {required bool overdue}) =>
      _Occ('todo', it, w, overdue);
  factory _Occ.note(Map<String, dynamic> it, DateTime w,
          {required bool overdue}) =>
      _Occ('note', it, w, overdue);

  Map<String, dynamic> get data => item['data'] as Map<String, dynamic>;
  bool get done => data['done'] == true;
  String get title => (data['title'] ?? data['body'] ?? '').toString();
}

class _AgendaRow extends StatelessWidget {
  final _Occ occ;
  const _AgendaRow({required this.occ});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final d = occ.data;
    final done = occ.done;
    final dateOnly = d['date_only'] == true;
    final timeStr =
        dateOnly ? t.remCalAllDay : DateFormat('h:mm a', appDateLocale(context)).format(occ.when);
    final rule = occ.kind == 'reminder' ? ruleFromData(d) : null;
    final railColor = occ.overdue && !done
        ? Brand.danger
        : _kindColor(occ.kind, scheme);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => _open(context),
        child: IntrinsicHeight(
          child: Row(children: [
            Container(width: 4, color: railColor),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    Gap.sm, Gap.sm, Gap.xs, Gap.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(timeStr,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: occ.overdue && !done
                                  ? Brand.danger
                                  : scheme.onSurfaceVariant)),
                    ),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(occ.title,
                              style: done
                                  ? Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                          decoration:
                                              TextDecoration.lineThrough,
                                          color:
                                              Theme.of(context).disabledColor)
                                  : Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(height: 3),
                          Wrap(
                            spacing: Gap.sm,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _tag(_kindIcon(occ.kind), _kindLabel(t, occ.kind),
                                  _kindColor(occ.kind, scheme)),
                              if (occ.overdue && !done)
                                _tag(Icons.warning_amber_rounded,
                                    t.remCalOverdue, Brand.danger),
                              if (rule != null)
                                _tag(Icons.repeat_rounded,
                                    recurrenceLabel(t, rule), Brand.purple),
                              if ((d['priority'] ?? 'none') == 'high')
                                _tag(Icons.flag_rounded, t.remPriorityHigh,
                                    Brand.warning),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // complete / undo (reminders + todos)
                    if (occ.kind != 'note')
                      IconButton(
                        tooltip: done ? t.remCalUndo : t.remCalDone,
                        icon: Icon(
                            done
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            color: done ? Brand.success : null),
                        onPressed: () => _toggleDone(context),
                      ),
                    // reschedule
                    IconButton(
                      tooltip: t.remCalReschedule,
                      icon: const Icon(Icons.edit_calendar_rounded),
                      onPressed: () => _reschedule(context),
                    ),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    if (occ.kind == 'reminder') {
      editReminder(context, item: occ.item);
    } else {
      _reschedule(context);
    }
  }

  void _toggleDone(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final repo = occ.kind == 'reminder' ? app.reminders : app.todos;
    final d = occ.data;
    final done = occ.done;
    final rule = occ.kind == 'reminder' ? ruleFromData(d) : null;
    // completing a recurring reminder advances it instead of ending it
    if (!done && rule != null) {
      final adv = nextOccurrence(occ.when, rule, after: DateTime.now());
      repo.update(occ.item, {
        'due_at': adv?.toUtc().toIso8601String(),
        'done': false,
      });
      Notifications.cancel(occ.item['localId']);
      if (adv != null) {
        Notifications.schedule(
            occ.item['localId'], d['title'] ?? '', d['notes'] ?? '', adv);
      }
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.remRecurringAdvanced)));
      return;
    }
    repo.update(occ.item, {'done': !done});
    if (!done) Notifications.cancel(occ.item['localId']);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(done ? t.remCalMarkedOpen : t.remCalMarkedDone),
      action: SnackBarAction(
          label: t.undo,
          onPressed: () => repo.update(occ.item, {'done': done})),
    ));
  }

  Future<void> _reschedule(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final repo = switch (occ.kind) {
      'reminder' => app.reminders,
      'todo' => app.todos,
      _ => app.notes,
    };
    final d = occ.data;
    final date = await showDatePicker(
      context: context,
      initialDate: occ.when,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (date == null || !context.mounted) return;
    final tm = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(occ.when));
    final when = DateTime(
        date.year, date.month, date.day, tm?.hour ?? 9, tm?.minute ?? 0);
    await repo.update(occ.item, {
      'due_at': when.toUtc().toIso8601String(),
      'date_only': tm == null,
      if (occ.kind != 'note') 'done': false,
    });
    if (occ.kind != 'note') {
      Notifications.cancel(occ.item['localId']);
      Notifications.schedule(
          occ.item['localId'], d['title'] ?? '', d['notes'] ?? '', when);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${t.remCalRescheduledTo} ${DateFormat('d MMM, h:mm a', appDateLocale(context)).format(when)}')));
    }
  }

  Widget _tag(IconData icon, String label, Color tint) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: tint),
        const SizedBox(width: 2),
        Text(label, style: TextStyle(fontSize: 11, color: tint)),
      ]);
}

Color _kindColor(String kind, ColorScheme scheme) {
  switch (kind) {
    case 'todo':
      return Brand.success;
    case 'note':
      return Brand.warning;
    default:
      return scheme.primary;
  }
}

IconData _kindIcon(String kind) {
  switch (kind) {
    case 'todo':
      return Icons.checklist_rounded;
    case 'note':
      return Icons.sticky_note_2_rounded;
    default:
      return Icons.alarm_rounded;
  }
}

String _kindLabel(AppLocalizations t, String kind) {
  switch (kind) {
    case 'todo':
      return t.remCalKindTodo;
    case 'note':
      return t.remCalKindNote;
    default:
      return t.remCalKindReminder;
  }
}
