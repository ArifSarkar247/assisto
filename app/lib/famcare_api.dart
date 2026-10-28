import 'api.dart';
import 'widgets/loading_gate.dart';

/// famcare (owner review 28 Oct) — Family Care calls, built only on the
/// generic getJson / postJson helpers (no api.dart edit). Server side:
/// backend/core/famcare.py + views_famcare.py.
///
///   GET  /family/limits                {limit, used, left, safety_free}
///   GET  /family/circle-pick           my accepted Circle + family_id link
///   POST /family/from-circle           {circle_member_id}  (one tap)
///   GET  /family/reminders             assigned_by_me / assigned_to_me
///   POST /family/reminders             {member_id, title, due_at?, notes?}
///   POST /family/reminders/<id>/cancel
///   GET  /family/shopping              {lists:[{owner_id, mine, items}]}
///   POST /family/shopping              {text, qty?, owner_id?}
///   POST /family/shopping/<id>/toggle | /delete,  /family/shopping/clear-done
///   GET  /family/docs                  shared_by_me / shared_with_me
///   POST /family/docs                  {document_id, member_ids}
///   POST /family/docs/<id>/revoke,  GET /family/docs/<id>/open
extension FamCareApi on ApiClient {
  Future<Map<String, dynamic>> famLimits() => loadGuard(getJson('/family/limits'));

  Future<Map<String, dynamic>> famCirclePick() =>
      loadGuard(getJson('/family/circle-pick'));

  Future<Map<String, dynamic>> famFromCircle(int circleId) =>
      postJson('/family/from-circle', {'circle_member_id': circleId});

  Future<Map<String, dynamic>> famTasks() => loadGuard(getJson('/family/reminders'));

  Future<Map<String, dynamic>> famAssignTask(
          {required int memberId, required String title, DateTime? due, String notes = ''}) =>
      postJson('/family/reminders', {
        'member_id': memberId,
        'title': title,
        if (due != null) 'due_at': due.toIso8601String(),
        if (notes.isNotEmpty) 'notes': notes,
      });

  Future<Map<String, dynamic>> famCancelTask(int id) =>
      postJson('/family/reminders/$id/cancel');

  Future<Map<String, dynamic>> famShopping() => loadGuard(getJson('/family/shopping'));

  Future<Map<String, dynamic>> famShopAdd(String text, {String qty = '', int? ownerId}) =>
      postJson('/family/shopping', {
        'text': text,
        if (qty.isNotEmpty) 'qty': qty,
        if (ownerId != null) 'owner_id': ownerId,
      });

  Future<Map<String, dynamic>> famShopToggle(int id) =>
      postJson('/family/shopping/$id/toggle');

  Future<Map<String, dynamic>> famShopDelete(int id) =>
      postJson('/family/shopping/$id/delete');

  Future<Map<String, dynamic>> famShopClearDone({int? ownerId}) =>
      postJson('/family/shopping/clear-done', {if (ownerId != null) 'owner_id': ownerId});

  Future<Map<String, dynamic>> famDocs() => loadGuard(getJson('/family/docs'));

  Future<Map<String, dynamic>> famShareDoc(int documentId, List<int> memberIds) =>
      postJson('/family/docs', {'document_id': documentId, 'member_ids': memberIds});

  Future<Map<String, dynamic>> famRevokeDoc(int shareId) =>
      postJson('/family/docs/$shareId/revoke');

  Future<Map<String, dynamic>> famOpenDoc(int shareId) =>
      loadGuard(getJson('/family/docs/$shareId/open'));
}

/// Rows of GET /family/circle-pick.
List<Map<String, dynamic>> famPickRows(Object? r) {
  final raw = r is Map ? r['results'] : r;
  if (raw is! List) return const [];
  return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
}
