import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../notifications.dart';
import '../services/home_widget_service.dart';
import '../widgets/skeleton.dart';
import '../widgets/reminders_nlp.dart';
import '../widgets/rem_calendar.dart';
import '../widgets/offline_banner.dart';
import 'reminders_quick_add.dart';
import '../widgets/bn_day_periods.dart' show appDateLocale;

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

class _RemindersScreenState extends State<RemindersScreen>
    with WidgetsBindingObserver {
  // list = the grouped Overdue/Today/Upcoming view; calendar = the combined
  // day/week/month agenda over reminders + to-dos + dated notes.
  bool _calendar = false;

  // Notification-permission banner (Android 13+): null = still checking,
  // true = enabled (hide), false = disabled (show). Dismissal is in-memory
  // for the session so a user who closes it isn't nagged again this run.
  bool? _notifEnabled;
  bool _notifBannerDismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshNotifStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check when the user comes back (e.g. after toggling the OS setting).
    if (state == AppLifecycleState.resumed) _refreshNotifStatus();
  }

  Future<void> _refreshNotifStatus() async {
    final enabled = await Notifications.isEnabled();
    if (mounted) setState(() => _notifEnabled = enabled);
  }

  Future<void> _enableNotifications() async {
    final granted = await Notifications.requestPermission();
    // If the runtime prompt can no longer help (permanently denied), send the
    // user to the OS settings page instead.
    if (!granted) await Notifications.openSettings();
    await _refreshNotifStatus();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final items = app.reminders.items;
    final groups = _group(items);

    // #196 Keep the home-screen widget in sync with the latest reminders.
    // Fire-and-forget; a no-op when the widget is disabled. Labels are already
    // localised (bn/en) so the native widget never holds a hard-coded string.
    HomeWidgetService.refresh(app,
        labels: HomeWidgetLabels(
          emptyTitle: t.hwEmptyTitle,
          emptyBody: t.hwEmptyBody,
          todayLabel: t.hwTodayLabel,
        ));

    return Scaffold(
      // banners-everywhere (owner 26 Oct): one bottom banner, Free only
      bottomNavigationBar: const AdBannerSlot(screen: 'reminders'),
      appBar: AppBar(
        title: Text(t.navReminders),
        actions: [
          IconButton(
            tooltip: _calendar ? t.remCalShowList : t.remCalShowCalendar,
            onPressed: () => setState(() => _calendar = !_calendar),
            icon: Icon(_calendar
                ? Icons.view_agenda_rounded
                : Icons.calendar_month_rounded),
          ),
          IconButton(
            tooltip: t.remSyncTooltip,
            onPressed: () => app.reminders.sync(),
            icon: app.reminders.syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editReminder(context),
        icon: const Icon(Icons.add_alarm_rounded),
        label: Text(t.add),
      ),
      body: _calendar
          ? const RemCalendarView()
          : Column(
              children: [
                if (_notifEnabled == false && !_notifBannerDismissed)
                  _NotifPermBanner(
                    onEnable: _enableNotifications,
                    onDismiss: () =>
                        setState(() => _notifBannerDismissed = true),
                  ),
                const OfflineBanner(),
                QuickAddBar(onCommit: (p, title, link) async {
                  await _create(context, title: title, parsed: p, link: link);
                }),
                Expanded(
                  child: items.isEmpty
                      ? StateMessage(
                          icon: Icons.alarm_on_rounded,
                          title: t.remEmpty,
                          message: t.remEmptyHint,
                        )
                      // perf2gb: lazy list — only the rows on screen are
                      // built (500 reminders built every card at once).
                      : Builder(builder: (context) {
                          final rows = remRows<_Group>(groups, (g) => g.items);
                          return ListView.builder(
                            padding: const EdgeInsets.fromLTRB(
                                Gap.md, Gap.sm, Gap.md, 96),
                            itemCount: rows.length,
                            itemBuilder: (context, i) {
                              final r = rows[i];
                              return switch (r.kind) {
                                RemRowKind.header => _SectionHeader(
                                    label: r.group.label(t), tint: r.group.tint),
                                RemRowKind.card =>
                                  _ReminderCard(item: r.item!, group: r.group.kind),
                                RemRowKind.gap => const SizedBox(height: Gap.sm),
                              };
                            },
                          );
                        }),
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
    // perf2gb: each item's next/overdue fire time once (the sort used to
    // recompute both for every comparison: ~9k rule evaluations for 500).
    final nextOf = Map<Map<String, dynamic>, DateTime?>.identity();
    final overOf = Map<Map<String, dynamic>, DateTime?>.identity();
    DateTime? nx(Map<String, dynamic> it) =>
        nextOf.putIfAbsent(it, () => nextFireOf(it['data'], now));
    DateTime? ov(Map<String, dynamic> it) =>
        overOf.putIfAbsent(it, () => overdueFireOf(it['data'], now));
    for (final it in items) {
      final d = it['data'] as Map<String, dynamic>;
      if (d['done'] == true) {
        done.add(it);
        continue;
      }
      final next = nx(it);
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
      final da = nx(a);
      final db = nx(b);
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    }

    int byOverdue(Map<String, dynamic> a, Map<String, dynamic> b) {
      final da = ov(a);
      final db = ov(b);
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    }

    overdue.sort(byOverdue);
    today.sort(byNext);
    upcoming.sort(byNext);
    return [
      _Group('overdue', overdue, Theme.of(context).colorScheme.error),
      _Group('today', today, Brand.blue),
      _Group('upcoming', upcoming, Brand.purple),
      _Group('nodate', noDate, Theme.of(context).colorScheme.onSurfaceVariant),
      _Group('done', done, AssistoTokens.of(context).success),
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
      // qa1: {} not null (the API used to 400 on null; see tests_qa1_reminders)
      'recurrence_rule': parsed.recurrence?.toJson() ?? <String, dynamic>{},
      'date_only': parsed.dateOnly,
      'done': false,
      'source': 'nlp',
      if (link != null) 'link': link,
    };
    final created = await app.reminders.add(payload);
    final lid = created['localId'];
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
/// perf2gb: one row of the lazy reminders list.
enum RemRowKind { header, card, gap }

class RemRow<G> {
  const RemRow(this.kind, this.group, [this.item]);
  final RemRowKind kind;
  final G group;
  final Map<String, dynamic>? item;
}

/// Groups -> flat rows (header, its cards, a gap); empty groups are skipped.
@visibleForTesting
List<RemRow<G>> remRows<G>(
    List<G> groups, List<Map<String, dynamic>> Function(G) itemsOf) {
  final rows = <RemRow<G>>[];
  for (final g in groups) {
    final items = itemsOf(g);
    if (items.isEmpty) continue;
    rows.add(RemRow(RemRowKind.header, g));
    for (final it in items) {
      rows.add(RemRow(RemRowKind.card, g, it));
    }
    rows.add(RemRow(RemRowKind.gap, g));
  }
  return rows;
}

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
                ?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Brand.onTint(context, tint))),
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
                semanticLabel: (d['title'] ?? '').toString(),
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
                    const SizedBox(height: Gap.xxs),
                    Wrap(
                      spacing: Gap.sm,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (next != null)
                          _MetaChip(
                            icon: Icons.schedule_rounded,
                            label: _whenLabel(context, next, d),
                            tint: group == 'overdue'
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        if (rule != null)
                          _MetaChip(
                            icon: Icons.repeat_rounded,
                            label: recurrenceLabel(t, rule),
                            tint: Brand.onTint(context, Brand.purple),
                          ),
                        if (link != null)
                          _MetaChip(
                            icon: _linkIcon(link['type'] as String?),
                            label: (link['label'] ?? '').toString(),
                            tint: Brand.onTint(context, Brand.blue),
                          ),
                        if ((d['priority'] ?? 'none') == 'high')
                          _MetaChip(
                            icon: Icons.flag_rounded,
                            label: t.remPriorityHigh,
                            tint: AssistoTokens.of(context).warning,
                          ),
                        if ((d['category'] ?? '').toString().isNotEmpty)
                          _MetaChip(
                            icon: Icons.label_outline_rounded,
                            label: (d['category']).toString(),
                            tint: Brand.onTint(context, Brand.cyan),
                          ),
                      ],
                    ),
                    if ((d['notes'] ?? '').toString().isNotEmpty) ...[
                      const SizedBox(height: Gap.xxs),
                      Text((d['notes']).toString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AType.bodySmall.copyWith(color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
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
                          const Icon(Icons.snooze_rounded, size: 18),
                          const SizedBox(width: Gap.sm),
                          Text(t.remSnooze),
                        ])),
                  PopupMenuItem(
                      value: 'priority',
                      child: Row(children: [
                        Icon(
                            (d['priority'] ?? 'none') == 'high'
                                ? Icons.flag_rounded
                                : Icons.outlined_flag_rounded,
                            size: 18),
                        const SizedBox(width: Gap.sm),
                        Text((d['priority'] ?? 'none') == 'high'
                            ? t.remPriorityClear
                            : t.remPrioritySet),
                      ])),
                  PopupMenuItem(
                      value: 'category',
                      child: Row(children: [
                        const Icon(Icons.label_outline_rounded, size: 18),
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
    final timeStr = DateFormat('h:mm a', appDateLocale(context)).format(dt);
    if (sameDay) return dateOnly ? t.remGroupToday : '${t.remGroupToday}, $timeStr';
    if (isTomorrow) {
      return dateOnly ? t.remTomorrow : '${t.remTomorrow}, $timeStr';
    }
    return dateOnly
        ? DateFormat('d MMM', appDateLocale(context)).format(dt)
        : DateFormat('d MMM, h:mm a', appDateLocale(context)).format(dt);
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
              '${t.remSnoozedTo} ${DateFormat('d MMM, h:mm a', appDateLocale(context)).format(chosen)}')));
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
      return Icons.person_outline_rounded;
    case 'bill':
      return Icons.receipt_long_rounded;
    case 'document':
      return Icons.folder_rounded;
    case 'event':
      return Icons.event_rounded;
    default:
      return Icons.link_rounded;
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

// ---------------------------------------------------------------- notif banner
/// Dismissible strip shown when the OS is blocking notifications (Android 13+,
/// POST_NOTIFICATIONS denied). Without it a user who declined the prompt gets
/// NO reminder alerts and no clue why. Hidden on Android<13 / iOS where the
/// permission is auto-granted (Notifications.isEnabled returns true there).
///
/// WCAG: errorContainer / onErrorContainer pair (AA both themes), icon paired
/// with text (never colour-only). Copy comes from the ARB — no literals.
class _NotifPermBanner extends StatelessWidget {
  final Future<void> Function() onEnable;
  final VoidCallback onDismiss;
  const _NotifPermBanner({required this.onEnable, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.notifications_off_rounded,
                size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: Gap.xxs),
                  Text(t.remNotifBannerTitle,
                      style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700,
                          color: scheme.onErrorContainer)),
                  const SizedBox(height: Gap.xxs),
                  Text(t.remNotifBannerBody,
                      style: AType.bodySmall.copyWith(color: scheme.onErrorContainer)),
                  const SizedBox(height: Gap.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: onEnable,
                      icon: const Icon(Icons.settings_rounded, size: 16),
                      label: Text(t.remNotifBannerCta),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                            horizontal: Gap.sm, vertical: 0),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: t.close,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              color: scheme.onErrorContainer,
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
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
      Flexible(
          child: Text(label,
              style: AType.bodySmall
                  .copyWith(color: tint, fontFeatures: AFonts.tabular))), // qa1
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
            prefixIcon: const Icon(Icons.edit_calendar_rounded),
            suffixIcon: IconButton(
              tooltip: AppLocalizations.of(context).done,
              icon: const Icon(Icons.check_rounded),
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
