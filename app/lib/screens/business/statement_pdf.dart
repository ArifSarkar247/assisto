// bizbar — the customer / supplier STATEMENT as a real PDF, in Bangla.
//
// TallyKhata, Hishabee, Khatabook and Vyapar all hand the customer a PDF
// statement; ours only existed as server data. PDF fonts cannot shape Bangla
// conjuncts reliably, so every page is drawn with Flutter's OWN text engine
// (the app's Inter + Noto Sans Bengali, the same shaping the screen uses) onto
// an A4 picture, and the pictures are wrapped in a PDF (cctvx/mini_pdf.dart).
// Works offline (from the statement already on screen), one page at a time so
// a 2 GB phone never holds more than one page of pixels.
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Canvas, Color, Offset, Paint, RRect, Radius, Rect;

import 'package:flutter/painting.dart';

import '../../cctvx/mini_pdf.dart';
import '../../theme.dart' show AFonts;

class StatementPdfRow {
  final String date;
  final String details;
  final String gave; // the column that RAISES the balance ('' if none)
  final String got; // a payment ('' if none)
  final String balance;
  const StatementPdfRow(
      {required this.date,
      required this.details,
      required this.gave,
      required this.got,
      required this.balance});
}

/// Every string already localized (bn digits etc.) by the caller.
class StatementPdfDoc {
  final String shop;
  final String title;
  final String party; // "Karim · 01712…"
  final String made; // "Made on 2 Nov 2026"
  final String colDate, colDetails, colGave, colGot, colBalance;
  final List<StatementPdfRow> rows; // oldest first
  final String totalLabel, totalGave, totalGot;
  final String closingLabel, closing, closingStatus;
  final String? note; // e.g. "2 entries waiting to sync are not included"
  final String footer;
  final String Function(int page, int pages) pageLabel;
  final String emptyRows;
  const StatementPdfDoc({
    required this.shop,
    required this.title,
    required this.party,
    required this.made,
    required this.colDate,
    required this.colDetails,
    required this.colGave,
    required this.colGot,
    required this.colBalance,
    required this.rows,
    required this.totalLabel,
    required this.totalGave,
    required this.totalGot,
    required this.closingLabel,
    required this.closing,
    required this.closingStatus,
    required this.footer,
    required this.pageLabel,
    required this.emptyRows,
    this.note,
  });
}

// A4 at 150 dpi.
const double pdfPageW = 1240, pdfPageH = 1754;
const double _m = 72;
const double _w = pdfPageW - 2 * _m;
const double _colDate = 170, _colAmt = 180;
const double _colDetails = _w - _colDate - 3 * _colAmt;
const double _rowMin = 54;
const double _firstHeader = 300, _otherHeader = 110, _tableHead = 60;
const double _footer = 70, _summary = 250;

const _ink = Color(0xFF1B1B1F);
const _muted = Color(0xFF5F5E66);
const _line = Color(0xFFDADAE0);
const _band = Color(0xFFF1F0F7);
const _brand = Color(0xFF3D4BD6);

TextPainter _tp(String s, double size,
    {FontWeight w = FontWeight.w400,
    Color c = _ink,
    double maxW = _w,
    int? maxLines,
    TextAlign align = TextAlign.left}) {
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

double _rowHeight(StatementPdfRow r) {
  final d = _tp(r.details, 24, maxW: _colDetails - 16, maxLines: 3);
  final dt = _tp(r.date, 22, maxW: _colDate - 12, maxLines: 2);
  final h = (d.height > dt.height ? d.height : dt.height) + 22;
  d.dispose();
  dt.dispose();
  return h < _rowMin ? _rowMin : h;
}

/// Pure pagination: which rows go on which page, so the summary block fits
/// on the last page (a new page is added for it when needed). Never returns
/// an empty list (an empty statement is still one page).
List<List<int>> paginateRows(List<double> heights,
    {double pageH = pdfPageH,
    double first = _firstHeader,
    double other = _otherHeader,
    double head = _tableHead,
    double footer = _footer,
    double summary = _summary}) {
  final pages = <List<int>>[<int>[]];
  var room = pageH - 2 * _m - first - head - footer;
  for (var i = 0; i < heights.length; i++) {
    if (heights[i] > room && pages.last.isNotEmpty) {
      pages.add(<int>[]);
      room = pageH - 2 * _m - other - head - footer;
    }
    pages.last.add(i);
    room -= heights[i];
  }
  if (room < summary) pages.add(<int>[]);
  return pages;
}

/// Draws [doc] into A4 page pictures and returns the PDF bytes.
Future<Uint8List> buildStatementPdf(StatementPdfDoc doc) async {
  final heights = [for (final r in doc.rows) _rowHeight(r)];
  final plan = paginateRows(heights);
  final out = <PdfPageImage>[];
  for (var p = 0; p < plan.length; p++) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, const Rect.fromLTWH(0, 0, pdfPageW, pdfPageH));
    _drawPage(c, doc, plan[p], heights, p, plan.length);
    final pic = rec.endRecording();
    final img = await pic.toImage(pdfPageW.toInt(), pdfPageH.toInt());
    pic.dispose();
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (data == null) throw StateError('no pixels');
    out.add(PdfPageImage(
        rgbaToRgb(data.buffer.asUint8List()), pdfPageW.toInt(), pdfPageH.toInt()));
  }
  return imagePagesPdf(out, title: 'Statement');
}

void _text(Canvas c, TextPainter tp, double x, double y) {
  tp.paint(c, Offset(x, y));
  tp.dispose();
}

