import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../call_avatar.dart';
import '../call_video.dart';
import '../media_ext.dart';
import '../screen_share.dart';
import 'group_call.dart';

/// callsB: the group call stage — a grid of 1–4 participant tiles (name,
/// mute icon, "speaking" ring from the audio level, camera-off avatar,
/// ringing / connecting state), the screen-share bar and the controls.
/// Dark call canvas in both themes (CallInk tokens), 48 dp targets,
/// every tile announced to TalkBack as one sentence.
class GroupCallView extends StatelessWidget {
  const GroupCallView({
    super.key,
    required this.session,
    required this.onHangup,
    required this.onAddPerson,
    this.share,
    this.selfView,
    this.onShareTap,
    this.onSpeaker,
    this.speakerOn = false,
    this.onMinimize,
  });

  final GroupCallSession session;
  final Future<void> Function() onHangup;
  final VoidCallback onAddPerson;
  final ScreenShareController? share;

  /// My camera preview (null = placeholder: tests / camera not open).
  final Widget Function()? selfView;
  final VoidCallback? onShareTap;
  final VoidCallback? onSpeaker;
  final bool speakerOn;
  final VoidCallback? onMinimize;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tiles = session.tiles;
    final r = session.roster;
    final n = notifLocalizeDigits(context, '${tiles.length}');
    final sharing = share?.sharing ?? false;
    return Scaffold(
      key: const Key('group-call'),
      backgroundColor: Brand.ink,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: Brand.heroDark),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Gap.sm, vertical: Gap.xs),
                child: Row(
                  children: [
                    if (onMinimize != null)
                      IconButton(
                        key: const Key('group-minimize'),
                        tooltip: t.b1CallMinimize,
                        color: CallInk.text,
                        icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        onPressed: onMinimize,
                      )
                    else
                      const SizedBox(width: Gap.xxxl),
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            (r?.groupName ?? '').isNotEmpty
                                ? r!.groupName
                                : t.cgTitle(n),
                            key: const Key('group-title'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: AType.titleMedium.copyWith(
                                color: CallInk.text,
                                fontWeight: FontWeight.w700),
                          ),
                          Text(
                            (r?.groupName ?? '').isNotEmpty
                                ? t.cgTitle(n)
                                : t.c2CallEncrypted,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: AType.bodySmall
                                .copyWith(color: CallInk.textHint),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Gap.xxxl),
                  ],
                ),
              ),
              if (sharing) ScreenShareBar(onStop: () => share!.stop()),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.sm),
                  child: GroupTilesGrid(
                    tiles: tiles,
                    video: session.video,
                    selfView: selfView,
                  ),
                ),
              ),
              if (share != null) ScreenShareNoticeText(share: share!),
              _GroupControls(
                session: session,
                share: share,
                onShareTap: onShareTap,
                onAddPerson: onAddPerson,
                onSpeaker: onSpeaker,
                speakerOn: speakerOn,
                onHangup: onHangup,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 1 tile = full, 2 = stacked, 3–4 = a 2 x 2 grid.
class GroupTilesGrid extends StatelessWidget {
  const GroupTilesGrid(
      {super.key, required this.tiles, required this.video, this.selfView});
  final List<GroupTile> tiles;
  final bool video;
  final Widget Function()? selfView;

  @override
  Widget build(BuildContext context) {
    final views = [
      for (final tl in tiles)
        GroupTileView(
            key: Key('group-tile-${tl.member.userId}'),
            tile: tl,
            video: video,
            selfView: selfView),
    ];
    if (views.isEmpty) return const SizedBox.shrink();
    if (views.length <= 2) {
      return Column(children: [
        for (final v in views)
          Expanded(
              child: Padding(
                  padding: const EdgeInsets.all(Gap.xs), child: v)),
      ]);
    }
    final rows = [views.sublist(0, 2), views.sublist(2)];
    return Column(children: [
      for (final row in rows)
        Expanded(
          child: Row(children: [
            for (final v in row)
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.all(Gap.xs), child: v)),
            if (row.length == 1) const Expanded(child: SizedBox.shrink()),
          ]),
        ),
    ]);
  }
}

class GroupTileView extends StatelessWidget {
  const GroupTileView(
      {super.key, required this.tile, required this.video, this.selfView});
  final GroupTile tile;
  final bool video;
  final Widget Function()? selfView;

  String _status(AppLocalizations t) => switch (tile.status) {
        'ringing' => t.cgRinging,
        'connecting' => t.cgConnecting,
        'reconnecting' => t.cgReconnecting,
        _ => '',
      };

