import 'package:flutter/material.dart';
import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// #70 SMARTWATCH & FITNESS — Health Connect bridge (SPEC: wearables).
///
/// Reads the user's own health data from Android Health Connect via the
/// `health` package (which talks to Health Connect natively — ZERO custom
/// Kotlin). We request read access to steps, heart rate, sleep and active
/// energy, then surface:
///   - TODAY: steps, resting-ish heart rate (latest sample today), sleep hours,
///     active energy (kcal).
///   - 7-DAY: a per-day steps bar chart + simple totals/averages.
///
/// This SURFACES Health Connect data; it does NOT duplicate the app's own
/// wellness/fitness storage. From here the user can jump to the existing
/// Wellness tracker / Fitness partner to log goals — those remain the system of
/// record. (A "copy today's steps into Fitness" convenience is intentionally a
/// documented follow-up, not built, to avoid silent double-writes.)
///
/// Honest states (never a dead tap):
///   checking · Health Connect not installed (→ Play Store / open settings) ·
///   permission denied (→ request again / Open settings) · connected-no-data ·
///   connected-with-data · error.
///
/// ZERO Bangla literals — every string is an AppLocalizations getter.
///
/// DEVICE-TEST-ONLY: Health Connect + a paired watch/phone with real samples
/// are required to see live data. In headless CI the screen compiles and shows
/// the honest "checking → not available" path (the plugin reports unavailable).
class SmartwatchScreen extends StatefulWidget {
  const SmartwatchScreen({super.key});
  @override
  State<SmartwatchScreen> createState() => _SmartwatchScreenState();
}

/// The health data types we read. Order matters only for display grouping.
const List<HealthDataType> _types = [
  HealthDataType.STEPS,
  HealthDataType.HEART_RATE,
  HealthDataType.SLEEP_ASLEEP,
  HealthDataType.ACTIVE_ENERGY_BURNED,
];

const List<HealthDataAccess> _access = [
  HealthDataAccess.READ,
  HealthDataAccess.READ,
  HealthDataAccess.READ,
  HealthDataAccess.READ,
];

enum _Phase { checking, unavailable, needsPermission, loading, ready, error }

/// Trend window lengths offered by the toggle. 7 is the default; the longest
/// entry also drives how far back we fetch from Health Connect, so the shorter
/// windows are a pure re-fold of already-loaded data (no extra I/O).
const List<int> _windowDays = [7, 30, 90];
const int _maxWindowDays = 90;

