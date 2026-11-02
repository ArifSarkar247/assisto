// cctvx — a minimal, dependency-free PDF writer for the PRIVACY KIT: ONE page
// (A4 or A5 portrait) holding ONE picture — the sticker / staff notice the app
// rendered with Flutter's own text engine (so Bangla conjuncts are shaped
// correctly, which a PDF font path could not promise). The picture is RGB,
// Flate-compressed (dart:io zlib), centred with a margin. Unit-tested.
import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

enum PdfPaper { a4, a5 }

/// Page size in PostScript points (1/72 inch).
(double, double) pdfPaperSize(PdfPaper p) => switch (p) {
      PdfPaper.a4 => (595.28, 841.89),
      PdfPaper.a5 => (419.53, 595.28),
    };

/// RGBA (Flutter `ImageByteFormat.rawRgba`) -> RGB, alpha blended on white.
Uint8List rgbaToRgb(Uint8List rgba) {
  final n = rgba.length ~/ 4;
  final out = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    final a = rgba[i * 4 + 3];
    for (var c = 0; c < 3; c++) {
      final v = rgba[i * 4 + c];
      out[i * 3 + c] = ((v * a + 255 * (255 - a)) ~/ 255);
    }
  }
  return out;
}

/// A one-page PDF with [rgb] (width x height, 8-bit RGB) fitted inside the
/// page with [marginPt] on every side.
Uint8List onePagePdf({
  required Uint8List rgb,
  required int width,
  required int height,
  PdfPaper paper = PdfPaper.a4,
  double marginPt = 28,
  String title = 'Assisto',
}) {
  if (width <= 0 || height <= 0 || rgb.length != width * height * 3) {
    throw ArgumentError('rgb size');
  }
  final (pw, ph) = pdfPaperSize(paper);
  final boxW = pw - 2 * marginPt, boxH = ph - 2 * marginPt;
  final scale = (boxW / width < boxH / height) ? boxW / width : boxH / height;
  final dw = width * scale, dh = height * scale;
  final x = (pw - dw) / 2, y = (ph - dh) / 2;
  final img = Uint8List.fromList(ZLibCodec(level: 6).encode(rgb));
  String f(double v) => v.toStringAsFixed(2);
  final content = utf8.encode('q ${f(dw)} 0 0 ${f(dh)} ${f(x)} ${f(y)} cm /Im0 Do Q\n');

  final out = BytesBuilder(copy: false);
  final offsets = <int>[];
  var len = 0;
  void add(List<int> b) {
    out.add(b);
    len += b.length;
  }

  void obj(int n, List<int> body) {
    offsets.add(len);
    add(latin1.encode('$n 0 obj\n'));
    add(body);
    add(latin1.encode('\nendobj\n'));
  }

  add(latin1.encode('%PDF-1.4\n'));
  add([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]); // binary marker
  obj(1, latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'));
  obj(2, latin1.encode('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'));
  obj(3, latin1.encode('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${f(pw)} ${f(ph)}] '
      '/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>'));
  obj(4, [
    ...latin1.encode('<< /Type /XObject /Subtype /Image /Width $width /Height $height '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode '
        '/Length ${img.length} >>\nstream\n'),
    ...img,
    ...latin1.encode('\nendstream'),
  ]);
  obj(5, [
    ...latin1.encode('<< /Length ${content.length} >>\nstream\n'),
    ...content,
    ...latin1.encode('endstream'),
  ]);
  final safeTitle = title.replaceAll(RegExp(r'[^A-Za-z0-9 \-]'), '');
  obj(6, latin1.encode('<< /Title ($safeTitle) /Producer (Assisto) >>'));
  final xref = len;
  final sb = StringBuffer('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    sb.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  sb.write('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R /Info 6 0 R >>\n'
      'startxref\n$xref\n%%EOF\n');
  add(latin1.encode(sb.toString()));
  return out.takeBytes();
}

/// One page picture for [imagePagesPdf]: 8-bit RGB, [width] x [height].
class PdfPageImage {
  final Uint8List rgb;
  final int width;
  final int height;
  const PdfPageImage(this.rgb, this.width, this.height);
}

/// bizbar: a MULTI-page PDF, one full-bleed picture per page (the khata
/// statement is drawn by Flutter's own text engine, so Bangla conjuncts are
/// shaped right). Each picture is Flate-compressed once and the raw pixels
/// can be dropped by the caller page by page (2 GB phones).
Uint8List imagePagesPdf(List<PdfPageImage> pages,
    {PdfPaper paper = PdfPaper.a4, double marginPt = 0, String title = 'Assisto'}) {
  if (pages.isEmpty) throw ArgumentError('no pages');
  for (final p in pages) {
    if (p.width <= 0 || p.height <= 0 || p.rgb.length != p.width * p.height * 3) {
      throw ArgumentError('rgb size');
    }
  }
  final (pw, ph) = pdfPaperSize(paper);
  String f(double v) => v.toStringAsFixed(2);
  final out = BytesBuilder(copy: false);
  final offsets = <int, int>{};
  var len = 0;
  void add(List<int> b) {
    out.add(b);
    len += b.length;
  }

  void obj(int n, List<int> body) {
    offsets[n] = len;
    add(latin1.encode('$n 0 obj\n'));
    add(body);
    add(latin1.encode('\nendobj\n'));
  }

  // objects: 1 catalog, 2 pages, then per page i: page, image, content
  final n = pages.length;
  int pageObj(int i) => 3 + i * 3;
  final infoObj = 3 + n * 3;
  add(latin1.encode('%PDF-1.4\n'));
  add([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
  obj(1, latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'));
  final kids = [for (var i = 0; i < n; i++) '${pageObj(i)} 0 R'].join(' ');
  obj(2, latin1.encode('<< /Type /Pages /Kids [$kids] /Count $n >>'));
  for (var i = 0; i < n; i++) {
    final p = pages[i];
    final boxW = pw - 2 * marginPt, boxH = ph - 2 * marginPt;
    final scale = (boxW / p.width < boxH / p.height) ? boxW / p.width : boxH / p.height;
    final dw = p.width * scale, dh = p.height * scale;
    final x = (pw - dw) / 2, y = (ph - dh) / 2;
    final po = pageObj(i);
    obj(po, latin1.encode('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${f(pw)} ${f(ph)}] '
        '/Resources << /XObject << /Im0 ${po + 1} 0 R >> >> /Contents ${po + 2} 0 R >>'));
    final img = ZLibCodec(level: 6).encode(p.rgb);
    obj(po + 1, [
      ...latin1.encode('<< /Type /XObject /Subtype /Image /Width ${p.width} /Height ${p.height} '
          '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode '
          '/Length ${img.length} >>\nstream\n'),
      ...img,
      ...latin1.encode('\nendstream'),
    ]);
    final content = utf8.encode('q ${f(dw)} 0 0 ${f(dh)} ${f(x)} ${f(y)} cm /Im0 Do Q\n');
    obj(po + 2, [
      ...latin1.encode('<< /Length ${content.length} >>\nstream\n'),
      ...content,
      ...latin1.encode('endstream'),
    ]);
  }
  final safeTitle = title.replaceAll(RegExp(r'[^A-Za-z0-9 \-]'), '');
  obj(infoObj, latin1.encode('<< /Title ($safeTitle) /Producer (Assisto) >>'));
  final xref = len;
  final sb = StringBuffer('xref\n0 ${infoObj + 1}\n0000000000 65535 f \n');
  for (var i = 1; i <= infoObj; i++) {
    sb.write('${offsets[i]!.toString().padLeft(10, '0')} 00000 n \n');
  }
  sb.write('trailer\n<< /Size ${infoObj + 1} /Root 1 0 R /Info $infoObj 0 R >>\n'
      'startxref\n$xref\n%%EOF\n');
  add(latin1.encode(sb.toString()));
  return out.takeBytes();
}
