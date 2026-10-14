import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// FITNESS PARTNER — ADVANCED (#72, SPEC v2.1 §21).
///
/// A gentle workout/fitness companion. Set ONE goal (workout days/week, daily
/// steps, or a weight target), log workouts (type, minutes, optional calories/
/// steps), and track honest progress vs the goal with a weekly summary and a
/// day-streak. Status is deterministic: not-started / behind / on-track / ahead
/// / reached, pro-rated to how far the week/day is.
///
/// The on-screen logic mirrors backend/core/logic/fitness_partner.py VERBATIM
/// (Monday-anchored week, weekly summary, streak, pro-rated progress, honest
/// status) so the live view is deterministic and identical offline.
///
/// This is NOT a medical plan — copy is encouraging and never diagnostic or
/// extreme. AI-personalised coaching is a DOCUMENTED key-gated seam that is NOT
/// built: with no key the screen shows a fixed, non-medical fallback tip (clearly
/// not AI output) and the full tracker works without any key.
///
/// Honest states: welcome (first use) · loading · error · no-goal. ZERO Bangla
/// literals — every string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('fitness/goals')    → [{id, kind, target, start_weight,
///                                      start_date}]
///     kind ∈ {workout_days, steps, weight}; start_weight only for 'weight'.
///   listItems('fitness/workouts') → [{id, date, type, minutes, calories,
///                                      steps}]  date 'YYYY-MM-DD'
///   listItems('fitness/weighins') → [{id, date, weight}]  (weight goals)
/// create/update/deleteItem on the same paths. Each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection (PaCollectionItem
/// precedent). The newest goal row is treated as the active goal.
class FitnessPartnerScreen extends StatefulWidget {
  const FitnessPartnerScreen({super.key});
  @override
  State<FitnessPartnerScreen> createState() => _FitnessPartnerScreenState();
}

const String _goalsPath = 'fitness/goals';
const String _workoutsPath = 'fitness/workouts';
const String _weighinsPath = 'fitness/weighins';

const List<String> _kindKeys = ['workout_days', 'steps', 'weight'];
const List<String> _typeKeys = [
  'walk',
  'run',
  'cycle',
  'gym',
  'yoga',
  'sport',
  'other'
];

String _kindLabel(AppLocalizations tr, String? k) {
  switch (k) {
    case 'steps':
      return tr.fitKindSteps;
    case 'weight':
      return tr.fitKindWeight;
    default:
      return tr.fitKindWorkoutDays;
  }
}

String _kindUnit(AppLocalizations tr, String? k) {
  switch (k) {
    case 'steps':
      return tr.fitUnitSteps;
    case 'weight':
      return tr.fitUnitKg;
    default:
      return tr.fitUnitDays;
  }
}

String _typeLabel(AppLocalizations tr, String? t) {
  switch (t) {
    case 'run':
      return tr.fitTypeRun;
    case 'cycle':
      return tr.fitTypeCycle;
    case 'gym':
      return tr.fitTypeGym;
    case 'yoga':
      return tr.fitTypeYoga;
    case 'sport':
      return tr.fitTypeSport;
    case 'other':
      return tr.fitTypeOther;
    default:
      return tr.fitTypeWalk;
  }
}

IconData _typeIcon(String? t) {
  switch (t) {
    case 'run':
      return Icons.directions_run;
    case 'cycle':
      return Icons.directions_bike;
    case 'gym':
      return Icons.fitness_center;
    case 'yoga':
      return Icons.self_improvement;
    case 'sport':
      return Icons.sports_soccer;
    case 'other':
      return Icons.bolt;
    default:
      return Icons.directions_walk;
  }
}

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

