import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../vehicle/car_mode_engine.dart';
import '../vehicle/route_canvas.dart';
import '../vehicle/veh_format.dart';
import '../vehicle/veh_map.dart';
import '../vehicle/vehicle_api.dart';
import 'camera/camera_screen.dart';
import 'vehicle_obd_screen.dart';
import 'voice_assistant_screen.dart';

/// CAR MODE — big-button UI for Android head units (and phones on a mount).
///
/// Foreground only: trip logging uses the head unit's own GPS ONLY while this
/// screen is open (no background service, no WorkManager). Honest limit shown
/// on screen: a head unit is off when the car is parked, so this cannot
/// replace a hardware tracker for theft protection.
///
/// e2e-vehicle: while a trip is on, a pure [CarModeEngine] turns the fixes
/// into the live map, live speed, moving / stopped state and the SAME alert
/// kinds the hardware tracker raises (over-speed, off the usual route, long
/// stop) — shown on screen with a haptic + system alert sound. The usual
/// route is saved on this phone from a finished trip.
class CarModeScreen extends StatefulWidget {
  /// Test seam: replaces the GPS (no permission prompt, no plugin).
  final Stream<CarFix> Function()? positionSource;

  /// Test seam: map tiles config (otherwise loaded from the server).
  final VehMapConfig? mapConfig;

  const CarModeScreen({super.key, this.positionSource, this.mapConfig});

  @override
  State<CarModeScreen> createState() => _CarModeScreenState();
}

/// One GPS fix fed to Car Mode.
class CarFix {
  final double lat, lng, speedKmh;
  final DateTime at;
  const CarFix(this.lat, this.lng, this.speedKmh, this.at);
}

const _kLimit = 'veh_car_speed_limit';
const _kRoute = 'veh_car_usual_route';
const _kUseRoute = 'veh_car_use_route';
const _limits = [0, 40, 60, 80, 100];

class _CarModeScreenState extends State<CarModeScreen> {
  static const _screenCh = MethodChannel('com.assisto/shopbox');
  StreamSubscription<CarFix>? _sub;
  final List<Map<String, dynamic>> _points = [];
  bool _logging = false, _saving = false;
  double? _speedKmh;
  Map<String, dynamic>? _lastTrip;

  // e2e-vehicle: live engine + settings
  CarModeEngine _eng = CarModeEngine();
  VehMapConfig _mapCfg = const VehMapConfig();
  int _limit = 0;
  bool _useRoute = false;
  List<GeoPt> _usual = const [];
  List<GeoPt> _lastTrail = const [];
  CarAlert? _banner;

