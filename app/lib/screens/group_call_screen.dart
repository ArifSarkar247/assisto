import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../calls/call_avatar.dart';
import '../calls/call_data_prefs.dart';
import '../calls/call_keepalive.dart';
import '../calls/call_native.dart';
import '../calls/call_runtime.dart';
import '../calls/group_add_people_sheet.dart';
import '../calls/group_call_api.dart';
import '../calls/group_call_controller.dart';
import '../calls/group_mesh_media.dart' deferred as mesh;
import '../ds/ds.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;

/// group-calls (owner order 17 Nov): the group call screen — a grid of up
/// to 8 tiles (name, mic-off icon, ringing state, a green border on whoever
/// is speaking), Speaker / Camera / Flip / Mute / Add person, and Leave.
/// Leaving never ends the call for the others; the last two simply go on.
///
/// Opened by: a group chat's call button / "Join" bar, Add person in a 1:1
/// call (that call is handed over: [adoptCallId]), and answering a group
/// ring ([answerCallId]).
class GroupCallScreen extends StatefulWidget {
  const GroupCallScreen({
    super.key,
    required this.roomId,
    this.initial,
    this.video = false,
    this.title = '',
    this.answerCallId,
    this.adoptCallId,
    this.sinceSeq = 0,
    this.controller,
    this.surface,
  });

  final int roomId;

  /// The snapshot the start / add call returned (null = join on open).
  final Map<String, dynamic>? initial;
  final bool video;
  final String title;
  final int? answerCallId;
  final int? adoptCallId;
  final int sinceSeq;

