// ledger100 — khata fakes in the SERVER's real response shape
// (backend/core/business_views.py after ledger100: balance_poisha /
// balance_display / balance_status, statement `lines`, per-customer
// tagada `reminders`, schedules + `awaiting`). The old fakes used keys the
// server never sent (`rows`, `reminders` on GET schedule…), which is how
// the blank-balance bug hid from every screenshot.

Map<String, String> _pr(String bn, String en) => {'bn': bn, 'en': en};

String _tk(int poisha, bool bn) {
  final s = '৳${poisha ~/ 100}.${(poisha % 100).toString().padLeft(2, '0')}';
  if (!bn) return s;
  const d = '০১২৩৪৫৬৭৮৯';
  return s.split('').map((c) {
    final i = '0123456789'.indexOf(c);
    return i < 0 ? c : d[i];
  }).join();
}

Map<String, String> fmtPair(int poisha) =>
    {'bn': _tk(poisha, true), 'en': _tk(poisha, false)};

List<Map<String, dynamic>> fakeKhataParties(String book, bool bn) {
  Map<String, dynamic> row(int id, String nbn, String nen, String phone,
          int bal, {bool vip = false}) =>
      {
        'id': id,
        'name': bn ? nbn : nen,
        'phone': phone,
        'area': '',
        'vip': vip,
        'book': book,
        'phone_ok': phone.isNotEmpty,
        'balance': bal,
        'balance_poisha': bal,
        'balance_fmt': fmtPair(bal),
        'balance_display': fmtPair(bal),
        'status': bal > 0 ? _pr('বাকি', 'Due') : _pr('পরিশোধিত', 'Settled'),
        'balance_status':
            bal > 0 ? _pr('বাকি', 'Due') : _pr('পরিশোধিত', 'Settled'),
      };
  return [
    row(1, 'করিম স্টোর', 'Karim Store', '01712345678', 150000, vip: true),
    row(2, 'রহিম ট্রেডার্স', 'Rahim Traders', '01812345678', 0),
    row(3, 'সালমা বেগম', 'Salma Begum', '', 25000),
  ];
}

Map<String, dynamic> fakeKhataStatement(int id, bool empty, bool bn) {
  final bal = empty ? 0 : 150000;
  return {
    'book': 'customer',
    'party_id': id,
    'balance': bal,
    'balance_poisha': bal,
    'balance_display': fmtPair(bal),
    'balance_status': bal > 0 ? _pr('বাকি', 'Due') : _pr('পরিশোধিত', 'Settled'),
    'lines': empty
        ? const []
        : [
            {
              'entry_id': 12, 'version': 1, 'editable': true, 'amount': 50000,
              'note': '', 'at': '2026-10-10T12:00:00+06:00',
              'at_display': _pr('১০ অক্টো ২০২৬', '10 Oct 2026'),
              'particulars': _pr('টাকা পেলাম', 'Payment received'),
              'debit_display': _pr('', ''), 'credit_display': fmtPair(50000),
              'balance_display': fmtPair(150000),
            },
            {
              'entry_id': 11, 'version': 1, 'editable': false, 'amount': 200000,
              'note': '[sale#5]', 'at': '2026-10-01T12:00:00+06:00',
              'at_display': _pr('১ অক্টো ২০২৬', '1 Oct 2026'),
              'particulars': _pr('বাকি দিলাম — বিক্রি', 'Gave on credit — sale'),
              'debit_display': fmtPair(200000), 'credit_display': _pr('', ''),
              'balance_display': fmtPair(200000),
            },
          ],
  };
}

Map<String, dynamic> fakeKhataSms({bool ready = true, int balance = 40}) => {
      'ready': ready,
      'available': ready,
      'owner_only': false,
      'balance': balance,
      'per_segment': 1,
    };

Map<String, dynamic> fakeReminder(Map<String, dynamic> p, bool bn,
    {String shop = 'Rahim Store'}) {
  final bal = (p['balance_poisha'] as num).toInt();
  final name = '${p['name']}';
  final amount = _tk(bal, bn);
  final msg = bn
      ? 'আসসালামু আলাইকুম $name। $shop-এ আপনার বাকি $amount। সুবিধামতো পরিশোধ করলে কৃতজ্ঞ থাকব।'
      : 'Hello $name. Your due at $shop is $amount. Kindly clear it at your convenience, thank you.';
  final phone = '${p['phone']}';
  final m = phone.isEmpty ? '' : '88$phone';
  return {
    'party_id': p['id'], 'name': name, 'phone': phone,
    'phone_ok': phone.isNotEmpty, 'balance_poisha': bal,
    'balance_display': fmtPair(bal), 'message': msg,
    'wa_url': m.isEmpty ? '' : 'https://wa.me/$m?text=${Uri.encodeComponent(msg)}',
    'sms_uri': m.isEmpty ? '' : 'sms:+$m?body=${Uri.encodeComponent(msg)}',
    'sms_segments': 2, 'sms_credits': 2,
  };
}

