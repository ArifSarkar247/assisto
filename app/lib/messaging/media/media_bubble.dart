import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'media_descriptor.dart';
import 'media_outbox.dart';
import 'media_store.dart';
import 'video_tile.dart';
import 'voice_bubble.dart';

/// md1 — the media part of a My Circle bubble (photo / voice / document),
/// for a received or sent message ([desc]) or a send still on its way
/// ([job]: progress ring + cancel, honest failure + retry).
///
/// Received media shows the tiny encrypted-in-the-message thumbnail first,
/// then downloads (by itself on Wi-Fi; on mobile data only when the user
/// allowed that kind, otherwise a Download button with the size).
class MediaBubbleBody extends StatefulWidget {
  final MediaDescriptor? desc;
  final MediaJob? job;
  final bool mine;
  final Color fg;
  final void Function(File file, MediaDescriptor desc)? onOpen;
  const MediaBubbleBody({
    super.key,
    this.desc,
    this.job,
    required this.mine,
    required this.fg,
    this.onOpen,
  });

  @override
  State<MediaBubbleBody> createState() => _MediaBubbleBodyState();
}

class _MediaBubbleBodyState extends State<MediaBubbleBody> {
  File? _file;
  bool _autoTried = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(MediaBubbleBody old) {
    super.didUpdateWidget(old);
    if (old.desc?.ref != widget.desc?.ref) {
      _file = null;
      _autoTried = false;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final d = widget.desc;
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
    final d = widget.desc;
    if (d == null) return;
    final f = await MediaCache.instance.fetch(d);
    if (mounted && f != null) setState(() => _file = f);
  }

  String _err(AppLocalizations t, String code) => switch (code) {
        'gone' => t.md1ErrGone,
        'damaged' => t.md1ErrDamaged,
        _ => t.md1ErrNetwork,
      };

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    if (job != null) return _sending(context, job);
    final d = widget.desc!;
    return ValueListenableBuilder<Map<String, MediaDl>>(
      valueListenable: MediaCache.instance.states,
      builder: (context, states, _) {
        final st = states[d.ref];
        final file = _file ?? MediaCache.instance.cachedSync(d);
        switch (d.kind) {
          case 'photo':
            return _photo(context, d, file, st);
          case 'voice':
            return _voice(context, d, file, st);
          case 'video': // mc-media2
            return VideoTile(
              desc: d,
              file: file,
              box: _box(d.width, d.height),
              thumb: _thumb(d.thumb),
              control: file == null ? _dlControl(context, d, st, onImage: true) : null,
              onPlay: file == null ? null : () => widget.onOpen?.call(file, d),
            );
          default:
            return _document(context, d, file, st);
        }
      },
    );
  }

  // ---------------------------------------------------------------- photo
  Size _box(int? w, int? h) {
    const maxW = 240.0, maxH = 300.0;
    if (w == null || h == null || w <= 0 || h <= 0) return const Size(maxW, 180);
    final r = w / h;
    var bw = maxW, bh = maxW / r;
    if (bh > maxH) {
      bh = maxH;
      bw = maxH * r;
    }
    return Size(bw.clamp(120.0, maxW), bh.clamp(90.0, maxH));
  }

