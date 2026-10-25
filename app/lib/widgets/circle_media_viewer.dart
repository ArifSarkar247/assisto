import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Full-screen media viewer for circle photos/videos: pinch-zoom + swipe
/// between items, with a caption bar and save/forward actions. Decryption
/// happens on-device (see crypto/e2e.dart) — this viewer only ever receives
/// already-decrypted bytes via [MediaViewerItem.bytes] (or none, when the item
/// is still key-gated, in which case a lock placeholder is shown).
class MediaViewerItem {
  final String id;
  final Uint8List? bytes; // decrypted on-device; null when key-gated/undecryptable
  final String caption; // decrypted caption (may be empty)
  final bool isVideo;
  final bool gated; // storage not yet enabled
  // §21 download/cache affordance. When [bytes] is null but the item is NOT
  // gated, it is on the relay and [onDownload] pulls + decrypts it on-device.
  final VoidCallback? onDownload;
  final bool cachedLocally; // decrypted copy already on this device
  const MediaViewerItem({
    required this.id,
    this.bytes,
    this.caption = '',
    this.isVideo = false,
    this.gated = false,
    this.onDownload,
    this.cachedLocally = false,
  });

  /// Needs a download tap: not gated, nothing decrypted yet, and a puller wired.
  bool get needsDownload => !gated && bytes == null && onDownload != null;
}

class CircleMediaViewer extends StatefulWidget {
  final List<MediaViewerItem> items;
  final int initialIndex;
  final ValueChanged<MediaViewerItem>? onSave;
  final ValueChanged<MediaViewerItem>? onForward;
  final ValueChanged<MediaViewerItem>? onShare; // md1
  const CircleMediaViewer({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.onSave,
    this.onForward,
    this.onShare,
  });

  @override
  State<CircleMediaViewer> createState() => _CircleMediaViewerState();
}

class _CircleMediaViewerState extends State<CircleMediaViewer> {
  late final PageController _pager = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final item = widget.items.isEmpty ? null : widget.items[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.items.length}'),
        actions: [
          // mr1 NO SHOWPIECES: Save / Forward exist only for an item that is
          // really here (decrypted bytes) and a handler that really acts —
          // never a "saving will work when storage is enabled" answer.
          if (item != null && !item.gated && item.bytes != null &&
              widget.onSave != null)
            IconButton(
              key: const Key('mv-save'),
              tooltip: t.circleActionSave,
              icon: const Icon(Icons.save_alt_rounded),
              onPressed: () => widget.onSave!.call(item),
            ),
          if (item != null && !item.gated && item.bytes != null &&
              widget.onShare != null)
            IconButton(
              key: const Key('mv-share'),
              tooltip: t.md1Share,
              icon: const Icon(Icons.share_rounded),
              onPressed: () => widget.onShare!.call(item),
            ),
          if (item != null && !item.gated && item.bytes != null &&
              widget.onForward != null)
            IconButton(
              key: const Key('mv-forward'),
              tooltip: t.circleActionForward,
              icon: const Icon(Icons.forward_rounded),
              onPressed: () => widget.onForward!.call(item),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _pager,
        itemCount: widget.items.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => _page(widget.items[i], t),
      ),
    );
  }

  Widget _page(MediaViewerItem item, AppLocalizations t) {
    Widget content;
    if (item.needsDownload) {
      // §21 download affordance: on the relay but not yet on this device.
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_download_rounded,
                color: Colors.white70, size: 56),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              icon: const Icon(Icons.download_rounded),
              onPressed: item.onDownload,
              label: Text(t.circleActionDownload),
            ),
          ],
        ),
      );
    } else if (item.gated || item.bytes == null) {
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_clock_rounded, color: Colors.white70, size: 56),
            const SizedBox(height: Gap.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: Text(t.mr1MediaNotShown,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, height: 1.4)),
            ),
          ],
        ),
      );
    } else {
      final img = Image.memory(item.bytes!, fit: BoxFit.contain);
      content = InteractiveViewer(
        minScale: 1,
        maxScale: 5,
        child: Center(
          child: item.isVideo
              ? Stack(alignment: Alignment.center, children: [
                  img,
                  const Icon(Icons.play_circle_outline_rounded, color: Colors.white, size: 72),
                ])
              : img,
        ),
      );
    }
    return Column(
      children: [
        Expanded(child: content),
        if (item.caption.isNotEmpty)
          Container(
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(item.caption,
                style: const TextStyle(color: Colors.white, height: 1.4)),
          ),
      ],
    );
  }
}
