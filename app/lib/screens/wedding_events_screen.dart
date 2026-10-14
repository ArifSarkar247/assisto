import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/wedding_engine.dart';

/// WEDDING & EVENTS — ADVANCED (#189, SPEC v2.1 §20).
///
/// A thin, honest event planner, all computed on-device and mirrored VERBATIM
/// from backend/core/logic/wedding_events.py:
///   • Guest list        — RSVP tally (yes/no/maybe/invited) + confirmed vs
///     expected head count (honest: 'maybe' is NOT counted as confirmed).
///   • Budget tracker     — per-category estimated vs actual (INTEGER POISHA),
///     totals, variance, and an HONEST over-budget warning. Holds no money.
///   • Task / vendor list — due dates with HONEST overdue (device clock; a done
///     or undated task is never overdue).
///   • Countdown          — whole days to the event date.
///
/// Honest states: welcome (first use) · loading · error. ZERO Bangla literals —
/// every string is an AppLocalizations getter; ৳ is a currency glyph only.
///
/// Persistence (generic api helpers, NO api.dart edit):
///   listItems('wedding/event')  → [{id, title, event_date}]  (single row)
///   listItems('wedding/guests') → [{id, name, rsvp, plus_ones}]
///   listItems('wedding/budget') → [{id, category, estimated, actual}]
///   listItems('wedding/tasks')  → [{id, title, vendor, due_date, done}]
/// create/update/deleteItem on the same paths; each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection.
class WeddingEventsScreen extends StatefulWidget {
  const WeddingEventsScreen({super.key});
  @override
  State<WeddingEventsScreen> createState() => _WeddingEventsScreenState();
}

const String _eventPath = 'wedding/event';
const String _guestPath = 'wedding/guests';
const String _budgetPath = 'wedding/budget';
const String _taskPath = 'wedding/tasks';

class _WeddingEventsScreenState extends State<WeddingEventsScreen> {
  List<Map<String, dynamic>> _event = [];
  List<Map<String, dynamic>> _guests = [];
  List<Map<String, dynamic>> _budget = [];
  List<Map<String, dynamic>> _tasks = [];
  bool _loading = true, _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      final res = await Future.wait([
        api.listItems(_eventPath),
        api.listItems(_guestPath),
        api.listItems(_budgetPath),
        api.listItems(_taskPath),
      ]);
      _event = res[0];
      _guests = res[1];
      _budget = res[2];
      _tasks = res[3];
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic>? get _eventRow => _event.isEmpty ? null : _event.first;

  bool get _empty =>
      _event.isEmpty &&
      _guests.isEmpty &&
      _budget.isEmpty &&
      _tasks.isEmpty;

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.weddingTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.weddingTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.weddingLoadError,
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(tr.retry),
          ),
        ),
      );
    }
    if (_empty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.weddingTitle)),
        body: StateMessage(
          icon: Icons.celebration_outlined,
          title: tr.weddingWelcomeTitle,
          message: tr.weddingWelcomeBody,
          action: FilledButton.icon(
            onPressed: _editEvent,
            icon: const Icon(Icons.event),
            label: Text(tr.weddingSetEvent),
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.weddingTitle),
          actions: [
            IconButton(
              icon: const Icon(Icons.edit_calendar_outlined),
              tooltip: tr.weddingSetEvent,
              onPressed: _editEvent,
            ),
          ],
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(text: tr.weddingTabOverview),
            Tab(text: tr.weddingTabGuests),
            Tab(text: tr.weddingTabBudget),
            Tab(text: tr.weddingTabTasks),
          ]),
        ),
        body: TabBarView(children: [
          _OverviewTab(event: _eventRow, guests: _guests, budget: _budget,
              tasks: _tasks, onEditEvent: _editEvent),
          _GuestsTab(guests: _guests, onChanged: _load),
          _BudgetTab(rows: _budget, onChanged: _load),
          _TasksTab(tasks: _tasks, onChanged: _load),
        ]),
      ),
    );
  }

  Future<void> _editEvent() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EventEditor(existing: _eventRow),
    );
    if (changed == true) await _load();
  }
}

// ======================= shared helpers =======================
void _toast(BuildContext context, String m) =>
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));

