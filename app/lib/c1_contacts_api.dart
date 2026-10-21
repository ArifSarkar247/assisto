import 'api.dart';

/// c1-contacts — the extra calls the WhatsApp-style contacts screen needs.
/// Built only on the generic `getJson` / `postJson` helpers (no api.dart edit).
///
///   POST /messenger/contacts/lookup {phone}  -> find by number, ANY format
///   POST /circle/request {to_user_id, relation, custom_label?}
///        -> Add to My Circle (accept -> message + call)
///   POST /circle/request/<id>/act {event: accept}
extension C1ContactsApi on ApiClient {
  Future<Map<String, dynamic>> contactsLookup(String phone) =>
      postJson('/messenger/contacts/lookup', {'phone': phone});

  Future<Map<String, dynamic>> circleAddByUser({
    required int toUserId,
    required String relation,
    String? customLabel,
    String? note,
  }) =>
      postJson('/circle/request', {
        'to_user_id': toUserId,
        'relation': relation,
        if (customLabel != null && customLabel.isNotEmpty)
          'custom_label': customLabel,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<Map<String, dynamic>> circleAcceptRequest(int memberId) =>
      postJson('/circle/request/$memberId/act', {'event': 'accept'});
}
