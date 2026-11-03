// invoices — the invoice the server computed (business/sales/<id>/invoice or
// business/invoices/<id>), parsed into a plain object, plus the pure helpers
// the paper renderer and the tests share: paper sizes, money/date text in
// bn/en digits, which QR codes print and the per-template extra fields.
//
// All money is integer POISHA. VAT/SD math is done ONCE, on the server
// (core/logic/invoice_calc.py); the app only prints it.
import '../../../messaging/date_separators.dart' show localDigits;

/// Paper sizes. Thermal widths are the printer's own DOTS at 203 dpi
/// (58 mm paper → 48 mm printable = 384 dots; 80 mm → 72 mm = 576 dots), so a
/// shared image prints 1:1 without blur.
enum InvoicePaper { mm58, mm80, a4 }

extension InvoicePaperX on InvoicePaper {
  String get code => switch (this) {
        InvoicePaper.mm58 => '58',
        InvoicePaper.mm80 => '80',
        InvoicePaper.a4 => 'a4',
      };
  bool get thermal => this != InvoicePaper.a4;

  /// Picture width in pixels/dots.
  double get widthPx => switch (this) {
        InvoicePaper.mm58 => 384,
        InvoicePaper.mm80 => 576,
        InvoicePaper.a4 => 1240, // A4 at 150 dpi
      };

  /// PDF page width in points (1 pt = 1/72 in).
  double get pageWidthPt => switch (this) {
        InvoicePaper.mm58 => 58 / 25.4 * 72,
        InvoicePaper.mm80 => 80 / 25.4 * 72,
        InvoicePaper.a4 => 595.28,
      };

  /// The printed (dot) width inside the page, in points.
  double get printWidthPt => switch (this) {
        InvoicePaper.mm58 => 48 / 25.4 * 72,
        InvoicePaper.mm80 => 72 / 25.4 * 72,
        InvoicePaper.a4 => 595.28,
      };

  static InvoicePaper parse(String? s) => switch (s) {
        '58' => InvoicePaper.mm58,
        'a4' => InvoicePaper.a4,
        _ => InvoicePaper.mm80,
      };
}

const invoiceTemplates = <String>[
  'cafe', 'restaurant', 'fine_dining', 'ecommerce', 'retail', 'electronics',
  'lawyer', 'vat_invoice', 'tax_consultant', 'service',
];

/// invdesign: the templates the classic (flag-off) picker offers — the new
/// Mushak-6.3 layout appears only with the `invoice_designs` switch.
const classicTemplates = <String>[
  'cafe', 'restaurant', 'fine_dining', 'ecommerce', 'retail', 'electronics',
  'lawyer', 'tax_consultant', 'service',
];

/// invdesign: print-safe A4 accents (keys mirror invoice_calc.ACCENTS).
const invoiceAccents = <String>[
  'brand', 'teal', 'green', 'maroon', 'navy', 'charcoal', 'plum', 'brown',
];
const serviceTemplates = <String>['lawyer', 'tax_consultant', 'service'];
const foodTemplates = <String>['cafe', 'restaurant', 'fine_dining'];

/// Extra fields each template prints (mirrors invoice_calc.TEMPLATE_FIELDS).
const templateFields = <String, List<String>>{
  'cafe': ['table', 'token'],
  'restaurant': ['table', 'server', 'guests'],
  'fine_dining': ['table', 'server', 'guests'],
  'ecommerce': ['order_ref', 'delivery_address', 'courier', 'tracking'],
  'retail': [],
  'electronics': ['serial', 'warranty'],
  'lawyer': ['matter', 'case_ref', 'court', 'fee_basis', 'period'],
  'vat_invoice': ['destination', 'vehicle'],
  'tax_consultant': ['tax_year', 'tin', 'period'],
  'service': ['period'],
};