Future<bool> _confirmDelete(
    BuildContext context, String path, dynamic id, String body) async {
  final tr = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  final api = context.read<AppState>().api;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr.weddingDeleteTitle),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr.delete),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  if (id is int) await api.deleteItem(path, id);
  return true;
}

// ======================= EVENT editor =======================
class _EventEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _EventEditor({this.existing});
  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor> {
  late final TextEditingController _title;
  DateTime? _date;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: (e?['title'] ?? '').toString());
    _date = WeddingEngine.parseDate(e?['event_date']);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (d != null) setState(() => _date = d);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr.weddingSetEvent,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _title,
          decoration: InputDecoration(labelText: tr.weddingEventNameLabel),
        ),
        const SizedBox(height: Gap.md),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event),
          title: Text(_date == null
              ? tr.weddingNoDate
              : WeddingEngine.isoDate(_date!)),
          trailing: _date == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _date = null)),
          onTap: _pickDate,
        ),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr.save),
          ),
        ),
      ]),
    );
  }

  Future<void> _save() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    setState(() => _saving = true);
    final body = {
      'title': _title.text.trim(),
      'event_date': _date == null ? null : WeddingEngine.isoDate(_date!),
    };
    try {
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem(_eventPath, id, body);
      } else {
        await api.createItem(_eventPath, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _toast(context, tr.saveFailed);
      }
    }
  }
}

// ======================= OVERVIEW =======================
class _OverviewTab extends StatelessWidget {
  final Map<String, dynamic>? event;
  final List<Map<String, dynamic>> guests;
  final List<Map<String, dynamic>> budget;
  final List<Map<String, dynamic>> tasks;
  final Future<void> Function() onEditEvent;
  const _OverviewTab(
      {required this.event,
      required this.guests,
      required this.budget,
      required this.tasks,
      required this.onEditEvent});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cd = WeddingEngine.countdown(event?['event_date'], DateTime.now());
    final gs = WeddingEngine.guestSummary(guests);
    final bs = WeddingEngine.budgetSummary(budget);
    final tb = WeddingEngine.taskBoard(tasks, DateTime.now());
    final eventName = (event?['title'] ?? '').toString();
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 32),
      children: [
        // countdown hero
        Card(
          color: scheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(children: [
              Text(
                  eventName.isEmpty ? tr.weddingYourEvent : eventName,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.sm),
              Text(_countdownBig(tr, cd),
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: Gap.xs),
              Text(_countdownSub(tr, cd),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onPrimaryContainer)),
            ]),
          ),
        ),
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
            child: _StatCard(
              icon: Icons.groups_2_outlined,
              label: tr.weddingConfirmedGuests,
              value: gs.confirmedHeads.toString(),
              hint: tr.weddingExpectedGuests(gs.expectedHeads),
            ),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: _StatCard(
              icon: Icons.task_alt,
              label: tr.weddingOpenTasks,
              value: tb.all.where((t) => t.state != 'done').length.toString(),
              hint: tb.overdueCount > 0
                  ? tr.weddingOverdueTasks(tb.overdueCount)
                  : tr.weddingNoOverdue,
              tint: tb.overdueCount > 0 ? scheme.error : null,
            ),
          ),
        ]),
        const SizedBox(height: Gap.md),
        // budget snapshot
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr.weddingBudgetSnapshot,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.sm),
                _kv(context, tr.weddingEstimated,
                    WeddingEngine.fmtPoisha(bs.totalEstimated)),
                _kv(context, tr.weddingActual,
                    WeddingEngine.fmtPoisha(bs.totalActual)),
                const Divider(),
                if (bs.overBudget)
                  _overBanner(context,
                      tr.weddingOverBy(WeddingEngine.fmtPoisha(bs.overAmount)))
                else
                  _kv(context, tr.weddingRemaining,
                      WeddingEngine.fmtPoisha(-bs.totalVariance),
                      good: true),
                const SizedBox(height: Gap.sm),
                Text(tr.weddingNoMoneyNote,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _kv(BuildContext context, String k, String v, {bool good = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(k, style: TextStyle(color: scheme.onSurfaceVariant)),
        Text(v,
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: good ? scheme.primary : null)),
      ]),
    );
  }

  Widget _overBanner(BuildContext context, String msg) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded,
            size: 18, color: scheme.onErrorContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(msg,
              style: TextStyle(
                  color: scheme.onErrorContainer, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  String _countdownBig(AppLocalizations tr, Countdown cd) {
    switch (cd.state) {
      case 'future':
        return cd.days.toString();
      case 'today':
        return tr.weddingToday;
      case 'past':
        return tr.weddingDone;
      default:
        return '—';
    }
  }

  String _countdownSub(AppLocalizations tr, Countdown cd) {
    switch (cd.state) {
      case 'future':
        return tr.weddingDaysToGo(cd.days!);
      case 'today':
        return tr.weddingBigDay;
      case 'past':
        return tr.weddingDaysAgo(cd.daysAgo!);
      default:
        return tr.weddingSetDatePrompt;
    }
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String hint;
  final Color? tint;
  const _StatCard(
      {required this.icon,
      required this.label,
      required this.value,
      required this.hint,
      this.tint});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: tint ?? scheme.primary),
          const SizedBox(height: Gap.sm),
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(hint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: tint ?? scheme.onSurfaceVariant, fontSize: 12)),
        ]),
      ),
    );
  }
}

