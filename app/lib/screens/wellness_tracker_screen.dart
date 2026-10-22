import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// WATER / SLEEP / DIET TRACKER — ADVANCED (#71, SPEC v2.1 §10).
///
/// Daily wellness logging: water intake (glasses vs a goal), sleep hours (vs a
/// goal) and meals / diet notes. We show today's progress rings, a 7-day trend
/// and honest streaks.
///
/// This is a personal TRACKER, not medical advice. The user sets their own
/// goals (with gentle, widely-published defaults); we never diagnose or judge a
/// diet. A "not medical advice — consult a doctor" note is always shown.
///
/// Food-photo OCR is a DOCUMENTED, key-gated seam — intentionally NOT built
/// here. Diet is captured as free text today.
///
/// The on-screen math mirrors backend/core/logic/wellness_tracker.py VERBATIM
/// (fold-by-day, clamped ring + raw ratio, 7-day trend over logged days,
/// goal-met streaks) so results are identical online or offline.
///
/// Honest states: welcome (first use) · loading · error · empty-day. ZERO
/// Bangla literals — every string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('wellness/logs') → [{id, date (YYYY-MM-DD), water (int glasses),
///       sleep (hours num), diet (text), water_goal (int?), sleep_goal (num?)}]
///   create/update/deleteItem on the same path; one flexible per-user JSON
///   collection. One log per day (the UI edits today's existing row if present).
class WellnessTrackerScreen extends StatefulWidget {
  const WellnessTrackerScreen({super.key});
  @override
  State<WellnessTrackerScreen> createState() => _WellnessTrackerScreenState();
}

const String _logsPath = 'wellness/logs';
const int _defaultWaterGoal = 8;
const double _defaultSleepGoal = 8.0;

class _WellnessTrackerScreenState extends State<WellnessTrackerScreen> {
  List<Map<String, dynamic>> _rows = [];
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
      _rows = await api.listItems(_logsPath);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  String get _todayIso => DateTime.now().toIso8601String().split('T').first;

  Map<String, dynamic>? get _todayRow {
    for (final r in _rows) {
      if ((r['date']?.toString().split('T').first) == _todayIso) return r;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr.wellTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.wellTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.wellLoadError,
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_rows.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.wellTitle)),
        body: ListView(children: [
          StateMessage(
            icon: Icons.favorite_outline,
            tint: Brand.blue,
            title: tr.wellWelcomeTitle,
            message: tr.wellWelcomeBody,
            action: FilledButton.icon(
              onPressed: _logToday,
              icon: const Icon(Icons.add),
              label: Text(tr.wellLogToday),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.lg),
            child: _Disclaimer(),
          ),
        ]),
      );
    }

    final today = _Well.todayView(_rows, _todayIso);
    final trend = _Well.trend(_rows, _todayIso);
    final streaks = _Well.streaks(_rows, _todayIso);

    return Scaffold(
      appBar: AppBar(title: Text(tr.wellTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _logToday,
        icon: Icon(today.logged ? Icons.edit_outlined : Icons.add),
        label: Text(today.logged ? tr.wellEditToday : tr.wellLogToday),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          children: [
            _TodayCard(view: today),
            const SizedBox(height: Gap.md),
            _StreaksRow(streaks: streaks),
            const SizedBox(height: Gap.md),
            _TrendCard(trend: trend),
            if (today.diet.isNotEmpty) ...[
              const SizedBox(height: Gap.md),
              _DietCard(diet: today.diet),
            ],
            const SizedBox(height: Gap.md),
            const _Disclaimer(),
          ],
        ),
      ),
    );
  }

  Future<void> _logToday() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final existing = _todayRow;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _LogForm(existing: existing, todayIso: _todayIso),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_logsPath, existing['id'] as int, result);
      } else {
        await api.createItem(_logsPath, result);
      }
      await _load();
      if (mounted) _toast(tr.wellSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

// ======================= TODAY CARD (rings) =======================
class _TodayCard extends StatelessWidget {
  final _DayView view;
  const _TodayCard({required this.view});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(tr.wellToday,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            if (!view.logged)
              Text(tr.wellNotLoggedYet,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: _Ring(
                ring: view.water.ring,
                color: Brand.blue,
                icon: Icons.water_drop_outlined,
                valueLabel: tr.wellGlassesOf(/* (goal, value) */ view.water.goal, view.water.value),
                caption: tr.wellWater,
                met: view.water.met,
              ),
            ),
            Expanded(
              child: _Ring(
                ring: view.sleep.ring,
                color: Brand.purple,
                icon: Icons.bedtime_outlined,
                valueLabel: tr.wellHoursOf(/* (goal, value) */
                    _fmt(view.sleep.goal), _fmt(view.sleep.value)),
                caption: tr.wellSleep,
                met: view.sleep.met,
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  final double ring;
  final Color color;
  final IconData icon;
  final String valueLabel;
  final String caption;
  final bool met;
  const _Ring(
      {required this.ring,
      required this.color,
      required this.icon,
      required this.valueLabel,
      required this.caption,
      required this.met});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      SizedBox(
        height: 92,
        width: 92,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            height: 92,
            width: 92,
            child: CircularProgressIndicator(
              value: ring,
              strokeWidth: 9,
              backgroundColor: color.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(met ? Icons.check : icon, color: color, size: 22),
          ]),
        ]),
      ),
      const SizedBox(height: Gap.sm),
      Text(valueLabel,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700)),
      Text(caption,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
    ]);
  }
}

