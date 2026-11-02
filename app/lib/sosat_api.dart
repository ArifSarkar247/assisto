import 'api.dart';

/// sosat — SOS escalation ladder + experimental fall "I'm OK" (backend
/// core/family_alerts.ladder, core/sos_triggers). An extension on ApiClient
/// (public getJson/postJson only) so the shared api.dart stays untouched.
///   GET  /family/sos/ladder   -> {stage, recipients:[{name,status,received,seen,rerung}],
///                                total, received, seen, age_s, kind}
///   GET  /family/fall/pending -> {pending: {client_id, at, seconds_left} | null}
///   POST /family/fall/ok {client_id?}
extension SosatApi on ApiClient {
  Future<Map<String, dynamic>> sosLadder() => getJson('/family/sos/ladder');

  Future<Map<String, dynamic>> fallPending() => getJson('/family/fall/pending');

  Future<Map<String, dynamic>> fallOk({String? clientId}) =>
      postJson('/family/fall/ok', {if (clientId != null) 'client_id': clientId});
}
