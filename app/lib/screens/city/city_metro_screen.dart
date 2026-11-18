// cityapp B4: Metro guide — every MRT station, each exit gate (side, what is
// near, connecting buses / stands, lift), first and last train, frequency,
// Friday times, card recharge, fares (official DTCA/DMTCL rate, checked
// date). With a destination: "Which gate to take" per station. Works
// offline from the city package.
import 'package:flutter/material.dart';
import '../../widgets/skeleton.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../city/city_api.dart';
import '../../city/city_models.dart';
import '../../city/city_offline.dart';
import '../../city/city_widgets.dart';
import '../../city/metro_fare.dart'; // gap-nearby
import '../../l10n/app_localizations.dart';
import '../../maps/place_search.dart' show PlacePick;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import 'city_service_screen.dart' show showCityCorrection;

class CityMetroScreen extends StatefulWidget {
  final String city;
  final CityStore? store;
  final PlacePick? dest;
  const CityMetroScreen({super.key, this.city = 'dhaka', this.store, this.dest});
  @override
  State<CityMetroScreen> createState() => _CityMetroScreenState();
}

class _CityMetroScreenState extends State<CityMetroScreen> {
  Map<String, dynamic>? _m;
  List<CityStation> _stations = const [];
  bool _loading = true, _offline = false;
  String? _fromId, _toId; // gap-nearby: station-to-station fare