// ======================= STREAKS =======================
class _StreaksRow extends StatelessWidget {
  final _Streaks streaks;
  const _StreaksRow({required this.streaks});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Row(children: [
      Expanded(
        child: _StreakCard(
          icon: Icons.water_drop_outlined,
          color: Brand.blue,
          label: tr.wellWaterStreak,
          current: streaks.waterCurrent,
          best: streaks.waterBest,
        ),
      ),
      const SizedBox(width: Gap.md),
      Expanded(
        child: _StreakCard(
          icon: Icons.bedtime_outlined,
          color: Brand.purple,
          label: tr.wellSleepStreak,
          current: streaks.sleepCurrent,
          best: streaks.sleepBest,
        ),
      ),
    ]);
  }
}

class _StreakCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final int current;
  final int best;
  const _StreakCard(
      {required this.icon,
      required this.color,
      required this.label,
      required this.current,
      required this.best});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(tr.wellDaysCount(current),
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold, color: color)),
          Text(tr.wellBestStreak(best),
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

// ======================= 7-DAY TREND =======================
class _TrendCard extends StatelessWidget {
  final _Trend trend;
  const _TrendCard({required this.trend});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.wellTrend7d,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(
            trend.loggedDays == 0
                ? tr.wellTrendEmpty
                : tr.wellTrendAverages(/* (sleep, water) */
                    _fmt(trend.avgSleep), _fmt(trend.avgWater)),
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Gap.md),
          _TrendBars(
              series: trend.series,
              color: Brand.blue,
              metric: 'water',
              label: tr.wellWater),
          const SizedBox(height: Gap.md),
          _TrendBars(
              series: trend.series,
              color: Brand.purple,
              metric: 'sleep',
              label: tr.wellSleep),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
            _goalPill(context, Brand.blue, tr.wellWater,
                tr.wellGoalDays(trend.waterGoalDays, trend.days)),
            _goalPill(context, Brand.purple, tr.wellSleep,
                tr.wellGoalDays(trend.sleepGoalDays, trend.days)),
          ]),
        ]),
      ),
    );
  }

  Widget _goalPill(
      BuildContext context, Color c, String metric, String text) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(
          color: c, borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 5),
      Text('$metric · $text',
          style: TextStyle(
              fontSize: 11.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]);
  }
}

class _TrendBars extends StatelessWidget {
  final List<_DayView> series;
  final Color color;
  final String metric; // water | sleep
  final String label;
  const _TrendBars(
      {required this.series,
      required this.color,
      required this.metric,
      required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.xs),
      SizedBox(
        height: 72,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final d in series)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            heightFactor: _barHeight(d),
                            child: Container(
                              decoration: BoxDecoration(
                                color: d.logged
                                    ? color.withValues(
                                        alpha: _metricMet(d) ? 1.0 : 0.45)
                                    : scheme.outlineVariant
                                        .withValues(alpha: 0.4),
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4)),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(_dayLetter(context, d.date),
                          style: TextStyle(
                              fontSize: 10, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ]);
  }

  double _barHeight(_DayView d) {
    final r = metric == 'water' ? d.water.ring : d.sleep.ring;
    // keep a tiny stub so empty days are visibly "there" but clearly low.
    return math.max(0.06, r);
  }

  bool _metricMet(_DayView d) =>
      metric == 'water' ? d.water.met : d.sleep.met;