class _FitnessPartnerScreenState extends State<FitnessPartnerScreen> {
  List<Map<String, dynamic>> _goals = [];
  List<Map<String, dynamic>> _workouts = [];
  List<Map<String, dynamic>> _weighins = [];
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
        api.listItems(_goalsPath),
        api.listItems(_workoutsPath),
        api.listItems(_weighinsPath),
      ]);
      _goals = res[0];
      _workouts = res[1];
      _weighins = res[2];
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic>? get _activeGoal {
    if (_goals.isEmpty) return null;
    // newest row (highest id) is the active goal
    final sorted = [..._goals]..sort((a, b) =>
        ((b['id'] ?? 0) as int).compareTo((a['id'] ?? 0) as int));
    return sorted.first;
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
        appBar: AppBar(title: Text(tr.fitTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.fitTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.fitLoadError,
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry)),
        ),
      );
    }
    final goal = _activeGoal;
    if (goal == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.fitTitle)),
        body: StateMessage(
          icon: Icons.favorite_outline,
          title: tr.fitWelcomeTitle,
          message: tr.fitWelcomeBody,
          action: FilledButton.icon(
            onPressed: _setGoal,
            icon: const Icon(Icons.flag_outlined),
            label: Text(tr.fitSetGoal),
          ),
        ),
      );
    }
    final p = _FitMath.progress(goal, _workouts, _today(), _weighins);
    final wk = _FitMath.weeklySummary(_workouts, _today());
    final streak = _FitMath.streak(_workouts, _today());
    return Scaffold(
      appBar: AppBar(title: Text(tr.fitTitle), actions: [
        IconButton(
          tooltip: tr.fitChangeGoal,
          icon: const Icon(Icons.flag_outlined),
          onPressed: _setGoal,
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _logWorkout,
        icon: const Icon(Icons.add),
        label: Text(tr.fitLogWorkout),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          children: [
            _GoalHeadline(progress: p),
            const SizedBox(height: Gap.md),
            _WeeklyStreakRow(summary: wk, streak: streak),
            const SizedBox(height: Gap.md),
            _CoachTip(status: p.status),
            const SizedBox(height: Gap.lg),
            Text(tr.fitRecentWorkouts,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            ..._recentWorkoutTiles(tr),
            const SizedBox(height: Gap.md),
            _nonMedicalNote(context, tr.fitNonMedicalNote),
          ],
        ),
      ),
    );
  }

  List<Widget> _recentWorkoutTiles(AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    final sorted = [..._workouts]..sort((a, b) =>
        (b['date'] ?? '').toString().compareTo((a['date'] ?? '').toString()));
    if (sorted.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          child: Text(tr.fitNoWorkoutsYet,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      ];
    }
    return [
      for (final w in sorted.take(12))
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            dense: true,
            leading:
                Icon(_typeIcon(w['type'] as String?), color: scheme.primary),
            title: Text(_typeLabel(tr, w['type'] as String?)),
            subtitle: Text(_workoutSubtitle(tr, w)),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: tr.delete,
              onPressed: () async {
                final id = w['id'];
                if (id is int) {
                  await context.read<AppState>().api.deleteItem(_workoutsPath, id);
                  await _load();
                }
              },
            ),
          ),
        ),
    ];
  }

  String _workoutSubtitle(AppLocalizations tr, Map<String, dynamic> w) {
    final parts = <String>[(w['date'] ?? '').toString()];
    final mins = _FitMath.toInt(w['minutes']);
    if (mins > 0) parts.add(tr.fitMinutes(mins));
    final cal = _FitMath.numOrNull(w['calories']);
    if (cal != null) parts.add(tr.fitCalories(cal.round()));
    final steps = _FitMath.toInt(w['steps']);
    if (steps > 0) parts.add(tr.fitStepsShort(steps));
    return parts.join('  ·  ');
  }

  Future<void> _setGoal() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GoalForm(defaultDate: _today()),
    );
    if (result == null) return;
    try {
      await api.createItem(_goalsPath, result);
      await _load();
      if (mounted) _toast(tr.fitSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _logWorkout() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final goal = _activeGoal;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _WorkoutForm(
        defaultDate: _today(),
        showSteps: (goal?['kind'] == 'steps'),
      ),
    );
    if (result == null) return;
    try {
      await api.createItem(_workoutsPath, result);
      // a weight goal also keeps an optional weigh-in log from the workout sheet
      final wt = result.remove('weight_kg');
      if (goal?['kind'] == 'weight' && wt != null && wt.toString().isNotEmpty) {
        await api.createItem(
            _weighinsPath, {'date': result['date'], 'weight': wt});
      }
      await _load();
      if (mounted) _toast(tr.fitSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

// ======================= goal headline =======================
class _GoalHeadline extends StatelessWidget {
  final _Progress progress;
  const _GoalHeadline({required this.progress});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final c = _statusColor(context, progress.status);
    return Card(
      color: c.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(_kindLabel(tr, progress.kind),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                ),
                _statusChip(context, progress.status),
              ]),
              const SizedBox(height: Gap.sm),
              Text(_headlineValue(tr),
                  style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface)),
              const SizedBox(height: Gap.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(Radii.pill),
                child: LinearProgressIndicator(
                  value: progress.percent / 100.0,
                  minHeight: 10,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: c,
                ),
              ),
              const SizedBox(height: Gap.xs),
              Text('${progress.percent}%',
                  style: TextStyle(fontWeight: FontWeight.w700, color: c)),
            ]),
      ),
    );
  }

  String _headlineValue(AppLocalizations tr) {
    switch (progress.kind) {
      case 'steps':
        return tr.fitStepsOfTarget(
            progress.actual.round(), progress.target.round());
      case 'weight':
        return tr.fitWeightOfTarget(
            _fmtKg(progress.actual), _fmtKg(progress.target));
      default:
        return tr.fitDaysOfTarget(
            progress.actual.round(), progress.target.round());
    }
  }
}

