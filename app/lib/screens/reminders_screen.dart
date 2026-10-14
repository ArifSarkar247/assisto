import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../notifications.dart';
import '../widgets/skeleton.dart';
import '../widgets/reminders_nlp.dart';
import '../widgets/rem_calendar.dart';
import '../widgets/offline_banner.dart';
import 'reminders_quick_add.dart';

/// Reminders & Memory brain — the daily natural-language reminder screen.
///
/// Advanced depth vs Google Keep / TickTick / BZ Reminder:
///  - A natural-language quick-add ("pr2ti shukrobar sokal 8ta ...") with an
///    instant parsed preview before confirm (offline, client-side mirror of the
///    backend NLP engine), Bangla + English + Banglish + Bangla digits.
///  - Smart recurrence (daily/weekly-by-weekday/monthly-by-date/yearly).
///  - Smart snooze (10 min / tomorrow morning / adha ghonta).
///  - Overdue / Today / Upcoming / Done grouping with live next-occurrence.
///  - Optional link to a person / bill / document / event (a chip).
class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  // list = the grouped Overdue/Today/Upcoming view; calendar = the combined
  // day/week/month agenda over reminders + to-dos + dated notes.
  bool _calendar = false;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final items = app.reminders.items;
    final groups = _group(items);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.navReminders),
        actions: [
          IconButton(
            tooltip: _calendar ? t.remCalShowList : t.remCalShowCalendar,
            onPressed: () => setState(() => _calendar = !_calendar),
            icon: Icon(_calendar
                ? Icons.view_agenda_outlined
                : Icons.calendar_month_outlined),
          ),
          IconButton(
            tooltip: t.remSyncTooltip,
            onPressed: () => app.reminders.sync(),
            icon: app.reminders.syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editReminder(context),
        icon: const Icon(Icons.add_alarm),
        label: Text(t.add),
      ),
      body: _calendar
          ? const RemCalendarView()
          : Column(
              children: [
                const OfflineBanner(),
                QuickAddBar(onCommit: (p, title, link) async {
                  await _create(context, title: title, parsed: p, link: link);
                }),
                Expanded(
                  child: items.isEmpty
                      ? StateMessage(
                          icon: Icons.alarm_on_outlined,
                          title: t.remEmpty,
                          message: t.remEmptyHint,
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(
                              Gap.md, Gap.sm, Gap.md, 96),
                          children: [
                            for (final g in groups)
                              if (g.items.isNotEmpty) ...[
                                _SectionHeader(
                                    label: g.label(t), tint: g.tint),
                                for (final it in g.items)
                                  _ReminderCard(item: it, group: g.kind),
                                const SizedBox(height: Gap.sm),
                              ],
                          ],
                        ),
                ),
              ],
            ),
    );
  }

  // ---- grouping -----------------------------------------------------------
  List<_Group> _group(List<Map<String, dynamic>> items) {
    final now = DateTime.now();
    final overdue = <Map<String, dynamic>>[];
    final today = <Map<String, dynamic>>[];
    final upcoming = <Map<String, dynamic>>[];
    final noDate = <Map<String, dynamic>>[];
    final done = <Map<String, dynamic>>[];
    for (final it in items) {
      final d = it['data'] as Map<String, dynamic>;
      if (d['done'] == true) {
        done.add(it);
        continue;
      }
      final next = nextFireOf(d, now);
      if (isOverdue(d, now)) {
        overdue.add(it);
      } else if (next == null) {
        noDate.add(it);
      } else if (next.year == now.year &&
          next.month == now.month &&
          next.day == now.day) {
        today.add(it);
      } else {
        upcoming.add(it);
      }
    }
    int byNext(Map<String, dynamic> a, Map<String, dynamic> b) {
      final da = nextFireOf(a['data'], now);
      final db = nextFireOf(b['data'], now);
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    }

    int byOverdue(Map<String, dynamic> a, Map<String, dynamic> b) {
      final da = overdueFireOf(a['data'], now);
      final db = overdueFireOf(b['data'], now);
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    }

    overdue.sort(byOverdue);
    today.sort(byNext);
    upcoming.sort(byNext);
    return [
      _Group('overdue', overdue, Brand.danger),
      _Group('today', today, Brand.blue),
      _Group('upcoming', upcoming, Brand.purple),
      _Group('nodate', noDate, Colors.blueGrey),
      _Group('done', done, Brand.success),
    ];
  }

  Future<void> _create(BuildContext context,
      {required String title,
      required ParsedReminder parsed,
      Map<String, dynamic>? link}) async {
    final app = context.read<AppState>();
    final payload = <String, dynamic>{
      'title': title,
      'notes': '',
      'due_at': parsed.dateTime?.toUtc().toIso8601String(),
      'recurrence': parsed.recurrence?.freq ?? 'none',
      'recurrence_rule': parsed.recurrence?.toJson(),
      'date_only': parsed.dateOnly,
      'done': false,
      'source': 'nlp',
      if (link != null) 'link': link,
    };
    await app.reminders.add(payload);
    final lid = app.reminders.items.isNotEmpty
        ? app.reminders.items.first['localId']
        : null;
    if (parsed.dateTime != null && lid != null) {
      Notifications.schedule(lid, title, '', parsed.dateTime!);
    }
  }
}

