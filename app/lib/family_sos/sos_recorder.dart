import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../audio/audio_route_service.dart';

/// fcsos — the 30-second SOS sound clip. Recorded on the SENDER's phone ONLY
/// after the SOS went out, with a red "Recording" banner and Stop on screen;
/// uploaded once for the family of that SOS (deleted on the server after 7
/// days, and from this phone right after the upload). Never given to AI.
abstract class SosRecorder {
  /// Microphone already allowed (no prompt).
  Future<bool> granted();

  /// Ask for the microphone (only after the user tapped "Record").
  Future<bool> request();
  Future<bool> start();

  /// Stops; returns the recorded bytes (null on failure). The file is deleted.
  Future<List<int>?> stop();
}

class PluginSosRecorder implements SosRecorder {
  AudioRecorder? _r;
  AudioRecorder get _rec => _r ??= AudioRecorder();
  final MicRouteHold _mic = MicRouteHold(AudioUse.voiceNoteRecord);
  String? _path;

  @override
  Future<bool> granted() async {
    try {
      return (await Permission.microphone.status).isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> request() async {
    try {
      return (await Permission.microphone.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> start() async {
    try {
      if (!await granted()) return false;
      final dir = await getTemporaryDirectory();
      _path = '${dir.path}/sos_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _mic.start();
      await _rec.start(
          const RecordConfig(
              encoder: AudioEncoder.aacLc, bitRate: 48000, sampleRate: 22050, numChannels: 1,
              androidConfig: AndroidRecordConfig(manageBluetooth: false)),
          path: _path!);
      return true;
    } catch (_) {
      _mic.stop();
      return false;
    }
  }

  @override
  Future<List<int>?> stop() async {
    _mic.stop();
    String? p;
    try {
      p = await _rec.stop();
    } catch (_) {
      p = null;
    }
    p ??= _path;
    if (p == null) return null;
    try {
      final f = File(p);
      if (!f.existsSync()) return null;
      final b = await f.readAsBytes();
      f.deleteSync();
      return b.isEmpty ? null : b;
    } catch (_) {
      return null;
    }
  }
}

/// Tests / the gallery swap this.
SosRecorder Function() sosRecorderFactory = PluginSosRecorder.new;
