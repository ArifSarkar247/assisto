import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;

/// sjtrain (Safe Journey V2, TRAIN 6): the train's stations as a vertical 2D
/// line, like a metro map. Passed stations are green (V2), the train icon sits at
/// the current point ("Now: passing X"), the next stations show their ETA
/// (timetable + live delay; always an estimate). Timetable stops are bold.
/// Data: GET /train/<no>/live -> "line" (backend train_geo.line_view).
///
/// train-app (Train Tracker V2, owner order 17 Nov): Design System V2 metro
/// timeline — PASSED stations green with the actual time (when riders /
/// check-ins confirmed it, else the timetable time) and the delay; the TRAIN
/// icon with its speed and how many riders share live; the NEXT station
/// yellow with its ETA; later stations grey. Plain widgets + one tiny
/// painter (GPU-light, no animation), so it stays smooth on old phones.
class TrainLineView extends StatefulWidget {
  const TrainLineView(
      {super.key,
      required this.line,
      this.live = false,
      this.onStation,
      this.speedKmh,
      this.riders = 0});

  /// live speed (km/h) shown on the train icon (null = not known)
  final int? speedKmh;

  /// riders sharing live right now
  final int riders;

  /// {"stations": [{id, bn, en, km, stop, eta, passed}], "now_index",
  ///  "passing", "next_index"}
  final Map<String, dynamic> line;

  /// true = the position comes from passengers (else timetable estimate).
  final bool live;

  /// Tap on a station: check-in (reached / left) or the get-off alarm.
  final void Function(Map<String, dynamic> station)? onStation;

  /// How many stations are shown before "Show all" (2 passed + here + next).
  static const int collapsedAfter = 6;

  @override
  State<TrainLineView> createState() => _TrainLineViewState();
}

String trainLineName(Map? s, bool bn) {
  if (s == null) return '';
  final b = '${s['bn'] ?? ''}', e = '${s['en'] ?? ''}';
  return bn && b.isNotEmpty ? b : (e.isNotEmpty ? e : b);
}

