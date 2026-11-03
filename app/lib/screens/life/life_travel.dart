import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/local_digits.dart';
import '../train/train_tracker_screen.dart';
import '../travel_planner_screen.dart' show tvNiceDate;
import 'life_common.dart';
import 'life_logic.dart';

/// p3life — Travel planner additions (owner PART 3, 3 Nov):
///   * [TravelLegsTab]  transport legs — train (opens our Train tracker),
///                      bus, launch, air, car — with the OFFICIAL ticket site
///   * [TravelDocsTab]  NID / passport / visa / ticket / insurance expiry
///                      checked against the trip dates
///   * [showTravelOfficialInfo] official tourism sources, cited by name

String legModeLabel(AppLocalizations t, String m) => switch (m) {
      'train' => t.p3lModeTrain,
      'bus' => t.p3lModeBus,
      'launch' => t.p3lModeLaunch,
      'air' => t.p3lModeAir,
      'car' => t.p3lModeCar,
      _ => t.p3lModeOther,
    };

IconData legModeIcon(String m) => switch (m) {
      'train' => Icons.train_rounded,
      'bus' => Icons.directions_bus_rounded,
      'launch' => Icons.directions_boat_rounded,
      'air' => Icons.flight_rounded,
      'car' => Icons.directions_car_rounded,
      _ => Icons.route_rounded,
    };

String docKindLabel(AppLocalizations t, String k) => switch (k) {
      'nid' => t.p3lDocNid,
      'passport' => t.p3lDocPassport,
      'visa' => t.p3lDocVisa,
      'ticket' => t.p3lDocTicket,
      'insurance' => t.p3lDocInsurance,
      _ => t.p3lDocOther,
    };

class TravelLegsTab extends StatelessWidget {
  final int tripId;
  const TravelLegsTab({super.key, required this.tripId});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return LifeCollectionView(
      path: 'travel/legs',
      filter: (r) => r['trip_id'] == tripId,
      extra: {'trip_id': tripId},
      sort: sortLegs,
      emptyIcon: Icons.alt_route_rounded,
      emptyTitle: t.p3lLegsEmptyTitle,
      emptyBody: t.p3lLegsEmptyBody,
      emptyHowTo: t.p3lLegsHowTo,
      addLabel: t.p3lLegAdd,
      formTitle: t.p3lLegEdit,
      deleteBody: t.p3lLegDelete,
      fields: [
        LifeField('mode', t.p3lLegMode, kind: LifeFieldKind.choice, options: [
          for (final m in kLegModes) (m, legModeLabel(t, m)),
        ]),
        LifeField('from', t.p3lLegFrom, maxLength: 60, required: true),
        LifeField('to', t.p3lLegTo, maxLength: 60),
        LifeField('date', t.p3lLegDate, kind: LifeFieldKind.date),
        LifeField('time', t.p3lLegTime, kind: LifeFieldKind.time),
        LifeField('ref', t.p3lLegRef, maxLength: 60),
        LifeField('note', t.p3lNote, kind: LifeFieldKind.multiline, maxLength: 200),
      ],
      item: (context, r, onEdit, onDelete) => _LegCard(row: r, onEdit: onEdit, onDelete: onDelete),
    );
  }
}

class _LegCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onEdit, onDelete;
  const _LegCard({required this.row, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final mode = normMode(row['mode']);
    final from = '${row['from'] ?? ''}', to = '${row['to'] ?? ''}';
    final date = '${row['date'] ?? ''}', time = '${row['time'] ?? ''}';
    final ref = '${row['ref'] ?? ''}', note = '${row['note'] ?? ''}';
    final src = officialForMode(mode);
    final meta = [
      if (date.isNotEmpty) tvNiceDate(context, date),
      if (time.isNotEmpty) ld(context, time),
      if (ref.isNotEmpty) ref,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              backgroundColor: s.primaryContainer,
              child: Icon(legModeIcon(mode), color: s.onPrimaryContainer,
                  semanticLabel: legModeLabel(t, mode)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(to.isEmpty ? from : '$from → $to',
                    style: Theme.of(context).textTheme.titleMedium),
                Text(legModeLabel(t, mode), style: TextStyle(color: s.onSurfaceVariant)),
                if (meta.isNotEmpty) Text(meta),
                if (note.isNotEmpty) Text(note, style: TextStyle(color: s.onSurfaceVariant)),
              ]),
            ),
            LifeRowMenu(onEdit: onEdit, onDelete: onDelete),
          ]),
          Wrap(spacing: Gap.sm, children: [
            if (mode == 'train')
              TextButton.icon(
                key: const ValueKey('life-leg-track'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.my_location_rounded),
                label: Text(t.p3lTrackTrain),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const TrainTrackerScreen())),
              ),
            if (src != null)
              TextButton.icon(
                key: ValueKey('life-leg-official-${src.id}'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(t.p3lOfficialSite),
                onPressed: () => openOfficial(context, src),
              ),
          ]),
        ]),
      ),
    );
  }
}