/// The stored anchor (due_at) as a local DateTime, or null.
DateTime? _anchorOf(Map<String, dynamic> d) =>
    d['due_at'] != null ? DateTime.tryParse(d['due_at'])?.toLocal() : null;

/// Next UPCOMING fire (strictly after `now`), used to file a reminder under
/// Today / Upcoming and to show its "when" chip. For a one-off that has already
/// passed this returns the past instant (so an overdue one-off still shows its
/// time); for a recurring reminder it returns the next future occurrence
/// (a daily 08:00 reminder at 10:00 -> tomorrow 08:00, NOT today's past time).
DateTime? nextFireOf(Map<String, dynamic> d, DateTime now) {
  final anchor = _anchorOf(d);
  if (anchor == null) return null;
  final rule = ruleFromData(d);
  if (rule == null) return anchor; // one-off keeps its instant (may be overdue)
  return nextOccurrence(anchor, rule, after: now);
}

/// Whether a reminder is genuinely overdue (needs action for a fire that
/// already happened and was not acknowledged). Mirrors Python
/// reminders_engine.is_overdue intent:
///  - one-off: a past due_at that isn't done;
///  - recurring: the acknowledgement pointer (due_at) is in the past AND a
///    whole further occurrence has already elapsed since it — i.e. the user
///    skipped at least one fire. A daily 08:00 reminder seen at 10:00 (due_at =
///    today 08:00, next = tomorrow 08:00 > now) is therefore NOT overdue; it
///    files under Today. A daily reminder whose pointer is yesterday 08:00
///    (next after it = today 08:00 <= now) IS overdue.
bool isOverdue(Map<String, dynamic> d, DateTime now) {
  if (d['done'] == true) return false;
  final anchor = _anchorOf(d);
  if (anchor == null) return false;
  final rule = ruleFromData(d);
  if (rule == null) return anchor.isBefore(now); // one-off past due
  if (!anchor.isBefore(now)) return false; // pointer still in the future
  final afterPointer = nextOccurrence(anchor, rule, after: anchor);
  return afterPointer != null && !afterPointer.isAfter(now);
}

/// The missed instant to surface on an overdue card (the acknowledgement
/// pointer), falling back to the next fire.
DateTime? overdueFireOf(Map<String, dynamic> d, DateTime now) =>
    _anchorOf(d) ?? nextFireOf(d, now);

