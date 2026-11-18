import 'call_controller.dart' show MediaStats;

/// callsbar (owner 2 Nov: calls on poor networks, imo-level).
///
/// PURE Dart — no plugin, no clock of its own (one call per stats sample,
/// every ~2 s), so it is unit-tested with network traces.
///
/// What it decides, from each getStats() sample of the pair in use:
///  * the Opus cap for OUR outgoing voice (sender maxBitrate + the
///    `maxaveragebitrate` we ask the other phone to send at — SDP fmtp):
///      normal 32 kbit/s -> 24 (fair) -> 16 (poor); low-data 16 -> 12;
///    Opus in-band FEC + DTX are always on (lost packets are rebuilt from the
///    next one; silence costs ~nothing) — imo's trick for 2G/3G voice;
///  * the cap for OUR outgoing video (bitrate / fps / resolution scale):
///      normal 600 kbit/s 24 fps -> fair 350 kbit/s 20 fps;
///      low-data 200 kbit/s 15 fps at half resolution;
///  * AUDIO-ONLY FALLBACK: when the uplink can't carry video (available send
///    bandwidth < [pauseBelowKbps] or loss > [pauseLossPct] for
///    [pauseAfter] samples ≈ 6 s) our video is PAUSED — the voice goes on
///    (Google Meet behaviour, WhatsApp freezes instead). It comes back after
///    [resumeAfter] good samples (≈ 10 s). While paused, little is sent, so
///    the bandwidth estimate may stay low: a PROBE resumes video after
///    [probeAfterSamples] (≈ 20 s, doubling to ≈ 2 min if it fails again).
///
/// The other phone runs the same policy for ITS uplink, so both directions
/// adapt. Hysteresis everywhere: one bad sample never flips anything.
enum NetTier { good, fair, poor }

/// calls-quality: the camera capture size (decided once, at camera open).
enum VideoCapture { hd720, sd480 }

/// Below this smoothed uplink (kbit/s) the NEXT call opens the camera at
/// 480p even on a capable phone.
const double weakUplinkKbps = 900;

/// 720p only on a phone with more than ~3 GB RAM (MemoryInfo.totalMem; a
/// "3 GB" phone reports ~2.7–2.9 GB, so 3328 MB is the cut, as in
/// LowRamTuning), not flagged low-RAM, and no weak uplink measured last call.
/// Unknown RAM (0) = 480p (safe).
VideoCapture videoCaptureFor(
    {required int ramMb, required bool lowRam, double? lastUplinkKbps}) {
  if (lowRam || ramMb <= 3328) return VideoCapture.sd480;
  if (lastUplinkKbps != null && lastUplinkKbps < weakUplinkKbps) {
    return VideoCapture.sd480;
  }
  return VideoCapture.hd720;
}

/// calls-quality: one rung of the live resolution ladder.
class VideoRung {
  const VideoRung(this.height, this.maxBps, this.fps);
  final int height; // target picture height (720 / 480 / 320)
  final int maxBps;
  final int fps;
}

class MediaPlan {
  const MediaPlan({
    required this.audioMaxBps,
    required this.videoMaxBps,
    required this.videoMaxFps,
    required this.videoScaleDown,
    required this.videoActive,
    this.opusPtimeMs,
  });

  final int audioMaxBps;

  /// Low-data: ask the other phone for 60 ms Opus packets (`a=ptime:60`)
  /// instead of 20 ms — a third of the packets, so the per-packet header
  /// cost (IP/UDP/RTP/SRTP ≈ 60 bytes, ~25 kbit/s at 20 ms) drops to ~8
  /// kbit/s. null = the default 20 ms (lowest delay).
  final int? opusPtimeMs;
  final int videoMaxBps;
  final int videoMaxFps;
  final double videoScaleDown;

  /// false = our camera keeps running locally but NOTHING is sent (paused
  /// for the network); the voice continues.
  final bool videoActive;

  /// The Opus `maxaveragebitrate` we ask the other phone to use (SDP).
  int get opusMaxAverage => audioMaxBps;

  @override
  bool operator ==(Object o) =>
      o is MediaPlan &&
      o.audioMaxBps == audioMaxBps &&
      o.videoMaxBps == videoMaxBps &&
      o.videoMaxFps == videoMaxFps &&
      o.videoScaleDown == videoScaleDown &&
      o.videoActive == videoActive &&
      o.opusPtimeMs == opusPtimeMs;

  @override
  int get hashCode => Object.hash(audioMaxBps, videoMaxBps, videoMaxFps,
      videoScaleDown, videoActive, opusPtimeMs);

