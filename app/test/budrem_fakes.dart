// budrem: an in-memory RemitSource for the gallery + widget tests. Shapes
// mirror backend/core/remittance_views.py. The fixture family is Rahim's
// (never the owner's name).
import 'dart:async';
import 'dart:io';

import 'package:assisto/api.dart';
import 'package:assisto/screens/remittance/remit_source.dart';

class FakeRemit implements RemitSource {
  /// 'empty' (first run), 'data' (a month with entries, plan, goal, bills),
  /// 'missing' (expected money has not come), 'off' (flag hidden),
  /// 'fail' (server error), 'offline' (no internet).
  final String mode;
  FakeRemit([this.mode = 'data']) : offline = mode == 'offline';

  bool offline;
  final List<String> calls = [];
  final List<Map<String, dynamic>> created = [];
  final List<Map<String, dynamic>> spent = [];
  final List<String> shared = [];
  final List<String> notes = [];
  final Map<String, String> prefs = {};
  int _id = 100;

  static const month = '2026-10';

  late final List<Map<String, dynamic>> entries = mode == 'data' || mode == 'missing'
      ? [
          if (mode == 'data') ...[
            {
              'id': 1, 'client_id': 'seed-0001', 'received_on': '2026-10-05', 'month': month,
              'amount': '500', 'currency': 'SAR', 'rate': '32.50', 'taka': '16250.00',
              'channel': 'bank', 'sender_member_id': 7, 'sender_name': 'Karim', 'note': '', 'source': 'manual',
            },
            {
              'id': 2, 'client_id': 'seed-0002', 'received_on': '2026-10-12', 'month': month,
              'amount': '20000', 'currency': 'BDT', 'rate': '1', 'taka': '20000.00',
              'channel': 'bkash', 'sender_member_id': null, 'sender_name': 'Bhai', 'note': '', 'source': 'text',
            },
          ],
        ]
      : [];

  Map<String, double> plan = {'food': 12000, 'rent': 8000, 'education': 4000, 'savings': 5000};
  Map<String, double> actual = {'food': 10500, 'rent': 9000, 'health': 1200, 'savings': 4000};
  Map<String, dynamic>? goal = {'id': 3, 'title': 'Roof repair', 'target': '100000.00', 'saved': '40000.00', 'pct': 40};
  late List<Map<String, dynamic>> bills = mode == 'data'
      ? [
          {'id': 1, 'name': 'School fee', 'amount': '3000.00', 'due_day': 7, 'category': 'education',
           'paid_months': [month], 'reminder_local_id': 'r1'},
          {'id': 2, 'name': 'Electricity', 'amount': '1400.00', 'due_day': 15, 'category': 'other',
           'paid_months': [], 'reminder_local_id': ''},
        ]
      : [];
  Map<String, dynamic> expected = {'taka': '30000.00', 'day': 10, 'sender': 'Karim'};
  bool guideDone = false;

  Future<void> _gate() async {
    if (mode == 'off') throw ApiException('This feature is not available yet.', 403);
    if (mode == 'fail') throw ApiException('Error 500', 500);
    if (offline) throw const SocketException('offline');
  }

  String _line(String k) {
    final p = plan[k] ?? 0, a = actual[k] ?? 0;
    final st = p == 0 ? 'none' : (a > p ? 'over' : (a >= p * 0.8 ? 'near' : 'ok'));
    return st;
  }

  double get _received => entries.fold(0.0, (s, e) => s + (double.tryParse('${e['taka']}') ?? 0));
  double get _spent => actual.values.fold(0.0, (a, b) => a + b);

  @override
  Future<Map<String, dynamic>> overview(String m) async {
    calls.add('overview:$m');
    await _gate();
    final status = switch (mode) {
      'missing' => 'missing',
      'empty' => 'none',
      _ => _received >= 30000 ? 'arrived' : 'partial',
    };
    return {
      'month': m,
      'received': _received.toStringAsFixed(2),
      'count': entries.length,
      'entries': [for (final e in entries) if ('${e['month']}' == m) e],
      'expected': mode == 'empty'
          ? {'taka': '0.00', 'day': 0, 'sender': '', 'status': 'none', 'due_date': null, 'alert_now': false}
          : {...expected, 'status': status, 'due_date': '$m-10', 'alert_now': mode == 'missing'},
      'plan': {
        'lines': [
          for (final k in ['food', 'rent', 'education', 'health', 'savings', 'loan', 'other'])
            {
              'key': k,
              'plan': (mode == 'empty' ? 0 : (plan[k] ?? 0)).toStringAsFixed(2),
              'actual': (mode == 'empty' ? 0 : (actual[k] ?? 0)).toStringAsFixed(2),
              'pct': 0,
              'state': mode == 'empty' ? 'none' : _line(k),
            }
        ],
        'planned': '29000.00',
        'spent': (mode == 'empty' ? 0 : _spent).toStringAsFixed(2),
        'left': (_received - (mode == 'empty' ? 0 : _spent)).toStringAsFixed(2),
        'unplanned': '0.00',
      },
      'goal': mode == 'empty' ? null : goal,
      'bills': [for (final b in bills) {...b, 'paid': (b['paid_months'] as List).contains(m)}],
      'guide_done': guideDone,
      'channels': ['bank', 'bkash', 'nagad', 'rocket', 'western_union', 'moneygram', 'other'],
    };
  }

