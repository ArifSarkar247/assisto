import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_keepalive.dart';
import 'call_log.dart';
import 'call_native.dart';
import 'call_recording.dart';
import 'group_call.dart';

/// b3-group: flutter_webrtc pieces shared by 1:1 calls (webrtc_media.dart)
/// and group calls (livekit_room.dart). Only reachable from those two
/// DEFERRED libraries — nothing here runs at app launch.

/// B4 screen share host: the system MediaProjection consent dialog, then the
/// call's foreground service restarted with the mediaProjection type
/// (Android 14 order: consent FIRST, service SECOND, capture THIRD).
class NativeScreenShareHost implements ScreenShareHost {
  NativeScreenShareHost(
      {required this.channelName, required this.title, required this.text});
  final String channelName;
  final String title;
  final String text;
  bool _on = false;

  @override
  Future<bool> supported() => CallNative.screenShareReady();

  @override
  Future<bool> begin() async {
    try {
      if (!await supported()) return false;
      final ok = await Helper.requestCapturePermission();
      if (!ok) return false;
      final fgs = await CallKeepAlive.setScreenShare(true,
          channelName: channelName, title: title, text: text);
      if (!fgs) return false;
      _on = true;
      return true;
    } catch (e) {
      callLog('screen#begin', e);
      return false;
    }
  }

  @override
  Future<void> end() async {
    if (!_on) return;
    _on = false;
    try {
      await CallKeepAlive.setScreenShare(false,
          channelName: channelName, title: title, text: text);
    } catch (e) {
      callLog('screen#end', e);
    }
  }
}

/// B5 recorder: AUDIO ONLY (honest: video recording of a WebRTC call is not
/// reliable across Android OEMs). Two flutter_webrtc MediaRecorders run side
/// by side — this phone's microphone and what the phone plays (everyone
/// else) — each into an M4A in private app storage; [RecordingVault] then
/// encrypts both and deletes the plaintext. Played back together.
class WebRtcCallRecorder implements CallRecorderEngine {
  MediaRecorder? _mic;
  MediaRecorder? _out;

  @override
  Future<List<String>> start(String dir) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final mic = '$dir/rec_${stamp}_me.m4a';
    final out = '$dir/rec_${stamp}_others.m4a';
    final files = <String>[];
    try {
      _out = MediaRecorder();
      await _out!.start(out, audioChannel: RecorderAudioChannel.OUTPUT);
      files.add(out);
    } catch (e) {
      callLog('rec#out', e);
      _out = null;
    }
    try {
      _mic = MediaRecorder();
      await _mic!.start(mic, audioChannel: RecorderAudioChannel.INPUT);
      files.add(mic);
    } catch (e) {
      callLog('rec#mic', e);
      _mic = null;
    }
    if (files.isEmpty) throw StateError('no recorder could start');
    return files;
  }

  @override
  Future<void> stop() async {
    for (final r in [_out, _mic]) {
      if (r == null) continue;
      try {
        await r.stop();
      } catch (e) {
        callLog('rec#stop', e);
      }
    }
    _out = null;
    _mic = null;
  }
}

/// Is the native recorder usable here (Android only).
bool recorderSupported() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android && Platform.isAndroid;
