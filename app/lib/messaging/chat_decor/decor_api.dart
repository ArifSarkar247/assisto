import '../../api.dart';

/// cde-chat — the server copy of a chat's theme + nicknames (core/views_cde.py).
/// Built only on the public getJson / postJson helpers.
extension DecorApi on ApiClient {
  Future<Map<String, dynamic>> decorMember(int edgeId) =>
      getJson('/circle/decor/member/$edgeId');

  /// {theme: id}. A Premium theme for a Free plan -> ApiException 402.
  Future<Map<String, dynamic>> setMemberTheme(int edgeId, String themeId) =>
      postJson('/circle/decor/member/$edgeId', {'theme': themeId});

  /// who: 'peer' | 'me'; name '' = remove.
  Future<Map<String, dynamic>> setMemberNick(int edgeId, String who, String name) =>
      postJson('/circle/decor/member/$edgeId', {
        'nick': {'who': who, 'name': name}
      });

  Future<Map<String, dynamic>> decorGroup(int groupId) =>
      getJson('/circle/decor/group/$groupId');

  Future<Map<String, dynamic>> setGroupTheme(int groupId, String themeId) =>
      postJson('/circle/decor/group/$groupId', {'theme': themeId});

  Future<Map<String, dynamic>> setGroupNick(int groupId, int userId, String name) =>
      postJson('/circle/decor/group/$groupId', {
        'nick': {'user_id': userId, 'name': name}
      });
}
