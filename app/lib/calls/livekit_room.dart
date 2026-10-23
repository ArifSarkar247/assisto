import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'call_log.dart';
import 'call_native.dart';
import 'call_recording.dart';
import 'group_call.dart';
import 'webrtc_extras.dart';

/// b3-group: [GroupRoom] on livekit_client (Apache-2.0) — the ONLY file that
/// imports it. Loaded with `deferred as` when a group call starts, so no
/// LiveKit Dart code runs at app launch.
///
/// Audio session: LiveKit owns it ONLY while connected (CallNative.audioOwner);
/// before / after that flutter_webrtc owns it for 1:1 calls and live view.
class LiveKitGroupRoom implements GroupRoom {
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  final _changes = StreamController<void>.broadcast();
  GroupLink _link = GroupLink.idle;
  String _reason = '';
  bool _front = true;

  @override
  Stream<void> get changes => _changes.stream;
  @override
  GroupLink get link => _link;
  @override
  String get disconnectReason => _reason;

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> connect(String url, String token,
      {required bool camera, required bool mic}) async {
    _link = GroupLink.connecting;
    _reason = '';
    await CallNative.audioOwner(livekit: true);
    final room = lk.Room(
      roomOptions: const lk.RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultCameraCaptureOptions: lk.CameraCaptureOptions(
          maxFrameRate: 24,
          params: lk.VideoParametersPresets.h540_169,
        ),
        defaultVideoPublishOptions: lk.VideoPublishOptions(simulcast: true),
      ),
    );
    _room = room;
    final l = room.createListener();
    _listener = l;
    l
      ..on<lk.RoomReconnectingEvent>((_) {
        _link = GroupLink.reconnecting;
        _emit();
      })
      ..on<lk.RoomReconnectedEvent>((_) {
        _link = GroupLink.connected;
        _emit();
      })
      ..on<lk.RoomDisconnectedEvent>((e) {
        _link = GroupLink.disconnected;
        _reason = switch (e.reason) {
          lk.DisconnectReason.participantRemoved => 'removed',
          lk.DisconnectReason.roomDeleted => 'room_deleted',
          lk.DisconnectReason.duplicateIdentity => 'duplicate',
          lk.DisconnectReason.clientInitiated => 'client',
          _ => '',
        };
        _emit();
      });
    room.addListener(_emit);
    try {
      await room.connect(url, token,
          connectOptions: const lk.ConnectOptions(autoSubscribe: true));
    } catch (e) {
      _link = GroupLink.disconnected;
      await _teardown();
      final s = '$e'.toLowerCase();
      throw GroupRoomException(
          s.contains('permission') ? 'denied' : 'unreachable', '$e');
    }
    _link = GroupLink.connected;
    final lp = room.localParticipant;
    try {
      await lp?.setMicrophoneEnabled(mic);
    } catch (e) {
      final s = '$e'.toLowerCase();
      if (s.contains('permission') || s.contains('notallowed')) {
        await disconnect();
        throw GroupRoomException('denied', '$e');
      }
      callLog('livekit#mic', e);
    }
    if (camera) {
      try {
        await lp?.setCameraEnabled(true);
      } catch (e) {
        // camera busy / refused: stay in the call with the camera off
        callLog('livekit#cam', e);
      }
    }
    try {
      await lk.AudioManager.instance.setSpeakerOutputPreferred(true);
    } catch (e) {
      callLog('livekit#speaker', e);
    }
    _emit();
  }

  Future<void> _teardown() async {
    try {
      await _listener?.dispose();
    } catch (_) {}
    _listener = null;
    final r = _room;
    _room = null;
    if (r != null) {
      r.removeListener(_emit);
      try {
        await r.dispose();
      } catch (_) {}
    }
    await CallNative.audioOwner(livekit: false);
  }

  @override
  Future<void> disconnect() async {
    final r = _room;
    if (r == null) return;
    try {
      await r.disconnect();
    } catch (e) {
      callLog('livekit#disconnect', e);
    }
    _link = GroupLink.disconnected;
    if (_reason.isEmpty) _reason = 'client';
    await _teardown();
    _emit();
  }

  @override
  Future<void> setMic(bool on) async =>
      _room?.localParticipant?.setMicrophoneEnabled(on);

  @override
  Future<void> setCamera(bool on) async =>
      _room?.localParticipant?.setCameraEnabled(on);

  @override
  Future<void> flipCamera() async {
    final pub = _room?.localParticipant
        ?.getTrackPublicationBySource(lk.TrackSource.camera);
    final t = pub?.track;
    if (t is lk.LocalVideoTrack) {
      _front = !_front;
      await t.setCameraPosition(
          _front ? lk.CameraPosition.front : lk.CameraPosition.back);
    }
  }

  @override
  Future<void> setScreenShare(bool on) async {
    await _room?.localParticipant?.setScreenShareEnabled(on);
    _emit();
  }

  @override
  Future<void> setSpeaker(bool on) =>
      lk.AudioManager.instance.setSpeakerOutputPreferred(on);

  GroupMediaPeer _peer(lk.Participant p, {required bool local}) =>
      GroupMediaPeer(
        id: p.identity,
        name: p.name,
        isLocal: local,
        micOn: p.isMicrophoneEnabled(),
        camOn: p.isCameraEnabled(),
        screenOn: p.isScreenShareEnabled(),
        speaking: p.isSpeaking,
      );

  @override
  List<GroupMediaPeer> get peers {
    final r = _room;
    if (r == null) return const [];
    return [
      if (r.localParticipant != null) _peer(r.localParticipant!, local: true),
      for (final p in r.remoteParticipants.values) _peer(p, local: false),
    ];
  }

  @override
  List<String> get activeSpeakers =>
      [for (final p in _room?.activeSpeakers ?? const []) p.identity];

  lk.Participant? _by(String id) {
    final r = _room;
    if (r == null) return null;
    if (r.localParticipant?.identity == id) return r.localParticipant;
    for (final p in r.remoteParticipants.values) {
      if (p.identity == id) return p;
    }
    return null;
  }

  @override
  String? trackSid(String identity, {required bool video}) {
    final p = _by(identity);
    if (p == null) return null;
    final pub = p.getTrackPublicationBySource(
        video ? lk.TrackSource.camera : lk.TrackSource.microphone);
    return pub?.sid;
  }

  @override
  Widget? videoView(String identity, {bool screen = false}) {
    final p = _by(identity);
    if (p == null) return null;
    final pub = p.getTrackPublicationBySource(
        screen ? lk.TrackSource.screenShareVideo : lk.TrackSource.camera);
    final t = pub?.track;
    if (t is! lk.VideoTrack || pub!.muted) return null;
    return lk.VideoTrackRenderer(t,
        fit: screen ? lk.VideoViewFit.contain : lk.VideoViewFit.cover,
        mirrorMode: (p is lk.LocalParticipant && !screen && _front)
            ? lk.VideoViewMirrorMode.mirror
            : lk.VideoViewMirrorMode.off);
  }
}

GroupRoom createLiveKitGroupRoom() => LiveKitGroupRoom();

ScreenShareHost createScreenShareHost(
        {required String channelName,
        required String title,
        required String text}) =>
    NativeScreenShareHost(channelName: channelName, title: title, text: text);

CallRecorderEngine? createRecorderEngine() =>
    recorderSupported() ? WebRtcCallRecorder() : null;
