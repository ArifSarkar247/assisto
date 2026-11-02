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
      },
      'saved': saved,
      'can_edit': true,
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
        'tin': '123456789012',
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
