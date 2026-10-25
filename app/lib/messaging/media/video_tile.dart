import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'media_descriptor.dart';

/// mc-media2 — the inline video in a chat bubble: the tiny first-frame
/// thumbnail (sealed inside the E2E message), the length, and either the
/// download control (auto-download settings decide) or a Play button that
/// opens the full-screen player. Nothing is decoded inline: the player is
/// created only on Play.
class VideoTile extends StatelessWidget {
  final MediaDescriptor? desc;
  final File? file;
  final Size box;
  final Widget thumb;
  final int? durationMs;
  final Widget? control; // download / progress ring (no file yet)
  final VoidCallback? onPlay;
  const VideoTile({
    super.key,
    this.desc,
    this.file,
    required this.box,
    required this.thumb,
    this.durationMs,
    this.control,
    this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ms = durationMs ?? desc?.durationMs;
    final ready = file != null && onPlay != null;
    final badge = [
      if (ms != null && ms > 0) mediaDurationLabel(ms),
      if (!ready && desc != null) mediaSizeLabel(desc!.size),
    ].join(' · ');
    return Semantics(
      label: t.circleVideo,
      button: ready,
      child: InkWell(
        key: Key('mc2-video-${desc?.ref ?? 'sending'}'),
        onTap: ready ? onPlay : null,
        borderRadius: BorderRadius.circular(Radii.md),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: SizedBox(
            width: box.width,
            height: box.height,
            child: Stack(fit: StackFit.expand, children: [
              const ColoredBox(color: Brand.ink),
              thumb,
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54],
                  ),
                ),
              ),
              Center(
                child: ready
                    ? Material(
                        color: Colors.black54,
                        shape: const CircleBorder(),
                        child: Padding(
                          padding: const EdgeInsets.all(Gap.sm),
                          child: Icon(Icons.play_arrow_rounded,
                              key: const Key('mc2-video-play'),
                              size: 40,
                              color: Colors.white,
                              semanticLabel: t.mc2PlayVideo),
                        ),
                      )
                    : (control ?? const SizedBox.shrink()),
              ),
              Positioned(
                left: Gap.sm,
                bottom: Gap.xs,
                right: Gap.sm,
                child: Row(children: [
                  const Icon(Icons.videocam_rounded, size: 16, color: Colors.white),
                  const SizedBox(width: Gap.xs),
                  Flexible(
                    child: Text(notifLocalizeDigits(context, badge),
                        key: const Key('mc2-video-badge'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
