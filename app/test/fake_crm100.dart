// crm100 — canned server answers for the one-customer history page, the
// merged customer list, shop quotes and send-from-CRM (tests + gallery).
// Shapes mirror backend crm/views_crm100.py exactly. No real person.

Map<String, dynamic> crm100Summary({bool empty = false}) => empty
    ? {
        'name': '', 'phone': '01811111111', 'phone_key': '01811111111', 'sources': [],
        'khata_due_poisha': 0, 'khata_parties': [], 'orders_count': 0, 'orders_open': 0,
        'orders_cod_to_collect_poisha': 0, 'orders_returned': 0,
        'orders_payment_to_check': 0, 'sales_count': 0, 'sales_total_poisha': 0,
        'sales_due_poisha': 0, 'chats_count': 0, 'last_chat_at': null, 'leads': [],
        'deals_open': 0, 'tasks_open': 0, 'quotes_open': 0, 'last_contact_at': null,
        'opted_out': false, 'role': 'owner', 'has_business': true, 'has_crm': true,
      }
    : {
        'name': 'Karim Mia', 'phone': '01712345678', 'phone_key': '01712345678',
        'sources': ['khata', 'sale', 'order', 'chat', 'crm'],
        'khata_due_poisha': 85000, 'khata_parties': [1], 'orders_count': 3,
        'orders_open': 1, 'orders_cod_to_collect_poisha': 180000, 'orders_returned': 1,
        'orders_payment_to_check': 1, 'sales_count': 2, 'sales_total_poisha': 420000,
        'sales_due_poisha': 0, 'chats_count': 1, 'last_chat_at': '2026-10-26T10:00:00+06:00',
        'leads': [
          {'id': 7, 'org': 1, 'name': 'Karim Mia', 'status': 'contacted', 'score': 60}
        ],
        'deals_open': 1, 'tasks_open': 1, 'quotes_open': 1,
        'last_contact_at': '2026-10-27T18:00:00+06:00', 'opted_out': false,
        'role': 'owner', 'has_business': true, 'has_crm': true,
      };

List<Map<String, dynamic>> crm100Items() => [
      {'kind': 'message', 'at': '2026-10-27T18:00:00+06:00', 'channel': 'whatsapp_link',
       'status': 'opened', 'reason': '', 'purpose': 'tagada', 'text': 'Karim, ৳850 due',
       'credits': 0, 'ref': {'type': 'message', 'id': 3}, 'id': 'm3'},
      {'kind': 'quote', 'at': '2026-10-27T12:00:00+06:00', 'state': 'viewed',
       'amount_poisha': 300000, 'items': 1, 'order': null,
       'valid_until': '2026-10-30T12:00:00+06:00', 'ref': {'type': 'quote', 'id': 5},
       'id': 'q5'},
      {'kind': 'chat', 'at': '2026-10-26T10:00:00+06:00', 'channel': 'messenger',
       'messages': 6, 'last_text': 'Red saree available?', 'last_dir': 'in',
       'last_ai': false, 'opted_out': false, 'ref': {'type': 'thread', 'id': 9}, 'id': 'c9'},
      {'kind': 'order', 'at': '2026-10-25T09:00:00+06:00', 'amount_poisha': 180000,
       'status': 'confirmed', 'payment': 'cod', 'payment_status': 'pending_verification',
       'channel': 'messenger', 'items': 1, 'first_item': 'Red saree',
       'ref': {'type': 'order', 'id': 41}, 'id': 'o41'},
      {'kind': 'order', 'at': '2026-10-10T09:00:00+06:00', 'amount_poisha': 250000,
       'status': 'returned', 'payment': 'cod', 'payment_status': '', 'channel': 'manual',
       'items': 2, 'first_item': 'Blue panjabi', 'ref': {'type': 'order', 'id': 30},
       'id': 'o30'},
      {'kind': 'khata', 'at': '2026-10-20T11:00:00+06:00', 'dir': 'gave',
       'amount_poisha': 150000, 'note': 'Eid shopping', 'ref': {'type': 'party', 'id': 1},
       'id': 'k2'},
      {'kind': 'khata', 'at': '2026-10-22T11:00:00+06:00', 'dir': 'got',
       'amount_poisha': 65000, 'note': '', 'ref': {'type': 'party', 'id': 1}, 'id': 'k3'},
      {'kind': 'activity', 'at': '2026-10-21T15:00:00+06:00', 'sub': 'task',
       'subject': 'Call about the blue saree', 'body': '', 'done': false, 'due_at': null,
       'ref': {'type': 'lead', 'id': 7}, 'id': 'a4'},
      {'kind': 'deal', 'at': '2026-10-21T14:00:00+06:00', 'title': 'Eid wholesale',
       'amount_poisha': 500000, 'state': 'open', 'stage': 'Talking', 'next_step': '',
       'ref': {'type': 'deal', 'id': 2}, 'id': 'd2'},
      {'kind': 'sale', 'at': '2026-10-05T19:00:00+06:00', 'amount_poisha': 220000,
       'due_poisha': 0, 'payment': 'bkash', 'voided': false,
       'ref': {'type': 'sale', 'id': 11}, 'id': 's11'},
    ];

Map<String, dynamic> crm100History({bool empty = false}) => {
      'items': empty ? <Map<String, dynamic>>[] : crm100Items(),
      'next_before': null,
      'summary': crm100Summary(empty: empty),
      'server_time': '2026-10-28T09:00:00+06:00',
    };