// ======================= GUESTS =======================
class _GuestsTab extends StatelessWidget {
  final List<Map<String, dynamic>> guests;
  final Future<void> Function() onChanged;
  const _GuestsTab({required this.guests, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final s = WeddingEngine.guestSummary(guests);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(tr.weddingAddGuest),
      ),
      body: guests.isEmpty
          ? StateMessage(
              icon: Icons.groups_2_outlined,
              title: tr.weddingGuestsEmptyTitle,
              message: tr.weddingGuestsEmptyBody,
            )
          : RefreshIndicator(
              onRefresh: onChanged,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.md),
                      child: Wrap(
                        spacing: Gap.sm,
                        runSpacing: Gap.sm,
                        children: [
                          _chip(context, tr.weddingRsvpYes, s.counts['yes']!),
                          _chip(context, tr.weddingRsvpMaybe, s.counts['maybe']!),
                          _chip(context, tr.weddingRsvpNo, s.counts['no']!),
                          _chip(context, tr.weddingRsvpInvited,
                              s.counts['invited']!),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  for (final g in guests)
                    Card(
                      margin: const EdgeInsets.only(bottom: Gap.sm),
                      child: ListTile(
                        title: Text(
                            (g['name'] ?? '').toString().isEmpty
                                ? tr.weddingUnnamed
                                : g['name'].toString(),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(_guestSub(tr, g)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (await _confirmDelete(context, _guestPath,
                                g['id'], tr.weddingDeleteGuestBody)) {
                              await onChanged();
                            }
                          },
                        ),
                        onTap: () => _edit(context, g),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  String _guestSub(AppLocalizations tr, Map<String, dynamic> g) {
    final rsvp = (g['rsvp'] ?? 'invited').toString();
    final plus = int.tryParse('${g['plus_ones'] ?? 0}') ?? 0;
    final rsvpText = _rsvpLabel(tr, rsvp);
    return plus > 0 ? '$rsvpText · ${tr.weddingPlusOnes(plus)}' : rsvpText;
  }

  Widget _chip(BuildContext context, String label, int n) {
    return Chip(label: Text('$label  $n'));
  }

  Future<void> _edit(BuildContext context, Map<String, dynamic>? existing) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _GuestEditor(existing: existing, guests: guests),
    );
    if (changed == true) await onChanged();
  }
}

String _rsvpLabel(AppLocalizations tr, String r) {
  switch (r) {
    case 'yes':
      return tr.weddingRsvpYes;
    case 'no':
      return tr.weddingRsvpNo;
    case 'maybe':
      return tr.weddingRsvpMaybe;
    default:
      return tr.weddingRsvpInvited;
  }
}

class _GuestEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final List<Map<String, dynamic>> guests;
  const _GuestEditor({this.existing, required this.guests});
  @override
  State<_GuestEditor> createState() => _GuestEditorState();
}

class _GuestEditorState extends State<_GuestEditor> {
  late final TextEditingController _name;
  late final TextEditingController _plus;
  String _rsvp = 'invited';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: (e?['name'] ?? '').toString());
    _plus = TextEditingController(text: (e?['plus_ones'] ?? '').toString());
    final r = (e?['rsvp'] ?? 'invited').toString();
    if (WeddingEngine.rsvpStates.contains(r)) _rsvp = r;
  }

