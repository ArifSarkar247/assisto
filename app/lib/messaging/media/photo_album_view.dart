import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'album.dart';
import 'media_descriptor.dart';
import 'media_outbox.dart';
import 'media_store.dart';

/// circlemedia — the photo / video / album bubble.
///
/// The picture runs edge to edge inside the bubble (about 16 dp corners, no
/// frame, no padding) at its real aspect ratio within min / max sizes; the
/// time and ticks sit on a small soft dark pill at the bottom right; a
/// caption appears under the picture only when there is one. An album is a
/// grid: 2 side by side, 3 = one large + two small, 4 = 2×2, more = 2×2 with
/// "+N". Received items show their tiny blurred thumbnail (it travels inside
/// the E2E message) until the real file has downloaded and decrypted.
///
/// This is its own widget so other bubble variants (e.g. view once) render
/// separately and never inherit album behaviour by accident.

/// One item of the bubble: a received / sent item ([desc]) or one still on
/// its way out ([job]).
class AlbumItem {
  final String id; // message id (or client id while sending)
  final MediaDescriptor? desc;
  final MediaJob? job;
  const AlbumItem({required this.id, this.desc, this.job});

  String get kind => desc?.kind ?? job?.kind ?? 'photo';
  int? get width => desc?.width ?? job?.width;
  int? get height => desc?.height ?? job?.height;
  int? get durationMs => desc?.durationMs ?? job?.durationMs;
  Uint8List? get thumb {
    if (desc != null) return desc!.thumb;
    final b = job?.thumbB64 ?? '';
    if (b.isEmpty) return null;
    try {
      return base64Decode(b);
    } catch (_) {
      return null;
    }
  }

  String get key => desc?.ref ?? job?.id ?? id;
}

/// Bubble corner radius (about 16 dp).
const double kPhotoBubbleRadius = Radii.lg;

/// The widest a photo bubble may be on this screen.
double photoBubbleMaxWidth(BuildContext context) =>
    (MediaQuery.sizeOf(context).width * 0.72).clamp(160.0, 300.0);

/// The picture area's size for [items] at the screen's max width.
Size albumBoxSize(BuildContext context, List<AlbumItem> items) {
  final maxW = photoBubbleMaxWidth(context);
  if (items.length == 1) {
    final s = photoBubbleSize(items.first.width, items.first.height, maxW);
    return Size(s.w, s.h);
  }
  return Size(maxW, maxW * albumLayout(items.length).heightFactor);
}

/// The grid of pictures (no frame). [onOpen] gets the item index and its
/// decrypted file (null while it isn't on the phone).
class PhotoAlbumView extends StatelessWidget {
  final List<AlbumItem> items;
  final Size size;
  final void Function(int index, File file)? onOpen;
  const PhotoAlbumView({super.key, required this.items, required this.size, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lay = albumLayout(items.length);
    final w = size.width;
    const gap = 2.0;
    return Semantics(
      container: true,
      label: items.length > 1
          ? notifLocalizeDigits(context, t.cmAlbumLabel('${items.length}'))
          : null,
      child: SizedBox(
        key: Key('cm-album-${items.length}'),
        width: size.width,
        height: size.height,
        child: Stack(children: [
          for (var i = 0; i < lay.tiles.length && i < items.length; i++)
            _place(lay, i, w,
              AlbumTile(
                key: ValueKey('cm-tile-${items[i].key}'),
                item: items[i],
                index: i,
                overflow: i == lay.tiles.length - 1 ? lay.overflow : 0,
                onOpen: onOpen,
              )),
        ]),
      ),
    );
  }
}

/// Places tile [i] of [lay] in a grid [w] wide, with a 2 dp gap between
/// tiles (a single picture fills the whole box).
Widget _place(AlbumLayout lay, int i, double w, Widget child) {
  if (lay.tiles.length == 1) return Positioned.fill(child: child);
  final s = lay.tiles[i];
  const g = 1.0; // half the gap
  return Positioned(
    left: s.x * w,
    top: s.y * w,
    width: s.w * w,
    height: s.h * w,
    child: Padding(
      padding: EdgeInsets.only(
        left: s.x > 0 ? g : 0,
        top: s.y > 0 ? g : 0,
        right: s.x + s.w < 0.999 ? g : 0,
        bottom: s.y + s.h < lay.heightFactor - 0.001 ? g : 0,
      ),
      child: child,
    ),
  );
}

/// One picture of the grid: cached file / blurred thumbnail + download or
/// upload state.
class AlbumTile extends StatefulWidget {
  final AlbumItem item;
  final int index;
  final int overflow;
  final void Function(int index, File file)? onOpen;
  const AlbumTile(
      {super.key, required this.item, required this.index, this.overflow = 0, this.onOpen});

