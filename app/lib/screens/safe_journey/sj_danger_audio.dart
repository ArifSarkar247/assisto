import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../api.dart';
import '../../audio/audio_route_service.dart';
import 'sj_during_api.dart';

/// sjduring — the 30-second audio after a DANGER PIN on arrival.
///
/// The traveller's screen shows a normal "Arrived"; this records quietly in
/// the background and sends the clip to the server for the watchers. It
/// NEVER asks for the microphone (a permission dialog would give the
/// traveller away): no mic permission already -> no clip, the watchers
/// still get red + live location. Audio goes through the audio route
/// service (registered as the SOS exception). The local file is deleted
/// right after the upload.
const Duration kSjDangerClip = Duration(seconds: 30);

/// Tests swap this (no plugin in `flutter test`).
Future<void> Function(ApiClient api, int journeyId) sjRecordDangerClip = _record;

Future<void> _record(ApiClient api, int journeyId) async {
  AudioRouteLease? lease;
  AudioRecorder? rec;
  String? path;
  try {
    if (!(await Permission.microphone.status).isGranted) return;
    lease = await AudioRouteService.instance.acquire(AudioUse.sos);
    final dir = await getTemporaryDirectory();
    path = '${dir.path}/sjd_${DateTime.now().millisecondsSinceEpoch}.m4a';
    rec = AudioRecorder();
    await rec.start(
        const RecordConfig(
            encoder: AudioEncoder.aacLc, bitRate: 48000, sampleRate: 22050, numChannels: 1,
            androidConfig: AndroidRecordConfig(manageBluetooth: false)),
        path: path);
    await Future<void>.delayed(kSjDangerClip);
    final out = await rec.stop();
    final f = File(out ?? path);
    if (!f.existsSync()) return;
    final bytes = await f.readAsBytes();
    if (bytes.isEmpty) return;
    for (var i = 0; i < 3; i++) {
      try {
        await api.sjDangerAudioUpload(journeyId, base64Encode(bytes));
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 20)); // offline: retry
      }
    }
  } catch (_) {
    // best-effort: the red alert + live location already went out
  } finally {
    try {
      await rec?.dispose();
    } catch (_) {
      // already released
    }
    await lease?.release();
    if (path != null) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // temp dir: the OS clears it
      }
    }
  }
}
