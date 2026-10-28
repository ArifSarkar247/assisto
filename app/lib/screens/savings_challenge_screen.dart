import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// SAVINGS CHALLENGE — ADVANCED (#171, SPEC v2.1).
///
/// Gamified saving for the ordinary saver: pick a challenge, the engine builds a
/// fixed DEPOSIT SCHEDULE, you log the deposits you actually made, and it shows
/// — honestly — progress %, streak, projected final amount, and whether you are
/// BEHIND / ON-TRACK / AHEAD of plan as of today.
///
/// Three challenge types:
///   week52  — the classic 52-week challenge (week N saves N × base).
///   fixed   — a fixed amount every daily/weekly/monthly period for N periods.
///   roundup — an open round-up jar with a gentle per-day target (no fake jar).
///
/// All MONEY is INTEGER POISHA. The on-screen math mirrors backend/core/logic/
/// savings_challenge.py VERBATIM (schedule generation, expected-by-now, pace
/// projection capped at goal) so the live status is deterministic and identical
/// offline. The app HOLDS NO MONEY — it only shows your progress.
///
/// Honest states: welcome (first use) · loading · error · not-started. Status
/// compares deposits to what the plan EXPECTED by today, never to the grand
/// total, so an early saver is never told they are "98% behind". ZERO Bangla
/// literals — every string is an AppLocalizations getter; ৳ is a currency glyph.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('savechal/plans')    → [{id, name, kind, base, periods,
///                                       period, start_date}]
///     kind ∈ {week52, fixed, roundup}; period ∈ {daily, weekly, monthly}.
///   listItems('savechal/deposits') → [{id, plan, date, amount}]  date 'YYYY-MM-DD'
/// create/update/deleteItem on the same paths. Each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection (PaCollectionItem
/// precedent).
class SavingsChallengeScreen extends StatefulWidget {
  const SavingsChallengeScreen({super.key});
  @override
  State<SavingsChallengeScreen> createState() => _SavingsChallengeScreenState();
}

const String _plansPath = 'savechal/plans';
const String _depositsPath = 'savechal/deposits';

const List<String> _kindKeys = ['week52', 'fixed', 'roundup'];
const List<String> _periodKeys = ['daily', 'weekly', 'monthly'];

String _kindLabel(AppLocalizations tr, String? k) {
  switch (k) {
    case 'fixed':
      return tr.savechalKindFixed;
    case 'roundup':
      return tr.savechalKindRoundup;
    default:
      return tr.savechalKindWeek52;
  }
}

String _periodLabel(AppLocalizations tr, String? p) {
  switch (p) {
    case 'daily':
      return tr.savechalDaily;
    case 'monthly':
      return tr.savechalMonthly;
    default:
      return tr.savechalWeekly;
  }
}

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