String _hm(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// The one-line status under the header: "Now: passing X" or "Next: Y · 10:45".
String? trainLineStatus(AppLocalizations t, Map<String, dynamic>? line, bool bn) {
  if (line == null) return null;
  final st = [for (final s in (line['stations'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
  final passing = (line['passing'] as num?)?.toInt();
  if (passing != null && passing >= 0 && passing < st.length) {
    return t.sjtNowPassing(trainLineName(st[passing], bn));
  }
  final next = (line['next_index'] as num?)?.toInt();
  if (next != null && next >= 0 && next < st.length) {
    return t.sjtNextAt(trainLineName(st[next], bn), _hm('${st[next]['eta']}'));
  }
  return null;
}

class _TrainLineViewState extends State<TrainLineView> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final cs = Theme.of(context).colorScheme;
    final st = [
      for (final s in (widget.line['stations'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)
    ];
    if (st.isEmpty) return const SizedBox.shrink();
    final nowI = (widget.line['now_index'] as num?)?.toInt();
    final passing = (widget.line['passing'] as num?)?.toInt();
    final nextI = (widget.line['next_index'] as num?)?.toInt();
    // the window: two passed stations before the train, then what is ahead
    final from = _all ? 0 : ((nowI ?? 0) - 2).clamp(0, st.length - 1);
    final to = _all ? st.length : (from + TrainLineView.collapsedAfter + 2).clamp(0, st.length);
    final rows = <Widget>[];
    if (from > 0) {
      rows.add(_ellipsis(cs, t.sjtPassedCount(notifLocalizeDigits(context, '$from'))));
    }
    for (var i = from; i < to; i++) {
      // the train sits ON a station (passing) or BETWEEN i and i+1
      final trainHere = nowI != null && i == nowI && passing == nowI;
      rows.add(_row(context, t, bn, cs, st[i],
          first: i == 0,
          last: i == st.length - 1,
          trainOn: trainHere,
          trainAfter: nowI != null && i == nowI && passing != nowI && i < st.length - 1,
          isNext: nextI != null && i == nextI && !trainHere));
    }
    if (to < st.length) {
      rows.add(_ellipsis(cs, t.sjtMoreAhead(notifLocalizeDigits(context, '${st.length - to}'))));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...rows,
      if (st.length > TrainLineView.collapsedAfter + 2)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey('sjt_line_toggle'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: Icon(_all ? Icons.unfold_less_rounded : Icons.unfold_more_rounded),
            label: Text(_all
                ? t.sjtShowLess
                : t.sjtShowAll(notifLocalizeDigits(context, '${st.length}'))),
            onPressed: () => setState(() => _all = !_all),
          ),
        ),
    ]);
  }

  Widget _ellipsis(ColorScheme cs, String text) => Padding(
        padding: const EdgeInsets.only(left: 0),
        child: Row(children: [
          SizedBox(
            width: 48,
            height: 32,
            child: Center(child: Icon(Icons.more_vert_rounded, color: cs.outline, size: 20)),
          ),
          Expanded(child: Text(text, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant))),
        ]),
      );

  Widget _row(BuildContext context, AppLocalizations t, bool bn, ColorScheme cs,
      Map<String, dynamic> s,
      {required bool first,
      required bool last,
      required bool trainOn,
      required bool trainAfter,
      required bool isNext}) {
    final ds = cs.ds;
    final passed = s['passed'] == true;
    final stop = s['stop'] == true;
    final name = trainLineName(s, bn);
    // passed: the actual time riders / check-ins confirmed, else the timetable
    final actual = '${s['actual'] ?? ''}';
    final time = notifLocalizeDigits(
        context, _hm(passed && actual.isNotEmpty ? actual : '${s[passed ? 'sched' : 'eta'] ?? s['eta']}'));
    final delay = (s['delay_min'] as num?)?.toInt();
    final green = ds.success, greenInk = ds.successInk;
    final amber = trainAmber(context), amberInk = Brand.warnInk(context);
    final grey = ds.muted;
    final done = passed && !trainOn;
    // design3: upcoming dots in a visible muted tone (ds.border nearly vanished on the page)
    final dotColor = done ? green : (trainOn ? cs.primary : (isNext ? amber : grey.withValues(alpha: 0.55)));
    final nameStyle = (stop || isNext ? AType.titleSmall : AType.bodyMedium).copyWith(
        // design3: passed names in the text ink (the green rail + time say "passed")
        color: done ? ds.text : (isNext ? cs.onSurface : (trainOn ? cs.onSurface : grey)),
        fontWeight: stop || isNext ? FontWeight.w700 : FontWeight.w400);
    final state = trainOn
        ? t.sjtHere
        : (passed ? t.sjtPassed : (isNext ? t.tr2NextBadge : t.sjtAhead));
    final delayText = delay == null
        ? ''
        : (delay <= 2 ? t.sjtOnTimeChip : notifLocalizeDigits(context, t.tr2DelayShort('$delay')));
    final canTap = widget.onStation != null;
    final body = Semantics(
      container: true,
      button: canTap,
      label: t.sjtStationA11y(name, delayText.isEmpty ? state : '$state, $delayText', time),
      excludeSemantics: true,
      child: InkWell(
        onTap: canTap ? () => widget.onStation!(s) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 48,
                child: CustomPaint(
                  painter: _RailPainter(
                    top: first ? null : (passed ? green : grey.withValues(alpha: 0.45)),
                    bottom: last ? null : (done ? green : grey.withValues(alpha: 0.45)),
                    dot: dotColor,
                    ring: isNext ? amberInk : null,
                    hole: cs.surface,
                    big: stop || isNext,
                  ),
                  child: trainOn
                      ? Center(child: _TrainBadge(color: cs.primary, on: cs.onPrimary))
                      : null,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(name, style: nameStyle),
                        if (trainOn) ...[
                          Text(t.sjtNowPassing(name),
                              style: AType.labelMedium.copyWith(
                                  color: cs.primary, fontWeight: FontWeight.w700)),
                          _TrainFacts(speedKmh: widget.speedKmh, riders: widget.riders),
                        ],
                        if (isNext)
                          Text(t.tr2NextBadge,
                              key: const ValueKey('tr2_next'),
                              style: AType.labelMedium.copyWith(
                                  color: amberInk, fontWeight: FontWeight.w700)),
                      ]),
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: Gap.sm),
                child: Center(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (time.isNotEmpty)
                          Text(done ? time : '≈ $time',
                              style: AType.bodyMedium.copyWith(
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                  fontWeight: isNext ? FontWeight.w700 : FontWeight.w400,
                                  color: done ? greenInk : (isNext ? amberInk : grey))),
                        if (done && delayText.isNotEmpty)
                          Text(delayText,
                              style: AType.labelSmall.copyWith(
                                  color: delay! > 2 ? ds.dangerInk : greenInk,
                                  fontWeight: FontWeight.w700)),
                      ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    if (!trainAfter) return body;
    // the train between this station and the next
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      body,
      Semantics(
        container: true,
        label: t.sjtBetweenA11y(name),
        excludeSemantics: true,
        // design3: where the train is now — a soft primary band so the eye
        // finds it at once
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.ds.primarySoft,
            borderRadius: BorderRadius.circular(DsRadius.card),
          ),
          child: Row(children: [
          SizedBox(
            width: 48,
            height: 56,
            child: CustomPaint(
              painter: _RailPainter(top: green, bottom: grey.withValues(alpha: 0.45), hole: cs.surface),
              child: Center(child: _TrainBadge(color: cs.primary, on: cs.onPrimary)),
            ),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.sjtBetween(name),
                  style: AType.labelLarge.copyWith(color: cs.ds.primaryInk, fontWeight: FontWeight.w800)),
              _TrainFacts(speedKmh: widget.speedKmh, riders: widget.riders),
            ]),
          ),
        ]),
        ),
      ),
    ]);
  }
}

