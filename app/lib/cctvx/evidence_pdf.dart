// cctvevidence (W7) — the BANGLA PDF of the evidence pack, made on this phone:
// title, facts (shop, address, camera, time, what happened), the alert photo,
// every file with its SHA-256, how to check them, and the GD draft. Drawn
// with Flutter's own text engine (Bangla conjuncts shaped right) onto A4
// page pictures, then written by the dependency-free mini_pdf writer.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'evidence_pack.dart';
import 'mini_pdf.dart';

/// Page geometry (A4 at ~150 dpi).
const double kEvPageW = 1240, kEvPageH = 1754, kEvMargin = 90;

/// One printed block: a heading, a paragraph, a mono line or a picture.
class EvBlock {
  final String kind; // 'title' | 'h' | 'p' | 'mono' | 'img'
  final String text;
  final Uint8List? image;
  const EvBlock(this.kind, this.text, {this.image});
}

/// All words the PDF needs (from the ARB, so bn / en stay strict).
class EvPdfWords {
  final String title, shop, address, camera, when, what, photo, files, howCheck, letter, footer;
  const EvPdfWords({
    required this.title,
    required this.shop,
    required this.address,
    required this.camera,
    required this.when,
    required this.what,
    required this.photo,
    required this.files,
    required this.howCheck,
    required this.letter,
    required this.footer,
  });
}

/// The blocks in print order. Pure: unit-tested.
List<EvBlock> evidencePdfBlocks({
  required EvPdfWords w,
  required Map<String, Object?> facts,
  required List<EvidenceFile> files,
  required String letter,
  Uint8List? photo,
}) {
  String f(String k) => (facts[k] ?? '').toString().trim();
  final out = <EvBlock>[EvBlock('title', w.title)];
  void fact(String label, String v) {
    if (v.isNotEmpty) out.add(EvBlock('p', '$label: $v'));
  }

  fact(w.shop, f('shop_name').isNotEmpty ? f('shop_name') : f('shop'));
  fact(w.address, f('address'));
  fact(w.camera, f('camera'));
  fact(w.when, f('when'));
  fact(w.what, f('what'));
  if (photo != null && photo.isNotEmpty) {
    out.add(EvBlock('h', w.photo));
    out.add(EvBlock('img', '', image: photo));
  }
  out.add(EvBlock('h', w.files));
  for (final x in files) {
    out.add(EvBlock('mono', '${x.name}  (${x.bytes.length} B)\n${sha256Hex(x.bytes)}'));
  }
  out.add(EvBlock('p', w.howCheck));
  out.add(EvBlock('h', w.letter));
  for (final para in letter.split('\n\n')) {
    if (para.trim().isNotEmpty) out.add(EvBlock('p', para.trim()));
  }
  out.add(EvBlock('p', w.footer));
  return out;
}

const _ink = Color(0xFF111111);
const _muted = Color(0xFF555555);

TextPainter _tp(String s, double size, double width,
    {FontWeight weight = FontWeight.normal, Color c = _ink, String? family}) {
  final tp = TextPainter(
    text: TextSpan(
        text: s,
        style: TextStyle(fontSize: size, color: c, fontWeight: weight, height: 1.35,
            fontFamily: family)),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width);
  return tp;
}

/// Renders [blocks] to A4 PDF bytes.
Future<Uint8List> buildEvidencePdf(List<EvBlock> blocks, {String pageLabel = ''}) async {
  final cw = kEvPageW - 2 * kEvMargin;
  // measure every block once
  final items = <(double, void Function(Canvas, double))>[];
  for (final b in blocks) {
    switch (b.kind) {
      case 'img':
        final img = await _decode(b.image!);
        if (img == null) continue;
        var w = img.width * (cw / img.width);
        var h = img.height * (cw / img.width);
        if (h > 760) {
          h = 760;
          w = img.width * (760 / img.height);
        }
        items.add((
          h + 24,
          (c, y) => c.drawImageRect(
              img,
              Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
              Rect.fromLTWH(kEvMargin, y, w, h),
              Paint()..filterQuality = FilterQuality.medium)
        ));
      default:
        final tp = switch (b.kind) {
          'title' => _tp(b.text, 44, cw, weight: FontWeight.w700),
          'h' => _tp(b.text, 32, cw, weight: FontWeight.w700),
          'mono' => _tp(b.text, 22, cw, c: _muted, family: 'monospace'),
          _ => _tp(b.text, 27, cw),
        };
        final gap = b.kind == 'title' ? 28.0 : (b.kind == 'h' ? 22.0 : 14.0);
        items.add((tp.height + gap, (c, y) => tp.paint(c, Offset(kEvMargin, y))));
    }
  }
  // paginate between blocks
  final pages = <List<int>>[<int>[]];
  final room0 = kEvPageH - 2 * kEvMargin - 40;
  var room = room0;
  for (var i = 0; i < items.length; i++) {
    final h = items[i].$1;
    if (h > room && pages.last.isNotEmpty) {
      pages.add(<int>[]);
      room = room0;
    }
    pages.last.add(i);
    room -= h;
  }
  final out = <PdfPageImage>[];
  for (var p = 0; p < pages.length; p++) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, const Rect.fromLTWH(0, 0, kEvPageW, kEvPageH));
    c.drawRect(const Rect.fromLTWH(0, 0, kEvPageW, kEvPageH), Paint()..color = const Color(0xFFFFFFFF));
    var y = kEvMargin;
    for (final i in pages[p]) {
      items[i].$2(c, y);
      y += items[i].$1;
    }
    final foot = _tp('$pageLabel ${p + 1}/${pages.length}'.trim(), 20, kEvPageW - 2 * kEvMargin,
        c: _muted);
    foot.paint(c, Offset(kEvMargin, kEvPageH - kEvMargin + 10));
    final pic = rec.endRecording();
    final img = await pic.toImage(kEvPageW.toInt(), kEvPageH.toInt());
    pic.dispose();
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = img.width, h = img.height;
    img.dispose();
    if (data == null) throw StateError('no pixels');
    out.add(PdfPageImage(rgbaToRgb(data.buffer.asUint8List()), w, h));
  }
  return imagePagesPdf(out, title: 'Assisto CCTV evidence');
}

Future<ui.Image?> _decode(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final f = await codec.getNextFrame();
    return f.image;
  } catch (_) {
    return null;
  }
}