class _SavingsChallengeScreenState extends State<SavingsChallengeScreen> {
  List<Map<String, dynamic>> _plans = [];
  List<Map<String, dynamic>> _deposits = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
        api.listItems(_plansPath),
        api.listItems(_depositsPath),
      ]);
      _plans = res[0];
      _deposits = res[1];
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.savechalTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.savechalTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.savechalLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_plans.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.savechalTitle)),
        body: StateMessage(
          icon: Icons.savings_rounded,
          title: tr.savechalWelcomeTitle,
          message: tr.savechalWelcomeBody,
          action: FilledButton.icon(
            onPressed: _addPlan,
            icon: const Icon(Icons.add_rounded),
            label: Text(tr.savechalStartChallenge),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr.savechalTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPlan,
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.savechalStartChallenge),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          children: [
            for (final p in _plans)
              _PlanCard(
                plan: p,
                deposits: _deposits
                    .where((d) => d['plan'] == p['id'])
                    .toList(),
                onOpen: () => _openPlan(p),
              ),
            const SizedBox(height: Gap.md),
            _noMoneyNote(context, tr.savechalNoMoneyNote),
          ],
        ),
      ),
    );
  }

  Future<void> _openPlan(Map<String, dynamic> plan) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PlanDetailScreen(plan: plan, allDeposits: _deposits),
    ));
    await _load();
  }

  Future<void> _addPlan() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _PlanForm(),
    );
    if (result == null) return;
    try {
      await api.createItem(_plansPath, result);
      await _load();
      if (mounted) _toast(tr.savechalSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

// ======================= plan card (progress summary) =======================
class _PlanCard extends StatelessWidget {
  final Map<String, dynamic> plan;
  final List<Map<String, dynamic>> deposits;
  final VoidCallback onOpen;
  const _PlanCard(
      {required this.plan, required this.deposits, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = _SaveMath.progress(plan, deposits, _today());
    final c = _statusColor(context, p.status);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(p.name,
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              _statusChip(context, p.status),
            ]),
            const SizedBox(height: Gap.xxs),
            Text(_kindLabel(tr, p.kind),
                style:
                    AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            // progress bar (goal-based) or open-ended saved line
            if (p.percent != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(Radii.pill),
                child: LinearProgressIndicator(
                  value: p.percent! / 100.0,
                  minHeight: 8,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: c,
                ),
              ),
              const SizedBox(height: Gap.xs),
              Row(children: [
                Text('${p.percent}%',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, color: c, fontFeatures: AFonts.tabular)),
                const Spacer(),
                Text('${p.savedDisplay} / ${p.goalDisplay}',
                    style: AType.bodySmall.copyWith(fontFeatures: AFonts.tabular, color: scheme.onSurfaceVariant)),
              ]),
            ] else ...[
              Row(children: [
                Icon(Icons.savings_rounded, size: 16, color: c),
                const SizedBox(width: Gap.xs),
                Text(p.savedDisplay,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: scheme.onSurface)),
                const Spacer(),
                Text(tr.savechalOpenEnded,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ],
            const SizedBox(height: Gap.sm),
            Row(children: [
              _miniStat(context, Icons.local_fire_department_rounded,
                  tr.savechalStreakShort(p.streak)),
              const SizedBox(width: Gap.md),
              if (p.goal > 0)
                _miniStat(context, Icons.flag_rounded,
                    tr.savechalProjectedShort(p.projectedDisplay)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _miniStat(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: scheme.onSurfaceVariant),
      const SizedBox(width: 3),
      Flexible(
        child: Text(text,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ),
    ]);
  }
}

// ======================= plan detail =======================
class _PlanDetailScreen extends StatefulWidget {
  final Map<String, dynamic> plan;
  final List<Map<String, dynamic>> allDeposits;
  const _PlanDetailScreen({required this.plan, required this.allDeposits});
  @override
  State<_PlanDetailScreen> createState() => _PlanDetailScreenState();
}

class _PlanDetailScreenState extends State<_PlanDetailScreen> {
  late List<Map<String, dynamic>> _deposits;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _deposits = widget.allDeposits
        .where((d) => d['plan'] == widget.plan['id'])
        .toList();
  }

  Future<void> _reload() async {
    final api = context.read<AppState>().api;
    final all = await api.listItems(_depositsPath);
    setState(() =>
        _deposits = all.where((d) => d['plan'] == widget.plan['id']).toList());
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = _SaveMath.progress(widget.plan, _deposits, _today());
    final c = _statusColor(context, p.status);
    final sorted = [..._deposits]..sort((a, b) =>
        (b['date'] ?? '').toString().compareTo((a['date'] ?? '').toString()));
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: tr.delete,
            onPressed: _confirmDeletePlan,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addDeposit,
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.savechalLogDeposit),
      ),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96)),
        children: [
          // headline status + progress ring-ish bar
          Card(
            color: c.withValues(alpha: 0.10),
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _statusChip(context, p.status),
                    const SizedBox(height: Gap.sm),
                    Text(p.savedDisplay,
                        style: AType.displaySmall.copyWith(fontWeight: FontWeight.bold, color: scheme.onSurface)),
                    Text(
                        p.goal > 0
                            ? tr.savechalOfGoal(p.goalDisplay)
                            : tr.savechalKindRoundup,
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                    if (p.percent != null) ...[
                      const SizedBox(height: Gap.md),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(Radii.pill),
                        child: LinearProgressIndicator(
                          value: p.percent! / 100.0,
                          minHeight: 10,
                          backgroundColor: scheme.surfaceContainerHighest,
                          color: c,
                        ),
                      ),
                      const SizedBox(height: Gap.xs),
                      Text('${p.percent}%',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, color: c, fontFeatures: AFonts.tabular)),
                    ],
                  ]),
            ),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
                child: _statCard(
                    context,
                    tr.savechalExpectedByNow,
                    p.expectedDisplay,
                    scheme.secondary,
                    Icons.schedule_rounded)),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: _statCard(
                    context,
                    p.aheadBy >= 0 ? tr.savechalAheadBy : tr.savechalBehindBy,
                    _SaveMath.fmtPoisha(p.aheadBy.abs().toDouble()),
                    p.aheadBy >= 0 ? Brand.success : scheme.error,
                    p.aheadBy >= 0
                        ? Icons.trending_up_rounded
                        : Icons.trending_down_rounded)),
          ]),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
                child: _statCard(
                    context,
                    tr.savechalStreak,
                    tr.savechalPeriods(p.streak),
                    Brand.purple,
                    Icons.local_fire_department_rounded)),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: _statCard(
                    context,
                    tr.savechalProjected,
                    p.projectedDisplay,
                    scheme.primary,
                    Icons.flag_rounded)),
          ]),
          const SizedBox(height: Gap.lg),
          Text(tr.savechalDeposits,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          if (sorted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.sm),
              child: Text(tr.savechalNoDepositsYet,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          for (final d in sorted)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: ListTile(
                dense: true,
                leading: Icon(Icons.savings_rounded, color: scheme.primary),
                title: Text(_SaveMath.fmtPoisha(
                    _SaveMath.toPoisha(d['amount']).toDouble())),
                subtitle: Text((d['date'] ?? '').toString()),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  tooltip: tr.delete,
                  onPressed: () async {
                    final id = d['id'];
                    if (id is int) {
                      await context
                          .read<AppState>()
                          .api
                          .deleteItem(_depositsPath, id);
                      await _reload();
                    }
                  },
                ),
              ),
            ),
          const SizedBox(height: Gap.lg),
          _noMoneyNote(context, tr.savechalNoMoneyNote),
        ],
      ),
    );
  }

  Future<void> _addDeposit() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DepositForm(defaultDate: _today()),
    );
    if (result == null) return;
    result['plan'] = widget.plan['id'];
    setState(() => _busy = true);
    try {
      await api.createItem(_depositsPath, result);
      await _reload();
      if (mounted) _toast(tr.savechalSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _confirmDeletePlan() async {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final api = context.read<AppState>().api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(tr.savechalDeleteTitle),
        content: Text(tr.savechalDeleteBody((widget.plan['name'] ?? '').toString())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = widget.plan['id'];
    if (id is int) await api.deleteItem(_plansPath, id);
    if (mounted) Navigator.of(context).pop();
  }
}

// ======================= forms =======================
class _PlanForm extends StatefulWidget {
  const _PlanForm();
  @override
  State<_PlanForm> createState() => _PlanFormState();
}

class _PlanFormState extends State<_PlanForm> {
  final _name = TextEditingController();
  final _base = TextEditingController(text: '50');
  final _periods = TextEditingController(text: '12');
  late final _start = TextEditingController(text: _today());
  String _kind = 'week52';
  String _period = 'weekly';

  @override
  void dispose() {
    _name.dispose();
    _base.dispose();
    _periods.dispose();
    _start.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final nameOk = _name.text.trim().isNotEmpty;
    final baseOk = _SaveMath.toPoisha(_base.text) > 0;
    final periodsOk =
        _kind != 'fixed' || (int.tryParse(_periods.text.trim()) ?? 0) > 0;

    // live preview total so the saver sees the goal before committing
    final preview = _SaveMath.progress({
      'name': _name.text,
      'kind': _kind,
      'base': _base.text,
      'periods': _periods.text,
      'period': _period,
      'start_date': _start.text,
    }, const [], _today());

    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.savechalStartChallenge,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: tr.savechalName,
                    hintText: tr.savechalNameHint,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                decoration: InputDecoration(
                    labelText: tr.savechalType,
                    border: const OutlineInputBorder()),
                items: [
                  for (final k in _kindKeys)
                    DropdownMenuItem(value: k, child: Text(_kindLabel(tr, k))),
                ],
                onChanged: (v) => setState(() => _kind = v ?? 'week52'),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _base,
                onChanged: (_) => setState(() {}),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: _kind == 'roundup'
                        ? tr.savechalDailyTarget
                        : tr.savechalBaseAmount,
                    helperText: _kind == 'week52'
                        ? tr.savechalWeek52Helper
                        : (_kind == 'roundup'
                            ? tr.savechalRoundupHelper
                            : null),
                    prefixText: '৳ ',
                    border: const OutlineInputBorder()),
              ),
              if (_kind == 'fixed') ...[
                const SizedBox(height: Gap.md),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _period,
                      decoration: InputDecoration(
                          labelText: tr.savechalEvery,
                          border: const OutlineInputBorder()),
                      items: [
                        for (final pk in _periodKeys)
                          DropdownMenuItem(
                              value: pk, child: Text(_periodLabel(tr, pk))),
                      ],
                      onChanged: (v) =>
                          setState(() => _period = v ?? 'weekly'),
                    ),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: TextField(
                      controller: _periods,
                      onChanged: (_) => setState(() {}),
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                          labelText: tr.savechalHowMany,
                          border: const OutlineInputBorder()),
                    ),
                  ),
                ]),
              ],
              const SizedBox(height: Gap.md),
              TextField(
                controller: _start,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                    labelText: tr.savechalStartDate,
                    hintText: tr.savechalDateHint,
                    border: const OutlineInputBorder()),
              ),
              if (preview.goal > 0) ...[
                const SizedBox(height: Gap.md),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Gap.md),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Text(tr.savechalGoalPreview(preview.goalDisplay),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr.cancel)),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton(
                    onPressed: (nameOk && baseOk && periodsOk)
                        ? () => Navigator.pop(context, <String, dynamic>{
                              'name': _name.text.trim(),
                              'kind': _kind,
                              'base': _base.text.trim(),
                              if (_kind == 'fixed') ...{
                                'period': _period,
                                'periods': _periods.text.trim(),
                              },
                              'start_date': _start.text.trim(),
                            })
                        : null,
                    child: Text(tr.save),
                  ),
                ),
              ]),
            ]),
      ),
    );
  }
}

