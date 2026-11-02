// callsbar: CallController on poor networks — caps applied on connect,
// low-data for both directions (mine + the other phone's `media` signal),
// the audio-only fallback (notice, `net_paused` to the other side, resume),
// TURN-relay-only ICE after repeated failures (before connect + while
// reconnecting), the end-of-call quality report (numbers only) and the
// "ask for a rating?" rule.
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_rating.dart';

import 'c2_calls_fakes.dart';

Future<void> settle() => pumpEventQueue(times: 40);

class AdaptiveFakeMedia extends FakeCallMedia implements AdaptiveCallMedia {
  final plans = <MediaPlan>[];
  int relayCalls = 0;

  @override
  Future<void> applyPlan(MediaPlan plan) async => plans.add(plan);

  @override
  Future<bool> forceRelay() async {
    relayCalls++;
    log.add('relay-only');
    return true;
  }
}

CallController mk(FakeCallMedia m, FakeSignaling s,
        {bool video = false,
        bool outgoing = true,
        bool lowData = false,
        void Function(int, Map<String, dynamic>)? onReport}) =>
    CallController(
      media: m,
      signaling: s,
      sounds: FakeSounds(),
      video: video,
      outgoing: outgoing,
      memberId: 7,
      callId: outgoing ? null : 42,
      lowData: lowData,
      reconnectGrace: const Duration(milliseconds: 20),
      reconnectGiveUp: const Duration(seconds: 5),
      restartEvery: const Duration(milliseconds: 60),
      statusEvery: const Duration(seconds: 30),
      statsEvery: const Duration(seconds: 30),
      connectTimeout: const Duration(seconds: 30),
      onQualityReport: onReport,
    );

Future<CallController> live(FakeCallMedia m, FakeSignaling s,
    {bool video = false,
    bool lowData = false,
    void Function(int, Map<String, dynamic>)? onReport}) async {
  final c = mk(m, s, video: video, lowData: lowData, onReport: onReport);
  await c.start();
  m.link.add(MediaLinkState.connected);
  await settle();
  expect(c.phase, CallPhase.connected);
  return c;
}

/// one stats poll (the timer is 30 s in tests — poll by hand)
Future<void> poll(CallController c, FakeCallMedia m, MediaStats st) async {
  m.nextStats = st;
  await c.debugPollStats();
  await settle();
}

const weak = MediaStats(rttMs: 650, lossPct: 6, jitterMs: 90, availableKbps: 70);
const good = MediaStats(
    rttMs: 40, lossPct: 0.2, jitterMs: 6, availableKbps: 2500,
    bytesSent: 400000, bytesReceived: 600000);

List<(String, Map<String, dynamic>)> mediaSignals(FakeSignaling s) =>
    s.signals.where((e) => e.$1 == 'media').toList();