class _SmartwatchScreenState extends State<SmartwatchScreen>
    with WidgetsBindingObserver {
  final Health _health = Health();
  _Phase _phase = _Phase.checking;
  _Summary? _summary;
  // Raw (de-duplicated) points for the longest window, kept so the trend toggle
  // can re-fold over 7 / 30 / 90 days without re-querying Health Connect.
  List<HealthDataPoint> _points = const [];
  int? _loadedTodaySteps;
  int _window = 7;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// hc1: back from the Play Store / Health Connect after tapping Install —
  /// check again so the screen never stays on "not installed" after the user
  /// actually installed (or updated) Health Connect.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        mounted &&
        _phase == _Phase.unavailable) {
      _boot();
    }
  }

  Future<void> _boot() async {
    setState(() => _phase = _Phase.checking);
    try {
      await _health.configure();
    } catch (_) {
      // configure() can throw on unsupported platforms — treat as unavailable.
      if (mounted) setState(() => _phase = _Phase.unavailable);
      return;
    }
    // Is Health Connect present/usable on this device?
    HealthConnectSdkStatus? status;
    try {
      status = await _health.getHealthConnectSdkStatus();
    } catch (_) {
      status = null;
    }
    // hc1: anything but "available" — not installed (common on ColorOS /
    // Android 13), installed but needs a Play Store update, or the plugin
    // could not answer — shows the honest install/update step. Connecting
    // would only fail in those states, so never offer it.
    if (status != HealthConnectSdkStatus.sdkAvailable) {
      if (mounted) setState(() => _phase = _Phase.unavailable);
      return;
    }
    // Already granted? Jump straight to loading.
    bool granted = false;
    try {
      granted = await _health.hasPermissions(_types, permissions: _access) ??
          false;
    } catch (_) {
      granted = false;
    }
    if (granted) {
      await _loadData();
    } else {
      if (mounted) setState(() => _phase = _Phase.needsPermission);
    }
  }

  Future<void> _requestPermission() async {
    setState(() => _phase = _Phase.checking);
    // On Android 14+ reading in the background / activity recognition may be
    // required by the OEM; request the common runtime permission defensively.
    try {
      await Permission.activityRecognition.request();
    } catch (_) {}
    bool ok = false;
    try {
      ok = await _health.requestAuthorization(_types, permissions: _access);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      await _loadData();
    } else {
      setState(() => _phase = _Phase.needsPermission);
    }
  }

  /// Open Health Connect's own settings (where the user can grant/revoke per
  /// data type), falling back to the app's system settings page. Never a dead
  /// tap: one of these always resolves.
  Future<void> _openSettings() async {
    try {
      await _health.installHealthConnect();
      return;
    } catch (_) {}
    try {
      await openAppSettings();
    } catch (_) {}
  }

  Future<void> _loadData() async {
    setState(() => _phase = _Phase.loading);
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    // Fetch the longest window up-front so shorter windows are a pure re-fold.
    final rangeStart = todayStart.subtract(const Duration(days: _maxWindowDays - 1));
    try {
      List<HealthDataPoint> points = await _health.getHealthDataFromTypes(
        types: _types,
        startTime: rangeStart,
        endTime: now,
      );
      points = _health.removeDuplicates(points);
      // Steps are best fetched via the aggregate helper where available.
      int? todaySteps;
      try {
        todaySteps =
            await _health.getTotalStepsInInterval(todayStart, now);
      } catch (_) {
        todaySteps = null;
      }
      if (mounted) {
        setState(() {
          _points = points;
          _loadedTodaySteps = todaySteps;
          _summary = _Summary.from(points, now, todaySteps, _window);
          _phase = _Phase.ready;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.error);
    }
  }

  /// Re-fold the already-loaded points over a new trend window. No I/O.
  void _setWindow(int days) {
    if (days == _window) return;
    setState(() {
      _window = days;
      _summary =
          _Summary.from(_points, DateTime.now(), _loadedTodaySteps, days);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.swTitle), actions: [
        if (_phase == _Phase.ready || _phase == _Phase.needsPermission)
          IconButton(
            tooltip: tr.swOpenSettings,
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
      ]),
      body: switch (_phase) {
        _Phase.checking || _Phase.loading => const SkeletonList(),
        _Phase.unavailable => _unavailable(tr),
        _Phase.needsPermission => _needsPermission(tr),
        _Phase.error => StateMessage(
            icon: Icons.cloud_off,
            tint: scheme.error,
            title: tr.swErrorTitle,
            message: tr.swErrorBody,
            action: FilledButton.tonalIcon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry),
            ),
          ),
        _Phase.ready => _ready(tr),
      },
    );
  }

  Widget _unavailable(AppLocalizations tr) => ListView(children: [
        StateMessage(
          icon: Icons.watch_off_outlined,
          tint: Brand.purple,
          title: tr.swUnavailableTitle,
          message: tr.swUnavailableBody2,
          action: FilledButton.icon(
            onPressed: _openSettings,
            icon: const Icon(Icons.download_outlined),
            label: Text(tr.swInstall),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.lg),
          child: _PrivacyNote(),
        ),
      ]);

  Widget _needsPermission(AppLocalizations tr) => ListView(children: [
        StateMessage(
          icon: Icons.watch_outlined,
          tint: Brand.blue,
          title: tr.swConnectTitle,
          message: tr.swConnectBody,
          action: FilledButton.icon(
            onPressed: _requestPermission,
            icon: const Icon(Icons.link),
            label: Text(tr.swConnect),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
          child: Center(
            child: TextButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: Text(tr.swOpenSettings),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg),
          child: _PrivacyNote(),
        ),
      ]);

  Widget _ready(AppLocalizations tr) {
    final s = _summary!;
    final hasAny = s.hasAnyData;
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl),
        children: [
          if (!hasAny)
            StateMessage(
              icon: Icons.favorite_outline,
              tint: Brand.cyan,
              title: tr.swNoDataTitle,
              message: tr.swNoDataBody,
            )
          else ...[
            Text(tr.swToday,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            _TodayGrid(summary: s),
            const SizedBox(height: Gap.lg),
            _StepsWeekCard(
              summary: s,
              window: _window,
              onWindowChanged: _setWindow,
            ),
          ],
          const SizedBox(height: Gap.lg),
          const _SurfaceLinks(),
          const SizedBox(height: Gap.md),
          const _PrivacyNote(),
        ],
      ),
    );
  }
}

