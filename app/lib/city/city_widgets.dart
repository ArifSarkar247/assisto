// cityapp: shared City Service widgets — fare chip (with its label and
// checked date), status badge, the step list, an option summary, the CNG
// "Show this if overcharged" card and the honest "no data" card.
import 'package:flutter/material.dart';
import '../ds/ds.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart' show openForUser;
import '../theme.dart';
import '../widgets/app_sheet.dart' show showAppSheet;
import '../widgets/bn_day_periods.dart' show appDateLocale;
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'city_models.dart';

bool cityBn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

/// ASCII digits -> Bangla digits when the app is Bangla (owner rule).
String cityD(BuildContext c, String s) => notifLocalizeDigits(c, s);


/// "2026-11-09" -> "Nov 9, 2026" (Bangla months + digits in Bangla).
String cityDate(BuildContext c, String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return cityD(c, iso);
  try {
    return cityD(c, DateFormat.yMMMd(appDateLocale(c)).format(d));
  } catch (_) {
    return cityD(c, DateFormat.yMMMd().format(d));
  }
}

/// "৳20" or "৳20–25".
String cityTaka(BuildContext c, int low, int high) =>
    cityD(c, low == high ? '৳$low' : '৳$low–$high');

String cityMinutes(BuildContext c, int m) {
  final t = AppLocalizations.of(c);
  if (m >= 60) return cityD(c, t.cityHoursMinutes('${m ~/ 60}', '${m % 60}'));
  return cityD(c, t.cityMinutes('$m'));
}

String cityDistance(BuildContext c, num meters) {
  final t = AppLocalizations.of(c);
  return cityD(c, meters >= 1000 ? t.cityKm((meters / 1000).toStringAsFixed(1)) : t.cityMeters('${meters.round()}'));
}

String cityModeName(AppLocalizations t, String mode) => switch (mode) {
      'walk' => t.cityModeWalk,
      'metro' => t.cityModeMetro,
      'bus' => t.cityModeBus,
      'leguna' => t.cityModeLeguna,
      'water' => t.cityModeWater,
      'rickshaw' => t.cityModeRickshaw,
      'cng' => t.cityModeCng,
      'ride_bike' => t.cityModeRideBike,
      'ride_car' => t.cityModeRideCar,
      _ => t.cityModeBus,
    };

IconData cityModeIcon(String mode) => switch (mode) {
      'walk' => Icons.directions_walk_rounded,
      'metro' => Icons.subway_rounded,
      'bus' => Icons.directions_bus_rounded,
      'leguna' => Icons.airport_shuttle_rounded,
      'water' => Icons.directions_boat_rounded,
      'rickshaw' => Icons.pedal_bike_rounded,
      'cng' => Icons.electric_rickshaw_rounded,
      'ride_bike' => Icons.two_wheeler_rounded,
      'ride_car' => Icons.local_taxi_rounded,
      _ => Icons.place_rounded,
    };

Color cityModeColor(String mode) => switch (mode) {
      'metro' => Brand.success,
      'bus' => Brand.blue,
      'leguna' => Brand.purple,
      'water' => Brand.info,
      'rickshaw' || 'cng' => Brand.warning,
      'ride_bike' || 'ride_car' => Brand.blueDeep,
      _ => Brand.blueDeep,
    };

String fareLabelText(AppLocalizations t, FareLabel l) => switch (l) {
      FareLabel.official => t.cityFareOfficial,
      FareLabel.reported => t.cityFareReported,
      FareLabel.estimate => t.cityFareEstimate,
      FareLabel.mixed => t.cityFareMixed,
    };

/// Small pill.
class CityPill extends StatelessWidget {
  final String text;
  final Color bg, fg;
  final IconData? icon;
  const CityPill(this.text, {super.key, required this.bg, required this.fg, this.icon});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: Gap.xxs)],
          Flexible(child: Text(text, style: AType.labelMedium.copyWith(color: fg, fontWeight: FontWeight.w700))),
        ]),
      );
}