  @override
  String toString() =>
      'MediaPlan(a=$audioMaxBps v=$videoMaxBps@$videoMaxFps/x$videoScaleDown'
      '${videoActive ? '' : ' PAUSED'})';
}

/// What changed after one sample.
class PolicyStep {
  const PolicyStep(this.plan, {this.paused = false, this.resumed = false});
  final MediaPlan plan;

  /// our video was just paused for the network (show the notice once)
  final bool paused;

  /// our video just came back
  final bool resumed;
}

class CallNetPolicy {
  CallNetPolicy({
    this.lowData = false,
    this.pauseBelowKbps = 120,
    this.pauseLossPct = 15,
    this.resumeAboveKbps = 250,
    this.pauseAfter = 3,
    this.resumeAfter = 5,
    this.tierAfter = 2,
    this.probeAfterSamples = 10,
    this.maxProbeAfterSamples = 60,
    this.hd = false,
  }) : rung = 1; // calls-quality: start at 480p, climb to 720p on a good uplink

  /// calls-quality: the camera was opened at 720p ([VideoCapture.hd720]).
  /// false = 480p capture: the ladder starts at 480p (the old plan values).
  final bool hd;

  /// The live resolution ladder (index = [rung]): 720p 1.5 Mbit/s, 480p
  /// 600 kbit/s, 320p 350 kbit/s. Every call starts at 480p (a 720p first
  /// keyframe on a 300 kbit/s start estimate took > 15 s to arrive on the CI
  /// emulators, calls2emu 44254417569) and a 720p camera climbs to 720p
  /// after [rungUpAfter] samples of an uplink that fills the 480p cap. The
  /// ladder follows the uplink while the camera is OFF too, so turning the
  /// camera on starts at a size the link can carry right now. Down one rung when the smoothed available
  /// send bitrate stays under [rungDownKbps] for [rungDownAfter] samples;
  /// up one rung (a probe) after [rungUpAfter] samples of an uplink that
  /// fills the current cap — a probe that falls back within 10 samples
  /// doubles the wait (max [maxRungUpAfter]). A fair/poor network (loss,
  /// RTT, jitter) caps the ladder at 320p.
  static const ladder = [
    VideoRung(720, 1500000, 24),
    VideoRung(480, 600000, 24),
    VideoRung(320, 350000, 20),
  ];
  static const rungDownKbps = [900.0, 380.0];
  static const rungDownAfter = 2;
  static const rungUpAfter = 3;
  static const maxRungUpAfter = 24;

  /// current ladder rung (0 = 720p, 1 = 480p, 2 = 320p)
  int rung;
  int _downRun = 0, _upRun = 0, _sinceUp = 1 << 20, _samples = 0;
  int _upWait = rungUpAfter;

  /// smoothed available send bitrate (kbit/s, EMA) — the next call's
  /// capture decision reads it (CallVideoProfile.lastUplinkKbps).
  double? uplinkKbps;

  /// the camera's own height for this call (720 or 480)
  int get captureHeight => hd ? 720 : 480;

  int get _topRung => hd ? 0 : 1;

  /// The person chose "Low-data calls" (or the other phone asked for it).
  bool lowData;
  final double pauseBelowKbps;
  final double pauseLossPct;
  final double resumeAboveKbps;
  final int pauseAfter;
  final int resumeAfter;

  /// samples a worse / better tier must hold before the audio cap moves
  final int tierAfter;
  final int probeAfterSamples;
  final int maxProbeAfterSamples;

  // audio caps (bit/s)
  static const int audioNormal = 32000;
  static const int audioFair = 24000;
  static const int audioPoor = 16000;
  static const int audioLowData = 16000;
  static const int audioLowDataPoor = 12000;

  NetTier tier = NetTier.good;
  NetTier? _pendingTier;
  int _pendingCount = 0;

  bool videoPaused = false;
  int _badRun = 0;
  int _goodRun = 0;
  int _pausedSamples = 0;
  late int _probeEvery = probeAfterSamples;
  bool _probing = false;

  /// how many samples our video has been paused in total (x sample period
  /// = seconds, for the quality report)
  int pausedSamplesTotal = 0;

  /// Tier of ONE sample. Missing numbers never count as bad.
  static NetTier tierOf(MediaStats s) {
    final l = s.lossPct ?? 0, r = s.rttMs ?? 0, j = s.jitterMs ?? 0;
    final b = s.availableKbps;
    if (l > 10 || r > 700 || j > 120 || (b != null && b < 40)) {
      return NetTier.poor;
    }
    if (l > 3 || r > 350 || j > 50 || (b != null && b < 80)) {
      return NetTier.fair;
    }
    return NetTier.good;
  }