void main() {
  test('caps are applied as soon as the peer exists (normal: 32k voice)',
      () async {
    final m = AdaptiveFakeMedia(), s = FakeSignaling();
    await live(m, s);
    expect(m.plans, isNotEmpty);
    expect(m.plans.first.audioMaxBps, 32000);
  });

  test('low-data from settings: 16k from the first packet, told to the '
      'other phone', () async {
    final m = AdaptiveFakeMedia(), s = FakeSignaling();
    final c = await live(m, s, lowData: true);
    expect(m.plans.first.audioMaxBps, 16000);
    expect(c.effectiveLowData, isTrue);
    await c.toggleMute(); // any media state carries the flag
    expect(mediaSignals(s).last.$2['low_data'], isTrue);
  });

  test('switching low-data in the call: new caps now + notice + signal',
      () async {
    final m = AdaptiveFakeMedia(), s = FakeSignaling();
    final c = await live(m, s, video: true);
    await c.setLowData(true);
    await settle();
    expect(m.plans.last.audioMaxBps, 16000);
    expect(m.plans.last.videoMaxBps, 200000);
    expect(c.notice, CallNotice.lowDataOn);
    expect(mediaSignals(s).last.$2['low_data'], isTrue);
    await c.setLowData(false);
    await settle();
    expect(m.plans.last.audioMaxBps, 32000);
    expect(c.notice, CallNotice.lowDataOff);
  });

  test('the other phone asks for low data -> my caps follow', () async {
    final m = AdaptiveFakeMedia(), s = FakeSignaling();
    final c = await live(m, s);
    s.remoteSignal('media', {'camera': false, 'mic': true, 'low_data': true});
    await settle();
    expect(c.remoteLowData, isTrue);
    expect(c.effectiveLowData, isTrue);
    expect(m.plans.last.audioMaxBps, 16000);
    expect(c.notice, CallNotice.lowDataOn);
    expect(c.lowData, isFalse, reason: 'my own setting is not changed');
  });

  test('weak network on video: paused + notice + net_paused to the other '
      'side; voice goes on; video back when the network recovers', () async {
    final m = AdaptiveFakeMedia(), s = FakeSignaling();
    final c = await live(m, s, video: true);
    for (var i = 0; i < 3; i++) {
      await poll(c, m, weak);
    }
    expect(c.videoPausedForNet, isTrue);
    expect(c.notice, CallNotice.videoPausedNet);
    expect(m.plans.last.videoActive, isFalse);
    expect(c.phase, CallPhase.connected, reason: 'the call never drops');
    expect(mediaSignals(s).last.$2['net_paused'], isTrue);
    for (var i = 0; i < 5; i++) {
      await poll(c, m, good);
    }
    expect(c.videoPausedForNet, isFalse);
    expect(c.notice, CallNotice.videoResumedNet);
    expect(m.plans.last.videoActive, isTrue);
    expect(mediaSignals(s).last.$2['net_paused'], isFalse);
    expect(c.videoPausedSeconds, greaterThan(0));
  });

  test('the other phone paused its video -> shown, never as a frozen call',
      () async {
    final m = AdaptiveFakeMedia(), s = FakeSignaling();
    final c = await live(m, s, video: true);
    s.remoteSignal('media', {'camera': true, 'mic': true, 'net_paused': true});
    await settle();
    expect(c.remoteVideoPausedNet, isTrue);
    s.remoteSignal('media', {'camera': true, 'mic': true});
    await settle();
    expect(c.remoteVideoPausedNet, isFalse);
  });

  test('before connect: restart, then TURN-relay-only restart', () async {
    final m = AdaptiveFakeMedia(), s = FakeSignaling();
    final c = mk(m, s);
    await c.start();
    s.state('accepted');
    await settle();
    m.link.add(MediaLinkState.failed);
    await settle();
    expect(m.relayCalls, 0, reason: 'first failure: normal ICE restart');
    m.link.add(MediaLinkState.failed);
    await settle();
    expect(m.relayCalls, 1);
    expect(c.relayForced, isTrue);
    expect(m.log.where((e) => e == 'offer:restart').length, 2);
    expect(m.log.indexOf('relay-only'),
        lessThan(m.log.lastIndexOf('offer:restart')));
  });

  test('no TURN configured: relay is never forced', () async {
    final m = AdaptiveFakeMedia();
    final s = FakeSignaling(rtc: const {
      'configured': false,
      'throttled': false,
      'ice_servers': []
    });
    final c = mk(m, s);
    await c.start();
    s.state('accepted');
    await settle();
    m.link.add(MediaLinkState.failed);
    m.link.add(MediaLinkState.failed);
    await settle();
    expect(m.relayCalls, 0);
    expect(c.relayForced, isFalse);
  });

  test('reconnecting: after 2 failed restarts, relay-only (once)', () async {
    final m = AdaptiveFakeMedia(), s = FakeSignaling();
    final c = await live(m, s);
    c.onNetworkChanged('cellular');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await settle();
    expect(c.phase, CallPhase.reconnecting);
    expect(m.relayCalls, 1);
    expect(c.reconnects, 1);
    m.link.add(MediaLinkState.connected);
    await settle();
    expect(c.phase, CallPhase.connected);
    expect(c.lastNetKind, 'cellular');
    await c.hangup();
  });

  test('a plain (non-adaptive) media never breaks: no plans, no relay',
      () async {
    final m = FakeCallMedia(), s = FakeSignaling();
    final c = await live(m, s, video: true);
    for (var i = 0; i < 3; i++) {
      await poll(c, m, weak);
    }
    // the policy still decides (and tells the other side honestly)
    expect(c.videoPausedForNet, isTrue);
    expect(c.appliedPlan, isNull);
  });

  test('end of a connected call: ONE quality report with the measured '
      'numbers (never content)', () async {
    final reports = <(int, Map<String, dynamic>)>[];
    final m = AdaptiveFakeMedia(), s = FakeSignaling();
    final c = await live(m, s, onReport: (id, r) => reports.add((id, r)));
    await poll(c, m, good);
    await poll(c, m, weak);
    await c.hangup();
    await settle();
    expect(reports.length, 1);
    final (id, r) = reports.single;
    expect(id, 42);
    expect(r['rtt_ms'], 650);
    expect(r['loss_pct'], 6.0);
    expect(r['min_kbps'], 70);
    expect(r['data_kb'], (1000000 / 1024).round());
    expect(r['reconnects'], 0);
    expect(r['low_data'], isFalse);
    expect(r.keys, isNot(contains('sdp')));
    await c.hangup();
    expect(reports.length, 1, reason: 'never twice');
  });

  test('a call that never connected sends no report', () async {
    final reports = <Map<String, dynamic>>[];
    final m = AdaptiveFakeMedia(), s = FakeSignaling();
    final c = mk(m, s, onReport: (_, r) => reports.add(r));
    await c.start();
    await c.hangup();
    await settle();
    expect(reports, isEmpty);
  });

  group('ask for a rating?', () {
    CallController ended(
        {int talkS = 60,
        CallEndReason reason = CallEndReason.hangup,
        int callId = 42}) {
      final c = previewController(
          video: false,
          outgoing: true,
          phase: CallPhase.ended,
          reason: reason);
      c.callId = callId;
      c.connectedAt = DateTime(2026, 11, 2, 10, 0, 0);
      c.endedAt = c.connectedAt!.add(Duration(seconds: talkS));
      return c;
    }

    test('never for a call under 10 s or one that never connected', () {
      expect(shouldAskCallRating(ended(talkS: 5)), isFalse);
      final c = ended();
      c.connectedAt = null;
      expect(shouldAskCallRating(c), isFalse);
    });

    test('1 in 3 normal calls (by id), always after a problem', () {
      expect(shouldAskCallRating(ended(callId: 42)), isTrue);
      expect(shouldAskCallRating(ended(callId: 43)), isFalse);
      final p = ended(callId: 43)..reconnects = 1;
      expect(shouldAskCallRating(p), isTrue);
      expect(shouldAskCallRating(ended(callId: 43, reason: CallEndReason.lost)),
          isTrue);
    });

    test('not after a declined / failed setup', () {
      expect(
          shouldAskCallRating(
              ended(callId: 42, reason: CallEndReason.connectFailed)),
          isFalse);
    });
  });
}
