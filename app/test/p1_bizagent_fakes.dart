// p1-bizagent: FakeApi stubs for /bizagent/* (gallery + widget tests).
// Mirrors the server shapes in backend/core/views_bizagent.py.
import 'fake_api.dart' show FakeMode;

/// Every POST the fakes received (path → body), for test assertions.
final List<MapEntry<String, Map<String, dynamic>>> p1Posts = [];

/// Gallery knob: false = the "nothing connected yet" first-run state.
bool p1Connected = true;

/// g1 gallery knob: is a vision provider connected on the server?
bool g1VisionReady = false;

/// sales2 knobs: thread 9's open handoff + who is replying there.
bool s2HandoffOpen = true;
bool s2Handover = false;

/// sales2: quick replies the server builds from the catalog (bn digits in bn,
/// like the real rule-layer text after the app's digit pass).
List<Map<String, dynamic>> s2QuickReplies(bool bn) => [
      {'kind': 'product', 'product_id': 1, 'name': bn ? 'সুতি পাঞ্জাবি' : 'Cotton panjabi',
       'price': bn ? '১২০০' : '1200', 'in_stock': true, 'mentioned': true,
       'text': bn
           ? 'সুতি পাঞ্জাবি — দাম ৳১২০০, স্টকে আছে। সাইজ: M, L। অর্ডার করতে নাম, মোবাইল নম্বর ও পূর্ণ ঠিকানা লিখুন।'
           : 'Cotton panjabi — ৳1200, in stock. Sizes: M, L. To order, send your name, mobile number and full address.'},
      {'kind': 'product', 'product_id': 2, 'name': bn ? 'জামদানি শাড়ি' : 'Jamdani saree',
       'price': bn ? '৪৫০০' : '4500', 'in_stock': false, 'mentioned': false,
       'text': bn
           ? 'জামদানি শাড়ি — দাম ৳৪৫০০। দুঃখিত, এটি এখন স্টকে নেই।'
           : 'Jamdani saree — ৳4500. Sorry, it is out of stock right now.'},
      {'kind': 'delivery',
       'text': bn
           ? 'ডেলিভারি চার্জ: ঢাকার ভিতরে ৳৬০, ঢাকার বাইরে ৳১২০।'
           : 'Delivery charge: inside Dhaka ৳60, outside Dhaka ৳120.'},
      {'kind': 'payment',
       'text': bn
           ? 'ক্যাশ অন ডেলিভারি — পণ্য হাতে পেয়ে টাকা দিন। কখনো কাউকে আপনার পিন বা OTP দেবেন না।'
           : 'Cash on delivery — pay when you receive the parcel. Never share your PIN or OTP with anyone.'},
    ];

Map<String, dynamic> s2HandoffThread(bool bn) => {
      'thread': {
        'id': 9, 'channel': 'instagram', 'customer_name': bn ? 'রাশেদ' : 'Rashed',
        'customer_phone': '', 'handover': s2Handover, 'reply_mode': s2Handover ? 'human' : 'ai',
        'paused_until': null, 'paused_by': '', 'opted_out': false, 'status': 'attention',
        'last_text': '', 'last_at': '2026-10-28T10:00:00+06:00', 'pending': 1,
        'in_window': true, 'order_draft': {}, 'handback_at': null,
        'handoff_card': !s2HandoffOpen
            ? null
            : {
                'reason': 'complaint', 'want': 'complaint', 'sentiment': 'unhappy',
                'pending': true, 'message_id': 31, 'status': 'pending_approval',
                'items': const [], 'total': '', 'last_question': '',
                'lines': {
                  'bn': ['চান: অভিযোগ করছেন — সুতি পাঞ্জাবি × ১ (৳১২০০)',
                         'শেষ প্রশ্ন: “পার্সেল এখনো আসেনি কেন?”',
                         'কারণ: অভিযোগ / অসন্তুষ্ট গ্রাহক · মেজাজ: অসন্তুষ্ট'],
                  'en': ['Wants: has a complaint — Cotton panjabi × 1 (৳1200)',
                         'Last question: “Why has the parcel not come yet?”',
                         'Why: complaint / unhappy customer · Mood: unhappy'],
                },
              },
      },
      'messages': [
        {'id': 30, 'direction': 'in', 'kind': 'text', 'is_ai': false, 'status': 'received',
         'source': '', 'rule': '', 'image_url': '', 'risk_reason': '', 'send_error': '',
         'confidence': 0, 'created_at': '',
         'text': bn ? 'পার্সেল এখনো আসেনি কেন?' : 'Why has the parcel not come yet?'},
        // the per-message card rides on the row too — the app must NOT repeat it
        {'id': 31, 'direction': 'out', 'kind': 'text', 'is_ai': true,
         'status': 'pending_approval', 'source': 'ai', 'rule': '', 'image_url': '',
         'risk_reason': 'complaint', 'send_error': '', 'confidence': 0.4, 'created_at': '',
         'text': bn ? 'দুঃখিত, আমরা দেখছি।' : 'Sorry, we are checking.',
         'handoff_card': {'reason': 'complaint', 'lines': {'bn': ['x'], 'en': ['x']}}},
      ],
      'orders': [],
    };