/// The "next station" yellow: a warm amber dot (the text next to it uses
/// Brand.warnInk, AA on both themes).
Color trainAmber(BuildContext context) => Brand.nextStop(context);

/// Speed + live riders next to the train icon ("62 km/h · 3 riders live").
class _TrainFacts extends StatelessWidget {
  const _TrainFacts({this.speedKmh, this.riders = 0});
  final int? speedKmh;
  final int riders;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final parts = <String>[
      if (speedKmh != null) t.tr2Speed('$speedKmh'),
      if (riders > 0) t.tr2RidersLive('$riders'),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(notifLocalizeDigits(context, parts.join(' · ')),
        key: const ValueKey('tr2_train_facts'),
        style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.ds.muted));
  }
}

class _TrainBadge extends StatelessWidget {
  const _TrainBadge({required this.color, required this.on});
  final Color color, on;

  @override
  Widget build(BuildContext context) => Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(Icons.train_rounded, size: 18, color: on),
      );
}

class _RailPainter extends CustomPainter {
  _RailPainter({this.top, this.bottom, this.dot, this.ring, required this.hole, this.big = false});
  final Color? top, bottom, dot, ring;
  final Color hole;
  final bool big;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final mid = size.height / 2;
    final p = Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.butt;
    if (top != null) canvas.drawLine(Offset(x, 0), Offset(x, mid), p..color = top!);
    if (bottom != null) {
      canvas.drawLine(Offset(x, mid), Offset(x, size.height), p..color = bottom!);
    }
    if (dot != null) {
      final r = big ? 8.0 : 5.0;
      canvas.drawCircle(Offset(x, mid), r, Paint()..color = dot!);
      if (ring != null) {
        canvas.drawCircle(
            Offset(x, mid),
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = ring!);
      } else if (big) {
        canvas.drawCircle(Offset(x, mid), r - 3.5, Paint()..color = hole);
      }
    }
  }

  @override
  bool shouldRepaint(_RailPainter o) =>
      o.top != top ||
      o.bottom != bottom ||
      o.dot != dot ||
      o.ring != ring ||
      o.hole != hole ||
      o.big != big;
}
