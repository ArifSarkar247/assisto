// retention1: an in-memory RetentionSource for the gallery + widget tests.
// Shapes mirror backend/core/views_retention.py.
import 'package:assisto/api.dart';
import 'package:assisto/screens/retention/retention_source.dart';

class FakeRetention implements RetentionSource {
  /// 'data' (two automations), 'empty' (first run), 'plan' (not Business),
  /// 'off' (flag hidden -> 403), 'fail' (network error), 'inbox_empty'.
  final String mode;
  FakeRetention([this.mode = 'data']);

  final List<String> calls = [];
  Map<String, dynamic>? lastCreate;
  Map<String, dynamic>? lastUpdate;
  Map<String, dynamic>? lastCaps;
  String? lastReply;
  int? stopped;
  bool previewFails = false;

  static const kinds = [
    {
      'kind': 'thanks_review',
      'purpose': 'marketing',
      'vars': ['name', 'shop', 'product'],
      'params': {
        'days_after': {'min': 1, 'max': 30, 'default': 2}
      },
      'default_bn': '{name}, thank you (bn)',
      'default_en': '{name}, thank you for shopping at {shop}!',
    },
    {
      'kind': 'winback',
      'purpose': 'marketing',
      'vars': ['name', 'shop', 'days'],
      'params': {
        'days_without': {'min': 14, 'max': 365, 'default': 45}
      },
      'default_bn': '{name}, we miss you (bn)',
      'default_en': '{name}, we miss you at {shop}!',
    },
    {
      'kind': 'khata_due',
      'purpose': 'utility',
      'vars': ['name', 'shop', 'due'],
      'params': {
        'min_due_taka': {'min': 1, 'max': 1000000, 'default': 100},
        'every_days': {'min': 7, 'max': 60, 'default': 14},
      },
      'default_bn': '{name}, due {due} (bn)',
      'default_en': '{name}, a gentle note: {due} is due.',
    },
    {
      'kind': 'back_in_stock',
      'purpose': 'marketing',
      'vars': ['name', 'shop', 'product'],
      'params': {},
      'default_bn': '{product} is back (bn)',
      'default_en': '{name}, the {product} you asked for is back.',
    },
    {
      'kind': 'birthday',
      'purpose': 'marketing',
      'vars': ['name', 'shop'],
      'params': {},
      'default_bn': 'Happy birthday {name} (bn)',
      'default_en': 'Happy birthday, {name}!',
    },
  ];

  static Map<String, dynamic> automation(
          {int id = 1, String kind = 'thanks_review', bool enabled = true, String channel = 'in_app'}) =>
      {
        'id': id,
        'kind': kind,
        'name': '',
        'enabled': enabled,
        'params': kind == 'thanks_review' ? {'days_after': 2} : {'days_without': 45},
        'template_bn': '{name}, thanks (bn)',
        'template_en': '{name}, thank you!',
        'channel': channel,
        'wa_template': <String, dynamic>{},
        'send_hour': 11,
        'last_run_at': '2026-10-26T11:30:00+06:00',
        'created_at': '2026-10-20T10:00:00+06:00',
        'summary': {'sent': 24, 'replied': 6, 'purchases': 3, 'opted_out': 1},
      };

  void _fail() {
    if (mode == 'fail') throw ApiException('Error 500', 500);
    if (mode == 'off') throw ApiException('This feature is not available yet.', 403);
  }

  @override
  Future<Map<String, dynamic>> overview() async {
    calls.add('overview');
    _fail();
    return {
      'plan_ok': mode != 'plan',
      'credits': 120,
      'shop': 'Rina Store',
      'quiet': {'start': '21:00', 'end': '09:00', 'now': false},
      'channels_ready': ['in_app', 'whatsapp'],
      'kinds': kinds,
      'max_automations': 10,
      'attribution_days': 7,
      'opted_out_count': 1,
      'caps': {'per_customer_day': 1, 'per_customer_week': 2, 'business_daily': 100},
      'server_max': {'per_customer_day': 1, 'per_customer_week': 2, 'business_daily': 100},
      'automations': mode == 'empty' || mode == 'plan'
          ? <Map<String, dynamic>>[]
          : [automation(), automation(id: 2, kind: 'winback', enabled: false, channel: 'whatsapp')],
    };
  }

  @override
  Future<Map<String, dynamic>> saveCaps(Map<String, dynamic> caps) async {
    calls.add('caps');
    lastCaps = caps;
    return {'caps': caps};
  }

  @override
  Future<Map<String, dynamic>> create(Map<String, dynamic> body) async {
    calls.add('create');
    lastCreate = body;
    return {...automation(), ...body, 'id': 9};
  }

  @override
  Future<Map<String, dynamic>> update(int id, Map<String, dynamic> body) async {
    calls.add('update:$id');
    lastUpdate = body;
    return {...automation(id: id), ...body};
  }

  @override
  Future<void> delete(int id) async {
    calls.add('delete:$id');
  }

