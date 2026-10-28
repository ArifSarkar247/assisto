import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../payments/credits_out_sheet.dart'; // credout
import '../services/security_guard.dart';
import '../state.dart';
import '../theme.dart';
import '../vehicle/car_mode_engine.dart';
import '../vehicle/route_canvas.dart';
import '../vehicle/veh_map.dart';
import '../vehicle/veh_format.dart';
import '../vehicle/vehicle_api.dart';
import '../widgets/skeleton.dart';
import 'vehicle_obd_screen.dart';
import 'vehicle_tracker_settings_screen.dart';
import 'package:assisto/widgets/app_sheet.dart';
import 'vehicle_report_screen.dart'; // veh100
import 'vehicle_drivers_screen.dart'; // veh100
import '../vehicle/veh_share_sheet.dart'; // veh100
import '../services/action_feedback.dart'; // db1

/// ONE tracker: live position, animated 24 h route playback, trips / stops /
/// mileage (computed server-side), remote engine cut-off with an honest
/// command lifecycle, AI "unusual trips" summary, OBD + settings entries.
class VehicleTrackerScreen extends StatefulWidget {
  final int trackerId;
  const VehicleTrackerScreen({super.key, required this.trackerId});

  @override
  State<VehicleTrackerScreen> createState() => _VehicleTrackerScreenState();
}

class _VehicleTrackerScreenState extends State<VehicleTrackerScreen> {
  Map<String, dynamic>? _t;
  Map<String, dynamic> _route = const {};
  List<Map<String, dynamic>> _commands = const [];
  bool _loading = true, _error = false, _sending = false, _planBusy = false;
  Timer? _poll;
  VehMapConfig _mapCfg = const VehMapConfig();

  // playback
  Timer? _play;
  int? _playIdx;
  int _speedX = 8;

  // AI summary
  bool _aiBusy = false;
  Map<String, dynamic>? _ai;

  @override
  void initState() {
    super.initState();
    _load();
    _schedulePoll();
  }

