import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// journey2 — small shared helpers for the Safe Journey screens: Bangla
/// digits, straight-line distance, the HONEST rough trip time (mirror of
/// backend core/logic/journey_dest.py — never called a traffic ETA), ride
/// labels in one language, and saved-place kinds.

bool _bn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

/// Digits in the UI's script (codepoints only, no Bangla literal in source).
String jDigits(BuildContext c, Object v) {
  final s = '$v';
  if (!_bn(c)) return s;
  final b = StringBuffer();
  for (final cu in s.codeUnits) {
    b.writeCharCode(cu >= 0x30 && cu <= 0x39 ? 0x09E6 + (cu - 0x30) : cu);
  }
  return b.toString();
}

/// "2.4" (km, one decimal) in the UI's digits.
String jKm(BuildContext c, num metres) => jDigits(c, (metres / 1000).toStringAsFixed(1));

/// Great-circle distance in metres.
double jDistanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dp = rad(lat2 - lat1), dl = rad(lng2 - lng1);
  final a = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Road factor and typical door-to-door city speeds (km/h) — same table as
/// the server. Rough on purpose: the app labels it "not live traffic".
const double kRoadFactor = 1.35;
const Map<String, double> kModeKmh = {
  'walk': 4.5, 'rickshaw': 7, 'bus': 10, 'cng': 12, 'car': 12, 'bike': 16, 'ride': 12,
};

/// Rough minutes for a straight-line distance, rounded UP to 5 (never
/// sooner than true), at least 5.
int jRoughMinutes(double metres, String? mode) {
  final kmh = kModeKmh[mode ?? ''] ?? 12;
  final mins = metres * kRoadFactor / 1000 / kmh * 60;
  final up = (mins / 5).ceil() * 5;
  return math.max(5, up);
}

/// Ride modes the server accepts (core.logic.journey_dest.MODES).
const kJourneyModes = ['cng', 'bike', 'car', 'rickshaw', 'bus', 'walk', 'ride'];
const kRideApps = ['pathao', 'uber', 'obhai', 'indrive', 'other'];

String jModeLabel(AppLocalizations t, String? mode) => switch (mode) {
      'cng' => t.journeyModeCng,
      'bike' => t.j2ModeBike,
      'car' => t.journeyModeCar,
      'rickshaw' => t.journeyModeRickshaw,
      'bus' => t.journeyModeBus,
      'walk' => t.journeyModeWalk,
      'ride' => t.j2ModeRide,
      _ => '',
    };

String jAppLabel(AppLocalizations t, String? app) => switch (app) {
      'pathao' => t.j2AppPathao,
      'uber' => t.j2AppUber,
      'obhai' => t.j2AppObhai,
      'indrive' => t.j2AppIndrive,
      'other' => t.j2AppOther,
      _ => '',
    };

/// "CNG · Pathao · DHAKA METRO THA 11-2233" (labels in the UI language; the
/// plate stays exactly as typed — it is what is painted on the vehicle).
String jRideLine(AppLocalizations t, Map? v) {
  if (v == null) return '';
  final parts = [
    jModeLabel(t, v['mode']?.toString()),
    if (v['app'] != 'other') jAppLabel(t, v['app']?.toString()),
    (v['plate'] ?? '').toString(),
  ].where((e) => e.isNotEmpty);
  return parts.join(' · ');
}

/// Saved-place kinds (core.logic.journey_dest.PLACE_KINDS).
const kPlaceKinds = ['home', 'school', 'office'];

String jPlaceKind(Map p) {
  final k = '${p['kind'] ?? p['label'] ?? ''}'.toLowerCase();
  return const ['home', 'school', 'office'].contains(k) ? k : 'other';
}

String jKindLabel(AppLocalizations t, String kind) => switch (kind) {
      'home' => t.j2PlaceHome,
      'school' => t.j2PlaceSchool,
      'office' => t.j2PlaceOffice,
      _ => t.j2PlaceOther,
    };

/// The chip text for a saved place: its own name when it has one that is not
/// just the kind, else the localized kind ("Home").
String jPlaceLabel(AppLocalizations t, Map p) {
  final kind = jPlaceKind(p);
  final name = '${p['name'] ?? ''}'.trim();
  if (kind != 'other') return jKindLabel(t, kind);
  if (name.isNotEmpty) return name;
  final label = '${p['label'] ?? ''}'.trim();
  return label.isNotEmpty ? label : t.j2PlaceOther;
}

IconData jPlaceIcon(String kind) => switch (kind) {
      'home' => Icons.home_rounded,
      'school' => Icons.school_rounded,
      'office' => Icons.work_rounded,
      _ => Icons.place_rounded,
    };
