import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'media_actions.dart';
import 'media_descriptor.dart';
import 'media_store.dart';
import 'video_player_screen.dart';

/// circlemedia — the full-screen viewer for a photo or a whole album:
/// swipe between items, pinch / double-tap zoom, Save to the phone and
/// Forward. While an item downloads its blurred thumbnail (from inside the
/// E2E message) is shown, never a blank screen; a failed download has a
/// Try again button.
Future<void> openAlbumViewer(BuildContext context, List<MediaDescriptor> items,
    {int initialIndex = 0, void Function(int index)? onForward}) {
  if (items.isEmpty) return Future.value();
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => AlbumViewer(
        items: items,
        initialIndex: initialIndex.clamp(0, items.length - 1),
        onForward: onForward),
  ));
}

class AlbumViewer extends StatefulWidget {
  final List<MediaDescriptor> items;
  final int initialIndex;
  final void Function(int index)? onForward;
  const AlbumViewer({super.key, required this.items, this.initialIndex = 0, this.onForward});

  @override
  State<AlbumViewer> createState() => _AlbumViewerState();
}

class _AlbumViewerState extends State<AlbumViewer> {
  late final PageController _pager = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _zoomed = false;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  MediaDescriptor get _cur => widget.items[_index];

  Future<void> _save() async {
    final f = MediaCache.instance.cachedSync(_cur) ?? await MediaCache.instance.fetch(_cur);
    if (!mounted || f == null) return;
    await saveMediaToPhone(context, f, _cur);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final n = widget.items.length;
    final cap = _cur.caption;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: n > 1
            ? Text(notifLocalizeDigits(context, t.cmCountOf('${_index + 1}', '$n')),
                key: const Key('cm-viewer-count'),
                style: const TextStyle(fontSize: 16, color: Colors.white))
            : null,
        actions: [
          IconButton(
            key: const Key('cm-viewer-save'),
            tooltip: t.circleActionSave,
            icon: const Icon(Icons.save_alt_rounded),
            onPressed: _save,
          ),
          if (widget.onForward != null)
            IconButton(
              key: const Key('cm-viewer-forward'),
              tooltip: t.circleActionForward,
              icon: const Icon(Icons.forward_rounded),
              onPressed: () => widget.onForward!(_index),
            ),
        ],
      ),
      body: Stack(children: [
        PageView.builder(
          key: const Key('cm-viewer-pager'),
          controller: _pager,
          // a zoomed photo pans instead of swiping to the next one
          physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
          itemCount: n,
          onPageChanged: (i) => setState(() {
            _index = i;
            _zoomed = false;
          }),
          itemBuilder: (_, i) => _ViewerPage(
            key: ValueKey('cm-page-${widget.items[i].ref}'),
            desc: widget.items[i],
            onZoom: (z) {
              if (z != _zoomed && mounted) setState(() => _zoomed = z);
            },
          ),
        ),
        if (cap.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black54,
              padding: withNavBarInset(
                  context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.md)),
              child: Text(cap,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, height: 1.4)),
            ),
          ),
      ]),
    );
  }
}

class _ViewerPage extends StatefulWidget {
  final MediaDescriptor desc;
  final ValueChanged<bool> onZoom;
  const _ViewerPage({super.key, required this.desc, required this.onZoom});
  @override
  State<_ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<_ViewerPage> {
  final _tc = TransformationController();
  File? _file;
  bool _failed = false;
  TapDownDetails? _tap;

  @override
  void initState() {
    super.initState();
    _tc.addListener(() => widget.onZoom(_tc.value.getMaxScaleOnAxis() > 1.01));
    _file = MediaCache.instance.cachedSync(widget.desc);
    if (_file == null) unawaited(Future<void>.microtask(_load));
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_failed) setState(() => _failed = false);
    final d = widget.desc;
    final f = MediaCache.instance.cachedSync(d) ??
        await MediaCache.instance.cached(d) ??
        await MediaCache.instance.fetch(d);
    if (!mounted) return;
    setState(() {
      _file = f;
      _failed = f == null;
    });
  }

  void _doubleTap() {
    if (_tc.value.getMaxScaleOnAxis() > 1.01) {
      _tc.value = Matrix4.identity();
      return;
    }
    final p = _tap?.localPosition ?? Offset.zero;
    const z = 2.5; // zoom in around the tapped point
    _tc.value = Matrix4.identity()
      ..setEntry(0, 0, z)
      ..setEntry(1, 1, z)
      ..setEntry(0, 3, -(z - 1) * p.dx)
      ..setEntry(1, 3, -(z - 1) * p.dy);
  }

  Widget _placeholder() {
    final th = widget.desc.thumb;
    return Stack(fit: StackFit.expand, children: [
      if (th != null)
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Image.memory(th, fit: BoxFit.contain, gaplessPlayback: true),
        ),
      Center(
        child: _failed
            ? FilledButton.icon(
                key: Key('cm-viewer-retry-${widget.desc.ref}'),
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(AppLocalizations.of(context).md1Retry),
              )
            : const CircularProgressIndicator(color: Colors.white),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final f = _file;
    if (f == null) return _placeholder();
    if (widget.desc.kind == 'video') {
      return Stack(fit: StackFit.expand, children: [
        if (widget.desc.thumb != null)
          Image.memory(widget.desc.thumb!, fit: BoxFit.contain, gaplessPlayback: true),
        Center(
          child: IconButton.filled(
            key: Key('cm-viewer-play-${widget.desc.ref}'),
            tooltip: t.cmPlayVideo,
            iconSize: 48,
            onPressed: () =>
                unawaited(openVideoPlayer(context, f, caption: widget.desc.caption)),
            icon: const Icon(Icons.play_arrow_rounded),
          ),
        ),
      ]);
    }
    return GestureDetector(
      onDoubleTapDown: (d) => _tap = d,
      onDoubleTap: _doubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 1,
        maxScale: 5,
        child: Center(
          child: Image.file(
            f,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            semanticLabel: t.circlePhoto,
            frameBuilder: (_, child, frame, sync) =>
                sync || frame != null ? child : _placeholder(),
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 64),
          ),
        ),
      ),
    );
  }
}
