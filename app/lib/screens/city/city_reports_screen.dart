// cityapp B6: live reports with one tap — Traffic jam, Road closed,
// Waterlogging, Bus not coming, Bus crowded, Seats free. Shown with how many
// people reported and minutes ago; the server expires them after 60 minutes,
// counts one person once, rate-limits and hides a report after 3 "Not true"
// flags (moderated). No names are ever shown.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import '../../widgets/skeleton.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../city/city_api.dart';
import '../../city/city_models.dart';
import '../../city/city_offline.dart' show havM;
import '../../city/city_widgets.dart';
import '../../l10n/app_localizations.dart';
import '../../maps/place_search.dart' show placeHereNow;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;

String cityReportName(AppLocalizations t, String kind) => switch (kind) {
      'jam' => t.cityLiveJam,
      'road_closed' => t.cityLiveClosed,
      'waterlogging' => t.cityLiveWater,
      'bus_not_coming' => t.cityLiveNoBus,
      'bus_crowded' => t.cityLiveCrowded,
      'seats_free' => t.cityLiveSeats,
      _ => t.cityLiveJam,
    };

IconData cityReportIcon(String kind) => switch (kind) {
      'jam' => Icons.traffic_rounded,
      'road_closed' => Icons.block_rounded,
      'waterlogging' => Icons.water_rounded,
      'bus_not_coming' => Icons.bus_alert_rounded,
      'bus_crowded' => Icons.groups_rounded,
      'seats_free' => Icons.event_seat_rounded,
      _ => Icons.campaign_rounded,
    };

class CityReportsScreen extends StatefulWidget {
  @visibleForTesting
  final ({double lat, double lon})? debugHere;
  const CityReportsScreen({super.key, this.debugHere});
  @override
  State<CityReportsScreen> createState() => _CityReportsScreenState();
}

class _CityReportsScreenState extends State<CityReportsScreen> {
  ({double lat, double lon})? _here;
  bool _loading = true, _failed = false;
  List<CityReport> _reports = const [];
  final Set<String> _sent = {};
  final Set<int> _flagged = {};

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    _here = widget.debugHere;
    if (_here == null) {
      if (mounted) setState(() => _loading = true);
      final p = await placeHereNow(context);
      if (p != null) _here = (lat: p.lat, lon: p.lng);
    }
    await _load();
  }

  Future<void> _load() async {
    final h = _here;
    if (h == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final r = await _api.cityReports(h.lat, h.lon);
      if (!mounted) return;
      setState(() {
        _reports = [for (final e in (r['reports'] as List? ?? const [])) CityReport.from(e)];
        _failed = false;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _report(String kind) async {
    final t = AppLocalizations.of(context);
    final h = _here;
    final msg = ScaffoldMessenger.of(context);
    if (h == null) {
      msg.showSnackBar(SnackBar(content: Text(t.cityAroundNeedLocation)));
      return;
    }
    try {
      await _api.cityReport(kind, h.lat, h.lon);
      setState(() => _sent.add(kind));
      msg.showSnackBar(SnackBar(content: Text(t.cityLiveThanks)));
      await _load();
    } catch (e) {
      msg.showSnackBar(SnackBar(
          content: Text(e is ApiException && e.status == 429 ? t.cityLiveTooMany : t.citySendFailed)));
    }
  }

  Future<void> _flag(CityReport r) async {
    final t = AppLocalizations.of(context);
    final msg = ScaffoldMessenger.of(context);
    try {
      await _api.cityReportFlag(r.id);
      setState(() => _flagged.add(r.id));
      msg.showSnackBar(SnackBar(content: Text(t.cityLiveFlagged)));
    } catch (_) {
      msg.showSnackBar(SnackBar(content: Text(t.citySendFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.cityLiveReports)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          key: const ValueKey('city_live_list'),
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [
            Text(t.cityLiveTapToReport, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.xs),
            Text(t.cityLiveHow, style: AType.bodySmall),
            const SizedBox(height: Gap.sm),
            LayoutBuilder(builder: (context, c) {
              final cols = MediaQuery.textScalerOf(context).scale(14) > 22 ? 1 : 2;
              final w = (c.maxWidth - Gap.sm * (cols - 1)) / cols;
              return Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                for (final k in kLiveKinds)
                  SizedBox(
                    width: w,
                    child: FilledButton.tonalIcon(
                      key: ValueKey('city_live_$k'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 56), alignment: AlignmentDirectional.centerStart),
                      onPressed: _sent.contains(k) ? null : () => _report(k),
                      icon: Icon(_sent.contains(k) ? Icons.check_rounded : cityReportIcon(k)),
                      label: Text(cityReportName(t, k)),
                    ),
                  ),
              ]);
            }),
            CitySection(t.cityLiveNearYou, icon: Icons.campaign_rounded),
            if (_loading)
              const SkeletonList(count: 3)
            else if (_here == null)
              CityRetryCard(
                  key: const ValueKey('city_live_need_location'),
                  icon: Icons.location_off_rounded,
                  text: t.cityAroundNeedLocation,
                  buttonText: t.cityTryAgain,
                  onPressed: _init)
            else if (_failed)
              CityRetryCard(
                  key: const ValueKey('city_live_failed'),
                  text: t.cityGLoadFailed,
                  buttonText: t.cityTryAgain,
                  onPressed: () {
                    setState(() => _loading = true);
                    _load();
                  })
            else if (_reports.isEmpty)
              DsCard(
                padding: const EdgeInsets.all(Gap.lg),
                child: Text(t.cityLiveNone),
              )
            else
              for (final r in _reports)
                DsCard(key: ValueKey('city_report_${r.id}'),
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    minVerticalPadding: Gap.sm,
                    leading: CircleAvatar(
                        backgroundColor: s.ds.primarySoft,
                        child: Icon(cityReportIcon(r.kind), color: s.ds.primaryInk)),
                    title: Text(cityReportName(t, r.kind), style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                    subtitle: Text(cityD(context, [
                      t.cityReportCount('${r.count}', '${r.minutesAgo}'),
                      if (_here != null && r.lat != null && r.lon != null)
                        cityDistance(context, havM(_here!.lat, _here!.lon, r.lat!, r.lon!)),
                    ].join(' · '))),
                    trailing: _flagged.contains(r.id)
                        ? const Icon(Icons.check_rounded)
                        : TextButton(
                            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                            onPressed: () => _flag(r),
                            child: Text(t.cityLiveNotTrue)),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
