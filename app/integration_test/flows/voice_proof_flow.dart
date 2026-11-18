// voice-proof (18 Nov): "Hey Assisto" + voice/text actions on a REAL
// Android emulator, through its VIRTUAL MICROPHONE (opt-in group
// 'voiceproof', .github/workflows/voice-emu.yml).
//
// The CI host feeds WAV clips into the emulator's mic (PulseAudio null sink
// -> emulator -allow-host-audio): the app prints `REALITY_AUDIO <clip> <ack>`,
// tools/voiceproof/emu_audio.sh plays <clip> and writes <ack> (with a small
// JSON answer for probes). Nothing here fakes the microphone, the wake-word
// engine or the model: it is the shipped Kotlin service + the model the
// in-runner server serves.
//
// Results (numbers only, no audio) -> <ext files>/reality/voiceproof_<flow>.json,
// pulled by run_flows.sh; tools/voiceproof/report.py turns them into the
// true-accept / false-accept / CPU table.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/push/push_service.dart' show appNavigatorKey;
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/screens/journey_sos_screen.dart';
import 'package:assisto/screens/safe_journey/sj_hub_screen.dart';
import 'package:assisto/screens/voice_assistant_screen.dart';
import 'package:assisto/screens/watchman/watchman_screen.dart';
import 'package:assisto/voice/va_native.dart';

import '../support/harness.dart';

final Map<String, dynamic> _out = {'wake_true': [], 'wake_false': {}, 'actions': []};

Future<void> _save(RFlow f) async {
  await f.net(() async {
    final d = await f.h.outDir();
    // one file per flow: a retried group (emulator restart) never loses an
    // earlier flow's numbers; tools/voiceproof/report.py merges them
    await File('${d.path}/voiceproof_${f.r.id}.json').writeAsString(jsonEncode(_out));
  });
}

/// Ask the CI host to play [clip] into the emulator's microphone (or run a
/// probe); returns the host's answer (JSON text, may be empty).
Future<String> _host(RFlow f, String clip,
    {Duration max = const Duration(seconds: 40), Future<void> Function()? tick}) async {
  final d = await f.net(() => f.h.outDir());
  final name = 'vp_${clip}_${DateTime.now().millisecondsSinceEpoch}';
  final ack = File('${d.path}/acks/$name');
  // ignore: avoid_print
  print('REALITY_AUDIO $clip $name');
  final end = DateTime.now().add(max);
  var n = 0;
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    if (tick != null && (n++ % 2 == 0)) await tick();
    if (await f.tester.runAsync(() => ack.exists()) == true) {
      return (await f.net(() => ack.readAsString())).trim();
    }
  }
  throw TestFailure('the CI host never answered REALITY_AUDIO $clip');
}

Future<Map<String, dynamic>> _st(RFlow f) async {
  final m = await f.net(() => VaNative.wakeStatus());
  return {for (final e in (m ?? const {}).entries) '${e.key}': e.value};
}

int _wakes(Map<String, dynamic> s) => (s['wakes'] as num?)?.toInt() ?? 0;

/// Close an Assisto Voice screen a wake opened (like the user saying nothing).
Future<bool> _closeVoice(RFlow f) async {
  final v = find.byType(VoiceAssistantScreen);
  if (v.evaluate().isEmpty) return false;
  try {
    await Navigator.of(f.tester.element(v.first)).maybePop();
  } catch (_) {}
  await f.tester.pump(const Duration(milliseconds: 600));
  return true;
}

/// Wait until the service listens again (after a wake it pauses ~6 s).
Future<bool> _listening(RFlow f, {int seconds = 20}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    final s = await _st(f);
    if (s['state'] == 'listening') return true;
    await f.pumpFor(const Duration(milliseconds: 700));
  }
  return false;
}

List<String> _clips(String prefix, String manifest) => [
      for (final l in const LineSplitter().convert(manifest))
        if (l.trim().startsWith(prefix)) l.trim()
    ];

