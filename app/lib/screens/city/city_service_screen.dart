// cityapp (owner order HOME + CITY SERVICE ONE FINAL, 9 Nov 11:45): City
// Service — how to go from A to B in a Bangladeshi city: by what, which bus,
// fare (Official / Reported by users / Estimate + date), easiest and cheapest
// way, which exit after the metro, what is around.
//
// Data + routing: Assisto's own server (citydata, CITY_SERVICE_API.md) —
// zero Google cost. Offline: the city package on the phone (city_offline).
// No ads on this screen (route results and safety screens never carry ads;
// the only Ad-labelled listings live in Around me -> Food).
import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ads/ad_banner_slot.dart'; // adcontrol
import '../../ads/ad_spot_card.dart'; // adcontrol
import '../../api.dart';
import '../../city/city_api.dart';
import '../../city/city_models.dart';
import '../../city/city_offline.dart';
import '../../city/city_widgets.dart';
import '../../l10n/app_localizations.dart';
import '../../maps/place_search.dart';
import '../../state.dart';
import '../../ds/ds.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show showAppSheet, withNavBarInset;
import '../../widgets/local_counter.dart';
import 'city_around_screen.dart';
import 'city_directory_screen.dart';
import '../../city/map/city_map_data.dart' show CityMapApi, GTransitRoute; // mapapp, adwire
import '../../city/map/city_route_compare.dart' show CityRouteCompare; // adwire
import '../../ads/ad_reward_gate.dart' show AdRewardGate, AdGateGrant; // adwire
import 'city_journey.dart';
import 'city_map_screen.dart'; // mapapp
import 'city_metro_screen.dart';
import 'city_field_screen.dart'; // citycov
import 'city_reports_screen.dart';
import 'city_voice.dart';
import 'city_women_screen.dart';
import '../../widgets/num_input.dart'; // savesweep

const String kCitySimpleModeKey = 'city_simple_mode';

typedef CityLatLon = ({double lat, double lon});

class CityServiceScreen extends StatefulWidget {
  /// Test / gallery: the phone's position (skips GPS + permission).
  @visibleForTesting
  final CityLatLon? debugHere;

  /// Test / gallery: a destination already chosen (plans on open).
  @visibleForTesting
  final PlacePick? debugTo;

  /// Test / gallery: start in New-here mode / with this chip.
  @visibleForTesting
  final bool? debugSimple;
  @visibleForTesting
  final CityPick? debugPick;

  /// Offline package store (prod: files on the phone).
  final CityStore? store;

  /// Test (gap-city): the phone's GPS answer (null = location off) instead
  /// of asking the platform.
  @visibleForTesting
  final Future<CityLatLon?> Function()? debugLocate;

  /// Test: "now" for the Safer-at-night default.
  @visibleForTesting
  final DateTime? debugNow;

  const CityServiceScreen(
      {super.key, this.debugHere, this.debugTo, this.debugSimple, this.debugPick, this.store, this.debugNow, this.debugLocate});

  @override
  State<CityServiceScreen> createState() => _CityServiceScreenState();
}

class _CityServiceScreenState extends State<CityServiceScreen> {
  CityLatLon? _here;
  bool _locating = true;
  PlacePick? _from; // null = My current location
  PlacePick? _to;
  CityWhere? _where;
  bool _whereFailed = false;
  CityPlan? _plan;
  bool _planning = false;
  String? _planError;
  late CityPick _pick;
  bool _simple = false;
  bool _offlineReady = false;
  DateTime? _rememberedAt;
  List<CityReport> _reports = const [];
  bool? _learnOn; // trip learning consent (null = unknown / offline)
  int _verifiedStops = 0; // mapapp: "You verified N stops"
  TimeOfDay? _leaveAt; // gap-city: null = leave now

  // adwire: "More routes (Google)" on the results — one Google transit
  // request behind one rewarded ad (Free; Premium / Plus no ad). Offered only
  // when the server says the Google budget allows it (silent otherwise).
  bool _gReady = false;
  List<GTransitRoute> _google = const [];
  bool _gLoading = false, _gTried = false;
  int _gSel = 0;