/// Verified / Reported by users.
class CityStatusBadge extends StatelessWidget {
  final String status;
  const CityStatusBadge(this.status, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final v = status == 'verified';
    return CityPill(v ? t.cityStatusVerified : t.cityStatusReported,
        icon: v ? Icons.verified_rounded : Icons.groups_rounded,
        bg: v ? s.ds.primarySoft : s.ds.cardHighest,
        fg: v ? s.ds.primaryInk : s.ds.muted);
  }
}

/// "৳20 · Official · Checked 9 Nov 2026" — tap for the source.
class CityFareChip extends StatelessWidget {
  final CityFare fare;
  final bool showChecked;
  const CityFareChip(this.fare, {super.key, this.showChecked = true});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final (bg, fg) = switch (fare.label) {
      FareLabel.official => (s.ds.primarySoft, s.ds.primaryInk),
      FareLabel.reported => (s.ds.successBg, s.ds.successInk),
      _ => (s.ds.cardHighest, s.ds.muted),
    };
    return Semantics(
      button: true,
      label: '${cityTaka(context, fare.low, fare.high)} ${fareLabelText(t, fare.label)}',
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => showFareSource(context, fare),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Gap.xs,
            runSpacing: Gap.xxs,
            children: [
              Text(cityTaka(context, fare.low, fare.high),
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
              CityPill(fareLabelText(t, fare.label), bg: bg, fg: fg),
              if (fare.card != null && fare.card != fare.low)
                Text(cityD(context, t.cityFareCard('${fare.card}')), style: AType.bodySmall),
              if (showChecked && fare.checked.isNotEmpty)
                Text(t.cityCheckedOn(cityDate(context, fare.checked)),
                    style: AType.bodySmall.copyWith(color: s.ds.muted)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where a fare comes from (source + link + date).
Future<void> showFareSource(BuildContext context, CityFare f) {
  final t = AppLocalizations.of(context);
  return showAppSheet<void>(
    context: context,
    builder: (c) => Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.cityFareSourceTitle, style: AType.titleLarge),
        const SizedBox(height: Gap.sm),
        Text(fareLabelText(t, f.label), style: AType.titleMedium),
        Text(switch (f.label) {
          FareLabel.official => t.cityFareOfficialHelp,
          FareLabel.reported => t.cityFareReportedHelp,
          _ => t.cityFareEstimateHelp,
        }),
        if (f.source.isNotEmpty) ...[const SizedBox(height: Gap.sm), Text(cityD(c, f.source))],
        if (f.checked.isNotEmpty) Text(t.cityCheckedOn(cityDate(c, f.checked))),
        if (f.sourceUrl.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => openForUser(c, Uri.parse(f.sourceUrl),
                where: 'city.fare_source', mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(t.cityOpenSource),
          ),
        ],
      ]),
    ),
  );
}

/// One option's summary: time, total fare, changes, walking.
class CityOptionSummary extends StatelessWidget {
  final CityOption option;
  const CityOptionSummary(this.option, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Gap.md, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(cityMinutes(context, option.minutes), style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w800)),
        CityFareChip(option.fare, showChecked: false),
      ]),
      const SizedBox(height: Gap.xs),
      Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
        for (final l in option.legs)
          Icon(cityModeIcon(l.mode), size: 22, color: cityModeColor(l.mode), semanticLabel: cityModeName(t, l.mode)),
      ]),
      const SizedBox(height: Gap.xs),
      Text(
          cityD(
              context,
              [
                option.changes == 0 ? t.cityNoChange : t.cityGChangesN(option.changes),
                t.cityWalkTotal(cityDistance(context, option.walkM)),
              ].join(' · ')),
          style: AType.bodyMedium.copyWith(color: s.ds.muted)),
    ]);
  }
}