/// Open Assisto Voice fresh and switch to typing.
Future<void> _openVoiceTyping(RFlow f) async {
  await f.backToHome();
  await f.openRoute('voice_assistant', settleSeconds: 3);
  if (await f.appears(find.byKey(const Key('perm-reason-no')), seconds: 2)) {
    await f.tap(find.byKey(const Key('perm-reason-no')), settleSeconds: 1);
  }
  final type = find.byTooltip(f.t.vaTypeInstead);
  await f.waitFor(type, what: '"Type instead"');
  await f.tap(type);
}

Future<void> _say(RFlow f, String text) async {
  await f.enter(text, label: f.t.vaTypeHint);
  await f.tap(find.byTooltip(f.t.vaSend), settleSeconds: 3);
}

Future<Map<String, dynamic>?> _member(RFlow f, String name) async {
  final api = await f.h.backend();
  final r = await f.net(() => api.getJson('/circle/members'));
  for (final m in ((r['results'] ?? r['members'] ?? const []) as List)) {
    if (m is Map && '${m['name']}'.contains(name)) return m.cast<String, dynamic>();
  }
  return null;
}

bool _posted(RFlow f, int mark, String part) => f.h.recorder.hits
    .skip(mark)
    .any((x) => x.method == 'POST' && x.path.contains(part) && x.status < 300);

