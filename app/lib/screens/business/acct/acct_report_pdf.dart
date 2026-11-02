// acctui — any accounting report (P&L, balance sheet, trial balance, cash
// flow, VAT) as an A4 PDF in Bangla or English. Same approach as the khata
// statement (statement_pdf.dart): every page is drawn with Flutter's own text
// engine (Inter + Noto Sans Bengali, so Bangla conjuncts are shaped right)
// onto a picture, and the pictures are wrapped by cctvx/mini_pdf.dart. One
// page of pixels at a time (2 GB phones).
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Canvas, Color, Offset, Paint, Rect;

import 'package:flutter/painting.dart';

import '../../../cctvx/mini_pdf.dart';
import '../../../theme.dart' show AFonts, PrintInk;
import 'acct_report_model.dart';

const double _pw = 1240, _ph = 1754, _m = 72;
const double _w = _pw - 2 * _m;
const double _amtW = 260;
const double _header = 260, _otherHeader = 110, _footer = 80;

class AcctPdfText {
  final String shop;
  final String made; // "Made on 2 Nov 2026 by Assisto"
  final String balanced; // "Debits equal credits" (or '' when n/a)
  final String Function(int poisha) money;
  final String Function(int page, int pages) pageLabel;
  const AcctPdfText(
      {required this.shop,
      required this.made,
      required this.balanced,
      required this.money,
      required this.pageLabel});
}

TextPainter _tp(String s, double size,
    {FontWeight w = FontWeight.w400, Color c = PrintInk.ink, double maxW = _w,
    TextAlign align = TextAlign.left, int? maxLines}) {
  final tp = TextPainter(
    text: TextSpan(
        text: s,
        style: TextStyle(
            fontSize: size,
            fontWeight: w,
            color: c,
            height: 1.3,
            fontFamily: AFonts.latin,
            fontFamilyFallback: AFonts.fallback,
            fontFeatures: AFonts.tabular)),
    textDirection: TextDirection.ltr,
    textAlign: align,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  );
  tp.layout(minWidth: align == TextAlign.left ? 0 : maxW, maxWidth: maxW);
  return tp;
}

double _labelW(AcctReport r) => _w - (r.twoColumns ? 2 * _amtW : _amtW);

double _rowH(AcctReport r, AcctReportRow x) {
  final tp = _tp(x.label, x.style == AcctRowStyle.heading ? 26 : 24,
      maxW: _labelW(r) - (x.style == AcctRowStyle.indent ? 40 : 0) - 16, maxLines: 3);
  final h = tp.height + (x.style == AcctRowStyle.heading ? 30 : 20);
  tp.dispose();
  return h < 52 ? 52 : h;
}

/// Pure pagination over row heights (first page has the big header).
List<List<int>> paginateReport(List<double> heights, {double tail = 160}) {
  final pages = <List<int>>[<int>[]];
  var room = _ph - 2 * _m - _header - _footer;
  for (var i = 0; i < heights.length; i++) {
    if (heights[i] > room && pages.last.isNotEmpty) {
      pages.add(<int>[]);
      room = _ph - 2 * _m - _otherHeader - _footer;
    }
    pages.last.add(i);
    room -= heights[i];
  }
  if (room < tail) pages.add(<int>[]);
  return pages;
}

Future<Uint8List> buildReportPdf(AcctReport r, AcctPdfText txt) async {
  final heights = [for (final x in r.rows) _rowH(r, x)];
  final plan = paginateReport(heights);
  final out = <PdfPageImage>[];
  for (var p = 0; p < plan.length; p++) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, const Rect.fromLTWH(0, 0, _pw, _ph));
    _page(c, r, txt, plan[p], heights, p, plan.length);
    final pic = rec.endRecording();
    final img = await pic.toImage(_pw.toInt(), _ph.toInt());
    pic.dispose();
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (data == null) throw StateError('no pixels');
    out.add(PdfPageImage(rgbaToRgb(data.buffer.asUint8List()), _pw.toInt(), _ph.toInt()));
  }
  return imagePagesPdf(out, title: 'Accounts');
}

void _draw(Canvas c, TextPainter tp, double x, double y) {
  tp.paint(c, Offset(x, y));
  tp.dispose();
}

