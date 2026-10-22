// Photo Studio evaluation harness (p2-photo) — runs the SAME classical
// pipeline the app runs (lib/photo_studio/ps_classic.dart) on raw RGBA files
// prepared by tools/photo_model/eval_photos.py, and prints the time per photo.
//
//   dart run tool/ps_eval.dart <in.rgba> <out_prefix> [faces "x,y,w,h;..."]
//   dart compile exe tool/ps_eval.dart -o /tmp/ps_eval   (AOT = phone-like)
//
// <in.rgba> = 8-byte header (uint32 LE width, height) + RGBA8888 pixels.
// Writes <out_prefix>_{light,natural,strong}.rgba and prints JSON lines
// {"level":..,"ms":..,"w":..,"h":..}.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/photo_studio/ps_classic.dart';
import '../lib/photo_studio/ps_models.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: ps_eval <in.rgba> <out_prefix> [faces]');
    exit(2);
  }
  final raw = File(args[0]).readAsBytesSync();
  final bd = ByteData.sublistView(raw);
  final w = bd.getUint32(0, Endian.little), h = bd.getUint32(4, Endian.little);
  final rgba = Uint8List.sublistView(raw, 8);
  final faces = <ClassicFace>[];
  if (args.length > 2 && args[2].trim().isNotEmpty) {
    for (final f in args[2].split(';')) {
      final v = f.split(',').map(double.parse).toList();
      if (v.length == 4) faces.add(ClassicFace(v[0], v[1], v[2], v[3]));
    }
  }
  // warm-up (JIT/AOT caches), not timed
  enhanceClassic(downscaleRgba(rgba, w, h, 256).rgba,
      downscaleRgba(rgba, w, h, 256).w, downscaleRgba(rgba, w, h, 256).h,
      ClassicParams.natural);
  for (final s in EditStrength.values) {
    final sw = Stopwatch()..start();
    final out = enhanceClassic(rgba, w, h, ClassicParams.of(s), faces: faces);
    sw.stop();
    final hdr = ByteData(8)
      ..setUint32(0, w, Endian.little)
      ..setUint32(4, h, Endian.little);
    final f = File('${args[1]}_${s.name}.rgba').openSync(mode: FileMode.write);
    f.writeFromSync(hdr.buffer.asUint8List());
    f.writeFromSync(out);
    f.closeSync();
    stdout.writeln(jsonEncode(
        {'level': s.name, 'ms': sw.elapsedMilliseconds, 'w': w, 'h': h}));
  }
}
