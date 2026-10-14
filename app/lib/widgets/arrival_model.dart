import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Safe-arrival ("I've arrived") ADVANCED model + pure client-side helpers that
/// MIRROR backend/core/logic/safety.py so the live countdown / status /
/// reminder / night-grace / routine logic agree offline.
///
/// SPEC v2.1 §21: ZERO Bangla glyphs live in this file — every localized string
/// now comes from the generated [AppLocalizations] getters (ARB-backed). The
/// runtime-keyed routine-day labels are resolved via [arrivalLabel] and the
/// two "{min}" countdown strings via [aMin]. Bangla DIGITS use [aNum].
///
/// REUSE, not duplication: the screen talks to the EXISTING Safe Journey /
/// safety APIs (safetyCheckinStart/Arrived, journeyRoutines, journeySos duress,
/// journey last_location) — this file only models state + copy.

bool aIsBn(BuildContext c) =>
    Localizations.localeOf(c).languageCode == 'bn';

/// Localized integer: Western digits, or Bangla digits via codepoints when bn.
String aNum(BuildContext c, int n) {
  if (!aIsBn(c)) return '$n';
  const zeroBn = 0x09E6; // Bengali digit zero
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Resolve a runtime-keyed arrival label (the routine-day chips feed this a
/// `kRoutineDayLabelKeys[i]` value) to its generated ARB getter. Mirrors the
/// photo module's `phLabel` dynamic-key dispatcher. Unknown keys fall through
/// to the raw key so the UI never crashes.
String arrivalLabel(BuildContext c, String key) {
  final t = AppLocalizations.of(c);
  switch (key) {
    case 'aDaySun':
      return t.aDaySun;
    case 'aDayMon':
      return t.aDayMon;
    case 'aDayTue':
      return t.aDayTue;
    case 'aDayWed':
      return t.aDayWed;
    case 'aDayThu':
      return t.aDayThu;
    case 'aDayFri':
      return t.aDayFri;
    case 'aDaySat':
      return t.aDaySat;
    default:
      return key;
  }
}

/// "{min}"-placeholder helper for the two countdown strings. Dispatches the
/// runtime key to its generated ARB getter, passing a locale-aware (Bangla)
/// digit string so the placeholder renders with native numerals.
String aMin(BuildContext c, String key, int min) {
  final t = AppLocalizations.of(c);
  final n = aNum(c, min);
  switch (key) {
    case 'aMinLate':
      return t.aMinLate(n);
    case 'aMinLeft':
    default:
      return t.aMinLeft(n);
  }
}

// --- weekday catalog (routine day picker) ----------------------------------
// Backend safety_journey.routine_due() keys days by 3-letter lowercase codes.
const List<String> kRoutineDayCodes = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
const List<String> kRoutineDayLabelKeys = [
  'aDaySun', 'aDayMon', 'aDayTue', 'aDayWed', 'aDayThu', 'aDayFri', 'aDaySat'
];

// --- check-in status state machine (mirror of safety.checkin_status) --------
enum ArrivalState { arrived, onTime, grace, overdue, unknown }

class ArrivalStatus {
  final ArrivalState state;
  final int minutes; // minutes-left (onTime) / minutes-into (grace/overdue)
  const ArrivalStatus(this.state, this.minutes);
}

/// Grace used by this check-in. Night-safety mode tightens it (mirror of
/// safety.effective_grace / NIGHT_GRACE_MINUTES = 7).
const int kArrivalGraceDefault = 15;
const int kNightGraceMinutes = 7;
const int kNightStartHour = 20;
const int kNightEndHour = 6;

bool aIsNightTime(DateTime dt) => dt.hour >= kNightStartHour || dt.hour < kNightEndHour;

int aEffectiveGrace(DateTime? eta, {bool nightMode = false, int grace = kArrivalGraceDefault}) {
  if (nightMode && eta != null && aIsNightTime(eta)) {
    return grace < kNightGraceMinutes ? grace : kNightGraceMinutes;
  }
  return grace;
}

/// Mirror of safety.checkin_status.
ArrivalStatus aCheckinStatus(DateTime? eta,
    {DateTime? now, bool arrived = false, int grace = kArrivalGraceDefault}) {
  if (arrived) return const ArrivalStatus(ArrivalState.arrived, 0);
  if (eta == null) return const ArrivalStatus(ArrivalState.unknown, 0);
  now ??= DateTime.now();
  final deltaMin = now.difference(eta).inMinutes;
  if (deltaMin < 0) return ArrivalStatus(ArrivalState.onTime, -deltaMin);
  if (deltaMin <= grace) return ArrivalStatus(ArrivalState.grace, deltaMin);
  return ArrivalStatus(ArrivalState.overdue, deltaMin);
}

/// Mirror of safety.checkin_reminder_due — pop a local "tap arrived" nudge once
/// inside the pre-arrival window. NEVER alerts anyone.
const int kRemindLeadDefault = 10;

bool aReminderDue(DateTime? eta,
    {DateTime? now, bool arrived = false, int leadMinutes = kRemindLeadDefault}) {
  if (arrived || eta == null) return false;
  now ??= DateTime.now();
  final start = eta.subtract(Duration(minutes: leadMinutes.clamp(0, 60)));
  return !now.isBefore(start) && !now.isAfter(eta);
}

/// Mirror of safety.countdown_parts — signed live countdown for the UI.
class ArrivalCountdown {
  final bool overdue;
  final int totalMinutes;
  const ArrivalCountdown(this.overdue, this.totalMinutes);
}

ArrivalCountdown aCountdown(DateTime? eta, {DateTime? now}) {
  if (eta == null) return const ArrivalCountdown(false, 0);
  now ??= DateTime.now();
  final secs = eta.difference(now).inSeconds;
  return ArrivalCountdown(secs < 0, (secs.abs() ~/ 60));
}
