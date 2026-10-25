import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';

import '../../crypto/e2e.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'camera_draw_canvas.dart';
import 'camera_send_sheet.dart';

/// Preview + edit the captured/picked media, then SEND it.
///
/// PHOTO: full edit surface — crop + rotate (image_cropper), freehand DRAW over
/// the image, drop short TEXT stickers, and a CAPTION field. On SEND the user
/// chooses a destination (one chat / several chats / post as Status) via
/// [showCameraSendSheet], which wires into the EXISTING circle media + status
/// paths (see that file + the integration note).
///
/// VIDEO: the edit tools that need pixels (crop/draw/text) don't apply, so we
/// show a video placeholder with a caption + the same SEND chooser. The video
/// path is honest about what it can do today.
class CameraPreviewEditScreen extends StatefulWidget {
  final File file;
  final bool isVideo;
  final IdentityKeyPair? identity;
  final List<Map<String, dynamic>> members;

  const CameraPreviewEditScreen({
    super.key,
    required this.file,
    required this.isVideo,
    this.identity,
    this.members = const [],
  });

  @override
  State<CameraPreviewEditScreen> createState() =>
      _CameraPreviewEditScreenState();
}

enum _EditTool { none, draw, text }

class _CameraPreviewEditScreenState extends State<CameraPreviewEditScreen> {
  final _caption = TextEditingController();
  final _canvasKey = GlobalKey();

  late File _file;
  _EditTool _tool = _EditTool.none;
  int _imageRev = 0; // bump to force Image.file to reload after crop/rotate

  final List<DrawStroke> _strokes = [];
  final List<TextSticker> _texts = [];
  DrawStroke? _active;

