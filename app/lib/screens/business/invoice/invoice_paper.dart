// invoices — draws an [InvoiceDoc] on 58 mm / 80 mm thermal paper or A4.
//
// Like the khata statement (statement_pdf.dart), every page is drawn with
// Flutter's OWN text engine using the app's bundled fonts (Inter + Noto Sans
// Bengali, both SIL OFL 1.1, in assets/fonts) so Bangla conjuncts are shaped
// exactly as on screen; the pictures are wrapped in a PDF by cctvx/mini_pdf.
// The fonts therefore travel INSIDE the PDF as shaped pixels — no printer or
// PDF viewer needs a Bangla font.
//
// Thermal pictures are exactly the printer's dot width (384 / 576) in pure
// black on white, so a shared PNG/PDF prints 1:1. A4 is 150 dpi, paginated.
//
// invdesign: per-business-type designs (header styles, logo, accent, token
// box, ship-to + COD boxes, Mushak-6.3 columns) behind [InvoiceDesign.styled];
// bilingual paper prints every label "বাংলা / English".
//
// The layout is a list of measured blocks (pure apart from text measuring),
// which the tests inspect: every block fits the paper width and each template
// prints its own fields.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../cctvx/mini_pdf.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme.dart' show AFonts, PrintInk;
import 'invoice_doc.dart';

const _black = PrintInk.thermal;

/// One measured piece of the paper.
class InvoiceBlock {
  final String kind; // header|title|meta|buyer|line|thead|rule|total|qr|note|...
  final double height;
  final List<String> texts; // every string drawn (tests)
  final double usedWidth; // widest thing drawn (tests: <= content width)
  final void Function(Canvas c, double x, double y) paint;
  const InvoiceBlock(this.kind, this.height, this.texts, this.usedWidth, this.paint);
}

class InvoiceLayout {
  final InvoicePaper paper;
  final String lang;
  final double width; // picture width (px / dots)
  final double margin; // left/right inside the picture
  final List<InvoiceBlock> blocks;
  const InvoiceLayout(this.paper, this.lang, this.width, this.margin, this.blocks);
  double get contentWidth => width - 2 * margin;
  double get height => blocks.fold<double>(0, (a, b) => a + b.height) + 2 * margin;
  List<String> get allTexts => [for (final b in blocks) ...b.texts];
  Iterable<InvoiceBlock> ofKind(String k) => blocks.where((b) => b.kind == k);
}

class _Style {
  final double base, small, big, title, pad, qr;
  const _Style(this.base, this.small, this.big, this.title, this.pad, this.qr);
}

_Style _style(InvoicePaper p) => switch (p) {
      InvoicePaper.mm58 => const _Style(21, 18, 30, 25, 4, 220),
      InvoicePaper.mm80 => const _Style(24, 20, 36, 29, 6, 260),
      InvoicePaper.a4 => const _Style(24, 20, 44, 32, 4, 220),
    };

double _margin(InvoicePaper p) => switch (p) {
      InvoicePaper.mm58 => 4,
      InvoicePaper.mm80 => 6,
      InvoicePaper.a4 => 84,
    };

