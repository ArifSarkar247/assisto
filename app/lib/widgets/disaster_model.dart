import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// DISASTER ALERTS (ADVANCED) model + pure client-side helpers that MIRROR
/// backend/core/logic/disaster.py so severity bands, signal/level mapping and
/// family-area matching agree OFFLINE.
///
/// SPEC v2.1 §21: ZERO Bangla glyphs live in this file — every localized
/// string comes from the generated [AppLocalizations] getters (ARB-backed) and
/// is dispatched here by a runtime key (mirrors the photo / arrival modules).
///
/// OFFICIAL-SOURCE-ONLY + NEVER-FABRICATE: this file does NOT contain any
/// active-warning data. Live warnings only ever come from the server's official
/// feed; with no feed key the screen shows the "connect official feed" state
/// plus clearly-flagged SAMPLE items (sample=true / isLive=false). The two
/// hotlines 999 and 1090 are constants below.

const String kHotlineEmergency = '999';
const String kHotlineDisaster = '1090';

// --- disaster kinds (mirror disaster.KINDS) --------------------------------
const List<String> kDisasterKinds = ['cyclone', 'flood', 'heat', 'earthquake'];

// --- severity bands (mirror disaster._SEV_RANK) ----------------------------
enum DisasterSev { info, advisory, warning, severe, extreme }

DisasterSev dSevFromKey(String? key) {
  switch (key) {
    case 'advisory':
      return DisasterSev.advisory;
    case 'warning':
      return DisasterSev.warning;
    case 'severe':
      return DisasterSev.severe;
    case 'extreme':
      return DisasterSev.extreme;
    default:
      return DisasterSev.info;
  }
}

int dSevRank(DisasterSev s) => s.index;

/// Severity tint — distinct hue AND always paired with a label/icon elsewhere
/// (never colour alone), so it stays WCAG-honest.
Color dSevColor(DisasterSev s) {
  switch (s) {
    case DisasterSev.info:
      return Brand.blue;
    case DisasterSev.advisory:
      return const Color(0xFF0E9FB8); // teal
    case DisasterSev.warning:
      return Brand.warning;
    case DisasterSev.severe:
      return const Color(0xFFE56A1C); // deep orange
    case DisasterSev.extreme:
      return Brand.danger;
  }
}

IconData dKindIcon(String kind) {
  switch (kind) {
    case 'cyclone':
      return Icons.cyclone_rounded;
    case 'flood':
      return Icons.water_drop_rounded;
    case 'heat':
      return Icons.thermostat_rounded;
    case 'earthquake':
      return Icons.vibration_rounded;
    default:
      return Icons.warning_amber_rounded;
  }
}

// --- client mirrors of disaster.py classifiers (offline agreement) ---------

/// Mirror of disaster.cyclone_signal_severity (BMD signal 1-11).
DisasterSev dCycloneSeverity(int? signal) {
  if (signal == null || signal < 1 || signal > 11) return DisasterSev.info;
  if (signal <= 3) return DisasterSev.advisory;
  if (signal <= 6) return DisasterSev.warning;
  if (signal <= 9) return DisasterSev.severe;
  return DisasterSev.extreme;
}

/// Mirror of disaster.flood_level_severity (metres above FFWC danger level).
DisasterSev dFloodSeverity(double? aboveDangerM) {
  if (aboveDangerM == null || aboveDangerM < 0) return DisasterSev.info;
  if (aboveDangerM < 0.5) return DisasterSev.advisory;
  if (aboveDangerM < 1.0) return DisasterSev.warning;
  if (aboveDangerM < 1.5) return DisasterSev.severe;
  return DisasterSev.extreme;
}

/// Mirror of disaster.heat_severity (BMD heatwave bands, °C).
DisasterSev dHeatSeverity(double? tempC) {
  if (tempC == null || tempC < 36) return DisasterSev.info;
  if (tempC < 38) return DisasterSev.advisory;
  if (tempC < 40) return DisasterSev.warning;
  if (tempC < 42) return DisasterSev.severe;
  return DisasterSev.extreme;
}