  String _dayLetter(BuildContext context, String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    // localised narrow weekday via MaterialLocalizations (no Bangla literal).
    final names = MaterialLocalizations.of(context).narrowWeekdays;
    // DateTime.weekday: Mon=1..Sun=7; narrowWeekdays index: Sun=0..Sat=6.
    return names[d.weekday % 7];
  }
}

// ======================= DIET =======================
class _DietCard extends StatelessWidget {
  final String diet;
  const _DietCard({required this.diet});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.restaurant_outlined, size: 16, color: Brand.success),
            const SizedBox(width: 6),
            Text(tr.wellDietToday,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: Gap.xs),
          Text(diet, style: TextStyle(color: scheme.onSurface, height: 1.4)),
        ]),
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.wellDisclaimer,
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

// ======================= LOG FORM =======================
class _LogForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String todayIso;
  const _LogForm({this.existing, required this.todayIso});
  @override
  State<_LogForm> createState() => _LogFormState();
}

class _LogFormState extends State<_LogForm> {
  late int _water = _intOf(widget.existing?['water'], 0);
  late double _sleep = _numOf(widget.existing?['sleep'], 0);
  late int _waterGoal =
      _intOf(widget.existing?['water_goal'], _defaultWaterGoal);
  late double _sleepGoal =
      _numOf(widget.existing?['sleep_goal'], _defaultSleepGoal);
  late final TextEditingController _diet =
      TextEditingController(text: widget.existing?['diet']?.toString() ?? '');

  static int _intOf(dynamic v, int d) =>
      v == null ? d : (int.tryParse(v.toString().split('.').first) ?? d);
  static double _numOf(dynamic v, double d) =>
      v == null ? d : (double.tryParse(v.toString()) ?? d);

  @override
  void dispose() {
    _diet.dispose();
    super.dispose();
  }

  Map<String, dynamic> _result() => {
        'date': widget.todayIso,
        'water': _water,
        'sleep': _sleep,
        'diet': _diet.text.trim(),
        'water_goal': _waterGoal,
        'sleep_goal': _sleepGoal,
      };

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.wellLogToday,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            // WATER stepper
            _StepperRow(
              icon: Icons.water_drop_outlined,
              color: Brand.blue,
              label: tr.wellWater,
              valueLabel: tr.wellGlassesOf(/* (goal, value) */ _waterGoal, _water),
              onMinus: _water > 0 ? () => setState(() => _water--) : null,
              onPlus: _water < 40 ? () => setState(() => _water++) : null,
            ),
            const SizedBox(height: Gap.sm),
            _GoalRow(
              label: tr.wellWaterGoal,
              valueLabel: tr.wellGlasses(_waterGoal),
              onMinus:
                  _waterGoal > 1 ? () => setState(() => _waterGoal--) : null,
              onPlus:
                  _waterGoal < 20 ? () => setState(() => _waterGoal++) : null,
            ),
            const Divider(height: Gap.xl),
            // SLEEP stepper (0.5h steps)
            _StepperRow(
              icon: Icons.bedtime_outlined,
              color: Brand.purple,
              label: tr.wellSleep,
              valueLabel: tr.wellHours(_fmt(_sleep)),
              onMinus: _sleep > 0
                  ? () => setState(() => _sleep = (_sleep - 0.5).clamp(0, 24))
                  : null,
              onPlus: _sleep < 24
                  ? () => setState(() => _sleep = (_sleep + 0.5).clamp(0, 24))
                  : null,
            ),
            const SizedBox(height: Gap.sm),
            _GoalRow(
              label: tr.wellSleepGoal,
              valueLabel: tr.wellHours(_fmt(_sleepGoal)),
              onMinus: _sleepGoal > 1
                  ? () =>
                      setState(() => _sleepGoal = (_sleepGoal - 0.5).clamp(1, 16))
                  : null,
              onPlus: _sleepGoal < 16
                  ? () =>
                      setState(() => _sleepGoal = (_sleepGoal + 0.5).clamp(1, 16))
                  : null,
            ),
            const Divider(height: Gap.xl),
            // DIET notes (free text; OCR seam documented, not built)
            TextField(
              controller: _diet,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                  labelText: tr.wellDietNotes,
                  hintText: tr.wellDietHint,
                  alignLabelWithHint: true,
                  prefixIcon: const Icon(Icons.restaurant_outlined),
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
                  onPressed: () => Navigator.pop(context, _result()),
                  child: Text(tr.save),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _StepperRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String valueLabel;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  const _StepperRow(
      {required this.icon,
      required this.color,
      required this.label,
      required this.valueLabel,
      this.onMinus,
      this.onPlus});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, color: color),
      const SizedBox(width: Gap.sm),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(valueLabel,
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      ),
      IconButton.filledTonal(
          onPressed: onMinus, icon: const Icon(Icons.remove)),
      const SizedBox(width: Gap.sm),
      IconButton.filledTonal(onPressed: onPlus, icon: const Icon(Icons.add)),
    ]);
  }
}

