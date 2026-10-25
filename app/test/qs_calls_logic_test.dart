import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/calls/call_controller.dart';

/// qs-calls (quality sweep, owner item 5) — pure call-state mapping the call
/// screen relies on: every server phase / end reason, unknown values never
/// look "connected", and the quality-bar thresholds at their boundaries.
void main() {
  group('phaseFromServer', () {
    test('every live phase maps; anything else is ended', () {
      expect(phaseFromServer('calling'), CallPhase.calling);
      expect(phaseFromServer('ringing'), CallPhase.ringing);
      expect(phaseFromServer('accepted'), CallPhase.accepted);
      expect(phaseFromServer('connected'), CallPhase.connected);
      expect(phaseFromServer('reconnecting'), CallPhase.reconnecting);
      for (final s in ['ended', '', 'CONNECTED', 'active', 'weird']) {
        expect(phaseFromServer(s), CallPhase.ended, reason: s);
      }
    });
  });

  group('endReasonFromServer', () {
    test('every server reason maps 1:1', () {
      const want = {
        'hangup': CallEndReason.hangup,
        'no_answer': CallEndReason.noAnswer,
        'busy': CallEndReason.busy,
        'declined': CallEndReason.declined,
        'offline': CallEndReason.offline,
        'canceled': CallEndReason.canceled,
        'failed': CallEndReason.failed,
        'lost': CallEndReason.lost,
      };
      want.forEach((k, v) => expect(endReasonFromServer(k), v, reason: k));
    });
    test('empty = none; an unknown reason is a plain hang-up (never busy)',
        () {
      expect(endReasonFromServer(''), CallEndReason.none);
      expect(endReasonFromServer('server_exploded'), CallEndReason.hangup);
    });
  });

  group('MediaStats quality', () {
    test('no numbers = unknown, never bad', () {
      expect(const MediaStats(relayed: true).quality, CallQuality.unknown);
    });
    test('voice boundaries', () {
      expect(const MediaStats(lossPct: 2.5).quality, CallQuality.good);
      expect(const MediaStats(lossPct: 2.6).quality, CallQuality.fair);
      expect(const MediaStats(lossPct: 8).quality, CallQuality.fair);
      expect(const MediaStats(lossPct: 8.1).quality, CallQuality.poor);
      expect(const MediaStats(rttMs: 300).quality, CallQuality.good);
      expect(const MediaStats(rttMs: 601).quality, CallQuality.poor);
      expect(const MediaStats(jitterMs: 41).quality, CallQuality.fair);
      expect(const MediaStats(jitterMs: 101).quality, CallQuality.poor);
      expect(const MediaStats(availableKbps: 48).quality, CallQuality.good);
      expect(const MediaStats(availableKbps: 47).quality, CallQuality.fair);
      expect(const MediaStats(availableKbps: 23).quality, CallQuality.poor);
    });
    test('video needs more bandwidth for the same bar', () {
      const s = MediaStats(availableKbps: 200);
      expect(s.qualityFor(), CallQuality.good);
      expect(s.qualityFor(video: true), CallQuality.fair);
      expect(const MediaStats(availableKbps: 149).qualityFor(video: true),
          CallQuality.poor);
      expect(const MediaStats(availableKbps: 400).qualityFor(video: true),
          CallQuality.good);
    });
    test('the worst metric wins', () {
      expect(const MediaStats(rttMs: 50, lossPct: 0, jitterMs: 150).quality,
          CallQuality.poor);
    });
  });

  group('audio routes', () {
    test('ids round-trip; unknown id is null', () {
      for (final r in AudioRoute.values) {
        expect(audioRouteFromId(audioRouteId(r)), r);
      }
      expect(audioRouteFromId('usb'), isNull);
      expect(audioRouteFromId(''), isNull);
    });
  });
}