// ======================= weekly + streak =======================
class _WeeklyStreakRow extends StatelessWidget {
  final Map<String, dynamic> summary;
  final int streak;
  const _WeeklyStreakRow({required this.summary, required this.streak});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Row(children: [
      Expanded(
          child: _statCard(context, tr.fitThisWeek,
              tr.fitSessions((summary['count'] as int?) ?? 0),
              Brand.blue, Icons.calendar_today_outlined)),
      const SizedBox(width: Gap.sm),
      Expanded(
          child: _statCard(context, tr.fitMinutesLabel,
              '${(summary['minutes'] as int?) ?? 0}',
              Brand.purple, Icons.timer_outlined)),
      const SizedBox(width: Gap.sm),
      Expanded(
          child: _statCard(context, tr.fitStreak, tr.fitDays(streak),
              Brand.success, Icons.local_fire_department_outlined)),
    ]);
  }
}

// ======================= coach tip (seam) =======================
class _CoachTip extends StatelessWidget {
  final String status;
  const _CoachTip({required this.status});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.tips_and_updates_outlined,
              size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_tip(tr, status),
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(tr.fitCoachingSeam,
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ]),
          ),
        ]),
      ),
    );
  }

  String _tip(AppLocalizations tr, String status) {
    switch (status) {
      case 'not_started':
        return tr.fitTipNotStarted;
      case 'behind':
        return tr.fitTipBehind;
      case 'ahead':
        return tr.fitTipAhead;
      case 'reached':
        return tr.fitTipReached;
      default:
        return tr.fitTipOnTrack;
    }
  }
}

// ======================= goal form =======================
class _GoalForm extends StatefulWidget {
  final String defaultDate;
  const _GoalForm({required this.defaultDate});
  @override
  State<_GoalForm> createState() => _GoalFormState();
}

class _GoalFormState extends State<_GoalForm> {
  final _target = TextEditingController();
  final _startWeight = TextEditingController();
  late final _start = TextEditingController(text: widget.defaultDate);
  String _kind = 'workout_days';