  @override
  void dispose() {
    _name.dispose();
    _plus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
            widget.existing == null
                ? tr.weddingAddGuest
                : tr.weddingEditGuest,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _name,
          decoration: InputDecoration(labelText: tr.weddingGuestNameLabel),
        ),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<String>(
          initialValue: _rsvp,
          decoration: InputDecoration(labelText: tr.weddingRsvpLabel),
          items: [
            for (final r in WeddingEngine.rsvpStates)
              DropdownMenuItem(value: r, child: Text(_rsvpLabel(tr, r))),
          ],
          onChanged: (v) => setState(() => _rsvp = v ?? 'invited'),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _plus,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: tr.weddingPlusOnesLabel),
        ),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr.save),
          ),
        ),
      ]),
    );
  }

  Future<void> _save() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast(context, tr.weddingNameRequired);
      return;
    }
    final dup = widget.guests.any((g) =>
        g['id'] != widget.existing?['id'] &&
        (g['name'] ?? '').toString().toLowerCase() == name.toLowerCase());
    if (dup) {
      _toast(context, tr.weddingDuplicateName);
      return;
    }
    setState(() => _saving = true);
    final body = {
      'name': name,
      'rsvp': _rsvp,
      'plus_ones': int.tryParse(_plus.text.trim()) ?? 0,
    };
    try {
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem(_guestPath, id, body);
      } else {
        await api.createItem(_guestPath, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _toast(context, tr.saveFailed);
      }
    }
  }
}

