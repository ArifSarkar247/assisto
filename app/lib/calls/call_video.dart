import 'package:flutter/widgets.dart';

/// Video views of a call's media (implemented by WebRtcCallMedia; a fake in
/// gallery / widget tests). Kept separate from the deferred WebRTC library
/// so the call screen can type-check it without loading the plugin.
abstract class CallVideoSurface {
  ValueNotifier<bool> get hasRemoteVideo;
  Widget localView({bool mirror = true});
  Widget remoteView();
}
