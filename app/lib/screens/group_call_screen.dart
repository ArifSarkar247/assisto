import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../calls/api_group_calls.dart';
import '../calls/call_avatar.dart';
import '../calls/call_banners.dart';
import '../calls/call_controller.dart' show CallController;
import '../calls/call_keepalive.dart';
import '../calls/call_log.dart';
import '../calls/call_native.dart';
import '../calls/call_recording.dart';
import '../calls/call_runtime.dart';
import '../calls/circle_pick_sheet.dart';
import '../calls/group_call.dart';
import '../calls/livekit_room.dart' deferred as lk;
import '../l10n/app_localizations.dart';
import '../push/lock_screen_guard.dart';
import '../state.dart';
import '../theme.dart';

/// b3-group: group voice / video call (3+ people) on our LiveKit SFU.
///
/// Grid (1 / 2x2 / 3x3, paged above 9) or speaker view (the active speaker
/// big, the rest in a strip), active-speaker highlight, mic / camera
/// badges, host menu (mute / camera off / remove), screen share (B4) with a
/// permanent "You are sharing your screen — Stop" banner, consented
/// recording (B5) with the red Recording banner for everyone, leave / rejoin
/// while the room lives, and honest errors ("Group calls are not available
/// right now"). LiveKit loads lazily (deferred) only when this screen opens.
class GroupCallScreen extends StatefulWidget {
  const GroupCallScreen({
    super.key,
    this.room,
    this.callId,
    this.groupId,
    this.memberIds = const [],
    this.video = false,
    this.title = '',
    this.handover,
    this.controller,
  });

  /// Join this live room (ring / sfu_move / group banner).
  final String? room;

  /// Add people to this live 1:1 call (start a room from it).
  final int? callId;

  /// Start (or join) the circle group's call.
  final int? groupId;
  final List<int> memberIds;
  final bool video;

  /// Group name / the other person — shown until the server answers.
  final String title;

  /// b3: the 1:1 call this group call grew out of. It is hung up once we
  /// are connected to the room (the server also ends it on "joined").
  final CallController? handover;