  MediaPlan get plan {
    final int a;
    if (lowData) {
      a = tier == NetTier.poor ? audioLowDataPoor : audioLowData;
    } else {
      a = switch (tier) {
        NetTier.good => audioNormal,
        NetTier.fair => audioFair,
        NetTier.poor => audioPoor,
      };
    }
    final fair = tier != NetTier.good;
    // calls-quality: a fair / poor network caps the ladder at 320p
    final r = ladder[fair ? 2 : rung.clamp(_topRung, 2)];
    return MediaPlan(
      audioMaxBps: a,
      videoMaxBps: lowData ? 200000 : r.maxBps,
      videoMaxFps: lowData ? 15 : r.fps,
      // low-data: ~240p (half of 480p, a third of 720p)
      videoScaleDown: lowData
          ? (hd ? 3.0 : 2.0)
          : ((captureHeight / r.height) < 1 ? 1.0 : captureHeight / r.height),
      videoActive: !videoPaused,
      opusPtimeMs: lowData ? 60 : null,
    );
  }

  /// The target picture height of our outgoing video right now.
  int get targetHeight => (captureHeight / plan.videoScaleDown).round();

  /// calls-quality: one step of the resolution ladder (uplink only; the
  /// tier cap is applied in [plan]). Missing numbers never move it.
  void _stepRung(double? kbps) {
    _samples++;
    if (kbps == null || kbps <= 0) return;
    final u = uplinkKbps;
    uplinkKbps = u == null ? kbps : u * 0.6 + kbps * 0.4;
    if (_samples <= 1) return; // the estimate is still ramping up
    _sinceUp++;
    final e = uplinkKbps!;
    final cur = rung.clamp(_topRung, 2);
    if (cur < 2 && e < rungDownKbps[cur]) {
      _upRun = 0;
      if (++_downRun >= rungDownAfter) {
        rung = cur + 1;
        _downRun = 0;
        // a probe that failed quickly: wait twice as long next time
        if (_sinceUp <= 10) {
          _upWait = (_upWait * 2).clamp(rungUpAfter, maxRungUpAfter);
        }
      }
      return;
    }
    _downRun = 0;
    if (cur > _topRung && e >= ladder[cur].maxBps / 1000 * 0.9) {
      if (++_upRun >= _upWait) {
        rung = cur - 1;
        _upRun = 0;
        _sinceUp = 0;
      }
    } else {
      _upRun = 0;
      if (_sinceUp > 10) _upWait = rungUpAfter; // the last probe held
    }
  }

  /// One stats sample. [sendingVideo] = our camera is on in a video call
  /// (the pause logic is idle otherwise).
  PolicyStep onSample(MediaStats s, {required bool sendingVideo}) {
    _stepTier(tierOf(s));
    _stepRung(s.availableKbps);
    var paused = false, resumed = false;
    if (!sendingVideo) {
      // voice call / camera off: nothing to pause; forget any pause state
      if (videoPaused) {
        videoPaused = false;
        _resetPause();
      }
      return PolicyStep(plan);
    }
    final b = s.availableKbps;
    final l = s.lossPct ?? 0;
    final bad = (b != null && b < pauseBelowKbps) || l > pauseLossPct;
    final good = (b == null || b >= resumeAboveKbps) && l < 5;
    if (!videoPaused) {
      _badRun = bad ? _badRun + 1 : 0;
      if (_probing) {
        // the probe: one bad sample after resuming -> back to paused with a
        // longer wait; good samples end the probe
        if (bad) {
          videoPaused = true;
          _probing = false;
          _badRun = 0;
          _pausedSamples = 0;
          _probeEvery =
              (_probeEvery * 2).clamp(probeAfterSamples, maxProbeAfterSamples);
          // no notice for a failed probe (the person already knows)
        } else if (good) {
          _goodRun++;
          if (_goodRun >= resumeAfter) {
            _probing = false;
            _probeEvery = probeAfterSamples;
            _goodRun = 0;
          }
        }
      } else if (_badRun >= pauseAfter) {
        videoPaused = true;
        paused = true;
        _badRun = 0;
        _goodRun = 0;
        _pausedSamples = 0;
      }
    } else {
      pausedSamplesTotal++;
      _pausedSamples++;
      _goodRun = good ? _goodRun + 1 : 0;
      if (_goodRun >= resumeAfter) {
        videoPaused = false;
        resumed = true;
        _resetPause();
      } else if (_pausedSamples >= _probeEvery) {
        // try sending video again: the estimate can only grow while we send
        videoPaused = false;
        _probing = true;
        _goodRun = 0;
        _badRun = 0;
        _pausedSamples = 0;
      }
    }
    return PolicyStep(plan, paused: paused, resumed: resumed);
  }