  @override
  Future<Map<String, dynamic>> createEntry(Map<String, dynamic> body) async {
    calls.add('create:${body['client_id']}');
    await _gate();
    // idempotent on client id, like the server
    for (final e in entries) {
      if (e['client_id'] == body['client_id']) return {...e, 'duplicate': true};
    }
    final cur = '${body['currency']}';
    final taka = cur == 'BDT'
        ? double.parse('${body['amount']}')
        : (double.tryParse('${body['taka']}') ??
            double.parse('${body['amount']}') * double.parse('${body['rate']}'));
    final row = {
      'id': ++_id, ...body, 'month': '${body['received_on']}'.substring(0, 7),
      'taka': taka.toStringAsFixed(2), 'rate': cur == 'BDT' ? '1' : '${body['rate']}',
    };
    entries.add(row);
    created.add(body);
    return row;
  }

  @override
  Future<Map<String, dynamic>> updateEntry(int id, Map<String, dynamic> body) async {
    calls.add('update:$id');
    await _gate();
    final e = entries.firstWhere((e) => e['id'] == id);
    e.addAll(body);
    return e;
  }

  @override
  Future<void> deleteEntry(int id) async {
    calls.add('delete:$id');
    await _gate();
    entries.removeWhere((e) => e['id'] == id);
  }

  @override
  Future<Map<String, dynamic>> saveSettings(Map<String, dynamic> body) async {
    calls.add('settings:${body.keys.join(',')}');
    await _gate();
    if (body['guide_done'] == true) guideDone = true;
    if (body.containsKey('expected_taka')) {
      expected = {'taka': '${body['expected_taka']}', 'day': body['expected_day'], 'sender': body['expected_sender']};
    }
    return body;
  }

  @override
  Future<Map<String, dynamic>> savePlan(Map<String, String> lines) async {
    calls.add('plan');
    await _gate();
    plan = {for (final e in lines.entries) if ((double.tryParse(e.value) ?? 0) > 0) e.key: double.parse(e.value)};
    return {};
  }

  @override
  Future<Map<String, dynamic>> spend(Map<String, dynamic> body) async {
    calls.add('spend:${body['category']}:${body['amount']}');
    await _gate();
    spent.add(body);
    final k = '${body['category']}';
    actual[k] = (actual[k] ?? 0) + double.parse('${body['amount']}');
    return {'id': ++_id};
  }

  @override
  Future<Map<String, dynamic>> saveGoal(String title, String target) async {
    calls.add('goal:$title:$target');
    await _gate();
    goal = {'id': 3, 'title': title, 'target': target, 'saved': '${goal?['saved'] ?? '0'}', 'pct': 0};
    return goal!;
  }

  @override
  Future<Map<String, dynamic>> addToGoal(String clientId, String amount) async {
    calls.add('goaladd:$amount');
    await _gate();
    final saved = double.parse('${goal!['saved']}') + double.parse(amount);
    final target = double.parse('${goal!['target']}');
    goal = {...goal!, 'saved': saved.toStringAsFixed(2), 'pct': (saved * 100 ~/ target)};
    return goal!;
  }

  @override
  Future<Map<String, dynamic>> addBill(Map<String, dynamic> body) async {
    calls.add('bill:${body['name']}');
    await _gate();
    final b = {...body, 'id': ++_id, 'paid_months': <String>[], 'reminder_local_id': ''};
    bills.add(b);
    return b;
  }

  @override
  Future<Map<String, dynamic>> updateBill(int id, Map<String, dynamic> body) async {
    calls.add('billupd:$id:${body.keys.join(',')}');
    await _gate();
    final b = bills.firstWhere((b) => b['id'] == id);
    b.addAll(body);
    return b;
  }

