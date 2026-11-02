// audioroute policy tests (owner 28 Oct: Bluetooth / wired earphones must
// work everywhere, exactly like WhatsApp). A fake platform stands in for
// AudioRouteChannel.kt — the CI emulator has no Bluetooth, so THIS is where
// "headset present => headset route" is proven (the gap that let the bug
// ship: no test ever asserted it).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/audio/audio_route_service.dart';
import 'package:assisto/calls/call_controller.dart';

import 'c2_calls_fakes.dart';

class FakeRoutePlatform implements AudioRoutePlatform {
  FakeRoutePlatform({List<AudioOutput>? outs, this.permitted = true})
      : outs = outs ?? [phone, speaker];

  static const phone = AudioOutput(AudioRoute.earpiece);
  static const speaker = AudioOutput(AudioRoute.speaker);
  static const buds = AudioOutput(AudioRoute.bluetooth, name: 'AirPods Pro', id: 7);
  static const wired = AudioOutput(AudioRoute.wired, name: 'USB-C', id: 9);

  List<AudioOutput> outs;
  bool permitted;
  bool owner = true;
  bool commOpen = false;
  AudioRoute? selected;
  int restores = 0;
  int begins = 0;
  final calls = <String>[];
  final ctl = StreamController<void>.broadcast();

  void connect(AudioOutput o) {
    outs = [...outs, o];
    ctl.add(null);
  }

  void disconnect(AudioRoute r) {
    outs = outs.where((o) => o.route != r).toList();
    ctl.add(null);
  }

  @override
  Future<bool> beginCommunication() async {
    begins++;
    commOpen = true;
    calls.add('begin');
    return owner;
  }

  @override
  Future<List<AudioOutput>> outputs() async => List.of(outs);
  @override
  Future<AudioRoute?> active() async => selected;
  @override
  Future<bool> select(AudioOutput o) async {
    selected = o.route;
    calls.add('select:${o.route.name}');
    return true;
  }

  @override
  Future<void> restore() async {
    restores++;
    commOpen = false;
    selected = null;
    calls.add('restore');
  }

  @override
  Future<bool> bluetoothPermitted() async => permitted;
  @override
  Future<bool> bluetoothPresent() async =>
      outs.any((o) => o.route == AudioRoute.bluetooth);
  @override
  Stream<void> get changes => ctl.stream;
}

Future<void> settle() => pumpEventQueue(times: 30);

