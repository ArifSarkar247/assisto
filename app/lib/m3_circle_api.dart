import 'api.dart';
import 'widgets/loading_gate.dart';

/// m3-circle — the calls My Circle home + "Add to My Circle" need, built only
/// on the generic getJson / postJson helpers (no api.dart edit). Every read
/// goes through [loadGuard] so a hanging request ends in an error + Retry.
///
///   GET  /circle/requests                 incoming (accept/decline) + sent
///   POST /circle/request/<id>/act         accept | decline | cancel
///   POST /messenger/contacts/lookup       find by number, ANY format
///   POST /circle/request {to_user_id|phone, relation, custom_label?, note?}
///   GET  /circle/invite?relation=         my QR / link
///   POST /circle/invite/redeem {link}     paste someone's invite link
///   POST /messenger/invite/share-link     invite a non-user (share sheet)
extension M3CircleApi on ApiClient {
  Future<List<Map<String, dynamic>>> m3Requests() async {
    final r = await loadGuard(getJson('/circle/requests'));
    return ((r['results'] ?? r['requests'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  Future<Map<String, dynamic>> m3Act(int id, String event) =>
      loadGuard(postJson('/circle/request/$id/act', {'event': event}));

  Future<Map<String, dynamic>> m3Lookup(String phone) =>
      loadGuard(postJson('/messenger/contacts/lookup', {'phone': phone}));

  Future<Map<String, dynamic>> m3SendRequest({
    int? toUserId,
    String? phone,
    required String relation,
    String? customLabel,
    String? note,
  }) =>
      loadGuard(postJson('/circle/request', {
        if (toUserId != null) 'to_user_id': toUserId,
        if (toUserId == null && phone != null) 'phone': phone,
        'relation': relation,
        if (customLabel != null && customLabel.isNotEmpty)
          'custom_label': customLabel,
        if (note != null && note.isNotEmpty) 'note': note,
      }));

  Future<Map<String, dynamic>> m3MyInvite({String relation = 'friend'}) =>
      loadGuard(getJson('/circle/invite?relation=$relation'));

  Future<Map<String, dynamic>> m3Redeem(String link) =>
      loadGuard(postJson('/circle/invite/redeem', {'link': link}));

  Future<Map<String, dynamic>> m3ShareLink({String relation = 'friend'}) =>
      loadGuard(postJson('/messenger/invite/share-link', {'relation': relation}));
}

/// True for a request row sent TO me (accept / decline).
bool m3IsIncoming(Map<String, dynamic> r) {
  final dir = '${r['direction'] ?? ''}';
  if (dir == 'incoming') return true;
  if (dir == 'outgoing') return false;
  final actions =
      ((r['actions'] as List?) ?? const []).map((e) => '$e').toList();
  return actions.contains('accept');
}
