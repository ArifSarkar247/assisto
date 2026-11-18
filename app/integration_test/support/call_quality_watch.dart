// calls-quality — what ONE side of a call saw over a time window, measured
// from WebRtcCallMedia.debugQuality() snapshots taken every ~250 ms. Used by
// the flow driver (A) and the call peer (B) of the two-emulator call test so
// both sides are judged the same way.
//
//   video_frames      frames decoded in the window (the picture moved)
//   video_max_gap_ms  longest time with NO new decoded frame (a freeze as the
//                     viewer sees it) — the 2 s bar of the lossy-network case
//   audio_packets     audio packets received in the window
//   audio_max_gap_ms  longest time with NO new audio packet
//   freezes / freeze_ms   libwebrtc's own freeze counters (delta)
//   rtt / avail / size / fps / limit at the end of the window
import 'dart:async';

typedef QualitySnap = Future<Map<String, dynamic>> Function();
typedef QualityTick = Future<void> Function();

int _i(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;

/// Samples [snap] every [every] for [window]; [tick] runs between samples
/// (the flow pumps its UI there; the peer just waits).
Future<Map<String, dynamic>> watchQuality(QualitySnap snap, Duration window,
    {Duration every = const Duration(milliseconds: 250), QualityTick? tick}) async {
  final sw = Stopwatch()..start();
  final first = await snap();
  var last = first;
  var lastV = _i(first, 'vin_frames'), lastA = _i(first, 'ain_packets');
  var vAt = 0, aAt = 0, vGap = 0, aGap = 0, samples = 1, prevAt = 0, maxStep = 0;
  final rtts = <int>[];
  while (sw.elapsed < window) {
    if (tick != null) {
      await tick();
    } else {
      await Future<void>.delayed(every);
    }
    final s = await snap();
    samples++;
    final now = sw.elapsedMilliseconds;
    final v = _i(s, 'vin_frames'), a = _i(s, 'ain_packets');
    // calls-quality (calls2emu 44272508208): a gap is measured only up to the
    // LAST sample that still showed no new frame — when the sampler itself
    // stalls (the test's own UI pump on a busy emulator), that stall is not
    // reported as a freeze; [max_sample_ms] shows such stalls. libwebrtc's
    // own freeze counters (freezes / freeze_ms) are the receiver's truth.
    if (now - prevAt > maxStep) maxStep = now - prevAt;
    if (v <= lastV && now - vAt > vGap) vGap = now - vAt;
    if (a <= lastA && now - aAt > aGap) aGap = now - aAt;
    prevAt = now;
    if (v > lastV) {
      vAt = now;
      lastV = v;
    }
    if (a > lastA) {
      aAt = now;
      lastA = a;
    }
    final rtt = ((s['pair'] as Map?)?['rtt_ms'] as num?)?.toInt();
    if (rtt != null) rtts.add(rtt);
    last = s;
  }
  rtts.sort();
  final pair = (last['pair'] as Map?) ?? const {};
  final dLost = _i(last, 'vin_lost') - _i(first, 'vin_lost');
  final dRecv = _i(last, 'vin_recv') - _i(first, 'vin_recv');
  final aLost = _i(last, 'ain_lost') - _i(first, 'ain_lost');
  final aPk = _i(last, 'ain_packets') - _i(first, 'ain_packets');
  return {
    'window_ms': sw.elapsedMilliseconds,
    'samples': samples,
    'max_sample_ms': maxStep,
    'video_frames': _i(last, 'vin_frames') - _i(first, 'vin_frames'),
    'video_max_gap_ms': vGap,
    'video_loss_pct': dLost + dRecv > 0 ? (1000 * dLost / (dLost + dRecv)).round() / 10 : null,
    'freezes': _i(last, 'vin_freezes') - _i(first, 'vin_freezes'),
    'freeze_ms': _i(last, 'vin_freeze_ms') - _i(first, 'vin_freeze_ms'),
    'audio_packets': aPk,
    'audio_max_gap_ms': aGap,
    'audio_loss_pct': aLost + aPk > 0 ? (1000 * aLost / (aLost + aPk)).round() / 10 : null,
    'sent_video_frames': _i(last, 'vout_frames') - _i(first, 'vout_frames'),
    'rtt_median_ms': rtts.isEmpty ? null : rtts[rtts.length ~/ 2],
    'avail_kbps': pair['avail_kbps'],
    'local': pair['local'],
    'remote': pair['remote'],
    'in_size': '${last['vin_w']}x${last['vin_h']}',
    'in_fps': last['vin_fps'],
    'out_size': '${last['vout_w']}x${last['vout_h']}',
    'out_fps': last['vout_fps'],
    'out_limit': last['vout_limit'],
    'out_target_kbps': last['vout_target_kbps'],
  };
}

/// The selected pair goes through a TURN server (either end is a relay).
bool isRelayed(Map<String, dynamic> w) =>
    (w['local'] as Map?)?['type'] == 'relay' || (w['remote'] as Map?)?['type'] == 'relay';

/// One-line summary for notes / the owner doc.
String qualityLine(Map<String, dynamic> w) =>
    'video ${w['video_frames']} fr (max gap ${w['video_max_gap_ms']} ms, loss ${w['video_loss_pct']}%, '
    'freezes ${w['freezes']}/${w['freeze_ms']} ms, in ${w['in_size']}@${w['in_fps']}), '
    'audio ${w['audio_packets']} pk (max gap ${w['audio_max_gap_ms']} ms, loss ${w['audio_loss_pct']}%), '
    'rtt ${w['rtt_median_ms']} ms, avail ${w['avail_kbps']} kbps, out ${w['out_size']}@${w['out_fps']} '
    'limit ${w['out_limit']} target ${w['out_target_kbps']} kbps, '
    'path ${(w['local'] as Map?)?['type']}/${(w['local'] as Map?)?['networkType']}'
    '->${(w['remote'] as Map?)?['type']}';
