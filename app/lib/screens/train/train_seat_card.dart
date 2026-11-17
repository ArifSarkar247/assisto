import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../train/train_api.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/local_counter.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;

/// sjtrain (Safe Journey V2, TRAIN 7): the SEAT CARD. Bangladesh Railway
/// publishes no seat orientation, so the facts come from passengers (one-tap
/// questions after a trip) and stay "unverified" until 3 different people
/// agree. The sun side is CALCULATED on the server from the rail line and
/// the timetable. The coach picture is a top view with your seat marked
/// (its place along the coach is approximate, from the seat number).
class TrainSeatCard extends StatefulWidget {
  const TrainSeatCard({super.key, required this.no, required this.date, this.tripOver = false});
  final String no, date;

  /// true after the trip (or my share arrived): the questions are offered first.
  final bool tripOver;

  @override
  State<TrainSeatCard> createState() => _TrainSeatCardState();
}

String _seatKey(String no) => 'sjt_seat_$no';

class _TrainSeatCardState extends State<TrainSeatCard> {
  String? _coach, _seat;
  Map<String, dynamic>? _v;
  bool _loading = true, _failed = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final raw = await Settings.getString(_seatKey(widget.no));
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        _coach = '${j['coach'] ?? ''}';
        _seat = '${j['seat'] ?? ''}';
      }
    } catch (_) {
      // best-effort: no saved seat
    }
    if (!mounted) return;
    if ((_coach ?? '').isEmpty || (_seat ?? '').isEmpty) {
      setState(() => _loading = false);
      return;
    }
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.trainSeat(widget.no, widget.date, _coach!, _seat!);
      if (!mounted) return;
      setState(() {
        _v = r;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _pickSeat() async {
    final t = AppLocalizations.of(context);
    final c = TextEditingController(text: _coach ?? '');
    final s = TextEditingController(text: _seat ?? '');
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.sjtSeatAddTitle, style: AType.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(t.sjtSeatAddHelp, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('sjt_coach'),
            controller: c,
            maxLength: 8,
            buildCounter: localCounter,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(labelText: t.sjtCoach),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            key: const ValueKey('sjt_seat'),
            controller: s,
            maxLength: 8,
            buildCounter: localCounter,
            decoration: InputDecoration(labelText: t.sjtSeatNo),
          ),
          const SizedBox(height: Gap.sm),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => Navigator.pop(ctx, c.text.trim().isNotEmpty && s.text.trim().isNotEmpty),
            child: Text(t.sjtSeatSave),
          ),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    _coach = c.text.trim();
    _seat = s.text.trim();
    await Settings.setString(_seatKey(widget.no), jsonEncode({'coach': _coach, 'seat': _seat}));
    await _load();
  }

  Future<void> _ask() async {
    final t = AppLocalizations.of(context);
    final mine = Map<String, dynamic>.from(_v?['mine'] as Map? ?? const {});
    String facing = '${mine['facing'] ?? ''}', place = '${mine['place'] ?? ''}',
        side = '${mine['side'] ?? ''}';
    int? pos = (mine['coach_pos'] as num?)?.toInt();
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Widget group(String q, List<(String, String)> opts, String cur, void Function(String) pick) =>
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(q, style: AType.titleSmall),
                const SizedBox(height: Gap.xs),
                Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                  for (final o in opts)
                    ChoiceChip(
                      label: Text(o.$2),
                      selected: cur == o.$1,
                      onSelected: (_) => set(() => pick(cur == o.$1 ? '' : o.$1)),
                    ),
                ]),
              ]),
            );
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.sjtAskTitle, style: AType.titleLarge),
            const SizedBox(height: Gap.xs),
            Text(t.sjtAskHelp, style: AType.bodyMedium),
            const SizedBox(height: Gap.md),
            group(t.sjtQFacing, [('forward', t.sjtFacingForward), ('backward', t.sjtFacingBackward)],
                facing, (v) => facing = v),
            group(t.sjtQPlace,
                [('window', t.sjtPlaceWindow), ('aisle', t.sjtPlaceAisle), ('middle', t.sjtPlaceMiddle)],
                place, (v) => place = v),
            group(t.sjtQSide, [('left', t.sjtSideLeft), ('right', t.sjtSideRight)], side, (v) => side = v),
            Text(t.sjtQCoachPos, style: AType.titleSmall),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
              for (var i = 1; i <= 20; i++)
                ChoiceChip(
                  label: Text(notifLocalizeDigits(ctx, '$i')),
                  selected: pos == i,
                  onSelected: (_) => set(() => pos = pos == i ? null : i),
                ),
            ]),
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              key: const ValueKey('sjt_ask_send'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.check_rounded),
              label: Text(t.sjtAskSend),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ]),
        );
      }),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await _api.trainSeatAnswer(widget.no, widget.date, _coach!, _seat!,
          facing: facing, place: place, side: side, coachPos: pos);
      if (!mounted) return;
      setState(() => _v = r);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.sjtAskThanks)));
    } catch (e) {
      if (!mounted) return;
      final s = '$e';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s.contains('not_this_trip')
              ? t.sjtAskNotTrip
              : (s.contains('empty') ? t.sjtAskEmpty : t.trLoadFailed))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final v = _v;
    return DsSurface(key: const ValueKey('sjt_seat_card'), flat: true, borderColor: Theme.of(context).colorScheme.ds.border,
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.event_seat_rounded, color: cs.primary),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.sjtSeatTitle, style: AType.titleMedium)),
          ]),
          const SizedBox(height: Gap.sm),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(Gap.md),
              child: Center(child: CircularProgressIndicator()),
            )
          else if ((_coach ?? '').isEmpty)
            ..._empty(t)
          else if (_failed || v == null)
            ..._error(t)
          else
            ..._facts(t, cs, v),
        ]),
    );
  }

  List<Widget> _empty(AppLocalizations t) => [
        Text(t.sjtSeatBenefit, style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          key: const ValueKey('sjt_seat_add'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.add_rounded),
          label: Text(t.sjtSeatAdd),
          onPressed: _pickSeat,
        ),
        const SizedBox(height: Gap.sm),
        Text(t.sjtSeatHowTo, style: AType.bodySmall),
      ];

  List<Widget> _error(AppLocalizations t) => [
        Text(t.trLoadFailed, style: AType.bodyMedium),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t.trRetry),
          onPressed: _load,
        ),
      ];

  String _d(String s) => notifLocalizeDigits(context, s);

  /// "verified · 3 people" / "unverified · 1 of 2 said this"
  String _proof(AppLocalizations t, Map? f) {
    if (f == null) return t.sjtNotKnown;
    final n = '${f['n']}', k = '${f['agree']}';
    return _d(f['verified'] == true ? t.sjtVerified(k) : t.sjtUnverified(k, n));
  }

  Widget _fact(ColorScheme cs, IconData icon, String title, String sub, {bool ok = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 22, color: ok ? cs.primary : cs.onSurfaceVariant),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AType.bodyLarge),
              Text(sub,
                  style: AType.bodySmall.copyWith(
                      color: ok ? cs.primary : Brand.warnInk(context),
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
      );

  List<Widget> _facts(AppLocalizations t, ColorScheme cs, Map<String, dynamic> v) {
    Map? f(String k) => v[k] is Map ? v[k] as Map : null;
    final facing = f('facing'), place = f('place'), side = f('side'), pos = f('coach_pos');
    final sun = f('sun');
    final onSeat = f('sun_on_seat');
    final sideV = '${side?['value'] ?? ''}';
    final placeV = '${place?['value'] ?? ''}';
    final seatNo = int.tryParse(RegExp(r'\d+').stringMatch(_seat ?? '') ?? '');
    String sunLine;
    final sunSide = '${sun?['side'] ?? 'none'}';
    if (sun == null) {
      sunLine = t.sjtNotKnown;
    } else if (sunSide == 'left' || sunSide == 'right') {
      sunLine = _d(t.sjtSunMostly(sunSide == 'left' ? t.sjtSideLeft : t.sjtSideRight,
          '${sun[sunSide]}'));
    } else {
      sunLine = t.sjtSunLittle;
    }
    return [
      Text(_d(t.sjtSeatLine(_coach ?? '', _seat ?? '')), style: AType.titleSmall),
      const SizedBox(height: Gap.sm),
      Semantics(
        image: true,
        label: t.sjtCoachPicA11y(
            sideV == 'left' ? t.sjtSideLeft : (sideV == 'right' ? t.sjtSideRight : t.sjtNotKnown),
            placeV == 'window' ? t.sjtPlaceWindow : (placeV == 'aisle' ? t.sjtPlaceAisle : t.sjtNotKnown)),
        child: AspectRatio(
          aspectRatio: 3.2,
          child: CustomPaint(
            painter: CoachTopViewPainter(
              side: sideV,
              place: placeV,
              seatNo: seatNo,
              line: cs.outline,
              seat: cs.surfaceContainerHighest,
              mark: cs.primary,
              engine: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
      Text(t.sjtCoachPicNote, style: AType.bodySmall),
      const Divider(height: Gap.lg),
      _fact(
          cs,
          Icons.swap_vert_rounded,
          facing == null
              ? t.sjtFacingQ
              : (facing['value'] == 'forward' ? t.sjtFacingForward : t.sjtFacingBackward),
          _proof(t, facing),
          ok: facing?['verified'] == true),
      _fact(
          cs,
          Icons.window_rounded,
          place == null
              ? t.sjtPlaceQ
              : switch ('${place['value']}') {
                  'window' => t.sjtPlaceWindow,
                  'aisle' => t.sjtPlaceAisle,
                  _ => t.sjtPlaceMiddle,
                },
          _proof(t, place),
          ok: place?['verified'] == true),
      _fact(cs, Icons.compare_arrows_rounded,
          side == null ? t.sjtSideQ : t.sjtSideIs(sideV == 'left' ? t.sjtSideLeft : t.sjtSideRight),
          _proof(t, side),
          ok: side?['verified'] == true),
      _fact(
          cs,
          Icons.wb_sunny_rounded,
          onSeat != null ? _d(t.sjtSunOnSeat('${onSeat['pct']}')) : sunLine,
          onSeat != null ? '$sunLine · ${t.sjtCalculated}' : t.sjtCalculated,
          ok: true),
      _fact(cs, Icons.linear_scale_rounded,
          pos == null ? t.sjtCoachPosQ : _d(t.sjtCoachPos('${pos['value']}')), _proof(t, pos),
          ok: pos?['verified'] == true),
      const SizedBox(height: Gap.sm),
      if (widget.tripOver)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.xs),
          child: Text(t.sjtAskAfterTrip, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
        ),
      if (widget.tripOver)
        FilledButton.icon(
          key: const ValueKey('sjt_seat_ask'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.touch_app_rounded),
          label: Text(t.sjtAskButton),
          onPressed: _ask,
        )
      else
        OutlinedButton.icon(
          key: const ValueKey('sjt_seat_ask'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.touch_app_rounded),
          label: Text(t.sjtAskButton),
          onPressed: _ask,
        ),
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: _pickSeat,
        child: Text(t.sjtSeatChange),
      ),
      Text(_d(t.sjtSeatSource('${v['verify_n'] ?? 3}')), style: AType.bodySmall),
    ];
  }
}

/// Top view of a coach (engine on the left, the train moving left). The
/// seat's side (left / right when facing the engine) and window / aisle come
/// from passengers; the place along the coach is approximate (4 seats per
/// row from the seat number). Unknown = nothing highlighted.
class CoachTopViewPainter extends CustomPainter {
  CoachTopViewPainter({
    required this.side,
    required this.place,
    required this.seatNo,
    required this.line,
    required this.seat,
    required this.mark,
    required this.engine,
  });
  final String side, place;
  final int? seatNo;
  final Color line, seat, mark, engine;
  static const rows = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final arrowW = size.height * 0.45;
    final body = Rect.fromLTWH(arrowW + 6, 2, size.width - arrowW - 8, size.height - 4);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = line;
    canvas.drawRRect(RRect.fromRectAndRadius(body, const Radius.circular(10)), stroke);
    // direction of travel: an arrow toward the engine (left)
    final a = Paint()..color = engine;
    final cy = size.height / 2;
    final path = Path()
      ..moveTo(0, cy)
      ..lineTo(arrowW, cy - size.height * 0.22)
      ..lineTo(arrowW, cy + size.height * 0.22)
      ..close();
    canvas.drawPath(path, a);
    // 4 seats per row: top two = RIGHT side (facing the engine on the left,
    // your right hand points up), bottom two = LEFT side; outer = window.
    final pad = 6.0;
    final inner = body.deflate(pad);
    final aisle = inner.height * 0.18;
    final seatH = (inner.height - aisle) / 4;
    final seatW = inner.width / rows;
    int? hiRow;
    if (seatNo != null && seatNo! > 0) hiRow = ((seatNo! - 1) ~/ 4).clamp(0, rows - 1);
    int? hiLane; // 0 top-window, 1 top-aisle, 2 bottom-aisle, 3 bottom-window
    if (side == 'right') hiLane = place == 'window' ? 0 : (place.isEmpty ? null : 1);
    if (side == 'left') hiLane = place == 'window' ? 3 : (place.isEmpty ? null : 2);
    for (var r = 0; r < rows; r++) {
      for (var l = 0; l < 4; l++) {
        final y = inner.top + l * seatH + (l >= 2 ? aisle : 0);
        final rect = Rect.fromLTWH(inner.left + r * seatW + 1.5, y + 1.5, seatW - 3, seatH - 3);
        final hit = hiLane == l && (hiRow == null || hiRow == r);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)),
            Paint()..color = hit ? mark : seat);
      }
    }
  }

  @override
  bool shouldRepaint(CoachTopViewPainter o) =>
      o.side != side || o.place != place || o.seatNo != seatNo || o.mark != mark || o.seat != seat;
}