class _GoalRow extends StatelessWidget {
  final String label;
  final String valueLabel;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  const _GoalRow(
      {required this.label,
      required this.valueLabel,
      this.onMinus,
      this.onPlus});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 36),
      child: Row(children: [
        Expanded(
          child: Text('$label · $valueLabel',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ),
        IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onMinus,
            icon: const Icon(Icons.remove, size: 18)),
        IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onPlus,
            icon: const Icon(Icons.add, size: 18)),
      ]),
    );
  }
}

// ======================= formatting =======================
String _fmt(num v) {
  // whole numbers show without a trailing .0; halves show one decimal.
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(1);
}

// ===================================================================
// _Well — deterministic mirror of core/logic/wellness_tracker.py.
// fold-by-day, clamped ring + raw ratio, 7-day trend over logged days,
// goal-met streaks. No I/O, no live clock (today passed in as ISO string).
// ===================================================================
class _Ratio {
  final num value;
  final num goal;
  final double raw;
  final double ring;
  final bool met;
  const _Ratio(this.value, this.goal, this.raw, this.ring, this.met);
}

class _DayView {
  final String date;
  final _Ratio water;
  final _Ratio sleep;
  final String diet;
  final bool logged;
  const _DayView(
      {required this.date,
      required this.water,
      required this.sleep,
      required this.diet,
      required this.logged});
}

class _Trend {
  final int days;
  final List<_DayView> series;
  final double avgWater;
  final double avgSleep;
  final int loggedDays;
  final int waterGoalDays;
  final int sleepGoalDays;
  const _Trend(
      {required this.days,
      required this.series,
      required this.avgWater,
      required this.avgSleep,
      required this.loggedDays,
      required this.waterGoalDays,
      required this.sleepGoalDays});
}

class _Streaks {
  final int waterCurrent;
  final int waterBest;
  final int sleepCurrent;
  final int sleepBest;
  const _Streaks(
      this.waterCurrent, this.waterBest, this.sleepCurrent, this.sleepBest);
}

class _DayRecord {
  int water = 0;
  double sleep = 0;
  String diet = '';
  int waterGoal = _defaultWaterGoal;
  double sleepGoal = _defaultSleepGoal;
}

class _Well {
  static DateTime? _parse(dynamic v) {
    if (v == null || v == '') return null;
    final s = v.toString().split('T').first.split(' ').first;
    return DateTime.tryParse(s);
  }

  static double _numv(dynamic v, double d) {
    final f = double.tryParse(v?.toString() ?? '');
    if (f == null || f < 0) return d;
    return f;
  }

  static int _intv(dynamic v, int d) => _numv(v, d.toDouble()).round();

  static Map<String, _DayRecord> foldByDay(List<Map<String, dynamic>> rows) {
    final indexed = [
      for (var i = 0; i < rows.length; i++) MapEntry(i, rows[i])
    ];
    indexed.sort((a, b) {
      final ia = a.value['id'] is int ? a.value['id'] as int : 1000000000000;
      final ib = b.value['id'] is int ? b.value['id'] as int : 1000000000000;
      if (ia != ib) return ia.compareTo(ib);
      return a.key.compareTo(b.key);
    });
    final days = <String, _DayRecord>{};
    for (final e in indexed) {
      final r = e.value;
      final d = _parse(r['date']);
      if (d == null) continue;
      final key = d.toIso8601String().split('T').first;
      final rec = days.putIfAbsent(key, _DayRecord.new);
      rec.water += _intv(r['water'], 0);
      rec.sleep += _numv(r['sleep'], 0);
      final diet = (r['diet'] ?? '').toString().trim();
      if (diet.isNotEmpty) rec.diet = diet;
      if (r['water_goal'] != null && r['water_goal'].toString().isNotEmpty) {
        rec.waterGoal = math.max(1, _intv(r['water_goal'], _defaultWaterGoal));
      }
      if (r['sleep_goal'] != null && r['sleep_goal'].toString().isNotEmpty) {
        rec.sleepGoal =
            math.max(1.0, _numv(r['sleep_goal'], _defaultSleepGoal));
      }
    }
    return days;
  }

