// agent-core WP-APP: a fake agent-core server for widget tests and the
// screenshot gallery. Shapes mirror backend/core/agentcore/views.py. Every
// value here is a TEST fixture (never shown in the real app).
import 'dart:async';
import 'dart:io';

import 'package:assisto/api.dart';
import 'package:assisto/screens/agent_core/agent_core_source.dart';

Map<String, dynamic> acToolsJson({int plan = 7, int max = 15, int left = 3}) => {
      'version': 1,
      'estimate': {
        'plan_credits': plan,
        'typical_credits': plan,
        'max_credits': max,
        'runs_per_day': 3,
        'runs_left_today': left,
      },
      'topics': {},
      'tools': [
        {'name': 'money.month_summary', 'label_bn': 'মাসের আয়-খরচ', 'label_en': 'Month income/expense summary'},
        {'name': 'khata.dues', 'label_bn': 'খাতার বাকি', 'label_en': 'Khata dues'},
        {'name': 'notes.delete', 'label_bn': 'নোট মোছা', 'label_en': 'Delete a note'},
      ],
    };

final _created = DateTime.now().subtract(const Duration(minutes: 3)).toUtc().toIso8601String();
String _expires([Duration d = const Duration(hours: 47)]) =>
    DateTime.now().add(d).toUtc().toIso8601String();

Map<String, dynamic> acApprovalJson(
        {int id = 11,
        bool bn = false,
        String risk = 'delete',
        bool expired = false,
        bool masked = false}) =>
    {
      'id': id,
      'run': 5,
      'risk': risk,
      'status': 'pending',
      'title': masked
          ? (bn ? 'রহিমকে মেসেজ পাঠাবেন?' : 'Send a message to Rahim?')
          : (bn ? "নোট মুছবেন: 'বাজারের লিস্ট'?" : "Delete note: 'Grocery list'?"),
      'expires_at': expired
          ? DateTime.now().subtract(const Duration(hours: 1)).toUtc().toIso8601String()
          : _expires(),
      'tool': masked ? 'messages.send' : 'notes.delete',
      'tool_label': masked ? (bn ? 'মেসেজ পাঠানো' : 'Send a message') : (bn ? 'নোট মোছা' : 'Delete a note'),
      'credits': masked ? 1 : 0,
      'goal': bn ? 'পুরনো বাজারের লিস্ট মুছে দাও' : 'Delete my old grocery list',
      'details': masked
          ? [
              {'key': 'to', 'value': '017•••••678'},
              {'key': 'text', 'value': bn ? 'কাল দোকানে আসবেন' : 'Please come to the shop tomorrow'},
            ]
          : [
              {'key': 'id', 'value': '42'}
            ],
    };

Map<String, dynamic> acRunJson(String state,
    {int id = 5,
    bool bn = false,
    String error = '',
    String errorText = '',
    int credits = 7,
    List<Map<String, dynamic>>? approvals,
    int? feedback}) {
  final done = state == 'done';
  return {
    'id': id,
    'state': state,
    'topic': 'money',
    'topic_label': bn ? 'টাকা' : 'Money',
    'goal': bn ? 'এই মাসে কোথায় বেশি খরচ হলো?' : 'Where did I spend the most this month?',
    'answer': done
        ? (bn
            ? 'অক্টোবর ২০২৬: আয় ৳৪৫,০০০, খরচ ৳৩১,২০০। সবচেয়ে বেশি খরচ: বাজার ৳১২,৪০০।'
            : 'October 2026: income ৳45,000, spent ৳31,200. Top expense: groceries ৳12,400.')
        : '',
    'error': error,
    'error_text': errorText,
    'credits': credits,
    'steps': done ? 1 : 0,
    'created_at': _created,
    'finished_at': done ? _created : null,
    'feedback': feedback,
    'approvals': approvals ?? const [],
    'trail': [
      {'no': 1, 'kind': 'plan', 'tool': '', 'state': error.startsWith('ai_') ? 'failed' : 'done',
        'risk': '', 'summary': 'money.month_summary', 'credits': credits, 'error': ''},
      if (!error.startsWith('ai_') && error != 'credits')
        {
          'no': 2,
          'kind': 'tool',
          'tool': approvals != null && approvals.isNotEmpty ? 'notes.delete' : 'money.month_summary',
          'state': done
              ? 'done'
              : (state == 'waiting_approval' ? 'waiting_approval' : (state == 'cancelled' ? 'skipped' : 'pending')),
          'risk': 'read',
          'summary': done ? (bn ? 'আয় ৳৪৫,০০০, খরচ ৳৩১,২০০' : 'Income ৳45,000, spent ৳31,200') : '',
          'credits': 0,
          'error': '',
        },
    ],
  };
}

