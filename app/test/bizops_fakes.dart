// bizops: fake server for the morning business card (widget tests + gallery).
// Shapes mirror backend/core/agentcore/bizops.py card() / views._run_out.
import 'dart:io';

import 'package:assisto/api.dart';
import 'package:assisto/screens/agent_core/biz_brief_source.dart';

import 'agent_core_fakes.dart';

Map<String, dynamic> boCardJson({bool bn = false, String mode = 'data'}) {
  final data = mode == 'data' || mode == 'no_supplier';
  return {
    'date': '2026-11-02',
    'has_business': mode != 'no_business',
    'shop': 'Rahim Store',
    'empty': mode == 'empty',
    'ai_ready': false,
    'lines': data
        ? [
            {
              'key': 'sales',
              'text': bn
                  ? 'গতকাল ১৪টি বিক্রি, মোট ৳১২,৪০০; লাভ ৳২,১৮০ (গত সপ্তাহের একই দিনে লাভ ছিল ৳১,৮৭০ — ১৭% বেশি)।'
                  : 'Yesterday: 14 sales, ৳12,400 in total; profit ৳2,180 (same day last week profit was ৳1,870 — 17% more).'
            },
            {
              'key': 'dues',
              'text': bn
                  ? '৬জনের কাছে মোট ৳৯,৩০০ বাকি — আজ তাগাদা দিন: Karim ৳১,২০০ (আজ তাগাদার দিন), Selim ৳৩,৫০০।'
                  : '6 customer(s) owe ৳9,300 — remind today: Karim ৳1,200 (reminder due today), Selim ৳3,500.'
            },
            {
              'key': 'stock',
              'text': bn
                  ? '২টি পণ্য শেষ হচ্ছে: Dal (শেষ), Tel 1L (স্টক ৪, ~২ দিন চলবে)।'
                  : '2 product(s) are running out: Dal (out), Tel 1L (4 left, ~2 day(s)).'
            },
            {
              'key': 'followups',
              'text': bn ? 'আজ ১টি CRM ফলো-আপ: Nasir Traders।' : '1 CRM follow-up(s) due today: Nasir Traders.'
            },
            {
              'key': 'cash',
              'text': bn
                  ? 'গতকাল ক্যাশ ৳২০০ কম: হিসাবে ৳৮,৪০০, গোনা ৳৮,২০০।'
                  : 'Yesterday the cash was ৳200 short: books ৳8,400, counted ৳8,200.'
            },
          ]
        : mode == 'empty'
            ? [
                {
                  'key': 'cash',
                  'text': bn
                      ? 'গতকাল ক্যাশ গোনা (দিন বন্ধ) হয়নি — হিসাব অনুযায়ী বাক্সে থাকার কথা ৳০।'
                      : 'Yesterday the cash was not counted (day not closed) — the books say ৳0 should be in the box.'
                }
              ]
            : [],
    'actions': data
        ? [
            {
              'kind': 'tagada',
              'tool': 'khata.tagada',
              'target': 'Karim',
              'approval': true,
              'args': {'customer': 'Karim', 'channel': 'whatsapp'},
              'label': bn ? 'Karim-কে তাগাদা (৳১,২০০)' : 'Remind Karim (৳1,200)'
            },
            {
              'kind': 'reorder',
              'tool': 'supplier.reorder',
              'target': '',
              'approval': true,
              'args': {
                'items': [
                  {'product': 'Dal', 'qty': 6},
                  {'product': 'Tel 1L', 'qty': 24}
                ]
              },
              'label': bn ? 'সাপ্লায়ারকে অর্ডার (২টি পণ্য)' : 'Reorder from a supplier (2 products)'
            },
            {
              'kind': 'followup',
              'tool': 'crm.followup_task',
              'target': 'Nasir Traders',
              'approval': false,
              'args': {'lead': 'Nasir Traders', 'when': 'today'},
              'label': bn ? 'Nasir Traders — ফলো-আপ টাস্ক' : 'Nasir Traders — follow-up task'
            },
          ]
        : [],
    'suppliers': mode == 'no_supplier' ? [] : ['Mondol Traders', 'Hasan Wholesale'],
    'questions': [
      {'key': 'profit_today', 'text': bn ? 'আজ কত লাভ?' : "Today's profit?"},
      {'key': 'top_due', 'text': bn ? 'কার কাছে সবচেয়ে বেশি বাকি?' : 'Who owes me the most?'},
      {'key': 'running_out', 'text': bn ? 'কোন পণ্য শেষ হচ্ছে?' : 'What is running out?'},
      {'key': 'cash', 'text': bn ? 'কাল ক্যাশ মিলেছে?' : "Did yesterday's cash match?"},
    ],
    'cost': {
      'card_credits': 0,
      'rule_ok': true,
      'lines': bn
          ? [
              'এই কার্ড: AI ডাকা হয়নি — ০ ক্রেডিট, খরচ ৳০ (সব সংখ্যা আপনার খাতা থেকে)',
              'নিজের ভাষায় প্রশ্ন (AI): ৭ ক্রেডিট (৳৭)',
              'SMS তাগাদা (প্রতি SMS): ১ ক্রেডিট (৳১)',
            ]
          : [
              'This card: no AI call — 0 credits, ৳0 cost (every number from your books)',
              'A free-text question (AI): 7 credits (৳7)',
              'SMS due reminder (per SMS): 1 credit (৳1)',
            ],
    },
    'ai_used': false,
    'credits': 0,
  };
}