  static _Ratio _ratio(num value, num goal) {
    final g = goal > 0 ? goal : 0;
    final raw = g > 0 ? value / g : 0.0;
    final ring = raw < 0 ? 0.0 : (raw > 1 ? 1.0 : raw.toDouble());
    return _Ratio(value, g, double.parse(raw.toStringAsFixed(4)),
        double.parse(ring.toStringAsFixed(4)), raw >= 1.0);
  }

  static _DayView _dayView(String iso, _DayRecord? rec, bool logged) {
    final r = rec ?? _DayRecord();
    return _DayView(
      date: iso,
      water: _ratio(r.water, r.waterGoal),
      sleep: _ratio(r.sleep, r.sleepGoal),
      diet: r.diet,
      logged: logged,
    );
  }

  static _DayView todayView(List<Map<String, dynamic>> rows, String todayIso) {
    final days = foldByDay(rows);
    final rec = days[todayIso];
    return _dayView(todayIso, rec, rec != null);
  }

  static _Trend trend(List<Map<String, dynamic>> rows, String todayIso,
      {int days = 7}) {
    final t = DateTime.tryParse(todayIso);
    final folded = foldByDay(rows);
    if (t == null) {
      return const _Trend(
          days: 7,
          series: [],
          avgWater: 0,
          avgSleep: 0,
          loggedDays: 0,
          waterGoalDays: 0,
          sleepGoalDays: 0);
    }
    final start = DateTime(t.year, t.month, t.day)
        .subtract(Duration(days: days - 1));
    final series = <_DayView>[];
    int logged = 0, waterGoal = 0, sleepGoal = 0;
    num sumWater = 0;
    double sumSleep = 0;
    for (var i = 0; i < days; i++) {
      final d = start.add(Duration(days: i));
      final iso = d.toIso8601String().split('T').first;
      final rec = folded[iso];
      final isLogged = rec != null;
      final v = _dayView(iso, rec, isLogged);
      series.add(v);
      if (isLogged) {
        logged++;
        sumWater += rec.water;
        sumSleep += rec.sleep;
        if (v.water.met) waterGoal++;
        if (v.sleep.met) sleepGoal++;
      }
    }
    return _Trend(
      days: days,
      series: series,
      avgWater: logged == 0
          ? 0
          : double.parse((sumWater / logged).toStringAsFixed(2)),
      avgSleep: logged == 0
          ? 0
          : double.parse((sumSleep / logged).toStringAsFixed(2)),
      loggedDays: logged,
      waterGoalDays: waterGoal,
      sleepGoalDays: sleepGoal,
    );
  }

  static _Streaks streaks(List<Map<String, dynamic>> rows, String todayIso) {
    final folded = foldByDay(rows);
    final w = _streak(folded, todayIso, 'water');
    final s = _streak(folded, todayIso, 'sleep');
    return _Streaks(w[0], w[1], s[0], s[1]);
  }

  static bool _metOn(
      Map<String, _DayRecord> folded, DateTime d, String metric) {
    final rec = folded[d.toIso8601String().split('T').first];
    if (rec == null) return false;
    final v = _dayView('', rec, true);
    return metric == 'water' ? v.water.met : v.sleep.met;
  }

  static List<int> _streak(
      Map<String, _DayRecord> folded, String todayIso, String metric) {
    final t = DateTime.tryParse(todayIso);
    if (t == null || folded.isEmpty) return [0, 0];
    final today = DateTime(t.year, t.month, t.day);
    // current
    var cur = 0;
    var anchor = _metOn(folded, today, metric)
        ? today
        : today.subtract(const Duration(days: 1));
    var d = anchor;
    while (_metOn(folded, d, metric)) {
      cur++;
      d = d.subtract(const Duration(days: 1));
    }
    // best
    final dates = folded.keys.map((k) => DateTime.parse(k)).toList()..sort();
    var best = 0, run = 0;
    DateTime? prev;
    for (final cd in dates) {
      final isMet = _metOn(folded, cd, metric);
      if (!isMet) {
        run = 0;
        prev = cd;
        continue;
      }
      if (prev != null && cd.difference(prev).inDays == 1 && run > 0) {
        run++;
      } else {
        run = 1;
      }
      if (run > best) best = run;
      prev = cd;
    }
    return [cur, best];
  }
}
