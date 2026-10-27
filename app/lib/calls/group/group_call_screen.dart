import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../call_keepalive.dart';
import '../call_log.dart';
import '../call_native.dart';
import '../call_runtime.dart';
import '../call_controller.dart' show CallMedia, MediaOpenException;
import '../media_ext.dart';
import '../screen_share.dart';
import '../webrtc_media.dart' deferred as rtc;
import 'add_person_sheet.dart';
import 'group_call.dart';
import 'group_stage.dart';
import 'group_wiring.dart';

/// callsB: a group call WITHOUT a 1:1 call underneath — started from a
/// group chat (it rings the picked contacts) or joined from the chat's
/// "Join call". Every other participant is a pair link (mesh, max 4).
class GroupCallScreen extends StatefulWidget {
  const GroupCallScreen({
    super.key,
    required this.roomId,
    required this.kind,
    this.title = '',
    this.started,
    this.session,
  });

  final int roomId;

  /// 'voice' | 'video'.
  final String kind;
  final String title;

  /// The roster from "start" (I am already joined and ringing people);
  /// null = join the ongoing call now.
  final Map<String, dynamic>? started;

  /// Gallery / tests: a pre-built session (nothing is started).
  final GroupCallSession? session;

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  GroupCallSession? _s;
  MeshHost? _host;
  CallMedia? _media;
  ScreenShareController? _share;
  bool _owns = false;
  bool _closed = false;
  bool _failed = false;
  bool _denied = false;
  bool _wasAlive = false;
  bool _speaker = false;
  Timer? _autoClose;

  AppLocalizations get _t => AppLocalizations.of(context);
  bool get _video => widget.kind == 'video';

