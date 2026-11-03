import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';

import '../../l10n/app_localizations.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'media_descriptor.dart';
import 'media_prep.dart';
import 'photo_prep.dart';
import 'view_once_toggle.dart';

/// circlemedia — the preview before sending one or many photos / videos:
/// swipe through them, remove one, crop, rotate, one caption for the whole
/// album, HD or Standard, then Send. The thumbnail strip at the bottom shows
/// every item (tap to jump, "+" to add more).
///
/// The send bar has a clean slot for extra trailing controls next to Send:
/// the view-once "1" ([allowViewOnce]) and anything in [sendBarExtras].

/// One item as the user left it in the preview.
class AlbumSendItem {
  final MediaDraft draft;

  /// Quarter turns clockwise chosen with Rotate (photos only).
  final int turns;
  const AlbumSendItem(this.draft, {this.turns = 0});
}

/// What Send returns.
class AlbumSendChoice {
  final List<AlbumSendItem> items;
  final String caption;
  final bool hd;
  final bool viewOnce;
  const AlbumSendChoice(this.items,
      {this.caption = '', this.hd = false, this.viewOnce = false});
}

class AlbumSendPreview extends StatefulWidget {
  final List<MediaDraft> drafts;

  /// The most items one send may carry (MediaLimits.photosPerSend).
  final int limit;

  /// "+" — pick more; gets how many may still be added. null = no "+".
  final Future<List<MediaDraft>> Function(int remaining)? onAddMore;

  /// e-gaps: show the "1" (view once) toggle next to Send.
  final bool allowViewOnce;
  final bool initialViewOnce;
  final bool initialHd;

  /// Extra trailing controls placed right before Send.
  final List<Widget> sendBarExtras;

  /// Seam: crop one photo (path in → new path out; null = cancelled).
  final Future<String?> Function(BuildContext context, String path)? cropper;

  const AlbumSendPreview({
    super.key,
    required this.drafts,
    this.limit = 30,
    this.onAddMore,
    this.allowViewOnce = false,
    this.initialViewOnce = false,
    this.initialHd = false,
    this.sendBarExtras = const [],
    this.cropper,
  });

  @override
  State<AlbumSendPreview> createState() => _AlbumSendPreviewState();
}

class _AlbumSendPreviewState extends State<AlbumSendPreview> {
  late final List<AlbumSendItem> _items = [
    for (final d in widget.drafts) AlbumSendItem(d)
  ];
  final _caption = TextEditingController();
  late final PageController _pager = PageController();
  late bool _hd = widget.initialHd;
  late bool _viewOnce = widget.initialViewOnce;
  int _index = 0;
  bool _busy = false;
  int _rev = 0; // bumps when a file changes in place (image cache)
  bool _sent = false;

  @override
  void dispose() {
    // cancel / back: nothing of the unsent picks stays on the phone
    if (!_sent) deleteDraftFiles(_items.map((i) => i.draft));
    _caption.dispose();
    _pager.dispose();
    super.dispose();
  }

  AlbumSendItem get _cur => _items[_index.clamp(0, _items.length - 1)];
  bool get _curIsPhoto => _cur.draft.kind == 'photo';

  String _d(String s) => notifLocalizeDigits(context, s);