  /// Foreground-only refresh while this screen is open (no background work):
  /// every 8 s while the vehicle moves (the marker glides between fixes),
  /// every 20 s while it stands still — fewer requests, same freshness.
  void _schedulePoll() {
    _poll?.cancel();
    final moving = vehMap(_t?['live'])['moving'] == true;
    _poll = Timer(Duration(seconds: moving ? 8 : 20), () async {
      await _refreshLive();
      if (mounted) _schedulePoll();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _play?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _t == null;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      final res = await Future.wait([
        api.vehTracker(widget.trackerId),
        api.vehRoute(widget.trackerId),
        api.vehCommands(widget.trackerId),
      ]);
      _t = res[0];
      _route = res[1];
      _commands = vehList(res[2]['commands']);
      _mapCfg = await VehMapConfig.load(api); // never throws (canvas fallback)
    } catch (_) {
      _error = _t == null;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshLive() async {
    if (!mounted || _sending) return;
    final api = context.read<AppState>().api;
    try {
      final t = await api.vehTracker(widget.trackerId);
      final c = await api.vehCommands(widget.trackerId);
      if (mounted) {
        setState(() {
          _t = t;
          _commands = vehList(c['commands']);
        });
      }
    } catch (_) {}
  }

  /// The live point with its heading (the marker points where it drives).
  GeoPt? _livePt(Map<String, dynamic> t) {
    final live = vehMap(t['live']);
    final lat = vehNum(live['lat']), lng = vehNum(live['lng']);
    if (lat == null || lng == null) return null;
    return GeoPt(lat, lng,
        speed: vehNum(live['speed_kmh']) ?? 0,
        course: vehNum(live['course']) ?? 0,
        at: vehDate(live['at']));
  }

  int _limit(Map<String, dynamic> t) =>
      vehInt(vehMap(t['settings'])['speed_limit_kmh']) ?? 0;

  List<GeoPt> get _points => vehList(_route['points'])
      .map((p) => GeoPt(vehNum(p['lat']) ?? 0, vehNum(p['lng']) ?? 0,
          at: vehDate(p['at']), speed: vehNum(p['speed_kmh']) ?? 0))
      .toList();

  List<GeoPt> _planned(Map<String, dynamic> t) {
    final routes = vehList(vehMap(t['settings'])['routes']);
    if (routes.isEmpty) return const [];
    final pts = routes.first['points'];
    if (pts is! List) return const [];
    return [
      for (final p in pts)
        if (p is List && p.length >= 2)
          GeoPt(vehNum(p[0]) ?? 0, vehNum(p[1]) ?? 0),
    ];
  }

  /// Owner: the latest trip (else the whole 24 h route) becomes the planned
  /// route — off-route + long-stop alerts are then raised SERVER-side.
  Future<void> _setPlanned(bool clear) async {
    final tr = AppLocalizations.of(context);
    var pts = _points;
    final trips = vehList(_route['trips']);
    if (trips.isNotEmpty) {
      final s = vehDate(trips.last['start']), e = vehDate(trips.last['end']);
      if (s != null && e != null) {
        final sub = pts
            .where((p) => p.at != null && !p.at!.isBefore(s) && !p.at!.isAfter(e))
            .toList();
        if (sub.length >= 2) pts = sub;
      }
    }
    if (!clear && pts.length < 2) {
      _snack(tr.e2eVehPlanNeedsTrip);
      return;
    }
    setState(() => _planBusy = true);
    try {
      final t = await context.read<AppState>().api.vehSetRoutes(
          widget.trackerId,
          clear
              ? const []
              : [
                  {
                    'id': 'r1',
                    'name': '${_t?['name'] ?? ''}',
                    'points': [
                      for (final g in CarModeEngine.simplify(pts, max: 200)) [g.lat, g.lng]
                    ],
                    'corridor_m': 300,
                    'stop_alert_min': 15,
                  }
                ]);
      if (mounted) setState(() => _t = t);
      _snack(clear ? tr.e2eVehPlanCleared : tr.e2eVehPlanSaved);
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
    if (mounted) setState(() => _planBusy = false);
  }

  void _togglePlay() {
    final pts = _points;
    if (pts.length < 2) return;
    if (_play != null) {
      _play!.cancel();
      setState(() => _play = null);
      return;
    }
    var i = (_playIdx == null || _playIdx! >= pts.length - 1) ? 0 : _playIdx!;
    _play = Timer.periodic(const Duration(milliseconds: 120), (tm) {
      i = (i + _speedX ~/ 2).clamp(0, pts.length - 1);
      if (!mounted) return tm.cancel();
      setState(() => _playIdx = i);
      if (i >= pts.length - 1) {
        tm.cancel();
        setState(() => _play = null);
      }
    });
    setState(() => _playIdx = i);
  }

  Future<void> _openMaps(double lat, double lng) async {
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      showActionFailed(context, 'vehTracker.maps', e, open: true); // db1
    }
  }

  Future<void> _command(String kind) async {
    final tr = AppLocalizations.of(context);
    final cut = kind == 'engine_cut';
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        icon: Icon(cut ? Icons.power_settings_new_rounded : Icons.restart_alt_rounded),
        title: Text(cut ? tr.vehCutConfirmTitle : tr.vehRestoreConfirmTitle),
        content: Text(cut ? tr.vehCutConfirmBody : tr.vehRestoreConfirmBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(
            style: cut
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(cut ? tr.vehCutCta : tr.vehRestoreCta),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    // Same gate as Section-8 sensitive actions: class-3 biometric, then the
    // Assisto Security PIN (checked SERVER-side, with lockout).
    const guard = SecurityGuard();
    if (!await guard.ensureBiometric(context)) return;
    if (!mounted) return;
    final pin = await guard.askPin(context, tr);
    if (pin == null || pin.isEmpty || !mounted) return;
    setState(() => _sending = true);
    final api = context.read<AppState>().api;
    try {
      var r = await api.vehSendCommand(widget.trackerId, kind, pin);
      final token = r['confirm_token'];
      if (token is String && token.isNotEmpty) {
        // veh100: the SECOND confirmation (the server re-checks that the
        // vehicle is still standing still before anything is sent).
        if (mounted) setState(() => _sending = false);
        final cid = vehInt(vehMap(r['command'])['id']) ?? 0;
        final go2 = mounted ? await _finalConfirm(tr) : false;
        if (!mounted) return;
        if (go2 != true) {
          try {
            await api.vehCancel(cid);
          } catch (_) {} // best-effort: an unconfirmed request expires by itself in 60 s
          _snack(tr.v100CutNotSent);
          _refreshLive();
          return;
        }
        setState(() => _sending = true);
        r = await api.vehConfirmCommand(cid, token);
      }
      final state = '${vehMap(r['command'])['state']}';
      _snack(state == 'awaiting_approval' ? tr.vehCmdAwaitingApproval : tr.vehCmdQueued);
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
    if (mounted) setState(() => _sending = false);
    _refreshLive();
  }

  /// Final check, shown AFTER the PIN: what the tracker reports right now and
  /// a 60-second window. Default focus is "Do not cut".
  Future<bool?> _finalConfirm(AppLocalizations tr) {
    final t = _t ?? const {};
    final live = vehMap(t['live']);
    final speed = vehNum(live['speed_kmh']) ?? 0;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _CutFinalDialog(
        tr: tr,
        speedText: tr.vehKmh(vehNumStr(context, speed)),
        fixAgo: vehAgo(context, tr, vehDate(live['at'])),
      ),
    );
  }

  Future<void> _cancelCommand(int id) async {
    final tr = AppLocalizations.of(context);
    try {
      await context.read<AppState>().api.vehCancel(id);
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
    _refreshLive();
  }

  Future<void> _aiSummary({bool creditsRetry = false}) async {
    setState(() => _aiBusy = true);
    final lang = Localizations.localeOf(context).languageCode;
    try {
      final r = await context.read<AppState>().api.vehAiSummary(widget.trackerId, lang);
      if (mounted) setState(() => _ai = r);
      // credout: the free rule summary is shown; out of credits also opens
      // the buy-credits sheet (no ads on vehicle screens) and, once credits
      // land, asks for the AI summary again once.
      if (mounted && !creditsRetry && r['ai'] == false && r['reason'] == 'credits') {
        setState(() => _aiBusy = false);
        final ok = await CreditsOut.offer(context, screen: 'vehicle');
        if (ok && mounted) {
          await _aiSummary(creditsRetry: true);
          return;
        }
      }
    } catch (e) {
      if (mounted) _snack(vehReasonText(AppLocalizations.of(context), e));
    }
    if (mounted) setState(() => _aiBusy = false);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final t = _t;
    final name = '${t?['name'] ?? ''}'.trim();
    return Scaffold(
      appBar: AppBar(
        title: Text(name.isEmpty ? tr.vehUnnamedTracker : name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (t?['is_owner'] == true)
            IconButton(
              tooltip: tr.vehSettingsTitle,
              icon: const Icon(Icons.tune_rounded),
              onPressed: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            VehicleTrackerSettingsScreen(tracker: Map.of(t!))));
                if (mounted) _load();
              },
            ),
        ],
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: tr.vehLoadError,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr.retry)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(Gap.md),
                    children: [
                      _liveCard(tr, scheme, t!),
                      const SizedBox(height: Gap.md),
                      _mapCard(tr, scheme, t),
                      const SizedBox(height: Gap.md),
                      _summaryCard(tr, scheme),
                      const SizedBox(height: Gap.md),
                      _moreCard(tr, scheme, t),
                      const SizedBox(height: Gap.md),
                      if (vehMap(t['access'])['command'] == true) ...[
                        _engineCard(tr, scheme, t),
                        const SizedBox(height: Gap.md),
                      ],
                      _aiCard(tr, scheme),
                      const SizedBox(height: Gap.md),
                      Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          leading: const Icon(Icons.car_repair_rounded),
                          title: Text(tr.vehObdTitle),
                          subtitle: Text(tr.vehObdSubtitle,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      VehicleObdScreen(trackerId: widget.trackerId))),
                        ),
                      ),
                      const SizedBox(height: Gap.xl),
                    ],
                  ),
                ),
    );
  }

  Widget _stat(String label, String value, IconData icon, ColorScheme scheme) {
    return Container(
      constraints: const BoxConstraints(minWidth: 96),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.xs),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value,
                style: const TextStyle(fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            Text(label,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
    );
  }

  Widget _liveCard(AppLocalizations tr, ColorScheme scheme, Map<String, dynamic> t) {
    final live = vehMap(t['live']);
    final online = t['online'] == true;
    final speed = vehNum(live['speed_kmh']) ?? 0;
    final age = vehInt(live['fix_age_s']);
    final ign = t['ignition'];
    final volt = vehNum(t['ext_voltage_v']);
    final lat = vehNum(live['lat']), lng = vehNum(live['lng']);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                  color: online ? Brand.success : scheme.outline, shape: BoxShape.circle),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                online
                    ? (live['moving'] == true
                        ? tr.vehMovingAt(vehNumStr(context, speed))
                        : tr.vehParked)
                    : tr.vehOfflineSince(vehAgo(context, tr, vehDate(t['last_seen_at']))),
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
          if (age != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(tr.vehFixAge(vehAgo(context, tr, vehDate(live['at']))),
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            _stat(tr.vehSpeed, tr.vehKmh(vehNumStr(context, speed)), Icons.speed_rounded, scheme),
            _stat(
                tr.vehIgnition,
                ign == null ? tr.vehUnknown : (ign == true ? tr.vehOn : tr.vehOff),
                Icons.key_rounded,
                scheme),
            if (volt != null)
              _stat(tr.vehBattery, tr.vehVolts(vehNumStr(context, volt, decimals: 1)),
                  Icons.battery_charging_full_rounded, scheme),
          ]),
          if (lat != null && lng != null) ...[
            const SizedBox(height: Gap.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () => _openMaps(lat, lng),
                icon: const Icon(Icons.map_rounded),
                label: Text(tr.vehOpenMaps),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _mapCard(AppLocalizations tr, ColorScheme scheme, Map<String, dynamic> t) {
    final pts = _points;
    final live = vehMap(t['live']);
    final lat = vehNum(live['lat']), lng = vehNum(live['lng']);
    final fences = vehList(vehMap(t['settings'])['geofences'])
        .map((f) => GeoFenceView(vehNum(f['lat']) ?? 0, vehNum(f['lng']) ?? 0,
                vehNum(f['radius_m']) ?? 300, '${f['name'] ?? ''}',
                points: [
                  for (final p in (f['points'] is List ? f['points'] as List : const []))
                    if (p is List && p.length >= 2)
                      GeoPt(vehNum(p[0]) ?? 0, vehNum(p[1]) ?? 0),
                ]))
        .toList();
    final playAt = (_playIdx != null && pts.isNotEmpty)
        ? pts[_playIdx!.clamp(0, pts.length - 1)]
        : null;
    final km = vehNum(_route['total_km']) ?? 0;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr.vehRoute24h, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          AspectRatio(
            aspectRatio: 1.25,
            child: VehMap(
              config: _mapCfg,
              route: pts,
              plannedRoute: _planned(t),
              live: (lat != null && lng != null) ? _livePt(t) : null,
              playIndex: _playIdx,
              fences: fences,
              speedColours: true,
              speedLimitKmh: _limit(t),
              semanticsLabel: tr.vehMapSemantics(vehNumStr(context, km, decimals: 1)),
              emptyLabel: tr.vehNoRoute,
            ),
          ),
          const SizedBox(height: Gap.sm),
          Row(children: [
            IconButton.filledTonal(
              tooltip: _play != null ? tr.vehPause : tr.vehPlay,
              onPressed: pts.length < 2 ? null : _togglePlay,
              icon: Icon(_play != null ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            Expanded(
              child: Slider(
                value: (_playIdx ?? 0).toDouble().clamp(0, (pts.length - 1).clamp(0, 1 << 30).toDouble()),
                min: 0,
                max: (pts.length - 1).clamp(1, 1 << 30).toDouble(),
                onChanged: pts.length < 2
                    ? null
                    : (v) => setState(() => _playIdx = v.round()),
              ),
            ),
            PopupMenuButton<int>(
              tooltip: tr.vehPlaySpeed,
              initialValue: _speedX,
              onSelected: (v) => setState(() => _speedX = v),
              itemBuilder: (_) => [
                for (final x in [2, 8, 32])
                  PopupMenuItem(value: x, child: Text('${vehNumStr(context, x)}×')),
              ],
              child: Padding(
                padding: const EdgeInsets.all(Gap.sm),
                child: Text('${vehNumStr(context, _speedX)}×',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: AFonts.tabular)),
              ),
            ),
          ]),
          // veh100: the timeline — start / end of the 24 h route under the
          // scrubber, the moment + speed of the playback marker above it.
          if (pts.length >= 2)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
              child: Row(children: [
                Expanded(
                  child: Text(vehTime(context, pts.first.at),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AType.bodySmall.copyWith(
                          color: scheme.onSurfaceVariant, fontFeatures: AFonts.tabular)),
                ),
                Expanded(
                  child: Text(vehTime(context, pts.last.at),
                      maxLines: 1,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                      style: AType.bodySmall.copyWith(
                          color: scheme.onSurfaceVariant, fontFeatures: AFonts.tabular)),
                ),
              ]),
            ),
          if (playAt != null)
            Text(
              tr.vehPlaybackAt(vehTime(context, playAt.at),
                  tr.vehKmh(vehNumStr(context, playAt.speed))),
              style: TextStyle(color: scheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if (pts.length >= 2) _speedLegend(tr, scheme, _limit(t)),
          if (t['is_owner'] == true) ...[
            const SizedBox(height: Gap.sm),
            if (_planned(t).length >= 2) ...[
              // Info line + its action stacked, so long Bangla / large-font
              // labels wrap instead of overflowing at 360 dp.
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.alt_route_rounded, color: Brand.purple),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                      tr.e2eVehPlanInfo(vehNumStr(context,
                          vehInt(vehList(vehMap(t['settings'])['routes']).first['corridor_m']) ??
                              300)),
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              ]),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  key: const ValueKey('veh-plan-clear'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _planBusy ? null : () => _setPlanned(true),
                  child: Text(tr.e2eVehPlanClear, textAlign: TextAlign.center),
                ),
              ),
            ] else
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  key: const ValueKey('veh-plan-set'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _planBusy || pts.length < 2 ? null : () => _setPlanned(false),
                  icon: const Icon(Icons.alt_route_rounded),
                  label: Text(tr.e2eVehPlanSave),
                ),
              ),
          ],
        ]),
      ),
    );
  }

  Widget _summaryCard(AppLocalizations tr, ColorScheme scheme) {
    final trips = vehList(_route['trips']);
    final km = vehNum(_route['total_km']) ?? 0;
    final moving = vehInt(_route['moving_s']) ?? 0;
    final maxSpeed = vehNum(_route['max_speed_kmh']) ?? 0;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.vehTripsToday, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            _stat(tr.vehDistance, tr.vehKm(vehNumStr(context, km, decimals: 1)),
                Icons.straighten_rounded, scheme),
            _stat(tr.vehTrips, vehNumStr(context, trips.length), Icons.route_rounded, scheme),
            _stat(tr.vehDriving, vehDuration(context, tr, moving), Icons.timer_rounded,
                scheme),
            _stat(tr.vehTopSpeed, tr.vehKmh(vehNumStr(context, maxSpeed)), Icons.speed_rounded,
                scheme),
          ]),
          if (trips.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(tr.vehNoTrips, style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          for (final tp in trips.reversed.take(8))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(tp['night'] == true ? Icons.nightlight_round_rounded : Icons.route_rounded,
                  color: tp['night'] == true ? Brand.purple : scheme.primary),
              title: Text(
                '${vehTime(context, vehDate(tp['start']))} – ${vehTime(context, vehDate(tp['end']))}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontFeatures: AFonts.tabular),
              ),
              subtitle: Text(
                '${tr.vehKm(vehNumStr(context, vehNum(tp['km']) ?? 0, decimals: 1))}  ·  '
                '${vehDuration(context, tr, vehInt(tp['duration_s']) ?? 0)}'
                '${tp['night'] == true ? '  ·  ${tr.vehNightTrip}' : ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ]),
      ),
    );
  }

  String _cmdState(AppLocalizations tr, Map<String, dynamic> c) {
    switch ('${c['state']}') {
      case 'awaiting_approval':
        return tr.vehCmdStAwaiting;
      case 'queued':
        return tr.vehCmdStQueued;
      case 'sent':
        return tr.vehCmdStSent;
      case 'acked':
        return tr.vehCmdStAcked;
      case 'failed':
        return '${c['fail_reason']}' == 'no_reply'
            ? tr.vehCmdStNoReply
            : tr.vehCmdStFailed;
      case 'cancelled':
      case 'rejected':
        return tr.vehCmdStCancelled;
      default:
        return tr.vehCmdStExpired;
    }
  }

  /// veh100: colour key for the speed-coloured route.
  Widget _speedLegend(AppLocalizations tr, ColorScheme scheme, int limit) {
    final lim = limit > 0 ? limit : 80;
    Widget chip(Color c, String label) => Text.rich(TextSpan(children: [
          WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(
                  width: 14,
                  height: 6,
                  margin: const EdgeInsetsDirectional.only(end: Gap.xs),
                  decoration: BoxDecoration(
                      color: c, borderRadius: BorderRadius.circular(3)))),
          TextSpan(text: label),
        ]), style: AType.bodySmall);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Semantics(
        container: true,
        label: tr.v100LegendA11y(vehNumStr(context, lim)),
        child: ExcludeSemantics(
          child: Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
            chip(Brand.blue, tr.v100LegendCalm),
            chip(Brand.warning, tr.v100LegendNear),
            chip(scheme.error, tr.v100LegendOver(vehNumStr(context, lim))),
          ]),
        ),
      ),
    );
  }

  /// veh100: share live location (owner), daily / monthly report, driver.
  Widget _moreCard(AppLocalizations tr, ColorScheme scheme, Map<String, dynamic> t) {
    final owner = t['is_owner'] == true;
    final drv = vehMap(t['driver']);
    final drvName = '${drv['driver_name'] ?? ''}'.trim();
    Widget tile(Key key, IconData icon, String title, String sub, VoidCallback onTap) =>
        ListTile(
          key: key,
          minVerticalPadding: Gap.sm,
          leading: Icon(icon, color: scheme.primary),
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(sub, maxLines: 3, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        );
    return Card(
      margin: EdgeInsets.zero,
      child: Column(children: [
        if (owner)
          tile(const ValueKey('veh-share'), Icons.share_location_rounded, tr.v100ShareTitle,
              tr.v100ShareSub, () async {
            await showAppSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => VehShareSheet(trackerId: widget.trackerId,
                  paired: '${t['state']}' == 'paired'),
            );
          }),
        tile(const ValueKey('veh-report'), Icons.insights_rounded, tr.v100ReportTitle,
            tr.v100ReportSub, () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => VehicleReportScreen(
                    trackerId: widget.trackerId, name: '${t['name'] ?? ''}')))),
        tile(const ValueKey('veh-driver'), Icons.badge_rounded, tr.v100DriverTitle,
            drvName.isEmpty ? tr.v100DriverNone : tr.v100DriverNow(drvName), () async {
          await Navigator.push(context, MaterialPageRoute(
              builder: (_) => VehicleDriversScreen(
                  trackerId: widget.trackerId, canAssign: owner,
                  currentDriverId: vehInt(drv['driver_id']))));
          if (mounted) _refreshLive();
        }),
      ]),
    );
  }

  Widget _engineCard(AppLocalizations tr, ColorScheme scheme, Map<String, dynamic> t) {
    final cut = t['relay_cut'] == true;
    final pending = _commands.any((c) =>
        ['awaiting_approval', 'queued', 'sent'].contains('${c['state']}'));
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.power_settings_new_rounded, color: cut ? scheme.error : scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(tr.vehEngineTitle, style: Theme.of(context).textTheme.titleMedium),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(
            t['relay_cut'] == null
                ? tr.vehRelayUnknown
                : (cut ? tr.vehRelayCut : tr.vehRelayNormal),
            style: TextStyle(
                fontWeight: FontWeight.w600, color: cut ? scheme.error : Brand.success),
          ),
          const SizedBox(height: Gap.xs),
          Text(tr.vehEngineRules,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
          const SizedBox(height: Gap.xs),
          // veh100: honest safety + legal note, always visible
          Text(tr.v100CutSafetyNote,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
          if (t['engine_cut_enabled'] != true) ...[
            const SizedBox(height: Gap.sm),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline_rounded, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(tr.v100ErrCutOff, style: const TextStyle(height: 1.35))),
            ]),
          ],
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            if (t['engine_cut_enabled'] == true)
              FilledButton.icon(
                key: const ValueKey('veh-cut'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError),
                onPressed: (_sending || pending) ? null : () => _command('engine_cut'),
                icon: const Icon(Icons.block_rounded),
                label: Text(tr.vehCutCta),
              ),
            OutlinedButton.icon(
              onPressed: (_sending || pending) ? null : () => _command('engine_restore'),
              icon: const Icon(Icons.restart_alt_rounded),
              label: Text(tr.vehRestoreCta),
            ),
          ]),
          if (_commands.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(tr.vehRecentCommands, style: Theme.of(context).textTheme.labelLarge),
            for (final c in _commands.take(4))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(
                  '${c['state']}' == 'acked'
                      ? Icons.check_circle_rounded
                      : ('${c['state']}' == 'failed' ? Icons.error_outline_rounded : Icons.schedule_rounded),
                  color: '${c['state']}' == 'acked'
                      ? Brand.success
                      : ('${c['state']}' == 'failed' ? scheme.error : Brand.warning),
                ),
                title: Text(
                  '${'${c['kind']}' == 'engine_cut' ? tr.vehCutCta : tr.vehRestoreCta} · ${_cmdState(tr, c)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(vehDateTime(context, vehDate(c['created_at'])),
                    maxLines: 1, style: const TextStyle(fontFeatures: AFonts.tabular)),
                trailing: ['awaiting_approval', 'queued'].contains('${c['state']}')
                    ? TextButton(
                        onPressed: () => _cancelCommand(c['id'] as int),
                        child: Text(tr.cancel))
                    : null,
              ),
          ],
        ]),
      ),
    );
  }

  Widget _aiCard(AppLocalizations tr, ColorScheme scheme) {
    final ai = _ai;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.auto_awesome_rounded, color: Brand.purple),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(tr.vehAiTitle, style: Theme.of(context).textTheme.titleMedium)),
          ]),
          const SizedBox(height: Gap.xs),
          if (ai == null)
            Text(tr.vehAiBody,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35))
          else ...[
            Text('${ai['text'] ?? ''}', style: const TextStyle(height: 1.4)),
            const SizedBox(height: Gap.xs),
            Text(
              ai['ai'] == true
                  ? tr.vehAiByAi
                  : ('${ai['reason']}' == 'nothing_unusual'
                      ? tr.vehAiNothing
                      : tr.vehAiNoKey),
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: Gap.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonalIcon(
              onPressed: _aiBusy ? null : _aiSummary,
              icon: _aiBusy
                  ? const SizedBox(
                      width: Gap.lg, height: Gap.lg, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.manage_search_rounded),
              label: Text(tr.vehAiCta),
            ),
          ),
        ]),
      ),
    );
  }
}

