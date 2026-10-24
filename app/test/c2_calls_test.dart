// c2-calls: CallController state machine (fake peer + fake signalling),
// generated tones, the real-time transport and the call-screen states.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_sound_prefs.dart';
import 'package:assisto/calls/tone_generator.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/realtime/realtime_transport.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'c2_calls_fakes.dart';

Future<void> settle() => pumpEventQueue(times: 30);

CallController mk(FakeCallMedia m, FakeSignaling s, FakeSounds snd,
        {bool video = false, bool outgoing = true}) =>
    CallController(
      media: m,
      signaling: s,
      sounds: snd,
      video: video,
      outgoing: outgoing,
      memberId: 7,
      callId: outgoing ? null : 42,
      reconnectGrace: const Duration(milliseconds: 20),
      reconnectGiveUp: const Duration(milliseconds: 400),
      statusEvery: const Duration(seconds: 30),
      statsEvery: const Duration(seconds: 30),
      setupRetryDelays: const [Duration.zero, Duration.zero],
    );

void main() {
  group('CallController — caller', () {
    test(
        'calling -> ringing (only on callee ack) -> accepted -> connected -> hangup',
        () async {
      final m = FakeCallMedia(), s = FakeSignaling(), snd = FakeSounds();
      final c = mk(m, s, snd);
      await c.start();
      expect(c.phase, CallPhase.calling);
      expect(c.turnAvailable, isTrue);
      expect(s.eventLog, ['place:7:voice']);
      expect(m.log,
          containsAllInOrder(['open:audio', 'speaker:false', 'peer', 'offer']));
      expect(m.ice!.last['urls'], ['turn:turn.example:3478?transport=udp']);
      expect(s.signals.first.$1, 'offer');
      expect(snd.log, isNot(contains('ringback')),
          reason: 'no ringback before ringing');
      // local ICE candidates trickle to the server
      m.cands.add({
        'candidate': 'candidate:1 typ host',
        'sdpMid': '0',
        'sdpMLineIndex': 0
      });
      await settle();
      expect(s.signals.map((e) => e.$1), contains('ice'));

      s.state('ringing');
      await settle();
      expect(c.phase, CallPhase.ringing);
      expect(snd.log, contains('ringback'));

      s.state('accepted');
      await settle();
      expect(c.phase, CallPhase.accepted);
      expect(snd.log.last, 'stop-ringback');
      // a remote candidate before the answer is queued, then flushed
      s.remoteSignal('ice', {'candidate': 'cand-B'});
      await settle();
      expect(m.log, isNot(contains('cand:cand-B')));
      s.remoteSignal('answer', {'type': 'answer', 'sdp': 'v=0 B'});
      await settle();
      expect(m.log, containsAllInOrder(['set-answer:v=0 B', 'cand:cand-B']));

      // the SERVER saying "connected" never fakes it — only ICE does
      s.state('connected');
      await settle();
      expect(c.phase, CallPhase.accepted);
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      expect(c.connectedAt, isNotNull);
      expect(s.eventLog, contains('connected:relayed=false'));
      expect(snd.log, contains('proximity:true'));

      await c.hangup();
      expect(c.phase, CallPhase.ended);
      expect(c.endReason, CallEndReason.hangup);
      expect(s.eventLog.last, 'hangup');
      expect(m.disposed, isTrue);
      expect(snd.log, isNot(contains('ended')),
          reason: 'no tone on own hangup');
      expect(s.fast, 0);
      c.dispose();
    });

    test('busy at placement: busy tone, media never opened', () async {
      final m = FakeCallMedia(), snd = FakeSounds();
      final s = FakeSignaling(placeBody: {
        'allowed': true,
        'call_id': 42,
        'phase': 'ended',
        'end_reason': 'busy'
      });
      final c = mk(m, s, snd);
      await c.start();
      await settle();
      expect(c.endReason, CallEndReason.busy);
      expect(m.log, isNot(contains('open:audio')));
      expect(snd.log, contains('busy'));
      c.dispose();
    });

    test('offline at placement / declined / no answer while ringing', () async {
      for (final (reason, want, tone) in [
        ('offline', CallEndReason.offline, 'ended'),
        ('declined', CallEndReason.declined, 'declined'),
        ('no_answer', CallEndReason.noAnswer, 'ended'),
      ]) {
        final m = FakeCallMedia(), s = FakeSignaling(), snd = FakeSounds();
        final c = mk(m, s, snd);
        await c.start();
        s.state('ringing');
        await settle();
        s.state('ended', endReason: reason);
        await settle();
        expect(c.endReason, want, reason: reason);
        expect(snd.log, contains(tone), reason: reason);
        expect(snd.log, contains('stop-ringback'));
        expect(m.disposed, isTrue);
        c.dispose();
      }
    });

    test('microphone permission denied: honest error, server told "fail"',
        () async {
      final m = FakeCallMedia(openError: MediaOpenException(true));
      final s = FakeSignaling(), snd = FakeSounds();
      final c = mk(m, s, snd);
      await c.start();
      expect(c.endReason, CallEndReason.mediaDenied);
      expect(s.eventLog, contains('fail'));
      expect(c.phase, CallPhase.ended);
      c.dispose();
    });

    test(
        'server throttled -> serverBusy without placing; video gate -> upgrade',
        () async {
      final s = FakeSignaling(rtc: {'configured': true, 'throttled': true});
      final c = mk(FakeCallMedia(), s, FakeSounds());
      await c.start();
      expect(c.endReason, CallEndReason.serverBusy);
      expect(s.eventLog, isEmpty);
      c.dispose();

      final g = FakeSignaling(placeBody: {
        'allowed': false,
        'upgrade_required': true,
        'prompt': {'title': 'x'}
      });
      final v = mk(FakeCallMedia(), g, FakeSounds(), video: true);
      await v.start();
      expect(v.endReason, CallEndReason.upgrade);
      expect(v.upgradePrompt, isNotNull);
      v.dispose();
    });

    test('no TURN configured: falls back to the place() ICE and says so',
        () async {
      final s = FakeSignaling(rtc: {'configured': false, 'ice_servers': []});
      s.placeBody = {
        'allowed': true,
        'call_id': 42,
        'phase': 'calling',
        'ice': {
          'iceServers': [
            {
              'urls': ['stun:stun.example:19302']
            }
          ]
        }
      };
      final m = FakeCallMedia();
      final c = mk(m, s, FakeSounds());
      await c.start();
      expect(c.turnAvailable, isFalse);
      expect(m.ice!.single['urls'], ['stun:stun.example:19302']);
      c.dispose();
    });

    test(
        'network change: reconnecting + ICE restart offer, then connected again',
        () async {
      final m = FakeCallMedia(), s = FakeSignaling(), snd = FakeSounds();
      final c = mk(m, s, snd);
      await c.start();
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      m.link.add(MediaLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await settle();
      expect(c.phase, CallPhase.reconnecting);
      expect(s.eventLog, contains('reconnect'));
      expect(m.log, contains('offer:restart'));
      expect(s.signals.map((e) => e.$1), contains('restart_offer'));
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      c.dispose();
    });

    test('reconnect gives up -> lost (never stuck "connected")', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = mk(m, s, FakeSounds());
      await c.start();
      m.link.add(MediaLinkState.connected);
      await settle();
      m.link.add(MediaLinkState.failed);
      await settle();
      expect(c.phase, CallPhase.reconnecting);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await settle();
      expect(c.endReason, CallEndReason.lost);
      expect(s.eventLog, contains('fail'));
      c.dispose();
    });

    test(
        'ICE failed before connect -> one ICE restart, then the 20 s connect '
        'timeout fails BOTH sides as "couldn\'t connect"', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = CallController(
        media: m,
        signaling: s,
        sounds: FakeSounds(),
        video: false,
        outgoing: true,
        memberId: 7,
        statusEvery: const Duration(seconds: 30),
        connectTimeout: const Duration(milliseconds: 300),
      );
      await c.start();
      s.state('accepted');
      await settle();
      m.link.add(MediaLinkState.failed);
      await settle();
      expect(m.log, contains('offer:restart'));
      expect(c.isEnded, isFalse);
      m.link.add(MediaLinkState.failed);
      await settle();
      expect(c.isEnded, isFalse, reason: 'the timer decides, not one failure');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await settle();
      expect(c.endReason, CallEndReason.connectFailed);
      expect(s.eventLog, contains('fail'));
      c.dispose();
    });

    test('controls reach the media layer; camera off is signalled', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = mk(m, s, FakeSounds(), video: true);
      await c.start();
      expect(m.log, contains('open:video'));
      expect(c.speakerOn, isTrue, reason: 'video defaults to speaker');
      await c.toggleMute();
      await c.toggleSpeaker();
      await c.toggleCamera();
      await c.switchCamera();
      expect(
          m.log,
          containsAllInOrder(
              ['muted:true', 'speaker:false', 'camera:false', 'switch']));
      expect(s.signals.last.$1, 'media');
      expect(s.signals.last.$2, {'camera': false, 'mic': false, 'video': true});
      expect(c.frontCamera, isFalse);
      s.remoteSignal('media', {'camera': false});
      await settle();
      expect(c.remoteCameraOn, isFalse);
      c.dispose();
    });

    test('caller cancels before answer -> "cancel"', () async {
      final s = FakeSignaling();
      final c = mk(FakeCallMedia(), s, FakeSounds());
      await c.start();
      await c.hangup();
      expect(s.eventLog.last, 'cancel');
      c.dispose();
    });
  });

  group('CallController — callee', () {
    test('accept -> backlog offer -> answer -> connected', () async {
      final m = FakeCallMedia(), s = FakeSignaling(), snd = FakeSounds();
      s.backlogItems.add({
        'seq': 5,
        'topic': 'call.signal',
        'payload': {
          'call_id': 42,
          'kind': 'offer',
          'from': 'caller',
          'data': {'type': 'offer', 'sdp': 'v=0 A'}
        }
      });
      final c = mk(m, s, snd, outgoing: false);
      await c.start();
      await settle();
      expect(s.eventLog.first, 'accept:42');
      expect(c.phase, CallPhase.accepted);
      expect(m.log, contains('accept-offer:v=0 A'));
      expect(s.signals.first.$1, 'answer');
      // the same offer delivered again live is ignored (dedupe by seq)
      s.remoteSignal('offer', {'type': 'offer', 'sdp': 'v=0 A'},
          from: 'caller');
      await settle();
      expect(m.log.where((l) => l.startsWith('accept-offer')).length, 1);
      // ICE restart from the caller is answered
      s.remoteSignal('restart_offer', {'type': 'offer', 'sdp': 'v=0 R'},
          from: 'caller');
      await settle();
      expect(s.signals.map((e) => e.$1), contains('restart_answer'));
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      expect(snd.log, isNot(contains('ringback')),
          reason: 'callee never hears ringback');
      await c.hangup();
      expect(s.eventLog.last, 'hangup');
      c.dispose();
    });

    test('accepting a call that already ended: honest end, no media', () async {
      final m = FakeCallMedia();
      final s = FakeSignaling(
          acceptBody: {'phase': 'ended', 'end_reason': 'canceled'});
      final c = mk(m, s, FakeSounds(), outgoing: false);
      await c.start();
      expect(c.endReason, CallEndReason.canceled);
      expect(m.log, isNot(contains('open:audio')));
      c.dispose();
    });
  });

  group('quality + mapping', () {
    test('stats -> quality bars', () {
      expect(const MediaStats().quality, CallQuality.unknown);
      expect(
          const MediaStats(rttMs: 90, lossPct: 0.4).quality, CallQuality.good);
      expect(const MediaStats(rttMs: 350).quality, CallQuality.fair);
      expect(const MediaStats(lossPct: 12).quality, CallQuality.poor);
    });
    test('server phases / reasons', () {
      expect(phaseFromServer('calling'), CallPhase.calling);
      expect(phaseFromServer('accepted'), CallPhase.accepted);
      expect(phaseFromServer('ended'), CallPhase.ended);
      expect(endReasonFromServer('no_answer'), CallEndReason.noAnswer);
      expect(endReasonFromServer('offline'), CallEndReason.offline);
      expect(endReasonFromServer(''), CallEndReason.none);
    });
  });

  group('tones (generated in code)', () {
    double rms(Int16List p, int from, int to) {
      var s = 0.0;
      for (var i = from; i < to; i++) {
        s += p[i] * p[i].toDouble();
      }
      return to > from ? s / (to - from) : 0;
    }

    test('ringback = 425 Hz, 1 s on / 4 s off, looped', () {
      final t = ToneGenerator.ringback();
      expect(t.sampleRate, 16000);
      expect(t.loop, isTrue);
      expect(t.pcm.length, 5 * 16000);
      expect(rms(t.pcm, 1000, 15000), greaterThan(1e6));
      expect(rms(t.pcm, 16100, 80000), 0);
      // zero crossings in the first second ~ 2 x 425
      var zc = 0;
      for (var i = 1; i < 16000; i++) {
        if ((t.pcm[i - 1] < 0) != (t.pcm[i] < 0)) zc++;
      }
      expect(zc, inInclusiveRange(840, 860));
    });

    test('busy 4 x 0.5/0.5, declined 3 x 0.25/0.25, ended short', () {
      final b = ToneGenerator.busy();
      expect(b.pcm.length, 4 * 16000);
      expect(rms(b.pcm, 100, 7900), greaterThan(1e6));
      expect(rms(b.pcm, 8100, 15900), 0);
      expect(ToneGenerator.declined().pcm.length, (1.5 * 16000).round());
      expect(ToneGenerator.ended().duration.inMilliseconds, lessThan(800));
    });

    test('signature melody: original score, bounded, loopable WAV', () {
      final s = ToneGenerator.signature();
      expect(s.loop, isTrue);
      expect(s.sampleRate, 22050);
      expect(s.duration.inMilliseconds, inInclusiveRange(4000, 8000));
      expect(s.pcm.reduce((a, b) => a.abs() > b.abs() ? a : b).abs(),
          lessThan(32767));
      final wav = ToneGenerator.wav(s);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(wav.length, 44 + s.pcm.length * 2);
    });
  });

  group('sound prefs', () {
    test('per-contact > Assisto melody > picked > phone default', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await SharedPreferences.getInstance();
      expect(CallSoundPrefs.resolveRingtone(p, '9'), isNull);
      await p.setString(CallSoundPrefs.callUri, 'content://r/1');
      expect(CallSoundPrefs.resolveRingtone(p, '9'), 'content://r/1');
      await p.setBool(CallSoundPrefs.signature, true);
      await p.setString(CallSoundPrefs.signatureUri, 'content://assisto');
      expect(CallSoundPrefs.resolveRingtone(p, '9'), 'content://assisto');
      await p.setString(CallSoundPrefs.contactUri('9'), 'content://mom');
      expect(CallSoundPrefs.resolveRingtone(p, '9'), 'content://mom');
      expect(CallSoundPrefs.resolveRingtone(p, '8'), 'content://assisto');
      expect(CallSoundPrefs.channelIdFor(null), 'calls');
      expect(CallSoundPrefs.channelIdFor('content://mom'),
          CallSoundPrefs.channelIdFor('content://mom'));
      expect(
          CallSoundPrefs.channelIdFor('content://mom'), startsWith('calls_'));
    });
  });

  group('PollRealtimeTransport', () {
    test('primes the sequence, then delivers new events in order, topic filter',
        () async {
      final paths = <String>[];
      var round = 0;
      final t = PollRealtimeTransport(
        get: (p) async {
          paths.add(p);
          round++;
          if (round == 1) {
            return {
              'events': [
                {'seq': 3, 'topic': 'call.state', 'payload': {}}
              ],
              'seq': 3
            };
          }
          if (round == 2) {
            return {
              'events': [
                {
                  'seq': 4,
                  'topic': 'call.signal',
                  'payload': {'call_id': 1}
                },
                {'seq': 5, 'topic': 'typing.update', 'payload': {}},
              ],
              'seq': 5
            };
          }
          return {'events': [], 'seq': 5};
        },
        post: (p, b) async => {'ok': true, 'path': p, ...b},
        fastInterval: const Duration(milliseconds: 5),
        idleInterval: const Duration(milliseconds: 5),
      );
      final got = <RealtimeEvent>[];
      t.events.listen(got.add);
      t.subscribe('call');
      await t.connect();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(got.map((e) => e.seq), [4, 5], reason: 'old seq 3 not replayed');
      expect(paths.first, '/rt/events?after=0&topics=call');
      expect(paths[1], '/rt/events?after=3&topics=call');
      expect(t.seq, 5);
      expect(t.connected.value, isTrue);
      final r = await t.send('call.signal', {'call_id': 1});
      expect(r['path'], '/rt/send');
      expect(r['topic'], 'call.signal');
      await t.close();
    });

    test('errors back off and flag disconnected; pause stops polling',
        () async {
      var n = 0;
      final t = PollRealtimeTransport(
        get: (p) async {
          n++;
          throw Exception('offline');
        },
        post: (p, b) async => {},
        idleInterval: const Duration(milliseconds: 5),
      );
      await t.connect();
      expect(t.connected.value, isFalse);
      expect(t.currentInterval.inMilliseconds, 500);
      t.setPaused(true);
      final before = n;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(n, before);
      await t.close();
    });
  });

  group('call screen states', () {
    Future<void> pump(WidgetTester tester, CallController c,
        {String lang = 'en', bool video = false, bool outgoing = true}) async {
      await tester.pumpWidget(MaterialApp(
        locale: Locale(lang),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: CircleCallScreen(
          key: ObjectKey(c),
          member: const {'id': 7, 'name': 'Nadia'},
          kind: video ? 'video' : 'voice',
          outgoing: outgoing,
          controller: c,
          surface: video ? FakeSurface() : null,
        ),
      ));
      await tester.pump();
    }

    testWidgets('calling / ringing / connected timer / ended reasons',
        (tester) async {
      final t = lookupAppLocalizations(const Locale('en'));
      final c = previewController(
          video: false, outgoing: true, phase: CallPhase.calling);
      await pump(tester, c);
      expect(find.text(t.c2CallCalling), findsOneWidget);
      expect(find.byKey(const Key('call-hangup')), findsOneWidget);
      await pump(
          tester,
          previewController(
              video: false, outgoing: true, phase: CallPhase.ringing));
      expect(find.text(t.c2CallRinging), findsOneWidget);
      await pump(
          tester,
          previewController(
              video: false, outgoing: true, phase: CallPhase.connected));
      expect(find.text('04:07'), findsOneWidget);
      expect(find.byKey(const Key('call-quality-good')), findsOneWidget);
      for (final (r, label) in [
        (CallEndReason.busy, t.c2CallBusy),
        (CallEndReason.noAnswer, t.c2CallNoAnswer),
        (CallEndReason.declined, t.c2CallDeclined),
        (CallEndReason.offline, t.c2CallOffline),
        (CallEndReason.failed, t.c2CallFailedMedia),
      ]) {
        final e = previewController(
            video: false, outgoing: true, phase: CallPhase.ended, reason: r);
        await pump(tester, e);
        expect(find.text(label), findsOneWidget, reason: '$r');
        expect(find.byKey(const Key('call-again')), findsOneWidget);
        expect(find.byKey(const Key('call-hangup')), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no fake "connected" button exists; no-relay note is honest',
        (tester) async {
      final t = lookupAppLocalizations(const Locale('en'));
      final c = previewController(
          video: false, outgoing: true, phase: CallPhase.ringing, turn: false);
      await pump(tester, c);
      expect(find.byKey(const Key('call-no-relay')), findsOneWidget);
      expect(find.text(t.circleCallRelayConnected), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('video controls + Bangla labels fit at 360 px / 1.5x',
        (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final c = previewController(
          video: true, outgoing: true, phase: CallPhase.connected);
      await pump(tester, c, lang: 'bn', video: true);
      for (final k in [
        'call-speaker',
        'call-camera',
        'call-flip',
        'call-mute'
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('call-mute')));
      await tester.pump();
      expect(c.muted, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
