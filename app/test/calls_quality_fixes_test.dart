// calls-quality: each bug the two-emulator quality run found
// (calls2emu 44254417569 / 44261908414) becomes a test here.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/audio/audio_route_service.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_pip.dart';

import 'c2_calls_fakes.dart';

/// A phone (or tablet / emulator) whose Android may lack an earpiece and
/// may refuse a route.
class _Phone implements AudioRoutePlatform {
  _Phone(this.outs, {this.refuse = const {}});
  List<AudioOutput> outs;
  final Set<AudioRoute> refuse;
  AudioRoute? playing = AudioRoute.speaker; // what Android really plays on
  final ctl = StreamController<void>.broadcast();

  @override
  Future<bool> beginCommunication() async => true;
  @override
  Future<List<AudioOutput>> outputs() async => List.of(outs);
  @override
  Future<AudioRoute?> active() async => playing;
  @override
  Future<bool> select(AudioOutput o) async {
    if (refuse.contains(o.route) || !outs.any((x) => x.route == o.route)) return false;
    playing = o.route;
    return true;
  }

  @override
  Future<void> restore() async {}
  @override
  Future<bool> bluetoothPermitted() async => true;
  @override
  Future<bool> bluetoothPresent() async => false;
  @override
  Stream<void> get changes => ctl.stream;
}