RecurrenceRule? ruleFromData(Map<String, dynamic> d) {
  final raw = d['recurrence_rule'];
  if (raw is Map) {
    return RecurrenceRule(
      freq: (raw['freq'] ?? 'daily') as String,
      interval: (raw['interval'] ?? 1) as int,
      weekday: raw['weekday'] as int?,
      dayOfMonth: raw['day_of_month'] as int?,
      month: raw['month'] as int?,
      time: raw['time'] as String?,
    );
  }
  final freq = (d['recurrence'] ?? 'none') as String;
  if (freq == 'none' || freq.isEmpty) return null;
  final anchor = d['due_at'] != null
      ? DateTime.tryParse(d['due_at'])?.toLocal()
      : null;
  return RecurrenceRule(
    freq: freq,
    time: anchor != null
        ? '${anchor.hour.toString().padLeft(2, '0')}:${anchor.minute.toString().padLeft(2, '0')}'
        : null,
  );
}

// ---------------------------------------------------------------- grouping
class _Group {
  final String kind;
  final List<Map<String, dynamic>> items;
  final Color tint;
  _Group(this.kind, this.items, this.tint);

  String label(AppLocalizations t) {
    switch (kind) {
      case 'overdue':
        return t.remGroupOverdue;
      case 'today':
        return t.remGroupToday;
      case 'upcoming':
        return t.remGroupUpcoming;
      case 'nodate':
        return t.remGroupNoDate;
      default:
        return t.remGroupDone;
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final Color tint;
  const _SectionHeader({required this.label, required this.tint});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.md, Gap.xs, Gap.sm),
      child: Row(children: [
        Container(width: 8, height: 8,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
        const SizedBox(width: Gap.sm),
        Text(label,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(fontWeight: FontWeight.w700, color: tint)),
      ]),
    );
  }
}

