import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// qjourney: one BOUNDED location read for every SOS surface.
///
/// Before this, the journey SOS awaited `getCurrentPosition()` with no time
/// limit (indoors / no GPS fix = the SOS never left the phone), and the
/// Emergency SOS could wait on an unanswered Android permission prompt.
/// An SOS must always go out: we wait at most [fixTimeout] for a fresh fix,
/// fall back to the phone's last known position, and give up on an
/// unanswered permission prompt after [promptTimeout] — the alert is then
/// sent without location (the family still gets it at once).
typedef SosPosition = ({double lat, double lng});

/// Tests: replace the platform calls.
Future<SosPosition?> Function()? sosLocationOverride;

Future<SosPosition?> sosQuickPosition({
  Duration fixTimeout = const Duration(seconds: 6),
  Duration promptTimeout = const Duration(seconds: 10),
}) async {
  if (sosLocationOverride != null) return sosLocationOverride!();
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission()
          .timeout(promptTimeout, onTimeout: () => LocationPermission.denied);
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }
    try {
      final p = await Geolocator.getCurrentPosition().timeout(fixTimeout);
      return (lat: p.latitude, lng: p.longitude);
    } catch (_) {
      // no fresh fix in time (indoors, GPS cold) -> the last known one
      final last = await Geolocator.getLastKnownPosition()
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      return last == null ? null : (lat: last.latitude, lng: last.longitude);
    }
  } catch (_) {
    return null; // best-effort: the SOS goes out without location
  }
}
