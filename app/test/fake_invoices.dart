// invoices — fake server answers for the invoice screens (tests + gallery).
// Shapes match core/invoice_views.py exactly.

const fakeInvoiceVerifyUrl = 'https://lifeassisto.com/r/s41.Zx3kQ1n0Ff8Wb2mYtR4uVq9sLpA';

Map<String, dynamic> fakeInvoiceSettings({bool saved = true, bool vat = true}) => {
      'settings': {
        'template': 'restaurant',
        'name': 'Kacchi Ghor',
        'address': 'House 7, Road 12, Dhanmondi, Dhaka',
        'phone': '01712345678',
        'bin': vat ? '000123456-0101' : '',
        'signatory': 'Rahim Uddin, Manager',
        'payment_link': 'https://shop.bkash.com/kacchi-ghor',
        'footer': 'Open 11am to 11pm',
        'vat_mode': vat ? 'inclusive' : 'none',
        'vat_bp': 1500,
        'sd_bp': 0,
        'service_bp': 500,
        'verify_qr': true,
        'size': '80',
        'lang': 'bn',
        'accent': 'teal',
        'logo': '',
      },
      'saved': saved,
      'can_edit': true,
      'suggested_template': 'restaurant',
      'accents': const ['brand', 'teal', 'green', 'maroon', 'navy', 'charcoal', 'plum', 'brown'],
    };

Map<String, dynamic> fakeSaleInvoice({String template = 'restaurant', bool vat = true,
        bool cancelled = false, int due = 0, int lines = 3}) =>
    {
      'kind': 'sale',
      'id': 41,
      'number': 'S-0041',
      'issued_at': '2026-11-02T14:05:00+06:00',
      'template': template,
      'seller': {
        'name': 'Kacchi Ghor',
        'address': 'Dhanmondi, Dhaka',
        'phone': '01712345678',
        'bin': vat ? '000123456-0101' : '',
        'signatory': 'Rahim Uddin, Manager',
        'payment_link': 'https://shop.bkash.com/kacchi-ghor',
        'footer': 'Open every day',
      },
      'buyer': {'name': 'Karim Mia', 'phone': '01811111111', 'address': 'Mirpur', 'bin': ''},
      'extras': {
        'table': '7', 'server': 'Jamal', 'guests': '4', 'token': '22',
        'order_ref': 'FB-1043', 'delivery_address': 'Uttara Sector 4', 'courier': 'Pathao',
        'serial': '356789104512345', 'warranty': '12 months', 'case_ref': 'CR-221/2026',
        'court': 'Dhaka Judge Court', 'period': 'October 2026', 'tax_year': '2026-27',
        'tin': '123456789012', 'tracking': 'DT021125ABC7', 'matter': 'Rahman vs. Karim',
        'fee_basis': 'Per hearing', 'destination': 'Motijheel, Dhaka',
        'vehicle': 'Covered van',
      },
      'lines': [
        for (var i = 0; i < lines; i++)
          {'desc': const ['Kacchi biryani (full)', 'Borhani', 'Firni'][i % 3],
           'qty': 1 + i % 2, 'unit': 45000 - (i % 3) * 10000,
           'amount': (1 + i % 2) * (45000 - (i % 3) * 10000)},
      ],
      'calc': vat
          ? {'subtotal': 115000, 'discount': 0, 'service': 0, 'service_bp': 0,
             'taxable': 100000, 'sd': 0, 'sd_bp': 0, 'vat': 15000, 'vat_bp': 1500,
             'total': 115000, 'vat_mode': 'inclusive'}
          : {'subtotal': 115000, 'discount': 5000, 'service': 0, 'service_bp': 0,
             'taxable': 110000, 'sd': 0, 'sd_bp': 0, 'vat': 0, 'vat_bp': 0,
             'total': 110000, 'vat_mode': 'none'},
      'paid': vat ? 120000 : 110000 - due,
      'change': vat ? 5000 : 0,
      'due': due,
      'payment_method': 'cash',
      'cancelled': cancelled,
      'cancel_reason': cancelled ? 'Wrong table' : '',
      'consistent': true,
      'verify_url': fakeInvoiceVerifyUrl,
      'payment_link': 'https://shop.bkash.com/kacchi-ghor',
    };

Map<String, dynamic>? fakeInvoiceGet(String path, {bool empty = false}) {
  final p = path.split('?').first;
  if (p == '/business/invoice/settings') return fakeInvoiceSettings(saved: !empty);
  if (p == '/business/invoices/sales') {
    return {
      'items': empty
          ? const []
          : [
              {'id': 41, 'total': 115000, 'issued_at': '2026-11-02T14:05:00+06:00',
               'buyer': 'Karim Mia', 'payment_method': 'cash', 'cancelled': false},
              {'id': 40, 'total': 32000, 'issued_at': '2026-11-02T12:40:00+06:00',
               'buyer': '', 'payment_method': 'bkash', 'cancelled': true},
            ]
    };
  }
  if (p == '/business/invoices') {
    return {
      'items': empty
          ? const []
          : [
              {'id': 5, 'number': 'SV-0003', 'issued_at': '2026-11-01T18:20:00+06:00',
               'buyer': 'ABC Traders Ltd', 'total': 1150000, 'template': 'tax_consultant',
               'cancelled': false},
            ]
    };
  }
  if (RegExp(r'^/business/sales/\d+/invoice$').hasMatch(p)) return fakeSaleInvoice();
  if (RegExp(r'^/business/invoices/\d+$').hasMatch(p)) {
    return {...fakeSaleInvoice(template: 'lawyer'), 'kind': 'manual', 'id': 5, 'number': 'SV-0003'};
  }
  return null;
}