Map<String, dynamic> crm100Customers({bool empty = false}) => {
      'results': empty
          ? []
          : [
              {'key': '01712345678', 'phone_key': '01712345678', 'phone': '01712345678',
               'name': 'Karim Mia', 'sources': ['khata', 'order', 'chat', 'crm'],
               'due_poisha': 85000, 'orders': 3, 'last_at': '2026-10-27T18:00:00+06:00',
               'party_id': 1, 'lead_id': 7, 'lead_org': 1},
              {'key': '01811111111', 'phone_key': '01811111111', 'phone': '01811111111',
               'name': 'Rahela Begum', 'sources': ['khata'], 'due_poisha': 0, 'orders': 0,
               'last_at': '2026-10-20T10:00:00+06:00', 'party_id': 2, 'lead_id': null,
               'lead_org': null},
              {'key': '01911111111', 'phone_key': '01911111111', 'phone': '01911111111',
               'name': 'Sumon Traders', 'sources': ['crm'], 'due_poisha': 0, 'orders': 0,
               'last_at': null, 'party_id': null, 'lead_id': 8, 'lead_org': 1},
            ],
      'total': empty ? 0 : 3, 'offset': 0, 'limit': 50, 'next_offset': null,
      'has_business': true, 'has_crm': true, 'role': 'owner',
    };

Map<String, dynamic> crm100Quote({String state = 'viewed'}) => {
      'id': 5, 'state': state, 'customer_name': 'Karim Mia', 'customer_phone': '01712345678',
      'lead': null, 'lang': 'bn',
      'items': [
        {'product_id': 1, 'variant': '', 'name': 'Red saree', 'size': '', 'colour': '',
         'qty': 2, 'unit_poisha': 150000, 'list_poisha': 150000}
      ],
      'subtotal_poisha': 300000, 'discount_poisha': 0, 'delivery_poisha': 0,
      'total_poisha': 300000, 'payment': 'cod', 'note': '',
      'valid_until': '2026-10-30T12:00:00+06:00', 'created_at': '2026-10-27T12:00:00+06:00',
      'viewed_at': null, 'decided_at': null, 'decline_reason': '',
      'order': state == 'accepted' ? 52 : null,
      'path': '/q/abc.sig', 'url': 'https://lifeassisto.com/q/abc.sig',
    };

Map<String, dynamic> crm100Quotes({bool empty = false}) => {
      'results': empty
          ? []
          : [
              crm100Quote(),
              {...crm100Quote(state: 'accepted'), 'id': 4},
              {...crm100Quote(state: 'expired'), 'id': 3, 'customer_name': 'Rahela Begum'},
            ],
      'has_business': true,
    };

Map<String, dynamic> crm100Catalog() => {
      'results': [
        {'id': 1, 'name': 'Red saree', 'category': 'Saree', 'variants': [
          {'key': '', 'size': '', 'colour': '', 'sell_poisha': 150000, 'stock': 5,
           'min_poisha': 120000}
        ]},
        {'id': 2, 'name': 'Blue panjabi', 'category': 'Panjabi', 'variants': [
          {'key': 'm|blue', 'size': 'M', 'colour': 'Blue', 'sell_poisha': 120000, 'stock': 0,
           'min_poisha': 100000}
        ]},
      ],
      'has_business': true, 'role': 'owner',
    };

Map<String, dynamic> crm100Preview({String blocked = '', int balance = 40}) => {
      'name': 'Karim Mia', 'phone': '01712345678', 'known': true, 'phone_ok': true,
      'wa_url': 'https://wa.me/8801712345678?text=hi', 'sms_uri': 'sms:+8801712345678?body=hi',
      'sms': {'ready': true, 'owner_only': false, 'available': blocked.isEmpty,
              'blocked': blocked, 'balance': balance, 'text': 'Rahim Store: hi',
              'retry_at': null, 'segments': 1, 'credits': 1, 'per_segment': 1,
              'encoding': 'gsm7'},
    };

/// GET router for /crm/ crm100 paths; null = not a crm100 path.
Map<String, dynamic>? fakeCrm100Get(String path, {bool empty = false}) {
  if (path.startsWith('/crm/customers/history/')) return crm100History(empty: empty);
  if (path.startsWith('/crm/customers/')) return crm100Customers(empty: empty);
  if (path.startsWith('/crm/shop-quotes/catalog/')) return crm100Catalog();
  if (path.startsWith('/crm/shop-quotes/')) return crm100Quotes(empty: empty);
  return null;
}

/// POST router; null = not a crm100 path.
Map<String, dynamic>? fakeCrm100Post(String path, Map<String, dynamic> body) {
  if (path.startsWith('/crm/send/preview')) return crm100Preview();
  if (path.startsWith('/crm/send/log')) return {'ok': true, 'id': 1, 'status': 'opened'};
  if (path.startsWith('/crm/send/sms')) {
    return {'ok': true, 'status': 'sent', 'segments': 1, 'credits': 1, 'balance': 39};
  }
  if (path.startsWith('/crm/send/bulk')) {
    final targets = (body['targets'] as List? ?? const []);
    return {
      'bulk_id': 'b1',
      'cards': [
        for (var i = 0; i < targets.length; i++)
          {
            'name': i == 0 ? 'Karim Mia' : 'Rahela Begum',
            'phone': i == 0 ? '01712345678' : '01811111111',
            'target': targets[i],
            'text': '${i == 0 ? 'Karim Mia' : 'Rahela Begum'}, new stock has arrived.',
            'phone_ok': true,
            'wa_url': 'https://wa.me/88017$i',
            'sms_uri': 'sms:+88017$i',
            'sms': crm100Preview()['sms'],
          }
      ],
      'skipped': [],
      'truncated': false,
    };
  }
  if (path == '/crm/shop-quotes/' || path.startsWith('/crm/shop-quotes/?')) {
    return {...crm100Quote(state: 'issued'), 'warnings': []};
  }
  if (path.startsWith('/crm/shop-quotes/')) return crm100Quote();
  return null;
}