// ======================= TODAY GRID =======================
class _TodayGrid extends StatelessWidget {
  final _Summary summary;
  const _TodayGrid({required this.summary});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Column(children: [
      Row(children: [
        Expanded(
          child: _Metric(
            icon: Icons.directions_walk,
            color: Brand.blue,
            label: tr.swSteps,
            value: summary.todaySteps == null
                ? tr.swNoReading
                : _fmtInt(summary.todaySteps!),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: _Metric(
            icon: Icons.favorite,
            color: Brand.danger,
            label: tr.swHeartRate,
            value: summary.latestHeartRate == null
                ? tr.swNoReading
                : tr.swBpm(summary.latestHeartRate!.round()),
          ),
        ),
      ]),
      const SizedBox(height: Gap.md),
      Row(children: [
        Expanded(
          child: _Metric(
            icon: Icons.bedtime_outlined,
            color: Brand.purple,
            label: tr.swSleep,
            value: summary.todaySleepMinutes == null
                ? tr.swNoReading
                : tr.swHours(_fmtHours(summary.todaySleepMinutes!)),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: _Metric(
            icon: Icons.local_fire_department_outlined,
            color: Brand.warning,
            label: tr.swActiveEnergy,
            value: summary.todayEnergyKcal == null
                ? tr.swNoReading
                : tr.swKcal(summary.todayEnergyKcal!.round()),
          ),
        ),
      ]),
    ]);
  }
}

class _Metric extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  const _Metric(
      {required this.icon,
      required this.color,
      required this.label,
      required this.value});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: Gap.sm),
          Text(value,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          Text(label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

// ======================= STEPS TREND (7 / 30 / 90) =======================
class _StepsWeekCard extends StatelessWidget {
  final _Summary summary;
  final int window;
  final ValueChanged<int> onWindowChanged;
  const _StepsWeekCard(
      {required this.summary,
      required this.window,
      required this.onWindowChanged});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final series = summary.stepsByDay; // `window` entries, oldest → newest
    final maxVal = series.fold<int>(0, (m, e) => e.steps > m ? e.steps : m);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(tr.swSteps,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            _WindowToggle(window: window, onChanged: onWindowChanged),
          ]),
          const SizedBox(height: Gap.xs),
          Text(
            summary.weekStepsTotal == 0
                ? tr.swStepsWeekEmpty
                : tr.swStepsWeekSummary(
                    _fmtInt(summary.weekStepsTotal),
                    _fmtInt(summary.weekStepsAvg)),
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Gap.md),
          SizedBox(
            height: 84,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final d in series)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: series.length > 14 ? 0.7 : 3),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor: maxVal == 0
                                    ? 0.04
                                    : (d.steps / maxVal).clamp(0.04, 1.0),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: d.steps > 0
                                        ? Brand.blue
                                        : scheme.outlineVariant
                                            .withValues(alpha: 0.4),
                                    borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(4)),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Per-day letters only read well on the 7-day window;
                          // wider windows show the range in the summary line.
                          if (series.length <= 7) ...[
                            const SizedBox(height: 4),
                            Text(_dayLetter(context, d.date),
                                style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.onSurfaceVariant)),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  String _dayLetter(BuildContext context, DateTime d) {
    final names = MaterialLocalizations.of(context).narrowWeekdays;
    return names[d.weekday % 7];
  }
}

// ======================= trend window toggle (7 / 30 / 90) =======================
/// Segmented 7d / 30d / 90d selector. Labels reuse the existing analytics range
/// getters ("7 days" / "30 days" / "90 days") — no new ARB keys.
class _WindowToggle extends StatelessWidget {
  final int window;
  final ValueChanged<int> onChanged;
  const _WindowToggle({required this.window, required this.onChanged});

