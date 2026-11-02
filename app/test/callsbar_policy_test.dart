// callsbar: the poor-network policy (Opus caps, video caps, audio-only
// fallback with hysteresis + probing) driven by NETWORK PROFILES — the same
// numbers getStats() reports on shaped links (netem-style profiles: Wi-Fi,
// 4G, 3G, EDGE/2G, a lift / train dropout, lossy 4G). This is a SIMULATION
// of the decisions, not a real-phone measurement (that stays a two-phone
// owner test) — and the Opus SDP tuner on real SDP shapes.
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_net_policy.dart';

/// One netem-like profile -> the stats sample a phone would read.
MediaStats sample(String profile) => switch (profile) {
      'wifi' => const MediaStats(
          rttMs: 40, lossPct: 0.2, jitterMs: 6, availableKbps: 2500),
      '4g' => const MediaStats(
          rttMs: 90, lossPct: 0.8, jitterMs: 15, availableKbps: 1200),
      '3g' => const MediaStats(
          rttMs: 280, lossPct: 3.5, jitterMs: 45, availableKbps: 220),
      'edge' => const MediaStats(
          rttMs: 650, lossPct: 6, jitterMs: 90, availableKbps: 70),
      '2g-bad' => const MediaStats(
          rttMs: 900, lossPct: 14, jitterMs: 150, availableKbps: 30),
      'lossy4g' => const MediaStats(
          rttMs: 120, lossPct: 18, jitterMs: 40, availableKbps: 600),
      _ => const MediaStats(),
    };

List<PolicyStep> run(CallNetPolicy p, List<String> trace,
        {bool video = true}) =>
    [for (final s in trace) p.onSample(sample(s), sendingVideo: video)];