class _DepositForm extends StatefulWidget {
  final String defaultDate;
  const _DepositForm({required this.defaultDate});
  @override
  State<_DepositForm> createState() => _DepositFormState();
}

class _DepositFormState extends State<_DepositForm> {
  final _amount = TextEditingController();
  late final _date = TextEditingController(text: widget.defaultDate);

  @override
  void dispose() {
    _amount.dispose();
    _date.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final amountOk = _SaveMath.toPoisha(_amount.text) > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.savechalLogDeposit,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _amount,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr.savechalAmount,
                    prefixText: '৳ ',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _date,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                    labelText: tr.savechalDate,
                    hintText: tr.savechalDateHint,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr.cancel)),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton(
                    onPressed: amountOk
                        ? () => Navigator.pop(context, <String, dynamic>{
                              'amount': _amount.text.trim(),
                              'date': _date.text.trim(),
                            })
                        : null,
                    child: Text(tr.save),
                  ),
                ),
              ]),
            ]),
      ),
    );
  }
}

// ======================= shared small helpers =======================
Color _statusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  switch (status) {
    case 'ahead':
    case 'complete':
      return Brand.success;
    case 'behind':
      return scheme.error;
    case 'not_started':
      return scheme.onSurfaceVariant;
    default:
      return scheme.primary; // on_track
  }
}