Future<void> settle() => pumpEventQueue(times: 30);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('audio route: the screen never claims a route Android is not on', () {
    test('no earpiece (emulator / tablet): a voice call is on the speaker and says so', () async {
      final p = _Phone([const AudioOutput(AudioRoute.speaker)]);
      final s = AudioRouteService(p, stalePrefs: false);
      final seen = <AudioRoute>[];
      final sub = s.routeChanges.listen(seen.add);
      await s.beginCall(video: false);
      await settle();
      expect(s.active, AudioRoute.speaker);
      expect(p.playing, AudioRoute.speaker);
      // the user taps "speaker off": there is no earpiece -> the screen hears
      // that the speaker stays (it used to keep showing "earpiece")
      await s.select(AudioRoute.earpiece);
      await settle();
      expect(seen.last, AudioRoute.speaker);
      expect(s.active, AudioRoute.speaker);
      await sub.cancel();
    });

    test('a route Android refuses is read back from Android, not assumed', () async {
      final p = _Phone(
          [const AudioOutput(AudioRoute.earpiece), const AudioOutput(AudioRoute.speaker)],
          refuse: {AudioRoute.earpiece});
      final s = AudioRouteService(p, stalePrefs: false);
      await s.beginCall(video: false); // wants the earpiece, Android refuses
      await settle();
      expect(s.active, AudioRoute.speaker);
      expect(s.log.any((l) => l.startsWith('route:earpiece!->speaker')), isTrue, reason: '${s.log}');
    });

    test('a normal phone still toggles earpiece <-> speaker', () async {
      final p = _Phone([const AudioOutput(AudioRoute.earpiece), const AudioOutput(AudioRoute.speaker)])
        ..playing = AudioRoute.earpiece;
      final s = AudioRouteService(p, stalePrefs: false);
      await s.beginCall(video: false);
      await settle();
      expect(p.playing, AudioRoute.earpiece);
      await s.select(AudioRoute.speaker);
      await settle();
      expect(p.playing, AudioRoute.speaker);
      await s.select(AudioRoute.earpiece);
      await settle();
      expect(p.playing, AudioRoute.earpiece);
      expect(s.active, AudioRoute.earpiece);
    });
  });

  group('PiP layout from the window size', () {
    test('a tiny window while not in the foreground is PiP', () {
      // calls2emu: 364x485 px at 440 dpi = 132x176 dp, lifecycle inactive
      expect(looksLikePip(shortestSide: 132, state: AppLifecycleState.inactive), isTrue);
      expect(looksLikePip(shortestSide: 132, state: AppLifecycleState.paused), isTrue);
    });

    test('a phone screen, or split screen while in use, is not', () {
      expect(looksLikePip(shortestSide: 392, state: AppLifecycleState.inactive), isFalse);
      expect(looksLikePip(shortestSide: 250, state: AppLifecycleState.resumed), isFalse);
      expect(looksLikePip(shortestSide: 132, state: null), isFalse);
    });
  });

  group('3G-like path keeps video (no pause on an under-reading estimate)', () {
    MediaStats s(double kbps, double rtt, double loss) =>
        MediaStats(rttMs: rtt, lossPct: loss, jitterMs: 30, availableKbps: kbps);

    test('RTT 350 ms, 3.6 % loss, estimate ~60 kbit/s: video keeps adapting', () {
      final p = CallNetPolicy();
      for (var i = 0; i < 8; i++) {
        final st = p.onSample(s(60, 350, 3.6), sendingVideo: true);
        expect(st.paused, isFalse);
      }
      expect(p.plan.videoActive, isTrue);
      expect(p.targetHeight, 180, reason: 'steps down to 180p 8 fps instead');
      expect(p.plan.videoMaxFps, 8);
    });

    test('the ladder below 320p: 240p 10 fps, then 180p 8 fps, then back up', () {
      final p = CallNetPolicy();
      final seen = <int>{};
      for (var i = 0; i < 14; i++) {
        p.onSample(s(150, 120, 0.5), sendingVideo: true);
        seen.add(p.targetHeight);
      }
      expect(p.targetHeight, 240);
      expect(p.plan.videoMaxFps, 10);
      expect(p.plan.videoMaxBps, 150000);
      for (var i = 0; i < 14; i++) {
        p.onSample(s(70, 120, 0.5), sendingVideo: true);
      }
      expect(p.targetHeight, 180);
      expect(p.plan.videoActive, isTrue);
      for (var i = 0; i < 30; i++) {
        p.onSample(s(2500, 40, 0.1), sendingVideo: true);
      }
      expect(p.targetHeight, 480);
    });

    test('only an extreme path pauses: estimate < 40 kbit/s, or > 15 % loss', () {
      final hard = CallNetPolicy();
      final a = [for (var i = 0; i < 3; i++) hard.onSample(s(35, 200, 1), sendingVideo: true)];
      expect(a.last.paused, isTrue);
      final lossy = CallNetPolicy();
      final b = [for (var i = 0; i < 3; i++) lossy.onSample(s(900, 120, 18), sendingVideo: true)];
      expect(b.last.paused, isTrue);
      final edge = CallNetPolicy();
      final c = [for (var i = 0; i < 6; i++) edge.onSample(s(70, 650, 6), sendingVideo: true)];
      expect(c.any((x) => x.paused), isFalse, reason: 'EDGE keeps a small picture');
    });
  });

  group('ICE restart glare (Wi-Fi -> mobile data)', () {
    CallController mk(FakeCallMedia m, FakeSignaling sg, {bool outgoing = true}) => CallController(
          media: m,
          signaling: sg,
          sounds: FakeSounds(),
          video: true,
          outgoing: outgoing,
          memberId: 7,
          callId: outgoing ? null : 42,
          reconnectGrace: const Duration(milliseconds: 20),
          reconnectGiveUp: const Duration(seconds: 5),
          statusEvery: const Duration(seconds: 30),
          statsEvery: const Duration(seconds: 30),
          restartEvery: const Duration(seconds: 5),
        );

    test('an answer to an OLDER restart offer is dropped; the newest one is applied', () async {
      final m = FakeCallMedia(), sg = FakeSignaling();
      final c = mk(m, sg);
      await c.start();
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      sg.signals.clear();
      await c.restartIce();
      await c.restartIce(); // a second trigger before the first answer came
      final offers = sg.signals.where((e) => e.$1 == 'restart_offer').toList();
      expect(offers.map((e) => e.$2['rseq']), [1, 2]);
      m.log.clear();
      sg.remoteSignal('restart_answer', {'type': 'answer', 'sdp': 'v=0 old', 'rseq': 1});
      await settle();
      expect(m.log.where((l) => l.startsWith('set-answer')), isEmpty);
      expect(c.log, contains('restart_answer-stale:1'));
      sg.remoteSignal('restart_answer', {'type': 'answer', 'sdp': 'v=0 new', 'rseq': 2});
      await settle();
      expect(m.log, contains('set-answer:v=0 new'));
      // an older callee (no echo) still works
      sg.remoteSignal('restart_answer', {'type': 'answer', 'sdp': 'v=0 legacy'});
      await settle();
      expect(m.log, contains('set-answer:v=0 legacy'));
      c.dispose();
    });

    test('the callee echoes the restart number in its answer', () async {
      final m = FakeCallMedia(), sg = FakeSignaling();
      final c = mk(m, sg, outgoing: false);
      await c.start();
      await settle();
      sg.remoteSignal('offer', {'type': 'offer', 'sdp': 'v=0 A'}, from: 'caller');
      await settle();
      m.link.add(MediaLinkState.connected);
      await settle();
      sg.signals.clear();
      sg.remoteSignal('restart_offer', {'type': 'offer', 'sdp': 'v=0 R', 'rseq': 7}, from: 'caller');
      await settle();
      final ans = sg.signals.where((e) => e.$1 == 'restart_answer').toList();
      expect(ans, isNotEmpty);
      expect(ans.last.$2['rseq'], 7);
      c.dispose();
    });
  });

  test('an ICE restart is a REAL restart on Android (new credentials)', () {
    // flutter_webrtc Android ignores a top-level 'iceRestart' constraint
    // (calls2emu 44272508208: ufrag unchanged across 6 "restarts", call lost)
    final src = File('lib/calls/webrtc_media.dart').readAsStringSync();
    final i = src.indexOf('Future<Map<String, dynamic>> createOffer');
    final body = src.substring(i, src.indexOf('Future<Map<String, dynamic>> acceptOffer'));
    expect(body, contains('await _peer.restartIce()'));
    expect(body, contains("'mandatory': {'IceRestart': 'true'}"));
  });
}
