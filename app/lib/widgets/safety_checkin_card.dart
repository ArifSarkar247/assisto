import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';

/// Safe-arrival check-in card. When a check-in is active it shows the place +
/// ETA with a live status (on-time / grace / overdue) mirroring
/// core.logic.safety.checkin_status, and a big "arrived" button.
/// When no check-in is active it offers to set one.
class SafetyCheckinCard extends StatelessWidget {
  final String? place;
  final DateTime? eta;
  final VoidCallback onSet;
  final VoidCallback onArrived;
  final int graceMinutes;

  const SafetyCheckinCard({
    super.key,
    required this.place,
    required this.eta,
    required this.onSet,
    required this.onArrived,
    this.graceMinutes = 15,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (eta == null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.pin_drop_outlined),
          title: Text(t.safetyCheckinNone),
          subtitle: Text(t.safetyCheckinNoneDesc),
          trailing: FilledButton.tonal(onPressed: onSet, child: Text(t.safetyCheckinSet)),
        ),
      );
    }

    final now = DateTime.now();
    final deltaMin = now.difference(eta!).inMinutes;
    Color color;
    String status;
    if (deltaMin < 0) {
      color = Colors.green;
      status = t.safetyCheckinOnTime(-deltaMin);
    } else if (deltaMin <= graceMinutes) {
      color = Colors.orange;
      status = t.safetyCheckinGrace;
    } else {
      color = Colors.red;
      status = t.safetyCheckinOverdue(deltaMin);
    }

    return Card(
      color: color.withOpacity(0.08),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.flag, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                place == null
                    ? t.safetyCheckinTargetNoPlace(DateFormat('h:mm a').format(eta!))
                    : t.safetyCheckinTarget(place!, DateFormat('h:mm a').format(eta!)),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(status, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          if (deltaMin > graceMinutes) ...[
            const SizedBox(height: 4),
            Text(t.safetyCheckinOverdueNote, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.green),
                onPressed: onArrived,
                icon: const Icon(Icons.check),
                label: Text(t.safetyArrived),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: onSet, child: Text(t.edit)),
          ]),
        ]),
      ),
    );
  }
}