  void _snack(String msg) => ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(msg)));

  void _rotate() {
    if (!_curIsPhoto) return;
    setState(() => _items[_index] =
        AlbumSendItem(_cur.draft, turns: (_cur.turns + 1) % 4));
  }

  void _remove() {
    final it = _cur;
    _deleteQuietly(it.draft.path);
    if (_items.length == 1) {
      Navigator.pop(context); // nothing left: same as cancel
      return;
    }
    setState(() {
      _items.removeAt(_index);
      if (_index >= _items.length) _index = _items.length - 1;
    });
    if (_pager.hasClients) _pager.jumpToPage(_index);
  }

  void _go(int i) {
    setState(() => _index = i);
    if (_pager.hasClients) {
      _pager.animateToPage(i,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  Future<void> _crop() async {
    if (!_curIsPhoto || _busy) return;
    final t = AppLocalizations.of(context);
    final at = _index;
    final it = _cur;
    setState(() => _busy = true);
    try {
      var path = it.draft.path;
      // the cropper works on the picture as stored: bake the chosen
      // rotation in first so what the user saw is what they crop
      if (it.turns != 0) {
        final out = await photoPrep(await File(path).readAsBytes(),
            turns: it.turns, maxEdge: kHdEdge, quality: 95);
        if (out == null) throw StateError('rotate');
        await File(path).writeAsBytes(out.bytes, flush: true);
      }
      if (!mounted) return;
      final cropped = await (widget.cropper ?? _systemCrop)(context, path);
      if (!mounted) return;
      if (cropped == null) {
        if (it.turns != 0) {
          // rotation already baked in: keep it, now as 0 turns
          final d = await preparePhotoBytes(await File(path).readAsBytes(), it.draft.name);
          _deleteQuietly(path);
          if (mounted) setState(() => _items[at] = AlbumSendItem(d));
        }
        return;
      }
      final d = await preparePhotoBytes(await File(cropped).readAsBytes(), it.draft.name);
      _deleteQuietly(path);
      if (cropped != path) _deleteQuietly(cropped);
      if (mounted) {
        setState(() {
          _items[at] = AlbumSendItem(d);
          _rev++;
        });
      }
    } catch (e) {
      reportNonFatal('cm_crop', e);
      if (mounted) _snack(t.cmEditFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<String?> _systemCrop(BuildContext context, String path) async {
    final t = AppLocalizations.of(context);
    final c = await ImageCropper().cropImage(
      sourcePath: path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: t.camCropTitle,
          toolbarColor: Colors.black,
          toolbarWidgetColor: Colors.white,
          backgroundColor: Colors.black,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: t.camCropTitle),
      ],
    );
    return c?.path;
  }

  Future<void> _addMore() async {
    final add = widget.onAddMore;
    final left = widget.limit - _items.length;
    if (add == null || left <= 0 || _busy) return;
    setState(() => _busy = true);
    try {
      final more = await add(left);
      if (!mounted || more.isEmpty) return;
      setState(() {
        _items.addAll(more.take(left).map(AlbumSendItem.new));
        _index = _items.length - more.take(left).length;
      });
      if (_pager.hasClients) _pager.jumpToPage(_index);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _send() {
    if (_busy || _items.isEmpty) return;
    _sent = true;
    Navigator.pop(
        context,
        AlbumSendChoice(List.unmodifiable(_items),
            caption: _caption.text.trim(), hd: _hd, viewOnce: _viewOnce));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final many = _items.length > 1;
    final hasPhoto = _items.any((i) => i.draft.kind == 'photo');
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          key: const Key('cm-preview-close'),
          tooltip: t.md1Cancel,
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: many
            ? Text(_d(t.cmCountOf('${_index + 1}', '${_items.length}')),
                key: const Key('cm-preview-count'),
                style: const TextStyle(fontSize: 16))
            : null,
        actions: [
          if (hasPhoto)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
              child: Tooltip(
                message: _hd ? t.cmHdOnHint : t.cmHdOffHint,
                child: Semantics(
                  toggled: _hd,
                  button: true,
                  label: _hd ? t.cmHdOnHint : t.cmHdOffHint,
                  child: InkWell(
                    key: const Key('cm-hd-toggle'),
                    borderRadius: BorderRadius.circular(Radii.pill),
                    onTap: () {
                      setState(() => _hd = !_hd);
                      _snack(_hd ? t.cmHdOnHint : t.cmHdOffHint);
                    },
                    child: Container(
                      constraints: const BoxConstraints(minHeight: kMinTap, minWidth: kMinTap),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
                        decoration: BoxDecoration(
                          color: _hd ? Colors.white : Colors.transparent,
                          border: Border.all(color: Colors.white, width: 1.5),
                          borderRadius: BorderRadius.circular(Radii.sm),
                        ),
                        child: Text(_hd ? t.cmHd : t.cmStandard,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _hd ? Colors.black : Colors.white)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_curIsPhoto) ...[
            IconButton(
              key: const Key('cm-crop'),
              tooltip: t.cmCrop,
              icon: const Icon(Icons.crop_rounded),
              onPressed: _busy ? null : _crop,
            ),
            IconButton(
              key: const Key('cm-rotate'),
              tooltip: t.cmRotate,
              icon: const Icon(Icons.rotate_90_degrees_cw_rounded),
              onPressed: _busy ? null : _rotate,
            ),
          ],
          IconButton(
            key: const Key('cm-remove'),
            tooltip: t.cmRemoveItem,
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _busy ? null : _remove,
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Stack(children: [
            PageView.builder(
              key: const Key('cm-preview-pager'),
              controller: _pager,
              itemCount: _items.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => _page(_items[i]),
            ),
            if (_busy)
              const Positioned.fill(
                  child: ColoredBox(
                      color: Colors.black38,
                      child: Center(child: CircularProgressIndicator()))),
          ]),
        ),
        if (many || widget.onAddMore != null) _strip(t),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.md),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('cm-caption'),
                  controller: _caption,
                  minLines: 1,
                  maxLines: 4,
                  textAlignVertical: TextAlignVertical.center,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: t.md1CaptionHint,
                    hintStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: Colors.white12,
                    border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(Radii.pill)),
                        borderSide: BorderSide.none),
                    constraints: const BoxConstraints(minHeight: kMinTap),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
                  ),
                ),
              ),
              // the trailing slot: view once + any extras, then Send
              if (widget.allowViewOnce) ...[
                const SizedBox(width: Gap.xs),
                ViewOnceToggle(
                    value: _viewOnce, onChanged: (v) => setState(() => _viewOnce = v)),
              ],
              for (final w in widget.sendBarExtras) ...[
                const SizedBox(width: Gap.xs),
                w,
              ],
              const SizedBox(width: Gap.sm),
              Badge(
                isLabelVisible: many,
                label: Text(_d('${_items.length}')),
                child: IconButton.filled(
                  key: const Key('cm-send'),
                  tooltip: many ? _d(t.cmSendCount('${_items.length}')) : t.md1Send,
                  onPressed: _busy ? null : _send,
                  icon: const Icon(Icons.send_rounded),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _page(AlbumSendItem it) {
    final d = it.draft;
    if (d.kind == 'video') {
      return Center(
        child: Stack(alignment: Alignment.center, children: [
          if (d.thumbB64.isNotEmpty)
            Image.memory(base64Decode(d.thumbB64),
                fit: BoxFit.contain, gaplessPlayback: true, width: double.infinity)
          else
            const Icon(Icons.videocam_rounded, color: Colors.white54, size: 72),
          const CircleAvatar(
              radius: 30,
              backgroundColor: Colors.black54,
              child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 40)),
          if (d.durationMs != null)
            Positioned(
              bottom: Gap.md,
              child: Text(
                  _d('${mediaDurationLabel(d.durationMs!)} · ${mediaSizeLabel(d.size)}'),
                  style: const TextStyle(color: Colors.white)),
            ),
        ]),
      );
    }
    return InteractiveViewer(
      maxScale: 4,
      child: Center(
        child: RotatedBox(
          quarterTurns: it.turns,
          child: Image.file(File(d.path),
              key: ValueKey('${d.path}#$_rev'),
              fit: BoxFit.contain,
              cacheWidth: 1080,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 64)),
        ),
      ),
    );
  }

  Widget _strip(AppLocalizations t) {
    final canAdd = widget.onAddMore != null && _items.length < widget.limit;
    return SizedBox(
      height: 64,
      child: ListView.separated(
        key: const Key('cm-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        itemCount: _items.length + (canAdd ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(width: Gap.xs),
        itemBuilder: (_, i) {
          if (i >= _items.length) {
            return Tooltip(
              message: t.cmAddMore,
              child: InkWell(
                key: const Key('cm-add-more'),
                onTap: _busy ? null : _addMore,
                borderRadius: BorderRadius.circular(Radii.sm),
                child: Container(
                  width: 56,
                  height: 56,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white54),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: const Icon(Icons.add_photo_alternate_rounded, color: Colors.white),
                ),
              ),
            );
          }
          final it = _items[i];
          final sel = i == _index;
          return Semantics(
            selected: sel,
            button: true,
            label: _d(t.cmCountOf('${i + 1}', '${_items.length}')),
            child: InkWell(
              key: Key('cm-thumb-$i'),
              onTap: () => _go(i),
              child: Container(
                width: 56,
                height: 56,
                margin: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: sel ? Colors.white : Colors.transparent, width: 2),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.sm - 2),
                  child: Stack(fit: StackFit.expand, children: [
                    if (it.draft.kind == 'video')
                      it.draft.thumbB64.isEmpty
                          ? const ColoredBox(color: Colors.white12)
                          : Image.memory(base64Decode(it.draft.thumbB64), fit: BoxFit.cover)
                    else
                      RotatedBox(
                        quarterTurns: it.turns,
                        child: Image.file(File(it.draft.path),
                            key: ValueKey('${it.draft.path}#$_rev'),
                            fit: BoxFit.cover,
                            cacheWidth: 160,
                            errorBuilder: (_, __, ___) =>
                                const ColoredBox(color: Colors.white12)),
                      ),
                    if (it.draft.kind == 'video')
                      const Center(
                          child: Icon(Icons.play_circle_fill_rounded,
                              color: Colors.white, size: 22)),
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

void _deleteQuietly(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

/// Delete every draft file the user did not send (cancel).
@visibleForTesting
void deleteDraftFiles(Iterable<MediaDraft> drafts) {
  for (final d in drafts) {
    _deleteQuietly(d.path);
  }
}