/// The step list (walk metres, metro stations + direction, exit gate, bus
/// route + board / get-off stop, leguna, rickshaw, waterbus).
class CityStepList extends StatelessWidget {
  final CityOption option;
  final bool simple; // New-here mode: plain tips under each step
  final void Function(CityLeg leg)? onReportLeg;
  const CityStepList(this.option, {super.key, this.simple = false, this.onReportLeg});

  @override
  Widget build(BuildContext context) {
    final legs = option.legs;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < legs.length; i++)
        _Step(leg: legs[i], index: i, last: i == legs.length - 1, simple: simple, onReport: onReportLeg),
    ]);
  }
}

class _Step extends StatelessWidget {
  final CityLeg leg;
  final int index;
  final bool last, simple;
  final void Function(CityLeg leg)? onReport;
  const _Step({required this.leg, required this.index, required this.last, required this.simple, this.onReport});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = cityBn(context);
    final s = Theme.of(context).colorScheme;
    final c = cityModeColor(leg.mode);
    String d(String x) => cityD(context, x);
    final lines = <Widget>[];
    final title = StringBuffer();
    if (leg.isVehicle) {
      title.write('${cityModeName(t, leg.mode)} · ${leg.routeLabel(bn)}');
      final towards = leg.towards?.label(bn) ?? '';
      if (towards.isNotEmpty) lines.add(Text(d(t.cityTowards(towards))));
      lines.add(Text(d(t.cityBoardAt(leg.board?.label(bn) ?? '')),
          style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)));
      lines.add(Text(d(t.cityGGetOffAtN(leg.alight?.label(bn) ?? '', leg.stops)),
          style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)));
      final via = bn && leg.viaBn.any((v) => v.isNotEmpty) ? leg.viaBn : leg.via;
      final viaClean = via.where((v) => v.isNotEmpty).toList();
      if (viaClean.isNotEmpty) {
        lines.add(Text(d(t.cityVia(viaClean.take(6).join(', '))),
            style: AType.bodySmall.copyWith(color: s.ds.muted)));
      }
      final meta = [
        cityMinutes(context, leg.minutes),
        if (leg.headwayMin > 0) d(t.cityEvery(cityMinutes(context, leg.headwayMin))),
      ].join(' · ');
      lines.add(Text(meta, style: AType.bodySmall.copyWith(color: s.ds.muted)));
      lines.add(Wrap(spacing: Gap.xs, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (leg.status.isNotEmpty) CityStatusBadge(leg.status),
        if (leg.womenOnly)
          CityPill(t.cityWomenOnly, icon: Icons.woman_rounded, bg: s.ds.primarySoft, fg: s.ds.primaryInk),
      ]));
      if (leg.fare != null) lines.add(CityFareChip(leg.fare!));
      final g = leg.exitGate;
      if (g != null) lines.add(CityGateBox(gate: g));
      if (simple) lines.add(_tip(context, switch (leg.mode) {
            'metro' => t.cityTipMetro,
            'bus' => t.cityTipBus,
            'leguna' => t.cityTipLeguna,
            _ => t.cityTipWater,
          }));
    } else {
      final to = leg.to;
      final toName = to == null ? '' : (to.dest ? t.cityYourDestination : to.label(bn));
      title.write(leg.mode == 'walk'
          ? t.cityWalkMeters(cityDistance(context, leg.meters))
          : '${cityModeName(t, leg.mode)} · ${cityDistance(context, leg.meters)}');
      if (toName.isNotEmpty) lines.add(Text(d(t.cityTo(toName))));
      lines.add(Text(cityMinutes(context, leg.minutes), style: AType.bodySmall.copyWith(color: s.ds.muted)));
      if (leg.fare != null) lines.add(CityFareChip(leg.fare!));
      if (simple && leg.mode == 'rickshaw') lines.add(_tip(context, t.cityTipRickshaw));
    }
    return Semantics(
      container: true,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 40,
            child: Column(children: [
              CircleAvatar(radius: 18, backgroundColor: c, child: Icon(cityModeIcon(leg.mode), color: Colors.white, size: 20)),
              if (!last) Expanded(child: Container(width: 3, color: c.withValues(alpha: 0.5))),
            ]),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Gap.lg),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d(title.toString()), style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
                for (final w in lines) Padding(padding: const EdgeInsets.only(top: Gap.xxs), child: w),
                if (onReport != null && leg.isVehicle)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () => onReport!(leg),
                      icon: const Icon(Icons.edit_note_rounded, size: 20),
                      label: Text(t.cityWrongInfo),
                    ),
                  ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tip(BuildContext context, String text) {
    final s = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: Gap.xs),
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(color: s.ds.primarySoft, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lightbulb_outline_rounded, size: 18, color: s.ds.primaryInk),
        const SizedBox(width: Gap.xs),
        Expanded(child: Text(text, style: AType.bodyMedium.copyWith(color: s.ds.primaryInk))),
      ]),
    );
  }
}