  @override
  State<AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<AlbumTile> {
  File? _file;
  bool _autoTried = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(AlbumTile old) {
    super.didUpdateWidget(old);
    if (old.item.desc?.ref != widget.item.desc?.ref) {
      _file = null;
      _autoTried = false;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final d = widget.item.desc;
    if (d == null) return;
    final f = MediaCache.instance.cachedSync(d) ?? await MediaCache.instance.cached(d);
    if (!mounted) return;
    if (f != null) {
      setState(() => _file = f);
      return;
    }
    if (_autoTried) return;
    _autoTried = true;
    if (await MediaPrefs.shouldAutoDownload(d.kind)) await _download();
  }

  Future<void> _download() async {
    final d = widget.item.desc;
    if (d == null) return;
    final f = await MediaCache.instance.fetch(d);
    if (mounted && f != null) setState(() => _file = f);
  }

  Widget _thumb() {
    final th = widget.item.thumb;
    if (th == null) return const ColoredBox(color: Color(0xFF3A3F47));
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: Image.memory(th, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }

  Widget _picture(File f) => Image.file(
        f,
        fit: BoxFit.cover,
        cacheWidth: 720,
        gaplessPlayback: true,
        // blurred placeholder until the real picture is decoded
        frameBuilder: (_, child, frame, sync) => sync || frame != null
            ? child
            : Stack(fit: StackFit.expand, children: [_thumb()]),
        errorBuilder: (_, __, ___) => _thumb(),
      );

  Widget _round({required Key key, required IconData icon, double? progress, required VoidCallback? onTap, required String tip}) =>
      Tooltip(
        message: tip,
        child: Material(
          color: Colors.black54,
          shape: const CircleBorder(),
          child: InkWell(
            key: key,
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: kMinTap,
              height: kMinTap,
              child: Stack(alignment: Alignment.center, children: [
                if (progress != null || icon == Icons.close_rounded)
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                        value: progress, strokeWidth: 3, color: Colors.white),
                  ),
                Icon(icon, size: 20, color: Colors.white),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final job = it.job;
    if (job != null) return _sendingTile(context, job);
    final d = it.desc!;
    return ValueListenableBuilder<Map<String, MediaDl>>(
      valueListenable: MediaCache.instance.states,
      builder: (context, states, _) {
        final t = AppLocalizations.of(context);
        final st = states[d.ref];
        final file = _file ?? MediaCache.instance.cachedSync(d);
        Widget? control;
        if (file == null) {
          if (st != null && st.error.isEmpty) {
            control = _round(
                key: Key('cm-dl-cancel-${d.ref}'),
                icon: Icons.close_rounded,
                progress: st.progress < 0 ? null : st.progress,
                tip: t.md1Cancel,
                onTap: () => MediaCache.instance.cancel(d.ref));
          } else {
            control = _round(
                key: Key('cm-dl-${d.ref}'),
                icon: st != null ? Icons.refresh_rounded : Icons.download_rounded,
                tip: st != null
                    ? t.cmPhotoLoadFailed
                    : t.md1Download(notifLocalizeDigits(context, mediaSizeLabel(d.size))),
                onTap: _download);
          }
        }
        return _frame(
          context,
          base: file != null && d.kind == 'photo' ? _picture(file) : _thumb(),
          center: control ??
              (d.kind == 'video'
                  ? const CircleAvatar(
                      radius: 22,
                      backgroundColor: Colors.black54,
                      child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30))
                  : null),
          onTap: file == null
              ? (st == null || st.error.isNotEmpty ? _download : null)
              : () => widget.onOpen?.call(widget.index, file),
          label: d.kind == 'video' ? t.cmPlayVideo : t.circlePhoto,
          video: d.kind == 'video',
        );
      },
    );
  }

  Widget _sendingTile(BuildContext context, MediaJob job) {
    final t = AppLocalizations.of(context);
    final src = File(job.srcPath);
    final base = job.kind == 'photo' && src.existsSync()
        ? Image.file(src,
            fit: BoxFit.cover, cacheWidth: 720, gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _thumb())
        : _thumb();
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: MediaOutbox.instance.progress,
      builder: (context, prog, _) {
        final p = prog[job.id];
        final Widget center = job.failed
            ? _round(
                key: Key('cm-send-retry-${job.id}'),
                icon: Icons.refresh_rounded,
                tip: t.md1Retry,
                onTap: () => MediaOutbox.instance.retry(job.id))
            : _round(
                key: Key('cm-send-cancel-${job.id}'),
                icon: Icons.close_rounded,
                progress: p == null || p < 0 ? null : p,
                tip: t.md1CancelSend,
                onTap: () => MediaOutbox.instance.cancel(job.id));
        return _frame(context,
            base: base,
            center: center,
            onTap: null,
            label: job.kind == 'video' ? t.circleVideo : t.circlePhoto,
            video: job.kind == 'video');
      },
    );
  }

  Widget _frame(BuildContext context,
      {required Widget base,
      Widget? center,
      VoidCallback? onTap,
      required String label,
      bool video = false}) {
    final ms = widget.item.durationMs;
    return Semantics(
      button: onTap != null,
      label: label,
      child: GestureDetector(
        key: Key('cm-open-${widget.item.key}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(fit: StackFit.expand, children: [
          const ColoredBox(color: Color(0xFF2A2E35)),
          base,
          if (video && ms != null && ms > 0)
            Positioned(
              left: Gap.xs,
              bottom: Gap.xs,
              child: _SoftPill(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.videocam_rounded, size: 13, color: Colors.white),
                  const SizedBox(width: 3),
                  Text(notifLocalizeDigits(context, mediaDurationLabel(ms)),
                      style: const TextStyle(color: Colors.white, fontSize: 11)),
                ]),
              ),
            ),
          if (widget.overflow > 0)
            ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Text(notifLocalizeDigits(context, '+${widget.overflow}'),
                    key: const Key('cm-album-more'),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700)),
              ),
            ),
          if (center != null && widget.overflow == 0) Center(child: center),
        ]),
      ),
    );
  }
}