// ---------------------------------------------------------------- card
class _ReminderCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final String group;
  const _ReminderCard({required this.item, required this.group});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final d = item['data'] as Map<String, dynamic>;
    final done = d['done'] == true;
    final now = DateTime.now();
    // On an overdue card show the missed instant; otherwise the next fire.
    final next =
        group == 'overdue' ? overdueFireOf(d, now) : nextFireOf(d, now);
    final rule = ruleFromData(d);
    final link = d['link'] is Map ? d['link'] as Map : null;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => editReminder(context, item: item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Checkbox(
                value: done,
                onChanged: (v) {
                  // completing a recurring reminder advances it instead of killing it
                  if (v == true && rule != null) {
                    final adv = nextOccurrence(next ?? now, rule, after: now);
                    app.reminders.update(item, {
                      'due_at': adv?.toUtc().toIso8601String(),
                      'done': false,
                    });
                    Notifications.cancel(item['localId']);
                    if (adv != null) {
                      Notifications.schedule(
                          item['localId'], d['title'] ?? '', d['notes'] ?? '', adv);
                    }
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(t.remRecurringAdvanced)));
                  } else {
                    app.reminders.update(item, {'done': v ?? false});
                    if (v == true) Notifications.cancel(item['localId']);
                  }
                },
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (d['title'] ?? '').toString(),
                      style: done
                          ? Theme.of(context).textTheme.bodyLarge?.copyWith(
                              decoration: TextDecoration.lineThrough,
                              color: Theme.of(context).disabledColor)
                          : Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: Gap.sm,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (next != null)
                          _MetaChip(
                            icon: Icons.schedule,
                            label: _whenLabel(context, next, d),
                            tint: group == 'overdue'
                                ? Brand.danger
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        if (rule != null)
                          _MetaChip(
                            icon: Icons.repeat,
                            label: recurrenceLabel(t, rule),
                            tint: Brand.purple,
                          ),
                        if (link != null)
                          _MetaChip(
                            icon: _linkIcon(link['type'] as String?),
                            label: (link['label'] ?? '').toString(),
                            tint: Brand.blue,
                          ),
                        if ((d['priority'] ?? 'none') == 'high')
                          _MetaChip(
                            icon: Icons.flag,
                            label: t.remPriorityHigh,
                            tint: Brand.warning,
                          ),
                        if ((d['category'] ?? '').toString().isNotEmpty)
                          _MetaChip(
                            icon: Icons.label_outline,
                            label: (d['category']).toString(),
                            tint: Brand.cyan,
                          ),
                      ],
                    ),
                    if ((d['notes'] ?? '').toString().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text((d['notes']).toString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 12)),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') editReminder(context, item: item);
                  if (v == 'snooze') _snooze(context, item);
                  if (v == 'priority') _togglePriority(context, item);
                  if (v == 'category') _setCategory(context, item);
                  if (v == 'del') _del(context, item);
                },
                itemBuilder: (_) => [
                  if (!done)
                    PopupMenuItem(
                        value: 'snooze',
                        child: Row(children: [
                          const Icon(Icons.snooze, size: 18),
                          const SizedBox(width: Gap.sm),
                          Text(t.remSnooze),
                        ])),
                  PopupMenuItem(
                      value: 'priority',
                      child: Row(children: [
                        Icon(
                            (d['priority'] ?? 'none') == 'high'
                                ? Icons.flag
                                : Icons.outlined_flag,
                            size: 18),
                        const SizedBox(width: Gap.sm),
                        Text((d['priority'] ?? 'none') == 'high'
                            ? t.remPriorityClear
                            : t.remPrioritySet),
                      ])),
                  PopupMenuItem(
                      value: 'category',
                      child: Row(children: [
                        const Icon(Icons.label_outline, size: 18),
                        const SizedBox(width: Gap.sm),
                        Text(t.remCategorySet),
                      ])),
                  PopupMenuItem(value: 'edit', child: Text(t.edit)),
                  PopupMenuItem(value: 'del', child: Text(t.delete)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _whenLabel(BuildContext context, DateTime dt, Map<String, dynamic> d) {
    final t = AppLocalizations.of(context);
    final now = DateTime.now();
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final tomorrow = now.add(const Duration(days: 1));
    final isTomorrow = dt.year == tomorrow.year &&
        dt.month == tomorrow.month &&
        dt.day == tomorrow.day;
    final dateOnly = d['date_only'] == true;
    final timeStr = DateFormat('h:mm a').format(dt);
    if (sameDay) return dateOnly ? t.remGroupToday : '${t.remGroupToday}, $timeStr';
    if (isTomorrow) {
      return dateOnly ? t.remTomorrow : '${t.remTomorrow}, $timeStr';
    }
    return dateOnly
        ? DateFormat('d MMM').format(dt)
        : DateFormat('d MMM, h:mm a').format(dt);
  }

  Future<void> _snooze(BuildContext context, Map<String, dynamic> it) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final d = it['data'] as Map<String, dynamic>;
    final current = d['due_at'] != null
        ? DateTime.tryParse(d['due_at'])?.toLocal()
        : null;
    final chosen = await showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _SnoozeSheet(current: current),
    );
    if (chosen == null) return;
    await app.reminders.update(it, {
      'due_at': chosen.toUtc().toIso8601String(),
      'done': false,
    });
    Notifications.cancel(it['localId']);
    Notifications.schedule(it['localId'], d['title'] ?? '', d['notes'] ?? '', chosen);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${t.remSnoozedTo} ${DateFormat('d MMM, h:mm a').format(chosen)}')));
    }
  }

  void _togglePriority(BuildContext context, Map<String, dynamic> it) {
    final app = context.read<AppState>();
    final d = it['data'] as Map<String, dynamic>;
    final high = (d['priority'] ?? 'none') == 'high';
    app.reminders.update(it, {'priority': high ? 'none' : 'high'});
  }

  Future<void> _setCategory(BuildContext context, Map<String, dynamic> it) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final d = it['data'] as Map<String, dynamic>;
    final c = TextEditingController(text: (d['category'] ?? '').toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.remCategorySet),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: t.remCategoryHint),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
        ],
      ),
    );
    if (ok == true) app.reminders.update(it, {'category': c.text.trim()});
  }

  void _del(BuildContext context, Map<String, dynamic> it) {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    Notifications.cancel(it['localId']);
    app.reminders.remove(it);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(t.commonDeleted),
      action: SnackBarAction(label: t.undo, onPressed: () => app.undoLast()),
    ));
  }
}

