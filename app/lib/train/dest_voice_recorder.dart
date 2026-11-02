import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../audio/audio_route_service.dart';
import 'dest_alarm_math.dart';

/// train: PERSONAL VOICE for the destination alarm — the user records a short
/// clip in their own (or a family member's) voice. The file stays ON THE
/// PHONE only (app documents folder); it is never uploaded and never sent to
/// any AI: there is NO voice cloning. Recording goes through the audio route
/// service (a connected headset's mic is used).
const Duration kMaxClip = Duration(seconds: 10);

abstract class DestVoiceRecorder {
  Future<bool> start(TransportMode mode);
  Future<String?> stop();
  Future<void> delete(String path);
}

/// Local path for one mode's clip (never a URL).
Future<String> destVoicePath(TransportMode mode) async {
  final dir = await getApplicationDocumentsDirectory();
  final d = Directory('${dir.path}/dest_voice');
  if (!d.existsSync()) d.createSync(recursive: true);
  return '${d.path}/${mode.name}.m4a';
}

class PluginDestVoiceRecorder implements DestVoiceRecorder {
  AudioRecorder? _r;
  AudioRecorder get _rec => _r ??= AudioRecorder();
  final MicRouteHold _mic = MicRouteHold(AudioUse.destVoiceRecord);

  @override
  Future<bool> start(TransportMode mode) async {
    try {
      if (!(await Permission.microphone.request()).isGranted) return false;
      _mic.start();
      await _rec.start(
          const RecordConfig(
              encoder: AudioEncoder.aacLc, bitRate: 48000, sampleRate: 22050, numChannels: 1,
              androidConfig: AndroidRecordConfig(manageBluetooth: false)),
          path: await destVoicePath(mode));
      return true;
    } catch (_) {
      _mic.stop();
      return false; // no mic: the Bangla voice is used instead
    }
  }

  @override
  Future<String?> stop() async {
    _mic.stop();
    try {
      return await _rec.stop();
    } catch (_) {
      return null; // best-effort: nothing recorded
    }
  }

  @override
  Future<void> delete(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // best-effort: already gone
    }
  }
}

/// Tests swap this.
DestVoiceRecorder Function() destVoiceRecorderFactory = PluginDestVoiceRecorder.new;