TextPainter _tp(String s, double size, double maxW,
    {FontWeight w = FontWeight.w400,
    TextAlign align = TextAlign.left,
    Color c = _black,
    int? maxLines,
    double ls = 0}) {
  final tp = TextPainter(
    text: TextSpan(
        text: s,
        style: TextStyle(
            fontSize: size,
            fontWeight: w,
            color: c,
            height: 1.25,
            letterSpacing: ls,
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

String paymentLabel(AppLocalizations t, String code) => switch (code) {
      'cash' => t.invPmCash,
      'bkash' => t.invPmBkash,
      'nagad' => t.invPmNagad,
      'bank' => t.invPmBank,
      'due' => t.invPmDue,
      _ => code,
    };

String extraLabel(AppLocalizations t, String key) => switch (key) {
      'table' => t.invXTable,
      'token' => t.invXToken,
      'server' => t.invXServer,
      'guests' => t.invXGuests,
      'order_ref' => t.invXOrderRef,
      'delivery_address' => t.invXDeliverTo,
      'courier' => t.invXCourier,
      'tracking' => t.ivdXTracking,
      'serial' => t.invXSerial,
      'warranty' => t.invXWarranty,
      'matter' => t.ivdXMatter,
      'case_ref' => t.invXCaseRef,
      'court' => t.invXCourt,
      'fee_basis' => t.ivdXFeeBasis,
      'period' => t.invXPeriod,
      'tax_year' => t.invXTaxYear,
      'tin' => t.invXTin,
      'destination' => t.ivdXDestination,
      'vehicle' => t.ivdXVehicle,
      _ => key,
    };

String templateLabel(AppLocalizations t, String key) => switch (key) {
      'cafe' => t.invTplCafe,
      'restaurant' => t.invTplRestaurant,
      'fine_dining' => t.invTplFineDining,
      'ecommerce' => t.invTplEcommerce,
      'retail' => t.invTplRetail,
      'electronics' => t.invTplElectronics,
      'lawyer' => t.invTplLawyer,
      'vat_invoice' => t.ivdTplVat,
      'tax_consultant' => t.invTplTax,
      _ => t.invTplService,
    };

/// The paper title for this invoice (Mushak-6.3 wording when it carries VAT).
String invoiceTitle(AppLocalizations t, InvoiceDoc d) {
  if (d.calc.hasTax) return t.invTitleTax;
  if (foodTemplates.contains(d.template)) return t.invTitleBill;
  if (d.template == 'retail' || d.template == 'electronics') return t.invTitleMemo;
  return t.invTitleInvoice;
}

/// invdesign: how the paper is dressed. [styled] turns on the per-business-
/// type designs (switch `invoice_designs`); [classic] is the look before it.
class InvoiceDesign {
  final bool styled;
  final String accent; // key of PrintInk.accents (A4 only)
  final ui.Image? logo; // decoded owner logo (grey on thermal)
  const InvoiceDesign({this.styled = false, this.accent = 'brand', this.logo});
  static const classic = InvoiceDesign();
}

/// A4 header look per template.
String a4HeaderStyle(String template) => switch (template) {
      'fine_dining' => 'double',
      'lawyer' || 'tax_consultant' || 'service' => 'letter',
      'vat_invoice' => 'form',
      _ => 'band',
    };

const _grey = ui.ColorFilter.matrix(<double>[
  0.299, 0.587, 0.114, 0, 0, //
  0.299, 0.587, 0.114, 0, 0, //
  0.299, 0.587, 0.114, 0, 0, //
  0, 0, 0, 1, 0,
]);

void _paintLogo(Canvas cv, ui.Image img, Rect box, {required bool grey}) {
  final iw = img.width.toDouble(), ih = img.height.toDouble();
  final s = math.min(box.width / iw, box.height / ih);
  final w = iw * s, h = ih * s;
  final dst = Rect.fromLTWH(box.left + (box.width - w) / 2, box.top + (box.height - h) / 2, w, h);
  final p = Paint()..filterQuality = ui.FilterQuality.medium;
  if (grey) p.colorFilter = _grey;
  cv.drawImageRect(img, Rect.fromLTWH(0, 0, iw, ih), dst, p);
}

/// Builds the measured block list. [t] must be the localizations of [lang]
/// (`lookupAppLocalizations(Locale(lang))`), NOT the app's UI language — the
/// paper language is chosen per invoice. Bilingual paper: [lang] 'both', [t]
/// Bangla and [t2] English — every label prints "বাংলা / English" and the
/// digits are Latin (read by both).
InvoiceLayout layoutInvoice(InvoiceDoc d, InvoicePaper paper, AppLocalizations t,
    String lang,
    {AppLocalizations? t2, InvoiceDesign design = InvoiceDesign.classic}) {
  final st = _style(paper);
  final m = _margin(paper);
  final w = paper.widthPx - 2 * m;
  final a4 = paper == InvoicePaper.a4;
  final blocks = <InvoiceBlock>[];
  final styled = design.styled;
  final tpl = d.template;
  final brand = a4 ? (styled ? PrintInk.accent(design.accent) : PrintInk.brand) : _black;
  final muted = a4 ? PrintInk.muted : _black;
  final tableBand = a4 && styled ? brand.withValues(alpha: 0.10) : PrintInk.band;
  String money(int p) => invMoney(p, lang);
  String n(Object v) => invNum(v, lang);
  final t2v = t2;
  // one label in the paper's language(s)
  String L(String Function(AppLocalizations x) f) =>
      t2v == null ? f(t) : '${f(t)} / ${f(t2v)}';
  final logo = styled ? design.logo : null;

  // ---- helpers producing blocks
  void gap(double h) => blocks.add(InvoiceBlock('gap', h, const [], 0, (_, __, ___) {}));

  void text(String kind, String s,
      {double? size,
      FontWeight fw = FontWeight.w400,
      TextAlign align = TextAlign.left,
      Color? c,
      double padBelow = 2}) {
    if (s.trim().isEmpty) return;
    final tp = _tp(s, size ?? st.base, w, w: fw, align: align, c: c ?? _black);
    final h = tp.height + padBelow;
    final used = tp.width;
    blocks.add(InvoiceBlock(kind, h, [s], used, (cv, x, y) => tp.paint(cv, Offset(x, y))));
  }

  void rule({bool dashed = false, bool double_ = false, Color? color}) {
    final h = double_ ? 14.0 : 10.0;
    blocks.add(InvoiceBlock('rule', h, const [], w, (cv, x, y) {
      final p = Paint()
        ..color = color ?? (a4 ? PrintInk.line : _black)
        ..strokeWidth = 2;
      void line(double yy) {
        if (!dashed) {
          cv.drawLine(Offset(x, yy), Offset(x + w, yy), p);
          return;
        }
        for (var xx = x; xx < x + w; xx += 12) {
          cv.drawLine(Offset(xx, yy), Offset(math.min(xx + 6, x + w), yy), p);
        }
      }

      line(y + 4);
      if (double_) line(y + 9);
    }));
  }

  // label … value on one row; the label wraps, the value is right-aligned.
  void kv(String kind, String label, String value,
      {double? size, FontWeight fw = FontWeight.w400, Color? vc, double? width}) {
    if (value.trim().isEmpty) return;
    final bw = width ?? w;
    final sz = size ?? st.base;
    final vtp = _tp(value, sz, bw * 0.62, w: fw, align: TextAlign.right, c: vc ?? _black);
    final valueW = vtp.computeLineMetrics().fold<double>(
        0, (a, l) => l.width > a ? l.width : a);
    final ltp = _tp(label, sz, math.max(bw * 0.3, bw - valueW - 12), w: fw, c: _black);
    final h = (ltp.height > vtp.height ? ltp.height : vtp.height) + 3;
    final used = ltp.width + 12 + valueW;
    blocks.add(InvoiceBlock(kind, h, [label, value], used, (cv, x, y) {
      final ox = x + (w - bw);
      ltp.paint(cv, Offset(ox, y));
      vtp.paint(cv, Offset(ox + bw - bw * 0.62, y));
    }));
  }

  // a bordered box of text rows (ship-to, COD, token)
  void box(String kind, List<(String, double, FontWeight)> rows,
      {double stroke = 2, Color? color, TextAlign align = TextAlign.left, double? width}) {
    final rs = [for (final r in rows) if (r.$1.trim().isNotEmpty) r];
    if (rs.isEmpty) return;
    final bw = width ?? w;
    final tps = [
      for (final r in rs) _tp(r.$1, r.$2, bw - 24, w: r.$3, align: align, c: _black)
    ];
    final inner = tps.fold<double>(0, (a, p) => a + p.height + 2);
    final h = inner + 22;
    blocks.add(InvoiceBlock(kind, h + 8, [for (final r in rs) r.$1], bw, (cv, x, y) {
      cv.drawRect(
          Rect.fromLTWH(x, y + 2, bw, h),
          Paint()
            ..color = color ?? _black
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke);
      var yy = y + 12;
      for (final p in tps) {
        p.paint(cv, Offset(x + 12, yy));
        yy += p.height + 2;
      }
    }));
  }

  // ---- 1. cancelled stamp
  if (d.cancelled) {
    final s = d.cancelReason.isEmpty
        ? L((x) => x.invCancelled)
        : '${L((x) => x.invCancelled)} — ${d.cancelReason}';
    final tp = _tp(s, st.title, w - 16, w: FontWeight.w800, align: TextAlign.center,
        c: a4 ? PrintInk.gave : _black);
    blocks.add(InvoiceBlock('cancelled', tp.height + 22, [s], w, (cv, x, y) {
      cv.drawRect(Rect.fromLTWH(x, y, w, tp.height + 14), Paint()
        ..color = a4 ? PrintInk.gave : _black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3);
      tp.paint(cv, Offset(x + 8, y + 7));
    }));
  }

  // ---- 2. seller header
  final centred = !a4;
  final hAlign = centred ? TextAlign.center : TextAlign.left;
  final title = L((x) => invoiceTitle(x, d));
  final subs = [
    if (d.calc.hasTax) L((x) => x.invMushak),
    if (d.isService) L((x) => x.invSubFees),
  ];
  final hs = styled ? a4HeaderStyle(tpl) : 'band';
  final spaced = styled && tpl == 'fine_dining';
  if (a4) {
    final logoW = logo == null ? 0.0 : 150.0;
    final nameW = w * 0.56 - (logo == null ? 0 : logoW + 20);
    if (hs == 'form') {
      // Mushak-6.3 style: centred title box, seller block below
      final ttp = _tp(title, st.title, w - 40, w: FontWeight.w800, align: TextAlign.center, c: brand);
      final stps = [
        for (final s in subs) _tp(s, st.small, w - 40, align: TextAlign.center, c: muted)
      ];
      final h = stps.fold<double>(ttp.height, (a, p) => a + p.height) + 28;
      blocks.add(InvoiceBlock('header', h + 10, [title, ...subs], w, (cv, x, y) {
        cv.drawRect(Rect.fromLTWH(x, y, w, h), Paint()
          ..color = brand
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
        ttp.paint(cv, Offset(x + 20, y + 12));
        var sy = y + 12 + ttp.height;
        for (final p in stps) {
          p.paint(cv, Offset(x + 20, sy));
          sy += p.height;
        }
      }));
      final shop = _tp(d.seller.name.isEmpty ? '—' : d.seller.name, st.big, w - logoW - 20,
          w: FontWeight.w700, maxLines: 2);
      final sh = math.max(shop.height, logo == null ? 0.0 : 110.0) + 6;
      blocks.add(InvoiceBlock('header', sh, [d.seller.name], w, (cv, x, y) {
        if (logo != null) _paintLogo(cv, logo, Rect.fromLTWH(x, y, logoW, 110), grey: false);
        shop.paint(cv, Offset(x + (logo == null ? 0 : logoW + 20), y));
      }));
    } else {
      final ttp = _tp(title, st.title, w * 0.42, w: FontWeight.w700, align: TextAlign.right, c: brand);
      final stps = [
        for (final s in subs) _tp(s, st.small, w * 0.42, align: TextAlign.right, c: muted)
      ];
      final shop = _tp(d.seller.name.isEmpty ? '—' : d.seller.name, st.big, nameW,
          w: FontWeight.w700, maxLines: 2, ls: spaced ? 3 : 0);
      final rightH = stps.fold<double>(ttp.height, (a, p) => a + p.height);
      final leftH = math.max(shop.height, logo == null ? 0.0 : 110.0);
      final h = (leftH > rightH ? leftH : rightH) + (hs == 'double' ? 24 : 8);
      blocks.add(InvoiceBlock('header', h, [d.seller.name, title, ...subs], w, (cv, x, y) {
        final fill = Paint()..color = brand;
        switch (hs) {
          case 'double':
            cv.drawRect(Rect.fromLTWH(x, y + 2, w, 3), fill);
            cv.drawRect(Rect.fromLTWH(x, y + 9, w, 1.5), fill);
          case 'letter':
            cv.drawRect(Rect.fromLTWH(0, 0, 18, 520), fill);
          default:
            cv.drawRect(Rect.fromLTWH(0, 0, paper.widthPx, 14), fill);
        }
        final top = y + (hs == 'double' ? 16 : 0);
        var nx = x;
        if (logo != null) {
          _paintLogo(cv, logo, Rect.fromLTWH(x, top, logoW, 110), grey: false);
          nx += logoW + 20;
        }
        shop.paint(cv, Offset(nx, top));
        ttp.paint(cv, Offset(x + w - w * 0.42, top));
        var sy = top + ttp.height;
        for (final p in stps) {
          p.paint(cv, Offset(x + w - w * 0.42, sy));
          sy += p.height;
        }
      }));
    }
  } else {
    if (logo != null) {
      final lh = paper == InvoicePaper.mm58 ? 96.0 : 128.0;
      blocks.add(InvoiceBlock('logo', lh + 8, const [], w * 0.5, (cv, x, y) {
        _paintLogo(cv, logo, Rect.fromLTWH(x + w * 0.25, y, w * 0.5, lh), grey: true);
      }));
    }
    if (tpl == 'fine_dining') rule(double_: true);
    final name = d.seller.name.isEmpty ? '—' : d.seller.name;
    final ntp = _tp(name, st.big, w, w: FontWeight.w800, align: hAlign, ls: spaced ? 2 : 0);
    blocks.add(InvoiceBlock('header', ntp.height + 2, [name], ntp.width,
        (cv, x, y) => ntp.paint(cv, Offset(x, y))));
  }
  text('seller', d.seller.address, size: st.small, align: hAlign, c: muted);
  if (d.seller.phone.isNotEmpty) {
    text('seller', '${L((x) => x.invPhone)}: ${n(d.seller.phone)}',
        size: st.small, align: hAlign, c: muted);
  }
  if (d.seller.bin.isNotEmpty) {
    text('seller', '${L((x) => x.invBin)}: ${n(d.seller.bin)}',
        size: st.small, fw: FontWeight.w600, align: hAlign, c: _black);
  }
  if (!a4) {
    if (tpl == 'fine_dining') rule(double_: true);
    rule(dashed: true);
    text('title', title, size: st.title, fw: FontWeight.w700, align: TextAlign.center);
    for (final s in subs) {
      text('title', s, size: st.small, align: TextAlign.center);
    }
  } else {
    gap(6);
    rule(color: styled && hs != 'band' ? brand : null);
  }

  // cafe: the token is what the customer listens for — print it BIG
  final tokenBox = styled && tpl == 'cafe' && (d.extras['token'] ?? '').isNotEmpty;
  if (tokenBox) {
    gap(4);
    box('token', [
      (L((x) => x.invXToken), st.small, FontWeight.w600),
      (n(d.extras['token']!), st.big * 1.6, FontWeight.w800),
    ], stroke: 3, color: brand, align: TextAlign.center, width: a4 ? w * 0.3 : null);
  }

  // ---- 3. meta + buyer
  final shipBox = styled && tpl == 'ecommerce';
  const shipKeys = {'delivery_address', 'courier', 'tracking'};
  final metaW = a4 ? w * 0.46 : w;
  final meta = <(String, String)>[
    (L((x) => x.invNo), d.number),
    if (d.issuedAt != null)
      (L((x) => x.invDateL), '${invDate(d.issuedAt!, lang)}  ${invTime(d.issuedAt!, lang)}'),
    if (d.paymentMethod.isNotEmpty)
      (L((x) => x.invPaidVia), L((x) => paymentLabel(x, d.paymentMethod))),
    for (final k in templateFields[tpl] ?? const <String>[])
      if ((d.extras[k] ?? '').isNotEmpty &&
          !(tokenBox && k == 'token') &&
          !(shipBox && shipKeys.contains(k)))
        (L((x) => extraLabel(x, k)), d.extras[k]!),
  ];
  final buyer = <String>[
    if (d.buyer.name.isNotEmpty) d.buyer.name,
    if (d.buyer.phone.isNotEmpty) n(d.buyer.phone),
    if (d.buyer.address.isNotEmpty && !shipBox) d.buyer.address,
    if (d.buyer.bin.isNotEmpty) '${L((x) => x.invBin)}: ${n(d.buyer.bin)}',
  ];
  final buyerLabel = d.isService ? L((x) => x.invClient) : L((x) => x.invBillTo);
  if (a4) {
    // two columns: buyer (left) | meta (right)
    final left = <TextPainter>[
      if (buyer.isNotEmpty) _tp(buyerLabel, st.small, w * 0.5, c: muted, w: FontWeight.w600),
      for (var i = 0; i < buyer.length; i++)
        _tp(buyer[i], i == 0 ? st.base + 2 : st.base, w * 0.5,
            w: i == 0 ? FontWeight.w700 : FontWeight.w400),
    ];
    final right = <(TextPainter, TextPainter)>[
      for (final r in meta)
        (_tp(r.$1, st.small, metaW * 0.42, c: muted),
            _tp(n(r.$2), st.base, metaW * 0.58, align: TextAlign.right, w: FontWeight.w600)),
    ];
    final lh = left.fold<double>(0, (a, p) => a + p.height + 2);
    final rh = right.fold<double>(
        0, (a, p) => a + (p.$1.height > p.$2.height ? p.$1.height : p.$2.height) + 4);
    blocks.add(InvoiceBlock('meta', (lh > rh ? lh : rh) + 12,
        [if (buyer.isNotEmpty) buyerLabel, ...buyer, for (final r in meta) ...[r.$1, n(r.$2)]],
        w, (cv, x, y) {
      var ly = y;
      for (final p in left) {
        p.paint(cv, Offset(x, ly));
        ly += p.height + 2;
      }
      var ry = y;
      final rx = x + w - metaW;
      for (final p in right) {
        p.$1.paint(cv, Offset(rx, ry));
        p.$2.paint(cv, Offset(rx + metaW * 0.42, ry));
        ry += (p.$1.height > p.$2.height ? p.$1.height : p.$2.height) + 4;
      }
    }));
  } else {
    for (final r in meta) {
      kv('meta', r.$1, n(r.$2), size: st.small);
    }
    if (buyer.isNotEmpty && !shipBox) {
      rule(dashed: true);
      text('buyer', buyerLabel, size: st.small, fw: FontWeight.w600);
      for (var i = 0; i < buyer.length; i++) {
        text('buyer', buyer[i], size: st.small, fw: i == 0 ? FontWeight.w700 : FontWeight.w400);
      }
    }
  }

  // e-commerce: the courier reads THIS box — ship-to, phone, courier, tracking
  if (shipBox) {
    final addr = (d.extras['delivery_address'] ?? '').isNotEmpty
        ? d.extras['delivery_address']!
        : d.buyer.address;
    final courier = [
      if ((d.extras['courier'] ?? '').isNotEmpty)
        '${L((x) => x.invXCourier)}: ${d.extras['courier']}',
      if ((d.extras['tracking'] ?? '').isNotEmpty)
        '${L((x) => x.ivdXTracking)}: ${d.extras['tracking']}',
    ].join('  ·  ');
    gap(4);
    box('ship', [
      (L((x) => x.ivdShipTo), st.small, FontWeight.w700),
      (d.buyer.name, st.base + 2, FontWeight.w800),
      (d.buyer.phone.isEmpty ? '' : n(d.buyer.phone), st.base, FontWeight.w700),
      (addr, st.base, FontWeight.w400),
      (courier, st.small, FontWeight.w600),
    ], stroke: 3, color: brand, width: a4 ? w * 0.6 : null);
  }

  // ---- 4. lines
  final hoursHead = d.byHours;
  final qtyHead = hoursHead ? L((x) => x.ivdHours) : L((x) => x.invColQty);
  final rateHead = hoursHead ? L((x) => x.ivdRatePerHour) : L((x) => x.invColRate);
  String serialLine(InvoiceLine l) =>
      l.serial.isEmpty ? '' : '${L((x) => x.invXSerial)}: ${l.serial}';
  String warrantyLine(InvoiceLine l) {
    if (l.warrantyM <= 0) return '';
    final months = n(l.warrantyM);
    final until = d.issuedAt == null ? '' : invDate(addMonths(d.issuedAt!, l.warrantyM), lang);
    return t2v == null
        ? t.ivdWarrantyUntil(months, until)
        : '${t.ivdWarrantyUntil(months, until)} / ${t2v.ivdWarrantyUntil(months, until)}';
  }

  final mushak = styled && tpl == 'vat_invoice' && d.calc.hasTax;
  final lineTax = mushak ? allocateLineTax(d.lines, d.calc) : const <LineTax>[];
  if (a4) {
    final List<String> heads;
    final List<double> widths;
    if (mushak) {
      heads = [
        '#', L((x) => x.invColItem), qtyHead, rateHead, L((x) => x.ivdColValue),
        '${L((x) => x.ivdColSd)} ${invRate(d.calc.sdBp, lang)}',
        '${L((x) => x.ivdColVat)} ${invRate(d.calc.vatBp, lang)}',
        L((x) => x.ivdColTotalIncl),
      ];
      widths = [
        w * 0.05, w * 0.25, w * 0.08, w * 0.12, w * 0.13, w * 0.11, w * 0.12, w * 0.14
      ];
    } else {
      heads = ['#', L((x) => x.invColItem), qtyHead, rateHead, L((x) => x.invColAmount)];
      final cQty = w * 0.11, cRate = w * 0.17, cAmt = w * 0.19, cNo = w * 0.06;
      widths = [cNo, w - cQty - cRate - cAmt - cNo, cQty, cRate, cAmt];
    }
    final body = mushak ? st.small : st.base;
    List<TextPainter> row(List<String> cells, {bool head = false}) => [
          for (var i = 0; i < cells.length; i++)
            _tp(cells[i], head ? st.small - (mushak ? 2 : 0) : body, widths[i] - 12,
                w: head ? FontWeight.w700 : FontWeight.w400,
                c: head && styled ? brand : _black,
                align: i >= 2 ? TextAlign.right : TextAlign.left,
                maxLines: i == 1 ? 8 : (head ? 4 : 2)),
        ];
    InvoiceBlock tableRow(String kind, List<String> cells, {bool head = false}) {
      final ps = row(cells, head: head);
      final h = ps.fold<double>(0, (a, p) => p.height > a ? p.height : a) + (head ? 18 : 16);
      return InvoiceBlock(kind, h, cells, w, (cv, x, y) {
        if (head) {
          cv.drawRect(Rect.fromLTWH(x, y, w, h - 4), Paint()..color = tableBand);
        }
        var cx = x;
        for (var i = 0; i < ps.length; i++) {
          ps[i].paint(cv, Offset(cx + 6, y + (head ? 8 : 7)));
          cx += widths[i];
        }
        if (!head) {
          cv.drawLine(Offset(x, y + h - 1), Offset(x + w, y + h - 1), Paint()
            ..color = PrintInk.line
            ..strokeWidth = 1);
        }
      });
    }

    blocks.add(tableRow('thead', heads, head: true));
    for (var i = 0; i < d.lines.length; i++) {
      final l = d.lines[i];
      final item = [l.desc, serialLine(l), warrantyLine(l)].where((s) => s.isNotEmpty).join('\n');
      blocks.add(tableRow('line', [
        n(i + 1), item, l.qtyText(lang), money(l.unit),
        if (mushak) ...[
          money(lineTax[i].value), money(lineTax[i].sd), money(lineTax[i].vat),
          money(lineTax[i].total),
        ] else
          money(l.amount),
      ]));
    }
  } else {
    kv('thead', L((x) => x.invColItem), L((x) => x.invColAmount), size: st.small, fw: FontWeight.w700);
    rule(dashed: true);
    for (var i = 0; i < d.lines.length; i++) {
      final l = d.lines[i];
      final dtp = _tp(l.desc, st.base, w, w: FontWeight.w600);
      final qtext = '${l.qtyText(lang)}${hoursHead ? ' ${L((x) => x.ivdHoursShort)}' : ''} × ${money(l.unit)}';
      final qtp = _tp(qtext, st.small, w * 0.5);
      final atp = _tp(money(l.amount), st.base, w * 0.5, align: TextAlign.right, w: FontWeight.w600);
      final extra = [
        serialLine(l),
        warrantyLine(l),
        if (mushak)
          '${L((x) => x.ivdColValue)} ${money(lineTax[i].value)} · '
              '${L((x) => x.ivdColVat)} ${money(lineTax[i].vat)}',
      ].where((s) => s.isNotEmpty).toList();
      final xtps = [for (final s in extra) _tp(s, st.small, w)];
      final second = qtp.height > atp.height ? qtp.height : atp.height;
      final xh = xtps.fold<double>(0, (a, p) => a + p.height);
      blocks.add(InvoiceBlock('line', dtp.height + second + xh + 6,
          [l.desc, qtext, money(l.amount), ...extra],
          dtp.width > w ? dtp.width : w, (cv, x, y) {
        dtp.paint(cv, Offset(x, y));
        qtp.paint(cv, Offset(x, y + dtp.height));
        atp.paint(cv, Offset(x + w * 0.5, y + dtp.height));
        var yy = y + dtp.height + second;
        for (final p in xtps) {
          p.paint(cv, Offset(x, yy));
          yy += p.height;
        }
      }));
    }
  }
  rule(dashed: !a4);

  // ---- 5. totals
  final tw = a4 ? w * 0.5 : w;
  final c = d.calc;
  kv('total', L((x) => x.invSubtotal), money(c.subtotal), width: tw);
  if (c.discount > 0) kv('total', L((x) => x.invDiscount), '-${money(c.discount)}', width: tw);
  if (c.service > 0) {
    kv('total', L((x) => x.invServiceCharge(invRate(c.serviceBp, lang))), money(c.service),
        width: tw);
  }
  if (c.hasTax) {
    kv('tax', L((x) => x.invTaxable), money(c.taxable), width: tw);
    if (c.sdBp > 0) kv('tax', L((x) => x.invSd(invRate(c.sdBp, lang))), money(c.sd), width: tw);
    kv('tax', L((x) => x.invVat(invRate(c.vatBp, lang))), money(c.vat), width: tw);
  }
  if (c.shipping > 0) kv('total', L((x) => x.ivdShipping), money(c.shipping), width: tw);
  kv('grand', L((x) => x.invTotal), money(c.total),
      size: st.title, fw: FontWeight.w800, vc: brand, width: tw);
  if (c.vatMode == 'inclusive') {
    text('note', L((x) => x.invVatIncluded),
        size: st.small, align: a4 ? TextAlign.right : TextAlign.left, c: muted);
  }
  final lawyer = styled && tpl == 'lawyer';
  final balance = styled && serviceTemplates.contains(tpl);
  if (d.paid > 0) {
    kv('pay', lawyer ? L((x) => x.ivdRetainerPaid) : L((x) => x.invPaid), money(d.paid), width: tw);
  }
  if (d.change > 0) kv('pay', L((x) => x.invChange), money(d.change), width: tw);
  if (d.due > 0 && !shipBox) {
    kv('pay',
        tpl == 'ecommerce'
            ? L((x) => x.invCod)
            : balance
                ? L((x) => x.ivdBalanceDue)
                : L((x) => x.invDue),
        money(d.due),
        fw: FontWeight.w700, vc: a4 ? PrintInk.gave : _black, width: tw);
  }
  // e-commerce: the one number the rider must collect, impossible to miss
  if (shipBox && !d.cancelled) {
    gap(6);
    box(
        'cod',
        d.due > 0
            ? [
                (L((x) => x.invCod), st.base, FontWeight.w700),
                (money(d.due), st.big * 1.3, FontWeight.w800),
              ]
            : [(L((x) => x.ivdPrepaid), st.base, FontWeight.w800)],
        stroke: 4,
        align: TextAlign.center,
        width: a4 ? w * 0.5 : null);
  }
  if (d.note.isNotEmpty) {
    gap(6);
    text('note', d.note, size: st.small);
  }

  // ---- 6. QR codes
  final qrs = invoiceQrs(d);
  if (qrs.isNotEmpty) {
    gap(10);
    final sz = st.qr;
    final per = a4 ? qrs.length : 1;
    for (var i = 0; i < qrs.length; i += per) {
      final group = qrs.sublist(i, math.min(i + per, qrs.length));
      String cap(InvoiceQr q) =>
          q.kind == 'verify' ? L((x) => x.invQrVerify) : L((x) => x.invQrPay);
      final caps = [
        for (final q in group)
          _tp(cap(q), st.small, a4 ? sz + 60 : w, align: TextAlign.center, w: FontWeight.w600)
      ];
      final capH = caps.fold<double>(0, (a, p) => p.height > a ? p.height : a);
      blocks.add(InvoiceBlock('qr', sz + capH + 16,
          [for (final q in group) q.data, for (final q in group) cap(q)],
          a4 ? group.length * (sz + 80) : sz, (cv, x, y) {
        for (var j = 0; j < group.length; j++) {
          final cellW = a4 ? sz + 80 : w;
          final cx = x + j * cellW;
          final qx = cx + (cellW - sz) / 2;
          try {
            final painter = QrPainter(
              data: group[j].data,
              version: QrVersions.auto,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              gapless: true,
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: _black),
              dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square, color: _black),
            );
            cv.save();
            cv.translate(qx, y);
            painter.paint(cv, Size(sz, sz));
            cv.restore();
          } catch (_) {
            // best-effort: an unencodable link is simply not printed (never a broken QR)
          }
          caps[j].paint(cv, Offset(a4 ? cx + 10 : x, y + sz + 6));
        }
      }));
    }
  }

  // ---- 7. signature (tax invoices + professional services)
  if (c.hasTax || d.isService) {
    gap(a4 ? 50 : 40);
    final sl = L((x) => x.invSignature);
    final sig = d.seller.signatory.isEmpty ? sl : '$sl\n${d.seller.signatory}';
    final sw = a4 ? w * 0.4 : w * 0.8;
    final tp = _tp(sig, st.small, sw, align: TextAlign.center);
    blocks.add(InvoiceBlock('signature', tp.height + 12, [sig], sw, (cv, x, y) {
      final sx = a4 ? x + w - sw : x + (w - sw) / 2;
      cv.drawLine(Offset(sx, y), Offset(sx + sw, y), Paint()
        ..color = _black
        ..strokeWidth = 2);
      tp.paint(cv, Offset(sx, y + 6));
    }));
  }

  // ---- 8. footer
  gap(10);
  if (tpl == 'electronics') {
    text('footer', L((x) => x.invWarrantyKeep), size: st.small, fw: FontWeight.w600, align: hAlign);
  }
  text('footer', d.seller.footer, size: st.small, align: hAlign);
  if (!d.isService && tpl != 'ecommerce' && tpl != 'vat_invoice') {
    text('footer', L((x) => x.invThanks), size: st.small, align: hAlign);
  }
  if (tpl == 'vat_invoice' && !c.hasTax) {
    text('footer', L((x) => x.ivdNotVatRegistered), size: st.small, align: hAlign, c: muted);
  }
  if (c.hasTax) {
    text('footer', L((x) => x.invRateNote), size: st.small - 2, align: hAlign, c: muted);
    // HONEST: we cannot claim NBR compliance — say so on every tax paper
    text('footer', L((x) => x.ivdNotNbr), size: st.small - 2, align: hAlign, c: muted);
  }
  text('footer', L((x) => x.invMadeWith), size: st.small - 2, align: hAlign, c: muted);

  return InvoiceLayout(paper, lang, paper.widthPx, m, blocks);
}

/// A4 pagination: block indices per page (page breaks fall between blocks).
List<List<int>> paginateInvoice(InvoiceLayout l, {double pageH = 1754}) {
  final room0 = pageH - 2 * l.margin - 60; // footer: page number
  final pages = <List<int>>[<int>[]];
  var room = room0;
  for (var i = 0; i < l.blocks.length; i++) {
    final h = l.blocks[i].height;
    if (h > room && pages.last.isNotEmpty) {
      pages.add(<int>[]);
      room = room0 - 50; // continuation header
    }
    pages.last.add(i);
    room -= h;
  }
  return pages;
}

Future<ui.Image> _draw(double width, double height, void Function(Canvas c) body) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, width, height));
  c.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = PrintInk.paper);
  body(c);
  final pic = rec.endRecording();
  final img = await pic.toImage(width.ceil(), height.ceil());
  pic.dispose();
  return img;
}

