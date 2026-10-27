import 'api.dart';

/// family100 — family alerts delivered by SERVER push (core/family_alerts.py).
///
/// An extension on ApiClient (public getJson/postJson only) so the shared
/// api.dart stays untouched. Paths are authoritative:
///   POST /family/sos {lat?, lng?, source, client_id}
///   POST /family/sos/resolve
///   GET  /family/alerts            -> {received:[...], sent:[...], unseen}
///   POST /family/alerts/<id>/seen
///   POST /family/alerts/received {ids:[...]}
extension FamilyAlertsApi on ApiClient {
  /// SOS from any surface. [clientId] makes a retry the SAME event (the
  /// server never rings a phone twice for one press). Returns
  /// {recipients, sent, no_device, push_off, held, failed, duplicate}.
  Future<Map<String, dynamic>> familySos({
    double? lat,
    double? lng,
    required String source,
    required String clientId,
  }) =>
      postJson('/family/sos', {
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        'source': source,
        'client_id': clientId,
      });

  /// "I'm safe now" — tells everyone who got the SOS.
  Future<Map<String, dynamic>> familySosResolve() =>
      postJson('/family/sos/resolve');

  Future<Map<String, dynamic>> familyAlerts() => getJson('/family/alerts');

  Future<Map<String, dynamic>> familyAlertSeen(int id) =>
      postJson('/family/alerts/$id/seen');
}

/// A fresh id for one SOS press (time + a little entropy; no plugin).
String newSosClientId() {
  final n = DateTime.now().microsecondsSinceEpoch;
  return 'sos-$n-${(n * 7919) % 100003}';
}