  Widget? _videoView() {
    if (!tile.cameraOn && !tile.screen) return null;
    if (tile.me) return tile.cameraOn ? selfView?.call() : null;
    final Object? m = tile.controller?.media;
    if (tile.screen && m is ScreenShareSurface) {
      return m.remoteScreenView();
    }
    if (m is CallVideoSurface && m.hasRemoteVideo.value) return m.remoteView();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final name = tile.me ? t.cgYou : tile.member.name;
    final status = _status(t);
    final view = _videoView();
    final a11y = [
      name,
      if (status.isNotEmpty) status,
      if (tile.muted) t.cgMutedA11y,
      if (tile.speaking) t.cgSpeakingA11y,
      if (video && !tile.cameraOn && !tile.screen) t.cgCameraOffA11y,
      if (tile.screen) t.cgSharingA11y,
    ].join(', ');
    return Semantics(
      container: true,
      label: a11y,
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: CallInk.glass,
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(
                color: tile.speaking ? CallInk.good : Colors.transparent,
                width: 3),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (view != null)
                view
              else
                Center(
                  child: LayoutBuilder(builder: (ctx, c) {
                    final r = (c.biggest.shortestSide / 4).clamp(20.0, 48.0);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CallAvatar(
                            name: tile.member.name,
                            photoUrl: tile.member.photo,
                            version: tile.member.photoV,
                            radius: r),
                        if (status.isNotEmpty) ...[
                          const SizedBox(height: Gap.sm),
                          Text(status,
                              key: Key('group-tile-status-${tile.member.userId}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AType.bodySmall
                                  .copyWith(color: CallInk.textSoft)),
                        ],
                      ],
                    );
                  }),
                ),
              Positioned(
                left: Gap.sm,
                right: Gap.sm,
                bottom: Gap.sm,
                child: Row(
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: Gap.sm, vertical: Gap.xxs),
                        decoration: BoxDecoration(
                          color: CallInk.chip,
                          borderRadius: BorderRadius.circular(Radii.sm),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (tile.muted) ...[
                              Icon(Icons.mic_off_rounded,
                                  key: Key('group-tile-muted-${tile.member.userId}'),
                                  size: 14,
                                  color: CallInk.text),
                              const SizedBox(width: Gap.xs),
                            ],
                            if (tile.screen) ...[
                              const Icon(Icons.screen_share_rounded,
                                  size: 14, color: CallInk.text),
                              const SizedBox(width: Gap.xs),
                            ],
                            Flexible(
                              child: Text(name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AType.bodySmall
                                      .copyWith(color: CallInk.text)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (tile.speaking)
                Positioned(
                  top: Gap.sm,
                  right: Gap.sm,
                  child: Icon(Icons.graphic_eq_rounded,
                      key: Key('group-tile-speaking-${tile.member.userId}'),
                      size: 18,
                      color: CallInk.good),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The red "You're sharing your screen · Stop" bar (one tap to stop).
class ScreenShareBar extends StatelessWidget {
  const ScreenShareBar({super.key, required this.onStop});
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const Key('screen-share-bar'),
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
        padding: const EdgeInsets.only(left: Gap.md),
        decoration: BoxDecoration(
          color: Brand.dangerFill,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Row(
          children: [
            const Icon(Icons.screen_share_rounded, color: CallInk.text),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.ssSharingBar,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AType.bodyMedium.copyWith(
                      color: CallInk.text, fontWeight: FontWeight.w600)),
            ),
            TextButton(
              key: const Key('screen-share-stop'),
              style: TextButton.styleFrom(
                foregroundColor: CallInk.text,
                minimumSize: const Size(64, 48),
              ),
              onPressed: onStop,
              child: Text(t.ssStop,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The honest one-liner after a refused / failed screen share (or while it
/// is starting).
class ScreenShareNoticeText extends StatefulWidget {
  const ScreenShareNoticeText({super.key, required this.share});
  final ScreenShareController share;
  @override
  State<ScreenShareNoticeText> createState() => _ScreenShareNoticeTextState();
}

class _ScreenShareNoticeTextState extends State<ScreenShareNoticeText> {
  int _seq = 0;
  ScreenShareNotice _shown = ScreenShareNotice.none;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _seq = widget.share.noticeSeq;
    widget.share.addListener(_on);
  }

  void _on() {
    final s = widget.share;
    if (s.noticeSeq != _seq) {
      _seq = s.noticeSeq;
      _shown = s.notice;
      _timer?.cancel();
      _timer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _shown = ScreenShareNotice.none);
      });
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.share.removeListener(_on);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = widget.share.state == ScreenShareState.starting
        ? t.ssStarting
        : switch (_shown) {
            ScreenShareNotice.denied => t.ssDenied,
            ScreenShareNotice.failed => t.ssFailed,
            ScreenShareNotice.none => null,
          };
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
      child: Semantics(
        liveRegion: true,
        child: Container(
          key: const Key('screen-share-notice'),
          width: double.infinity,
          padding:
              const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
          decoration: BoxDecoration(
            color: CallInk.notice,
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: Text(text,
              textAlign: TextAlign.center,
              style: AType.bodyMedium.copyWith(color: CallInk.text)),
        ),
      ),
    );
  }
}

/// Our own explanation BEFORE the system screen-capture dialog. true =
/// "Continue".
Future<bool> showScreenShareConsent(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => ScreenShareConsentSheet(
        onAnswer: (yes) => Navigator.of(ctx).pop(yes)),
  );
  return ok == true;
}

class ScreenShareConsentSheet extends StatelessWidget {
  const ScreenShareConsentSheet({super.key, required this.onAnswer});
  final ValueChanged<bool> onAnswer;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.lg),
        child: Column(
          key: const Key('screen-share-consent'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.screen_share_rounded,
                  color: theme.colorScheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.ssConsentTitle, style: theme.textTheme.titleLarge),
              ),
            ]),
            const SizedBox(height: Gap.md),
            Text(t.ssConsentBody, style: theme.textTheme.bodyLarge),
            const SizedBox(height: Gap.xl),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                TextButton(
                  key: const Key('screen-share-consent-no'),
                  style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: () => onAnswer(false),
                  child: Text(t.ssConsentNo),
                ),
                FilledButton.icon(
                  key: const Key('screen-share-consent-go'),
                  style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                  icon: const Icon(Icons.screen_share_rounded),
                  onPressed: () => onAnswer(true),
                  label: Text(t.ssConsentGo),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "Share screen" tapped: our consent sheet, then the state machine.
Future<void> runScreenShareFlow(
    BuildContext context, ScreenShareController share) async {
  if (share.sharing) {
    await share.stop();
    return;
  }
  share.request();
  if (share.state != ScreenShareState.consent) return;
  final ok = await showScreenShareConsent(context);
  if (ok) {
    await share.confirm();
  } else {
    share.cancel();
  }
}

class _GroupControls extends StatelessWidget {
  const _GroupControls({
    required this.session,
    required this.share,
    required this.onShareTap,
    required this.onAddPerson,
    required this.onSpeaker,
    required this.speakerOn,
    required this.onHangup,
  });
  final GroupCallSession session;
  final ScreenShareController? share;
  final VoidCallback? onShareTap;
  final VoidCallback onAddPerson;
  final VoidCallback? onSpeaker;
  final bool speakerOn;
  final Future<void> Function() onHangup;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final video = session.video;
    final canShare = video && (share?.supported ?? false) && session.alive;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(vertical: Gap.md, horizontal: Gap.xs),
            decoration: BoxDecoration(
              color: CallInk.glass,
              borderRadius: BorderRadius.circular(Radii.xl),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CallCtl(
                  key: const Key('group-speaker'),
                  icon: speakerOn
                      ? Icons.volume_up_rounded
                      : Icons.phone_in_talk_rounded,
                  label: t.circleCallSpeaker,
                  active: speakerOn,
                  onTap: onSpeaker,
                ),
                if (video)
                  CallCtl(
                    key: const Key('group-camera'),
                    icon: session.cameraOn
                        ? Icons.videocam_rounded
                        : Icons.videocam_off_rounded,
                    label: t.circleCallCamera,
                    active: !session.cameraOn,
                    onTap: () => unawaited(session.toggleCamera()),
                  ),
                if (canShare)
                  CallCtl(
                    key: const Key('group-share-screen'),
                    icon: Icons.screen_share_rounded,
                    label: share!.sharing ? t.ssStop : t.ssShare,
                    active: share!.sharing,
                    onTap: share!.busy ? null : onShareTap,
                  ),
                CallCtl(
                  key: const Key('group-add-person'),
                  icon: Icons.person_add_alt_1_rounded,
                  label: t.cgAddPerson,
                  active: false,
                  onTap: session.canAdd ? onAddPerson : null,
                ),
                CallCtl(
                  key: const Key('group-mute'),
                  icon: session.muted
                      ? Icons.mic_off_rounded
                      : Icons.mic_none_rounded,
                  label: t.circleCallMute,
                  active: session.muted,
                  onTap: () => unawaited(session.toggleMute()),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.lg),
          Semantics(
            button: true,
            label: t.cgLeave,
            child: Material(
              color: Brand.danger,
              shape: const CircleBorder(),
              child: InkWell(
                key: const Key('group-hangup'),
                customBorder: const CircleBorder(),
                onTap: () => unawaited(onHangup()),
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
}

/// A round call control with its label under it (the label is part of the
/// 52 dp tap target; 2-line labels at large text sizes).
class CallCtl extends StatelessWidget {
  const CallCtl({
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
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AType.bodySmall.copyWith(color: CallInk.textSoft)),
          ],
        ),
      ),
    );
  }
}