void main() {
  group('audio caps (Opus)', () {
    test('good network: 32 kbit/s, FEC + DTX via SDP', () {
      final p = CallNetPolicy();
      final steps = run(p, List.filled(5, 'wifi'), video: false);
      expect(steps.last.plan.audioMaxBps, 32000);
      expect(p.tier, NetTier.good);
    });

    test('3G -> fair (24k), bad 2G -> poor (16k), both after 2 samples', () {
      final p = CallNetPolicy();
      p.onSample(sample('3g'), sendingVideo: false);
      expect(p.plan.audioMaxBps, 32000, reason: 'one sample never flips');
      p.onSample(sample('3g'), sendingVideo: false);
      expect(p.plan.audioMaxBps, 24000);
      run(p, ['2g-bad', '2g-bad'], video: false);
      expect(p.plan.audioMaxBps, 16000);
      run(p, ['wifi', 'wifi'], video: false);
      expect(p.plan.audioMaxBps, 32000, reason: 'recovers');
    });

    test('low-data: 16k, 12k on a poor network; video small', () {
      final p = CallNetPolicy(lowData: true);
      expect(p.plan.audioMaxBps, 16000);
      expect(p.plan.videoMaxBps, 200000);
      expect(p.plan.videoMaxFps, 15);
      expect(p.plan.videoScaleDown, 2.0);
      run(p, ['2g-bad', '2g-bad'], video: false);
      expect(p.plan.audioMaxBps, 12000);
    });

    test('Opus payload caps per minute: 120 KB low-data vs 240 KB normal', () {
      // payload only, one direction, while talking (headers + the other
      // direction come on top; the real number is the owner's phone test)
      expect(CallNetPolicy.audioLowData * 60 / 8 / 1000, 120);
      expect(CallNetPolicy.audioNormal * 60 / 8 / 1000, 240);
    });
  });

  group('audio-only fallback (video)', () {
    test('Wi-Fi / 4G never pause video', () {
      final p = CallNetPolicy();
      final steps = run(p, [...List.filled(10, 'wifi'), ...List.filled(10, '4g')]);
      expect(steps.any((s) => s.paused), isFalse);
      expect(p.plan.videoActive, isTrue);
    });

    test('3G keeps video at the fair cap (350k / 20 fps)', () {
      final p = CallNetPolicy();
      run(p, List.filled(6, '3g'));
      expect(p.plan.videoActive, isTrue);
      expect(p.plan.videoMaxBps, 350000);
      expect(p.plan.videoMaxFps, 20);
    });

    test('EDGE: paused after 3 bad samples (~6 s), voice goes on', () {
      final p = CallNetPolicy();
      final steps = run(p, ['edge', 'edge', 'edge']);
      expect(steps[0].paused || steps[1].paused, isFalse);
      expect(steps[2].paused, isTrue);
      expect(p.plan.videoActive, isFalse);
      expect(p.plan.audioMaxBps, greaterThan(0));
    });

    test('heavy loss on a fast link also pauses (lossy 4G)', () {
      final p = CallNetPolicy();
      final steps = run(p, ['lossy4g', 'lossy4g', 'lossy4g']);
      expect(steps.last.paused, isTrue);
    });

    test('one bad sample (a lift) never pauses', () {
      final p = CallNetPolicy();
      final steps = run(p, ['wifi', '2g-bad', 'wifi', '2g-bad', 'wifi']);
      expect(steps.any((s) => s.paused), isFalse);
    });

    test('resumes after 5 good samples (~10 s) with one "back" event', () {
      final p = CallNetPolicy();
      run(p, ['edge', 'edge', 'edge']);
      final steps = run(p, List.filled(5, 'wifi'));
      expect(steps.where((s) => s.resumed).length, 1);
      expect(steps.last.resumed, isTrue);
      expect(p.plan.videoActive, isTrue);
      expect(p.pausedSamplesTotal, 5, reason: 'paused for 5 samples (~10 s)');
    });

    test('stuck low estimate: a probe re-sends video after ~20 s; a failed '
        'probe pauses again silently and waits twice as long', () {
      final p = CallNetPolicy();
      run(p, ['edge', 'edge', 'edge']); // paused
      // the estimate stays at EDGE while only voice is sent
      final probe = run(p, List.filled(10, 'edge'));
      expect(p.plan.videoActive, isTrue, reason: 'probing after 10 samples');
      expect(probe.any((s) => s.resumed), isFalse,
          reason: 'a probe is not announced as "video back"');
      final fail = p.onSample(sample('edge'), sendingVideo: true);
      expect(fail.plan.videoActive, isFalse);
      expect(fail.paused, isFalse, reason: 'no second notice');
      run(p, List.filled(10, 'edge'));
      expect(p.plan.videoActive, isFalse, reason: 'next probe waits 20');
      run(p, List.filled(10, 'edge'));
      expect(p.plan.videoActive, isTrue);
    });

    test('a probe that finds a good network ends paused-for-network', () {
      final p = CallNetPolicy();
      run(p, ['edge', 'edge', 'edge']);
      run(p, List.filled(10, 'edge')); // probe starts
      final steps = run(p, List.filled(6, 'wifi'));
      expect(steps.any((s) => s.paused), isFalse);
      expect(p.pausedForNetwork, isFalse);
      expect(p.plan.videoActive, isTrue);
    });

    test('voice-only / camera off: nothing to pause, state cleared', () {
      final p = CallNetPolicy();
      run(p, ['edge', 'edge', 'edge']);
      expect(p.pausedForNetwork, isTrue);
      p.onSample(sample('edge'), sendingVideo: false);
      expect(p.pausedForNetwork, isFalse);
      final steps = run(p, List.filled(8, 'edge'), video: false);
      expect(steps.any((s) => s.paused), isFalse);
    });

    test('missing numbers never count as bad', () {
      final p = CallNetPolicy();
      final steps = run(p, List.filled(8, 'none'));
      expect(steps.any((s) => s.paused), isFalse);
      expect(p.tier, NetTier.good);
    });
  });

  group('Opus SDP tuning', () {
    const offer = 'v=0\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111 63 9\r\n'
        'a=rtpmap:111 opus/48000/2\r\n'
        'a=rtcp-fb:111 transport-cc\r\n'
        'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
        'a=rtpmap:63 red/48000/2\r\n'
        'a=fmtp:63 111/111\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'a=rtpmap:96 VP8/90000\r\n';

    test('adds DTX, stereo=0 and the cap; keeps minptime; CRLF kept', () {
      final out = tuneOpusSdp(offer, maxAverageBitrate: 16000);
      expect(out, contains('a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1;'
          'stereo=0;maxaveragebitrate=16000\r\n'));
      expect(out, contains('a=fmtp:63 111/111\r\n'), reason: 'RED untouched');
      expect(out, contains('a=rtpmap:96 VP8/90000'));
      expect(out.split('\r\n').length, offer.split('\r\n').length);
    });

    test('replaces an old cap instead of adding a second one', () {
      final once = tuneOpusSdp(offer, maxAverageBitrate: 32000);
      final twice = tuneOpusSdp(once, maxAverageBitrate: 12000);
      expect('maxaveragebitrate'.allMatches(twice).length, 1);
      expect(twice, contains('maxaveragebitrate=12000'));
    });

    test('Opus without an fmtp line gets one', () {
      const sdp = 'v=0\nm=audio 9 RTP/AVP 111\na=rtpmap:111 opus/48000/2\n'
          'a=sendrecv\n';
      final out = tuneOpusSdp(sdp, maxAverageBitrate: 24000);
      expect(
          out,
          contains('a=rtpmap:111 opus/48000/2\na=fmtp:111 useinbandfec=1;'
              'usedtx=1;stereo=0;maxaveragebitrate=24000\na=sendrecv'));
    });

    test('low-data: one a=ptime:60 right after the Opus fmtp, old one gone',
        () {
      const withPtime = 'v=0\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=rtpmap:111 opus/48000/2\r\n'
          'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
          'a=ptime:20\r\n'
          'a=maxptime:120\r\n';
      final out =
          tuneOpusSdp(withPtime, maxAverageBitrate: 16000, ptimeMs: 60);
      expect('a=ptime:'.allMatches(out).length, 1);
      expect(out, contains('maxaveragebitrate=16000\r\na=ptime:60\r\n'));
      expect(out, contains('a=maxptime:120'));
      final plain = tuneOpusSdp(withPtime, maxAverageBitrate: 32000);
      expect(plain, contains('a=ptime:20'), reason: 'normal mode: untouched');
    });

    test('plan carries ptime 60 only in low-data', () {
      expect(CallNetPolicy().plan.opusPtimeMs, isNull);
      expect(CallNetPolicy(lowData: true).plan.opusPtimeMs, 60);
    });

    test('no Opus / garbage -> unchanged (tuning never breaks a call)', () {
      const pcmu = 'v=0\r\nm=audio 9 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n';
      expect(tuneOpusSdp(pcmu, maxAverageBitrate: 16000), pcmu);
      expect(tuneOpusSdp('', maxAverageBitrate: 16000), '');
    });
  });
}