  CityStore get _store => widget.store ?? CityStore.I;
  ApiClient get _api => context.read<AppState>().api;
  DateTime get _now => widget.debugNow ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    final h = _now.hour;
    _pick = widget.debugPick ?? ((h >= 20 || h < 6) ? CityPick.saferNight : CityPick.cheapest);
    _to = widget.debugTo;
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    if (widget.debugSimple != null) {
      _simple = widget.debugSimple!;
    } else {
      try {
        _simple = await Settings.getBool(kCitySimpleModeKey, false);
      } catch (_) {} // best-effort: default off
    }
    if (widget.debugHere != null) {
      _here = widget.debugHere;
    } else if (widget.debugLocate != null) {
      _here = await widget.debugLocate!();
    } else if (mounted) {
      final p = await placeHereNow(context);
      if (p != null) _here = (lat: p.lat, lon: p.lng);
    }
    if (!mounted) return;
    setState(() => _locating = false);
    unawaited(_loadConsent());
    await _loadWhere();
    if (_to != null) unawaited(_planNow());
  }

  CityLatLon? get _origin => _from != null ? (lat: _from!.lat, lon: _from!.lng) : _here;

  Future<void> _loadWhere() async {
    final o = _origin;
    if (o == null) return;
    try {
      final w = CityWhere.from(await _api.cityWhere(o.lat, o.lon));
      if (!mounted) return;
      setState(() {
        _where = w;
        _whereFailed = false;
      });
      if (w.hasData && w.city.isNotEmpty) {
        final ok = await _store.sync(_api, w.city);
        if (mounted) setState(() => _offlineReady = ok);
      }
    } catch (_) {
      // offline: the saved package still answers (honest "offline" label)
      final ok = (await _store.version('dhaka')).isNotEmpty;
      if (mounted) {
        setState(() {
          _whereFailed = true;
          _offlineReady = ok;
        });
      }
    }
  }

  Future<void> _loadConsent() async {
    try {
      final on = (await _api.cityTripConsent())['on'] == true;
      if (mounted) setState(() => _learnOn = on);
    } catch (_) {} // best-effort: the switch stays hidden offline
    try {
      final n = ((await _api.cityTripMine())['stops_verified'] as num?)?.toInt() ?? 0;
      if (mounted) setState(() => _verifiedStops = n);
    } catch (_) {} // mapapp: the counter is extra
  }

  Future<void> _setLearn(bool on) async {
    if (on && !(await showCityLearnConsent(context) ?? false)) return;
    if (!mounted) return;
    final msg = ScaffoldMessenger.of(context);
    final t = AppLocalizations.of(context);
    try {
      final r = await _api.cityTripConsentSet(on);
      if (mounted) setState(() => _learnOn = r['on'] == true);
    } catch (_) {
      msg.showSnackBar(SnackBar(content: Text(t.citySendFailed)));
    }
  }

  /// adwire: ask our server whether one Google transit request may run.
  Future<void> _peekGoogle(CityPlan plan) async {
    if (!plan.ok || plan.offline) return;
    final ok = await _api.mapsTransitReady();
    if (!mounted || !identical(plan, _plan)) return;
    setState(() => _gReady = ok);
  }

  /// adwire: the button — one rewarded ad at 'city_more_routes' for a Free
  /// user (owner switch on), then ONE Google transit request. Premium /
  /// Plus, switch off, no fill: the request runs with no ad (never a dead
  /// end).
  Future<void> _onMoreRoutes() async {
    if (_gLoading || _gTried) return;
    final t = AppLocalizations.of(context);
    await AdRewardGate.run(context,
        placement: 'city_more_routes',
        grant: AdGateGrant.perUse,
        what: t.adGateWhatRoutes,
        action: _fetchGoogle);
  }

  Future<void> _fetchGoogle() async {
    final o = _origin, d = _to, plan = _plan;
    if (o == null || d == null || !mounted) return;
    setState(() => _gLoading = true);
    var got = const <GTransitRoute>[];
    try {
      got = GTransitRoute.listFrom(await _api.mapsTransit(o.lat, o.lon, d.lat, d.lng));
    } catch (_) {} // silent: our own results stay (never a limit message)
    if (!mounted || !identical(plan, _plan)) return;
    setState(() {
      _google = got;
      _gSel = 0;
      _gLoading = false;
      _gTried = true;
    });
  }

  Future<void> _planNow() async {
    final o = _origin, d = _to;
    if (o == null || d == null) return;
    setState(() {
      _planning = true;
      _planError = null;
      _rememberedAt = null;
      _gReady = false; // adwire: a new trip asks Google afresh
      _google = const [];
      _gLoading = false;
      _gTried = false;
      _gSel = 0;
    });
    final la = _leaveAt;
    final at = la == null ? '' : '${la.hour.toString().padLeft(2, '0')}:${la.minute.toString().padLeft(2, '0')}';
    final key = CityStore.planKey(o.lat, o.lon, d.lat, d.lng) + (at.isEmpty ? '' : '@$at');
    CityPlan? plan;
    try {
      final m = await _api.cityPlan(o.lat, o.lon, d.lat, d.lng, at: at);
      plan = CityPlan.from(m);
      if (plan.ok) unawaited(_store.rememberPlan(key, m));
    } catch (_) {
      // offline: a remembered answer for this trip, else plan on the phone
      final rem = await _store.rememberedPlan(key);
      if (rem != null) {
        plan = CityPlan.from(rem.plan, offline: true);
        _rememberedAt = rem.at;
      } else {
        for (final city in const ['dhaka', 'chattogram']) {
          final r = await _store.router(city);
          if (r != null && r.covers(o.lat, o.lon)) {
            plan = CityPlan.from(r.plan(o.lat, o.lon, d.lat, d.lng, minute: la == null ? null : la.hour * 60 + la.minute),
                offline: true);
            break;
          }
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _planning = false;
      _plan = plan;
      if (plan == null) _planError = 'offline';
      if (plan != null && plan.ok && !plan.options.containsKey(_pick)) {
        _pick = plan.options.keys.first;
      }
    });
    if (plan != null && plan.ok && !plan.offline) unawaited(_loadReports());
    if (plan != null) unawaited(_peekGoogle(plan)); // adwire
  }

  Future<void> _loadReports() async {
    final o = _origin;
    if (o == null) return;
    try {
      final r = await _api.cityReports(o.lat, o.lon, km: 5);
      if (!mounted) return;
      setState(() => _reports = [
            for (final e in (r['reports'] as List? ?? const [])) CityReport.from(e),
          ]);
    } catch (_) {} // best-effort: reports are extra
  }

  Future<void> _pickFrom() async {
    final p = await showPlaceSearchSheet(context, _api,
        lat: _here?.lat, lng: _here?.lon, fieldKey: const ValueKey('city_from_field'));
    if (p == null || !mounted) return;
    setState(() => _from = p);
    await _loadWhere();
    await _planNow();
  }

  Future<void> _pickTo() async {
    final p = await showPlaceSearchSheet(context, _api,
        lat: _origin?.lat, lng: _origin?.lon, currentLocation: false, fieldKey: const ValueKey('city_to_field'));
    if (p == null || !mounted) return;
    setState(() => _to = p);
    await _planNow();
  }

  void _swap() {
    final t = AppLocalizations.of(context);
    final here = _here;
    final newFrom = _to;
    final PlacePick? newTo = _from ??
        (here == null ? null : (name: t.cityMyLocation, address: '', lat: here.lat, lng: here.lon));
    setState(() {
      _from = newFrom;
      _to = newTo;
    });
    _planNow();
  }

  /// gap-city: "Leave at…" — fares and times for a later trip (the server
  /// plans for that time of day; night -> Safer at night first).
  Future<void> _pickLeaveAt() async {
    final now = TimeOfDay.fromDateTime(_now);
    final v = await showTimePicker(context: context, initialTime: _leaveAt ?? now);
    if (v == null || !mounted) return;
    setState(() {
      _leaveAt = v;
      _pick = (v.hour >= 20 || v.hour < 6) ? CityPick.saferNight : CityPick.cheapest;
    });
    await _planNow();
  }

  Future<void> _leaveNow() async {
    final h = _now.hour;
    setState(() {
      _leaveAt = null;
      _pick = (h >= 20 || h < 6) ? CityPick.saferNight : CityPick.cheapest;
    });
    await _planNow();
  }

  Future<void> _setSimple(bool v) async {
    setState(() => _simple = v);
    try {
      await Settings.setBool(kCitySimpleModeKey, v);
    } catch (_) {} // best-effort: only a preference
  }

  Future<void> _voice() async {
    final city = _where?.city.isNotEmpty == true ? _where!.city : 'dhaka';
    final ans = await showCityVoiceAsk(context, api: _api, city: city, here: _origin);
    if (ans == null || !mounted) return;
    setState(() {
      if (ans.from != null) _from = ans.from;
      _to = ans.to;
    });
    await _planNow();
  }

  void _openMap() {
    final o = _origin;
    if (o == null) return;
    final city = _where?.city.isNotEmpty == true ? _where!.city : 'dhaka';
    _open(CityMapScreen(here: o, to: _to, plan: _plan != null && !_plan!.offline ? _plan : null, city: city, store: _store));
  }

  Future<T?> _open<T>(Widget screen) => Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));

  /// gap-city: a guide screen (Around me, offices, terminals) hands back a
  /// place -> it becomes the destination and the trip is planned at once.
  Future<void> _openForDest(Widget screen) async {
    final p = await _open<PlacePick>(screen);
    if (p == null || !mounted) return;
    setState(() => _to = p);
    await _planNow();
  }

  /// gap-city: location was off / denied -> ask again (the From field stays
  /// "Choose where you start" until one of the two works).
  Future<void> _retryHere() async {
    setState(() => _locating = true);
    final p = widget.debugLocate != null
        ? await widget.debugLocate!().then((h) => h == null ? null : (lat: h.lat, lng: h.lon))
        : await placeHereNow(context);
    if (!mounted) return;
    setState(() {
      if (p != null) _here = (lat: p.lat, lon: p.lng);
      _locating = false;
    });
    if (_here != null) {
      await _loadWhere();
      await _planNow();
    }
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.cityTitle), actions: [
        IconButton(
          key: const ValueKey('city_voice_btn'),
          tooltip: t.cityVoiceAsk,
          onPressed: _voice,
          icon: const Icon(Icons.mic_rounded),
        ),
      ]),
      // adcontrol (owner 10 Nov): City Service search & results — one banner
      // (Free only); never on the journey / navigation screen or the
      // destination alarm (those are other screens without a slot)
      bottomNavigationBar: const AdBannerSlot(screen: 'city_search'),
      body: ListView(
        key: const ValueKey('city_list'),
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xxl)),
        children: [
          _cityHeader(t),
          const SizedBox(height: Gap.sm),
          _fromTo(t),
          _simpleSwitch(t),
          ..._results(t),
          // adcontrol: one native card under real results (Free only)
          if (_plan?.ok == true && !_planning) const AdSpotCard(placement: 'city_results'),
          CitySection(t.cityExplore, icon: Icons.explore_rounded),
          _exploreGrid(t),
          if (_learnOn != null)
            SwitchListTile(
              key: const ValueKey('city_learn'),
              contentPadding: EdgeInsets.zero,
              value: _learnOn!,
              onChanged: _setLearn,
              secondary: const Icon(Icons.volunteer_activism_rounded),
              title: Text(t.cityLearnTitle),
              subtitle: Text(t.cityLearnSub),
            ),
          if (_verifiedStops > 0) // mapapp
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(children: [
                const Icon(Icons.verified_rounded, color: Brand.success),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text(cityD(context, t.cityLearnVerified('$_verifiedStops')),
                        key: const ValueKey('city_verified_stops'), style: AType.bodyMedium)),
              ]),
            ),
          const SizedBox(height: Gap.lg),
          Text(_plan?.attribution.isNotEmpty == true ? _plan!.attribution : t.cityAttribution,
              style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _cityHeader(AppLocalizations t) {
    final s = Theme.of(context).colorScheme;
    final w = _where;
    final bn = cityBn(context);
    if (_locating) return const LinearProgressIndicator();
    if (w != null && !w.hasData) {
      return CityNoDataCard(
          googleMaps: w.googleMaps.isNotEmpty ? w.googleMaps : googleMapsTransit(_origin?.lat, _origin?.lon, null, null),
          message: w.city.isEmpty ? t.cityNoDataBody : t.cityNoDataYetCity(w.label(bn)));
    }
    final lines = <String>[];
    if (w != null && w.hasData) {
      lines.add(t.cityCounts('${w.routes}', '${w.stops}', '${w.stations}'));
      if (w.coveragePct != null) lines.add(t.cityCoverage(w.coveragePct!.toStringAsFixed(0)));
    }
    // design2: where you are + what the app knows here is the soft hero
    return DsHeroCard(
      key: const ValueKey('city_header'),
      padding: const EdgeInsets.all(Gap.md),
      child: Row(children: [
          Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                  color: s.ds.primarySoft, borderRadius: BorderRadius.circular(DsRadius.card)),
              child: Icon(Icons.location_city_rounded, color: s.ds.primaryInk)),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(w != null && w.hasData ? w.label(bn) : t.cityTitle,
                  style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
              for (final l in lines) Text(cityD(context, l), style: AType.bodyMedium),
              if (_whereFailed)
                Text(_offlineReady ? t.cityOfflineReady : t.cityOfflineNone,
                    style: AType.bodySmall.copyWith(color: s.ds.dangerInk))
              else if (_offlineReady)
                Row(children: [
                  Icon(Icons.offline_pin_rounded, size: 16, color: s.primary),
                  const SizedBox(width: Gap.xxs),
                  Flexible(child: Text(t.cityOfflineSaved, style: AType.bodySmall)),
                ]),
            ]),
          ),
        ]),
    );
  }

  Widget _fromTo(AppLocalizations t) {
    final s = Theme.of(context).colorScheme;
    final fromName = _from?.name ?? (_here != null ? t.cityMyLocation : t.cityChooseStart);
    Widget field(Key key, IconData icon, Color c, String label, String value, VoidCallback onTap, {bool hint = false}) =>
        Semantics(
          button: true,
          label: '$label: $value',
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
                child: Row(children: [
                  Icon(icon, color: c),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label, style: AType.labelMedium.copyWith(color: s.onSurfaceVariant)),
                      Text(cityD(context, value),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AType.titleMedium.copyWith(
                              fontWeight: FontWeight.w700, color: hint ? s.onSurfaceVariant : null)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        );
    return DsCard(
        padding: const EdgeInsets.all(Gap.xs),
        child: Row(children: [
          Expanded(
            child: Column(children: [
              field(const ValueKey('city_from'), Icons.trip_origin_rounded, Brand.success, t.cityFrom, fromName, _pickFrom),
              const Divider(height: 1),
              field(const ValueKey('city_to'), Icons.place_rounded, Brand.danger, t.cityTo2,
                  _to?.name ?? t.cityWhereTo, _pickTo,
                  hint: _to == null),
            ]),
          ),
          IconButton(
            key: const ValueKey('city_swap'),
            tooltip: t.citySwap,
            onPressed: _to == null ? null : _swap,
            icon: const Icon(Icons.swap_vert_rounded),
          ),
        ]),
    );
  }

  Widget _simpleSwitch(AppLocalizations t) => SwitchListTile(
        key: const ValueKey('city_simple'),
        contentPadding: EdgeInsets.zero,
        value: _simple,
        onChanged: _setSimple,
        secondary: const Icon(Icons.waving_hand_rounded),
        title: Text(t.cityNewHere),
        subtitle: Text(t.cityNewHereSub),
      );

  List<Widget> _results(AppLocalizations t) {
    if (_to == null) return [_emptyHint(t)];
    // gap-city: no GPS and no start chosen -> say what is missing (it used
    // to say "Could not find the way" with a Try again that did nothing)
    if (_locating && _plan == null) {
      return const [Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()))];
    }
    if (_origin == null) {
      return [
        CityRetryCard(
          key: const ValueKey('city_need_start'),
          icon: Icons.location_off_rounded,
          text: t.cityGNeedStart,
          buttonText: t.cityGUseMyLocation,
          buttonKey: const ValueKey('city_need_start_gps'),
          onPressed: _retryHere,
          extra: OutlinedButton.icon(
            key: const ValueKey('city_need_start_pick'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _pickFrom,
            icon: const Icon(Icons.trip_origin_rounded),
            label: Text(t.cityChooseStart),
          ),
        )
      ];
    }
    if (_planning) {
      return const [Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()))];
    }
    final p = _plan;
    if (p == null) {
      return [
        DsCard(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_planError == 'offline' ? t.cityOfflineNoPlan : t.cityPlanFailed),
              const SizedBox(height: Gap.sm),
              FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _planNow,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(t.cityTryAgain)),
            ]),
        )
      ];
    }
    final o = _origin, d = _to!;
    final gm = p.googleMaps.isNotEmpty ? p.googleMaps : googleMapsTransit(o?.lat, o?.lon, d.lat, d.lng);
    if (!p.ok && p.reason == 'no_data') return [CityNoDataCard(googleMaps: gm)];
    final out = <Widget>[];
    if (p.offline) {
      out.add(_banner(
          Icons.cloud_off_rounded,
          _rememberedAt != null
              ? cityD(context, t.cityOfflineRemembered(_timeText(_rememberedAt!)))
              : t.cityOfflinePlanned));
    }
    if (!p.ok) {
      out.add(CityNoDataCard(googleMaps: gm, message: t.cityNoRoute));
    } else {
      final picks = _simple ? [CityPick.fewestChanges] : CityPick.values;
      final shown = _simple && p.options.containsKey(CityPick.fewestChanges) ? CityPick.fewestChanges : _pick;
      final opt = p.options[shown] ?? p.options.values.first;
      final la = _leaveAt;
      final laText = la == null ? '' : _timeText(DateTime(2000, 1, 1, la.hour, la.minute));
      out.add(Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          // gap-city: plan a later trip (fares + times for that hour)
          ActionChip(
            key: const ValueKey('city_leave_at'),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            avatar: const Icon(Icons.schedule_rounded, size: 18),
            label: Text(cityD(context, la == null ? t.cityGLeaveNow : t.cityGLeaveAt(laText))),
            onPressed: _pickLeaveAt,
          ),
          if (la != null)
            TextButton(
              key: const ValueKey('city_leave_now'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _leaveNow,
              child: Text(t.cityGLeaveNow),
            ),
          Text(cityD(context, la == null ? t.cityForNow(_timeText(_now)) : t.cityGForLeaving(laText)),
              style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      ));
      if (!_simple) {
        out.add(Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          for (final k in picks)
            if (p.options.containsKey(k))
              ChoiceChip(
                key: ValueKey('city_chip_${kCityPickKeys[k]}'),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                selected: k == shown,
                onSelected: (_) => setState(() => _pick = k),
                avatar: Icon(_pickIcon(k), size: 18),
                label: Text(_pickName(t, k)),
              ),
        ]));
      } else {
        out.add(_banner(Icons.waving_hand_rounded, t.cityNewHereShowing));
      }
      for (final w in p.warnings) {
        if (w == 'metro_hours') out.add(_banner(Icons.schedule_rounded, t.cityWarnMetroHours));
      }
      out.add(DsCard(key: const ValueKey('city_option'),
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CityOptionSummary(opt),
            if (opt.status == 'reported') ...[
              const SizedBox(height: Gap.xs),
              Text(t.cityRouteReportedNote, style: AType.bodySmall),
            ],
            ..._liveOnRoute(t, opt),
            const Divider(height: Gap.xl),
            CityStepList(opt, simple: _simple, onReportLeg: (l) => _correct(target: 'route', id: l.routeId)),
            const SizedBox(height: Gap.sm),
            if (_origin != null) // mapapp: the same trip on the map, side by side with other ways
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const ValueKey('city_see_on_map'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => _openMap(),
                    icon: const Icon(Icons.map_rounded),
                    label: Text(t.cityMapSeeOnMap),
                  ),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('city_start_sj'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                onPressed: () => startCityJourney(context, option: opt, dest: d),
                icon: const Icon(Icons.shield_rounded),
                label: Text(t.cityStartSafeJourney),
              ),
            ),
            const SizedBox(height: Gap.xs),
            Text(t.cityStartSafeJourneySub, style: AType.bodySmall),
          ]),
      ));
      // adwire: More routes (Google) — only online results, budget allowing
      if (_gReady && !p.offline && _origin != null)
        out.add(Padding(
          padding: const EdgeInsets.only(top: Gap.sm),
          child: CityRouteCompare(
            key: const ValueKey('city_google_more'),
            plan: null,
            googleView: true,
            google: _google,
            googleLoading: _gLoading,
            googleTried: _gTried,
            googleSelected: _gSel,
            moreRoutesLabel: t.adwireMoreRoutesGoogle,
            onMoreRoutes: _onMoreRoutes,
            onPickGoogle: (i) => setState(() => _gSel = i),
          ),
        ));
    }
    if (p.otherWays.isNotEmpty) {
      out.add(CitySection(t.cityOtherWays, icon: Icons.alt_route_rounded));
      for (final w in p.otherWays) {
        out.add(_otherWay(t, w, p.complaint));
      }
    }
    out.add(Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => _correct(target: 'other'),
        icon: const Icon(Icons.flag_outlined),
        label: Text(t.cityReportMistake),
      ),
    ));
    return out;
  }

  List<Widget> _liveOnRoute(AppLocalizations t, CityOption opt) {
    if (_reports.isEmpty) return const [];
    final ids = {for (final l in opt.legs) if (l.routeId.isNotEmpty) l.routeId};
    final pts = [
      for (final l in opt.legs)
        for (final p in [l.board, l.alight, l.from, l.to])
          if (p?.lat != null && p?.lon != null) (p!.lat!, p.lon!)
    ];
    final hits = _reports.where((r) {
      if (r.routeId.isNotEmpty && ids.contains(r.routeId)) return true;
      if (r.lat == null || r.lon == null) return false;
      return pts.any((p) => havM(p.$1, p.$2, r.lat!, r.lon!) < 600);
    }).toList();
    if (hits.isEmpty) return const [];
    return [
      const SizedBox(height: Gap.sm),
      for (final r in hits.take(3))
        _banner(Icons.campaign_rounded,
            cityD(context, '${cityReportName(t, r.kind)} · ${t.cityReportCount('${r.count}', '${r.minutesAgo}')}')),
    ];
  }

  Widget _otherWay(AppLocalizations t, CityOtherWay w, CityComplaint complaint) {
    return DsCard(key: ValueKey('city_other_${w.mode}'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(cityModeIcon(w.mode), color: cityModeColor(w.mode)),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(cityModeName(t, w.mode),
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800))),
            Text(cityMinutes(context, w.minutes), style: AType.titleMedium),
          ]),
          const SizedBox(height: Gap.xs),
          if (w.mode == 'cng')
            CityCngCard(way: w, complaint: complaint)
          else if (w.fare != null)
            CityFareChip(w.fare!),
          if (w.mode == 'ride_bike' || w.mode == 'ride_car') Text(t.cityRideShareNote, style: AType.bodySmall),
          if (w.mode == 'cng' || w.mode == 'rickshaw')
            TextButton.icon(
              key: ValueKey('city_paid_${w.mode}'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => _farePaid(w),
              icon: const Icon(Icons.payments_outlined),
              label: Text(t.cityIPaid),
            ),
        ]),
    );
  }

  Widget _banner(IconData icon, String text) {
    final s = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: Gap.sm),
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(color: s.surfaceContainerHighest, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(children: [
        Icon(icon, size: 20, color: s.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(text)),
      ]),
    );
  }

  Widget _emptyHint(AppLocalizations t) {
    final s = Theme.of(context).colorScheme;
    return DsSurface(key: const ValueKey('city_empty'), color: s.secondaryContainer,
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.cityEmptyTitle,
              style: AType.titleLarge.copyWith(color: s.onSecondaryContainer, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          Text(t.cityEmptyBody, style: TextStyle(color: s.onSecondaryContainer)),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('city_where_to_btn'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _pickTo,
              icon: const Icon(Icons.search_rounded),
              label: Text(t.cityWhereTo),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Text(t.cityEmptyHow, style: AType.bodySmall.copyWith(color: s.onSecondaryContainer)),
        ]),
    );
  }

  Widget _exploreGrid(AppLocalizations t) {
    final city = _where?.city.isNotEmpty == true ? _where!.city : 'dhaka';
    final o = _origin;
    // gap-city: "around me", live reports and mapping a stop are about where
    // the phone IS — never the typed start (a jam report at the chosen From
    // place would be filed at the wrong spot)
    final me = _here;
    final tiles = <(Key, IconData, Color, String, String, VoidCallback)>[
      // mapapp: the City map (our map + layers; Google view switch)
      if (o != null)
        (const ValueKey('city_tile_map'), Icons.map_rounded, Brand.purple, t.cityMapScreenTitle, t.cityMapTileSub,
            () => _openMap()),
      (const ValueKey('city_tile_metro'), Icons.subway_rounded, Brand.success, t.cityMetroGuide,
          t.cityMetroGuideSub, () => _open(CityMetroScreen(city: city, store: _store, dest: _to))),
      (const ValueKey('city_tile_around'), Icons.near_me_rounded, Brand.info, t.cityAroundMe, t.cityAroundMeSub,
          () => _openForDest(CityAroundScreen(debugHere: me, routeHere: true))),
      (const ValueKey('city_tile_live'), Icons.campaign_rounded, Brand.warning, t.cityLiveReports,
          t.cityLiveReportsSub, () => _open(CityReportsScreen(debugHere: me))),
      (const ValueKey('city_tile_women'), Icons.woman_rounded, Brand.danger, t.cityWomen, t.cityWomenSub,
          () => _open(CityWomenScreen(city: city))),
      (const ValueKey('city_tile_long'), Icons.directions_boat_rounded, Brand.blue, t.cityLongDistance,
          t.cityLongDistanceSub,
          () => _openForDest(
              CityDirectoryScreen(city: city, kinds: const ['terminals', 'ghats'], routeHere: true, store: _store))),
      (const ValueKey('city_tile_offices'), Icons.account_balance_rounded, Brand.blueDeep, t.cityOffices,
          t.cityOfficesSub,
          () => _openForDest(CityDirectoryScreen(city: city, kinds: const ['offices'], routeHere: true, store: _store))),
      // citycov: field collection
      (const ValueKey('city_tile_mapstop'), Icons.add_location_alt_rounded, Brand.success, t.cityMapStop,
          t.cityMapStopSub, () => _open(CityFieldScreen(debugHere: me))),
    ];
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 560 ? 3 : (MediaQuery.textScalerOf(context).scale(14) > 22 ? 1 : 2);
      final w = (c.maxWidth - Gap.sm * (cols - 1)) / cols;
      return Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        for (final e in tiles)
          SizedBox(
            width: w,
            // design2: alive DS tile (lifts on press), icon in a tinted bubble
            child: DsSurface(
              key: e.$1,
              onTap: e.$6,
              padding: const EdgeInsets.all(Gap.md),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 72),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: e.$3.withValues(alpha: DsTokens.of(context).isDark ? 0.22 : 0.12),
                      borderRadius: BorderRadius.circular(DsRadius.card),
                    ),
                    child: Icon(e.$2, color: Brand.onTint(context, e.$3), size: 24),
                  ),
                  const SizedBox(height: Gap.sm),
                  Text(e.$4, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
                  Text(e.$5, style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
                ]),
              ),
            ),
          ),
      ]);
    });
  }

  String _timeText(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final t = AppLocalizations.of(context);
    if (cityBn(context)) {
      // gap-city: a real Bangla time of day (dawn ... night, from the ARB)
      final x = d.hour;
      final hm = '$h:$m';
      if (x >= 4 && x < 6) return t.cityGAtDawn(hm);
      if (x >= 6 && x < 12) return t.cityGAtMorning(hm);
      if (x >= 12 && x < 15) return t.cityGAtNoon(hm);
      if (x >= 15 && x < 18) return t.cityGAtAfternoon(hm);
      if (x >= 18 && x < 20) return t.cityGAtEvening(hm);
      return t.cityGAtNight(hm);
    }
    return d.hour < 12 ? t.cityTimeAm('$h:$m') : t.cityTimePm('$h:$m');
  }

  // ---- corrections + fares paid ----
  Future<void> _correct({required String target, String id = ''}) async {
    final o = _origin;
    await showCityCorrection(context, api: _api, target: target, targetId: id, lat: o?.lat, lon: o?.lon);
  }

  Future<void> _farePaid(CityOtherWay w) async {
    final t = AppLocalizations.of(context);
    final c = TextEditingController();
    final paid = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.cityIPaidTitle(cityModeName(t, w.mode)), style: AType.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(t.cityIPaidSub),
          const SizedBox(height: Gap.sm),
          TextField(
            key: const ValueKey('city_paid_field'),
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 5,
            buildCounter: localCounter,
            decoration: InputDecoration(prefixText: '৳ ', labelText: t.cityIPaidLabel),
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('city_paid_send'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: () => Navigator.pop(ctx, parseIntInput(_asciiDigits(c.text.trim()))),
              child: Text(t.citySend),
            ),
          ),
        ]),
      ),
    );
    c.dispose();
    if (paid == null || paid <= 0 || !mounted) return;
    final o = _origin, d = _to;
    final msg = ScaffoldMessenger.of(context);
    try {
      await _api.cityFareReport(w.mode, paid, km: w.km, fLat: o?.lat, fLon: o?.lon, tLat: d?.lat, tLon: d?.lng);
      msg.showSnackBar(SnackBar(content: Text(t.cityThanksFare)));
    } catch (_) {
      msg.showSnackBar(SnackBar(content: Text(t.citySendFailed)));
    }
  }
}

