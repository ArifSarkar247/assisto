// audioroute CI GUARD (owner 28 Oct, "Call voice does not go to Bluetooth
// earphones"). No screen may play or record sound, or change Android's audio
// routing, without the ONE app-wide route service (lib/audio/).
//
//  (a) routing calls are forbidden outside lib/audio/ (Dart) and outside
//      audio/AudioRouteChannel.kt (Kotlin);
//  (b) every file that uses an audio plugin (players, recorders, speech,
//      WebRTC, the native TTS channel) is registered in
//      AudioRouteService.registry AND really references the service.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/audio/audio_route_service.dart';

List<File> _files(String dir, String ext) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith(ext))
    .toList();

String _rel(File f) => f.path.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');

/// Strips // comments so a doc line naming a forbidden call is not a hit.
String _code(String src) => src
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

void main() {
  group('audioroute guard (a): one routing owner', () {
    test('no Dart file outside lib/audio/ calls the plugin routing helpers',
        () {
      final bad = RegExp(r'Helper\s*\.\s*(setSpeakerphoneOn|selectAudioOutput|'
          r'setSpeakerphoneOnButPreferBluetooth|clearAndroidCommunicationDevice|'
          r'setAndroidAudioConfiguration|setAppleAudioConfiguration)\b');
      // audioplayers' global AudioContext sets AudioManager mode + speaker
      final ctx = RegExp(r'\bsetAudioContext\s*\(|AudioContextConfig\s*\(');
      final hits = <String>[];
      for (final f in _files('lib', '.dart')) {
        final p = _rel(f);
        if (p.startsWith('lib/audio/')) continue;
        final src = _code(f.readAsStringSync());
        for (final m in [...bad.allMatches(src), ...ctx.allMatches(src)]) {
          hits.add('$p: ${m.group(0)}');
        }
      }
      expect(hits, isEmpty,
          reason: 'route audio ONLY through lib/audio/audio_route_service.dart '
              '(AudioRouteService.select / beginCall / acquire)');
    });

    test('no Kotlin outside audio/AudioRouteChannel.kt changes the route', () {
      final bad = RegExp(r'\bsetMode\s*\(|\.mode\s*=\s*AudioManager\.MODE_|'
          r'\bisSpeakerphoneOn\s*=|\bsetSpeakerphoneOn\s*\(|'
          r'\bsetCommunicationDevice\s*\(|\bclearCommunicationDevice\s*\(|'
          r'\bstartBluetoothSco\s*\(|\bisBluetoothScoOn\s*=|'
          r'\bsetStreamVolume\s*\(');
      // STREAM_ALARM volume for sirens: loud on the speaker BY DESIGN (a
      // siren must be heard in the room, never only in an earbud).
      const allow = <String, String>{
        'MainActivity.kt': 'lost-phone siren: STREAM_ALARM to max volume',
        'antitheft/RemoteCommands.kt':
            'anti-theft siren: STREAM_ALARM to max, restored after',
      };
      const root = 'android_overlay/app/src/main/kotlin/com/assisto/assisto/';
      final hits = <String>[];
      for (final f in _files('android_overlay', '.kt')) {
        final p = _rel(f);
        if (p.endsWith('audio/AudioRouteChannel.kt')) continue;
        final short = p.startsWith(root) ? p.substring(root.length) : p;
        final src = _code(f.readAsStringSync());
        for (final m in bad.allMatches(src)) {
          if (allow.containsKey(short) &&
              m.group(0)!.startsWith('setStreamVolume') &&
              src
                  .substring(m.start, (m.start + 120).clamp(0, src.length))
                  .contains('STREAM_ALARM')) {
            continue;
          }
          hits.add('$short: ${m.group(0)}');
        }
      }
      expect(hits, isEmpty,
          reason: 'only audio/AudioRouteChannel.kt may change call audio '
              'routing (one owner — two owners fight and lose the headset)');
    });

    test('the native owner really exists and stays lazy', () {
      final k = File('android_overlay/app/src/main/kotlin/com/assisto/assisto/'
              'audio/AudioRouteChannel.kt')
          .readAsStringSync();
      expect(k, contains('com.assisto/audio_route'));
      expect(k, contains('setCommunicationDevice'));
      expect(k, contains('startBluetoothSco'));
      expect(k, contains('MODE_IN_COMMUNICATION'));
      expect(k, contains('registerAudioDeviceCallback'));
      // lazy: AudioManager is not looked up in register()
      final reg = k.substring(k.indexOf('fun register('),
          k.indexOf('private fun audio()'));
      expect(reg.contains('getSystemService'), isFalse);
      final main = File('android_overlay/app/src/main/kotlin/com/assisto/'
              'assisto/MainActivity.kt')
          .readAsStringSync();
      expect(main, contains('AudioRouteChannel.register('));
    });

    test('voice-note recorder leaves Bluetooth to the route service', () {
      final s = File('lib/messaging/media/voice_recorder_sheet.dart')
          .readAsStringSync();
      expect(s, contains('manageBluetooth: false'));
    });
  });

  group('audioroute guard (b): every audio place is registered', () {
    final audioImport = RegExp(
        r"package:(audioplayers|just_audio|video_player|record|speech_to_text|"
        r"flutter_tts|flutter_webrtc|soundpool|flutter_sound)/|"
        r"MethodChannel\('com\.assisto/voice'\)");

    test('files using an audio plugin are in AudioRouteService.registry', () {
      final missing = <String>[];
      for (final f in _files('lib', '.dart')) {
        final p = _rel(f);
        final src = f.readAsStringSync();
        if (!audioImport.hasMatch(src)) continue;
        if (!AudioRouteService.registry.containsKey(p)) missing.add(p);
      }
      expect(missing, isEmpty,
          reason: 'a new audio screen/service must use AudioRouteService '
              '(acquire / MicRouteHold / preparePlayback / beginCall) and be '
              'added to AudioRouteService.registry');
    });

    test('every registered file really uses the route service', () {
      final bad = <String>[];
      for (final e in AudioRouteService.registry.entries) {
        final f = File(e.key);
        expect(f.existsSync(), isTrue, reason: '${e.key} is registered');
        final src = f.readAsStringSync();
        if (e.key.startsWith('lib/audio/')) continue;
        if (!RegExp(r'AudioRouteService|MicRouteHold').hasMatch(src)) {
          bad.add(e.key);
        }
      }
      expect(bad, isEmpty);
    });

    test('mic users are the ones that hold the headset mic', () {
      expect(micUses, contains(AudioUse.voiceNoteRecord));
      expect(micUses, contains(AudioUse.assistantListen));
      expect(micUses, contains(AudioUse.kidsWatchRecord));
      expect(micUses, isNot(contains(AudioUse.sos)));
    });
  });
}