  @override
  Future<Map<String, dynamic>> deleteBill(int id) async {
    calls.add('billdel:$id');
    await _gate();
    final b = bills.firstWhere((b) => b['id'] == id);
    bills.remove(b);
    return {'ok': true, 'reminder_local_id': b['reminder_local_id']};
  }

  @override
  Future<Map<String, dynamic>> billPaid(int id, String m, String clientId) async {
    calls.add('billpaid:$id:$m');
    await _gate();
    (bills.firstWhere((b) => b['id'] == id)['paid_months'] as List).add(m);
    return {'paid': true};
  }

  @override
  Future<Map<String, dynamic>> report(String m, String lang) async {
    calls.add('report:$m:$lang');
    await _gate();
    return {
      'month': m,
      'lang': lang,
      'text': lang == 'bn'
          ? 'অক্টোবর ২০২৬-এর হিসাব\nএসেছে: ৳৩৬,২৫০ (২ বার)\nকোথায় গেল:\n• খাবার: ৳১০,৫০০ (পরিকল্পনা ৳১২,০০০)\n'
              '• ভাড়া: ৳৯,০০০ (পরিকল্পনা ৳৮,০০০)\nমোট খরচ: ৳২৪,৭০০\nহাতে আছে: ৳১১,৫৫০\n— Assisto'
          : 'Family budget — October 2026\nReceived: ৳36,250 (2 times)\nWhere it went:\n'
              '• Food: ৳10,500 (plan ৳12,000)\n• Rent: ৳9,000 (plan ৳8,000)\n'
              'Total spent: ৳24,700\nLeft: ৳11,550\n— Assisto',
    };
  }

  @override
  Future<Map<String, dynamic>> year(int y) async {
    calls.add('year:$y');
    await _gate();
    if (mode == 'empty') {
      return {'year': y, 'total': '0.00', 'count': 0, 'months': List.filled(12, '0.00'), 'by_sender': [],
        'by_channel': [], 'savings': '0.00', 'avg_month': '0.00'};
    }
    return {
      'year': y, 'total': '312500.00', 'count': 14,
      'months': ['30000.00', '28000.00', '31000.00', '30000.00', '29500.00', '45000.00', '30000.00',
        '30000.00', '20000.00', '36250.00', '0.00', '0.00'],
      'by_sender': [
        {'name': 'Karim', 'total': '216250.00', 'count': 9},
        {'name': 'Bhai', 'total': '96250.00', 'count': 5},
      ],
      'by_channel': [
        {'key': 'bank', 'total': '180000.00', 'count': 6},
        {'key': 'bkash', 'total': '92500.00', 'count': 6},
        {'key': 'western_union', 'total': '40000.00', 'count': 2},
      ],
      'savings': '44000.00', 'avg_month': '31250.00',
    };
  }

  @override
  Future<Map<String, dynamic>> export(String fmt) async {
    calls.add('export:$fmt');
    await _gate();
    return {'filename': 'assisto-remittance.$fmt', 'text': 'date,amount\n'};
  }

  @override
  Future<void> deleteAll() async {
    calls.add('deleteAll');
    await _gate();
    entries.clear();
    bills.clear();
    goal = null;
  }

  @override
  Future<List<Map<String, dynamic>>> members() async {
    calls.add('members');
    if (offline) throw const SocketException('offline');
    return [
      {'id': 7, 'name': 'Karim', 'relation': 'brother', 'public_key': 'k'},
      {'id': 8, 'name': 'Salma', 'relation': 'sister', 'public_key': 'k'},
    ];
  }

  @override
  Future<void> shareToMember(Map<String, dynamic> member, String text) async {
    calls.add('share:${member['id']}');
    await _gate();
    shared.add(text);
  }

  @override
  Future<String?> addMonthlyReminder(String title, DateTime first) async {
    calls.add('reminder:$title');
    return 'lid-${++_id}';
  }

  @override
  Future<void> removeReminder(String localId) async => calls.add('unremind:$localId');

  @override
  Future<void> scheduleNote(String key, String title, String body, DateTime when) async =>
      notes.add('schedule:$key');
  @override
  Future<void> cancelNote(String key) async => notes.add('cancel:$key');
  @override
  Future<void> showNote(String key, String title, String body) async => notes.add('show:$key');

  @override
  Future<String?> getPref(String key) async => prefs[key];
  @override
  Future<void> setPref(String key, String value) async => prefs[key] = value;
}

/// Lets a pending future finish inside a widget test.
Future<void> idle() => Future<void>.delayed(Duration.zero);