class TravelDocsTab extends StatelessWidget {
  final int tripId;
  final String? tripEnd; // ISO; documents are checked against it
  const TravelDocsTab({super.key, required this.tripId, this.tripEnd});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return LifeCollectionView(
      path: 'travel/docs',
      filter: (r) => r['trip_id'] == tripId,
      extra: {'trip_id': tripId},
      emptyIcon: Icons.badge_rounded,
      emptyTitle: t.p3lDocsEmptyTitle,
      emptyBody: t.p3lDocsEmptyBody,
      emptyHowTo: t.p3lDocsHowTo,
      addLabel: t.p3lDocAdd,
      formTitle: t.p3lDocEdit,
      deleteBody: t.p3lDocDelete,
      fields: [
        LifeField('kind', t.p3lDocKind, kind: LifeFieldKind.choice, options: [
          for (final k in kDocKinds) (k, docKindLabel(t, k)),
        ]),
        LifeField('label', t.p3lDocLabel, maxLength: 60),
        LifeField('expiry', t.p3lDocExpiry, kind: LifeFieldKind.date),
        LifeField('note', t.p3lNote, kind: LifeFieldKind.multiline, maxLength: 200),
      ],
      item: (context, r, onEdit, onDelete) {
        final s = Theme.of(context).colorScheme;
        final st = docStatus(r, tripEnd: parseIsoDate(tripEnd), today: DateTime.now());
        final (Color c, IconData ic, String msg) = switch (st) {
          'expired' => (s.error, Icons.error_rounded, t.p3lDocExpired),
          'before_trip' => (s.error, Icons.error_rounded, t.p3lDocBeforeTrip),
          'passport_6m' => (s.tertiary, Icons.warning_amber_rounded, t.p3lDocSixMonths),
          'nodate' => (s.onSurfaceVariant, Icons.help_outline_rounded, t.p3lDocNoDate),
          _ => (s.primary, Icons.check_circle_rounded, t.p3lDocOk),
        };
        final kind = '${r['kind'] ?? 'other'}';
        final label = '${r['label'] ?? ''}';
        final exp = '${r['expiry'] ?? ''}';
        return Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.xs, Gap.xs),
            leading: Icon(ic, color: c),
            title: Text(label.isEmpty ? docKindLabel(t, kind) : '${docKindLabel(t, kind)} · $label'),
            subtitle: Text([
              if (exp.isNotEmpty) t.p3lDocExpiresOn(tvNiceDate(context, exp)),
              msg,
            ].join('\n')),
            isThreeLine: exp.isNotEmpty,
            trailing: LifeRowMenu(onEdit: onEdit, onDelete: onDelete),
            onTap: onEdit,
          ),
        );
      },
    );
  }
}

/// Official tourism / transport sources — we only OPEN them (cited by name);
/// nothing is copied or summarised.
Future<void> showTravelOfficialInfo(BuildContext context) {
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.p3lOfficialTitle, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(t.p3lOfficialBody),
          const SizedBox(height: Gap.md),
          for (final src in [...kTourismSources, kSrcRailway, kSrcBiwtc, kSrcBrtc, kSrcBiman])
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: ListTile(
                key: ValueKey('life-src-${src.id}'),
                minTileHeight: 56,
                leading: const Icon(Icons.verified_rounded),
                title: Text(src.name),
                subtitle: Text(Uri.parse(src.url).host),
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: () => openOfficial(ctx, src),
              ),
            ),
          Text(t.p3lOfficialNote,
              style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
        ]),
      );
    },
  );
}
