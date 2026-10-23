// p1-bizagent: FakeApi stubs for /bizagent/* (gallery + widget tests).
// Mirrors the server shapes in backend/core/views_bizagent.py.
import 'fake_api.dart' show FakeMode;

/// Every POST the fakes received (path → body), for test assertions.
final List<MapEntry<String, Map<String, dynamic>>> p1Posts = [];

/// Gallery knob: false = the "nothing connected yet" first-run state.
bool p1Connected = true;

Map<String, dynamic> _setup(bool bn, FakeMode mode) {
  final empty = mode == FakeMode.empty || !p1Connected;
  return {
    'business': {'id': 1, 'shop_name': bn ? 'রূপা ফ্যাশন' : 'Rupa Fashion'},
    'settings': {
      'ai_enabled': !empty, 'tone': 'friendly', 'hours': empty ? {} : {'start': '10:00', 'end': '22:00'},
      'approve_all': false, 'cod_enabled': true, 'payment_link_enabled': false,
      'low_stock_alert': true, 'daily_report': true, 'default_courier': 'steadfast',
      'delivery_inside': '60', 'delivery_outside': '120', 'free_over': '',
      'returns': bn ? '৩ দিনের মধ্যে ত্রুটিপূর্ণ পণ্য বদলে দেওয়া হয়' : 'Faulty items exchanged within 3 days',
      'payment_note': '',
    },
    'channels': empty
        ? []
        : [
            {'id': 1, 'kind': 'messenger', 'external_id': '1000000000001',
             'display_name': bn ? 'রূপা ফ্যাশন পেজ' : 'Rupa Fashion Page', 'status': 'connected',
             'status_detail': '', 'enabled': true, 'test_mode': false, 'has_token': true},
            {'id': 2, 'kind': 'whatsapp_cloud', 'external_id': '2000000000002',
             'display_name': 'Rupa Fashion', 'status': 'error',
             'status_detail': '(#100) Invalid OAuth access token', 'enabled': true,
             'test_mode': false, 'has_token': true},
          ],
    'kill': {'messenger': false, 'instagram': false, 'whatsapp_cloud': false},
    'ai_kill': false,
    'catalog': {
      'products': empty ? 0 : 24, 'priced': empty ? 0 : 23, 'in_stock': empty ? 0 : 20,
      'low_stock': empty ? [] : [{'id': 3, 'name': bn ? 'জামদানি শাড়ি' : 'Jamdani saree', 'stock': 2, 'threshold': 3}],
      'missing_price': empty ? [] : [bn ? 'ওড়না' : 'Scarf'],
    },
    'couriers': {
      'pathao': {'connected': false, 'source': null},
      'steadfast': {'connected': !empty, 'source': empty ? null : 'seller'},
      'redx': {'connected': false, 'source': null},
    },
    'plan': {
      'plan': empty ? 'none' : 'trial', 'active': !empty,
      'period_end': '2026-10-30T10:00:00+06:00', 'quota': empty ? 0 : 100,
      'used': empty ? 0 : 37, 'left': empty ? 0 : 63, 'credits': 45, 'credit_replies': 15,
      'trial_available': empty, 'trial_days': 7, 'trial_replies': 100,
      'purchasable': false,
      'plans': [
        {'id': 'starter', 'price': 1490, 'replies': 1000, 'sku': 'seller_starter_monthly'},
        {'id': 'pro', 'price': 3990, 'replies': 3000, 'sku': 'seller_pro_monthly'},
      ],
    },
    'meta_ready': {'app': !empty, 'secret': !empty, 'verify_token': !empty},
    'pending_approvals': empty ? 0 : 2,
  };
}

List<Map<String, dynamic>> _approvals(bool bn) => [
      {
        'id': 11, 'direction': 'out', 'is_ai': true, 'status': 'pending_approval',
        'kind': 'text', 'risk_reason': 'unverified_number', 'send_error': '',
        'confidence': 0.9, 'created_at': '2026-10-23T11:00:00+06:00', 'thread_id': 5,
        'channel': 'messenger', 'customer_name': bn ? 'নাসরিন' : 'Nasrin',
        'customer_text': bn ? 'পাঞ্জাবির দাম কত? ছাড় আছে?' : 'How much is the panjabi? Any discount?',
        'text': bn ? 'পাঞ্জাবি আজ মাত্র ৳৯০০!' : 'The panjabi is only ৳900 today!',
        'problems': [{'type': 'money', 'value': '900'}],
      },
      {
        'id': 12, 'direction': 'out', 'is_ai': true, 'status': 'pending_approval',
        'kind': 'text', 'risk_reason': 'refund', 'send_error': '', 'confidence': 0.0,
        'created_at': '2026-10-23T11:05:00+06:00', 'thread_id': 6,
        'channel': 'whatsapp_cloud', 'customer_name': bn ? 'রহিম' : 'Rahim',
        'customer_text': bn ? 'ভুল সাইজ এসেছে, টাকা ফেরত চাই' : 'Wrong size arrived, I want a refund',
        'text': bn ? 'রিটার্ন/রিফান্ডের জন্য দোকানের একজন আপনাকে সাহায্য করবেন।' : 'For returns/refunds a team member will assist you.',
        'problems': [],
      },
    ];