/// A bizops run: tagada waiting for approval, or done with the prepared
/// WhatsApp message.
Map<String, dynamic> boRunJson(String state, {bool bn = false, int id = 21}) {
  final base = acRunJson(state == 'done' ? 'done' : state, id: id, bn: bn, credits: 0,
      approvals: state == 'waiting_approval'
          ? [
              {
                ...acApprovalJson(id: 31, bn: bn, risk: 'external'),
                'title': bn ? 'Karim-কে বাকি ৳১,২০০-এর তাগাদা পাঠাবেন?' : 'Send Karim a due reminder (৳1,200)?',
              }
            ]
          : null);
  return {
    ...base,
    'topic': 'business',
    'topic_label': bn ? 'ব্যবসা' : 'Business',
    'goal': bn ? 'Karim-কে তাগাদা' : 'Remind Karim',
    'answer': state == 'done'
        ? (bn
            ? 'Karim-এর জন্য তাগাদা মেসেজ (বাকি ৳১,২০০) তৈরি — WhatsApp খুলে আপনি নিজে পাঠান।'
            : 'Due reminder for Karim (৳1,200) is ready — open WhatsApp and send it yourself.')
        : '',
    'shares': state == 'done'
        ? [
            {
              'tool': 'khata.tagada',
              'text': bn ? 'আসসালামু আলাইকুম Karim ভাই, আপনার বাকি ৳১,২০০।' : 'Hello Karim, your due is ৳1,200.',
              'url': 'https://wa.me/8801811223344?text=x'
            }
          ]
        : [],
  };
}

/// mode: data | empty | no_business | no_supplier | off | fail | offline
class FakeBizBrief implements BizBriefSource {
  FakeBizBrief(this.mode, {this.bn = false});
  final String mode;
  final bool bn;
  final acts = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> brief() async {
    if (mode == 'off') {
      throw ApiException('This feature is not available yet.', 403, null, null,
          {'error': 'feature_off'});
    }
    if (mode == 'fail') throw ApiException('boom', 500);
    if (mode == 'offline') throw const SocketException('down');
    return boCardJson(bn: bn, mode: mode);
  }

  @override
  Future<Map<String, dynamic>> act(Map<String, dynamic> body) async {
    acts.add(body);
    if (body['kind'] == 'followup' || body['kind'] == 'question') {
      return boRunJson('done', bn: bn)..['shares'] = [];
    }
    return boRunJson('waiting_approval', bn: bn);
  }
}

/// The run panel's server after a card tap: approve -> done with a share.
class BoAgentFake extends FakeAgentCore {
  BoAgentFake({super.bn}) : super('approval');

  @override
  Future<Map<String, dynamic>> run(int id) async =>
      decided ? boRunJson('done', bn: bn, id: id) : boRunJson('waiting_approval', bn: bn, id: id);

  @override
  Future<Map<String, dynamic>> decide(int id, String decision) async {
    calls.add('decide:$id:$decision');
    decided = true;
    return {
      'approval': {...acApprovalJson(id: id, bn: bn, risk: 'external'), 'status': 'approved'},
      'run': boRunJson('done', bn: bn),
    };
  }
}