IconData _linkIcon(String? type) {
  switch (type) {
    case 'person':
      return Icons.person_outline;
    case 'bill':
      return Icons.receipt_long_outlined;
    case 'document':
      return Icons.folder_outlined;
    case 'event':
      return Icons.event_outlined;
    default:
      return Icons.link;
  }
}

String recurrenceLabel(AppLocalizations t, RecurrenceRule rule) {
  switch (rule.freq) {
    case 'daily':
      return t.remRecurDaily;
    case 'weekly':
      if (rule.weekday != null) {
        return '${t.remRecurWeekly} · ${_weekdayName(t, rule.weekday!)}';
      }
      return t.remRecurWeekly;
    case 'monthly':
      if (rule.dayOfMonth != null) {
        return t.remRecurMonthlyOn(rule.dayOfMonth!);
      }
      return t.remRecurMonthly;
    case 'yearly':
      return t.remRecurYearly;
    default:
      return '';
  }
}

String _weekdayName(AppLocalizations t, int wd) {
  // 0=Mon..6=Sun -> intl EEEE via a reference Monday (2024-01-01 was Monday)
  final ref = DateTime(2024, 1, 1).add(Duration(days: wd));
  return DateFormat('EEEE').format(ref);
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color tint;
  const _MetaChip({required this.icon, required this.label, required this.tint});
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: tint),
      const SizedBox(width: 3),
      Text(label, style: TextStyle(fontSize: 12, color: tint)),
    ]);
  }
}

// ---------------------------------------------------------------- snooze sheet
class _SnoozeSheet extends StatelessWidget {
  final DateTime? current;
  const _SnoozeSheet({this.current});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final now = DateTime.now();
    final presets = <_SnoozeOpt>[
      _SnoozeOpt(t.remSnooze10m, now.add(const Duration(minutes: 10))),
      _SnoozeOpt(t.remSnooze1h, now.add(const Duration(hours: 1))),
      _SnoozeOpt(t.remSnooze3h, now.add(const Duration(hours: 3))),
      _SnoozeOpt(t.remSnoozeTomorrow,
          DateTime(now.year, now.month, now.day + 1, 8, 0)),
      _SnoozeOpt(t.remSnoozeNextWeek,
          DateTime(now.year, now.month, now.day + 7, 9, 0)),
    ];
    final free = TextEditingController();
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg,
          Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.remSnooze,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.md),
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.sm,
          children: [
            for (final p in presets)
              ActionChip(
                label: Text(p.label),
                onPressed: () => Navigator.pop(context, p.when),
              ),
          ],
        ),
        const SizedBox(height: Gap.md),
        // natural-language snooze: "adha ghonta", "tomorrow morning", ...
        TextField(
          controller: free,
          decoration: InputDecoration(
            hintText: t.remSnoozeFreeHint,
            prefixIcon: const Icon(Icons.edit_calendar_outlined),
            suffixIcon: IconButton(
              icon: const Icon(Icons.check),
              onPressed: () {
                final dt = snoozeReminder(current, free.text, now: DateTime.now());
                if (dt != null) Navigator.pop(context, dt);
              },
            ),
          ),
          onSubmitted: (v) {
            final dt = snoozeReminder(current, v, now: DateTime.now());
            if (dt != null) Navigator.pop(context, dt);
          },
        ),
      ]),
    );
  }
}

class _SnoozeOpt {
  final String label;
  final DateTime when;
  _SnoozeOpt(this.label, this.when);
}