Map<String, dynamic> _thread(bool bn, {bool handover = false}) => {
      'id': 5, 'channel': 'messenger', 'customer_name': bn ? 'নাসরিন' : 'Nasrin',
      'customer_phone': '', 'handover': handover,
      'last_text': bn ? 'হ্যাঁ' : 'yes', 'last_at': '2026-10-23T11:10:00+06:00',
      'pending': 0, 'in_window': true,
      'order_draft': {'product': bn ? 'সুতি পাঞ্জাবি' : 'Cotton panjabi', 'qty': 2,
                      'phone': '01XXXXXXXXX', 'address': bn ? 'মিরপুর ১০, ঢাকা' : 'Mirpur 10, Dhaka'},
    };

Map<String, dynamic>? fakeBizAgentGet(String path, bool bn, FakeMode mode) {
  if (!path.startsWith('/bizagent/')) return null;
  final p = path.split('?').first;
  if (p == '/bizagent/setup') return _setup(bn, mode);
  if (p == '/bizagent/reports') {
    return {
      'today': {'orders': 7, 'revenue': '9840', 'messages': 64, 'ai_replies': 51,
                'pending_approvals': 2,
                'low_stock': [{'id': 3, 'name': bn ? 'জামদানি শাড়ি' : 'Jamdani saree', 'stock': 2, 'threshold': 3}]},
      'history': [],
    };
  }
  if (p == '/bizagent/approvals') {
    return {'approvals': mode == FakeMode.empty ? [] : _approvals(bn)};
  }
  if (p == '/bizagent/threads') {
    return {'threads': mode == FakeMode.empty ? [] : [
      _thread(bn),
      {..._thread(bn, handover: true), 'id': 6, 'channel': 'whatsapp_cloud',
       'customer_name': bn ? 'রহিম' : 'Rahim', 'pending': 1,
       'last_text': bn ? 'টাকা ফেরত চাই' : 'I want a refund'},
    ]};
  }
  if (p.startsWith('/bizagent/threads/')) {
    return {
      'thread': _thread(bn),
      'messages': [
        {'id': 1, 'direction': 'in', 'text': bn ? 'সুতি পাঞ্জাবির দাম কত?' : 'How much is the cotton panjabi?', 'is_ai': false, 'status': 'received', 'kind': 'text', 'risk_reason': '', 'send_error': '', 'confidence': 0, 'created_at': ''},
        {'id': 2, 'direction': 'out', 'text': bn ? 'আমি দোকানের এআই সহকারী। সুতি পাঞ্জাবি: দাম ৳১২০০, স্টকে আছে। ঢাকার ভিতরে ডেলিভারি ৳৬০।' : "I'm the shop's AI assistant. Cotton panjabi: ৳1200, in stock. Delivery inside Dhaka ৳60.", 'is_ai': true, 'status': 'sent', 'kind': 'text', 'risk_reason': '', 'send_error': '', 'confidence': 0.95, 'created_at': ''},
        {'id': 3, 'direction': 'in', 'text': bn ? '২টা নিব, মিরপুর ১০' : '2 please, Mirpur 10', 'is_ai': false, 'status': 'received', 'kind': 'text', 'risk_reason': '', 'send_error': '', 'confidence': 0, 'created_at': ''},
        {'id': 4, 'direction': 'out', 'text': bn ? 'অর্ডার করতে অনুগ্রহ করে জানান: আপনার নাম, মোবাইল নম্বর।' : 'To place the order please send: your name, mobile number.', 'is_ai': true, 'status': 'sent', 'kind': 'order', 'risk_reason': '', 'send_error': '', 'confidence': 1, 'created_at': ''},
      ],
      'orders': [],
    };
  }
  if (p == '/bizagent/plan') return _setup(bn, mode)['plan'] as Map<String, dynamic>;
  return null;
}

Map<String, dynamic>? fakeBizAgentPost(String path, Map<String, dynamic> body, bool bn) {
  if (!path.startsWith('/bizagent/')) return null;
  p1Posts.add(MapEntry(path, Map<String, dynamic>.from(body)));
  if (path == '/bizagent/settings') return {'ok': true, 'settings': body};
  if (path == '/bizagent/channels') {
    return {'ok': true, 'channel': {'id': 9, 'kind': body['kind'], 'external_id': body['external_id'],
      'display_name': 'Test Page', 'status': 'connected', 'status_detail': '', 'enabled': true,
      'test_mode': false, 'has_token': true}};
  }
  if (path.endsWith('/approve')) return {'ok': true, 'status': 'ok'};
  if (path.endsWith('/reject')) return {'ok': true};
  if (path.endsWith('/handover')) return {'ok': true, 'handover': body['on'] == true};
  if (path.endsWith('/send')) {
    return {'ok': true, 'message': {'id': 99, 'direction': 'out', 'text': body['text'], 'status': 'sent'}};
  }
  if (path == '/bizagent/plan/trial') return {'plan': 'trial', 'active': true};
  return {'ok': true};
}