void main() {
  late FakeRoutePlatform p;
  late AudioRouteService s;

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    p = FakeRoutePlatform();
    s = AudioRouteService(p, stalePrefs: false);
  });

  group('headset present => headset route (the owner bug)', () {
    test('voice call + Bluetooth => Bluetooth, NOT the earpiece', () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      await s.beginCall(video: false);
      expect(p.selected, AudioRoute.bluetooth);
      expect(s.active, AudioRoute.bluetooth);
      expect(s.bluetoothName, 'AirPods Pro');
      expect(p.commOpen, isTrue, reason: 'communication mode for BT mic');
    });

    test('video call + Bluetooth => Bluetooth, NOT the loudspeaker', () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      await s.beginCall(video: true);
      expect(p.selected, AudioRoute.bluetooth);
    });

    test('voice call + wired (3.5 mm / USB-C) => wired', () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.wired];
      await s.beginCall(video: false);
      expect(p.selected, AudioRoute.wired);
    });

    test('video call + wired => wired, not the speaker', () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.wired];
      await s.beginCall(video: true);
      expect(p.selected, AudioRoute.wired);
    });

    test('Bluetooth beats wired when both are connected', () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.wired, FakeRoutePlatform.buds];
      await s.beginCall(video: false);
      expect(p.selected, AudioRoute.bluetooth);
    });

    test('no headset: voice => earpiece, video => speaker', () async {
      await s.beginCall(video: false);
      expect(p.selected, AudioRoute.earpiece);
      await s.endCall();
      await s.beginCall(video: true);
      expect(p.selected, AudioRoute.speaker);
    });

    test('tablet without an earpiece: voice call => speaker', () async {
      p.outs = [FakeRoutePlatform.speaker];
      await s.beginCall(video: false);
      expect(p.selected, AudioRoute.speaker);
    });
  });

  group('live switch mid-call (never drop the call)', () {
    test('Bluetooth connects mid-call => switches to it', () async {
      await s.beginCall(video: false);
      expect(p.selected, AudioRoute.earpiece);
      p.connect(FakeRoutePlatform.buds);
      await settle();
      expect(p.selected, AudioRoute.bluetooth);
      expect(p.begins, 1, reason: 'no second session / media reopen');
      expect(p.restores, 0);
    });

    test('Bluetooth disconnects mid-call => voice falls back to earpiece',
        () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      await s.beginCall(video: false);
      p.disconnect(AudioRoute.bluetooth);
      await settle();
      expect(p.selected, AudioRoute.earpiece);
      expect(s.inCall, isTrue);
      expect(p.restores, 0);
    });

    test('wired unplugged in a video call => speaker', () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.wired];
      await s.beginCall(video: true);
      p.disconnect(AudioRoute.wired);
      await settle();
      expect(p.selected, AudioRoute.speaker);
    });

    test('routeChanges stream reports every switch', () async {
      final seen = <AudioRoute>[];
      final sub = s.routeChanges.listen(seen.add);
      await s.beginCall(video: false);
      p.connect(FakeRoutePlatform.wired);
      await settle();
      p.disconnect(AudioRoute.wired);
      await settle();
      expect(seen, [AudioRoute.earpiece, AudioRoute.wired, AudioRoute.earpiece]);
      await sub.cancel();
    });

    test('voice -> video moves earpiece to speaker; headset stays', () async {
      await s.beginCall(video: false);
      await s.setVideo(true);
      expect(p.selected, AudioRoute.speaker);
      p.connect(FakeRoutePlatform.buds);
      await settle();
      await s.setVideo(false);
      expect(p.selected, AudioRoute.bluetooth);
    });
  });

  group('user override', () {
    test('picking speaker with buds connected sticks across changes',
        () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      await s.beginCall(video: false);
      await s.select(AudioRoute.speaker);
      expect(p.selected, AudioRoute.speaker);
      // an unrelated change (wired plugged then unplugged) keeps the pick
      p.connect(FakeRoutePlatform.wired);
      await settle();
      // (a NEW headset connecting takes over, like the phone's dialer)
      expect(p.selected, AudioRoute.wired);
      await s.select(AudioRoute.speaker);
      p.disconnect(AudioRoute.wired);
      await settle();
      expect(p.selected, AudioRoute.speaker, reason: 'pick sticks');
    });

    test('picked device disappears => policy fallback', () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      await s.beginCall(video: false);
      await s.select(AudioRoute.bluetooth);
      p.disconnect(AudioRoute.bluetooth);
      await settle();
      expect(p.selected, AudioRoute.earpiece);
    });

    test('a pick is forgotten when the call ends', () async {
      await s.beginCall(video: false);
      await s.select(AudioRoute.speaker);
      await s.endCall();
      await s.beginCall(video: false);
      expect(p.selected, AudioRoute.earpiece);
    });
  });

  group('Nearby devices permission (Android 12+)', () {
    test('asked only when a Bluetooth device is present', () async {
      var asked = 0;
      p.permitted = false;
      s.askBluetooth = () async {
        asked++;
        return true;
      };
      await s.beginCall(video: false);
      expect(asked, 0, reason: 'no Bluetooth device: never asked');
      await s.endCall();
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      await s.beginCall(video: false);
      expect(asked, 1);
      expect(p.selected, AudioRoute.bluetooth);
    });

    test('refused => call stays on the earpiece, honest flag set', () async {
      p.permitted = false;
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      s.askBluetooth = () async => false;
      await s.beginCall(video: false);
      expect(s.bluetoothDenied, isTrue);
      expect(p.selected, AudioRoute.earpiece);
      expect(s.inCall, isTrue);
    });

    test('never asked twice in one session unless Bluetooth is tapped',
        () async {
      var asked = 0;
      p.permitted = false;
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      s.askBluetooth = () async {
        asked++;
        return false;
      };
      await s.beginCall(video: false);
      p.disconnect(AudioRoute.bluetooth);
      await settle();
      p.connect(FakeRoutePlatform.buds);
      await settle();
      expect(asked, 1);
      await s.select(AudioRoute.bluetooth);
      expect(asked, 2, reason: 'the user tapped Bluetooth: ask again');
    });
  });

  group('restore: music never stuck after a call', () {
    test('endCall restores normal audio', () async {
      await s.beginCall(video: false);
      await s.endCall();
      expect(p.restores, 1);
      expect(p.commOpen, isFalse);
      expect(s.active, isNull);
    });

    test('restore is idempotent', () async {
      await s.restore();
      await s.restore();
      await s.endCall();
      expect(s.inCall, isFalse);
    });

    test('playback after a leftover session clears call mode first',
        () async {
      await s.beginCall(video: false);
      s.inCall = false; // a crashed call path that never ended
      await s.preparePlayback(AudioUse.voiceNotePlay);
      expect(p.restores, 1);
    });

    test('playback never forces a route when nothing is open', () async {
      await s.preparePlayback(AudioUse.media);
      await s.preparePlayback(AudioUse.assistantSpeak);
      expect(p.calls, isEmpty);
    });

    test('playback during a call leaves the call alone', () async {
      await s.beginCall(video: false);
      await s.preparePlayback(AudioUse.voiceNotePlay);
      expect(p.restores, 0);
    });
  });

  group('microphone users (voice notes, assistant, kids watch)', () {
    test('Bluetooth connected => headset mic session, restored on release',
        () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      final l = await s.acquire(AudioUse.voiceNoteRecord);
      expect(p.commOpen, isTrue);
      expect(p.selected, AudioRoute.bluetooth);
      await l.release();
      expect(p.restores, 1);
      expect(s.activeUses, isEmpty);
    });

    test('no Bluetooth => nothing forced (phone / wired mic as usual)',
        () async {
      final l = await s.acquire(AudioUse.assistantListen);
      expect(p.begins, 0);
      await l.release();
      expect(p.restores, 0);
    });

    test('recording during a call never ends the call routing', () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      await s.beginCall(video: false);
      final l = await s.acquire(AudioUse.voiceNoteRecord);
      await l.release();
      expect(p.restores, 0);
      expect(p.selected, AudioRoute.bluetooth);
    });

    test('MicRouteHold start/stop is race-safe', () async {
      p.outs = [FakeRoutePlatform.phone, FakeRoutePlatform.speaker, FakeRoutePlatform.buds];
      final h = MicRouteHold(AudioUse.kidsWatchRecord, service: s);
      h.start();
      h.stop();
      h.start();
      await settle();
      expect(s.activeUses, [AudioUse.kidsWatchRecord]);
      h.stop();
      await settle();
      expect(s.activeUses, isEmpty);
      expect(p.commOpen, isFalse);
    });
  });

  group('call controller follows the route service', () {
    test('headset connect/disconnect mid-call: route follows, media not '
        'reopened, call not dropped', () async {
      final m = FakeCallMedia(), sig = FakeSignaling();
      final c = CallController(
        media: m,
        signaling: sig,
        sounds: FakeSounds(),
        video: false,
        outgoing: true,
        memberId: 1,
        setupRetryDelays: const [],
      );
      await c.start();
      await settle();
      expect(m.log.where((l) => l.startsWith('speaker:')), isEmpty,
          reason: 'ROOT CAUSE: never force speaker/earpiece after open');
      m.routeCtl.add(AudioRoute.bluetooth);
      await settle();
      expect(c.route, AudioRoute.bluetooth);
      expect(c.speakerOn, isFalse);
      m.routeCtl.add(AudioRoute.earpiece);
      await settle();
      expect(c.route, AudioRoute.earpiece);
      expect(m.log.where((l) => l.startsWith('open:')).length, 1);
      expect(c.isEnded, isFalse);
      await c.hangup();
      expect(m.disposed, isTrue, reason: 'dispose => AudioRouteService.endCall');
      c.dispose();
    });

    test('speaker off with a headset goes back to the headset', () async {
      final m = FakeCallMedia()
            ..routeList = const [
              AudioRoute.earpiece,
              AudioRoute.speaker,
              AudioRoute.bluetooth
            ],
          sig = FakeSignaling();
      final c = CallController(
        media: m,
        signaling: sig,
        sounds: FakeSounds(),
        video: false,
        outgoing: true,
        memberId: 1,
        setupRetryDelays: const [],
      );
      await c.start();
      await c.refreshRoutes();
      await c.toggleSpeaker();
      expect(c.route, AudioRoute.speaker);
      await c.toggleSpeaker();
      expect(c.route, AudioRoute.bluetooth);
      c.dispose();
    });

    test('every end path disposes media (=> restore)', () async {
      for (final end in ['hangup', 'remote', 'fail']) {
        final m = FakeCallMedia(), sig = FakeSignaling();
        final c = CallController(
          media: m,
          signaling: sig,
          sounds: FakeSounds(),
          video: false,
          outgoing: true,
          memberId: 1,
          setupRetryDelays: const [],
        );
        await c.start();
        if (end == 'hangup') {
          await c.hangup();
        } else if (end == 'remote') {
          sig.state('ended', endReason: 'hangup');
          await settle();
          if (!c.isEnded) await c.hangup();
        } else {
          m.link.add(MediaLinkState.failed);
          await settle();
          if (!c.isEnded) await c.hangup();
        }
        expect(m.disposed, isTrue, reason: end);
        c.dispose();
      }
      // media open refused (mic denied) also releases
      final m = FakeCallMedia(openError: MediaOpenException(true));
      final c = CallController(
        media: m,
        signaling: FakeSignaling(),
        sounds: FakeSounds(),
        video: false,
        outgoing: true,
        memberId: 1,
        setupRetryDelays: const [],
      );
      await c.start();
      expect(c.isEnded, isTrue);
      expect(m.disposed, isTrue);
      c.dispose();
    });
  });
}
