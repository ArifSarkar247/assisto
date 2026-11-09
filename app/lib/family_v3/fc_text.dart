import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'fc_status.dart';

/// fcscreen — shared words + colours for Family Care v3 (cards, line, widget).
/// Every number goes through [notifLocalizeDigits] (Bangla digits in Bangla).

String fcDigits(BuildContext context, Object v) => notifLocalizeDigits(context, '$v');

String fcAgo(BuildContext context, DateTime? at, DateTime now) {
  final t = AppLocalizations.of(context);
  if (at == null) return '';
  final s = now.toUtc().difference(at.toUtc()).inSeconds;
  if (s < 60) return t.fc3AgoNow;
  if (s < 3600) return t.fc3AgoMin(fcDigits(context, s ~/ 60));
  if (s < 86400) return t.fc3AgoHour(fcDigits(context, s ~/ 3600));
  return t.fc3AgoDay(fcDigits(context, s ~/ 86400));
}

String fcClock(BuildContext context, Object? iso) {
  final d = fcParseTs(iso);
  if (d == null) return '';
  final tod = TimeOfDay.fromDateTime(d.toLocal());
  return fcDigits(context, MaterialLocalizations.of(context).formatTimeOfDay(tod));
}

String fcStateWord(AppLocalizations t, String state) => switch (state) {
      'ok' => t.fc3StateOk,
      'check' => t.fc3StateCheck,
      'sos' => t.fc3StateSos,
      'paused' => t.fc3StatePaused,
      _ => t.fc3StateStale,
    };

/// Plain-words reason (owner order e).
String fcReason(BuildContext context, String reason, Map? brain) {
  final t = AppLocalizations.of(context);
  final b = brain ?? const {};
  final batt = b['battery'];
  return switch (reason) {
    'never' => t.fc3ReasonNever,
    'battery_off' => t.fc3ReasonBatteryOff(fcDigits(context, batt ?? 0)),
    'no_internet' => t.fc3ReasonNoInternet,
    'background_killed' => t.fc3ReasonBgKilled,
    'clock' => t.fc3ReasonClock,
    'watch' => t.fc3ReasonWatch,
    'carecall_missed' => t.fc3ReasonCarecallMissed,
    'journey_overdue' => t.fc3ReasonJourneyOverdue,
    'battery_low' => t.fc3ReasonBatteryLow(fcDigits(context, batt ?? 0)),
    'paused' => t.fc3ReasonPaused,
    'sos' => t.fc3ReasonSos,
    'ok' => t.fc3LineOkSub,
    _ => t.fc3ReasonOther,
  };
}

/// Readable ink for a state on the current surface.
Color fcInk(BuildContext context, String state) {
  final scheme = Theme.of(context).colorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (state) {
    'ok' => dark ? Brand.green : Brand.successFill,
    'check' => Brand.warnInk(context),
    'sos' => dark ? CallInk.failure : Brand.dangerFill,
    _ => scheme.onSurfaceVariant,
  };
}

/// Dot fill colour (green OK, amber check, red SOS, gray no news / paused).
Color fcDot(BuildContext context, String state) => switch (state) {
      'ok' => Brand.success,
      'check' => Brand.warning,
      'sos' => Brand.danger,
      _ => Theme.of(context).colorScheme.outline,
    };

String fcPlace(BuildContext context, Map? brain) {
  final t = AppLocalizations.of(context);
  final b = brain ?? const {};
  final kind = '${b['place_kind'] ?? ''}';
  final label = '${b['place_label'] ?? ''}'.trim();
  final byKind = switch (kind) {
    'home' => t.fc3PlaceHome,
    'school' => t.fc3PlaceSchool,
    'office' => t.fc3PlaceOffice,
    _ => '',
  };
  return byKind.isNotEmpty ? byKind : label;
}

String fcInitial(String name) {
  final s = name.trim();
  return s.isEmpty ? '?' : String.fromCharCodes(s.runes.take(1)).toUpperCase();
}
