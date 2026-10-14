import '../l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'arrival_model.dart';

/// One past safe-arrival check-in row. `arrived==true` -> green "Arrived";
/// otherwise it was MISSED and family was alerted (red). Icon + text carry the
/// meaning (never colour alone) for accessibility.
class ArrivalHistoryTile extends StatelessWidget {
  final String? place;
  final DateTime eta;
  final bool arrived;
  const ArrivalHistoryTile({
    super.key,
    required this.place,
    required this.eta,
    required this.arrived,
  });

  @override
  Widget build(BuildContext context) {
    final color = arrived ? Colors.green : Colors.red;
    final when = DateFormat('d MMM, h:mm a').format(eta);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(arrived ? Icons.check_circle : Icons.error_outline, color: color),
      title: Text(place == null || place!.isEmpty
          ? when
          : '${place!} - $when'),
      subtitle: Text(
        arrived ? AppLocalizations.of(context).aHistoryArrived : AppLocalizations.of(context).aHistoryMissed,
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }
}