  @override
  void initState() {
    super.initState();
    _mapCfg = widget.mapConfig ?? const VehMapConfig();
    _loadPrefs();
    if (widget.mapConfig == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final c = await VehMapConfig.load(context.read<AppState>().api);
        if (mounted) setState(() => _mapCfg = c);
      });
    }
  }

  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kRoute);
      final route = <GeoPt>[];
      if (raw != null) {
        for (final e in (jsonDecode(raw) as List)) {
          final l = e as List;
          route.add(GeoPt((l[0] as num).toDouble(), (l[1] as num).toDouble()));
        }
      }
      if (!mounted) return;
      setState(() {
        _limit = p.getInt(_kLimit) ?? 0;
        _usual = route;
        _useRoute = (p.getBool(_kUseRoute) ?? false) && route.length >= 2;
      });
    } catch (_) {} // prefs unavailable: defaults (no alerts) are safe
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kLimit, _limit);
      await p.setBool(_kUseRoute, _useRoute);
      await p.setString(_kRoute, jsonEncode([for (final g in _usual) [g.lat, g.lng]]));
    } catch (_) {} // best-effort persistence; the current trip still uses the values
  }

  Future<void> _saveUsualRoute() async {
    final tr = AppLocalizations.of(context);
    if (_lastTrail.length < 2) return;
    setState(() {
      _usual = CarModeEngine.simplify(_lastTrail, max: 200);
      _useRoute = true;
    });
    await _savePrefs();
    _snack(tr.e2eVehRouteSaved);
  }

  void _onFix(CarFix f) {
    if (_points.length >= 5000) return;
    _points.add({
      'at': f.at.toUtc().toIso8601String(),
      'lat': f.lat,
      'lng': f.lng,
      'speed_kmh': (f.speedKmh.isFinite && f.speedKmh > 0) ? f.speedKmh : 0,
    });
    final raised = _eng.add(f.lat, f.lng, f.at, f.speedKmh);
    if (raised.isNotEmpty) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    }
    if (mounted) {
      setState(() {
        _speedKmh = _eng.speedKmh;
        if (raised.isNotEmpty) _banner = raised.last;
      });
    }
  }

  void _set(VoidCallback f) => setState(f);

  Stream<CarFix> _gpsStream() => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high, distanceFilter: 10),
      ).map((p) => CarFix(p.latitude, p.longitude,
          (p.speed.isFinite && p.speed >= 0) ? p.speed * 3.6 : -1, DateTime.now()));

  @override
  void dispose() {
    _sub?.cancel();
    _keepOn(false);
    super.dispose();
  }

  Future<void> _keepOn(bool on) async {
    try {
      await _screenCh.invokeMethod('keepScreenOn', {'on': on});
    } catch (_) {}
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _startTrip() async {
    final tr = AppLocalizations.of(context);
    try {
      final src = widget.positionSource;
      if (src == null) {
        if (!await Geolocator.isLocationServiceEnabled()) {
          _snack(tr.vehCarGpsOff);
          return;
        }
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          perm = await Geolocator.requestPermission();
        }
        if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
          _snack(tr.vehCarGpsDenied);
          return;
        }
      }
      _points.clear();
      _eng = CarModeEngine(
        speedLimitKmh: _limit,
        route: _useRoute ? _usual : const [],
        corridorM: 300,
        stopAlertMin: 10,
      );
      _banner = null;
      _sub = (src ?? _gpsStream)()
          .listen(_onFix, onError: (_) {}); // best-effort: a GPS hiccup must not stop the trip
      setState(() => _logging = true);
      unawaited(_keepOn(true)); // best-effort; never blocks the trip UI
    } catch (_) {
      _snack(tr.vehCarGpsOff);
    }
  }

  Future<void> _stopTrip() async {
    final tr = AppLocalizations.of(context);
    // Not awaited: a GPS stream cancel needs nothing back, and awaiting it
    // must never be able to stall saving the trip.
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    unawaited(_keepOn(false));
    setState(() {
      _logging = false;
      _saving = true;
      _lastTrail = List.of(_eng.trail);
    });
    if (_points.length < 2) {
      _snack(tr.vehCarTooShort);
      setState(() => _saving = false);
      return;
    }
    try {
      final r = await context.read<AppState>().api.vehCarModeTrip(List.of(_points),
          speedLimitKmh: _limit,
          route: (_useRoute && _usual.length >= 2)
              ? {
                  'id': 'usual',
                  'points': [for (final g in _usual) [g.lat, g.lng]],
                  'corridor_m': 300,
                  'stop_alert_min': 10,
                }
              : null);
      if (mounted) setState(() => _lastTrip = r);
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _navigate() async {
    final tr = AppLocalizations.of(context);
    final c = TextEditingController();
    final dest = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.vehCarNavTitle),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(labelText: tr.vehCarNavHint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text), child: Text(tr.vehCarNavGo)),
        ],
      ),
    );
    if (dest == null || dest.trim().isEmpty) return;
    final q = Uri.encodeComponent(dest.trim());
    try {
      final ok = await launchUrl(Uri.parse('google.navigation:q=$q'),
          mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {} // best-effort: falls through to the web-maps link, which shows vehCarNoMaps on failure
    try {
      await launchUrl(
          Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$q'),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      _snack(tr.vehCarNoMaps);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.of(context).size.width > 600;
    final tiles = <Widget>[
      _BigButton(
        icon: Icons.navigation_rounded,
        label: tr.vehCarNavigate,
        color: Brand.blue,
        onTap: _navigate,
      ),
      _BigButton(
        icon: Icons.mic_none_rounded,
        label: tr.vehCarVoice,
        color: Brand.purple,
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const VoiceAssistantScreen())),
      ),
      _BigButton(
        key: const ValueKey('car-trip'),
        icon: _logging ? Icons.stop_circle_rounded : Icons.route_rounded,
        label: _logging ? tr.vehCarStopTrip : tr.vehCarStartTrip,
        color: _logging ? scheme.error : Brand.success,
        busy: _saving,
        onTap: _saving ? null : (_logging ? _stopTrip : _startTrip),
      ),
      _BigButton(
        icon: Icons.car_repair_rounded,
        label: tr.vehObdTitle,
        color: Brand.warning,
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const VehicleObdScreen())),
      ),
      _BigButton(
        icon: Icons.videocam_rounded,
        label: tr.vehCarDashcam,
        color: Brand.cyan,
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const CameraScreen())),
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr.vehCarModeTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Gap.md),
          children: [
            if (_logging || _eng.trail.isNotEmpty) _liveCard(tr, scheme),
            if (_banner != null) _alertBanner(tr, scheme, _banner!),
            if (_logging)
              Card(
                margin: const EdgeInsets.only(bottom: Gap.md),
                color: scheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Row(children: [
                    Icon(Icons.fiber_manual_record_rounded, color: scheme.error),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(
                        tr.vehCarLogging(vehNumStr(context, _points.length),
                            tr.vehKmh(vehNumStr(context, (_speedKmh ?? 0).clamp(0, 400)))),
                        style: TextStyle(
                            color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ]),
                ),
              ),
            if (_lastTrip != null)
              Card(
                margin: const EdgeInsets.only(bottom: Gap.md),
                child: ListTile(
                  leading: const Icon(Icons.check_circle_rounded, color: Brand.success),
                  title: Text(tr.vehCarTripSaved),
                  subtitle: Text(
                    '${tr.vehKm(vehNumStr(context, vehNum(_lastTrip!['total_km']) ?? 0, decimals: 1))}  ·  '
                    '${vehDuration(context, tr, vehInt(_lastTrip!['moving_s']) ?? 0)}',
                  ),
                ),
              ),
            if (!_logging && _lastTrail.length >= 2)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.md),
                child: OutlinedButton.icon(
                  key: const ValueKey('car-save-route'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: _saveUsualRoute,
                  icon: const Icon(Icons.alt_route_rounded),
                  label: Text(tr.e2eVehSaveRoute, textAlign: TextAlign.center),
                ),
              ),
            if (!_logging) _alertSettings(tr, scheme),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: wide ? 3 : 2,
              mainAxisSpacing: Gap.md,
              crossAxisSpacing: Gap.md,
              // qa1: taller tiles at large font (fixed ratio overflowed at 2.0x)
              childAspectRatio: (wide ? 1.5 : 1.05) /
                  MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6),
              children: tiles,
            ),
            const SizedBox(height: Gap.md),
            Card(
              margin: EdgeInsets.zero,
              color: scheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.info_outline_rounded, color: scheme.onSecondaryContainer),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(tr.vehCarHonest,
                        style: TextStyle(
                            color: scheme.onSecondaryContainer, height: 1.35)),
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension on _CarModeScreenState {
  Widget _liveCard(AppLocalizations tr, ColorScheme scheme) {
    final e = _eng;
    final speed = tr.vehKmh(vehNumStr(context, e.speedKmh.round()));
    final state = e.moving
        ? tr.e2eVehMoving
        : tr.e2eVehStoppedFor(vehNumStr(context, e.stoppedMinutes));
    final d = e.distanceToRouteM;
    final over = _limit > 0 && e.speedKmh > _limit;
    return Card(
      key: const ValueKey('car-live'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(
            aspectRatio: 1.4,
            child: VehMap(
              config: _mapCfg,
              route: e.trail,
              plannedRoute: _useRoute ? _usual : const [],
              live: e.live,
              follow: true,
              semanticsLabel: tr.e2eVehCarMapSemantics(speed, state),
            ),
          ),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: Gap.md,
            runSpacing: Gap.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(speed,
                    key: const ValueKey('car-speed'),
                    style: AType.headlineMedium.copyWith(
                        fontWeight: FontWeight.w800,
                        fontFeatures: AFonts.tabular,
                        color: over ? scheme.error : scheme.onSurface)),
              ),
              Chip(
                key: const ValueKey('car-state'),
                avatar: Icon(e.moving ? Icons.directions_car_rounded : Icons.local_parking_rounded,
                    size: 18),
                label: Text(state),
              ),
              if (d != null)
                Chip(
                  key: const ValueKey('car-route-state'),
                  backgroundColor: e.offRoute ? scheme.errorContainer : null,
                  avatar: Icon(e.offRoute ? Icons.wrong_location_rounded : Icons.alt_route_rounded,
                      size: 18, color: e.offRoute ? scheme.onErrorContainer : null),
                  label: Text(
                      e.offRoute
                          ? tr.e2eVehOffRoute(vehNumStr(context, d.round()))
                          : tr.e2eVehOnRoute,
                      style: TextStyle(color: e.offRoute ? scheme.onErrorContainer : null)),
                ),
            ],
          ),
        ]),
      ),
    );
  }

  Widget _alertBanner(AppLocalizations tr, ColorScheme scheme, CarAlert a) {
    final text = switch (a.kind) {
      CarAlertKind.overspeed => tr.e2eVehAlertOverspeed(
          tr.vehKmh(vehNumStr(context, a.speedKmh.round())),
          tr.vehKmh(vehNumStr(context, _limit))),
      CarAlertKind.offRoute => tr.e2eVehAlertOffRoute(vehNumStr(context, a.distanceM)),
      CarAlertKind.longStop => tr.e2eVehAlertLongStop(vehNumStr(context, a.minutes)),
    };
    return Card(
      key: const ValueKey('car-alert'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      color: scheme.errorContainer,
      child: Semantics(
        liveRegion: true,
        child: ListTile(
          minVerticalPadding: Gap.sm,
          leading: Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          title: Text(text,
              style: TextStyle(
                  color: scheme.onErrorContainer, fontWeight: FontWeight.w700, height: 1.3)),
          trailing: IconButton(
            tooltip: tr.close,
            icon: Icon(Icons.close_rounded, color: scheme.onErrorContainer),
            onPressed: () => _set(() => _banner = null),
          ),
        ),
      ),
    );
  }

  Widget _alertSettings(AppLocalizations tr, ColorScheme scheme) {
    return Card(
      key: const ValueKey('car-settings'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr.e2eVehSpeedAlert, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final l in _limits)
              ChoiceChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: Text(l == 0 ? tr.e2eVehOff : tr.vehKmh(vehNumStr(context, l))),
                selected: _limit == l,
                onSelected: (_) {
                  _set(() => _limit = l);
                  _savePrefs();
                },
              ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr.e2eVehUseRoute),
            subtitle: _usual.length < 2 ? Text(tr.e2eVehNoRouteYet) : null,
            value: _useRoute && _usual.length >= 2,
            onChanged: _usual.length < 2
                ? null
                : (v) {
                    _set(() => _useRoute = v);
                    _savePrefs();
                  },
          ),
        ]),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool busy;
  const _BigButton(
      {super.key,
      required this.icon,
      required this.label,
      required this.color,
      required this.onTap,
      this.busy = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            busy
                ? const SizedBox(
                    width: 40, height: 40, child: CircularProgressIndicator())
                : Icon(icon, size: 48, color: color),
            const SizedBox(height: Gap.sm),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface)),
          ]),
        ),
      ),
    );
  }
}