IconData _pickIcon(CityPick k) => switch (k) {
      CityPick.cheapest => Icons.savings_rounded,
      CityPick.fastest => Icons.bolt_rounded,
      CityPick.fewestChanges => Icons.linear_scale_rounded,
      CityPick.saferNight => Icons.nightlight_round,
    };

String _pickName(AppLocalizations t, CityPick k) => switch (k) {
      CityPick.cheapest => t.cityCheapest,
      CityPick.fastest => t.cityFastest,
      CityPick.fewestChanges => t.cityFewestChanges,
      CityPick.saferNight => t.citySaferNight,
    };

/// Bangla digits typed on a Bangla keyboard -> ASCII for parsing.
String _asciiDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r >= 0x09E6 && r <= 0x09EF ? r - 0x09E6 + 0x30 : r);
  }
  return b.toString();
}

/// One-tap corrections (B14): pick what is wrong, optionally say more.
Future<void> showCityCorrection(BuildContext context,
    {required ApiClient api, required String target, String targetId = '', double? lat, double? lon}) async {
  final t = AppLocalizations.of(context);
  final kinds = <(String, String)>[
    ('wrong_stop', t.cityFixStop),
    ('wrong_route', t.cityFixRoute),
    ('wrong_fare', t.cityFixFare),
    ('wrong_gate', t.cityFixGate),
    ('closed', t.cityFixClosed),
    ('other', t.cityFixOther),
  ];
  final text = TextEditingController();
  String? kind;
  final sent = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Padding(
        padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(ctx).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.cityFixTitle, style: AType.titleLarge),
            const SizedBox(height: Gap.xs),
            Text(t.cityFixSub),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final k in kinds)
                ChoiceChip(
                  key: ValueKey('city_fix_${k.$1}'),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  selected: kind == k.$1,
                  onSelected: (_) => set(() => kind = k.$1),
                  label: Text(k.$2),
                ),
            ]),
            const SizedBox(height: Gap.sm),
            TextField(
              key: const ValueKey('city_fix_text'),
              controller: text,
              maxLength: 300,
              maxLines: 3,
              minLines: 1,
              buildCounter: localCounter,
              decoration: InputDecoration(labelText: t.cityFixMore),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('city_fix_send'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                onPressed: kind == null ? null : () => Navigator.pop(ctx, true),
                child: Text(t.citySend),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
  final note = text.text.trim();
  text.dispose();
  if (sent != true || kind == null || !context.mounted) return;
  final msg = ScaffoldMessenger.of(context);
  try {
    await api.cityCorrection(target: target, targetId: targetId, kind: kind!, text: note, lat: lat, lon: lon);
    msg.showSnackBar(SnackBar(content: Text(t.cityThanksFix)));
  } catch (_) {
    msg.showSnackBar(SnackBar(content: Text(t.citySendFailed)));
  }
}

/// Trip learning consent (B13; owner decision 9 Nov 14:20): says plainly
/// that points are collected only while a journey started here is running
/// (Safe Journey's foreground notification), never in the background, and
/// that no new permission is asked. true = agreed.
Future<bool?> showCityLearnConsent(BuildContext context) {
  final t = AppLocalizations.of(context);
  final lines = [
    (Icons.directions_bus_rounded, t.cityLearnWhen),
    (Icons.do_not_disturb_on_rounded, t.cityLearnNever),
    (Icons.person_off_rounded, t.cityLearnNoNames),
    (Icons.delete_sweep_rounded, t.cityLearnDelete),
    (Icons.toggle_off_rounded, t.cityLearnOff),
  ];
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.cityLearnTitle, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          Text(t.cityLearnWhy),
          const SizedBox(height: Gap.sm),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(l.$1, size: 22),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(cityD(ctx, l.$2))),
              ]),
            ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('city_learn_agree'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.cityLearnAgree),
            ),
          ),
          const SizedBox(height: Gap.xs),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              key: const ValueKey('city_learn_no'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cityLearnNo),
            ),
          ),
        ]),
      ),
    ),
  );
}
