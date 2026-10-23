import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api.dart';
import '../realtime/realtime_transport.dart';
import 'call_log.dart';
import 'group_call.dart';

/// b3-group: [GroupCallApi] over our server (REST) + the shared real-time
/// transport (topic "call.group").
class ApiGroupCalls implements GroupCallApi {
  ApiGroupCalls(this.api, this.transport);

  final ApiClient api;
  final PollRealtimeTransport? transport;

  static String _p(String room, [String tail = '']) =>
      '/circle/calls/group/${Uri.encodeComponent(room)}$tail';

  @override
  Future<Map<String, dynamic>> start(
          {int? callId,
          int? groupId,
          List<int> memberIds = const [],
          String kind = 'voice'}) =>
      api.postJson('/circle/calls/group/start', {
        if (callId != null) 'call_id': callId,
        if (groupId != null) 'group_id': groupId,
        if (memberIds.isNotEmpty) 'member_ids': memberIds,
        'kind': kind,
      });

  @override
  Future<Map<String, dynamic>> token(String room) =>
      api.postJson(_p(room, '/token'));

  @override
  Future<Map<String, dynamic>> event(String room, String event,
          {bool? video}) =>
      api.postJson(_p(room, '/event'),
          {'event': event, if (video != null) 'video': video});

  @override
  Future<Map<String, dynamic>> status(String room) => api.getJson(_p(room));

  @override
  Future<Map<String, dynamic>> invite(String room, List<int> memberIds) =>
      api.postJson(_p(room, '/invite'), {'member_ids': memberIds});

  @override
  Future<void> mute(String room, int userId,
          {required String kind, String? trackSid}) =>
      api.postJson(_p(room, '/mute'), {
        'user_id': userId,
        'kind': kind,
        if (trackSid != null && trackSid.isNotEmpty) 'track_sid': trackSid,
      });

  @override
  Future<void> remove(String room, int userId) =>
      api.postJson(_p(room, '/remove'), {'user_id': userId});

  @override
  Future<Map<String, dynamic>> record(String room, String action) =>
      api.postJson(_p(room, '/record'), {'action': action});

  @override
  Stream<Map<String, dynamic>> events(String room) {
    final t = transport;
    if (t == null) return const Stream.empty();
    return t.events
        .where((e) => e.topic == 'call.group' && e.payload['room'] == room)
        .map((e) => e.payload);
  }
}

/// Is the group-call SFU installed + switched on (GET
/// circle/calls/group/config)? Every group-call entry in the app is HIDDEN
/// until this says yes — no showpiece before the owner installs LiveKit.
class GroupCallConfig {
  GroupCallConfig._();

  static final ValueNotifier<bool> available = ValueNotifier<bool>(false);
  static int maxParticipants = 0;
  static DateTime? _at;
  static Future<bool>? _inFlight;

  /// Cached for 10 minutes; any error = not available.
  static Future<bool> refresh(ApiClient api, {bool force = false}) {
    final at = _at;
    if (!force &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 10)) {
      return Future.value(available.value);
    }
    return _inFlight ??= () async {
      try {
        final r = await api.getJson('/circle/calls/group/config');
        maxParticipants = (r['max_participants'] as num?)?.toInt() ?? 0;
        available.value = r['available'] == true;
      } catch (e) {
        callLog('group#config', e);
        available.value = false;
      } finally {
        _at = DateTime.now();
        _inFlight = null;
      }
      return available.value;
    }();
  }

  @visibleForTesting
  static void setForTest(bool on, {int max = 8}) {
    available.value = on;
    maxParticipants = on ? max : 0;
    _at = DateTime.now();
  }

  @visibleForTesting
  static void reset() {
    available.value = false;
    maxParticipants = 0;
    _at = null;
    _inFlight = null;
  }
}
