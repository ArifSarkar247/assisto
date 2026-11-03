import 'dart:async';

import 'package:geocoding/geocoding.dart' as geo;

import '../api.dart';
import 'maps_api.dart';

/// mapscost — an address for a point, cheapest first (owner order 3 Nov):
///  1. the phone's own Android Geocoder (free, no Google bill);
///  2. only when that gives nothing: our server (/maps/reverse) — it answers
///     from its ~50 m cache before paying, and under daily caps;
///  3. otherwise the coordinates text (never an invented address).
/// Lazy: the platform Geocoder is touched only when this is called, every
/// call is try/catch + timeout, so a phone without a Geocoder just falls
/// through. NEVER used by SOS.
typedef PhoneGeocoder = Future<String?> Function(double lat, double lng, String lang);

class ResolvedAddress {
  final String text; // address, or the coordinates text
  final String source; // phone | server | coords
  const ResolvedAddress(this.text, this.source);
  bool get isAddress => source != 'coords';
}

class AddressResolver {
  /// Tests replace this; null = the real Android Geocoder.
  static PhoneGeocoder? debugPhone;
  static const phoneTimeout = Duration(seconds: 4);

  static Future<String?> _androidGeocoder(double lat, double lng, String lang) async {
    await geo.setLocaleIdentifier(lang == 'bn' ? 'bn_BD' : 'en_US');
    final rows = await geo.placemarkFromCoordinates(lat, lng);
    if (rows.isEmpty) return null;
    final p = rows.first;
    final parts = <String>[];
    for (final s in [p.name, p.street, p.subLocality, p.locality]) {
      final v = (s ?? '').trim();
      if (v.isNotEmpty && !parts.contains(v) && !RegExp(r'^[\d\s+,.-]+$').hasMatch(v)) {
        parts.add(v);
      }
    }
    return parts.isEmpty ? null : parts.take(3).join(', ');
  }

  static Future<ResolvedAddress> resolve(ApiClient api, double lat, double lng,
      {String lang = 'bn'}) async {
    try {
      final phone = await (debugPhone ?? _androidGeocoder)(lat, lng, lang)
          .timeout(phoneTimeout);
      if (phone != null && phone.trim().isNotEmpty) {
        return ResolvedAddress(phone.trim(), 'phone');
      }
    } catch (_) {
      // no Geocoder on this phone / no network for it -> ask our server
    }
    try {
      final r = await api.mapsReverse(lat, lng);
      final a = '${r['address'] ?? ''}'.trim();
      if (a.isNotEmpty && (r['state'] == 'ok' || r['state'] == 'cache')) {
        return ResolvedAddress(a, 'server');
      }
    } catch (_) {
      // offline / capped -> coordinates
    }
    return ResolvedAddress(mapsCoordsText(lat, lng), 'coords');
  }
}
