import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../vehicle/veh_format.dart';
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
class CarModeScreen extends StatefulWidget {
  const CarModeScreen({super.key});

  @override
  State<CarModeScreen> createState() => _CarModeScreenState();
}

class _CarModeScreenState extends State<CarModeScreen> {
  static const _screenCh = MethodChannel('com.assisto/shopbox');
  StreamSubscription<Position>? _sub;
  final List<Map<String, dynamic>> _points = [];
  bool _logging = false, _saving = false;
  double? _speedKmh;
  Map<String, dynamic>? _lastTrip;

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
      _points.clear();
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high, distanceFilter: 10),
      ).listen((p) {
        if (_points.length >= 5000) return;
        _points.add({
          'at': DateTime.now().toUtc().toIso8601String(),
          'lat': p.latitude,
          'lng': p.longitude,
          'speed_kmh': (p.speed.isFinite && p.speed > 0) ? p.speed * 3.6 : 0,
        });
        if (mounted) setState(() => _speedKmh = p.speed * 3.6);
      }, onError: (_) {}); // best-effort: a GPS hiccup must not stop the trip
      await _keepOn(true);
      setState(() => _logging = true);
    } catch (_) {
      _snack(tr.vehCarGpsOff);
    }
  }

  Future<void> _stopTrip() async {
    final tr = AppLocalizations.of(context);
    await _sub?.cancel();
    _sub = null;
    await _keepOn(false);
    setState(() {
      _logging = false;
      _saving = true;
    });
    if (_points.length < 2) {
      _snack(tr.vehCarTooShort);
      setState(() => _saving = false);
      return;
    }
    try {
      final r = await context.read<AppState>().api.vehCarModeTrip(List.of(_points));
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

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool busy;
  const _BigButton(
      {required this.icon,
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