/// The pictures of the paper: ONE tall picture for thermal, A4 pages.
Future<List<ui.Image>> renderInvoiceImages(InvoiceLayout l, AppLocalizations t,
    {String number = ''}) async {
  if (l.paper.thermal) {
    final h = l.height;
    return [
      await _draw(l.width, h, (c) {
        var y = l.margin;
        for (final b in l.blocks) {
          b.paint(c, l.margin, y);
          y += b.height;
        }
      })
    ];
  }
  const pageH = 1754.0;
  final plan = paginateInvoice(l, pageH: pageH);
  final out = <ui.Image>[];
  for (var p = 0; p < plan.length; p++) {
    out.add(await _draw(l.width, pageH, (c) {
      var y = l.margin;
      if (p > 0) {
        final tp = _tp(number, 20, l.contentWidth, c: PrintInk.muted);
        tp.paint(c, Offset(l.margin, y));
        y += 50;
      }
      for (final i in plan[p]) {
        l.blocks[i].paint(c, l.margin, y);
        y += l.blocks[i].height;
      }
      if (plan.length > 1) {
        final tp = _tp(t.invPage(invNum(p + 1, l.lang), invNum(plan.length, l.lang)), 20,
            l.contentWidth,
            align: TextAlign.right, c: PrintInk.muted);
        tp.paint(c, Offset(l.margin, pageH - l.margin));
      }
    }));
  }
  return out;
}

