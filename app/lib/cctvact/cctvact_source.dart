// cctvact — CCTV GUARD V3 (owner order 9 Nov) parts D, E, F, G: every server
// call the act / report / sales-match / ask / automation screens make,
// behind one seam so widget tests and the screenshot gallery inject a fake.
// Shapes mirror backend/core/cctv_act_views.py.
import '../api.dart';

abstract class CctvActSource {
  /// PUT shop/sites/<id>/location {lat, lon} -> the thana answer.
  Future<Map<String, dynamic>> setLocation(int siteId, double lat, double lon);

  /// GET shop/sites/<id>/thana[?refresh=1]
  Future<Map<String, dynamic>> thana(int siteId, {bool refresh = false});

  /// POST shop/events/<id>/play {sound: siren|warn, confirm: true}
  Future<Map<String, dynamic>> play(int eventId, String sound, {int? cameraId});

  /// POST shop/events/<id>/mark {status: wrong, reason}
  Future<Map<String, dynamic>> markWrong(int eventId, String reason);

  /// Tuya / Smart Life automations.
  Future<Map<String, dynamic>> automations(int siteId, {bool refresh = false});
  Future<Map<String, dynamic>> saveRules(int siteId, List<Map<String, dynamic>> rules);
  Future<Map<String, dynamic>> link(int siteId, Map<String, dynamic> body);
  Future<Map<String, dynamic>> unlink(int siteId);
  Future<Map<String, dynamic>> testDevice(int siteId, String deviceId);
  Future<Map<String, dynamic>> lock(int siteId, String pendingId);

  /// GET shop/sites/<id>/closing-report[?date=]; POST {use, push}.
  Future<Map<String, dynamic>> closingReport(int siteId, {String? date});
  Future<Map<String, dynamic>> saveReportCfg(int siteId, Map<String, dynamic> body);

  /// POS webhook key (secret only in the create answer) + CSV + match.
  Future<Map<String, dynamic>> posKey(int siteId);
  Future<Map<String, dynamic>> createPosKey(int siteId, String partner);
  Future<Map<String, dynamic>> revokePosKey(int siteId);
  Future<Map<String, dynamic>> importCsv(int siteId, String csv);
  Future<Map<String, dynamic>> salesMatch(int siteId, {String? date});

  /// POST shop/sites/<id>/ask {q}
  Future<Map<String, dynamic>> ask(int siteId, String q);
}

class ApiCctvActSource implements CctvActSource {
  final ApiClient api;
  ApiCctvActSource(this.api);

  String _s(int id) => '/shop/sites/$id';

  @override
  Future<Map<String, dynamic>> setLocation(int siteId, double lat, double lon) =>
      api.postJson('${_s(siteId)}/location', {'lat': lat, 'lon': lon});

  @override
  Future<Map<String, dynamic>> thana(int siteId, {bool refresh = false}) =>
      api.getJson('${_s(siteId)}/thana${refresh ? '?refresh=1' : ''}');

  @override
  Future<Map<String, dynamic>> play(int eventId, String sound, {int? cameraId}) =>
      api.postJson('/shop/events/$eventId/play', {
        'sound': sound,
        'confirm': true,
        if (cameraId != null) 'camera_id': cameraId,
      });

  @override
  Future<Map<String, dynamic>> markWrong(int eventId, String reason) =>
      api.postJson('/shop/events/$eventId/mark', {'status': 'wrong', 'reason': reason});

  @override
  Future<Map<String, dynamic>> automations(int siteId, {bool refresh = false}) =>
      api.getJson('${_s(siteId)}/automations${refresh ? '?refresh=1' : ''}');

  @override
  Future<Map<String, dynamic>> saveRules(int siteId, List<Map<String, dynamic>> rules) =>
      api.postJson('${_s(siteId)}/automations', {'rules': rules});

  @override
  Future<Map<String, dynamic>> link(int siteId, Map<String, dynamic> body) =>
      api.postJson('${_s(siteId)}/automations/link', body);

  @override
  Future<Map<String, dynamic>> unlink(int siteId) =>
      api.deleteJson('${_s(siteId)}/automations/link');

  @override
  Future<Map<String, dynamic>> testDevice(int siteId, String deviceId) =>
      api.postJson('${_s(siteId)}/automations/test', {'device_id': deviceId});

  @override
  Future<Map<String, dynamic>> lock(int siteId, String pendingId) => api.postJson(
      '${_s(siteId)}/automations/lock', {'pending_id': pendingId, 'confirm': true});

  @override
  Future<Map<String, dynamic>> closingReport(int siteId, {String? date}) =>
      api.getJson('${_s(siteId)}/closing-report${date != null ? '?date=$date' : ''}');

  @override
  Future<Map<String, dynamic>> saveReportCfg(int siteId, Map<String, dynamic> body) =>
      api.postJson('${_s(siteId)}/closing-report', body);

  @override
  Future<Map<String, dynamic>> posKey(int siteId) => api.getJson('${_s(siteId)}/pos-key');

  @override
  Future<Map<String, dynamic>> createPosKey(int siteId, String partner) =>
      api.postJson('${_s(siteId)}/pos-key', {'partner': partner});

  @override
  Future<Map<String, dynamic>> revokePosKey(int siteId) =>
      api.deleteJson('${_s(siteId)}/pos-key');

  @override
  Future<Map<String, dynamic>> importCsv(int siteId, String csv) =>
      api.postJson('${_s(siteId)}/pos-csv', {'csv': csv});

  @override
  Future<Map<String, dynamic>> salesMatch(int siteId, {String? date}) =>
      api.getJson('${_s(siteId)}/sales-match${date != null ? '?date=$date' : ''}');

  @override
  Future<Map<String, dynamic>> ask(int siteId, String q) =>
      api.postJson('${_s(siteId)}/ask', {'q': q});
}