  /// Pre-built controller (gallery / widget tests): nothing is started.
  final GroupCallController? controller;

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  GroupCallController? _c;
  bool _owns = false;
  bool _closed = false;
  Timer? _noticeTimer;
  int _noticeSeq = 0;
  GroupNotice _notice = GroupNotice.none;
  int _recSeq = 0;
  RecordNotice _recNotice = RecordNotice.none;
  Timer? _ticker;
  int _page = 0;
  CallController? _handover;
  bool _keepAlive = false;

  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _handover = widget.handover;
    final c = widget.controller;
    if (c != null) {
      _attach(c);
    } else {
      _owns = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_c?.isLive ?? false)) setState(() {});
    });
  }

  void _attach(GroupCallController c) {
    _c = c;
    c.addListener(_onChange);
    c.recording?.addListener(_onChange);
    _noticeSeq = c.noticeSeq;
    _recSeq = c.recording?.noticeSeq ?? 0;
  }

  Future<void> _begin() async {
    final app = context.read<AppState>();
    final t = _t;
    GroupRoom media;
    ScreenShareHost? host;
    CallRecorderEngine? engine;
    try {
      await lk.loadLibrary();
      media = lk.createLiveKitGroupRoom();
      host = lk.createScreenShareHost(
          channelName: t.c2ChOngoing,
          title: t.b3ScreenFgsTitle,
          text: t.b3ScreenFgsText);
      engine = lk.createRecorderEngine();
    } catch (e) {
      callLog('group_screen#load', e);
      media = _NoRoom();
    }
    if (!mounted) return;
    final transport = CallRuntime.instance.transportFor(app);
    final api = ApiGroupCalls(app.api, transport);
    final c = GroupCallController(
      api: api,
      media: media,
      room: widget.room,
      callId: widget.callId,
      groupId: widget.groupId,
      memberIds: widget.memberIds,
      video: widget.video,
      screenHost: host,
      selfId: app.user == null ? null : '${app.user!.id}',
    );
    c.recording = RecordingSession(
      send: (a) => api.record(c.room ?? '', a),
      engine: engine,
      title: widget.title,
    );
    _attach(c);
    transport.setFast(true);
    CallRuntime.instance.activeCallId ??= 0; // busy for 1:1 rings
    setState(() {});
    await c.start();
  }

  void _onChange() {
    final c = _c;
    if (c == null || !mounted) return;
    if (c.noticeSeq != _noticeSeq) {
      _noticeSeq = c.noticeSeq;
      _notice = c.notice;
      _noticeTimer?.cancel();
      _noticeTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _notice = GroupNotice.none);
      });
    }
    final r = c.recording;
    if (r != null && r.noticeSeq != _recSeq) {
      _recSeq = r.noticeSeq;
      _recNotice = r.notice;
      Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _recNotice = RecordNotice.none);
      });
    }
    if (_owns) {
      if (c.isLive) {
        final ho = _handover;
        if (ho != null) {
          // the 1:1 call is replaced by this room now
          _handover = null;
          unawaited(ho.hangup().whenComplete(ho.dispose));
        }
        if (!_keepAlive) {
          _keepAlive = true;
          final t = _t;
          unawaited(CallKeepAlive.start(
              channelName: t.c2ChOngoing,
              title: t.b3GroupCallTitle,
              text: t.c2CallOngoingText));
          if (c.isVideoRoom) unawaited(CallNative.keepScreenOn(true));
        }
      } else if (c.isEnded && _keepAlive) {
        _keepAlive = false;
        unawaited(CallKeepAlive.stop());
        unawaited(CallNative.keepScreenOn(false));
      }
      // names for the recording index
      r?.people = [
        for (final tl in c.tiles)
          if (!tl.isLocal && tl.inRoom) tl.name
      ];
      if (r != null && c.groupName.isNotEmpty) r.title = c.groupName;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _noticeTimer?.cancel();
    final c = _c;
    if (c != null) {
      c.removeListener(_onChange);
      c.recording?.removeListener(_onChange);
      if (_owns) {
        c.recording?.dispose();
        c.dispose(); // leaves if still in the room
        final app = context.read<AppState>();
        CallRuntime.instance.transportFor(app).setFast(false);
        if (CallRuntime.instance.activeCallId == 0) {
          CallRuntime.instance.activeCallId = null;
        }
      }
    }
    final ho = _handover;
    if (ho != null) unawaited(ho.hangup().whenComplete(ho.dispose));
    if (_keepAlive) {
      unawaited(CallKeepAlive.stop());
      unawaited(CallNative.keepScreenOn(false));
    }
    LockScreenGuard.release();
    super.dispose();
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).maybePop();
  }

  Future<void> _confirmLeave() async {
    final c = _c;
    if (c == null || !c.isLive) return _close();
    final t = _t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.b3LeaveConfirmTitle),
        content: Text(t.b3LeaveConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.b3Stay)),
          FilledButton(
              key: const Key('group-leave-confirm'),
              style: FilledButton.styleFrom(backgroundColor: Brand.dangerFill),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.b3Leave)),
        ],
      ),
    );
    if (ok == true) await c.leave();
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final c = _c;
    return PopScope(
      canPop: !(c?.isLive ?? false),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Brand.ink,
          body: DecoratedBox(
            decoration: const BoxDecoration(gradient: Brand.heroDark),
            child: SafeArea(
              child: c == null
                  ? _joining()
                  : c.isEnded
                      ? _ended(c)
                      : _live(c),
            ),
          ),
        ),
      ),
    );
  }

  TextStyle get _muted =>
      TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.75));

  Widget _joining() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: Gap.lg),
          Text(_t.b3Joining,
              style: const TextStyle(color: Colors.white, fontSize: 16)),
        ]),
      );

  String _title(GroupCallController c) {
    if (c.groupName.isNotEmpty) return c.groupName;
    if (widget.title.isNotEmpty) return widget.title;
    return _t.b3GroupCallTitle;
  }

  Widget _top(GroupCallController c) {
    final t = _t;
    final status = c.phase == GroupPhase.joining
        ? t.b3Joining
        : c.phase == GroupPhase.reconnecting
            ? t.circleCallReconnecting
            : t.b3PeopleCount(c.presentCount, c.maxParticipants);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.xs),
      child: Row(
        children: [
          IconButton(
            key: const Key('group-back'),
            tooltip: t.b3Leave,
            color: Colors.white,
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: _confirmLeave,
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_title(c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                Text(status,
                    key: const Key('group-status'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _muted),
                Text(t.b3Encrypted,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: _muted.copyWith(fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            key: const Key('group-layout'),
            tooltip: c.speakerView ? t.b3Grid : t.b3SpeakerView,
            color: Colors.white,
            icon: Icon(c.speakerView
                ? Icons.grid_view_rounded
                : Icons.person_pin_outlined),
            onPressed: c.toggleLayout,
          ),
        ],
      ),
    );
  }

  Widget _live(GroupCallController c) {
    final rec = c.recording;
    final consent = rec?.consent ?? const RecordingConsent();
    return Column(
      children: [
        _top(c),
        if (c.screenSharing)
          ScreenShareBanner(onStop: () => unawaited(c.toggleScreenShare())),
        if (consent.open)
          RecordingBanner(
              consent: consent, requesterName: _nameOf(c, consent.requester)),
        if (consent.iMustAnswer && rec != null)
          RecordingConsentCard(
            requesterName: _nameOf(c, consent.requester),
            busy: rec.busy,
            onAllow: () => unawaited(rec.accept()),
            onDecline: () => unawaited(rec.decline()),
          ),
        Expanded(child: c.speakerView ? _speaker(c) : _grid(c)),
        _noticeLine(c),
        _controls(c),
      ],
    );
  }

  String _nameOf(GroupCallController c, int? userId) {
    if (userId == null) return '';
    for (final t in c.tiles) {
      if (t.id == '$userId') return t.isLocal ? _t.b3You : t.name;
    }
    return '';
  }

  Widget _noticeLine(GroupCallController c) {
    final t = _t;
    final String? text = switch (_notice) {
      GroupNotice.none => null,
      GroupNotice.mutedByHost => t.b3MutedByHost,
      GroupNotice.hostActionFailed => t.b3HostActionFailed,
      GroupNotice.inviteSent => t.b3InviteSent,
      GroupNotice.inviteFailed => t.b3InviteFailed,
      GroupNotice.screenShareFailed => t.b3ScreenShareFailed,
      GroupNotice.screenSharePremium => t.b3ScreenSharePremium,
      GroupNotice.reconnected => t.b1CallNoticeReconnected,
    } ??
        recordNoticeText(t, _recNotice);
    if (text == null) return const SizedBox(height: Gap.xs);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.xs),
      child: Semantics(
        liveRegion: true,
        child: Container(
          key: const Key('group-notice'),
          width: double.infinity,
          padding:
              const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.white)),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- grid
  Widget _grid(GroupCallController c) {
    final tiles = c.tiles;
    final per = GroupCallController.perPage(tiles.length);
    final pages = (tiles.length / per).ceil().clamp(1, 99);
    if (_page >= pages) _page = pages - 1;
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            key: const Key('group-grid'),
            itemCount: pages,
            onPageChanged: (p) => setState(() => _page = p),
            itemBuilder: (_, p) {
              final slice = tiles.skip(p * per).take(per).toList();
              final cols = GroupCallController.columnsFor(slice.length);
              return LayoutBuilder(builder: (ctx, box) {
                final rows = (slice.length / cols).ceil().clamp(1, 3);
                final w = (box.maxWidth - Gap.sm * (cols + 1)) / cols;
                final h = (box.maxHeight - Gap.sm * (rows + 1)) / rows;
                return Padding(
                  padding: const EdgeInsets.all(Gap.sm),
                  child: Wrap(
                    spacing: Gap.sm,
                    runSpacing: Gap.sm,
                    children: [
                      for (final tl in slice)
                        SizedBox(
                            width: w,
                            height: h.clamp(80, 2000).toDouble(),
                            child: _tile(c, tl)),
                    ],
                  ),
                );
              });
            },
          ),
        ),
        if (pages > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < pages; i++)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page ? Colors.white : Colors.white38,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _speaker(GroupCallController c) {
    final tiles = c.tiles;
    final id = c.activeSpeakerId;
    final big = tiles.where((t) => t.id == id).firstOrNull ??
        (tiles.isEmpty ? null : tiles.first);
    final rest = [
      for (final t in tiles)
        if (!identical(t, big)) t
    ];
    return Column(
      key: const Key('group-speaker-view'),
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: big == null ? const SizedBox.shrink() : _tile(c, big, large: true),
          ),
        ),
        if (rest.isNotEmpty)
          SizedBox(
            height: 112,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
              itemCount: rest.length,
              separatorBuilder: (_, __) => const SizedBox(width: Gap.sm),
              itemBuilder: (_, i) =>
                  SizedBox(width: 92, child: _tile(c, rest[i])),
            ),
          ),
      ],
    );
  }

  Widget _tile(GroupCallController c, GroupTile tl, {bool large = false}) {
    final t = _t;
    final video = tl.inRoom
        ? c.media.videoView(tl.id, screen: tl.screenOn) ??
            (tl.screenOn ? c.media.videoView(tl.id) : null)
        : null;
    final showVideo = video != null && (tl.camOn || tl.screenOn);
    final name = tl.isLocal ? t.b3You : tl.name;
    final label = [
      name,
      if (tl.isHost) t.b3Host,
      if (tl.ringing) t.b3Ringing,
      if (tl.inRoom && !tl.micOn) t.b3MicOff,
      if (tl.screenOn) t.b3ScreenOn,
    ].join(', ');
    return Semantics(
      label: label,
      button: c.isHost && !tl.isLocal && tl.inRoom,
      child: GestureDetector(
        key: Key('group-tile-${tl.id}'),
        onTap: (c.isHost && !tl.isLocal && tl.inRoom)
            ? () => _hostMenu(c, tl)
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: tl.speaking ? Brand.cyan : Colors.transparent,
                width: 3),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (showVideo)
                  video
                else
                  Center(
                    child: Opacity(
                      opacity: tl.ringing ? 0.55 : 1,
                      child: CallAvatar(
                          name: tl.name,
                          photoUrl: tl.photo,
                          radius: large ? 56 : 30),
                    ),
                  ),
                Positioned(
                  left: Gap.xs,
                  right: Gap.xs,
                  bottom: Gap.xs,
                  child: Row(
                    children: [
                      if (tl.inRoom && !tl.micOn)
                        Container(
                          key: Key('group-mic-off-${tl.id}'),
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                              color: Brand.dangerFill, shape: BoxShape.circle),
                          child: const Icon(Icons.mic_off,
                              size: 14, color: Colors.white),
                        ),
                      if (tl.screenOn)
                        const Padding(
                          padding: EdgeInsets.only(left: 3),
                          child: Icon(Icons.screen_share,
                              size: 16, color: Colors.white),
                        ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            tl.ringing
                                ? '$name · ${t.b3Ringing}'
                                : tl.isHost
                                    ? '$name · ${t.b3Host}'
                                    : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _hostMenu(GroupCallController c, GroupTile tl) async {
    final t = _t;
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(tl.name,
                style: Theme.of(ctx).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          if (tl.micOn)
            ListTile(
              key: const Key('host-mute'),
              leading: const Icon(Icons.mic_off_outlined),
              title: Text(t.b3MuteParticipant(tl.name)),
              onTap: () => Navigator.pop(ctx, 'mute'),
            ),
          if (tl.camOn)
            ListTile(
              key: const Key('host-cam-off'),
              leading: const Icon(Icons.videocam_off_outlined),
              title: Text(t.b3CamOffParticipant(tl.name)),
              onTap: () => Navigator.pop(ctx, 'cam'),
            ),
          ListTile(
            key: const Key('host-remove'),
            leading: const Icon(Icons.person_remove_outlined,
                color: Brand.danger),
            title: Text(t.b3RemoveParticipant(tl.name)),
            onTap: () => Navigator.pop(ctx, 'remove'),
          ),
        ]),
      ),
    );
    if (!mounted || a == null) return;
    if (a == 'mute') await c.hostMute(tl);
    if (a == 'cam') await c.hostMute(tl, video: true);
    if (a == 'remove') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.b3RemoveConfirm(tl.name)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.b3Cancel)),
            FilledButton(
                key: const Key('host-remove-confirm'),
                style:
                    FilledButton.styleFrom(backgroundColor: Brand.dangerFill),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.b3Remove)),
          ],
        ),
      );
      if (ok == true) await c.hostRemove(tl);
    }
  }

  // ------------------------------------------------------------- controls
  Widget _controls(GroupCallController c) {
    final t = _t;
    final live = c.isLive;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.lg),
      child: Container(
        padding:
            const EdgeInsets.symmetric(vertical: Gap.md, horizontal: Gap.sm),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Btn(
              key: const Key('group-speaker'),
              icon: c.speakerOn ? Icons.volume_up : Icons.hearing,
              label: t.circleCallSpeaker,
              active: c.speakerOn,
              onTap: live ? c.toggleSpeaker : null,
            ),
            _Btn(
              key: const Key('group-mic'),
              icon: c.micOn ? Icons.mic_none : Icons.mic_off,
              label: t.circleCallMute,
              active: !c.micOn,
              onTap: live ? c.toggleMic : null,
            ),
            if (c.isVideoRoom)
              _Btn(
                key: const Key('group-camera'),
                icon: c.cameraOn
                    ? Icons.videocam_outlined
                    : Icons.videocam_off_outlined,
                label: t.circleCallCamera,
                active: !c.cameraOn,
                onTap: live ? c.toggleCamera : null,
              ),
            if (c.isVideoRoom && c.cameraOn)
              _Btn(
                key: const Key('group-flip'),
                icon: Icons.cameraswitch_outlined,
                label: t.c2CallFlip,
                active: false,
                onTap: live ? c.flipCamera : null,
              ),
            _Btn(
              key: const Key('group-more'),
              icon: Icons.more_horiz,
              label: t.b3More,
              active: false,
              onTap: live ? () => _more(c) : null,
            ),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Semantics(
                  button: true,
                  label: t.b3Leave,
                  child: Material(
                    color: Brand.danger,
                    shape: const CircleBorder(),
                    child: InkWell(
                      key: const Key('group-leave'),
                      customBorder: const CircleBorder(),
                      onTap: () => unawaited(c.leave()),
                      child: const SizedBox(
                          width: 52,
                          height: 52,
                          child: Icon(Icons.call_end, color: Colors.white)),
                    ),
                  ),
                ),
                const SizedBox(height: Gap.xs),
                Text(t.b3Leave,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.85))),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _more(GroupCallController c) async {
    final t = _t;
    final rec = c.recording;
    final consent = rec?.consent ?? const RecordingConsent();
    final canAdd = c.presentCount < c.maxParticipants;
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (canAdd)
            ListTile(
              key: const Key('group-add-people'),
              leading: const Icon(Icons.person_add_alt_1_outlined),
              title: Text(t.b3AddPeople),
              onTap: () => Navigator.pop(ctx, 'add'),
            ),
          if (c.screenShareAvailable)
            ListTile(
              key: const Key('group-share-screen'),
              leading: Icon(c.screenSharing
                  ? Icons.stop_screen_share_outlined
                  : Icons.screen_share_outlined),
              title:
                  Text(c.screenSharing ? t.b3StopSharing : t.b3ShareScreen),
              onTap: () => Navigator.pop(ctx, 'screen'),
            ),
          if (rec != null && rec.engine != null && !consent.open)
            ListTile(
              key: const Key('group-record'),
              leading: const Icon(Icons.fiber_manual_record_outlined,
                  color: Brand.danger),
              title: Text(t.b3RecordCall),
              onTap: () => Navigator.pop(ctx, 'record'),
            ),
          if (rec != null && consent.open && consent.requester != null &&
              '${consent.requester}' == c.selfId)
            ListTile(
              key: const Key('group-record-stop'),
              leading: const Icon(Icons.stop_circle_outlined),
              title: Text(t.b3StopRecording),
              onTap: () => Navigator.pop(ctx, 'record-stop'),
            ),
          ListTile(
            key: const Key('group-layout-item'),
            leading: Icon(c.speakerView
                ? Icons.grid_view_rounded
                : Icons.person_pin_outlined),
            title: Text(c.speakerView ? t.b3Grid : t.b3SpeakerView),
            onTap: () => Navigator.pop(ctx, 'layout'),
          ),
        ]),
      ),
    );
    if (!mounted || a == null) return;
    switch (a) {
      case 'add':
        final app = context.read<AppState>();
        final ids = await pickCirclePeople(context,
            api: app.api, max: c.maxParticipants - c.presentCount);
        if (ids != null && ids.isNotEmpty) await c.invite(ids);
      case 'screen':
        await c.toggleScreenShare();
      case 'record':
        if (await confirmRecordRequest(context)) await rec?.request();
      case 'record-stop':
        await rec?.stop();
      case 'layout':
        c.toggleLayout();
    }
  }

  // ---------------------------------------------------------------- ended
  String _endText(GroupCallController c) {
    final t = _t;
    return switch (c.endReason) {
      GroupEndReason.left => t.b3EndedLeft,
      GroupEndReason.ended || GroupEndReason.none => t.b3EndedEnded,
      GroupEndReason.removed => t.b3EndedRemoved,
      GroupEndReason.full => t.b3EndedFull(c.maxParticipants),
      GroupEndReason.unavailable => t.b3Unavailable,
      GroupEndReason.upgrade => t.b3EndedUpgrade,
      GroupEndReason.network => t.b3EndedNetwork,
      GroupEndReason.mediaDenied => t.b3EndedMic,
      GroupEndReason.failed => t.b3EndedFailed,
    };
  }

  Widget _ended(GroupCallController c) {
    final t = _t;
    return Column(
      children: [
        _top(c),
        const Spacer(),
        const Icon(Icons.groups_2_outlined, color: Colors.white70, size: 64),
        const SizedBox(height: Gap.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
          child: Text(_endText(c),
              key: const Key('group-ended'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 18)),
        ),
        if (recordNoticeText(t, _recNotice) case final s?)
          Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Text(s, textAlign: TextAlign.center, style: _muted),
          ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: Gap.md,
            runSpacing: Gap.sm,
            children: [
              if (c.canRejoin)
                FilledButton.icon(
                  key: const Key('group-rejoin'),
                  style: FilledButton.styleFrom(
                      backgroundColor: Brand.successFill,
                      foregroundColor: Colors.white),
                  onPressed: () => unawaited(c.rejoin()),
                  icon: const Icon(Icons.call),
                  label: Text(t.b3Rejoin),
                ),
              OutlinedButton(
                key: const Key('group-close'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54)),
                onPressed: _close,
                child: Text(t.b3Close),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({
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
        ? Colors.white
        : Colors.white.withValues(alpha: enabled ? 0.16 : 0.06);
    final fg =
        active ? Brand.ink : Colors.white.withValues(alpha: enabled ? 1 : 0.45);
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Semantics(
            button: true,
            toggled: active,
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
          Text(label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
        ]),
      ),
    );
  }
}

/// Used only if LiveKit can't load: the call fails honestly.
class _NoRoom implements GroupRoom {
  @override
  Future<void> connect(String url, String token,
          {required bool camera, required bool mic}) async =>
      throw GroupRoomException('unreachable', 'livekit unavailable');
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> setMic(bool on) async {}
  @override
  Future<void> setCamera(bool on) async {}
  @override
  Future<void> flipCamera() async {}
  @override
  Future<void> setScreenShare(bool on) async {}
  @override
  Future<void> setSpeaker(bool on) async {}
  @override
  GroupLink get link => GroupLink.disconnected;
  @override
  String get disconnectReason => '';
  @override
  List<GroupMediaPeer> get peers => const [];
  @override
  List<String> get activeSpeakers => const [];
  @override
  String? trackSid(String identity, {required bool video}) => null;
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Widget? videoView(String identity, {bool screen = false}) => null;
}

/// Opens a group call screen (from a ring, a group chat or a 1:1 upgrade).
Future<void> openGroupCall(
  BuildContext context, {
  String? room,
  int? callId,
  int? groupId,
  List<int> memberIds = const [],
  bool video = false,
  String title = '',
  bool replace = false,
  CallController? handover,
}) {
  final route = MaterialPageRoute<void>(
      builder: (_) => GroupCallScreen(
          room: room,
          callId: callId,
          groupId: groupId,
          memberIds: memberIds,
          video: video,
          title: title,
          handover: handover));
  final nav = Navigator.of(context);
  return replace ? nav.pushReplacement(route) : nav.push(route);
}

/// The circle-group chat's call buttons (header + menu): available only when
/// the SFU is installed (GroupCallConfig) — otherwise not shown at all.
Future<void> startGroupChatCall(BuildContext context,
    {required int groupId, required String name, required bool video}) async {
  final app = context.read<AppState>();
  if (!await GroupCallConfig.refresh(app.api)) return;
  if (!context.mounted) return;
  await openGroupCall(context, groupId: groupId, video: video, title: name);
}