  String _label(AppLocalizations tr, int days) {
    switch (days) {
      case 30:
        return tr.analyticsRange30d;
      case 90:
        return tr.analyticsRange90d;
      default:
        return tr.analyticsRange7d;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return SegmentedButton<int>(
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 11)),
      ),
      segments: [
        for (final d in _windowDays)
          ButtonSegment<int>(value: d, label: Text(_label(tr, d))),
      ],
      selected: {window},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

// ======================= surface links =======================
class _SurfaceLinks extends StatelessWidget {
  const _SurfaceLinks();
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.insights_outlined, size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.swSurfaceTitle,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(tr.swSurfaceBody,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ]),
          ),
        ]),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();
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
          Icon(Icons.lock_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.swPrivacyNote,
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

// ======================= formatting =======================
String _fmtInt(int v) {
  // thousands grouping with a plain comma (locale-neutral, no Bangla literal).
  final s = v.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return (v < 0 ? '-' : '') + b.toString();
}

String _fmtHours(int minutes) {
  final h = minutes / 60.0;
  if (h == h.roundToDouble()) return h.toInt().toString();
  return h.toStringAsFixed(1);
}

// ===================================================================
// _Summary — pure projection of Health Connect points into a display model.
// No I/O, no clock inside (now passed in).
// ===================================================================
class _DaySteps {
  final DateTime date;
  final int steps;
  const _DaySteps(this.date, this.steps);
}

class _Summary {
  final int? todaySteps;
  final double? latestHeartRate;
  final int? todaySleepMinutes;
  final double? todayEnergyKcal;
  final List<_DaySteps> stepsByDay; // `windowDays` entries, oldest → newest
  final int weekStepsTotal; // total over the selected window
  final int weekStepsAvg; // daily average over logged days in the window

  _Summary({
    required this.todaySteps,
    required this.latestHeartRate,
    required this.todaySleepMinutes,
    required this.todayEnergyKcal,
    required this.stepsByDay,
    required this.weekStepsTotal,
    required this.weekStepsAvg,
  });

  bool get hasAnyData =>
      (todaySteps != null && todaySteps! > 0) ||
      latestHeartRate != null ||
      (todaySleepMinutes != null && todaySleepMinutes! > 0) ||
      todayEnergyKcal != null ||
      weekStepsTotal > 0;

  static double _numVal(HealthValue v) {
    if (v is NumericHealthValue) return v.numericValue.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  static _Summary from(List<HealthDataPoint> points, DateTime now,
      int? aggregatedTodaySteps, int windowDays) {
    final todayStart = DateTime(now.year, now.month, now.day);
    final window = windowDays < 1 ? 1 : windowDays;

    // Per-day step buckets for the last `window` days (oldest → newest).
    final buckets = <DateTime, int>{};
    for (var i = window - 1; i >= 0; i--) {
      final d = todayStart.subtract(Duration(days: i));
      buckets[d] = 0;
    }

    double? latestHr;
    DateTime? latestHrAt;
    var todaySleep = 0;
    double? todayEnergy;
    var stepsFromPoints = 0; // today's steps if aggregate helper failed

    for (final p in points) {
      final start = p.dateFrom.toLocal();
      final end = p.dateTo.toLocal();
      final day = DateTime(start.year, start.month, start.day);
      final isToday = day == todayStart;
      switch (p.type) {
        case HealthDataType.STEPS:
          final v = _numVal(p.value).round();
          if (buckets.containsKey(day)) buckets[day] = buckets[day]! + v;
          if (isToday) stepsFromPoints += v;
          break;
        case HealthDataType.HEART_RATE:
          if (isToday) {
            if (latestHrAt == null || start.isAfter(latestHrAt)) {
              latestHrAt = start;
              latestHr = _numVal(p.value);
            }
          }
          break;
        case HealthDataType.SLEEP_ASLEEP:
          if (isToday) {
            final mins = end.difference(start).inMinutes;
            if (mins > 0) todaySleep += mins;
          }
          break;
        case HealthDataType.ACTIVE_ENERGY_BURNED:
          if (isToday) {
            todayEnergy = (todayEnergy ?? 0) + _numVal(p.value);
          }
          break;
        default:
          break;
      }
    }

    final todaySteps = aggregatedTodaySteps ??
        (stepsFromPoints > 0 ? stepsFromPoints : null);
    // Prefer the aggregate for today's bucket when we have it.
    if (aggregatedTodaySteps != null) {
      buckets[todayStart] = aggregatedTodaySteps;
    }

    final series = buckets.entries
        .map((e) => _DaySteps(e.key, e.value))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final total = series.fold<int>(0, (s, e) => s + e.steps);
    final loggedDays = series.where((e) => e.steps > 0).length;
    final avg = loggedDays == 0 ? 0 : (total / loggedDays).round();

    return _Summary(
      todaySteps: todaySteps,
      latestHeartRate: latestHr,
      todaySleepMinutes: todaySleep > 0 ? todaySleep : null,
      todayEnergyKcal: todayEnergy,
      stepsByDay: series,
      weekStepsTotal: total,
      weekStepsAvg: avg,
    );
  }
}
