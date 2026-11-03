// p3guides (owner PART 3, flag official_corners): Student corner study timer.
// Focus 25/50 min + break 5/10 min; studied minutes are saved on the phone per
// day (today + last 7 days). Works offline. Honest limit: the timer runs while
// this screen is open (no background service by design) — said on screen.
// Time is measured from the start instant, so a slow frame never drifts it.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart' show Settings;
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/local_digits.dart';

const String kStudyMinutesKey = 'study_minutes_v1';

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Pure: minutes studied today and in the 7 days ending [now] from the saved
/// {yyyy-mm-dd: minutes} map.
({int today, int week}) studyTotals(Map<String, int> log, DateTime now) {
  var week = 0;
  for (var i = 0; i < 7; i++) {
    week += log[_day(now.subtract(Duration(days: i)))] ?? 0;
  }
  return (today: log[_day(now)] ?? 0, week: week);
}

/// mm:ss for [secs] left.
String studyClock(int secs) {
  final s = secs < 0 ? 0 : secs;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

class StudyTimerTab extends StatefulWidget {
  /// Test seam: the clock.
  final DateTime Function() now;
  const StudyTimerTab({super.key, this.now = DateTime.now});
  @override
  State<StudyTimerTab> createState() => _StudyTimerTabState();
}

class _StudyTimerTabState extends State<StudyTimerTab>
    with AutomaticKeepAliveClientMixin {
  int _focusMin = 25;
  bool _onBreak = false;
  DateTime? _startedAt; // running since
  int _elapsedBefore = 0; // seconds banked before the last pause
  Timer? _tick;
  Map<String, int> _log = {};
  bool _justDone = false;

  @override
  bool get wantKeepAlive => true;

  int get _totalSecs => (_onBreak ? (_focusMin == 50 ? 10 : 5) : _focusMin) * 60;
  bool get _running => _startedAt != null;
  int get _elapsed =>
      _elapsedBefore +
      (_startedAt == null ? 0 : widget.now().difference(_startedAt!).inSeconds);

  @override
  void initState() {
    super.initState();
    _readLog();
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (!_onBreak) _bank(_elapsed); // honest: count what was studied
    super.dispose();
  }

  Future<void> _readLog() async {
    final raw = await Settings.getString(kStudyMinutesKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      _log = {for (final e in m.entries) e.key: (e.value as num).toInt()};
      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _bank(int secs) {
    final mins = secs ~/ 60;
    if (mins <= 0) return;
    final k = _day(widget.now());
    _log[k] = (_log[k] ?? 0) + mins;
    // keep 60 days
    if (_log.length > 60) {
      final keys = _log.keys.toList()..sort();
      for (final old in keys.take(_log.length - 60)) {
        _log.remove(old);
      }
    }
    Settings.setString(kStudyMinutesKey, jsonEncode(_log));
  }

  void _start() {
    setState(() {
      _justDone = false;
      _startedAt = widget.now();
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _pause() {
    _tick?.cancel();
    setState(() {
      _elapsedBefore = _elapsed;
      _startedAt = null;
    });
  }

  void _stop() {
    _tick?.cancel();
    if (!_onBreak) _bank(_elapsed);
    setState(() {
      _startedAt = null;
      _elapsedBefore = 0;
      _onBreak = false;
    });
  }

  void _onTick() {
    if (!mounted) return;
    if (_elapsed >= _totalSecs) {
      _tick?.cancel();
      HapticFeedback.heavyImpact();
      setState(() {
        if (!_onBreak) {
          _bank(_totalSecs);
          _justDone = true;
        }
        _onBreak = !_onBreak;
        _startedAt = null;
        _elapsedBefore = 0;
      });
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final t = studyTotals(_log, widget.now());
    final left = _totalSecs - _elapsed;
    final idle = !_running && _elapsedBefore == 0;
    return ListView(
      key: const ValueKey('p3g-timer'),
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
      children: [
        if (idle)
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final m in const [25, 50])
              ChoiceChip(
                key: ValueKey('p3g-focus-$m'),
                label: Text(tr.p3gTimerFocus(ld(context, m))),
                selected: _focusMin == m && !_onBreak,
                onSelected: (_) => setState(() {
                  _focusMin = m;
                  _onBreak = false;
                }),
              ),
          ]),
        const SizedBox(height: Gap.lg),
        Text(
          _onBreak
              ? tr.p3gTimerBreak(ld(context, _totalSecs ~/ 60))
              : tr.p3gTimerFocus(ld(context, _focusMin)),
          textAlign: TextAlign.center,
          style: AType.titleMedium.copyWith(color: scheme.onSurfaceVariant),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(ld(context, studyClock(left)),
              key: const ValueKey('p3g-clock'),
              style: AType.displayLarge.copyWith(
                  fontWeight: FontWeight.w800,
                  color: _onBreak ? scheme.tertiary : scheme.primary)),
        ),
        const SizedBox(height: Gap.md),
        Wrap(alignment: WrapAlignment.center, spacing: Gap.sm, runSpacing: Gap.sm, children: [
          if (_running)
            FilledButton.tonalIcon(
              key: const ValueKey('p3g-pause'),
              onPressed: _pause,
              icon: const Icon(Icons.pause_rounded),
              label: Text(tr.p3gTimerPause),
            )
          else
            FilledButton.icon(
              key: const ValueKey('p3g-start'),
              onPressed: _start,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(idle ? tr.p3gTimerStart : tr.p3gTimerResume),
            ),
          if (!idle)
            OutlinedButton.icon(
              key: const ValueKey('p3g-stop'),
              onPressed: _stop,
              icon: const Icon(Icons.stop_rounded),
              label: Text(tr.p3gTimerStop),
            ),
        ]),
        if (_justDone)
          Padding(
            padding: const EdgeInsets.only(top: Gap.md),
            child: Text(tr.p3gTimerDone,
                textAlign: TextAlign.center,
                style: AType.bodyLarge.copyWith(color: scheme.primary)),
          ),
        const SizedBox(height: Gap.xl),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr.p3gTimerToday(ld(context, t.today)),
                  key: const ValueKey('p3g-today'),
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Text(tr.p3gTimerWeek(ld(context, t.week)), style: AType.bodyMedium),
            ]),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(tr.p3gTimerHint,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }
}
