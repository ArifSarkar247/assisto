import 'dart:async';

import '../../api.dart';
import '../../realtime/realtime_transport.dart';
import 'group_call.dart';

/// callsB: [GroupCallApi] over our server (REST) + the shared real-time
/// transport (`call.roster` events — the transport already polls every
/// `call*` topic while a call screen is up).
class ApiGroupCallApi implements GroupCallApi {
  ApiGroupCallApi(this.api, this.transport);
  final ApiClient api;
  final PollRealtimeTransport transport;

  @override
  Future<Map<String, dynamic>> addPerson(int callId, int memberId) =>
      api.postJson('/circle/calls/$callId/add', {'member_id': memberId});

  @override
  Future<Map<String, dynamic>?> roomOfCall(int callId) async {
    try {
      return await api.getJson('/circle/calls/$callId/room');
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> room(int roomId) =>
      api.getJson('/circle/rooms/$roomId');

  @override
  Future<Map<String, dynamic>> join(int roomId) =>
      api.postJson('/circle/rooms/$roomId/join', const {});

  @override
  Future<Map<String, dynamic>> leave(int roomId) =>
      api.postJson('/circle/rooms/$roomId/leave', const {});

  @override
  Future<void> media(int roomId, Map<String, dynamic> data) async {
    await api.postJson('/circle/rooms/$roomId/media', data);
  }

  @override
  Stream<Map<String, dynamic>> rosterEvents() => transport.events
      .where((e) => e.topic == 'call.roster')
      .map((e) => e.payload);

  /// The group chat banner: {room: roster|null, ringable: [user ids]}.
  static Future<Map<String, dynamic>> active(ApiClient api, int groupId) =>
      api.getJson('/circle/groups/$groupId/call/active');

  /// Start a group call from the group chat (rings up to 3 contacts).
  static Future<Map<String, dynamic>> start(
          ApiClient api, int groupId, String kind, List<int> userIds) =>
      api.postJson('/circle/groups/$groupId/call/start',
          {'kind': kind, 'user_ids': userIds});
}
