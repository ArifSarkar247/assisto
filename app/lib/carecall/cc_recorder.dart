import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../audio/audio_route_service.dart';

/// carecall: the setter records the reminder in their OWN voice (AAC-LC
/// .m4a, mono, small). It is uploaded only for this Care Call and played
/// only on the receiver's phone — never given to any AI, never cloned.
/// Recording goes through the audio route service (a connected headset's
/// mic is used).
abstract class CcRecorder {
  Future<bool> start();
  Future<String?> stop();
  Future<void> delete(String path);
}

Future<String> ccDraftPath() async {
  final dir = await getApplicationDocumentsDirectory();
  final d = Directory('${dir.path}/carecall');
  if (!d.existsSync()) d.createSync(recursive: true);
  return '${d.path}/draft_${DateTime.now().millisecondsSinceEpoch}.m4a';
}

class PluginCcRecorder implements CcRecorder {
  AudioRecorder? _r;
  AudioRecorder get _rec => _r ??= AudioRecorder();
  final MicRouteHold _mic = MicRouteHold(AudioUse.voiceNoteRecord);

  @override
  Future<bool> start() async {
    try {
      // the screen showed our reason and asked first (_micOk)
      if (!(await Permission.microphone.status).isGranted) return false;
      _mic.start();
      await _rec.start(
          const RecordConfig(
              encoder: AudioEncoder.aacLc, bitRate: 48000, sampleRate: 22050, numChannels: 1,
              androidConfig: AndroidRecordConfig(manageBluetooth: false)),
          path: await ccDraftPath());
      return true;
    } catch (_) {
      _mic.stop();
      return false;
    }
  }

  @override
  Future<String?> stop() async {
    _mic.stop();
    try {
      return await _rec.stop();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> delete(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

/// Tests / the gallery swap this.
CcRecorder Function() ccRecorderFactory = PluginCcRecorder.new;
