// calls-quality (lead 18 Nov): adaptive video resolution — 720p on capable
// phones with a good uplink, 480p on ≤ 3 GB phones / after a weak uplink,
// and a LIVE step-down (720 -> 480 -> 320) when the uplink drops, back up by
// probing. Pure Dart: the same decisions the two-emulator run proves live.
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_net_policy.dart';
import 'package:assisto/calls/call_video_profile.dart';

MediaStats up(double kbps, {double rtt = 60, double loss = 0.2}) =>
    MediaStats(rttMs: rtt, lossPct: loss, jitterMs: 8, availableKbps: kbps);

/// feeds [n] samples of [kbps]; returns the sample index (1-based) at which
/// the rung first became [want] (null = never).
int? feedUntil(CallNetPolicy p, double kbps, int n, int want) {
  for (var i = 1; i <= n; i++) {
    p.onSample(up(kbps), sendingVideo: true);
    if (p.rung == want) return i;
  }
  return null;
}

void main() {
  tearDown(() {
    CallVideoProfile.forced = null;
    CallVideoProfile.lastUplinkKbps = null;
    CallVideoProfile.ramMb = () => 0;
    CallVideoProfile.lowRam = () => false;
  });

  group('camera size at open', () {
    test('720p only on > 3 GB phones without a weak last uplink', () {
      expect(videoCaptureFor(ramMb: 1900, lowRam: false), VideoCapture.sd480); // "2 GB"
      expect(videoCaptureFor(ramMb: 2850, lowRam: false), VideoCapture.sd480); // "3 GB"
      expect(videoCaptureFor(ramMb: 3800, lowRam: false), VideoCapture.hd720); // "4 GB"
      expect(videoCaptureFor(ramMb: 7600, lowRam: true), VideoCapture.sd480); // low-RAM flag
      expect(videoCaptureFor(ramMb: 0, lowRam: false), VideoCapture.sd480); // unknown
      expect(videoCaptureFor(ramMb: 7600, lowRam: false, lastUplinkKbps: 500), VideoCapture.sd480);
      expect(videoCaptureFor(ramMb: 7600, lowRam: false, lastUplinkKbps: 2400), VideoCapture.hd720);
    });

    test('profile reads the phone + the last call, constraints are plain numbers', () {
      CallVideoProfile.ramMb = () => 3800;
      expect(CallVideoProfile.capture, VideoCapture.hd720);
      expect(CallVideoProfile.constraintsFor(VideoCapture.hd720),
          {'width': 1280, 'height': 720, 'frameRate': 24});
      expect(CallVideoProfile.constraintsFor(VideoCapture.sd480),
          {'width': 640, 'height': 480, 'frameRate': 24});
      CallVideoProfile.lastUplinkKbps = 400;
      expect(CallVideoProfile.capture, VideoCapture.sd480);
    });

    test('the controller\'s ladder follows the same decision', () {
      CallVideoProfile.ramMb = () => 3800;
      expect(CallNetPolicy(hd: CallVideoProfile.capture == VideoCapture.hd720).targetHeight, 720);
      CallVideoProfile.ramMb = () => 1900;
      expect(CallNetPolicy(hd: CallVideoProfile.capture == VideoCapture.hd720).targetHeight, 480);
    });
  });

  group('live resolution ladder (720p capture)', () {
    test('good uplink keeps 720p at 1.5 Mbit/s', () {
      final p = CallNetPolicy(hd: true);
      feedUntil(p, 2500, 12, -1);
      expect(p.rung, 0);
      expect(p.plan.videoScaleDown, 1.0);
      expect(p.plan.videoMaxBps, 1500000);
      expect(p.targetHeight, 720);
    });

    test('uplink drops: 720 -> 480 -> 320 within a few samples, then back up', () {
      final p = CallNetPolicy(hd: true);
      feedUntil(p, 2500, 3, -1);
      final to480 = feedUntil(p, 600, 10, 1);
      expect(to480, isNotNull);
      expect(to480!, lessThanOrEqualTo(6), reason: '~12 s at one sample / 2 s');
      expect(p.targetHeight, 480);
      expect(p.plan.videoMaxBps, 600000);
      final to320 = feedUntil(p, 250, 10, 2);
      expect(to320, isNotNull);
      expect(p.targetHeight, 320);
      expect(p.plan.videoScaleDown, closeTo(2.25, 0.001));
      expect(p.plan.videoMaxFps, 20);
      // uplink back: probes up one rung at a time
      expect(feedUntil(p, 2500, 6, 1), isNotNull);
      expect(feedUntil(p, 2500, 6, 0), isNotNull);
      expect(p.targetHeight, 720);
      expect(p.uplinkKbps, greaterThan(1500));
    });

    test('one bad sample never steps down', () {
      final p = CallNetPolicy(hd: true);
      feedUntil(p, 2500, 4, -1);
      p.onSample(up(300), sendingVideo: true);
      p.onSample(up(2500), sendingVideo: true);
      expect(p.rung, 0);
    });

    test('a failed probe doubles the wait before the next one', () {
      final p = CallNetPolicy(hd: true);
      feedUntil(p, 200, 12, 2); // down to 320p
      expect(p.rung, 2);
      // 330 kbit/s fills the 350k cap -> probe 480p after 3 samples ...
      final probe = feedUntil(p, 330, 10, 1);
      expect(probe, isNotNull);
      // ... 480p needs >= 380: back down
      expect(feedUntil(p, 330, 4, 2), isNotNull);
      // the next probe waits twice as long (6 samples)
      final again = feedUntil(p, 330, 12, 1);
      expect(again, isNotNull);
      expect(again!, greaterThanOrEqualTo(6));
    });

    test('a fair network (3G loss / RTT) caps at 320p; low-data ~240p', () {
      final p = CallNetPolicy(hd: true);
      for (var i = 0; i < 4; i++) {
        p.onSample(up(2500, rtt: 420, loss: 4), sendingVideo: true);
      }
      expect(p.tier, NetTier.fair);
      expect(p.targetHeight, 320);
      final l = CallNetPolicy(hd: true, lowData: true);
      expect(l.targetHeight, 240);
      expect(l.plan.videoMaxBps, 200000);
    });
  });

  group('480p capture (≤ 3 GB phone)', () {
    test('never above 480p, the old caps, steps down to 320p', () {
      final p = CallNetPolicy();
      feedUntil(p, 5000, 12, -1);
      expect(p.rung, 1);
      expect(p.plan.videoMaxBps, 600000);
      expect(p.plan.videoScaleDown, 1.0);
      expect(feedUntil(p, 250, 14, 2), isNotNull);
      expect(p.targetHeight, 320);
      expect(p.plan.videoScaleDown, closeTo(1.5, 0.001));
    });

    test('voice / camera off: the ladder does not move', () {
      final p = CallNetPolicy(hd: true);
      for (var i = 0; i < 8; i++) {
        p.onSample(up(100), sendingVideo: false);
      }
      expect(p.rung, 0);
    });
  });
}