String citySideText(AppLocalizations t, String side) => switch (side) {
      'N' => t.citySideN,
      'E' => t.citySideE,
      'S' => t.citySideS,
      'W' => t.citySideW,
      _ => '',
    };

/// "Exit by Gate A (north side) — near: ..." box.
class CityGateBox extends StatelessWidget {
  final CityGate gate;
  final bool big;
  const CityGateBox({super.key, required this.gate, this.big = false});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = cityBn(context);
    final s = Theme.of(context).colorScheme;
    final side = citySideText(t, gate.side);
    final near = gate.near.map((n) => n.label(bn)).where((x) => x.isNotEmpty).take(4).join(', ');
    return Container(
      key: const ValueKey('city_gate_box'),
      margin: const EdgeInsets.only(top: Gap.xs),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: s.ds.primarySoft, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.logout_rounded, color: s.ds.primaryInk, size: big ? 32 : 22),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cityD(context, t.cityExitGate(gate.title(bn))),
                style: (big ? AType.headlineSmall : AType.titleMedium)
                    .copyWith(color: s.ds.primaryInk, fontWeight: FontWeight.w800)),
            if (side.isNotEmpty) Text(side, style: AType.bodyMedium.copyWith(color: s.ds.primaryInk)),
            if (near.isNotEmpty) Text(cityD(context, t.cityNear(near)), style: AType.bodyMedium.copyWith(color: s.ds.primaryInk)),
            if (gate.lift == true)
              Text(t.cityLiftHere, style: AType.bodyMedium.copyWith(color: s.ds.primaryInk, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }
}

/// CNG: meter fare + "Show this if overcharged" + one tap to the complaint line.
class CityCngCard extends StatelessWidget {
  final CityOtherWay way;
  final CityComplaint complaint;
  const CityCngCard({super.key, required this.way, required this.complaint});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final f = way.fare;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (f != null) CityFareChip(f),
      Text(t.cityCngMeterNote, style: AType.bodySmall),
      const SizedBox(height: Gap.xs),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        FilledButton.tonalIcon(
          key: const ValueKey('city_cng_show'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: f == null ? null : () => showOverchargeCard(context, way, complaint),
          icon: const Icon(Icons.front_hand_rounded),
          label: Text(t.cityShowIfOvercharged),
        ),
        CityComplaintButton(complaint: complaint),
      ]),
    ]);
  }
}

class CityComplaintButton extends StatelessWidget {
  final CityComplaint complaint;
  const CityComplaintButton({super.key, required this.complaint});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return OutlinedButton.icon(
      key: const ValueKey('city_complaint'),
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: () => openForUser(context, Uri.parse('tel:${complaint.dial}'), where: 'city.complaint'),
      icon: const Icon(Icons.call_rounded),
      label: Text(cityD(
          context, complaint.usesFallback ? t.cityComplaintFallback(complaint.dial) : t.cityComplaintBrta(complaint.dial))),
    );
  }
}