Widget _statusChip(BuildContext context, String status) {
  final tr = AppLocalizations.of(context);
  final c = _statusColor(context, status);
  final String label;
  switch (status) {
    case 'ahead':
      label = tr.savechalStatusAhead;
      break;
    case 'behind':
      label = tr.savechalStatusBehind;
      break;
    case 'complete':
      label = tr.savechalStatusComplete;
      break;
    case 'not_started':
      label = tr.savechalStatusNotStarted;
      break;
    default:
      label = tr.savechalStatusOnTrack;
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    child: Text(label,
        style: AType.bodySmall.copyWith(color: c, fontWeight: FontWeight.w700)),
  );
}

Widget _statCard(BuildContext context, String label, String value, Color color,
    IconData icon) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(label,
                style:
                    AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: Gap.xs),
        Text(value,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold, color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ]),
    ),
  );
}

Widget _noMoneyNote(BuildContext context, String text) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    color: scheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Row(children: [
        Icon(Icons.shield_rounded, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style:
                  AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ]),
    ),
  );
}

// ===================================================================
// _SaveMath — deterministic mirror of backend/core/logic/savings_challenge.py.
// All INTEGER POISHA. Schedule from the plan's own start_date; expected-by-now
// from a passed-in today; pace projection capped honestly at the goal.
// ===================================================================
class _Progress {
  final String name;
  final String kind;
  final int saved;
  final String savedDisplay;
  final int goal;
  final String goalDisplay;
  final int? percent;
  final int expected;
  final String expectedDisplay;
  final int elapsedPeriods;
  final int totalPeriods;
  final int aheadBy;
  final int projected;
  final String projectedDisplay;
  final int streak;
  final String status;
  _Progress(
      this.name,
      this.kind,
      this.saved,
      this.savedDisplay,
      this.goal,
      this.goalDisplay,
      this.percent,
      this.expected,
      this.expectedDisplay,
      this.elapsedPeriods,
      this.totalPeriods,
      this.aheadBy,
      this.projected,
      this.projectedDisplay,
      this.streak,
      this.status);
}