Map<String, dynamic> _g1ImageThread(bool bn) => {
      'thread': {
        'id': 7, 'channel': 'messenger', 'customer_name': bn ? 'সুমাইয়া' : 'Sumaiya',
        'customer_phone': '01XXXXXXXXX', 'handover': false, 'reply_mode': 'ai',
        'paused_until': null, 'paused_by': '', 'opted_out': false,
        'last_text': '', 'last_at': '2026-10-24T01:40:00+06:00', 'pending': 0,
        'in_window': true, 'order_draft': {},
      },
      'messages': [
        {'id': 1, 'direction': 'in', 'kind': 'image', 'text': '', 'is_ai': false,
         'status': 'received', 'source': '', 'rule': '', 'image_url': '', 'risk_reason': '',
         'send_error': '', 'confidence': 0, 'created_at': ''},
        {'id': 2, 'direction': 'out', 'kind': 'text', 'is_ai': true, 'status': 'sent',
         'source': 'rule', 'rule': 'image_match', 'image_url': '', 'risk_reason': '',
         'send_error': '', 'confidence': 1, 'created_at': '',
         'text': bn
             ? 'আমি দোকানের এআই সহকারী। ছবির পণ্যটি আমাদের কাছে আছে: সুতি পাঞ্জাবি — দাম ৳1200, স্টকে আছে। সাইজ: M, L। রং: সাদা, নীল। অর্ডার করতে নাম, মোবাইল নম্বর ও পূর্ণ ঠিকানা লিখুন।'
             : "I'm the shop's AI assistant. We have the product in your photo: Cotton panjabi — ৳1200, in stock. Sizes: M, L. Colours: White, Blue. To order, send your name, mobile number and full address."},
        {'id': 3, 'direction': 'in', 'kind': 'text', 'is_ai': false, 'status': 'received',
         'source': '', 'rule': '', 'image_url': '', 'risk_reason': '', 'send_error': '',
         'confidence': 0, 'created_at': '',
         'text': bn ? 'L সাইজ ২টা। সুমাইয়া, 01XXXXXXXXX, বাসা ৫, রোড ২, মিরপুর ১০, ঢাকা' : 'Size L, 2 pieces. Sumaiya, 01XXXXXXXXX, House 5, Road 2, Mirpur 10, Dhaka'},
        {'id': 4, 'direction': 'out', 'kind': 'order', 'is_ai': true, 'status': 'sent',
         'source': 'rule', 'rule': '', 'image_url': '', 'risk_reason': '', 'send_error': '',
         'confidence': 1, 'created_at': '',
         'text': bn
             ? 'অর্ডারের সারাংশ:\n- সুতি পাঞ্জাবি (L) × 2 = ৳2280\n- ডেলিভারি (ঢাকার ভিতরে): ৳60\n- মোট (ক্যাশ অন ডেলিভারি): ৳2340\nবান্ডেল ছাড়: 2টি বা বেশি নিলে প্রতি পিস ৳1200-এর বদলে ৳1140।\nসব ঠিক থাকলে "হ্যাঁ" লিখুন।'
             : 'Order summary:\n- Cotton panjabi (L) × 2 = ৳2280\n- Delivery (inside Dhaka): ৳60\n- Total (cash on delivery): ৳2340\nBundle price: 2+ pieces at ৳1140 each instead of ৳1200.\nReply "yes" to confirm.'},
        {'id': 5, 'direction': 'in', 'kind': 'text', 'text': bn ? 'হ্যাঁ' : 'yes', 'is_ai': false,
         'status': 'received', 'source': '', 'rule': '', 'image_url': '', 'risk_reason': '',
         'send_error': '', 'confidence': 0, 'created_at': ''},
        {'id': 6, 'direction': 'out', 'kind': 'invoice', 'is_ai': true, 'status': 'sent',
         'source': 'rule', 'rule': 'order_confirmed', 'image_url': '', 'risk_reason': '',
         'send_error': '', 'confidence': 1, 'created_at': '',
         'text': bn
             ? 'ইনভয়েস #41 — রূপা ফ্যাশন\nমোট (ক্যাশ অন ডেলিভারি): ৳2340\nসাথে পায়জামা (৳500) দেখতে পারেন — চাইলে জানাবেন।'
             : 'Invoice #41 — Rupa Fashion\nTotal (cash on delivery): ৳2340\nYou may also like Pajama (৳500) — tell us and we will add it.'},
        {'id': 7, 'direction': 'in', 'kind': 'image', 'text': bn ? 'বিকাশে অগ্রিম দিয়েছি' : 'Sent advance on bKash',
         'is_ai': false, 'status': 'received', 'source': '', 'rule': '', 'image_url': '',
         'risk_reason': '', 'send_error': '', 'confidence': 0, 'created_at': ''},
        {'id': 8, 'direction': 'out', 'kind': 'text', 'is_ai': true, 'status': 'sent',
         'source': 'rule', 'rule': 'payment_proof', 'image_url': '', 'risk_reason': '',
         'send_error': '', 'confidence': 1, 'created_at': '',
         'text': bn
             ? 'ধন্যবাদ, স্ক্রিনশট পেয়েছি। অর্ডার #41-এর পেমেন্ট দোকানের মালিক নিজে যাচাই করে জানাবেন — যাচাইয়ের আগে এটি পরিশোধিত ধরা হবে না।'
             : 'Thanks, we got the screenshot. The owner will verify the payment for order #41 — it is not marked as paid until then.'},
      ],
      'orders': [
        {'id': 41, 'status': 'shipped', 'total': '2340.00', 'tracking': 'TEST-STEADFAST-41',
         'courier': 'steadfast', 'courier_live': false, 'payment_status': 'pending_verification'},
      ],
    };