  // The draw/text palette. Brand-led, high-contrast on photos.
  static const _palette = [
    Colors.white,
    Brand.cyan,
    Brand.danger,
    Brand.warning,
    Brand.purple,
    Colors.black,
  ];
  Color _color = Colors.white;

  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _file = widget.file;
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Crop + rotate (image_cropper)
  // ---------------------------------------------------------------------------
  Future<void> _cropRotate() async {
    final t = _t;
    try {
      final cropped = await ImageCropper().cropImage(
        sourcePath: _file.path,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: t.camCropTitle,
            toolbarColor: Brand.ink,
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: Brand.blue,
            backgroundColor: Brand.ink,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
          ),
          IOSUiSettings(title: t.camCropTitle),
        ],
      );
      if (cropped == null || !mounted) return;
      setState(() {
        _file = File(cropped.path);
        _imageRev++;
        // Drawings/text were positioned on the old frame; clear them so nothing
        // lands in the wrong place after a crop.
        _strokes.clear();
        _texts.clear();
      });
    } catch (_) {
      _snack(t.camEditFailed);
    }
  }

  // ---------------------------------------------------------------------------
  // Text sticker
  // ---------------------------------------------------------------------------
  Future<void> _addText() async {
    final controller = TextEditingController();
    final t = _t;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.camAddText),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: t.camTextHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(t.save),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _texts.add(TextSticker(
        text: text,
        fraction: const Offset(0.5, 0.4),
        color: _color,
      ));
      _tool = _EditTool.text;
    });
  }

  // ---------------------------------------------------------------------------
  // Send
  // ---------------------------------------------------------------------------
  Future<void> _send() async {
    await showCameraSendSheet(
      context,
      file: _file,
      isVideo: widget.isVideo,
      caption: _caption.text.trim(),
      identity: widget.identity,
      members: widget.members,
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      backgroundColor: Brand.ink,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: t.close,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: widget.isVideo
            ? null
            : [
                IconButton(
                  tooltip: t.camCrop,
                  icon: const Icon(Icons.crop_rotate),
                  onPressed: _cropRotate,
                ),
                IconButton(
                  tooltip: t.camDraw,
                  icon: Icon(
                    Icons.brush_outlined,
                    color: _tool == _EditTool.draw ? Brand.cyan : Colors.white,
                  ),
                  onPressed: () => setState(() => _tool =
                      _tool == _EditTool.draw ? _EditTool.none : _EditTool.draw),
                ),
                IconButton(
                  tooltip: t.camAddText,
                  icon: const Icon(Icons.title),
                  onPressed: _addText,
                ),
              ],
      ),
      body: Column(
        children: [
          Expanded(child: _stage(t)),
          if (!widget.isVideo && _tool != _EditTool.none) _paletteBar(),
          _captionBar(t),
        ],
      ),
    );
  }

  Widget _stage(AppLocalizations t) {
    if (widget.isVideo) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_outlined,
                size: 72, color: Colors.white.withValues(alpha: 0.8)),
            const SizedBox(height: Gap.md),
            Text(t.camVideoReady,
                style: const TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Center(
            child: RepaintBoundary(
              key: _canvasKey,
              child: GestureDetector(
                onPanStart: _tool == _EditTool.draw ? _onPanStart : null,
                onPanUpdate: _tool == _EditTool.draw ? _onPanUpdate : null,
                onPanEnd: _tool == _EditTool.draw ? _onPanEnd : null,
                child: Stack(
                  children: [
                    Image.file(
                      _file,
                      key: ValueKey(_imageRev),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                    Positioned.fill(
                      child: CustomPaint(painter: DrawPainter(_strokes)),
                    ),
                    ..._texts.map((s) => _draggableText(s, constraints)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _draggableText(TextSticker s, BoxConstraints box) {
    final w = box.maxWidth;
    final h = box.maxHeight;
    return Positioned(
      left: (s.fraction.dx * w).clamp(0, w - 40),
      top: (s.fraction.dy * h).clamp(0, h - 24),
      child: GestureDetector(
        onPanUpdate: (d) {
          setState(() {
            s.fraction = Offset(
              (s.fraction.dx + d.delta.dx / w).clamp(0.0, 1.0),
              (s.fraction.dy + d.delta.dy / h).clamp(0.0, 1.0),
            );
          });
        },
        child: Text(
          s.text,
          style: AType.headlineSmall.copyWith(color: s.color,
            fontWeight: FontWeight.w800,
            shadows: const [Shadow(color: Colors.black54, blurRadius: 4)]),
        ),
      ),
    );
  }

  void _onPanStart(DragStartDetails d) {
    final stroke = DrawStroke(color: _color, width: 5)..points.add(d.localPosition);
    setState(() {
      _active = stroke;
      _strokes.add(stroke);
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_active == null) return;
    setState(() => _active!.points.add(d.localPosition));
  }

  void _onPanEnd(DragEndDetails d) => _active = null;

  Widget _paletteBar() {
    return Container(
      color: Colors.black38,
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final c in _palette)
            GestureDetector(
              onTap: () => setState(() => _color = c),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: Gap.xs),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _color == c ? Brand.cyan : Colors.white54,
                    width: _color == c ? 3 : 1,
                  ),
                ),
              ),
            ),
          if (_tool == _EditTool.draw && _strokes.isNotEmpty)
            IconButton(
              tooltip: _t.camUndo,
              icon: const Icon(Icons.undo, color: Colors.white),
              onPressed: () => setState(() => _strokes.removeLast()),
            ),
        ],
      ),
    );
  }

  Widget _captionBar(AppLocalizations t) {
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.black45,
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.sm),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _caption,
                maxLines: null,
                minLines: 1,
                maxLength: 300,
                style: const TextStyle(color: Colors.white),
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: t.camCaptionHint,
                  hintStyle: const TextStyle(color: Colors.white54),
                  counterText: '',
                  border: InputBorder.none,
                ),
              ),
            ),
            const SizedBox(width: Gap.sm),
            FloatingActionButton(tooltip: AppLocalizations.of(context).send,
              heroTag: 'cam_send',
              onPressed: _send,
              child: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