void registerVoiceProofFlows() {
  // ---------------------------------------------------------------- wake ON
  realityFlow('vp1_wake_on', 'Voice', '"Hey Assisto": user turns it on (disclosure), notification shows, mic hears', (f) async {
    await f.home();
    await f.step('Settings > Voice: turn "Hey Assisto" on (disclosure first)', () async {
      await f.openRoute('voice_settings', settleSeconds: 3);
      final sw = find.byKey(const Key('va-wake-switch'));
      await f.scrollToBuilt(sw, what: 'the Hey Assisto switch');
      await f.shot('settings-before');
      await f.tap(sw, settleSeconds: 2);
      if (await f.appears(find.text(f.t.vaWkDiscAgree), seconds: 6)) {
        await f.shot('disclosure');
        await f.tap(find.text(f.t.vaWkDiscAgree), settleSeconds: 2);
      }
      final end = DateTime.now().add(const Duration(seconds: 90));
      Map<String, dynamic> s = {};
      while (DateTime.now().isBefore(end)) {
        s = await _st(f);
        if (s['state'] == 'listening') break;
        await f.pumpFor(const Duration(seconds: 1));
      }
      _out['status_on'] = s;
      if (s['state'] != 'listening') throw TestFailure('wake service not listening: $s');
      await f.shot('settings-listening');
    });
    await f.step('the "listening" notification is visible (never hidden listening)', () async {
      final r = await _host(f, 'probe_notif');
      _out['notif_on'] = r;
      if (!r.contains('"wake_notif": true')) throw TestFailure('no visible wake notification: $r');
    });
    await f.step('the virtual mic reaches the engine (calibration tone)', () async {
      await _host(f, 'cal_tone');
      final s = await _st(f);
      _out['cal_peak_db'] = s['peakDb'];
      final db = (s['peakDb'] as num?)?.toDouble() ?? -120;
      if (db < -50) throw TestFailure('the engine hears nothing from the emulator mic (peak $db dBFS)');
    });
    await _save(f);
  }, timeout: const Duration(minutes: 5));

  // ------------------------------------------------------ true accepts
  realityFlow('vp2_wake_true', 'Voice', '"Hey Assisto" clips (held-out BD-accent TTS + far/noisy): true-accept rate', (f) async {
    final manifest = await _host(f, 'probe_manifest');
    final pos = _clips('pos_', manifest);
    if (pos.isEmpty) throw TestFailure('no positive clips on the host');
    var hit = 0, opened = 0;
    await f.step('play ${pos.length} wake clips through the mic', () async {
      for (final clip in pos) {
        await _listening(f);
        final before = _wakes(await _st(f));
        final t0 = DateTime.now();
        await _host(f, clip);
        var got = false;
        final end = DateTime.now().add(const Duration(milliseconds: 2500));
        while (DateTime.now().isBefore(end)) {
          if (_wakes(await _st(f)) > before) {
            got = true;
            break;
          }
          await f.tester.pump(const Duration(milliseconds: 200));
        }
        var screen = false;
        if (got) {
          hit++;
          // end-to-end: the wake opens the Assisto Voice screen
          screen = await f.appears(find.byType(VoiceAssistantScreen), seconds: 5);
          if (screen) {
            opened++;
            if (opened == 1) await f.shot('wake-opened-voice');
          }
          await _closeVoice(f);
        }
        final s = await _st(f);
        (_out['wake_true'] as List).add({
          'clip': clip, 'detected': got, 'screen': screen,
          'score': s['lastScore'], 'peakDb': s['peakDb'],
          'ms': DateTime.now().difference(t0).inMilliseconds,
        });
      }
    });
    _out['wake_true_summary'] = {'clips': pos.length, 'detected': hit, 'screen_opened': opened};
    f.note('true accepts $hit/${pos.length}; voice screen opened $opened');
    await _save(f);
  }, timeout: const Duration(minutes: 25));

  // ------------------------------------------------------ false accepts + CPU
  realityFlow('vp3_wake_false', 'Voice', '~30 min of Bangla/English speech, TV, music, noise: false wakes + CPU/battery', (f) async {
    var opened = 0;
    await f.step('play the long non-wake audio; count every wake', () async {
      await _listening(f);
      final before = _wakes(await _st(f));
      final host = await _host(f, 'neg_long', max: const Duration(minutes: 42), tick: () async {
        if (await _closeVoice(f)) opened++;
      });
      final after = _wakes(await _st(f));
      _out['wake_false'] = {'false_wakes': after - before, 'screens': opened, 'host': host};
      f.note('false wakes ${after - before} in the long negative audio');
    });
    await _save(f);
  }, timeout: const Duration(minutes: 45));

  // ------------------------------------------------------ wake OFF
  realityFlow('vp4_wake_off', 'Voice', 'Turn "Hey Assisto" off: notification gone, mic released', (f) async {
    await f.home();
    await f.step('Settings > Voice: switch off', () async {
      await f.openRoute('voice_settings', settleSeconds: 3);
      final sw = find.byKey(const Key('va-wake-switch'));
      await f.scrollToBuilt(sw, what: 'the Hey Assisto switch');
      await f.tap(sw, settleSeconds: 3);
      final s = await _st(f);
      _out['status_off'] = s;
      if (s['state'] == 'listening' || s['state'] == 'paused') {
        throw TestFailure('still running after off: $s');
      }
      await f.shot('settings-off');
    });
    await f.step('no wake notification and no recording by Assisto', () async {
      await f.pumpFor(const Duration(seconds: 3));
      final r = await _host(f, 'probe_notif');
      _out['notif_off'] = r;
      if (r.contains('"wake_notif": true')) throw TestFailure('notification still shown: $r');
      if (r.contains('"app_recording": true')) throw TestFailure('the mic is still recording: $r');
    });
    await _save(f);
  }, timeout: const Duration(minutes: 4));

  // ------------------------------------------------------ 8 actions by text
  final textCmds = <(String, String)>[
    ('call', 'call karim'),
    ('circle_message', 'message karim on my circle i have reached home'),
    ('reminder', 'remind me to pay the electricity bill tomorrow at 9 am'),
    ('expense', 'spent 250 taka on rickshaw'),
    ('safe_journey', 'start safe journey to Mirpur'),
    ('sos', 'help me i am in danger'),
    ('cctv', 'open cctv'),
    ('ask_ai', 'how do I keep my bKash account safe from scammers'),
    ('call', 'করিমকে কল দাও'),
    ('circle_message', 'সার্কেলে করিমকে লেখো আমি বাসায় পৌঁছেছি'),
    ('reminder', 'কাল সকাল ৯টায় বিদ্যুৎ বিল দেওয়ার কথা মনে করিয়ে দিও'),
    ('expense', 'রিকশায় ২৫০ টাকা খরচ'),
    ('safe_journey', 'নিরাপদ যাত্রা শুরু করো'),
    ('sos', 'আমাকে বাঁচাও'),
    ('cctv', 'সিসিটিভি খোলো'),
    ('ask_ai', 'বিকাশ অ্যাকাউন্ট নিরাপদ রাখব কীভাবে'),
  ];
  for (var k = 0; k < textCmds.length; k++) {
    final (kind, text) = textCmds[k];
    final lang = k < 8 ? 'en' : 'bn';
    realityFlow('vp5_text_${lang}_$kind', 'Voice', 'Typed action ($lang): $kind', (f) async {
      await f.home();
      await f.step('Assisto Voice: type "$kind" command', () async {
        await _openVoiceTyping(f);
        final mark = f.httpMark;
        await _say(f, text);
        try {
          await _act(f, kind, mark, 'text_$lang');
        } catch (e) {
          (_out['actions'] as List).add({'mode': 'text_$lang', 'kind': kind, 'ok': false,
              'why': '$e'.split('\n').first});
          await _save(f);
          rethrow;
        }
      });
      await _save(f);
    }, timeout: const Duration(minutes: 4));
  }

  // ------------------------------------------------------ 8 actions by Bangla speech
  realityFlow('vp6_speech_bn', 'Voice', 'Spoken Bangla commands through the mic (server speech-to-text in CI)', (f) async {
    final manifest = await _host(f, 'probe_manifest');
    final cmds = _clips('cmd_', manifest);
    for (final clip in cmds) {
      // cmd_<kind>_<engine>... ; kind is before the first double underscore
      final kind = clip.substring(4).split('__').first;
      await f.step('say "$kind" (clip $clip)', () async {
        await f.backToHome();
        final mark = f.httpMark;
        await f.openRoute('voice_assistant', settleSeconds: 2);
        if (await f.appears(find.byKey(const Key('perm-reason-yes')), seconds: 2)) {
          await f.tap(find.byKey(const Key('perm-reason-yes')), settleSeconds: 1);
        }
        await f.pumpFor(const Duration(milliseconds: 1200)); // recording started
        await _host(f, clip);
        // end-of-speech -> upload -> words -> action
        final end = DateTime.now().add(const Duration(seconds: 60));
        while (DateTime.now().isBefore(end)) {
          await f.tester.pump(const Duration(milliseconds: 400));
          if (f.h.recorder.hits.skip(mark).any((x) => x.path.contains('/voice/transcribe'))) break;
        }
        final tr = f.h.recorder.hits.skip(mark).where((x) => x.path.contains('/voice/transcribe')).toList();
        await f.pumpFor(const Duration(seconds: 3));
        final heard = _heardText(f);
        try {
          if (tr.isEmpty) throw TestFailure('no speech-to-text call (recording never ended?)');
          if (tr.every((x) => x.status >= 300)) {
            throw TestFailure('speech-to-text answered ${tr.map((x) => x.status).toList()}');
          }
          await _act(f, kind, mark, 'speech_bn', heard: heard);
        } catch (e) {
          appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
          (_out['actions'] as List).add({'mode': 'speech_bn', 'kind': kind, 'clip': clip,
              'ok': false, 'heard': heard, 'why': '$e'.split('\n').first});
          await f.shot('speech-$kind-miss');
        }
      });
    }
    await _save(f);
  }, timeout: const Duration(minutes: 20));
}