List<Map<String, dynamic>> _faqs(bool bn) => [
      {'id': 1, 'question': bn ? 'দোকান কোথায় | dokan kothay' : 'Where is the shop | dokan kothay',
       'answer': bn ? 'মিরপুর ১০, শাহ আলী প্লাজার পাশে।' : 'Mirpur 10, next to Shah Ali Plaza.',
       'status': 'approved', 'source': 'manual', 'has_price': false, 'hits': 42, 'updated_at': ''},
      {'id': 2, 'question': bn ? 'কাপড় ধোয়া যাবে?' : 'Can it be washed?',
       'answer': bn ? 'হ্যাঁ, ঠান্ডা পানিতে হাতে ধুয়ে নিন।' : 'Yes, hand-wash in cold water.',
       'status': 'suggested', 'source': 'learned', 'has_price': false, 'hits': 0, 'updated_at': ''},
      {'id': 3, 'question': bn ? 'কম্বো অফার আছে?' : 'Any combo offer?',
       'answer': bn ? 'দুইটা নিলে ৳২২০০।' : 'Two for ৳2200.',
       'status': 'suggested', 'source': 'learned', 'has_price': true, 'hits': 0, 'updated_at': ''},
    ];

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
      // ---- g1 ----
      'ai_mode': 'always', 'resume_minutes': 15, 'rules_enabled': true,
      'quiet_hours': {'start': '23:00', 'end': '08:00'}, 'morning_summary': true,
      'morning_hour': 8, 'followups_enabled': true, 'followup_after_hours': 3,
      'followup_max': 1, 'upsell_enabled': true,
      'bundle_rules': [{'min_qty': 2, 'off_pct': 5}], 'auto_courier': true,
      'vision_enabled': true, 'voice_enabled': true, 'comment_dm': true,
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
    'g1': {'vision_ready': g1VisionReady, 'voice_ready': false, 'vision_credits': 6,
           'voice_credits': 3, 'reply_credits': 3,
           'widget': {'enabled': true, 'has_key': true}},
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
  if (p == '/bizagent/inbox') {
    // biz-v2: Business inbox (views_bizagent_v2.InboxView)
    final all = mode == FakeMode.empty
        ? <Map<String, dynamic>>[]
        : <Map<String, dynamic>>[
            {..._thread(bn), 'status': 'agent', 'unread': 0},
            {..._thread(bn, handover: true), 'id': 6, 'channel': 'whatsapp_cloud',
             'customer_name': bn ? 'রহিম' : 'Rahim', 'pending': 0, 'status': 'owner',
             'unread': 2, 'last_text': bn ? 'লাল শাড়িটা আছে?' : 'Is the red saree there?'},
            {..._thread(bn), 'id': 8, 'customer_name': bn ? 'তানিয়া' : 'Tania',
             'status': 'attention', 'unread': 1, 'pending': 1,
             'last_text': bn ? '[ছবি]' : '[image]'},
          ];
    final qp = Uri.parse(path).queryParameters;
    final st = qp['status'] ?? '';
    final rows = all.where((r) => st.isEmpty || r['status'] == st).where(
        (r) => qp['unread'] != '1' || ((r['unread'] as int) > 0)).toList();
    return {
      'threads': rows,
      'counts': {'all': all.length, 'agent': all.isEmpty ? 0 : 1, 'owner': all.isEmpty ? 0 : 1,
                 'attention': all.isEmpty ? 0 : 1, 'unread': all.isEmpty ? 0 : 2},
      'features': {'own_channels': true, 'inbox': all.isNotEmpty, 'image_order': true,
                   'vision': false},
    };
  }
  if (p == '/bizagent/threads/8') {
    final d = _g1ImageThread(bn);
    return {
      ...d,
      'thread': {...(d['thread'] as Map<String, dynamic>), 'id': 8, 'handover': true,
                 'handback_at': '2026-10-24T02:40:00+06:00'},
      'messages': (d['messages'] as List).take(2).toList(),
      'orders': [
        {'id': 52, 'status': 'new', 'total': '1200.00', 'tracking': '', 'courier': '',
         'courier_live': false, 'payment_status': '', 'draft': true,
         'items': [{'product_id': 1, 'name': bn ? 'সুতি পাঞ্জাবি' : 'Cotton panjabi',
                    'qty': 1, 'price': '1200'}]},
      ],
    };
  }
  if (p == '/bizagent/threads/7') return _g1ImageThread(bn);
  // sales2: catalog quick replies (views_bizagent_v2.QuickRepliesView)
  if (p.startsWith('/bizagent/threads/') && p.endsWith('/quick-replies')) {
    return {'lang': bn ? 'bn' : 'en', 'replies': s2QuickReplies(bn)};
  }
  // sales2: a chat with an open handoff (bizagent_guard.open_handoff)
  if (p == '/bizagent/threads/9') return s2HandoffThread(bn);
  if (p == '/bizagent/faqs') {
    return {'faqs': mode == FakeMode.empty ? [] : _faqs(bn), 'rules_enabled': true};
  }
  if (p == '/bizagent/post-links') {
    return {'links': mode == FakeMode.empty ? [] : [
      {'id': 1, 'post_id': '1234_5678', 'product_id': 1, 'product': bn ? 'সুতি পাঞ্জাবি' : 'Cotton panjabi'},
    ], 'comment_dm': true};
  }
  if (p == '/bizagent/agent-report') {
    return {'days': 30, 'report': {
      'chats': 186, 'orders': 23, 'revenue': 31640.0, 'gross_profit': 9120.0,
      'ai_cost': 214.0, 'profit': 8906.0, 'rule_replies': 512, 'ai_replies': 141,
      'rule_share': 78.4, 'images': 37, 'voice': 9, 'cost_known': true},
      'rules': {'rule': 512, 'ai': 141, 'rule_pct': 78.4, 'saved_seller_credits': 1536,
                'saved_seller_bdt': 1536.0, 'by_rule': {'product': 301, 'delivery': 96}}};
  }
  if (p == '/bizagent/widget') {
    return {'enabled': true, 'key': 'w_demoKey123', 'origins': 'https://rupafashion.example',
            'snippet': '<script src="https://api.lifeassisto.com/api/v1/bizagent/chat.js" data-key="w_demoKey123" async></script>'};
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
  if (path == '/bizagent/settings') {
    return {'ok': true, 'settings': {...(_setup(bn, FakeMode.data)['settings'] as Map<String, dynamic>), ...body}};
  }
  if (path.endsWith('/mode')) {
    // sales2: thread 9 follows the toggle; giving it back resolves the handoff
    if (path == '/bizagent/threads/9/mode') {
      s2Handover = body['mode'] == 'human';
      if (body['mode'] == 'ai') s2HandoffOpen = false;
    }
    return {'ok': true, 'reply_mode': body['mode'], 'handover': body['mode'] == 'human'};
  }
  if (path == '/bizagent/faqs/learn') return {'ok': true, 'suggested': 2};
  if (path == '/bizagent/widget') {
    return {'ok': true, 'enabled': body['enabled'] ?? true, 'key': 'w_demoKey123',
            'origins': body['origins'] ?? '', 'snippet': '<script src="https://api.lifeassisto.com/api/v1/bizagent/chat.js" data-key="w_demoKey123" async></script>'};
  }
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