class _ScheduleRow {
  final int index;
  final String? date;
  final int target;
  final int cumulative;
  _ScheduleRow(this.index, this.date, this.target, this.cumulative);
}

class _SaveMath {
  static const Map<String, int> _periodDays = {
    'daily': 1,
    'weekly': 7,
    'monthly': 30
  };

  static int toPoisha(dynamic v) {
    if (v == null || v == '') return 0;
    if (v is bool) return 0;
    if (v is int) return v;
    if (v is double) v = v.toString();
    var s = v.toString().trim().replaceAll(',', '');
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    String whole, frac;
    if (s.contains('.')) {
      final parts = s.split('.');
      whole = parts[0];
      frac = parts.sublist(1).join();
    } else {
      whole = s;
      frac = '';
    }
    if (whole.isEmpty) whole = '0';
    frac = '${frac}000'.substring(0, 3); // db1: was '00' → RangeError on whole-taka input
    final taka = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (taka == null || milli == null) return 0;
    var poisha = taka * 100 + milli ~/ 10;
    if (milli % 10 >= 5) poisha += 1;
    return neg ? -poisha : poisha;
  }

  static int _int(dynamic v, [int d = 0]) {
    if (v == null || v == '') return d;
    return int.tryParse(v.toString().split('.').first) ?? d;
  }