void _page(Canvas c, AcctReport r, AcctPdfText txt, List<int> rows, List<double> heights,
    int page, int pages) {
  c.drawRect(const Rect.fromLTWH(0, 0, _pw, _ph), Paint()..color = PrintInk.paper);
  var y = _m;
  if (page == 0) {
    c.drawRect(const Rect.fromLTWH(0, 0, _pw, 14), Paint()..color = PrintInk.brand);
    final shop = _tp(txt.shop, 44, w: FontWeight.w700, maxLines: 1);
    final sh = shop.height;
    _draw(c, shop, _m, y);
    y += sh + 6;
    final title = _tp(r.title, 32, w: FontWeight.w700, c: PrintInk.brand, maxLines: 1);
    final th = title.height;
    _draw(c, title, _m, y);
    y += th + 8;
    _draw(c, _tp(r.period, 26, maxLines: 2), _m, y);
    y = _m + _header - 70;
    _draw(c, _tp(txt.made, 20, c: PrintInk.muted, maxLines: 1), _m, y);
    y = _m + _header - 20;
  } else {
    _draw(c, _tp('${txt.shop} · ${r.title}', 24, c: PrintInk.muted, maxLines: 1), _m, y);
    y = _m + _otherHeader - 20;
  }
  final lw = _labelW(r);
  if (r.twoColumns) {
    c.drawRect(Rect.fromLTWH(_m, y, _w, 50), Paint()..color = PrintInk.band);
    _draw(c, _tp(r.colA ?? '', 22, w: FontWeight.w700, maxW: _amtW - 16, align: TextAlign.right, maxLines: 1),
        _m + lw + 8, y + 12);
    _draw(c, _tp(r.colB ?? '', 22, w: FontWeight.w700, maxW: _amtW - 16, align: TextAlign.right, maxLines: 1),
        _m + lw + _amtW + 8, y + 12);
    y += 50;
  }
  for (final i in rows) {
    final x = r.rows[i];
    final heading = x.style == AcctRowStyle.heading;
    final strong = x.style == AcctRowStyle.strong;
    final indent = x.style == AcctRowStyle.indent ? 40.0 : 0.0;
    final w = heading || strong ? FontWeight.w700 : FontWeight.w400;
    final ty = y + (heading ? 18 : 10);
    if (strong) {
      c.drawLine(Offset(_m, y), Offset(_pw - _m, y), Paint()
        ..color = PrintInk.ink
        ..strokeWidth = 2);
    }
    _draw(c, _tp(x.label, heading ? 26 : 24, w: w, c: heading ? PrintInk.brand : PrintInk.ink,
        maxW: lw - indent - 16, maxLines: 3), _m + indent + 8, ty);
    void amt(int? v, double col) {
      if (v == null || heading) return;
      _draw(c, _tp(txt.money(v), 24, w: w, maxW: _amtW - 16, align: TextAlign.right, maxLines: 1),
          _m + lw + col + 8, ty);
    }

    if (r.twoColumns) {
      amt(x.debit == 0 && !strong ? null : x.debit, 0);
      amt(x.credit == 0 && !strong ? null : x.credit, _amtW);
    } else {
      amt(x.amount, 0);
    }
    y += heights[i];
    c.drawLine(Offset(_m, y), Offset(_pw - _m, y), Paint()
      ..color = PrintInk.line
      ..strokeWidth = 1);
  }
  if (page == pages - 1) {
    y += 24;
    if (r.balanced != null && txt.balanced.isNotEmpty) {
      _draw(c, _tp(txt.balanced, 24, w: FontWeight.w700,
          c: r.balanced! ? PrintInk.got : PrintInk.gave, maxLines: 2), _m, y);
      y += 50;
    }
    if (r.footnote != null) {
      _draw(c, _tp(r.footnote!, 20, c: PrintInk.muted, maxLines: 4), _m, y);
    }
  }
  final fy = _ph - _m - 30;
  c.drawLine(Offset(_m, fy - 12), Offset(_pw - _m, fy - 12), Paint()
    ..color = PrintInk.line
    ..strokeWidth = 2);
  _draw(c, _tp(txt.pageLabel(page + 1, pages), 20, c: PrintInk.muted, maxW: 260,
      align: TextAlign.right, maxLines: 1), _pw - _m - 260, fy);
}
