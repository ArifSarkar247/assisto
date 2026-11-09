import 'api.dart';

/// messv2 — MESS AND BACHELOR V2 API (backend core/views_mess.py).
///
/// An EXTENSION on [ApiClient] built only on the public getJson / postJson /
/// getBytes helpers (no api.dart edit). Money crosses the wire as INTEGER
/// POISHA; meals as on/off per slot (b breakfast, l lunch, d dinner) + guest
/// counts (gb, gl, gd). Every write accepts a `client_id` so an offline
/// re-send (see MessOutbox) is never counted twice.
extension MessV2Api on ApiClient {
  /// {messes:[{id,name,status,my_role,can_manage,...}], can_create, premium,
  /// free_limit, legacy_available}
  Future<Map<String, dynamic>> messList() => getJson('/mess/v2');

  Future<Map<String, dynamic>> messCreate(Map<String, dynamic> body) =>
      postJson('/mess/v2', body);

  /// Everything one screen needs: {mess, members, month, months_closed,
  /// summary, entries, my_days, today, premium}.
  Future<Map<String, dynamic>> messDetail(int id, {String? month}) =>
      getJson(month == null ? '/mess/v2/$id' : '/mess/v2/$id?month=$month');

  Future<Map<String, dynamic>> messEdit(int id, Map<String, dynamic> body) =>
      postJson('/mess/v2/$id/edit', body);

  /// {results:[{circle_member_id,user_id,name,relation,in_mess}], unlinked:[]}
  Future<Map<String, dynamic>> messCirclePick(int id) =>
      getJson('/mess/v2/$id/circle-pick');

  Future<Map<String, dynamic>> messAddMember(int id, int circleMemberId,
          {int? linkMemberId}) =>
      postJson('/mess/v2/$id/members', {
        'circle_member_id': circleMemberId,
        if (linkMemberId != null) 'link_member_id': linkMemberId,
      });

  /// action: remove | make_admin | remove_admin | make_manager | seat_share
  Future<Map<String, dynamic>> messMemberAction(int id, int memberId, String action,
          {int? value}) =>
      postJson('/mess/v2/$id/members/$memberId',
          {'action': action, if (value != null) 'value': value});

  Future<Map<String, dynamic>> messReport(int id, {String? month}) =>
      getJson(month == null ? '/mess/v2/$id/report' : '/mess/v2/$id/report?month=$month');

  Future<List<int>> messReportPdf(int id, {String? month}) => getBytes(month == null
      ? '/mess/v2/$id/report?pdf=1'
      : '/mess/v2/$id/report?pdf=1&month=$month');

  Future<Map<String, dynamic>> messHistory(int id) => getJson('/mess/v2/$id/history');

  Future<Map<String, dynamic>> messClose(int id) => postJson('/mess/v2/$id/close', {});

  Future<Map<String, dynamic>> messRemind(int id) => postJson('/mess/v2/$id/remind', {});

  Future<Map<String, dynamic>> messCloseMess(int id) =>
      postJson('/mess/v2/$id/close-mess', {});

  Future<Map<String, dynamic>> messImportLegacy() =>
      postJson('/mess/v2/import-legacy', {});

  /// {card:{meals_today, bazar_today_display, not_set_tomorrow:[names],
  /// bazar_turn_today, mess_id, name}} or {card:null}.
  Future<Map<String, dynamic>> messByGroup(int groupId) =>
      getJson('/mess/v2/by-group/$groupId');

  /// Generic write used by the offline outbox: [path] is relative to
  /// /mess/v2/<id>/ (meals, meals/off, entries, entries/<eid>).
  Future<Map<String, dynamic>> messWrite(String path, Map<String, dynamic> body) =>
      postJson(path, body);
}