// ======================= BUDGET =======================
class _BudgetTab extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final Future<void> Function() onChanged;
  const _BudgetTab({required this.rows, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = WeddingEngine.budgetSummary(rows);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add),
        label: Text(tr.weddingAddBudget),
      ),
      body: rows.isEmpty
          ? StateMessage(
              icon: Icons.account_balance_wallet_outlined,
              title: tr.weddingBudgetEmptyTitle,
              message: tr.weddingBudgetEmptyBody,
            )
          : RefreshIndicator(
              onRefresh: onChanged,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  Card(
                    color: s.overBudget ? scheme.errorContainer : null,
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(tr.weddingEstimated),
                              Text(WeddingEngine.fmtPoisha(s.totalEstimated),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(tr.weddingActual),
                              Text(WeddingEngine.fmtPoisha(s.totalActual),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                          const Divider(),
                          Row(children: [
                            Icon(
                                s.overBudget
                                    ? Icons.warning_amber_rounded
                                    : Icons.check_circle_outline,
                                color: s.overBudget
                                    ? scheme.onErrorContainer
                                    : scheme.primary),
                            const SizedBox(width: Gap.sm),
                            Expanded(
                              child: Text(
                                s.overBudget
                                    ? tr.weddingOverBy(WeddingEngine.fmtPoisha(
                                        s.overAmount))
                                    : tr.weddingRemainingAmt(
                                        WeddingEngine.fmtPoisha(
                                            -s.totalVariance)),
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: s.overBudget
                                        ? scheme.onErrorContainer
                                        : scheme.primary),
                              ),
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  for (final c in s.categories)
                    Card(
                      margin: const EdgeInsets.only(bottom: Gap.sm),
                      child: ListTile(
                        title: Text(_catLabel(tr, c.category)),
                        subtitle: Text(tr.weddingEstVsAct(
                            WeddingEngine.fmtPoisha(c.estimated),
                            WeddingEngine.fmtPoisha(c.actual))),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (c.over)
                            Icon(Icons.warning_amber_rounded,
                                size: 18, color: scheme.error),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              if (await _confirmDelete(context, _budgetPath,
                                  _idOf(c.category), tr.weddingDeleteBudgetBody)) {
                                await onChanged();
                              }
                            },
                          ),
                        ]),
                        onTap: () => _edit(context, _rawOf(c.category)),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  // one row per category key in our generic store
  Map<String, dynamic>? _rawOf(String cat) {
    for (final r in rows) {
      if ((r['category'] ?? 'other').toString() == cat) return r;
    }
    return null;
  }

  dynamic _idOf(String cat) => _rawOf(cat)?['id'];

  Future<void> _edit(BuildContext context, Map<String, dynamic>? existing) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BudgetEditor(existing: existing),
    );
    if (changed == true) await onChanged();
  }
}

String _catLabel(AppLocalizations tr, String key) {
  switch (key) {
    case 'venue':
      return tr.weddingCatVenue;
    case 'food':
      return tr.weddingCatFood;
    case 'decor':
      return tr.weddingCatDecor;
    case 'photography':
      return tr.weddingCatPhotography;
    case 'attire':
      return tr.weddingCatAttire;
    case 'gifts':
      return tr.weddingCatGifts;
    case 'transport':
      return tr.weddingCatTransport;
    case 'other':
      return tr.weddingCatOther;
    default:
      return key; // free-text category echoed verbatim
  }
}

class _BudgetEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _BudgetEditor({this.existing});
  @override
  State<_BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends State<_BudgetEditor> {
  late final TextEditingController _estimated;
  late final TextEditingController _actual;
  String _category = 'venue';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _estimated =
        TextEditingController(text: _takaOf(e?['estimated']));
    _actual = TextEditingController(text: _takaOf(e?['actual']));
    final c = (e?['category'] ?? 'venue').toString();
    if (WeddingEngine.categoryKeys.contains(c)) _category = c;
  }

  // display stored poisha back as taka for editing
  String _takaOf(dynamic v) {
    if (v == null || v == '') return '';
    final p = WeddingEngine.toPoisha(v);
    if (p == 0) return '';
    return (p / 100).toStringAsFixed(2);
  }

  @override
  void dispose() {
    _estimated.dispose();
    _actual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
            widget.existing == null
                ? tr.weddingAddBudget
                : tr.weddingEditBudget,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.lg),
        DropdownButtonFormField<String>(
          initialValue: _category,
          decoration: InputDecoration(labelText: tr.weddingCategoryLabel),
          items: [
            for (final k in WeddingEngine.categoryKeys)
              DropdownMenuItem(value: k, child: Text(_catLabel(tr, k))),
          ],
          onChanged: (v) => setState(() => _category = v ?? 'other'),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _estimated,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr.weddingEstimatedLabel),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _actual,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr.weddingActualLabel),
        ),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr.save),
          ),
        ),
      ]),
    );
  }

  Future<void> _save() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    setState(() => _saving = true);
    // store INTEGER POISHA so the backend/engine read it back exactly
    final body = {
      'category': _category,
      'estimated': WeddingEngine.toPoisha(_estimated.text.trim()),
      'actual': WeddingEngine.toPoisha(_actual.text.trim()),
    };
    try {
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem(_budgetPath, id, body);
      } else {
        await api.createItem(_budgetPath, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _toast(context, tr.saveFailed);
      }
    }
  }
}

// ======================= TASKS =======================
class _TasksTab extends StatelessWidget {
  final List<Map<String, dynamic>> tasks;
  final Future<void> Function() onChanged;
  const _TasksTab({required this.tasks, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final board = WeddingEngine.taskBoard(tasks, DateTime.now());
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add_task),
        label: Text(tr.weddingAddTask),
      ),
      body: board.all.isEmpty
          ? StateMessage(
              icon: Icons.checklist_outlined,
              title: tr.weddingTasksEmptyTitle,
              message: tr.weddingTasksEmptyBody,
            )
          : RefreshIndicator(
              onRefresh: onChanged,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  if (board.overdueCount > 0)
                    Card(
                      color: scheme.errorContainer,
                      margin: const EdgeInsets.only(bottom: Gap.md),
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.md),
                        child: Row(children: [
                          Icon(Icons.warning_amber_rounded,
                              color: scheme.onErrorContainer),
                          const SizedBox(width: Gap.md),
                          Expanded(
                            child: Text(
                                tr.weddingOverdueBanner(board.overdueCount),
                                style: TextStyle(
                                    color: scheme.onErrorContainer)),
                          ),
                        ]),
                      ),
                    ),
                  for (final s in board.all)
                    _TaskCard(
                      status: s,
                      onToggle: () => _toggle(context, s),
                      onDelete: () async {
                        if (await _confirmDelete(context, _taskPath, s.id,
                            tr.weddingDeleteTaskBody)) {
                          await onChanged();
                        }
                      },
                      onTap: () => _edit(context, _rawOf(s.id)),
                    ),
                ],
              ),
            ),
    );
  }

  Map<String, dynamic>? _rawOf(dynamic id) {
    for (final t in tasks) {
      if (t['id'] == id) return t;
    }
    return null;
  }

  Future<void> _toggle(BuildContext context, TaskStatus s) async {
    final api = context.read<AppState>().api;
    final raw = _rawOf(s.id);
    if (raw == null || raw['id'] is! int) return;
    try {
      await api.updateItem(_taskPath, raw['id'] as int, {
        'title': raw['title'],
        'vendor': raw['vendor'],
        'due_date': raw['due_date'],
        'done': !s.done,
      });
      await onChanged();
    } catch (_) {
      if (context.mounted) {
        _toast(context, AppLocalizations.of(context).saveFailed);
      }
    }
  }

  Future<void> _edit(BuildContext context, Map<String, dynamic>? existing) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TaskEditor(existing: existing),
    );
    if (changed == true) await onChanged();
  }
}