  Widget _photoFrame(Size box, Widget child) => ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(width: box.width, height: box.height, child: child),
      );

  Widget _thumb(Uint8List? thumb) {
    if (thumb == null) {
      return Container(color: Colors.black26);
    }
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
      child: Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }

  Widget _photo(BuildContext context, MediaDescriptor d, File? file, MediaDl? st) {
    final t = AppLocalizations.of(context);
    final box = _box(d.width, d.height);
    if (file != null) {
      return Semantics(
        label: t.circlePhoto,
        button: true,
        child: InkWell(
          key: Key('md1-photo-${d.ref}'),
          onTap: () => widget.onOpen?.call(file, d),
          child: _photoFrame(
              box,
              Image.file(file,
                  fit: BoxFit.cover,
                  cacheWidth: 720,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => _thumb(d.thumb))),
        ),
      );
    }
    return _photoFrame(
      box,
      Stack(fit: StackFit.expand, children: [
        _thumb(d.thumb),
        Center(child: _dlControl(context, d, st, onImage: true)),
      ]),
    );
  }

  /// Download button / progress ring with cancel / honest error + retry.
  Widget _dlControl(BuildContext context, MediaDescriptor d, MediaDl? st,
      {bool onImage = false}) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fg = onImage ? Colors.white : widget.fg;
    final bg = onImage ? Colors.black54 : widget.fg.withValues(alpha: 0.12);
    if (st != null && st.error.isEmpty) {
      return _ring(
          key: Key('md1-dl-cancel-${d.ref}'),
          progress: st.progress < 0 ? null : st.progress,
          fg: fg,
          bg: bg,
          tooltip: t.md1Cancel,
          onTap: () => MediaCache.instance.cancel(d.ref));
    }
    final label = st != null
        ? _err(t, st.error)
        : t.md1Download(notifLocalizeDigits(context, mediaSizeLabel(d.size)));
    return Material(
      color: st != null && onImage ? scheme.errorContainer : bg,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        key: Key('md1-dl-${d.ref}'),
        borderRadius: BorderRadius.circular(Radii.pill),
        onTap: _download,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(st != null ? Icons.refresh_rounded : Icons.download_rounded,
                size: 18, color: st != null && onImage ? scheme.onErrorContainer : fg),
            const SizedBox(width: Gap.xs),
            Flexible(
              child: Text(label,
                  maxLines: 3,
                  style: TextStyle(
                      fontSize: 12,
                      color: st != null && onImage ? scheme.onErrorContainer : fg)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _ring(
      {required Key key,
      required double? progress,
      required Color fg,
      required Color bg,
      required String tooltip,
      required VoidCallback onTap}) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          key: key,
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                    value: progress, strokeWidth: 3, color: fg),
              ),
              Icon(Icons.close_rounded, size: 18, color: fg),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- voice
  Widget _voice(BuildContext context, MediaDescriptor d, File? file, MediaDl? st) {
    final t = AppLocalizations.of(context);
    Widget? leading;
    if (file == null) {
      if (st != null && st.error.isEmpty) {
        leading = _ring(
            key: Key('md1-dl-cancel-${d.ref}'),
            progress: st.progress < 0 ? null : st.progress,
            fg: widget.fg,
            bg: widget.fg.withValues(alpha: 0.12),
            tooltip: t.md1Cancel,
            onTap: () => MediaCache.instance.cancel(d.ref));
      } else {
        leading = IconButton(
          key: Key('md1-dl-${d.ref}'),
          tooltip: t.md1Download(notifLocalizeDigits(context, mediaSizeLabel(d.size))),
          icon: Icon(st != null ? Icons.refresh_rounded : Icons.download_for_offline_rounded,
              size: 36, color: widget.fg),
          onPressed: _download,
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        VoiceNoteBody(
          path: file?.path,
          durationMs: d.durationMs ?? 0,
          wave: d.wave,
          fg: widget.fg,
          leading: leading,
          onPlayed: (ok) {
            if (!ok && context.mounted) {
              ScaffoldMessenger.maybeOf(context)
                  ?.showSnackBar(SnackBar(content: Text(t.md1PlayFailed)));
            }
          },
        ),
        if (st != null && st.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(_err(t, st.error),
                style: TextStyle(fontSize: 11, color: widget.fg.withValues(alpha: 0.85))),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- document
  Widget _docRow(BuildContext context,
      {required String name, required int size, required Widget trailing, VoidCallback? onTap, Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    final ext = name.contains('.') ? name.split('.').last.toUpperCase() : '';
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: onTap,
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(Gap.sm),
        decoration: BoxDecoration(
          color: widget.fg.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(children: [
          Container(
            width: 40,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Text(ext.length > 4 ? ext.substring(0, 4) : (ext.isEmpty ? 'FILE' : ext),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimaryContainer)),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name.isEmpty ? AppLocalizations.of(context).circleAttachDocument : name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: widget.fg, fontWeight: FontWeight.w600, fontSize: 13)),
                Text(notifLocalizeDigits(context, mediaSizeLabel(size)),
                    style: TextStyle(color: widget.fg.withValues(alpha: 0.75), fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: Gap.xs),
          trailing,
        ]),
      ),
    );
  }

  Widget _document(BuildContext context, MediaDescriptor d, File? file, MediaDl? st) {
    final t = AppLocalizations.of(context);
    if (file != null) {
      return _docRow(context,
          key: Key('md1-doc-${d.ref}'),
          name: d.name,
          size: d.plainSize,
          trailing: Icon(Icons.open_in_new_rounded, size: 18, color: widget.fg),
          onTap: () => widget.onOpen?.call(file, d));
    }
    final Widget trailing;
    if (st != null && st.error.isEmpty) {
      trailing = _ring(
          key: Key('md1-dl-cancel-${d.ref}'),
          progress: st.progress < 0 ? null : st.progress,
          fg: widget.fg,
          bg: widget.fg.withValues(alpha: 0.12),
          tooltip: t.md1Cancel,
          onTap: () => MediaCache.instance.cancel(d.ref));
    } else {
      trailing = Icon(st != null ? Icons.refresh_rounded : Icons.download_rounded,
          size: 22, color: widget.fg);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _docRow(context,
            key: Key('md1-dl-${d.ref}'),
            name: d.name,
            size: d.plainSize,
            trailing: trailing,
            onTap: st != null && st.error.isEmpty ? null : _download),
        if (st != null && st.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_err(t, st.error),
                style: TextStyle(fontSize: 11, color: widget.fg.withValues(alpha: 0.85))),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- sending
  Widget _sending(BuildContext context, MediaJob job) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: MediaOutbox.instance.progress,
      builder: (context, prog, _) {
        final p = prog[job.id];
        final ring = job.failed
            ? null
            : _ring(
                key: Key('md1-send-cancel-${job.id}'),
                progress: p == null || p < 0 ? null : p,
                fg: job.kind == 'photo' || job.kind == 'video' ? Colors.white : widget.fg,
                bg: job.kind == 'photo' || job.kind == 'video' ? Colors.black54 : widget.fg.withValues(alpha: 0.12),
                tooltip: t.md1CancelSend,
                onTap: () => MediaOutbox.instance.cancel(job.id));
        final status = job.failed
            ? (job.error == 'missing' ? t.md1ErrMissing : job.error)
            : p == null
                ? t.md1WaitingNet
                : p < 0
                    ? t.md1Preparing
                    : t.md1Sending;
        Widget body;
        switch (job.kind) {
          case 'photo':
            final box = _box(job.width, job.height);
            final src = File(job.srcPath);
            body = _photoFrame(
                box,
                Stack(fit: StackFit.expand, children: [
                  src.existsSync()
                      ? Image.file(src, fit: BoxFit.cover, cacheWidth: 720,
                          errorBuilder: (_, __, ___) => _thumb(null))
                      : _thumb(job.thumbB64.isEmpty ? null : base64Decode(job.thumbB64)),
                  if (ring != null) Center(child: ring),
                ]));
          case 'video': // mc-media2
            body = VideoTile(
              box: _box(job.width, job.height),
              thumb: _thumb(job.thumbB64.isEmpty ? null : base64Decode(job.thumbB64)),
              durationMs: job.durationMs,
              control: ring,
            );
          case 'voice':
            body = VoiceNoteBody(
              path: File(job.srcPath).existsSync() ? job.srcPath : null,
              durationMs: job.durationMs ?? 0,
              wave: job.wave,
              fg: widget.fg,
              leading: ring,
            );
          default:
            body = _docRow(context,
                name: job.name,
                size: job.plainSize,
                trailing: ring ?? Icon(Icons.error_outline_rounded, color: scheme.error));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            body,
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (job.failed)
                Icon(Icons.error_outline_rounded, size: 14, color: scheme.error)
              else
                Icon(Icons.schedule_rounded, size: 13, color: widget.fg.withValues(alpha: 0.8)),
              const SizedBox(width: 4),
              Flexible(
                child: Text(status.isEmpty ? t.md1SendFailed : status,
                    key: Key('md1-send-status-${job.id}'),
                    style: TextStyle(fontSize: 11, color: widget.fg.withValues(alpha: 0.85))),
              ),
            ]),
            if (job.failed)
              Wrap(spacing: Gap.xs, children: [
                TextButton(
                  key: Key('md1-send-retry-${job.id}'),
                  onPressed: () => MediaOutbox.instance.retry(job.id),
                  child: Text(t.md1Retry),
                ),
                TextButton(
                  key: Key('md1-send-remove-${job.id}'),
                  onPressed: () => MediaOutbox.instance.cancel(job.id),
                  child: Text(t.md1Remove),
                ),
              ]),
          ],
        );
      },
    );
  }
}