/// The small soft dark pill (time + ticks, video length).
class _SoftPill extends StatelessWidget {
  final Widget child;
  const _SoftPill({required this.child});
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: child,
        ),
      );
}

/// The time + ticks pill shown on the picture's bottom-right corner.
class PhotoMetaPill extends StatelessWidget {
  final List<Widget> children;
  const PhotoMetaPill({super.key, required this.children});
  @override
  Widget build(BuildContext context) => _SoftPill(
        child: IconTheme.merge(
          data: const IconThemeData(color: Colors.white),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white, fontSize: 11),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      );
}

/// The whole edge-to-edge photo / album bubble: optional [header]
/// (sender, forwarded, reply quote), the pictures with the [meta] pill, an
/// optional [caption], and the album's send status while items are on
/// their way.
class PhotoBubbleShell extends StatelessWidget {
  final List<AlbumItem> items;
  final Color bg;
  final Color fg;
  final Widget? header;
  final Widget? caption;
  final Widget meta;
  final void Function(int index, File file)? onOpen;
  final BorderRadius? radius;
  const PhotoBubbleShell({
    super.key,
    required this.items,
    required this.bg,
    required this.fg,
    required this.meta,
    this.header,
    this.caption,
    this.onOpen,
    this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final size = albumBoxSize(context, items);
    final status = AlbumSendStatus(items: items, fg: fg);
    return Container(
      key: const Key('cm-photo-bubble'),
      width: size.width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius ?? BorderRadius.circular(kPhotoBubbleRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.xs),
              child: header,
            ),
          // edge to edge: the bubble's own rounded corners clip the picture
          Stack(children: [
            PhotoAlbumView(items: items, size: size, onOpen: onOpen),
            Positioned(right: 6, bottom: 6, child: meta),
          ]),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
              child: caption,
            ),
          if (status.visible)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.xs),
              child: status,
            ),
        ],
      ),
    );
  }
}

/// While items are on their way: "Waiting for internet" / "2 of 5 sent",
/// and for failed items the honest reason + Retry / Remove.
class AlbumSendStatus extends StatelessWidget {
  final List<AlbumItem> items;
  final Color fg;
  const AlbumSendStatus({super.key, required this.items, required this.fg});

  List<MediaJob> get _jobs => [for (final i in items) if (i.job != null) i.job!];
  bool get visible => _jobs.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final jobs = _jobs;
    final failed = jobs.where((j) => j.failed).toList();
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: MediaOutbox.instance.progress,
      builder: (context, prog, _) {
        String status;
        if (failed.isNotEmpty) {
          final e = failed.first.error;
          status = e == 'missing' ? t.md1ErrMissing : (e.isEmpty ? t.md1SendFailed : e);
        } else if (items.length > 1) {
          status = notifLocalizeDigits(
              context, t.cmAlbumSent('${items.length - jobs.length}', '${items.length}'));
        } else {
          final p = prog[jobs.first.id];
          status = p == null ? t.md1WaitingNet : (p < 0 ? t.md1Preparing : t.md1Sending);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(failed.isNotEmpty ? Icons.error_outline_rounded : Icons.schedule_rounded,
                  size: 14, color: failed.isNotEmpty ? scheme.error : fg.withValues(alpha: 0.85)),
              const SizedBox(width: 4),
              Flexible(
                child: Text(status,
                    key: const Key('cm-album-status'),
                    style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.9))),
              ),
            ]),
            if (failed.isNotEmpty)
              Wrap(spacing: Gap.xs, children: [
                TextButton(
                  key: const Key('cm-album-retry'),
                  style: TextButton.styleFrom(foregroundColor: fg),
                  onPressed: () {
                    for (final j in failed) {
                      unawaited(MediaOutbox.instance.retry(j.id));
                    }
                  },
                  child: Text(t.md1Retry),
                ),
                TextButton(
                  key: const Key('cm-album-remove'),
                  style: TextButton.styleFrom(foregroundColor: fg),
                  onPressed: () {
                    for (final j in failed) {
                      unawaited(MediaOutbox.instance.cancel(j.id));
                    }
                  },
                  child: Text(t.md1Remove),
                ),
              ]),
          ],
        );
      },
    );
  }
}