void _drawPage(Canvas c, StatementPdfDoc d, List<int> rows,
    List<double> heights, int page, int pages) {
  c.drawRect(const Rect.fromLTWH(0, 0, pdfPageW, pdfPageH),
      Paint()..color = const Color(0xFFFFFFFF));
  var y = _m;
  final lp = Paint()
    ..color = _line
    ..strokeWidth = 2;
  if (page == 0) {
    c.drawRect(const Rect.fromLTWH(0, 0, pdfPageW, 14), Paint()..color = _brand);
    final shop = _tp(d.shop, 44, w: FontWeight.w700, maxLines: 1);
    final sh = shop.height;
    _text(c, shop, _m, y);
    y += sh + 6;
    final title = _tp(d.title, 30, w: FontWeight.w600, c: _brand, maxLines: 1);
    final th = title.height;
    _text(c, title, _m, y);
    y += th + 14;
    final party = _tp(d.party, 28, w: FontWeight.w600, maxLines: 2);
    final ph = party.height;
    _text(c, party, _m, y);
    y += ph + 6;
    _text(c, _tp(d.made, 22, c: _muted, maxLines: 1), _m, y);
    y = _m + _firstHeader - 20;
  } else {
    final top = _tp('${d.shop} · ${d.party}', 24, c: _muted, maxLines: 1);
    _text(c, top, _m, y);
    y = _m + _otherHeader - 20;
  }
  c.drawLine(Offset(_m, y), Offset(pdfPageW - _m, y), lp);
  y += 10;

  // table head
  c.drawRect(Rect.fromLTWH(_m, y, _w, _tableHead - 10), Paint()..color = _band);
  void cell(String s, double x, double cw, double yy,
      {bool right = false, FontWeight w = FontWeight.w400, double size = 24,
      Color col = _ink, int maxLines = 1}) {
    final tp = _tp(s, size,
        w: w,
        c: col,
        maxW: cw - 16,
        maxLines: maxLines,
        align: right ? TextAlign.right : TextAlign.left);
    _text(c, tp, x + 8, yy);
  }

  final xDetails = _m + _colDate;
  final xGave = xDetails + _colDetails;
  final xGot = xGave + _colAmt;
  final xBal = xGot + _colAmt;
  final hy = y + 12;
  cell(d.colDate, _m, _colDate, hy, w: FontWeight.w700, size: 22);
  cell(d.colDetails, xDetails, _colDetails, hy, w: FontWeight.w700, size: 22);
  cell(d.colGave, xGave, _colAmt, hy, right: true, w: FontWeight.w700, size: 22);
  cell(d.colGot, xGot, _colAmt, hy, right: true, w: FontWeight.w700, size: 22);
  cell(d.colBalance, xBal, _colAmt, hy, right: true, w: FontWeight.w700, size: 22);
  y += _tableHead;

  if (d.rows.isEmpty && page == 0) {
    cell(d.emptyRows, _m, _w, y + 12, col: _muted);
    y += _rowMin;
  }
  for (final i in rows) {
    final r = d.rows[i];
    final h = heights[i];
    final ry = y + 11;
    cell(r.date, _m, _colDate, ry, size: 22, col: _muted, maxLines: 2);
    cell(r.details, xDetails, _colDetails, ry, maxLines: 3);
    if (r.gave.isNotEmpty) {
      cell(r.gave, xGave, _colAmt, ry, right: true, col: const Color(0xFFB3261E));
    }
    if (r.got.isNotEmpty) {
      cell(r.got, xGot, _colAmt, ry, right: true, col: const Color(0xFF1B7F3B));
    }
    cell(r.balance, xBal, _colAmt, ry, right: true, w: FontWeight.w600);
    y += h;
    c.drawLine(Offset(_m, y), Offset(pdfPageW - _m, y), Paint()
      ..color = _line
      ..strokeWidth = 1);
  }

  if (page == pages - 1) {
    y += 24;
    // totals
    cell(d.totalLabel, _m, _colDate + _colDetails, y, w: FontWeight.w700);
    cell(d.totalGave, xGave, _colAmt, y, right: true, w: FontWeight.w700);
    cell(d.totalGot, xGot, _colAmt, y, right: true, w: FontWeight.w700);
    y += 56;
    final box = Rect.fromLTWH(_m, y, _w, 110);
    c.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(16)),
        Paint()..color = _band);
    cell(d.closingLabel, _m + 16, _w / 2, y + 18, w: FontWeight.w600, col: _muted);
    cell(d.closingStatus, _m + 16, _w / 2, y + 58, w: FontWeight.w700, size: 28);
    cell(d.closing, _m + _w / 2, _w / 2 - 16, y + 30,
        right: true, w: FontWeight.w800, size: 44, col: _brand);
    y += 130;
    if (d.note != null && d.note!.isNotEmpty) {
      cell(d.note!, _m, _w, y, col: const Color(0xFFB3261E), size: 22, maxLines: 2);
    }
  }

  // footer
  final fy = pdfPageH - _m - 30;
  c.drawLine(Offset(_m, fy - 12), Offset(pdfPageW - _m, fy - 12), lp);
  cell(page == pages - 1 ? d.footer : '', _m, _w - 200, fy,
      size: 18, col: _muted, maxLines: 2);
  cell(d.pageLabel(page + 1, pages), pdfPageW - _m - 220, 220, fy,
      right: true, size: 20, col: _muted);
}