/// The user's own words as shown on the voice screen (first user bubble).
String _heardText(RFlow f) {
  final texts = find
      .descendant(of: find.byType(VoiceAssistantScreen), matching: find.byType(Text))
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '')
      .where((s) => s.trim().isNotEmpty)
      .toList();
  return texts.take(6).join(' | ');
}

/// Check the expected result for [kind]; confirm steps are verified FIRST,
/// money / safety actions only run after the confirm tap; SOS is cancelled in
/// its countdown (never sent).
Future<void> _act(RFlow f, String kind, int mark, String mode, {String heard = ''}) async {
  final t = f.t;
  final row = <String, dynamic>{'mode': mode, 'kind': kind, 'heard': heard};
  Future<void> ok(String what) async {
    row['ok'] = true;
    row['result'] = what;
    (_out['actions'] as List).add(row);
    await f.shot('$mode-$kind');
  }

  switch (kind) {
    case 'call':
      final karim = await _member(f, 'Karim');
      await f.waitFor(find.text(t.vaConfirmCallTitle('${karim?['name'] ?? 'Reality Karim'}')),
          what: 'the call confirm card (My Circle person)');
      await f.waitFor(find.text(t.vaCircleCallLabel), what: 'the "free Assisto call" label');
      row['confirm_card'] = true;
      if (_posted(f, mark, '/call')) throw TestFailure('a call was placed BEFORE the confirm tap');
      await f.shot('$mode-call-confirm');
      await f.tap(find.text(t.vaCallNow), settleSeconds: 4);
      await f.waitFor(find.byType(CircleCallScreen), what: 'the Assisto call screen');
      final hang = find.byKey(const Key('call-hangup'));
      if (await f.appears(hang, seconds: 8)) await f.tap(hang, settleSeconds: 3);
      await ok('confirm -> Assisto call screen');
    case 'circle_message':
      await f.waitFor(find.text(t.vaCircleSend), what: 'the My Circle message confirm card');
      if (_posted(f, mark, '/messages')) throw TestFailure('sent BEFORE the confirm tap');
      row['confirm_card'] = true;
      await f.shot('$mode-msg-confirm');
      final send = find.text(t.vaCircleSend);
      await f.tap(send, settleSeconds: 5);
      await f.eventually('the message reached the server', () async => _posted(f, mark, '/messages'),
          seconds: 25);
      await ok('confirm -> encrypted chat sent');
    case 'reminder':
      await f.waitFor(find.text(t.vaUndo), seconds: 10, what: 'the reminder card (with Undo)');
      final api = await f.h.backend();
      await f.eventually('the reminder is on the server', () async {
        final rows = await api.listItems('reminders');
        return rows.any((r) => '${r['source'] ?? ''}' == 'voice' ||
            '${r['title']}'.toLowerCase().contains('electric') ||
            '${r['title']}'.contains('বিল'));
      }, seconds: 25);
      await ok('saved (Undo offered)');
    case 'expense':
      await f.waitFor(find.text(t.save), what: 'the expense confirm card (money)');
      row['confirm_card'] = true;
      if (_posted(f, mark, '/transactions')) throw TestFailure('saved BEFORE the confirm tap');
      await f.shot('$mode-expense-confirm');
      await f.tap(find.text(t.save), settleSeconds: 3);
      final api = await f.h.backend();
      await f.eventually('the expense is on the server', () async {
        final rows = await api.listItems('transactions');
        return rows.any((r) => '${r['amount']}'.startsWith('250'));
      }, seconds: 25);
      await ok('confirm -> saved');
    case 'safe_journey':
      await f.waitFor(find.text(t.vaJourneyOpen), what: 'the Safe Journey confirm card');
      row['confirm_card'] = true;
      await f.shot('$mode-journey-confirm');
      await f.tap(find.text(t.vaJourneyOpen), settleSeconds: 3);
      await f.waitFor(find.byType(SafeJourneyHubScreen), what: 'Safe Journey');
      await ok('confirm -> Safe Journey (user picks who + Start)');
    case 'sos':
      await f.waitFor(find.text(t.vaSendSos), what: 'the SOS confirm card');
      row['confirm_card'] = true;
      if (_posted(f, mark, 'sos')) throw TestFailure('SOS went out BEFORE the confirm tap');
      await f.shot('$mode-sos-confirm');
      await f.tap(find.text(t.vaSendSos), settleSeconds: 1);
      await f.waitFor(find.byType(JourneySosScreen), what: 'the SOS countdown');
      await f.waitFor(find.text(t.sosCancel), seconds: 4, what: 'Cancel in the countdown');
      await f.tap(find.text(t.sosCancel), settleSeconds: 2);
      await f.pumpFor(const Duration(seconds: 6));
      if (_posted(f, mark, 'sos')) throw TestFailure('SOS was sent although cancelled in the countdown');
      await ok('confirm -> 5 s countdown -> cancelled, nothing sent');
    case 'cctv':
      await f.waitFor(find.byType(WatchmanScreen), seconds: 10, what: 'Assisto CCTV');
      await ok('CCTV opened');
    case 'ask_ai':
      await f.eventually('the AI answered', () async => _posted(f, mark, '/agent'), seconds: 30);
      await f.pumpFor(const Duration(seconds: 2));
      await ok('agent answered');
    default:
      throw TestFailure('unknown kind $kind');
  }
  // leave cleanly for the next command
  final nav = appNavigatorKey.currentState;
  nav?.popUntil((r) => r.isFirst);
  await f.pumpFor(const Duration(seconds: 1));
}
