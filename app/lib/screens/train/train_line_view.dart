import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;

/// sjtrain (Safe Journey V2, TRAIN 6): the train's stations as a vertical 2D
/// line, like a metro map. Passed stations are grey, the train icon sits at
/// the current point ("Now: passing X"), the next stations show their ETA
/// (timetable + live delay; always an estimate). Timetable stops are bold.
/// Data: GET /train/<no>/live -> "line" (backend train_geo.line_view).
class TrainLineView extends StatefulWidget {
  const TrainLineView({super.key, required this.line, this.live = false, this.onStation});

  /// {"stations": [{id, bn, en, km, stop, eta, passed}], "now_index",
  ///  "passing", "next_index"}
  final Map<String, dynamic> line;

  /// true = the position comes from passengers (else timetable estimate).
  final bool live;

  /// Tap on an upcoming station (e.g. "Set the get-off alarm here").
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
          trainAfter: nowI != null && i == nowI && passing != nowI && i < st.length - 1));
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
      {required bool first, required bool last, required bool trainOn, required bool trainAfter}) {
    final passed = s['passed'] == true;
    final stop = s['stop'] == true;
    final name = trainLineName(s, bn);
    final time = notifLocalizeDigits(context, _hm('${s['eta']}'));
    final grey = cs.onSurface.withValues(alpha: 0.45);
    final lineDone = cs.outlineVariant;
    final lineAhead = cs.primary;
    final nameStyle = (stop ? AType.titleSmall : AType.bodyMedium).copyWith(
        color: passed && !trainOn ? grey : cs.onSurface,
        fontWeight: stop ? FontWeight.w700 : FontWeight.w400);
    final state = trainOn ? t.sjtHere : (passed ? t.sjtPassed : t.sjtAhead);
    final canTap = !passed && widget.onStation != null;
    final body = Semantics(
      container: true,
      button: canTap,
      label: t.sjtStationA11y(name, state, passed ? '' : time),
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
                    top: first ? null : (passed ? lineDone : lineAhead),
                    bottom: last ? null : (passed && !trainOn ? lineDone : lineAhead),
                    dot: passed && !trainOn ? lineDone : lineAhead,
                    hole: cs.surface,
                    big: stop,
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
                        if (trainOn)
                          Text(t.sjtNowPassing(name),
                              style: AType.labelMedium.copyWith(
                                  color: cs.primary, fontWeight: FontWeight.w700)),
                      ]),
                ),
              ),
              if (!passed || trainOn)
                Padding(
                  padding: const EdgeInsets.only(left: Gap.sm),
                  child: Center(
                    child: Text(time.isEmpty ? '' : '≈ $time',
                        style: AType.bodyMedium.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: cs.onSurfaceVariant)),
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
        child: Row(children: [
          SizedBox(
            width: 48,
            height: 44,
            child: CustomPaint(
              painter: _RailPainter(top: lineDone, bottom: lineAhead, hole: cs.surface),
              child: Center(child: _TrainBadge(color: cs.primary, on: cs.onPrimary)),
            ),
          ),
          Expanded(
            child: Text(t.sjtBetween(name),
                style: AType.labelMedium.copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    ]);
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
  _RailPainter({this.top, this.bottom, this.dot, required this.hole, this.big = false});
  final Color? top, bottom, dot;
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
      if (big) {
        canvas.drawCircle(Offset(x, mid), r - 3.5, Paint()..color = hole);
      }
    }
  }

  @override
  bool shouldRepaint(_RailPainter o) =>
      o.top != top || o.bottom != bottom || o.dot != dot || o.hole != hole || o.big != big;
}
