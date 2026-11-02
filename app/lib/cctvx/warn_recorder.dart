import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../audio/audio_route_service.dart';

/// cctvescalate C5: the owner records ONE short Bangla warning in their own
/// voice (WAV, 16 kHz mono — the format the camera clouds accept). Recording
/// goes through the audio route service (a headset's mic is used when one is
/// connected). The file is uploaded once to Assisto; the camera cloud gets
/// it only when the owner presses "play on the camera" and confirms.
const Duration kWarnMaxClip = Duration(seconds: 20);

abstract class WarnRecorder {
  Future<bool> start();
  Future<String?> stop();
  Future<Uint8List?> read(String path);
}

Future<String> warnClipPath() async {
  final dir = await getApplicationDocumentsDirectory();
  final d = Directory('${dir.path}/cctv_warn');
  if (!d.existsSync()) d.createSync(recursive: true);
  return '${d.path}/warning.wav';
}

/// Whether the microphone is already granted (the sheet shows the in-app
/// disclosure first when it is not). Tests swap this.
Future<bool> Function() warnMicGranted = () async {
  try {
    return (await Permission.microphone.status).isGranted;
  } catch (_) {
    return false;
  }
};

class PluginWarnRecorder implements WarnRecorder {
  AudioRecorder? _r;
  AudioRecorder get _rec => _r ??= AudioRecorder();
  final MicRouteHold _mic = MicRouteHold(AudioUse.cctvWarnRecord);

  @override
  Future<bool> start() async {
    try {
      if (!(await Permission.microphone.request()).isGranted) return false;
      _mic.start();
      await _rec.start(
          const RecordConfig(
              encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1,
              androidConfig: AndroidRecordConfig(manageBluetooth: false)),
          path: await warnClipPath());
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
  Future<Uint8List?> read(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }
}

/// Tests swap this.
WarnRecorder Function() warnRecorderFactory = PluginWarnRecorder.new;
