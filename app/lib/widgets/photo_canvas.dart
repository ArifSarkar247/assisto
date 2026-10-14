// Photo Enhance (ADVANCED, SPEC §21) — faithful on-device render pipeline.
//
// Renders the user's OWN photo through a colour matrix (brightness / contrast /
// saturation) + a transform (90° rotation, small straighten, square crop) and
// an optional sharpen overlay. Everything here is a pure, non-generative,
// pixel-faithful transform — it CANNOT add, remove, or invent content, and it
// never touches identity. Uses only Flutter built-ins (no extra packages), so
// it works offline on CPU today. Export is via RepaintBoundary -> toImage.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'photo_presets.dart';

/// Builds the 5×4 colour matrix for ColorFilter.matrix from faithful knobs.
List<double> buildColorMatrix(PhotoAdjustments a) {
  // Brightness as an additive offset (in 0..255 space) derived from a
  // multiplier around 1.0 so it composes cleanly with contrast.
  final b = (a.brightness - 1.0) * 255.0;
  final c = a.contrast; // contrast multiplier
  final t = (1.0 - c) * 128.0; // keep mid-grey anchored under contrast
  final s = a.saturation; // saturation multiplier

  // Saturation matrix (luminance-preserving), standard Rec.601 weights.
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;

  // Compose saturation then contrast+brightness on the diagonal.
  final ca = (sr + s) * c;
  final cb = sg * c;
  final cc = sb * c;
  final da = sr * c;
  final db2 = (sg + s) * c;
  final dc = sb * c;
  final ea = sr * c;
  final eb = sg * c;
  final ec = (sb + s) * c;
  final off = t + b;

  return <double>[
    ca, cb, cc, 0, off,
    da, db2, dc, 0, off,
    ea, eb, ec, 0, off,
    0, 0, 0, 1, 0,
  ];
}

/// The live, faithful preview of [image] under [adj]. Set [captureKey] to wrap
/// it in a RepaintBoundary for export.
class PhotoCanvas extends StatelessWidget {
  const PhotoCanvas({
    super.key,
    required this.image,
    required this.adj,
    this.captureKey,
    this.fit = BoxFit.cover,
  });

  final File image;
  final PhotoAdjustments adj;
  final GlobalKey? captureKey;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    Widget img = Image.file(image, fit: fit, width: double.infinity,
        gaplessPlayback: true);

    // Sharpen: faithful high-frequency boost approximated by overlaying a
    // slightly scaled, higher-contrast copy at low opacity. No new content.
    if (adj.sharpness > 0) {
      img = Stack(fit: StackFit.expand, children: [
        img,
        Opacity(
          opacity: (adj.sharpness * 0.35).clamp(0.0, 0.35),
          child: ColorFiltered(
            colorFilter: const ColorFilter.matrix(<double>[
              1.4, 0, 0, 0, -51,
              0, 1.4, 0, 0, -51,
              0, 0, 1.4, 0, -51,
              0, 0, 0, 1, 0,
            ]),
            child: Image.file(image, fit: fit, width: double.infinity,
                gaplessPlayback: true),
          ),
        ),
      ]);
    }

    // Colour grade (brightness/contrast/saturation).
    img = ColorFiltered(
      colorFilter: ColorFilter.matrix(buildColorMatrix(adj)),
      child: img,
    );

    // Geometry: straighten (small angle) then quarter-turns.
    if (adj.straightenDeg != 0) {
      img = Transform.rotate(
        angle: adj.straightenDeg * 3.1415926535 / 180.0,
        child: img,
      );
    }
    if (adj.rotationQuarters % 4 != 0) {
      img = RotatedBox(quarterTurns: adj.rotationQuarters % 4, child: img);
    }

    // Square crop via aspect ratio.
    Widget framed = adj.squareCrop
        ? AspectRatio(aspectRatio: 1, child: ClipRect(child: img))
        : img;

    framed = ClipRRect(borderRadius: BorderRadius.circular(12), child: framed);
    if (captureKey != null) {
      framed = RepaintBoundary(key: captureKey, child: framed);
    }
    return framed;
  }
}

/// Export the current faithfully-adjusted pixels from a RepaintBoundary to a
/// PNG on disk. Returns the file, or null if capture failed. We NEVER return a
/// fabricated image — this is exactly what the user sees.
Future<File?> capturePng(GlobalKey key, String outPath,
    {double pixelRatio = 2.5}) async {
  final ctx = key.currentContext;
  if (ctx == null) return null;
  final boundary = ctx.findRenderObject();
  if (boundary is! RenderRepaintBoundary) return null;
  final ui.Image rendered = await boundary.toImage(pixelRatio: pixelRatio);
  final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) return null;
  final file = File(outPath);
  await file.writeAsBytes(bytes.buffer.asUint8List());
  return file;
}