/// Mirror of disaster.area_matches — case-insensitive substring both ways.
bool dAreaMatches(String? memberArea, String? warningArea) {
  final m = (memberArea ?? '').trim().toLowerCase();
  final w = (warningArea ?? '').trim().toLowerCase();
  if (m.isEmpty || w.isEmpty) return false;
  return w.contains(m) || m.contains(w);
}

// --- ARB-keyed label dispatchers (zero Bangla glyphs here) -----------------

bool dIsBn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

/// Localized integer with Bangla digits (codepoints) when the locale is bn.
String dNum(BuildContext c, num n) {
  if (!dIsBn(c)) return '$n';
  const zeroBn = 0x09E6;
  final buf = StringBuffer();
  final s = n.toString();
  for (final r in s.runes) {
    if (r >= 0x30 && r <= 0x39) {
      buf.writeCharCode(zeroBn + (r - 0x30));
    } else {
      buf.writeCharCode(r); // '.', '-' pass through
    }
  }
  return buf.toString();
}

/// Human severity label (ARB-backed).
String dSevLabel(BuildContext c, DisasterSev s) {
  final t = AppLocalizations.of(c);
  switch (s) {
    case DisasterSev.info:
      return t.disSevInfo;
    case DisasterSev.advisory:
      return t.disSevAdvisory;
    case DisasterSev.warning:
      return t.disSevWarning;
    case DisasterSev.severe:
      return t.disSevSevere;
    case DisasterSev.extreme:
      return t.disSevExtreme;
  }
}

/// Human disaster-kind label (ARB-backed).
String dKindLabel(BuildContext c, String kind) {
  final t = AppLocalizations.of(c);
  switch (kind) {
    case 'cyclone':
      return t.disKindCyclone;
    case 'flood':
      return t.disKindFlood;
    case 'heat':
      return t.disKindHeat;
    case 'earthquake':
      return t.disKindEarthquake;
    default:
      return kind;
  }
}

/// A fully-parsed warning the UI renders (built from the server feed OR from the
/// clearly-flagged sample set — `isLive`/`sample` keep them honest).
class DisasterWarning {
  final String kind;
  final String area;
  final String title;
  final String text;
  final DisasterSev severity;
  final String source;
  final bool isLive;
  final bool sample;

  /// kind-specific metric (for the chip): signal no. / m above DL / °C.
  final int? signal;
  final double? aboveDangerM;
  final double? tempC;

  const DisasterWarning({
    required this.kind,
    required this.area,
    required this.title,
    required this.text,
    required this.severity,
    required this.source,
    required this.isLive,
    required this.sample,
    this.signal,
    this.aboveDangerM,
    this.tempC,
  });

  factory DisasterWarning.fromMap(Map<String, dynamic> m) {
    final kind = (m['kind'] ?? '').toString();
    final sev = dSevFromKey(m['severity']?.toString());
    double? asD(dynamic v) => v == null ? null : double.tryParse(v.toString());
    int? asI(dynamic v) => v == null ? null : int.tryParse(v.toString());
    return DisasterWarning(
      kind: kind,
      area: (m['area'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      text: (m['text'] ?? '').toString(),
      severity: sev,
      source: (m['source'] ?? '').toString(),
      isLive: m['is_live'] == true,
      sample: m['sample'] == true,
      signal: asI(m['signal']),
      aboveDangerM: asD(m['above_danger_m']),
      tempC: asD(m['temp_c']),
    );
  }

  /// The small metric chip text (signal no. / m above DL / °C), ARB-backed.
  String? metricChip(BuildContext c) {
    final t = AppLocalizations.of(c);
    if (kind == 'cyclone' && signal != null) {
      return t.disChipSignal(dNum(c, signal!));
    }
    if (kind == 'flood' && aboveDangerM != null) {
      return t.disChipFlood(dNum(c, aboveDangerM!));
    }
    if (kind == 'heat' && tempC != null) {
      return t.disChipHeat(dNum(c, tempC!));
    }
    return null;
  }
}