  static String _group(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$tail';
  }

  static String fmtPoisha(double pf) {
    var p = pf.round();
    final neg = p < 0;
    p = p.abs();
    final taka = p ~/ 100;
    final paisa = p % 100;
    return '${neg ? '-' : ''}৳${_group(taka)}.${paisa.toString().padLeft(2, '0')}';
  }

  // ---- dates via ordinal (no DateTime arithmetic drift) ----
  static List<int>? _ymd(dynamic s) {
    if (s == null || s.toString().trim().isEmpty) return null;
    final parts = s.toString().trim().split('-');
    if (parts.length < 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    return [y, m, d];
  }

  static bool _isLeap(int y) => y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
  static const List<int> _mdays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

  static int _ordinal(List<int> ymd) {
    final y = ymd[0], m = ymd[1], d = ymd[2];
    var days = 0;
    for (var yy = 1; yy < y; yy++) {
      days += _isLeap(yy) ? 366 : 365;
    }
    for (var mm = 1; mm < m; mm++) {
      days += _mdays[mm - 1] + ((mm == 2 && _isLeap(y)) ? 1 : 0);
    }
    return days + d;
  }

  static String _addDays(List<int> ymd, int n) {
    var o = _ordinal(ymd) + n;
    var y = 1;
    while (true) {
      final yl = _isLeap(y) ? 366 : 365;
      if (o > yl) {
        o -= yl;
        y++;
      } else {
        break;
      }
    }
    var m = 1;
    while (true) {
      final ml = _mdays[m - 1] + ((m == 2 && _isLeap(y)) ? 1 : 0);
      if (o > ml) {
        o -= ml;
        m++;
      } else {
        break;
      }
    }
    return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${o.toString().padLeft(2, '0')}';
  }

  static int? daysBetween(dynamic a, dynamic b) {
    final ya = _ymd(a), yb = _ymd(b);
    if (ya == null || yb == null) return null;
    return _ordinal(yb) - _ordinal(ya);
  }

  // ---- schedule ----
  static List<_ScheduleRow> schedule(Map<String, dynamic> plan) {
    final kind = (plan['kind'] ?? 'week52').toString();
    var base = toPoisha(plan['base']);
    final start = _ymd(plan['start_date']);
    final period = (plan['period'] ?? 'weekly').toString();
    if (kind == 'roundup') return const [];
    if (kind == 'week52') {
      if (base <= 0) base = toPoisha('50');
      const step = 7;
      final rows = <_ScheduleRow>[];
      var cum = 0;
      for (var i = 1; i <= 52; i++) {
        final tgt = base * i;
        cum += tgt;
        final date = start == null ? null : _addDays(start, (i - 1) * step);
        rows.add(_ScheduleRow(i, date, tgt, cum));
      }
      return rows;
    }
    final n = _int(plan['periods']);
    if (n <= 0 || base <= 0) return const [];
    final step = _periodDays[period] ?? 7;
    final rows = <_ScheduleRow>[];
    var cum = 0;
    for (var i = 1; i <= n; i++) {
      cum += base;
      final date = start == null ? null : _addDays(start, (i - 1) * step);
      rows.add(_ScheduleRow(i, date, base, cum));
    }
    return rows;
  }

  static int planTotal(Map<String, dynamic> plan) {
    if ((plan['kind'] ?? 'week52') == 'roundup') return 0;
    final sch = schedule(plan);
    return sch.isEmpty ? 0 : sch.last.cumulative;
  }

  static int depositsTotal(List<Map<String, dynamic>> deposits) =>
      deposits.fold<int>(0, (a, d) => a + toPoisha(d['amount']));

  static List<int> expectedBy(Map<String, dynamic> plan, String now) {
    final kind = (plan['kind'] ?? 'week52').toString();
    final start = _ymd(plan['start_date']);
    if (kind == 'roundup') {
      final base = toPoisha(plan['base']);
      if (start == null || base <= 0) return [0, 0];
      final d = daysBetween(plan['start_date'], now);
      if (d == null || d < 0) return [0, 0];
      final elapsed = d + 1;
      return [base * elapsed, elapsed];
    }
    final sch = schedule(plan);
    if (sch.isEmpty || start == null) return [0, 0];
    var elapsed = 0, expected = 0;
    for (final row in sch) {
      if (row.date != null) {
        final dd = daysBetween(row.date, now);
        if (dd == null || dd < 0) break;
      }
      elapsed += 1;
      expected = row.cumulative;
    }
    return [expected, elapsed];
  }

  static int streak(
      Map<String, dynamic> plan, List<Map<String, dynamic>> deposits) {
    final sch = schedule(plan);
    if ((plan['kind'] ?? 'week52') == 'roundup' || sch.isEmpty) {
      return _roundupStreak(deposits);
    }
    final total = depositsTotal(deposits);
    for (var i = sch.length - 1; i >= 0; i--) {
      if (total >= sch[i].cumulative) return sch[i].index;
    }
    return 0;
  }

  static int _roundupStreak(List<Map<String, dynamic>> deposits) {
    final days = <String>{};
    for (final d in deposits) {
      if (_ymd(d['date']) != null && toPoisha(d['amount']) > 0) {
        days.add(d['date'].toString());
      }
    }
    final list = days.toList()..sort((a, b) => b.compareTo(a));
    if (list.isEmpty) return 0;
    var run = 1;
    for (var i = 1; i < list.length; i++) {
      if (daysBetween(list[i], list[i - 1]) == 1) {
        run++;
      } else {
        break;
      }
    }
    return run;
  }

  static _Progress progress(
      Map<String, dynamic> plan, List<Map<String, dynamic>> deposits, String now) {
    final kind = (plan['kind'] ?? 'week52').toString();
    final saved = depositsTotal(deposits);
    final goal = planTotal(plan);
    final sch = schedule(plan);
    final totalPeriods =
        sch.isNotEmpty ? sch.length : (kind == 'fixed' ? _int(plan['periods']) : 0);
    final eb = expectedBy(plan, now);
    final expected = eb[0], elapsed = eb[1];
    final aheadBy = saved - expected;

    int? percent;
    if (goal > 0) {
      percent = (saved * 100 / goal).round();
      if (percent < 0) percent = 0;
      if (percent > 100) percent = 100;
    }

    int projected;
    if (goal > 0 && elapsed > 0 && totalPeriods > 0) {
      final pace = saved / elapsed;
      var proj = (pace * totalPeriods).round();
      proj = saved < goal ? (proj > goal ? goal : proj) : saved;
      projected = proj;
    } else {
      projected = saved;
    }

    final start = _ymd(plan['start_date']);
    String status;
    if (start == null || (daysBetween(plan['start_date'], now) ?? -1) < 0) {
      status = 'not_started';
    } else if (goal > 0 && saved >= goal) {
      status = 'complete';
    } else if (expected <= 0) {
      status = 'on_track';
    } else if (aheadBy >= 0) {
      final one = sch.isNotEmpty ? sch.first.target : toPoisha(plan['base']);
      status = aheadBy > one ? 'ahead' : 'on_track';
    } else {
      status = 'behind';
    }

    return _Progress(
        (plan['name'] ?? '').toString(),
        kind,
        saved,
        fmtPoisha(saved.toDouble()),
        goal,
        fmtPoisha(goal.toDouble()),
        percent,
        expected,
        fmtPoisha(expected.toDouble()),
        elapsed,
        totalPeriods,
        aheadBy,
        projected,
        fmtPoisha(projected.toDouble()),
        streak(plan, deposits),
        status);
  }
}
