import 'dart:async';

import '../api.dart';
import '../realtime/realtime_transport.dart';
import 'call_controller.dart';

/// [CallSignaling] over our server: REST for place / events, and the shared
/// real-time transport ([PollRealtimeTransport]) for call.state + call.signal.
class ApiCallSignaling implements CallSignaling {
  ApiCallSignaling(this.api, this.transport);

  final ApiClient api;
  final PollRealtimeTransport transport;

  @override
  Future<Map<String, dynamic>> place(int memberId, String kind,
          {String? clientCallId}) =>
      api.postJson('/circle/$memberId/call', {
        'kind': kind,
        if (clientCallId != null) 'client_call_id': clientCallId,
      });

  @override
  Future<Map<String, dynamic>> accept(int callId) async {
    try {
      return await api
          .postJson('/circle/calls/$callId/event', {'event': 'answer'});
    } on ApiException catch (e) {
      if (e.status == 404 || e.status == 410) {
        return {'phase': 'ended', 'end_reason': 'canceled'};
      }
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> event(int callId, String event,
          {bool? relayed}) =>
      api.postJson('/circle/calls/$callId/event',
          {'event': event, if (relayed != null) 'relayed': relayed});

  @override
  Future<void> signal(int callId, String kind, Map<String, dynamic> data) =>
      transport
          .send('call.signal', {'call_id': callId, 'kind': kind, 'data': data});

  @override
  Future<Map<String, dynamic>> status(int callId) =>
      api.getJson('/circle/calls/$callId');

  @override
  Future<Map<String, dynamic>?> rtcConfig() async {
    try {
      return await api.getJson('/rtc/turn');
    } catch (_) {
      return null; // unknown -> the call falls back to the place() ICE
    }
  }

  bool _mine(RealtimeEvent e, int callId) =>
      (e.topic == 'call.state' || e.topic == 'call.signal') &&
      (e.payload['call_id'] as num?)?.toInt() == callId;

  Map<String, dynamic> _env(RealtimeEvent e) =>
      {'seq': e.seq, 'topic': e.topic, 'payload': e.payload};

  @override
  Stream<Map<String, dynamic>> events(int callId) =>
      transport.events.where((e) => _mine(e, callId)).map(_env);

  @override
  Future<List<Map<String, dynamic>>> backlog(int callId) async {
    try {
      final evs =
          await transport.backlog(topics: 'call.signal', callId: callId);
      return evs.where((e) => _mine(e, callId)).map(_env).toList();
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