  void _resetPause() {
    _badRun = 0;
    _goodRun = 0;
    _pausedSamples = 0;
    _probing = false;
    _probeEvery = probeAfterSamples;
  }

  void _stepTier(NetTier t) {
    if (t == tier) {
      _pendingTier = null;
      _pendingCount = 0;
      return;
    }
    if (_pendingTier == t) {
      _pendingCount++;
    } else {
      _pendingTier = t;
      _pendingCount = 1;
    }
    if (_pendingCount >= tierAfter) {
      tier = t;
      _pendingTier = null;
      _pendingCount = 0;
    }
  }

  /// true while our video is off the wire only because of the network
  /// (a probe in progress counts as "not paused").
  bool get pausedForNetwork => videoPaused;
}

/// Opus SDP tuning (callsbar): in the `a=fmtp:` line of every Opus payload
/// type set `useinbandfec=1` (packet-loss concealment from the next packet),
/// `usedtx=1` (no bits while silent), `stereo=0` and
/// `maxaveragebitrate=<cap>` (what we ask the OTHER phone to send at). An SDP
/// without Opus, or without an fmtp line for it, gets one added. Any parse
/// trouble returns the SDP unchanged — tuning can never break a call.
///
/// [ptimeMs] (low-data): every `a=ptime:` line is replaced by ONE
/// `a=ptime:<ms>` right after the Opus fmtp line (the other phone then sends
/// fewer, bigger packets).
String tuneOpusSdp(String sdp, {required int maxAverageBitrate, int? ptimeMs}) {
  try {
    final nl = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(nl);
    final pts = <String>{};
    final rtpmap = RegExp(r'^a=rtpmap:(\d+) opus/48000', caseSensitive: false);
    for (final l in lines) {
      final m = rtpmap.firstMatch(l);
      if (m != null) pts.add(m.group(1)!);
    }
    if (pts.isEmpty) return sdp;
    final want = <String, String>{
      'useinbandfec': '1',
      'usedtx': '1',
      'stereo': '0',
      'maxaveragebitrate': '$maxAverageBitrate',
    };
    final seen = <String>{};
    final out = <String>[];
    for (final l in lines) {
      final m = RegExp(r'^a=fmtp:(\d+) (.*)$').firstMatch(l);
      if (m != null && pts.contains(m.group(1))) {
        final pt = m.group(1)!;
        seen.add(pt);
        final params = <String, String>{};
        final order = <String>[];
        for (final part in m.group(2)!.split(';')) {
          final p = part.trim();
          if (p.isEmpty) continue;
          final eq = p.indexOf('=');
          final k = eq < 0 ? p : p.substring(0, eq).trim();
          final v = eq < 0 ? '' : p.substring(eq + 1).trim();
          if (!params.containsKey(k)) order.add(k);
          params[k] = v;
        }
        for (final e in want.entries) {
          if (!params.containsKey(e.key)) order.add(e.key);
          params[e.key] = e.value;
        }
        out.add('a=fmtp:$pt ${order.map((k) => params[k]!.isEmpty ? k : '$k=${params[k]}').join(';')}');
        if (ptimeMs != null && seen.length == 1) out.add('a=ptime:$ptimeMs');
        continue;
      }
      if (ptimeMs != null && l.startsWith('a=ptime:')) continue;
      out.add(l);
    }
    // an Opus payload with no fmtp line: add one right after its rtpmap
    if (seen.length < pts.length) {
      final fixed = <String>[];
      for (final l in out) {
        fixed.add(l);
        final m = rtpmap.firstMatch(l);
        if (m != null && !seen.contains(m.group(1))) {
          fixed.add('a=fmtp:${m.group(1)} '
              '${want.entries.map((e) => '${e.key}=${e.value}').join(';')}');
          if (ptimeMs != null && seen.isEmpty) {
            fixed.add('a=ptime:$ptimeMs');
            seen.add(m.group(1)!);
          }
        }
      }
      return fixed.join(nl);
    }
    return out.join(nl);
  } catch (_) {
    return sdp;
  }
}
