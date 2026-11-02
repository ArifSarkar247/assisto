import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../train/journey_transit.dart';
import '../../train/train_api.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'train_tracker_screen.dart';

/// journeymode: "I'm going by train" inside Safe Journey — the train
/// tracker's OWN picker ([TrainSearchPanel]), then "where do you get off?"
/// from the train's stops. Returns the pick (or null when backed out).
Future<JourneyTrainPick?> pickJourneyTrain(BuildContext context) =>
    Navigator.push<JourneyTrainPick>(
        context, MaterialPageRoute(builder: (_) => const JourneyTrainPickScreen()));

class JourneyTrainPickScreen extends StatelessWidget {
  const JourneyTrainPickScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.jmPickTrain)),
      body: TrainSearchPanel(
        leading: [
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text(t.jmPickTrainHelp, style: AType.bodyMedium),
          ),
        ],
        onPick: (tr, date) async {
          final pick = await _pickStation(context, tr, date);
          if (pick != null && context.mounted) Navigator.pop(context, pick);
        },
      ),
    );
  }
}

Future<JourneyTrainPick?> _pickStation(
    BuildContext context, Map<String, dynamic> tr, String date) async {
  final t = AppLocalizations.of(context);
  final bn = Localizations.localeOf(context).languageCode == 'bn';
  final no = '${tr['no']}';
  Map<String, dynamic> v;
  try {
    v = await context.read<AppState>().api.trainLive(no, date);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.trLoadFailed)));
    }
    return null;
  }
  if (!context.mounted) return null;
  final raw = [
    for (final s in (v['stops'] as List? ?? const []))
      if (s is Map && s['lat'] is num && s['lng'] is num) Map<String, dynamic>.from(s)
  ];
  final stops = trainStops({'stops': raw});
  if (stops.length < 2) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.trLoadFailed)));
    return null;
  }
  String d(String s) => notifLocalizeDigits(context, s);
  final i = await showAppSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          children: [
            Text(t.jmPickStationTitle, style: AType.titleLarge),
            Text(t.jmPickStationHelp, style: AType.bodySmall),
            const SizedBox(height: Gap.sm),
            // the first stop is where the train starts: you cannot get off there
            for (var k = 1; k < stops.length; k++)
              ListTile(
                key: ValueKey('jm_station_${stops[k].id}'),
                minVerticalPadding: Gap.sm,
                leading: const Icon(Icons.place_rounded),
                title: Text(stops[k].name(bn)),
                trailing: Text(d('${trainHm('${raw[k]['at'] ?? ''}')} ${t.trEstShort}'),
                    style: AType.bodySmall),
                onTap: () => Navigator.pop(ctx, k),
              ),
          ],
        ),
      ),
    ),
  );
  if (i == null) return null;
  final at = DateTime.tryParse('${raw[i]['at'] ?? ''}')?.toLocal();
  return JourneyTrainPick(
      no: no,
      nameBn: '${tr['name_bn'] ?? (v['train'] as Map?)?['name_bn'] ?? ''}',
      date: date,
      station: stops[i],
      stationAt: at,
      stops: stops,
      path: trainPath(v));
}