/// mode: data | empty | fail | off | no_ai | credits | cap | slow (running ->
/// done on the 2nd poll) | approval | offline (POST throws SocketException)
class FakeAgentCore implements AgentCoreSource {
  FakeAgentCore([this.mode = 'data', {this.bn = false, this.left = 3}]);
  final String mode;
  final bool bn;
  final int left;
  final calls = <String>[];
  int polls = 0;
  bool decided = false;

  Never _off() => throw ApiException('This feature is not available yet.', 403, null, null,
      {'error': 'feature_off', 'detail': 'This feature is not available yet.'});

  @override
  Future<Map<String, dynamic>> tools() async {
    calls.add('tools');
    if (mode == 'off') _off();
    if (mode == 'fail') throw const SocketException('down');
    return acToolsJson(left: left);
  }

  @override
  Future<Map<String, dynamic>> startGoal(String text, {required String clientId}) async {
    calls.add('goal:$text:$clientId');
    switch (mode) {
      case 'offline':
        throw const SocketException('no route');
      case 'cap':
        throw ApiException("Today's agent task limit is reached — please try tomorrow.", 429, null,
            null, {'error': 'daily_cap'});
      case 'no_ai':
        return acRunJson('failed', bn: bn, error: 'ai_no_key', credits: 0,
            errorText: bn ? 'এজেন্ট এখনো চালু হয়নি।' : 'The agent is not switched on yet.');
      case 'credits':
        return acRunJson('failed', bn: bn, error: 'credits', credits: 0,
            errorText: bn ? 'ক্রেডিট শেষ — ক্রেডিট নিয়ে আবার চেষ্টা করুন।' : 'Out of credits — top up and try again.');
      case 'slow':
        return acRunJson('running', bn: bn, credits: 7);
      case 'approval':
        return acRunJson('waiting_approval', bn: bn, approvals: [acApprovalJson(bn: bn)]);
      default:
        return acRunJson('done', bn: bn);
    }
  }

  @override
  Future<Map<String, dynamic>> runs() async {
    calls.add('runs');
    if (mode == 'fail') throw const SocketException('down');
    if (mode == 'empty') return {'runs': []};
    return {
      'runs': [
        acRunJson('done', id: 5, bn: bn),
        acRunJson('waiting_approval', id: 4, bn: bn, credits: 7),
        acRunJson('failed', id: 3, bn: bn, error: 'ai_no_key', credits: 0),
      ]
    };
  }

  @override
  Future<Map<String, dynamic>> run(int id) async {
    calls.add('run:$id');
    polls++;
    if (mode == 'slow') {
      return polls >= 2 ? acRunJson('done', id: id, bn: bn) : acRunJson('running', id: id, bn: bn);
    }
    if (mode == 'approval' && !decided) {
      return acRunJson('waiting_approval', id: id, bn: bn, approvals: [acApprovalJson(bn: bn)]);
    }
    return acRunJson('done', id: id, bn: bn);
  }

  @override
  Future<Map<String, dynamic>> cancel(int id) async {
    calls.add('cancel:$id');
    return acRunJson('cancelled', id: id, bn: bn, error: 'user');
  }

  @override
  Future<Map<String, dynamic>> feedback(int id, int value, String note) async {
    calls.add('feedback:$id:$value:$note');
    return {'ok': true, 'feedback': value};
  }

  @override
  Future<Map<String, dynamic>> approvals() async {
    calls.add('approvals');
    if (mode == 'fail') throw const SocketException('down');
    if (mode == 'empty' || mode == 'data' || decided) return {'approvals': []};
    return {
      'approvals': [
        acApprovalJson(id: 11, bn: bn),
        acApprovalJson(id: 12, bn: bn, risk: 'external', masked: true),
        if (mode == 'expired') acApprovalJson(id: 13, bn: bn, expired: true),
      ]
    };
  }

  @override
  Future<Map<String, dynamic>> decide(int id, String decision) async {
    calls.add('decide:$id:$decision');
    decided = true;
    return {
      'approval': {
        ...acApprovalJson(id: id, bn: bn),
        'status': decision == 'approve' ? 'approved' : 'rejected'
      },
      'run': acRunJson('done', bn: bn),
    };
  }
}

/// A source whose calls never finish (the "sending…" gallery state).
class HangingAgentCore extends FakeAgentCore {
  HangingAgentCore() : super('data');
  @override
  Future<Map<String, dynamic>> startGoal(String text, {required String clientId}) =>
      Completer<Map<String, dynamic>>().future;
}
