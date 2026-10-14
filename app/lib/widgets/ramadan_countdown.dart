import 'dart:async';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Live Sehri / Iftar countdown. Ticks once per second and shows the time
/// remaining to the NEXT of the two events. Pure presentation — the HH:MM
/// targets come from the backend prayer_times (location-based); this only
/// counts down. Mirrors `core.logic.ramadan.minutes_until`.
class RamadanCountdown extends StatefulWidget {
  final String sehriEnd; // HH:MM (Fajr)
  final String iftar; // HH:MM (Maghrib)
  const RamadanCountdown(
      {super.key, required this.sehriEnd, required this.iftar});

  @override
  State<RamadanCountdown> createState() => _RamadanCountdownState();
}

class _RamadanCountdownState extends State<RamadanCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // Seconds from `now` to the next occurrence of HH:MM (wraps to tomorrow).
  int? _secondsUntil(String hhmm, DateTime now) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    final nowSec = now.hour * 3600 + now.minute * 60 + now.second;
    final tgtSec = h * 3600 + m * 60;
    return ((tgtSec - nowSec) % (24 * 3600) + 24 * 3600) % (24 * 3600);
  }

  String _fmt(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final now = DateTime.now();
    final toSehri = _secondsUntil(widget.sehriEnd, now);
    final toIftar = _secondsUntil(widget.iftar, now);
    if (toSehri == null || toIftar == null) return const SizedBox.shrink();

    // Show whichever event is sooner as the primary big countdown.
    final sehriSooner = toSehri <= toIftar;
    final label = sehriSooner ? t.ramadanUntilSehri : t.ramadanUntilIftar;
    final value = _fmt(sehriSooner ? toSehri : toIftar);
    final color = sehriSooner ? Brand.purple : Brand.warning;

    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.14), Brand.blue.withOpacity(0.08)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: [
        Text(label,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color: color,
                fontSize: 36,
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: Gap.xs),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _mini(t.ramadanUntilSehri, _fmt(toSehri), Brand.purple),
          _mini(t.ramadanUntilIftar, _fmt(toIftar), Brand.warning),
        ]),
      ]),
    );
  }

  Widget _mini(String label, String value, Color color) {
    return Column(children: [
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      Text(value,
          style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}