  /// Pre-built controller (gallery / widget tests): rendered, never started.
  final GroupCallController? controller;
  final GroupVideoSurface? surface;

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  GroupCallController? _c;
  GroupVideoSurface? _surface;
  GroupCallApi? _api;
  bool _owns = false;
  Timer? _ticker;
  Timer? _autoClose;
  Timer? _noticeTimer;
  String? _notice;
  bool _keepAlive = false;
  bool _busyAdd = false;

  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    if (c != null) {
      _attach(c, widget.surface);
    } else {
      _owns = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
    }
  }

  Future<void> _start() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final transport = CallRuntime.instance.transportFor(app);
    final api = _api = GroupCallApi(app.api);
    final low = await CallDataPrefs.lowData();
    GroupMedia media;
    try {
      await mesh.loadLibrary();
      media = mesh.createGroupMeshMedia();
    } catch (_) {
      media = _NoMedia();
    }
    if (!mounted) {
      unawaited(media.dispose());
      return;
    }
    final c = GroupCallController(
      media: media,
      signaling: ApiGroupSignaling(api, transport),
      roomId: widget.roomId,
      myId: app.user?.id ?? 0,
      video: widget.video,
      answerCallId: widget.answerCallId,
      adoptCallId: widget.adoptCallId,
      sinceSeq: widget.sinceSeq,
      onMobileData: low,
      networkEvents: CallNative.networkChanges(),
    );
    _attach(c, media is GroupVideoSurface ? media as GroupVideoSurface : null);
    if (widget.video) unawaited(CallNative.keepScreenOn(true));
    await c.start(initial: widget.initial);
  }

  void _attach(GroupCallController c, GroupVideoSurface? s) {
    _c = c;
    _surface = s;
    c.addListener(_onChange);
    s?.videoChanged.addListener(_onChange);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && c.isLive) setState(() {});
    });
  }

  void _onChange() {
    final c = _c;
    if (c == null || !mounted) return;
    if (_owns && c.isLive && !_keepAlive) {
      _keepAlive = true;
      final t = _t;
      unawaited(CallKeepAlive.start(
          channelName: t.c2ChOngoing,
          title: t.gcallTitle,
          text: t.c2CallOngoingText,
          hangupLabel: t.c2CallHangup,
          onHangup: () async => c.leave()));
    }
    if (c.isEnded && _owns) {
      unawaited(CallNative.keepScreenOn(false));
      if (_keepAlive) unawaited(CallKeepAlive.stop());
      _keepAlive = false;
      _autoClose ??= Timer(const Duration(milliseconds: 2500), _close);
    }
    setState(() {});
  }

  void _close() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  void _say(String msg) {
    _noticeTimer?.cancel();
    setState(() => _notice = msg);
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  String _d(String s) => notifLocalizeDigits(context, s);

  Future<void> _addPerson() async {
    final c = _c;
    final api = _api;
    if (c == null || !c.isLive || _busyAdd) return;
    if (c.free <= 0) {
      _say(c.fullMessage.isNotEmpty ? c.fullMessage : _t.gcallFull);
      return;
    }
    final ids = await showGroupAddPeopleSheet(context,
        load: () => api == null
            ? Future.value(const <Map<String, dynamic>>[])
            : api.candidates(roomId: widget.roomId),
        alreadyIn: c.seatedUserIds,
        free: c.free);
    if (ids == null || ids.isEmpty || !mounted) return;
    setState(() => _busyAdd = true);
    try {
      final res = await c.invite(ids);
      if (!mounted) return;
      _say(addResultLine(_t, res, c.tiles));
    } on GroupCallError catch (e) {
      if (mounted) _say(groupErrorLine(_t, e));
    } finally {
      if (mounted) setState(() => _busyAdd = false);
    }
  }

  Future<void> _leave() async {
    final c = _c;
    if (c == null) {
      _close();
      return;
    }
    await c.leave();
    _close();
  }

  Future<bool> _confirmLeave() async {
    final t = _t;
    final r = await showAppSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DsButton.danger(
                key: const Key('gcall-leave-confirm'),
                icon: Icons.call_end_rounded,
                label: t.gcallLeave,
                expand: true,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
              const SizedBox(height: Gap.sm),
              DsButton.secondary(
                label: t.cancel,
                expand: true,
                onPressed: () => Navigator.of(ctx).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
    return r == true;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _autoClose?.cancel();
    _noticeTimer?.cancel();
    final c = _c;
    final s = _surface;
    s?.videoChanged.removeListener(_onChange);
    if (c != null) {
      c.removeListener(_onChange);
      if (_owns) {
        c.dispose(); // leaves if still in the call
        unawaited(CallNative.keepScreenOn(false));
        if (_keepAlive) unawaited(CallKeepAlive.stop());
      }
    }
    super.dispose();
  }

  // ----------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final c = _c;
    final live = c != null && c.isLive;
    return PopScope(
      canPop: !live,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave()) await _leave();
      },
      child: Scaffold(
        backgroundColor: Brand.ink,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Brand.navyInk, Brand.ink],
            ),
          ),
          child: SafeArea(
            child: c == null
                ? Center(
                    child: Text(_t.gcallStarting,
                        style: AType.bodyLarge.copyWith(color: CallInk.textSoft)))
                : c.isEnded
                    ? _ended(c)
                    : Column(
                        children: [
                          _top(c),
                          if (_notice != null) _noticeBar(_notice!),
                          Expanded(child: _grid(c)),
                          _controls(c),
                        ],
                      ),
          ),
        ),
      ),
    );
  }

  Widget _top(GroupCallController c) {
    final t = _t;
    final title = c.groupName.isNotEmpty
        ? c.groupName
        : (widget.title.isNotEmpty ? widget.title : t.gcallTitle);
    final at = c.connectedAt;
    final parts = <String>[t.gcallPeople(_d('${c.inCallCount}'))];
    if (at != null) {
      final s = DateTime.now().difference(at).inSeconds;
      final mm = (s ~/ 60).toString().padLeft(2, '0');
      final ss = (s % 60).toString().padLeft(2, '0');
      parts.add(_d('$mm:$ss'));
    } else if (c.phase == GroupCallPhase.joining) {
      parts.add(t.gcallConnecting);
    } else if (c.inCallCount <= 1) {
      parts.add(t.gcallWaiting);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    key: const Key('gcall-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AType.titleLarge.copyWith(color: CallInk.text)),
                Text(parts.join(' · '),
                    key: const Key('gcall-status'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AType.bodyMedium.copyWith(color: CallInk.textSoft)),
              ],
            ),
          ),
          if (c.onMobileData)
            Container(
              key: const Key('gcall-low-data'),
              padding: const EdgeInsets.symmetric(
                  horizontal: Gap.sm, vertical: Gap.xs),
              decoration: BoxDecoration(
                color: CallInk.chip,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text(t.gcallLowData,
                  style: AType.labelMedium.copyWith(color: CallInk.text)),
            ),
        ],
      ),
    );
  }

  Widget _noticeBar(String msg) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Container(
          key: const Key('gcall-notice'),
          width: double.infinity,
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: CallInk.notice,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Semantics(
            liveRegion: true,
            child: Text(msg,
                style: AType.bodyMedium.copyWith(color: CallInk.text)),
          ),
        ),
      );

  Widget _grid(GroupCallController c) {
    final tiles = c.tiles;
    final (cols, rows) = gridShape(tiles.length);
    return Padding(
      padding: const EdgeInsets.all(Gap.sm),
      child: Column(
        key: const Key('gcall-grid'),
        children: [
          for (var r = 0; r < rows; r++)
            Expanded(
              child: Row(
                children: [
                  for (var k = 0; k < cols; k++)
                    if (r * cols + k < tiles.length)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(Gap.xs),
                          child: _tile(c, tiles[r * cols + k]),
                        ),
                      )
                    else
                      const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(GroupCallController c, GroupTile tile) {
    final t = _t;
    final s = _surface;
    Widget? video;
    if (tile.isMe && c.cameraOn && s != null) {
      video = s.localView();
    } else if (!tile.isMe && tile.legId != null && tile.camera && s != null) {
      video = s.remoteView(tile.legId!);
    }
    final name = tile.isMe ? t.gcallYou : tile.name;
    String? state;
    if (tile.ringing) {
      state = t.gcallRinging;
    } else if (!tile.isMe && !tile.connected) {
      state = t.gcallConnecting;
    }
    final label = [
      name,
      if (tile.speaking) t.gcallSpeaking,
      if (tile.muted) t.gcallMicOff,
      if (state != null) state,
    ].join(', ');
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: AnimatedContainer(
          key: Key('gcall-tile-${tile.userId}'),
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: CallInk.glass,
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(
                color: tile.speaking ? CallInk.good : Colors.transparent,
                width: 3),
          ),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(builder: (ctx, box) {
            final r =
                (box.biggest.shortestSide * 0.24).clamp(18.0, 56.0).toDouble();
            return Stack(
              fit: StackFit.expand,
              children: [
                if (video != null)
                  video
                else
                  Center(
                    child: Opacity(
                      opacity: tile.ringing ? 0.6 : 1,
                      child: CallAvatar(
                          name: tile.name,
                          photoUrl: tile.photoUrl,
                          version: tile.photoV,
                          radius: r),
                    ),
                  ),
                if (tile.speaking)
                  const Positioned(
                    top: Gap.sm,
                    right: Gap.sm,
                    child: Icon(Icons.graphic_eq_rounded,
                        key: Key('gcall-speaking'), color: CallInk.good),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Gap.sm, vertical: Gap.xs),
                    color: CallInk.chip,
                    child: Row(
                      children: [
                        if (tile.muted)
                          const Padding(
                            padding: EdgeInsets.only(right: Gap.xs),
                            child: Icon(Icons.mic_off_rounded,
                                key: Key('gcall-mic-off'),
                                size: 18,
                                color: CallInk.failure),
                          ),
                        Expanded(
                          child: Text(
                            state == null ? name : '$name · $state',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AType.labelLarge
                                .copyWith(color: CallInk.text),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget _controls(GroupCallController c) {
    final t = _t;
    final live = c.isLive;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                vertical: Gap.md, horizontal: Gap.sm),
            decoration: BoxDecoration(
              color: CallInk.glass,
              borderRadius: BorderRadius.circular(Radii.xl),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GroupCtlButton(
                  key: const Key('gcall-speaker'),
                  icon: c.speakerOn
                      ? Icons.volume_up_rounded
                      : Icons.phone_in_talk_rounded,
                  label: t.gcallSpeaker,
                  active: c.speakerOn,
                  onTap: live ? c.toggleSpeaker : null,
                ),
                if (c.isVideo)
                  GroupCtlButton(
                    key: const Key('gcall-camera'),
                    icon: c.cameraOn
                        ? Icons.videocam_rounded
                        : Icons.videocam_off_rounded,
                    label: t.gcallCamera,
                    active: !c.cameraOn,
                    onTap: live && !c.media.cameraUnavailable
                        ? c.toggleCamera
                        : null,
                  ),
                if (c.isVideo)
                  GroupCtlButton(
                    key: const Key('gcall-flip'),
                    icon: Icons.cameraswitch_rounded,
                    label: t.gcallFlip,
                    active: false,
                    onTap: live && c.cameraOn ? c.switchCamera : null,
                  ),
                GroupCtlButton(
                  key: const Key('gcall-mute'),
                  icon: c.muted ? Icons.mic_off_rounded : Icons.mic_none_rounded,
                  label: t.gcallMute,
                  active: c.muted,
                  onTap: live ? c.toggleMute : null,
                ),
                GroupCtlButton(
                  key: const Key('gcall-add'),
                  icon: Icons.person_add_alt_1_rounded,
                  label: t.gcallAddPerson,
                  active: false,
                  onTap: live && !_busyAdd ? _addPerson : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.lg),
          Semantics(
            button: true,
            label: t.gcallLeave,
            child: Material(
              color: Brand.danger,
              shape: const CircleBorder(),
              child: InkWell(
                key: const Key('gcall-leave'),
                customBorder: const CircleBorder(),
                onTap: _leave,
                child: const SizedBox(
                    width: 68,
                    height: 68,
                    child: Icon(Icons.call_end_rounded,
                        color: CallInk.text, size: 32)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ended(GroupCallController c) {
    final t = _t;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.call_end_rounded, color: CallInk.textSoft, size: 48),
            const SizedBox(height: Gap.md),
            Text(endLine(t, c.endReason),
                key: const Key('gcall-ended'),
                textAlign: TextAlign.center,
                style: AType.titleMedium.copyWith(color: CallInk.text)),
            const SizedBox(height: Gap.lg),
            DsButton.secondary(
              key: const Key('gcall-close'),
              label: t.close,
              onPressed: _close,
            ),
          ],
        ),
      ),
    );
  }
}

/// group-calls: the group call a ring belongs to (push / in-app ring data
/// `room_id`), or null for a normal 1:1 ring.
int? groupRoomOf(Map<String, String> data) {
  final v = int.tryParse(data['room_id'] ?? '');
  return v != null && v > 0 ? v : null;
}

/// The line under an ended group call.
String endLine(AppLocalizations t, GroupEndReason r) => switch (r) {
      GroupEndReason.ended => t.gcallEndedAll,
      GroupEndReason.full => t.gcallFull,
      GroupEndReason.unavailable => t.gcallUnavailable,
      GroupEndReason.mediaDenied => t.gcallMicDenied,
      GroupEndReason.mediaError => t.gcallMediaError,
      GroupEndReason.network => t.gcallNetwork,
      _ => t.gcallEnded,
    };

/// A server refusal in the user's words.
String groupErrorLine(AppLocalizations t, GroupCallError e) =>
    switch (e.code) {
      'full' => t.gcallFull,
      'upgrade_required' => t.gcallVideoPremium,
      'unavailable' || 'not_found' => t.gcallUnavailable,
      'call_ended' => t.gcallEnded,
      _ => e.message.isNotEmpty ? e.message : t.gcallNetwork,
    };

/// "Ringing A, B" / "Couldn't add C" after Add person.
String addResultLine(AppLocalizations t, List<Map<String, dynamic>> res,
    List<GroupTile> tiles) {
  String nameOf(int? id) {
    for (final x in tiles) {
      if (x.userId == id) return x.name;
    }
    return '';
  }

  final ok = <String>[];
  final bad = <String>[];
  var full = false;
  for (final r in res) {
    final id = (r['user_id'] as num?)?.toInt();
    final n = nameOf(id);
    if (r['ok'] == true) {
      if (n.isNotEmpty) ok.add(n);
    } else if (r['code'] == 'full') {
      full = true;
    } else if (r['code'] != 'already' && n.isNotEmpty) {
      bad.add(n);
    }
  }
  final lines = <String>[
    if (ok.isNotEmpty) t.gcallRingingNames(ok.join(', ')),
    if (bad.isNotEmpty) t.gcallCouldNotAdd(bad.join(', ')),
    if (full) t.gcallFull,
  ];
  if (lines.isEmpty) {
    return res.any((r) => r['ok'] == true) ? t.gcallRinging : t.gcallNobodyReached;
  }
  return lines.join('\n');
}

class GroupCtlButton extends StatelessWidget {
  const GroupCtlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final bg = active
        ? CallInk.text
        : CallInk.text.withValues(alpha: enabled ? 0.16 : 0.06);
    final fg =
        active ? Brand.ink : CallInk.text.withValues(alpha: enabled ? 1 : 0.45);
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              toggled: active,
              enabled: enabled,
              label: label,
              child: Material(
                color: bg,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  child: SizedBox(
                      width: 52, height: 52, child: Icon(icon, color: fg)),
                ),
              ),
            ),
            const SizedBox(height: Gap.xs),
            ExcludeSemantics(
              child: Text(label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AType.bodySmall.copyWith(color: CallInk.textSoft)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Used only if the WebRTC library can't load: the call fails honestly.
class _NoMedia implements GroupMedia {
  @override
  bool get cameraUnavailable => true;
  @override
  Future<void> open({required bool video}) async =>
      throw StateError('webrtc unavailable');
  @override
  Future<void> addPeer(int legId, List<Map<String, dynamic>> iceServers,
          {required bool video}) async =>
      throw StateError('webrtc unavailable');
  @override
  Future<Map<String, dynamic>> createOffer(int legId) async =>
      throw StateError('webrtc unavailable');
  @override
  Future<Map<String, dynamic>> acceptOffer(
          int legId, Map<String, dynamic> offer) async =>
      throw StateError('webrtc unavailable');
  @override
  Future<void> setAnswer(int legId, Map<String, dynamic> answer) async {}
  @override
  Future<void> addCandidate(int legId, Map<String, dynamic> c) async {}
  @override
  Future<void> closePeer(int legId) async {}
  @override
  Stream<LegCandidate> get localCandidates => const Stream.empty();
  @override
  Stream<LegLink> get linkStates => const Stream.empty();
  @override
  Future<LegStats> stats(int legId) async => const LegStats();
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setCameraEnabled(bool on) async {}
  @override
  Future<void> switchCamera() async {}
  @override
  Future<void> setSpeaker(bool on) async {}
  @override
  Future<void> setVideoKbps(int kbps) async {}
  @override
  Future<void> dispose() async {}
}