class _TaskCard extends StatelessWidget {
  final TaskStatus status;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onTap;
  const _TaskCard(
      {required this.status,
      required this.onToggle,
      required this.onDelete,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = _badge(tr, scheme, status);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        leading: Checkbox(value: status.done, onChanged: (_) => onToggle()),
        title: Text(
          status.title.isEmpty ? tr.weddingUntitledTask : status.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            decoration:
                status.done ? TextDecoration.lineThrough : TextDecoration.none,
          ),
        ),
        subtitle: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Text(label,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          if (status.vendor.isNotEmpty) ...[
            const SizedBox(width: Gap.sm),
            Flexible(
              child: Text(status.vendor,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          ],
        ]),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: onDelete,
        ),
        onTap: onTap,
      ),
    );
  }

  (String, Color) _badge(
      AppLocalizations tr, ColorScheme scheme, TaskStatus s) {
    switch (s.state) {
      case 'done':
        return (tr.weddingStateDone, scheme.primary);
      case 'overdue':
        return (tr.weddingOverdueDays(-s.days!), scheme.error);
      case 'due_today':
        return (tr.weddingDueToday, scheme.tertiary);
      case 'upcoming':
        return (tr.weddingDueInDays(s.days!), scheme.secondary);
      default:
        return (tr.weddingNoDue, scheme.onSurfaceVariant);
    }
  }
}

class _TaskEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _TaskEditor({this.existing});
  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  late final TextEditingController _title;
  late final TextEditingController _vendor;
  DateTime? _due;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: (e?['title'] ?? '').toString());
    _vendor = TextEditingController(text: (e?['vendor'] ?? '').toString());
    _due = WeddingEngine.parseDate(e?['due_date']);
  }

  @override
  void dispose() {
    _title.dispose();
    _vendor.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (d != null) setState(() => _due = d);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
            widget.existing == null
                ? tr.weddingAddTask
                : tr.weddingEditTask,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _title,
          decoration: InputDecoration(labelText: tr.weddingTaskTitleLabel),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _vendor,
          decoration: InputDecoration(labelText: tr.weddingVendorLabel),
        ),
        const SizedBox(height: Gap.md),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event),
          title: Text(_due == null
              ? tr.weddingNoDue
              : WeddingEngine.isoDate(_due!)),
          trailing: _due == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _due = null)),
          onTap: _pickDate,
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr.save),
          ),
        ),
      ]),
    );
  }

  Future<void> _save() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    if (_title.text.trim().isEmpty) {
      _toast(context, tr.weddingTaskTitleRequired);
      return;
    }
    setState(() => _saving = true);
    final body = {
      'title': _title.text.trim(),
      'vendor': _vendor.text.trim(),
      'due_date': _due == null ? null : WeddingEngine.isoDate(_due!),
      'done': widget.existing?['done'] ?? false,
    };
    try {
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem(_taskPath, id, body);
      } else {
        await api.createItem(_taskPath, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _toast(context, tr.saveFailed);
      }
    }
  }
}