/// veh100: the final engine-cut confirmation (after the PIN). Shows what the
/// tracker reports now, a 60-second countdown, and defaults to "Do not cut".
class _CutFinalDialog extends StatefulWidget {
  final AppLocalizations tr;
  final String speedText, fixAgo;
  const _CutFinalDialog({required this.tr, required this.speedText, required this.fixAgo});

  @override
  State<_CutFinalDialog> createState() => _CutFinalDialogState();
}

class _CutFinalDialogState extends State<_CutFinalDialog> {
  static const _window = 55; // under the server's 60 s, network included
  int _left = _window;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (tm) {
      if (!mounted) return tm.cancel();
      setState(() => _left--);
      if (_left <= 0) {
        tm.cancel();
        Navigator.pop(context, false);
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: Text(tr.v100CutFinalTitle),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text(tr.v100CutFinalBody(widget.speedText, widget.fixAgo),
              style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.sm),
          Text(tr.v100CutFinalLeft(vehNumStr(context, _left < 0 ? 0 : _left)),
              style: TextStyle(color: scheme.onSurfaceVariant, fontFeatures: AFonts.tabular)),
        ]),
      ),
      actions: [
        FilledButton.tonal(
          autofocus: true,
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr.v100CutKeepRunning),
        ),
        FilledButton(
          key: const ValueKey('veh-cut-final'),
          style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError),
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr.v100CutFinalCta),
        ),
      ],
    );
  }
}