int _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
String _s(Object? v) => v == null ? '' : '$v';
Map<String, dynamic> _m(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

class InvoiceLine {
  final String desc;
  final int qty;
  final int unit;
  final int amount;
  /// Fractional quantity in hundredths (1.5 hours = 150); null = whole [qty].
  final int? qtyC;
  /// Serial / IMEI the seller typed for this line ('' = none).
  final String serial;
  /// Warranty in months (0 = none).
  final int warrantyM;
  const InvoiceLine(this.desc, this.qty, this.unit, this.amount,
      {this.qtyC, this.serial = '', this.warrantyM = 0});

  /// "2" / "1.5" (bn digits when [lang] is bn).
  String qtyText(String lang) {
    final c = qtyC;
    if (c == null) return localDigits('$qty', lang);
    final whole = c ~/ 100, frac = c % 100;
    final f = frac.toString().padLeft(2, '0').replaceAll(RegExp(r'0$'), '');
    return localDigits(frac == 0 ? '$whole' : '$whole.$f', lang);
  }
}

/// [d] + [months], clamped to the month's last day (31 Jan + 1 = 28/29 Feb).
DateTime addMonths(DateTime d, int months) {
  final m0 = d.month - 1 + months;
  final y = d.year + (m0 ~/ 12);
  final m = m0 % 12 + 1;
  final last = DateTime(y, m + 1, 0).day;
  return DateTime(y, m, d.day > last ? last : d.day);
}

/// Mushak-6.3 per-line split: the invoice-level taxable value, SD and VAT
/// spread over the lines in proportion to each line's amount (largest
/// remainder), so every column sums EXACTLY to the server's totals.
class LineTax {
  final int value, sd, vat;
  const LineTax(this.value, this.sd, this.vat);
  int get total => value + sd + vat;
}

List<int> _spread(int total, List<int> weights) {
  final sum = weights.fold<int>(0, (a, b) => a + b);
  if (weights.isEmpty) return const [];
  if (sum <= 0) return [total, for (var i = 1; i < weights.length; i++) 0];
  final out = <int>[];
  final rem = <(int, int)>[];
  var used = 0;
  for (var i = 0; i < weights.length; i++) {
    final num = total * weights[i];
    final q = num ~/ sum;
    out.add(q);
    used += q;
    rem.add((num % sum, i));
  }
  rem.sort((a, b) => b.$1 != a.$1 ? b.$1.compareTo(a.$1) : a.$2.compareTo(b.$2));
  for (var k = 0; k < total - used; k++) {
    out[rem[k % rem.length].$2] += 1;
  }
  return out;
}

List<LineTax> allocateLineTax(List<InvoiceLine> lines, InvoiceCalc c) {
  final w = [for (final l in lines) l.amount < 0 ? 0 : l.amount];
  final v = _spread(c.taxable, w), s = _spread(c.sd, w), t = _spread(c.vat, w);
  return [for (var i = 0; i < lines.length; i++) LineTax(v[i], s[i], t[i])];
}

class InvoiceParty {
  final String name, phone, address, bin;
  const InvoiceParty(
      {this.name = '', this.phone = '', this.address = '', this.bin = ''});
  bool get isEmpty => name.isEmpty && phone.isEmpty && address.isEmpty;
  factory InvoiceParty.from(Object? raw) {
    final m = _m(raw);
    return InvoiceParty(
        name: _s(m['name']),
        phone: _s(m['phone']),
        address: _s(m['address']),
        bin: _s(m['bin']));
  }
}

class InvoiceSeller {
  final String name, address, phone, bin, signatory, footer;
  const InvoiceSeller(
      {this.name = '',
      this.address = '',
      this.phone = '',
      this.bin = '',
      this.signatory = '',
      this.footer = ''});
  factory InvoiceSeller.from(Object? raw) {
    final m = _m(raw);
    return InvoiceSeller(
        name: _s(m['name']),
        address: _s(m['address']),
        phone: _s(m['phone']),
        bin: _s(m['bin']),
        signatory: _s(m['signatory']),
        footer: _s(m['footer']));
  }
}

class InvoiceCalc {
  final int subtotal, discount, service, serviceBp, taxable, sd, sdBp, vat, vatBp, total;
  final int shipping; // delivery charge, added after tax
  final String vatMode; // none | exclusive | inclusive
  const InvoiceCalc({
    this.subtotal = 0,
    this.discount = 0,
    this.service = 0,
    this.serviceBp = 0,
    this.taxable = 0,
    this.sd = 0,
    this.sdBp = 0,
    this.vat = 0,
    this.vatBp = 0,
    this.total = 0,
    this.vatMode = 'none',
    this.shipping = 0,
  });
  bool get hasTax => vatMode != 'none';
  factory InvoiceCalc.from(Object? raw) {
    final m = _m(raw);
    return InvoiceCalc(
      subtotal: _i(m['subtotal']),
      discount: _i(m['discount']),
      service: _i(m['service']),
      serviceBp: _i(m['service_bp']),
      taxable: _i(m['taxable']),
      sd: _i(m['sd']),
      sdBp: _i(m['sd_bp']),
      vat: _i(m['vat']),
      vatBp: _i(m['vat_bp']),
      total: _i(m['total']),
      shipping: _i(m['shipping']),
      vatMode: _s(m['vat_mode']).isEmpty ? 'none' : _s(m['vat_mode']),
    );
  }
}

class InvoiceDoc {
  final String kind; // sale | manual
  final int id;
  final String number;
  final DateTime? issuedAt; // business-local wall time
  final String template;
  final InvoiceSeller seller;
  final InvoiceParty buyer;
  final Map<String, String> extras;
  final List<InvoiceLine> lines;
  final InvoiceCalc calc;
  final int paid, change, due;
  final String paymentMethod;
  final bool cancelled;
  final String cancelReason;
  final bool consistent;
  final String verifyUrl;
  final String paymentLink;
  final String note;
  final bool byHours; // service lines are hours x rate

  const InvoiceDoc({
    this.kind = 'sale',
    this.id = 0,
    this.number = '',
    this.issuedAt,
    this.template = 'retail',
    this.seller = const InvoiceSeller(),
    this.buyer = const InvoiceParty(),
    this.extras = const {},
    this.lines = const [],
    this.calc = const InvoiceCalc(),
    this.paid = 0,
    this.change = 0,
    this.due = 0,
    this.paymentMethod = '',
    this.cancelled = false,
    this.cancelReason = '',
    this.consistent = true,
    this.verifyUrl = '',
    this.paymentLink = '',
    this.note = '',
    this.byHours = false,
  });

  bool get isService => serviceTemplates.contains(template);

  /// The same invoice drawn with another design (the owner switches the
  /// template on the preview; facts and money never change).
  InvoiceDoc withTemplate(String t) => InvoiceDoc(
        kind: kind,
        id: id,
        number: number,
        issuedAt: issuedAt,
        template: invoiceTemplates.contains(t) ? t : template,
        seller: seller,
        buyer: buyer,
        extras: extras,
        lines: lines,
        calc: calc,
        paid: paid,
        change: change,
        due: due,
        paymentMethod: paymentMethod,
        cancelled: cancelled,
        cancelReason: cancelReason,
        consistent: consistent,
        verifyUrl: verifyUrl,
        paymentLink: paymentLink,
        note: note,
        byHours: byHours,
      );

  factory InvoiceDoc.fromJson(Map<String, dynamic> j) {
    final at = DateTime.tryParse(_s(j['issued_at']));
    return InvoiceDoc(
      kind: _s(j['kind']).isEmpty ? 'sale' : _s(j['kind']),
      id: _i(j['id']),
      number: _s(j['number']),
      // keep the BUSINESS-local wall time the server wrote (+06:00): drop the
      // offset instead of converting to the phone's zone
      issuedAt: at == null
          ? null
          : DateTime(at.year, at.month, at.day, _wallHour(j['issued_at'], at),
              _wallMinute(j['issued_at'], at)),
      template: invoiceTemplates.contains(j['template'])
          ? j['template'] as String
          : 'retail',
      seller: InvoiceSeller.from(j['seller']),
      buyer: InvoiceParty.from(j['buyer']),
      extras: {
        for (final e in _m(j['extras']).entries)
          if (_s(e.value).trim().isNotEmpty) e.key: _s(e.value).trim()
      },
      lines: [
        for (final l in (j['lines'] is List ? j['lines'] as List : const []))
          InvoiceLine(_s(_m(l)['desc']), _i(_m(l)['qty']), _i(_m(l)['unit']),
              _m(l).containsKey('amount')
                  ? _i(_m(l)['amount'])
                  : _i(_m(l)['qty']) * _i(_m(l)['unit']),
              qtyC: _m(l)['qty_c'] == null ? null : _i(_m(l)['qty_c']),
              serial: _s(_m(l)['serial']).trim(),
              warrantyM: _i(_m(l)['warranty_m'])),
      ],
      calc: InvoiceCalc.from(j['calc']),
      paid: _i(j['paid']),
      change: _i(j['change']),
      due: _i(j['due']),
      paymentMethod: _s(j['payment_method']),
      cancelled: j['cancelled'] == true,
      cancelReason: _s(j['cancel_reason']),
      consistent: j['consistent'] != false,
      verifyUrl: _s(j['verify_url']),
      paymentLink: _s(j['payment_link']),
      note: _s(j['note']),
      byHours: j['by_hours'] == true,
    );
  }
}

// "2026-11-02T14:05:00+06:00" → 14 / 5 exactly as written (wall time).
int _wallHour(Object? raw, DateTime parsed) {
  final m = RegExp(r'T(\d{2}):(\d{2})').firstMatch(_s(raw));
  return m == null ? parsed.hour : int.parse(m.group(1)!);
}

int _wallMinute(Object? raw, DateTime parsed) {
  final m = RegExp(r'T(\d{2}):(\d{2})').firstMatch(_s(raw));
  return m == null ? parsed.minute : int.parse(m.group(2)!);
}

/// "৳1,234.50" (bn: Bangla digits). Always two decimals on paper.
String invMoney(int poisha, String lang) {
  final neg = poisha < 0;
  final p = poisha.abs();
  final whole = (p ~/ 100).toString();
  final b = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) b.write(',');
    b.write(whole[i]);
  }
  final s = '${neg ? '-' : ''}৳$b.${(p % 100).toString().padLeft(2, '0')}';
  return localDigits(s, lang);
}

