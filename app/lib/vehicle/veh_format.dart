import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';

bool vehIsBn(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'bn';

/// Bengali digit zero (U+09E6); digits 1-9 follow consecutively.
const _bnZero = 0x09E6;

/// Number with locale digits (Bangla digits in bn).
String vehNumStr(BuildContext context, num v, {int decimals = 0}) {
  final s = v.toStringAsFixed(decimals);
  if (!vehIsBn(context)) return s;
  return s.split('').map((c) {
    final d = int.tryParse(c);
    return d == null ? c : String.fromCharCode(_bnZero + d);
  }).join();
}

String vehTime(BuildContext context, DateTime? t) {
  if (t == null) return '';
  return DateFormat('h:mm a', Localizations.localeOf(context).languageCode)
      .format(t.toLocal());
}

String vehDateTime(BuildContext context, DateTime? t) {
  if (t == null) return '';
  return DateFormat('d MMM, h:mm a', Localizations.localeOf(context).languageCode)
      .format(t.toLocal());
}

DateTime? vehDate(dynamic v) => v == null ? null : DateTime.tryParse('$v');

/// "1 h 20 min" (localized via vehDurHm / vehDurM)
String vehDuration(BuildContext context, AppLocalizations tr, int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) {
    return tr.vehDurHm(vehNumStr(context, h), vehNumStr(context, m));
  }
  return tr.vehDurM(vehNumStr(context, m));
}

/// How long ago, for "last seen".
String vehAgo(BuildContext context, AppLocalizations tr, DateTime? t) {
  if (t == null) return tr.vehNever;
  final s = DateTime.now().difference(t.toLocal()).inSeconds;
  if (s < 60) return tr.vehJustNow;
  if (s < 3600) return tr.vehMinAgo(vehNumStr(context, s ~/ 60));
  if (s < 86400) return tr.vehHourAgo(vehNumStr(context, s ~/ 3600));
  return vehDateTime(context, t);
}

/// Localized text for a server `reason` code (ApiException.message).
String vehReasonText(AppLocalizations tr, Object e) {
  final code = e is ApiException ? e.message : '$e';
  switch (code) {
    case 'moving':
      return tr.vehErrMoving;
    case 'stale_fix':
      return tr.vehErrStaleFix;
    case 'no_fix':
      return tr.vehErrNoFix;
    case 'offline':
      return tr.vehErrOffline;
    case 'not_paired':
      return tr.vehErrNotPaired;
    case 'busy':
      return tr.vehErrBusy;
    case 'bad_pin':
      return tr.vehErrBadPin;
    case 'no_pin':
      return tr.vehErrNoPin;
    case 'locked':
      return tr.vehErrLocked;
    case 'bad_imei':
      return tr.vehErrBadImei;
    case 'imei_taken':
      return tr.vehErrImeiTaken;
    case 'no_credits':
      return tr.vehErrNoCredits;
    case 'business_only':
      return tr.vehErrBusinessOnly;
    case 'approver_required':
      return tr.vehErrApproverRequired;
    case 'forbidden':
    case 'not_found':
      return tr.vehErrNoAccess;
    // veh100
    case 'few_fixes':
      return tr.v100ErrFewFixes;
    case 'feature_off':
      return tr.v100ErrCutOff;
    case 'confirm_timeout':
      return tr.v100ErrConfirmTimeout;
    case 'bad_confirm':
    case 'not_pending':
      return tr.v100ErrConfirmFailed;
    case 'too_many_links':
      return tr.v100ErrTooManyLinks;
    case 'bad_geofence':
      return tr.v100ErrBadFence;
    case 'bad_driver':
      return tr.v100ErrBadDriver;
    case 'bad_odometer':
      return tr.v100ErrBadOdometer;
    default:
      return tr.vehErrGeneric;
  }
}
