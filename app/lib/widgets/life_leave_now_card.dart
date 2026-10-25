import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'ladder_common.dart';
import '../services/action_feedback.dart'; // db1

/// "Leave now" (bn label supplied via l10n) card for an appointment.
///
/// The user types a best-effort travel estimate (minutes) — we NEVER invent
/// traffic/ETA. From it we mirror core.logic.meetings.leave_now_phase:
///   - unknown  -> prompt to add a travel estimate
///   - later    -> "leave in N min"
///   - leave_now-> highlighted "Leave now" + Maps directions deep-link.
///
/// The Maps link is the provider's own directions URL (deep-link), built by
/// mirroring meetings.maps_dir_url — no fake route data.
class LifeLeaveNowCard extends StatefulWidget {
  final DateTime start;
  final String? placeName;
  final double? placeLat;
  final double? placeLng;

  /// The travel estimate (minutes) the user previously entered for THIS
  /// appointment, owned by the parent so it survives list rebuilds. Null = not
  /// entered yet. Changes are reported back via [onTravelChanged].
  final int? travelMin;
  final ValueChanged<int?>? onTravelChanged;
  const LifeLeaveNowCard({
    super.key,
    required this.start,
    this.placeName,
    this.placeLat,
    this.placeLng,
    this.travelMin,
    this.onTravelChanged,
  });

  @override
  State<LifeLeaveNowCard> createState() => _LifeLeaveNowCardState();
}

class _LifeLeaveNowCardState extends State<LifeLeaveNowCard> {
  int? _travelMin;

  static const int _bufferMin = 5;

  @override
  void initState() {
    super.initState();
    _travelMin = widget.travelMin;
  }

  @override
  void didUpdateWidget(covariant LifeLeaveNowCard old) {
    super.didUpdateWidget(old);
    // Keep in sync if the parent-owned value changed (e.g. list rebuild).
    if (widget.travelMin != old.travelMin && widget.travelMin != _travelMin) {
      _travelMin = widget.travelMin;
    }
  }

  DateTime? get _leaveAt {
    if (_travelMin == null) return null;
    return widget.start.subtract(Duration(minutes: _travelMin! + _bufferMin));
  }

  /// Mirrors meetings.leave_now_phase.
  ({String state, int minutes}) _phase() {
    final la = _leaveAt;
    if (la == null) return (state: 'unknown', minutes: 0);
    final diff = la.difference(DateTime.now()).inMinutes;
    // Guard against absurd values from a far/invalid meeting date (e.g. default
    // or epoch data would otherwise render "leave in 37980541 min"). Beyond a
    // day in either direction, fall back to the neutral "add travel" state.
    if (diff.abs() > 24 * 60) return (state: 'unknown', minutes: 0);
    if (diff > 0) return (state: 'later', minutes: diff);
    return (state: 'leave_now', minutes: -diff);
  }

  String? _mapsDirUrl() {
    if (widget.placeLat != null && widget.placeLng != null) {
      return 'https://www.google.com/maps/dir/?api=1&destination='
          '${widget.placeLat},${widget.placeLng}';
    }
    final p = widget.placeName;
    if (p != null && p.trim().isNotEmpty) {
      return 'https://www.google.com/maps/dir/?api=1&destination='
          '${Uri.encodeComponent(p.trim())}';
    }
    return null;
  }

  Future<void> _openMaps() async {
    final url = _mapsDirUrl();
    if (url == null) return;
    await openForUser(context, Uri.parse(url), // db1
        where: 'leaveNow.maps', mode: LaunchMode.externalApplication);
  }

  Future<void> _setTravel() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController(
        text: _travelMin == null ? '' : '$_travelMin');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.leaveNowTravelTitle),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.leaveNowTravelHint, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: t.leaveNowTravelLabel),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
            child: Text(t.save),
          ),
        ],
      ),
    );
    if (v != null && v >= 0) {
      setState(() => _travelMin = v);
      // Persist up to the parent so it survives list rebuilds.
      widget.onTravelChanged?.call(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final phase = _phase();
    final hasMaps = _mapsDirUrl() != null;

    if (phase.state == 'unknown') {
      return Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.directions_rounded, size: 16),
            label: Text(t.leaveNowAddTravel),
            onPressed: _setTravel,
          ),
        ),
        if (hasMaps) ...[
          const SizedBox(width: Gap.sm),
          IconButton(
            tooltip: t.leaveNowOpenMaps,
            icon: const Icon(Icons.map_rounded),
            onPressed: _openMaps,
          ),
        ],
      ]);
    }

    final isNow = phase.state == 'leave_now';
    final bg = isNow ? Brand.danger.withOpacity(0.12) : Brand.blue.withOpacity(0.08);
    final fg = isNow ? Brand.danger : Brand.blue;
    return Container(
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(isNow ? Icons.directions_run_rounded : Icons.timelapse_rounded, size: 18, color: fg),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            isNow ? t.leaveNowGo : t.leaveNowIn(fmtInt(context, phase.minutes)),
            style: TextStyle(color: fg, fontWeight: isNow ? FontWeight.bold : FontWeight.normal),
          ),
        ),
        TextButton(onPressed: _setTravel, child: Text(t.edit)),
        if (hasMaps)
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: fg, visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.map_rounded, size: 16),
            label: Text(t.leaveNowDirections),
            onPressed: _openMaps,
          ),
      ]),
    );
  }
}
