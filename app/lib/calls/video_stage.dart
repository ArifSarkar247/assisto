// cde-chat (order 6 C) — the WhatsApp-style video call stage:
//   * tap the small view          -> swap big / small (me <-> them)
//   * drag the small view          -> it snaps to the nearest corner
//   * pinch the big view           -> zoom (1x–4x; reset on swap)
//   * double-tap the big view      -> full screen (controls hidden) / back
// The views themselves come from the call's CallVideoSurface (WebRTC
// renderers; coloured fakes in tests) — this widget only arranges them, so it
// costs nothing at app launch and never touches the camera itself.
import 'package:flutter/material.dart';

import '../theme.dart';

enum StageCorner { topLeft, topRight, bottomLeft, bottomRight }

class VideoStage extends StatefulWidget {
  /// Their video (or the avatar placeholder when their camera is off).
  final Widget remote;

  /// My camera preview (or the camera-off placeholder).
  final Widget local;

  /// Their video is really showing — only then can the views swap.
  final bool canSwap;

  /// The top bar / name / controls, drawn between the big and the small view.
  final Widget? overlay;

  /// Where the small view may sit (keeps it off the top bar and controls).
  final double topInset;
  final double bottomInset;

  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  final String localLabel;
  final String remoteLabel;
  final String bigLabel;

  /// Gallery / tests: start swapped / in another corner.
  final bool initialSwapped;
  final StageCorner initialCorner;

  const VideoStage({
    super.key,
    required this.remote,
    required this.local,
    required this.canSwap,
    required this.fullscreen,
    required this.onToggleFullscreen,
    this.overlay,
    this.topInset = 80,
    this.bottomInset = 200,
    this.localLabel = '',
    this.remoteLabel = '',
    this.bigLabel = '',
    this.initialSwapped = false,
    this.initialCorner = StageCorner.topRight,
  });

  static const double tileW = 104;
  static const double tileH = 150;
  static const double margin = 16;

  @override
  State<VideoStage> createState() => VideoStageState();
}

class VideoStageState extends State<VideoStage> {
  late bool _swapped = widget.initialSwapped;
  late StageCorner _corner = widget.initialCorner;
  Offset? _drag; // live position while the finger is down
  final TransformationController _zoom = TransformationController();

  bool get swapped => _swapped && widget.canSwap;
  StageCorner get corner => _corner;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _swap() {
    if (!widget.canSwap) return;
    setState(() {
      _swapped = !_swapped;
      _zoom.value = Matrix4.identity();
    });
  }

  Rect _area(Size s) => Rect.fromLTRB(
        VideoStage.margin,
        widget.topInset,
        s.width - VideoStage.margin,
        (s.height - widget.bottomInset).clamp(widget.topInset + VideoStage.tileH, s.height),
      );

  Offset _pos(StageCorner c, Rect a) => switch (c) {
        StageCorner.topLeft => a.topLeft,
        StageCorner.topRight => Offset(a.right - VideoStage.tileW, a.top),
        StageCorner.bottomLeft => Offset(a.left, a.bottom - VideoStage.tileH),
        StageCorner.bottomRight =>
          Offset(a.right - VideoStage.tileW, a.bottom - VideoStage.tileH),
      };

  /// The corner nearest to where the small view was let go.
  static StageCorner nearest(Offset tileTopLeft, Rect area) {
    final cx = tileTopLeft.dx + VideoStage.tileW / 2;
    final cy = tileTopLeft.dy + VideoStage.tileH / 2;
    final left = cx < area.center.dx;
    final top = cy < area.center.dy;
    if (top) return left ? StageCorner.topLeft : StageCorner.topRight;
    return left ? StageCorner.bottomLeft : StageCorner.bottomRight;
  }

  @override
  Widget build(BuildContext context) {
    final sw = swapped;
    final big = sw ? widget.local : widget.remote;
    final small = sw ? widget.remote : widget.local;
    return LayoutBuilder(builder: (context, box) {
      final size = box.biggest;
      final area = _area(size);
      final pos = _drag ?? _pos(_corner, area);
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Semantics(
              label: widget.bigLabel,
              child: GestureDetector(
                key: const Key('call-big-view'),
                behavior: HitTestBehavior.opaque,
                onDoubleTap: widget.onToggleFullscreen,
                child: InteractiveViewer(
                  transformationController: _zoom,
                  minScale: 1,
                  maxScale: 4,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox.expand(
                    child: KeyedSubtree(
                        key: Key(sw ? 'call-big-local' : 'call-big-remote'), child: big),
                  ),
                ),
              ),
            ),
          ),
          if (widget.overlay != null) Positioned.fill(child: widget.overlay!),
          AnimatedPositioned(
            duration: _drag == null ? const Duration(milliseconds: 220) : Duration.zero,
            curve: Curves.easeOutCubic,
            left: pos.dx,
            top: pos.dy,
            width: VideoStage.tileW,
            height: VideoStage.tileH,
            child: Semantics(
              button: widget.canSwap,
              label: sw ? widget.remoteLabel : widget.localLabel,
              child: GestureDetector(
                key: const Key('call-self-view'),
                onTap: widget.canSwap ? _swap : null,
                onPanStart: (_) => setState(() => _drag = _pos(_corner, area)),
                onPanUpdate: (d) {
                  final p = (_drag ?? _pos(_corner, area)) + d.delta;
                  setState(() => _drag = Offset(
                        p.dx.clamp(0, size.width - VideoStage.tileW),
                        p.dy.clamp(0, size.height - VideoStage.tileH),
                      ));
                },
                onPanEnd: (_) => setState(() {
                  _corner = nearest(_drag ?? pos, area);
                  _drag = null;
                }),
                onPanCancel: () => setState(() => _drag = null),
                child: DecoratedBox(
                  key: ValueKey('call-self-corner-${_corner.name}'),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.lg),
                    boxShadow: const [
                      BoxShadow(color: CallInk.tileShadow, blurRadius: 10, offset: Offset(0, 3)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.lg),
                    child: ColoredBox(
                      color: Colors.black,
                      child: KeyedSubtree(
                          key: Key(sw ? 'call-small-remote' : 'call-small-local'),
                          child: small),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}
