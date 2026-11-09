import '../api.dart';
import '../widgets/loading_gate.dart';

/// fcscreen — Family Care v3 calls (generic getJson / postJson only, no
/// api.dart edit). Server: backend/core/family_v3.py + views_family_v3.py.
/// Contract: owner_actions/FAMILY_CARE_V3_API.md §4.
extension FcApi on ApiClient {
  Future<Map<String, dynamic>> fcFamilies() => loadGuard(getJson('/family/v3/families'));

  Future<Map<String, dynamic>> fcCreateFamily(String name) =>
      postJson('/family/v3/families', {'name': name});

  Future<Map<String, dynamic>> fcBoard(int familyId) =>
      loadGuard(getJson('/family/v3/families/$familyId/board'));

  Future<Map<String, dynamic>> fcInvite(int familyId, int circleMemberId,
          {String role = 'adult', String relation = ''}) =>
      postJson('/family/v3/families/$familyId/invite',
          {'circle_member_id': circleMemberId, 'role': role, 'relation': relation});

  Future<Map<String, dynamic>> fcAnswerInvite(int membershipId, bool accept) =>
      postJson('/family/v3/invites/$membershipId/${accept ? 'accept' : 'decline'}');

  Future<Map<String, dynamic>> fcLeave(int familyId) =>
      postJson('/family/v3/families/$familyId/leave');

  Future<Map<String, dynamic>> fcMemberPage(int userId, int familyId) =>
      loadGuard(getJson('/family/v3/members/$userId?family=$familyId'));

  Future<Map<String, dynamic>> fcAddTask(int familyId, String title,
          {String kind = 'other', String? dueDate}) =>
      postJson('/family/v3/families/$familyId/tasks',
          {'title': title, 'kind': kind, if (dueDate != null) 'due_date': dueDate});

  /// take | release | done | undo | delete
  Future<Map<String, dynamic>> fcTaskAction(int taskId, String action) =>
      postJson('/family/v3/tasks/$taskId/$action');

  /// fcbrain's server ask (offline rules first, AI only when needed).
  Future<Map<String, dynamic>> fcAsk(int familyId, String q) =>
      postJson('/family/brain/ask', {'q': q, 'family_id': familyId});
}