Future<PdfPageImage> _rgb(ui.Image img) async {
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final w = img.width, h = img.height;
  img.dispose();
  if (data == null) throw StateError('no pixels');
  return PdfPageImage(rgbaToRgb(data.buffer.asUint8List()), w, h);
}

/// PDF bytes: thermal = one roll page exactly the paper width (58 / 80 mm)
/// and as tall as the receipt; A4 = A4 pages.
Future<Uint8List> buildInvoicePdf(InvoiceLayout l, AppLocalizations t,
    {String number = ''}) async {
  final imgs = await renderInvoiceImages(l, t, number: number);
  final pages = <PdfPageImage>[];
  for (final i in imgs) {
    pages.add(await _rgb(i));
  }
  if (l.paper.thermal) {
    return imagePagesPdf(pages,
        title: 'Invoice',
        pageWidthPt: l.paper.pageWidthPt,
        imageWidthPt: l.paper.printWidthPt,
        marginPt: 8);
  }
  return imagePagesPdf(pages, title: 'Invoice');
}

/// PNG of the thermal receipt (for printer apps that take an image).
Future<Uint8List> buildInvoicePng(InvoiceLayout l, AppLocalizations t) async {
  final imgs = await renderInvoiceImages(l, t);
  final img = imgs.first;
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  for (final i in imgs) {
    i.dispose();
  }
  if (data == null) throw StateError('no pixels');
  return data.buffer.asUint8List();
}
