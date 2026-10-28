import 'dart:async';

import '../api.dart';
import '../realtime/realtime_transport.dart';
import '../services/error_kind.dart';
import 'call_controller.dart';

/// [CallSignaling] over our server: REST for place / events, and the shared
/// real-time transport ([PollRealtimeTransport]) for call.state + call.signal.
class ApiCallSignaling implements CallSignaling, RealtimeHints {
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

  /// circle2: waits before re-sending an ICE candidate whose POST never got
  /// an answer (the network was switching). Tests pass zeros.
  List<Duration> iceRetry = const [
    Duration(milliseconds: 400),
    Duration(milliseconds: 1200),
  ];

  /// circle2: a transient failure (no answer / 5xx / 429) worth a re-send.
  static bool transient(Object e) {
    if (e is ApiException) {
      final s = e.status ?? 0;
      return s == 0 || s == 429 || s >= 500;
    }
    return failKindOf(e) == FailKind.network;
  }

  @override
  Future<void> signal(
      int callId, String kind, Map<String, dynamic> data) async {
    final body = {'call_id': callId, 'kind': kind, 'data': data};
    try {
      if (kind != 'ice') {
        await transport.send('call.signal', body);
        return;
      }
      // circle2: an ICE candidate sent while Wi-Fi <-> data is switching
      // used to be lost on the first failed POST. Re-send it (a duplicate
      // candidate is harmless; offers/answers are never re-sent).
      for (var i = 0;; i++) {
        try {
          await transport.send('call.signal', body);
          return;
        } catch (e) {
          if (i >= iceRetry.length || !transient(e)) rethrow;
          await Future<void>.delayed(iceRetry[i]);
        }
      }
    } on ApiException catch (e) {
      // b1: the server's plan gate refused switching this call to video
      if (kind == 'video_request' && (e.status == 402 || e.status == 403)) {
        throw const CallUpgradeRequired();
      }
      rethrow;
    }
  }

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

  bool _steady = false;
  @override
  void setSteady(bool on) {
    if (on == _steady) return;
    _steady = on;
    transport.setSteady(on);
  }

  @override
  void networkChanged(String kind) {
    unawaited(transport.networkChanged());
  }
}