  @override
  void dispose() {
    _target.dispose();
    _startWeight.dispose();
    _start.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final target = _FitMath.numOrNull(_target.text);
    final targetOk = target != null && target > 0 &&
        !(_kind == 'workout_days' && target > 7);
    final weightOk = _kind != 'weight' ||
        ((_FitMath.numOrNull(_startWeight.text) ?? 0) > 0 &&
            (_FitMath.numOrNull(_startWeight.text) != target));
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.fitSetGoal,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.sm),
              Text(tr.fitGoalHelp,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: Gap.lg),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                decoration: InputDecoration(
                    labelText: tr.fitGoalType,
                    border: const OutlineInputBorder()),
                items: [
                  for (final k in _kindKeys)
                    DropdownMenuItem(value: k, child: Text(_kindLabel(tr, k))),
                ],
                onChanged: (v) => setState(() => _kind = v ?? 'workout_days'),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _target,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr.fitTargetLabel(_kindUnit(tr, _kind)),
                    helperText: _kind == 'workout_days'
                        ? tr.fitDaysHelper
                        : (_kind == 'weight' ? tr.fitWeightTargetHelper : null),
                    border: const OutlineInputBorder()),
              ),
              if (_kind == 'weight') ...[
                const SizedBox(height: Gap.md),
                TextField(
                  controller: _startWeight,
                  onChanged: (_) => setState(() {}),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: tr.fitStartWeight,
                      suffixText: tr.fitUnitKg,
                      border: const OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: Gap.md),
              TextField(
                controller: _start,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                    labelText: tr.fitStartDate,
                    hintText: tr.fitDateHint,
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
                    onPressed: (targetOk && weightOk)
                        ? () => Navigator.pop(context, <String, dynamic>{
                              'kind': _kind,
                              'target': _target.text.trim(),
                              if (_kind == 'weight')
                                'start_weight': _startWeight.text.trim(),
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

// ======================= workout form =======================
class _WorkoutForm extends StatefulWidget {
  final String defaultDate;
  final bool showSteps;
  const _WorkoutForm({required this.defaultDate, required this.showSteps});
  @override
  State<_WorkoutForm> createState() => _WorkoutFormState();
}

class _WorkoutFormState extends State<_WorkoutForm> {
  final _minutes = TextEditingController();
  final _calories = TextEditingController();
  final _steps = TextEditingController();
  final _weight = TextEditingController();
  late final _date = TextEditingController(text: widget.defaultDate);
  String _type = 'walk';

  @override
  void dispose() {
    _minutes.dispose();
    _calories.dispose();
    _steps.dispose();
    _weight.dispose();
    _date.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final mins = _FitMath.numOrNull(_minutes.text);
    final minutesOk = mins != null && mins > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.fitLogWorkout,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: InputDecoration(
                    labelText: tr.fitWorkoutType,
                    border: const OutlineInputBorder()),
                items: [
                  for (final t in _typeKeys)
                    DropdownMenuItem(value: t, child: Text(_typeLabel(tr, t))),
                ],
                onChanged: (v) => setState(() => _type = v ?? 'walk'),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _minutes,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tr.fitDurationMinutes,
                    border: const OutlineInputBorder()),
              ),
              if (widget.showSteps) ...[
                const SizedBox(height: Gap.md),
                TextField(
                  controller: _steps,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: tr.fitStepsLabel,
                      border: const OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: Gap.md),
              TextField(
                controller: _calories,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tr.fitCaloriesOptional,
                    helperText: tr.fitCaloriesHelper,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _date,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                    labelText: tr.fitDate,
                    hintText: tr.fitDateHint,
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
                    onPressed: minutesOk
                        ? () => Navigator.pop(context, <String, dynamic>{
                              'type': _type,
                              'minutes': _minutes.text.trim(),
                              if (_calories.text.trim().isNotEmpty)
                                'calories': _calories.text.trim(),
                              if (widget.showSteps &&
                                  _steps.text.trim().isNotEmpty)
                                'steps': _steps.text.trim(),
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
    case 'reached':
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
      label = tr.fitStatusAhead;
      break;
    case 'behind':
      label = tr.fitStatusBehind;
      break;
    case 'reached':
      label = tr.fitStatusReached;
      break;
    case 'not_started':
      label = tr.fitStatusNotStarted;
      break;
    default:
      label = tr.fitStatusOnTrack;
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    child: Text(label,
        style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
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
        Icon(icon, size: 16, color: color),
        const SizedBox(height: Gap.xs),
        Text(value,
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.bold, color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        Text(label,
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
      ]),
    ),
  );
}

Widget _nonMedicalNote(BuildContext context, String text) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    color: scheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Row(children: [
        Icon(Icons.favorite_border, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ),
      ]),
    ),
  );
}

String _fmtKg(double v) {
  if (v == v.roundToDouble()) return v.round().toString();
  return v.toStringAsFixed(1);
}

// ===================================================================
// _FitMath — deterministic mirror of backend/core/logic/fitness_partner.py.
// Monday-anchored week, weekly summary, streak, pro-rated progress, honest
// status. No clock inside the pure functions (today is passed in).
// ===================================================================
class _Progress {
  final String kind;
  final double target;
  final double actual;
  final int percent;
  final String status;
  _Progress(this.kind, this.target, this.actual, this.percent, this.status);
}

class _FitMath {
  static const List<String> _validKinds = ['workout_days', 'steps', 'weight'];

  static double? numOrNull(dynamic v) {
    if (v == null || v == '') return null;
    if (v is bool) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().replaceAll(',', ''));
  }

  static int toInt(dynamic v) {
    final n = numOrNull(v);
    return n == null ? 0 : n.toInt();
  }

  // ---- dates (ordinal) ----
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

  static String _fromOrdinal(int o) {
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

  static int _weekday(List<int> ymd) => (_ordinal(ymd) - 1) % 7; // 0=Mon

  /// [monday, sunday, weekdayIndex]
  static List<dynamic>? weekBounds(String now) {
    final ymd = _ymd(now);
    if (ymd == null) return null;
    final wd = _weekday(ymd);
    final o = _ordinal(ymd);
    return [_fromOrdinal(o - wd), _fromOrdinal(o - wd + 6), wd];
  }

  static bool _inWeek(dynamic dateStr, String monday, String sunday) {
    final d = _ymd(dateStr);
    if (d == null) return false;
    final o = _ordinal(d);
    return _ordinal(_ymd(monday)!) <= o && o <= _ordinal(_ymd(sunday)!);
  }

  static Map<String, dynamic> weeklySummary(
      List<Map<String, dynamic>> workouts, String now) {
    final wb = weekBounds(now);
    if (wb == null) {
      return {
        'week_start': null,
        'week_end': null,
        'days': 0,
        'count': 0,
        'minutes': 0,
        'calories': 0,
        'empty': true
      };
    }
    final monday = wb[0] as String, sunday = wb[1] as String;
    var count = 0, minutes = 0, calories = 0;
    final dates = <String>{};
    for (final w in workouts) {
      if (!_inWeek(w['date'], monday, sunday)) continue;
      count++;
      minutes += toInt(w['minutes']);
      final cal = numOrNull(w['calories']);
      if (cal != null) calories += cal.toInt();
      dates.add(w['date'].toString());
    }
    return {
      'week_start': monday,
      'week_end': sunday,
      'days': dates.length,
      'count': count,
      'minutes': minutes,
      'calories': calories,
      'empty': count == 0,
    };
  }

  static int streak(List<Map<String, dynamic>> workouts, String now) {
    final set = <String>{};
    for (final w in workouts) {
      if (_ymd(w['date']) != null) set.add(w['date'].toString());
    }
    final days = set.toList()..sort((a, b) => b.compareTo(a));
    if (days.isEmpty) return 0;
    final gap = daysBetween(days[0], now);
    if (gap == null || gap < 0 || gap > 1) return 0;
    var run = 1;
    for (var i = 1; i < days.length; i++) {
      if (daysBetween(days[i], days[i - 1]) == 1) {
        run++;
      } else {
        break;
      }
    }
    return run;
  }

  static int _pct(double actual, double target) {
    if (target <= 0) return 0;
    var p = (actual * 100 / target).round();
    if (p < 0) p = 0;
    if (p > 100) p = 100;
    return p;
  }

  static String _proRatedStatus(double actual, double expected, double target) {
    if (target > 0 && actual >= target) return 'reached';
    if (expected <= 0) return 'on_track';
    if (actual >= expected * 1.1) return 'ahead';
    if (actual >= expected * 0.9) return 'on_track';
    return 'behind';
  }

  static _Progress progress(Map<String, dynamic> goal,
      List<Map<String, dynamic>> workouts, String now,
      [List<Map<String, dynamic>> weighins = const []]) {
    final kind = (goal['kind'] ?? '').toString();
    if (!_validKinds.contains(kind)) return _notStarted('');
    final start = goal['start_date'];
    if (start != null &&
        start.toString().isNotEmpty &&
        (daysBetween(start, now) ?? 0) < 0) {
      return _notStarted(kind);
    }

    if (kind == 'workout_days') {
      final target = numOrNull(goal['target']) ?? 0;
      final wk = weeklySummary(workouts, now);
      final actual = (wk['days'] as int).toDouble();
      final wb = weekBounds(now);
      final elapsed = wb != null ? (wb[2] as int) + 1 : 7;
      final expected = target > 0 ? target * elapsed / 7.0 : 0.0;
      var status = _proRatedStatus(actual, expected, target);
      if (workouts.isEmpty) status = 'not_started';
      return _Progress(kind, target, actual, _pct(actual, target), status);
    }

    if (kind == 'steps') {
      final target = numOrNull(goal['target']) ?? 0;
      final todaySteps = workouts
          .where((w) => w['date'].toString() == now)
          .fold<int>(0, (a, w) => a + toInt(w['steps']))
          .toDouble();
      var status = _proRatedStatus(todaySteps, target, target);
      if (!workouts.any((w) => w['date'].toString() == now)) {
        status = 'not_started';
      }
      return _Progress(
          kind, target, todaySteps, _pct(todaySteps, target), status);
    }

    // weight
    final target = numOrNull(goal['target']);
    final startW = numOrNull(goal['start_weight']);
    var current = _latestWeight(weighins);
    current ??= startW;
    if (target == null || startW == null || current == null) {
      return _notStarted(kind);
    }
    final gap = startW - target;
    final done = startW - current;
    int percent;
    String status;
    if (gap.abs() < 1e-9) {
      percent = 100;
      status = 'reached';
    } else {
      final frac = done / gap;
      percent = (frac * 100).round();
      if (percent < 0) percent = 0;
      if (percent > 100) percent = 100;
      final reached = gap > 0 ? (current <= target) : (current >= target);
      status = reached ? 'reached' : (percent > 0 ? 'on_track' : 'behind');
    }
    return _Progress(kind, target, current, percent, status);
  }

  static double? _latestWeight(List<Map<String, dynamic>> weighins) {
    final dated = weighins
        .where((w) => _ymd(w['date']) != null && numOrNull(w['weight']) != null)
        .toList();
    if (dated.isEmpty) return null;
    dated.sort((a, b) => b['date'].toString().compareTo(a['date'].toString()));
    return numOrNull(dated.first['weight']);
  }

  static _Progress _notStarted(String kind) =>
      _Progress(kind, 0, 0, 0, 'not_started');
}