  CityStore get _store => widget.store ?? CityStore.I;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    Map<String, dynamic>? m;
    var offline = false;
    try {
      m = await api.cityMetro(widget.city);
      if (m['ok'] == false) m = null;
    } catch (_) {
      final pkg = await _store.package(widget.city);
      final r = await _store.router(widget.city);
      if (pkg != null && r != null) {
        final metro = ((pkg['net'] as Map?)?['metro'] as Map?)?.cast<String, dynamic>() ?? const {};
        m = {...metro, 'stations': r.stations(), 'fare': {...?(pkg['rates'] as Map?)?['metro'] as Map?}};
        offline = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _m = m;
      _offline = offline;
      _stations = [for (final s in (m?['stations'] as List? ?? const [])) CityStation.from(s)];
      if (_stations.length >= 2) {
        _fromId ??= _stations.first.id;
        _toId ??= _stations.last.id;
      }
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = cityBn(context);
    final m = _m;
    return Scaffold(
      appBar: AppBar(title: Text(t.cityMetroGuide)),
      body: _loading
          ? const SkeletonList()
          : m == null || _stations.isEmpty
              ? ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                  CityNoDataCard(googleMaps: googleMapsTransit(null, null, null, null), message: t.cityMetroNoData),
                ])
              : ListView(
                  key: const ValueKey('city_metro_list'),
                  padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
                  children: [
                    if (_offline)
                      Padding(
                          padding: const EdgeInsets.only(bottom: Gap.sm),
                          child: Text(t.cityOfflineShowing, style: AType.bodySmall)),
                    _lineCard(t, bn, m),
                    _fareCard(t, m),
                    _pairFareCard(t, bn, m),
                    _rechargeCard(t, bn, m),
                    CitySection(t.cityStations, icon: Icons.subway_rounded),
                    for (var i = 0; i < _stations.length; i++)
                      Padding(padding: const EdgeInsets.only(bottom: Gap.xs), child: DsCard(
                          padding: EdgeInsets.zero,
                          child: ListTile(
                          key: ValueKey('city_station_${_stations[i].id}'),
                          minVerticalPadding: Gap.sm,
                          leading: CircleAvatar(
                              backgroundColor: Brand.success,
                              child: Text(cityD(context, '${i + 1}'),
                                  style: AType.bodyMedium.copyWith(color: Colors.white, fontWeight: FontWeight.w800))),
                          title: Text(cityD(context, _stations[i].label(bn)),
                              style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
                          subtitle: Text(cityD(
                              context,
                              _stations[i].gates > 0
                                  ? t.cityGatesCount('${_stations[i].gates}')
                                  : t.cityGatesUnknown)),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => CityStationScreen(
                                  city: widget.city, station: _stations[i], store: _store, dest: widget.dest, metro: m))),
                        ),
                        )),
                  ],
                ),
    );
  }

  Widget _lineCard(AppLocalizations t, bool bn, Map<String, dynamic> m) =>
      CityMetroHoursCard(metro: m);

  Widget _fareCard(AppLocalizations t, Map<String, dynamic> m) {
    final f = (m['fare'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (f.isEmpty) return const SizedBox.shrink();
    String n(String k) => '${(f[k] as num?)?.round() ?? ''}';
    final fare = CityFare(
        low: (f['min'] as num?)?.round() ?? 0,
        high: (f['max'] as num?)?.round() ?? 0,
        label: fareLabelOf('${f['label'] ?? 'official'}'),
        checked: '${f['checked'] ?? ''}',
        source: '${f['source'] ?? ''}',
        sourceUrl: '${f['source_url'] ?? ''}');
    return DsCard(key: const ValueKey('city_metro_fare'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.cityMetroFares, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
          CityFareChip(fare),
          Text(cityD(context, t.cityMetroFareRule(n('per_km'), n('min'), n('max')))),
          if ((f['card_discount_pct'] as num?) != null && (f['card_discount_pct'] as num) > 0)
            Text(cityD(context, t.cityMetroCardDiscount(n('card_discount_pct')))),
        ]),
    );
  }

  /// gap-nearby: pick two stations -> the fare (official chart when the pair
  /// is on it, else the official per-km rate), card price, source + date.
  Widget _pairFareCard(AppLocalizations t, bool bn, Map<String, dynamic> m) {
    final f = (m['fare'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (f.isEmpty || _stations.length < 2) return const SizedBox.shrink();
    CityStation? by(String? id) {
      for (final s in _stations) {
        if (s.id == id) return s;
      }
      return null;
    }

    final a = by(_fromId), b = by(_toId);
    final r = a != null && b != null ? metroPairFare(a, b, f) : null;
    Widget pick(String key, String label, String? value, ValueChanged<String?> on) =>
        DropdownButtonFormField<String>(
          key: ValueKey(key),
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          items: [
            for (final s in _stations)
              DropdownMenuItem(
                  value: s.id,
                  child: Text(cityD(context, s.label(bn)), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: on,
        );
    return DsCard(
      key: const ValueKey('city_metro_pair'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.cityMetroPairTitle, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.sm),
        pick('city_metro_pair_from', t.cityMetroPairFrom, _fromId, (v) => setState(() => _fromId = v)),
        const SizedBox(height: Gap.sm),
        pick('city_metro_pair_to', t.cityMetroPairTo, _toId, (v) => setState(() => _toId = v)),
        const SizedBox(height: Gap.sm),
        if (r == null)
          Text(a != null && b != null && a.id == b.id ? t.cityMetroPairSame : t.cityMetroPairUnknown,
              key: const ValueKey('city_metro_pair_none'), style: AType.bodyMedium)
        else ...[
          KeyedSubtree(
            key: ValueKey('city_metro_pair_tk_${r.tk}'),
            child: CityFareChip(CityFare(
                low: r.tk,
                high: r.tk,
                card: r.card,
                label: fareLabelOf('${f['label'] ?? 'official'}'),
                basis: r.fromChart ? 'chart' : 'rate',
                checked: '${f['checked'] ?? ''}',
                source: '${f['source'] ?? ''}',
                sourceUrl: '${f['source_url'] ?? ''}')),
          ),
          Text(
              cityD(
                  context,
                  r.fromChart
                      ? t.cityMetroPairFromChart
                      : t.cityMetroPairFromRate(r.km!.toStringAsFixed(1))),
              style: AType.bodySmall),
        ],
      ]),
    );
  }

  Widget _rechargeCard(AppLocalizations t, bool bn, Map<String, dynamic> m) {
    final r = (m['recharge'] as Map?)?.cast<String, dynamic>() ?? const {};
    final text = '${(bn ? r['text_bn'] : r['text_en']) ?? r['text_en'] ?? ''}';
    if (text.isEmpty) return const SizedBox.shrink();
    return DsCard(key: const ValueKey('city_metro_recharge'),
      padding: EdgeInsets.zero,
      child: ListTile(
        minVerticalPadding: Gap.sm,
        leading: const Icon(Icons.credit_card_rounded),
        title: Text(t.cityRecharge, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
        subtitle: Text(cityD(context, text)),
      ),
    );
  }
}

/// First / last train, Friday, frequency + status and checked date.
class CityMetroHoursCard extends StatelessWidget {
  final Map<String, dynamic> metro;
  const CityMetroHoursCard({super.key, required this.metro});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = cityBn(context);
    final line = (metro['line'] as Map?)?.cast<String, dynamic>() ?? const {};
    final svc = MetroService.from(metro['service']);
    final (f1, l1) = MetroService.split(svc.hoursSatThu);
    final (f2, l2) = MetroService.split(svc.hoursFri);
    final name = '${(bn ? line['name_bn'] : line['name']) ?? line['name'] ?? ''}';
    String d(String s) => cityD(context, s);
    return DsCard(key: const ValueKey('city_metro_hours'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (name.isNotEmpty) Text(d(name), style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
          if ('${line['operator'] ?? ''}'.isNotEmpty) Text(d('${line['operator']}'), style: AType.bodySmall),
          const SizedBox(height: Gap.sm),
          if (svc.hoursSatThu.isNotEmpty) Text(d(t.cityMetroSatThu(f1, l1)), style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
          if (svc.hoursFri.isNotEmpty) Text(d(t.cityMetroFriday(f2, l2)), style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
          if (svc.headwayPeak > 0)
            Text(d(t.cityMetroEvery('${svc.headwayPeak}', '${svc.headwayOffpeak}', '${svc.headwayFri}'))),
          if (svc.endToEnd > 0) Text(d(t.cityMetroEndToEnd('${svc.endToEnd}'))),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (svc.status.isNotEmpty) CityStatusBadge(svc.status),
            if (svc.checked.isNotEmpty) Text(t.cityCheckedOn(cityDate(context, svc.checked)), style: AType.bodySmall),
          ]),
        ]),
    );
  }
}

class CityStationScreen extends StatefulWidget {
  final String city;
  final CityStation station;
  final CityStore? store;
  final PlacePick? dest;
  final Map<String, dynamic>? metro;
  const CityStationScreen(
      {super.key, required this.city, required this.station, this.store, this.dest, this.metro});
  @override
  State<CityStationScreen> createState() => _CityStationScreenState();
}

class _CityStationScreenState extends State<CityStationScreen> {
  Map<String, dynamic>? _g;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ApiClient api = context.read<AppState>().api;
    final d = widget.dest;
    Map<String, dynamic>? g;
    try {
      g = await api.cityStation(widget.city, widget.station.id, lat: d?.lat, lon: d?.lng);
    } catch (_) {
      final r = await (widget.store ?? CityStore.I).router(widget.city);
      g = r?.stationGuide(widget.station.id, lat: d?.lat, lon: d?.lng);
    }
    if (!mounted) return;
    setState(() {
      _g = g;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = cityBn(context);
    final g = _g;
    final gates = [for (final x in (g?['gates'] as List? ?? const [])) if (CityGate.from(x) case final gg?) gg];
    final which = CityGate.from(g?['which_gate']);
    final buses = [for (final b in (g?['connecting_buses'] as List? ?? const [])) '$b'];
    final metro = widget.metro ?? (g == null ? null : {'service': g['service'], 'line': g['line']});
    return Scaffold(
      appBar: AppBar(title: Text(cityD(context, widget.station.label(bn)))),
      body: _loading
          ? const SkeletonList()
          : ListView(
              key: const ValueKey('city_station_list'),
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: [
                if (which != null && widget.dest != null) ...[
                  Text(cityD(context, t.cityWhichGateFor(widget.dest!.name)),
                      style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
                  CityGateBox(gate: which, big: true),
                  const SizedBox(height: Gap.md),
                ],
                if (metro != null && metro['service'] != null) CityMetroHoursCard(metro: metro),
                CitySection(t.cityExitGates, icon: Icons.logout_rounded),
                if (gates.isEmpty) Text(t.cityGatesNotMapped),
                for (final gate in gates) _gateCard(t, bn, gate),
                if (buses.isNotEmpty) ...[
                  CitySection(t.cityConnectingBuses, icon: Icons.directions_bus_rounded),
                  Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
                    for (final b in buses) Chip(label: Text(cityD(context, b))),
                  ]),
                ],
                const SizedBox(height: Gap.md),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => showCityCorrection(context,
                        api: context.read<AppState>().api, target: 'station', targetId: widget.station.id),
                    icon: const Icon(Icons.flag_outlined),
                    label: Text(t.cityReportMistake),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _gateCard(AppLocalizations t, bool bn, CityGate g) {
    final side = citySideText(t, g.side);
    return DsCard(key: ValueKey('city_gate_${g.ref}'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(cityD(context, t.cityGateTitle(g.title(bn))),
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800))),
            if (g.status.isNotEmpty) CityStatusBadge(g.status),
          ]),
          if (side.isNotEmpty) Text(side),
          if (g.lift == true) Text(t.cityLiftHere, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
          if (g.escalator == true) Text(t.cityEscalatorHere, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
          if (g.near.isNotEmpty)
            Text(cityD(
                context,
                t.cityNear(g.near
                    .take(6)
                    .map((n) => n.meters > 0 ? '${n.label(bn)} (${t.cityMeters('${n.meters}')})' : n.label(bn))
                    .join(', ')))),
          if (g.buses.isNotEmpty) Text(cityD(context, t.cityBusesHere(g.buses.take(8).join(', ')))),
          if (g.stands.isNotEmpty)
            Text(cityD(context, t.cityStandsHere(g.stands.map((s) => s.label(bn)).take(4).join(', ')))),
        ]),
    );
  }
}
