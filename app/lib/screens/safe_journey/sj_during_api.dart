import 'package:flutter/material.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/journey_ride.dart' show jDigits;

/// sjduring — Safe Journey V2 DURING the trip: the server calls
/// (backend core/views_sjduring.py) and the shared labels for the states.
///
/// RULE (owner 9 Nov): late does not mean danger and early does not mean
/// safe. The traveller is asked PRIVATELY first; the family hears only when
/// there is no answer; red only on a strong signal.
extension SjDuringApi on ApiClient {
  /// Traveller: state + the private ask + a PIN wait. GET /journey/<id>/during
  Future<Map<String, dynamic>> sjDuring(int id) => getJson('/journey/$id/during');

  /// Traveller: one of the private screen's buttons.
  /// action = extend | share | ok | danger.
  Future<Map<String, dynamic>> sjAnswer(int id, String action, {int? minutes}) =>
      postJson('/journey/$id/answer', {
        'action': action,
        if (minutes != null) 'minutes': minutes,
      });

  /// Traveller: the PIN on arrival. Never throws on wrong / locked — the
  /// body carries `pin` (wrong | locked | required | not_set) and `_status`.
  Future<Map<String, dynamic>> sjArrivePin(int id, String pin) =>
      postJsonRaw('/journey/$id/arrive-pin', {'pin': pin});

  /// Traveller: the 30 s clip after a danger PIN (quiet, best-effort).
  Future<Map<String, dynamic>> sjDangerAudioUpload(int id, String b64) =>
      postJsonRaw('/journey/$id/danger-audio', {'audio_b64': b64});

  /// Watcher: the 30 s clip.
  Future<Map<String, dynamic>> sjDangerAudio(int id) => getJson('/journey/$id/danger-audio');

  Future<Map<String, dynamic>> sjPinPref() => getJson('/journey/arrive-pin-pref');
  Future<Map<String, dynamic>> sjSetPinPref(bool always) =>
      postJson('/journey/arrive-pin-pref', {'always': always});

  /// Watcher board: {count, active:[...], finished:[...]}. Also used by the
  /// Family screen (count of journeys on the way).
  Future<Map<String, dynamic>> sjWatchBoard() => getJson('/journey/watch-board');
}

/// One state's label, colour and icon (traveller chip + watcher card).
({String label, Color color, IconData icon}) sjStateLook(
    BuildContext context, AppLocalizations t, Map<String, dynamic> d) {
  final cs = Theme.of(context).colorScheme;
  final mins = (d['state_minutes'] as num?)?.toInt() ?? 0;
  final batt = (d['battery'] as num?)?.toInt();
  switch ('${d['state'] ?? ''}') {
    case 'slow':
      return (label: t.sjdStSlow, color: Brand.warnInk(context), icon: Icons.traffic_rounded);
    case 'stopped':
      return (
        label: t.sjdStStopped(jDigits(context, mins)),
        color: Brand.warnInk(context),
        icon: Icons.pause_circle_rounded
      );
    case 'off_route':
      return (label: t.sjdStOffRoute, color: Brand.warnInk(context), icon: Icons.alt_route_rounded);
    case 'nearly':
      return (label: t.sjdStNearly, color: Brand.successFill, icon: Icons.near_me_rounded);
    case 'phone_off':
      return (
        label: batt == null ? t.sjdStPhoneOff : t.sjdStPhoneOffBatt(jDigits(context, batt)),
        color: cs.onSurfaceVariant,
        icon: Icons.phonelink_erase_rounded
      );
    case 'arrived':
      return (label: t.sjdStArrived, color: Brand.successFill, icon: Icons.check_circle_rounded);
    default:
      return (label: t.sjdStMoving, color: Brand.successFill, icon: Icons.navigation_rounded);
  }
}

/// Honest reason line for "Phone off" ('' when not off).
String sjPhoneOffWhy(AppLocalizations t, Map<String, dynamic> d) {
  if (d['state'] != 'phone_off') return '';
  switch ('${d['why'] ?? ''}') {
    case 'battery':
      return t.sjdWhyBattery;
    case 'killed':
      return t.sjdWhyKilled;
    default:
      return t.sjdWhyUnknown;
  }
}

/// Icon by travel mode (watcher cards).
IconData sjModeIcon(String mode) {
  switch (mode) {
    case 'walk':
      return Icons.directions_walk_rounded;
    case 'bike':
      return Icons.two_wheeler_rounded;
    case 'car':
    case 'ride':
      return Icons.directions_car_rounded;
    case 'cng':
    case 'rickshaw':
      return Icons.electric_rickshaw_rounded;
    case 'train':
      return Icons.train_rounded;
    case 'metro':
      return Icons.subway_rounded;
    case 'launch':
      return Icons.directions_boat_rounded;
    case 'local_bus':
    case 'long_bus':
    case 'bus':
      return Icons.directions_bus_rounded;
    default:
      return Icons.navigation_rounded;
  }
}

/// "10:40" in the UI's digits.
String sjClock(BuildContext context, String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  if (d == null) return '';
  return jDigits(context, TimeOfDay.fromDateTime(d).format(context));
}
