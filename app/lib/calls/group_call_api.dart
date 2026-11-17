import 'dart:async';

import '../api.dart';
import '../realtime/realtime_transport.dart';
import 'group_call_controller.dart';

/// group-calls: the REST side of group calls (core/views_group_calls.py)
/// and [GroupSignaling] over the shared real-time poll.
class GroupCallApi {
  GroupCallApi(this.api);
  final ApiClient api;

  static GroupCallError errorOf(Object e) {
    if (e is GroupCallError) return e;
    if (e is ApiException) {
      final b = e.body;
      final code = '${b?['code'] ?? e.reason ?? ''}';
      final msg = '${b?['detail'] ?? ''}';
      return GroupCallError(
          code.isEmpty ? (e.status == null ? 'network' : 'error') : code,
          msg,
          e.status);
    }
    return const GroupCallError('network');
  }

  Future<T> _wrap<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw errorOf(e);
    }
  }

  /// A group call from a group chat (rings every member; joins the call
  /// already on in that group).
  Future<Map<String, dynamic>> startFromGroup(int groupId, String kind) =>
      _wrap(() => api.postJson(
          '/circle/group-calls', {'group_id': groupId, 'kind': kind}));

  /// Add people to a running 1:1 call (it becomes a group call).
  Future<Map<String, dynamic>> addToCall(int callId, List<int> userIds) =>
      _wrap(() => api.postJson('/circle/group-calls',
          {'from_call_id': callId, 'user_ids': userIds}));

  Future<Map<String, dynamic>> snapshot(int roomId) =>
      _wrap(() => api.getJson('/circle/group-calls/$roomId'));

  Future<Map<String, dynamic>> join(int roomId, {int? callId}) =>
      _wrap(() => api.postJson('/circle/group-calls/$roomId/join',
          {if (callId != null) 'call_id': callId}));

  Future<void> leave(int roomId) =>
      _wrap(() => api.postJson('/circle/group-calls/$roomId/leave', {}));

  Future<Map<String, dynamic>> invite(int roomId, List<int> userIds) =>
      _wrap(() => api.postJson(
          '/circle/group-calls/$roomId/invite', {'user_ids': userIds}));

  Future<void> media(int roomId, {bool? muted, bool? camera}) =>
      _wrap(() => api.postJson('/circle/group-calls/$roomId/media', {
            if (muted != null) 'muted': muted,
            if (camera != null) 'camera': camera,
          }));

  /// My Circle people for the "Add person" picker (never a blocked person).
  Future<List<Map<String, dynamic>>> candidates({int? roomId}) async {
    final r = await _wrap(() => api.getJson('/circle/group-calls/candidates'
        '${roomId == null ? '' : '?room=$roomId'}'));
    return ((r['people'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  /// The group chat's "Join call" bar: the live call or null.
  Future<Map<String, dynamic>?> liveInGroup(int groupId) async {
    final r =
        await _wrap(() => api.getJson('/circle/group-calls/group/$groupId'));
    final c = r['call'];
    return c is Map ? c.cast<String, dynamic>() : null;
  }
}

class ApiGroupSignaling implements GroupSignaling {
  ApiGroupSignaling(this.calls, this.transport);
  final GroupCallApi calls;
  final PollRealtimeTransport transport;

  @override
  Future<Map<String, dynamic>> snapshot(int roomId) => calls.snapshot(roomId);

  @override
  Future<Map<String, dynamic>> join(int roomId, {int? callId}) =>
      calls.join(roomId, callId: callId);

  @override
  Future<void> leave(int roomId) => calls.leave(roomId);

  @override
  Future<Map<String, dynamic>> invite(int roomId, List<int> userIds) =>
      calls.invite(roomId, userIds);

  @override
  Future<void> media(int roomId, {bool? muted, bool? camera}) =>
      calls.media(roomId, muted: muted, camera: camera);

  @override
  Future<void> signal(int legId, String kind, Map<String, dynamic> data) =>
      transport.send(
          'call.signal', {'call_id': legId, 'kind': kind, 'data': data});

  @override
  Future<void> event(int legId, String event, {bool? relayed}) =>
      calls.api.postJson('/circle/calls/$legId/event',
          {'event': event, if (relayed != null) 'relayed': relayed});

  static Map<String, dynamic> _env(RealtimeEvent e) =>
      {'seq': e.seq, 'topic': e.topic, 'payload': e.payload};

  @override
  Stream<Map<String, dynamic>> get events => transport.events
      .where((e) =>
          e.topic.startsWith('group.') ||
          e.topic == 'call.signal' ||
          e.topic == 'call.state')
      .map(_env);

  @override
  Future<List<Map<String, dynamic>>> backlog(int legId) async {
    try {
      final evs = await transport.backlog(topics: 'call.signal', callId: legId);
      return evs.map(_env).toList();
    } catch (_) {
      return const [];
    }
  }

  bool _fast = false;
  @override
  void setFast(bool on) {
    if (on == _fast) return;
    _fast = on;
    transport.setFast(on);
  }
}