/// Full-screen big card to show the driver.
Future<void> showOverchargeCard(BuildContext context, CityOtherWay way, CityComplaint complaint) {
  final f = way.fare!;
  return Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (c) {
      final t = AppLocalizations.of(c);
      final s = Theme.of(c).colorScheme;
      return Scaffold(
        appBar: AppBar(title: Text(t.cityShowIfOvercharged)),
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(Gap.xl), children: [
            Text(t.cityOverchargeHeadline, style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.lg),
            Text(cityD(c, t.cityOverchargeDistance(way.km.toStringAsFixed(1))), style: AType.titleLarge),
            const SizedBox(height: Gap.sm),
            Text(cityTaka(c, f.meter ?? f.low, f.high),
                style: AType.displayMedium.copyWith(fontWeight: FontWeight.w900, color: s.primary)),
            Text(t.cityOverchargeMeterRule, style: AType.titleMedium),
            const SizedBox(height: Gap.sm),
            if (f.source.isNotEmpty) Text(cityD(c, f.source)),
            if (f.checked.isNotEmpty) Text(t.cityCheckedOn(cityDate(c, f.checked))),
            const SizedBox(height: Gap.xl),
            Text(t.cityOverchargeLaw, style: AType.bodyLarge),
            const SizedBox(height: Gap.lg),
            CityComplaintButton(complaint: complaint),
          ]),
        ),
      );
    },
  ));
}

/// Honest "no data for this city yet" + Open in Google Maps transit.
class CityNoDataCard extends StatelessWidget {
  final String googleMaps;
  final String? message;
  const CityNoDataCard({super.key, required this.googleMaps, this.message});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DsCard(key: const ValueKey('city_no_data'),
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.travel_explore_rounded, size: 32),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.cityNoDataTitle, style: AType.titleLarge)),
          ]),
          const SizedBox(height: Gap.sm),
          Text(message ?? t.cityNoDataBody),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('city_open_gmaps'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: googleMaps.isEmpty
                  ? null
                  : () => openForUser(context, Uri.parse(googleMaps),
                      where: 'city.gmaps', mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.map_rounded),
              label: Text(t.cityOpenGoogleMapsTransit),
            ),
          ),
        ]),
    );
  }
}

/// Section header.
class CitySection extends StatelessWidget {
  final String title;
  final IconData? icon;
  const CitySection(this.title, {super.key, this.icon});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.sm),
        child: Row(children: [
          if (icon != null) ...[Icon(icon, size: 22), const SizedBox(width: Gap.sm)],
          Expanded(child: Text(title, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800))),
        ]),
      );
}

// gap-city: a failed / needs-something state is never a dead end — the
// message plus a real button (Try again, Choose start, ...).
class CityRetryCard extends StatelessWidget {
  final String text;
  final IconData icon;
  final String buttonText;
  final VoidCallback onPressed;
  final Key? buttonKey;
  final Widget? extra;
  const CityRetryCard(
      {super.key,
      required this.text,
      required this.buttonText,
      required this.onPressed,
      this.icon = Icons.cloud_off_rounded,
      this.buttonKey,
      this.extra});
  @override
  Widget build(BuildContext context) => DsCard(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(text)),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            FilledButton.icon(
              key: buttonKey,
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onPressed,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(buttonText),
            ),
            if (extra != null) extra!,
          ]),
        ]),
      );
}

/// gap-city: "Go by bus / metro" — plan this place in City Service (our own
/// routes + fares) instead of leaving for another app.
class CityRouteHereButton extends StatelessWidget {
  final VoidCallback onPressed;
  const CityRouteHereButton({super.key, required this.onPressed});
  @override
  Widget build(BuildContext context) => FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: onPressed,
        icon: const Icon(Icons.directions_bus_rounded, size: 18),
        label: Text(AppLocalizations.of(context).cityGRouteHere),
      );
}