/// invdesign: one realistic paper per business type (sums are exact, as the
/// server would compute them in invoice_calc.compute).
Map<String, dynamic> fakeDesignInvoice(String template) {
  final base = fakeSaleInvoice(template: template);
  Map<String, dynamic> none(int subtotal, {int shipping = 0, int discount = 0}) => {
        'subtotal': subtotal, 'discount': discount, 'service': 0, 'service_bp': 0,
        'taxable': subtotal - discount, 'sd': 0, 'sd_bp': 0, 'vat': 0, 'vat_bp': 0,
        'shipping': shipping, 'total': subtotal - discount + shipping, 'vat_mode': 'none',
      };
  Map<String, dynamic> l(String d, int q, int u, {String serial = '', int w = 0, int? qc}) => {
        'desc': d, 'qty': q, 'unit': u,
        'amount': qc == null ? q * u : (qc * u + 50) ~/ 100,
        if (qc != null) 'qty_c': qc,
        if (serial.isNotEmpty) 'serial': serial,
        if (w > 0) 'warranty_m': w,
      };
  switch (template) {
    case 'cafe':
      return {
        ...base,
        'seller': {...base['seller'] as Map, 'name': 'Brew & Bean', 'bin': ''},
        'buyer': const {},
        'extras': {'table': '3', 'token': '47'},
        'lines': [l('Cappuccino', 2, 22000), l('Chicken sandwich', 1, 35000)],
        'calc': none(79000), 'paid': 80000, 'change': 1000, 'due': 0,
      };
    case 'electronics':
      return {
        ...base,
        'seller': {...base['seller'] as Map, 'name': 'Gadget Point'},
        'extras': const {},
        'lines': [
          l('Samsung Galaxy A15 (Black)', 1, 2299900, serial: '356938035643809', w: 12),
          l('Fast charger 25W', 1, 150000, w: 6),
        ],
        'calc': {'subtotal': 2449900, 'discount': 0, 'service': 0, 'service_bp': 0,
                 'taxable': 2130348, 'sd': 0, 'sd_bp': 0, 'vat': 319552, 'vat_bp': 1500,
                 'shipping': 0, 'total': 2449900, 'vat_mode': 'inclusive'},
        'paid': 2449900, 'change': 0, 'due': 0, 'payment_method': 'bkash',
      };
    case 'ecommerce':
      return {
        ...base,
        'seller': {...base['seller'] as Map, 'name': 'Deshi Fashion House', 'bin': ''},
        'buyer': {'name': 'Nusrat Jahan', 'phone': '01911222333', 'address': '', 'bin': ''},
        'extras': {
          'order_ref': '#1043',
          'delivery_address': 'House 12, Road 3, Sector 7, Uttara, Dhaka',
          'courier': 'Pathao', 'tracking': 'DT021125ABC7',
        },
        'lines': [l('Cotton panjabi (L / White)', 1, 185000), l('Attar 6 ml', 2, 25000)],
        'calc': none(235000, shipping: 12000), 'paid': 0, 'change': 0, 'due': 247000,
        'payment_method': '',
      };
    case 'lawyer':
      return {
        ...base, 'kind': 'manual', 'number': 'SV-0012',
        'seller': {...base['seller'] as Map, 'name': 'Adv. Farhana Akter & Associates',
                   'bin': '', 'signatory': 'Farhana Akter, Advocate'},
        'buyer': {'name': 'Abdur Rahman', 'phone': '01711000222', 'address': 'Mohammadpur, Dhaka', 'bin': ''},
        'extras': {
          'matter': 'Rahman vs. Karim (land dispute)', 'case_ref': 'Title Suit 221/2026',
          'court': 'Joint District Judge Court, Dhaka', 'fee_basis': 'Per hearing + drafting',
        },
        'lines': [l('Drafting written statement', 1, 1500000),
                  l('Court appearance (hearings)', 2, 500000)],
        'calc': none(2500000), 'paid': 1000000, 'change': 0, 'due': 1500000,
        'payment_method': 'bank',
      };
    case 'vat_invoice':
      return {
        ...base, 'kind': 'manual', 'number': 'SV-0031',
        'seller': {...base['seller'] as Map, 'name': 'Rupa Furniture Ltd'},
        'buyer': {'name': 'ABC Traders Ltd', 'phone': '', 'address': 'Motijheel C/A, Dhaka',
                  'bin': '004567891-0203'},
        'extras': {'destination': 'Motijheel, Dhaka', 'vehicle': 'Covered van'},
        'lines': [l('Office chair (ergonomic)', 4, 650000), l('Steel file cabinet', 1, 1200000)],
        'calc': {'subtotal': 3800000, 'discount': 0, 'service': 0, 'service_bp': 0,
                 'taxable': 3800000, 'sd': 0, 'sd_bp': 0, 'vat': 570000, 'vat_bp': 1500,
                 'shipping': 0, 'total': 4370000, 'vat_mode': 'exclusive'},
        'paid': 4370000, 'change': 0, 'due': 0, 'payment_method': 'bank',
      };
    case 'service':
      return {
        ...base, 'kind': 'manual', 'number': 'SV-0007', 'by_hours': true,
        'seller': {...base['seller'] as Map, 'name': 'Pixel Studio', 'bin': ''},
        'buyer': {'name': 'Green Grocers', 'phone': '01811999000', 'address': 'Banani, Dhaka', 'bin': ''},
        'extras': {'period': 'October 2026'},
        'lines': [l('Website maintenance', 3, 150000, qc: 250),
                  l('Logo revisions', 2, 120000, qc: 150)],
        'calc': none(555000), 'paid': 0, 'change': 0, 'due': 555000, 'payment_method': '',
      };
    default:
      return base;
  }
}