/// GET stubs; null when [bare] is not a khata path.
Map<String, dynamic>? fakeKhataGet(String bare, String query,
    {required bool bn, required bool empty}) {
  if (bare == 'business/khata/parties') {
    final book = Uri.splitQueryString(query)['book'] ?? 'customer';
    return {
      'parties': empty ? const [] : fakeKhataParties(book, bn),
      'role': 'owner',
      'free': true,
    };
  }
  if (bare == 'business/khata/net-position') {
    return {
      'receivable': 175000, 'receivable_display': fmtPair(175000),
      'payable': 0, 'payable_display': fmtPair(0),
      'net_display': fmtPair(175000), 'due_customers': 2, 'ahead': true,
    };
  }
  final m = RegExp(r'^business/khata/parties/(\d+)/statement$').firstMatch(bare);
  if (m != null) return fakeKhataStatement(int.parse(m.group(1)!), empty, bn);
  if (bare == 'business/khata/tagada/schedule') {
    final rows = empty
        ? const <Map<String, dynamic>>[]
        : [
            {
              'id': 7, 'party': 1, 'party_id': 1,
              'party_name': bn ? 'করিম স্টোর' : 'Karim Store',
              'mode': 'push', 'channel': 'push', 'preset': 'reminder',
              'next_at': '2026-10-30T04:00:00+00:00', 'interval_days': 7,
              'until_paid': true, 'enabled': true, 'awaiting_owner': true,
              'last_result': 'push', 'balance_poisha': 150000,
              'balance_display': fmtPair(150000),
            }
          ];
    final party = Uri.splitQueryString(query)['party'];
    final list = party == null
        ? rows
        : rows.where((r) => '${r['party_id']}' == party).toList();
    return {
      'schedules': list,
      'awaiting': [for (final r in list) if (r['awaiting_owner'] == true) r],
      'sms': fakeKhataSms(),
    };
  }
  return null;
}

/// POST stubs; null when not a khata path.
Map<String, dynamic>? fakeKhataPost(String p, Map<String, dynamic> body,
    {required bool bn}) {
  if (p == 'business/khata/tagada/bulk') {
    final ids = ((body['party_ids'] ?? const []) as List).map((e) => '$e').toSet();
    final all = fakeKhataParties('customer', bn);
    final picked = ids.isEmpty ? all : all.where((x) => ids.contains('${x['id']}')).toList();
    return {
      'reminders': [
        for (final x in picked)
          if ((x['balance_poisha'] as int) > 0) fakeReminder(x, bn)
      ],
      'skipped': [
        for (final x in picked)
          if ((x['balance_poisha'] as int) <= 0)
            {'party_id': x['id'], 'name': x['name'], 'reason': 'no_due'}
      ],
      'sms': fakeKhataSms(),
    };
  }
  if (RegExp(r'^business/khata/parties/\d+/(entries|payment)$').hasMatch(p)) {
    return {
      'entry_id': 99, 'id': 99, 'client_id': body['client_id'] ?? '',
      'version': 1, 'duplicate': false,
      'balance_poisha': 150000, 'balance_display': fmtPair(150000),
      'balance_status': _pr('বাকি', 'Due'),
      if (body['notify_customer'] == true)
        'entry_added_message': _pr('করিম স্টোর, আপনার খাতায় বাকি যোগ হলো।',
            'Karim Store, a due was added to your khata.'),
    };
  }
  if (RegExp(r'^business/khata/entries/\d+$').hasMatch(p)) {
    return {'entry_id': 12, 'version': ((body['base_version'] as int?) ?? 1) + 1,
            'balance_poisha': 150000, 'balance_display': fmtPair(150000)};
  }
  if (p == 'business/khata/tagada/schedule') {
    return {'id': 7, 'party_id': body['party'], 'mode': body['channel'],
            'interval_days': body['interval_days'], 'enabled': true};
  }
  if (RegExp(r'^business/khata/tagada/schedule/\d+$').hasMatch(p)) {
    return {'id': 7, 'awaiting_owner': false};
  }
  if (RegExp(r'^business/khata/tagada/sms/\d+$').hasMatch(p)) {
    return {'ok': true, 'segments': 2, 'credits': 2, 'balance': 38, '_status': 200};
  }
  return null;
}