  @override
  Future<Map<String, dynamic>> preview(Map<String, dynamic> draft) async {
    calls.add('preview');
    if (previewFails) throw ApiException('Error 500', 500);
    return {
      'audience': mode == 'empty' ? 0 : 38,
      'opted_out': 1,
      'no_phone': 4,
      'due_now': 3,
      'on_assisto': 12,
      'on_assisto_checked': 38,
      'sample_names': ['Karim'],
      'sample_text': 'Karim, thank you!\nTap "Stop" to get no more messages.',
      'quiet_now': false,
      'next_send_at': '2026-10-27T09:00:00+06:00',
    };
  }

  @override
  Future<Map<String, dynamic>> results(int id) async {
    calls.add('results:$id');
    _fail();
    return {
      'sent': mode == 'empty' ? 0 : 24,
      'delivered': 20,
      'read': 0,
      'replied': 6,
      'opted_out': 1,
      'purchases': 3,
      'revenue_poisha': 425000,
      'credits': 0,
      'attribution_days': 7,
      'not_sent': 5,
      'not_sent_reasons': mode == 'empty' ? {} : {'not_on_assisto': 4, 'insufficient_credits': 1},
      'automation': automation(id: id),
      'recent': mode == 'empty'
          ? []
          : [
              {
                'id': 1,
                'name': 'Karim',
                'phone': '017•••••002',
                'channel': 'in_app',
                'status': 'delivered',
                'reason': '',
                'at': '2026-10-26T11:30:00+06:00',
                'replied': true,
                'reply_text': 'Very good!',
                'opted_out': false,
                'purchase_poisha': 80000,
                'text': 'Karim, thank you!',
              },
              {
                'id': 2,
                'name': '',
                'phone': '018•••••771',
                'channel': 'in_app',
                'status': 'skipped',
                'reason': 'not_on_assisto',
                'at': '2026-10-26T11:30:00+06:00',
                'replied': false,
                'reply_text': '',
                'opted_out': false,
                'purchase_poisha': 0,
                'text': '',
              },
            ],
    };
  }

  @override
  Future<Map<String, dynamic>> customers(String q, {bool withBirthday = false}) async {
    calls.add('customers:$q');
    _fail();
    if (mode == 'empty') return {'customers': []};
    return {
      'customers': [
        {'id': 1, 'name': 'Karim', 'phone': '01710000002', 'birthday': '1990-10-27'},
        {'id': 2, 'name': 'Mita', 'phone': '01710000003', 'birthday': null},
      ]
    };
  }

  @override
  Future<Map<String, dynamic>> setBirthday(int customerId, String? isoDate) async {
    calls.add('birthday:$customerId:$isoDate');
    return {'id': customerId, 'birthday': isoDate};
  }

  @override
  Future<Map<String, dynamic>> stockAsks() async {
    calls.add('asks');
    _fail();
    return {
      'asks': mode == 'empty'
          ? []
          : [
              {
                'id': 1,
                'product_id': 5,
                'product': 'Blue saree',
                'in_stock': false,
                'customer_id': 1,
                'customer': 'Karim',
                'phone': '01710000002',
                'notified': false,
                'created_at': '2026-10-25T12:00:00+06:00',
              },
              {
                'id': 2,
                'product_id': 6,
                'product': 'Red kurti',
                'in_stock': true,
                'customer_id': 2,
                'customer': 'Mita',
                'phone': '01710000003',
                'notified': true,
                'created_at': '2026-10-24T12:00:00+06:00',
              },
            ],
      'products': [
        {'id': 5, 'name': 'Blue saree', 'in_stock': false},
        {'id': 6, 'name': 'Red kurti', 'in_stock': true},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> addStockAsk(int productId, int customerId) async {
    calls.add('ask:$productId:$customerId');
    return {'id': 3};
  }

  @override
  Future<void> removeStockAsk(int id) async {
    calls.add('unask:$id');
  }

  @override
  Future<Map<String, dynamic>> addOptOut(String phone) async {
    calls.add('optout:$phone');
    return {'ok': true, 'opted_out_count': 2};
  }

  @override
  Future<Map<String, dynamic>> inbox() async {
    calls.add('inbox');
    _fail();
    if (mode == 'inbox_empty' || mode == 'empty') return {'messages': []};
    return {
      'messages': [
        {
          'id': 7,
          'shop': 'Rina Store',
          'text': 'Karim, thank you for shopping at Rina Store!\n'
              'Tap "Stop" to get no more messages.',
          'at': '2026-10-26T11:30:00+06:00',
          'replied': false,
          'reply_text': '',
          'stopped': stopped == 7,
        },
        {
          'id': 8,
          'shop': 'Mitali Pharmacy',
          'text': 'A gentle note: 1,250 taka is due.',
          'at': '2026-10-20T10:00:00+06:00',
          'replied': true,
          'reply_text': 'Will pay Friday',
          'stopped': true,
        },
      ]
    };
  }

  @override
  Future<Map<String, dynamic>> reply(int id, String text) async {
    calls.add('reply:$id');
    lastReply = text;
    return {'ok': true, 'stopped': false};
  }

  @override
  Future<Map<String, dynamic>> stop(int id) async {
    calls.add('stop:$id');
    stopped = id;
    return {'ok': true, 'stopped': true};
  }
}