  @override
  void initState() {
    super.initState();
    _speaker = _video;
    final pre = widget.session;
    if (pre != null) {
      _s = pre..addListener(_onChange);
      return;
    }
    _owns = true;
    if (!CallRuntime.instance.acquireScreen(this, _live)) {
      _owns = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _close());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  bool _live() => mounted && !_closed && (_s?.alive ?? true);

  Future<void> _begin() async {
    final app = context.read<AppState>();
    final transport = CallRuntime.instance.transportFor(app);
    MeshHost host;
    try {
      await rtc.loadLibrary();
      final media = rtc.createWebRtcCallMedia();
      _media = media;
      host = media as MeshHost;
      await host.openLocal(video: _video);
    } on MediaOpenException catch (e) {
      callLog('group_screen#1', e);
      if (mounted) {
        setState(() {
          _failed = true;
          _denied = e.denied;
        });
      }
      await _leaveServer(app);
      return;
    } catch (e) {
      callLog('group_screen#2', e);
      if (mounted) setState(() => _failed = true);
      await _leaveServer(app);
      return;
    }
    if (!mounted) {
      await host.releaseAll();
      return;
    }
    _host = host;
    final started = widget.started;
    final s = newGroupSession(
        api: app.api,
        transport: transport,
        host: host,
        roster: started == null ? null : GroupRoster.fromJson(started));
    s.cameraOn = _video;
    s.addListener(_onChange);
    _s = s;
    if (host is ScreenShareMedia) {
      _share = ScreenShareController(
        media: host,
        service: NativeScreenShareService(),
        links: () => s.controllers,
        texts: () => (_t.ssNotifTitle, _t.ssNotifBody, _t.ssNotifStop),
      )..addListener(_onShare);
    }
    transport.setFast(true);
    try {
      await _media?.setSpeaker(_speaker);
    } catch (e) {
      callLog('group_screen#3', e);
    }
    if (started == null) {
      final ok = await s.join(widget.roomId);
      if (!ok && mounted) setState(() => _failed = true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _leaveServer(AppState app) async {
    if (widget.started == null) return;
    try {
      await app.api.postJson('/circle/rooms/${widget.roomId}/leave', const {});
    } catch (e) {
      callLog('group_screen#4', e);
    }
  }

  void _onShare() {
    _s?.setScreenSharing(_share?.sharing ?? false);
    if (mounted) setState(() {});
  }

  void _onChange() {
    final s = _s;
    if (s == null || !mounted) return;
    if (_owns) {
      if (s.alive) {
        _wasAlive = true;
        final t = _t;
        unawaited(CallKeepAlive.start(
            channelName: t.c2ChOngoing,
            title: t.c2CallOngoingTitle(
                widget.title.isNotEmpty ? widget.title : t.cgGroupCall),
            text: t.c2CallOngoingText,
            hangupLabel: t.c2CallHangup,
            onHangup: _hangup));
        if (_video) unawaited(CallNative.keepScreenOn(true));
      } else if (_wasAlive || (s.roster != null && !s.roster!.live)) {
        unawaited(CallKeepAlive.stop());
        unawaited(CallNative.keepScreenOn(false));
        unawaited(_share?.stop());
        _autoClose ??= Timer(const Duration(milliseconds: 1400), _close);
      }
    }
    setState(() {});
  }

  Future<void> _hangup() async {
    await _share?.stop();
    await _s?.leave();
    _close();
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).maybePop();
  }

  Future<void> _openAdd() async {
    final s = _s;
    if (s == null) return;
    final api = context.read<AppState>().api;
    await AddPersonSheet.show(context,
        loadContacts: () async {
          final m = await api.getJson('/circle/members');
          return ((m['results'] ?? m['members'] ?? const []) as List)
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
        },
        session: s);
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _speaker = !_speaker);
    try {
      await _media?.setSpeaker(_speaker);
    } catch (e) {
      callLog('group_screen#5', e);
    }
  }

  @override
  void dispose() {
    _autoClose?.cancel();
    final s = _s;
    s?.removeListener(_onChange);
    if (_owns) {
      final share = _share;
      if (share != null) {
        share.removeListener(_onShare);
        unawaited(share.stop());
        share.dispose();
      }
      if (s != null) {
        unawaited(s.leave());
        s.dispose();
      }
      final host = _host;
      if (host != null) {
        unawaited(host.releaseAll().catchError((Object e) {
          callLog('group_screen#6', e);
        }));
      }
      unawaited(CallKeepAlive.stop());
      unawaited(CallNative.keepScreenOn(false));
      CallRuntime.instance.releaseScreen(this);
      try {
        final app = context.read<AppState>();
        CallRuntime.instance.transportFor(app).setFast(false);
      } catch (e) {
        callLog('group_screen#7', e);
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final alive = s?.alive ?? false;
    return PopScope(
      // back never leaves a live group call by accident (Leave = red button)
      canPop: !(_owns && alive && !_closed),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: _body(s),
      ),
    );
  }

  Widget _body(GroupCallSession? s) {
    final t = _t;
    if (_failed || s == null || (s.roster != null && !s.alive)) {
      final ended = s?.roster != null && !(s?.alive ?? false) && !_failed;
      return Scaffold(
        backgroundColor: Brand.ink,
        body: DecoratedBox(
          decoration: const BoxDecoration(gradient: Brand.heroDark),
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(Gap.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s == null && !_failed)
                      const CircularProgressIndicator(color: CallInk.text)
                    else
                      Text(
                        _failed
                            ? (_denied ? t.c2CallPermission : t.cgJoinFailed)
                            : (ended ? t.cgEnded : t.cgConnecting),
                        key: const Key('group-status'),
                        textAlign: TextAlign.center,
                        style: AType.titleMedium.copyWith(color: CallInk.text),
                      ),
                    const SizedBox(height: Gap.xl),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: Gap.md,
                      runSpacing: Gap.sm,
                      children: [
                        if (_denied)
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.settings_rounded),
                            label: Text(t.c2CallOpenSettings),
                            onPressed: () => openAppSettings(),
                          ),
                        OutlinedButton(
                          key: const Key('group-close'),
                          style: OutlinedButton.styleFrom(
                              foregroundColor: CallInk.text,
                              minimumSize: const Size(64, 48),
                              side: const BorderSide(color: CallInk.textHint)),
                          onPressed: _close,
                          child: Text(t.close),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final share = _share;
    return GroupCallView(
      session: s,
      share: share,
      selfView: _host == null ? null : () => _host!.localPreview(),
      onShareTap: share == null
          ? null
          : () => unawaited(runScreenShareFlow(context, share)),
      onAddPerson: () => unawaited(_openAdd()),
      onSpeaker: () => unawaited(_toggleSpeaker()),
      speakerOn: _speaker,
      onHangup: _hangup,
    );
  }
}