/// Basis points → "15%" / "7.5%" (bn digits).
String invRate(int bp, String lang) {
  final whole = bp ~/ 100, frac = bp % 100;
  var s = frac == 0
      ? '$whole'
      : '$whole.${frac.toString().padLeft(2, '0').replaceAll(RegExp(r'0$'), '')}';
  s = '$s%';
  return localDigits(s, lang);
}

String invNum(Object n, String lang) => localDigits('$n', lang);

/// "02/11/2026" and "14:05" (bn digits).
String invDate(DateTime d, String lang) => localDigits(
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}',
    lang);
String invTime(DateTime d, String lang) => localDigits(
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}',
    lang);

/// The QR codes this paper carries, in print order: the server-signed CHECK
/// link (anyone can confirm the paper is genuine) and the business's own
/// PAYMENT link when there is money still to pay. Never invented.
class InvoiceQr {
  final String kind; // verify | pay
  final String data;
  const InvoiceQr(this.kind, this.data);
}

List<InvoiceQr> invoiceQrs(InvoiceDoc d) => [
      if (d.verifyUrl.startsWith('https://') || d.verifyUrl.startsWith('http://'))
        InvoiceQr('verify', d.verifyUrl),
      if (!d.cancelled && d.due > 0 && d.paymentLink.startsWith('https://'))
        InvoiceQr('pay', d.paymentLink),
    ];
