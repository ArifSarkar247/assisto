import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zxing2/qrcode.dart';

/// circle-extras (row 50) — a small QR scanner with NO new native code: the
/// app's existing `camera` plugin streams frames and the pure-Dart zxing2
/// decoder reads the luminance (Y) plane in a background isolate (~3 frames
/// a second). The camera opens only while this widget is on screen and every
/// failure (no camera, permission denied, OEM camera error) becomes the
/// [onUnavailable] callback — the screen then offers "type the code".
class QrScanView extends StatefulWidget {
  const QrScanView({
    super.key,
    required this.onCode,
    required this.onUnavailable,
    this.size = 260,
  });

  /// Called ONCE with the first decoded text.
  final ValueChanged<String> onCode;

  /// (denied?) — true when the camera permission was refused.
  final ValueChanged<bool> onUnavailable;
  final double size;

  @override
  State<QrScanView> createState() => _QrScanViewState();
}

class _QrScanViewState extends State<QrScanView> {
  CameraController? _cam;
  bool _busy = false;
  bool _done = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        widget.onUnavailable(false);
        return;
      }
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      _cam = c;
      await c.startImageStream(_onFrame);
      setState(() {});
    } on CameraException catch (e) {
      widget.onUnavailable(e.code.toLowerCase().contains('denied'));
    } catch (_) {
      widget.onUnavailable(false);
    }
  }

  void _onFrame(CameraImage img) {
    final now = DateTime.now();
    if (_busy || _done || now.difference(_last).inMilliseconds < 300) return;
    _last = now;
    _busy = true;
    final p = img.planes.first;
    final frame = YFrame(Uint8List.fromList(p.bytes), img.width, img.height, p.bytesPerRow);
    compute(decodeQrFrame, frame).then((text) {
      if (text != null && !_done && mounted) {
        _done = true;
        widget.onCode(text);
      }
    }).catchError((_) {}).whenComplete(() => _busy = false);
  }

  @override
  void dispose() {
    final c = _cam;
    _cam = null;
    if (c != null) {
      unawaited(() async {
        try {
          if (c.value.isStreamingImages) await c.stopImageStream();
        } catch (_) {}
        try {
          await c.dispose();
        } catch (_) {}
      }());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _cam;
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: c == null || !c.value.isInitialized
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: const Center(child: CircularProgressIndicator()))
            : Stack(fit: StackFit.expand, children: [
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: c.value.previewSize?.height ?? widget.size,
                    height: c.value.previewSize?.width ?? widget.size,
                    child: CameraPreview(c),
                  ),
                ),
                IgnorePointer(
                  child: Container(
                    margin: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ]),
      ),
    );
  }
}

/// One camera frame's luminance plane (sendable to an isolate).
class YFrame {
  const YFrame(this.bytes, this.width, this.height, this.rowStride);
  final Uint8List bytes;
  final int width;
  final int height;
  final int rowStride;
}

/// zxing2 source over a Y plane with a row stride (camera planes are padded).
class YPlaneSource extends LuminanceSource {
  YPlaneSource(this._f) : super(_f.width, _f.height);
  final YFrame _f;

  @override
  Int8List getRow(int y, Int8List? row) {
    final out = (row == null || row.length < width) ? Int8List(width) : row;
    final off = y * _f.rowStride;
    for (var x = 0; x < width; x++) {
      out[x] = _f.bytes[off + x].toSigned(8);
    }
    return out;
  }

  @override
  Int8List getMatrix() {
    final m = Int8List(width * height);
    for (var y = 0; y < height; y++) {
      final off = y * _f.rowStride;
      for (var x = 0; x < width; x++) {
        m[y * width + x] = _f.bytes[off + x].toSigned(8);
      }
    }
    return m;
  }
}

/// PURE (tests + isolate): the QR text in [f], or null.
String? decodeQrFrame(YFrame f) {
  try {
    final bmp = BinaryBitmap(HybridBinarizer(YPlaneSource(f)));
    return QRCodeReader().decode(bmp).text;
  } catch (_) {
    return null;
  }
}
