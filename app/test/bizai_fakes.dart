// bizai: fake server for test/bizai_test.dart + gallery shots (bizai_shots.dart).
// bn=true gives Bangla shop data (the launch Bangla sweep reads bn shots).
import 'package:assisto/bizai/bizai_source.dart';
import 'package:assisto/bizai/cctv_accuracy_screen.dart';
import 'package:assisto/bizai/winback_screen.dart';

const _discBn = 'এই দোকান উত্তর দিতে Assisto AI ব্যবহার করে। এখানের মেসেজ এন্ড-টু-এন্ড '
    'এনক্রিপ্টেড নয় — দোকান ও তার AI সহকারী দেখতে পান।';
const _shopBn = 'রূপা ফ্যাশন';
const _replyBn = 'পাঞ্জাবি: ১২০০ টাকা, স্টকে আছে';
const _disc = 'This shop uses Assisto AI to reply. Messages here are not end-to-end '
    'encrypted and are visible to the shop and its AI assistant.';

class FakeBizai implements BizaiSource {
  final bool bn;
  FakeBizai({this.bn = false});
  final List<Map<String, dynamic>> msgs = [];
  final List<String> sent = [];
  final List<String> files = [];
  bool person = false;
  bool fail = false;
  bool chatOk = true;
  List<Map<String, dynamic>> shops = [];
  Map<String, dynamic> out = {
    'empty': false,
    'total_bdt': '4000.00',
    'rows': [
      {'key': 'ai_orders', 'count': 3, 'bdt': '2700.00', 'how_bn': 'AI চ্যাটে নিজে যে অর্ডার নিয়েছে', 'how_en': 'Orders the AI took in chat'},
      {'key': 'customers_back', 'count': 1, 'bdt': '500.00', 'how_bn': 'অটো-মেসেজের পরে আবার কিনেছেন', 'how_en': 'Bought again'},
      {'key': 'dues_collected', 'count': 1, 'bdt': '0', 'how_bn': 'তাগাদার পরে খাতায় জমা', 'how_en': 'Paid'},
      {'key': 'losses_prevented', 'count': 1, 'bdt': '800.00', 'how_bn': 'ঝুঁকিপূর্ণ COD অর্ডার আটকানো', 'how_en': 'Held'},
    ],
  };
  Map<String, dynamic> link = {
    'code': '12-ab34cd56', 'url': 'https://lifeassisto.com/shop/12-ab34cd56', 'shop': 'Rupa',
    'app_chat_enabled': true, 'cod_risk_guard': true, 'ai_on': true,
  };
  int _id = 0;

  Map<String, dynamic> _m(String dir, String text, {bool ai = false}) =>
      {'id': ++_id, 'dir': dir, 'text': text, 'kind': 'text', 'ai': ai, 'image': '', 'voice': false, 'at': ''};

  @override
  Future<List<Map<String, dynamic>>> myShops() async {
    if (fail) throw Exception('offline');
    return shops;
  }

  @override
  Future<Map<String, dynamic>> shop(String code) async {
    if (fail) throw Exception('offline');
    return {'ok': chatOk, 'shop': bn ? _shopBn : 'Rupa Fashion', 'disclosure': bn ? _discBn : _disc,
      'disclosure_seen': msgs.isNotEmpty, 'with_person': person, 'own_shop': false,
      'messages': List.of(msgs)};
  }

  @override
  Future<Map<String, dynamic>> messages(String code, int after) async =>
      {'messages': msgs.where((m) => (m['id'] as int) > after).toList(), 'with_person': person};

  @override
  Future<Map<String, dynamic>> send(String code, String text) async {
    sent.add(text);
    final a = _m('in', text);
    final rows = [a];
    if (!person) rows.add(_m('out', bn ? _replyBn : 'Panjabi: 1200 taka, in stock', ai: true));
    msgs.addAll(rows);
    return {'ok': true, 'replied': !person, 'messages': rows, 'with_person': person};
  }

  @override
  Future<Map<String, dynamic>> sendFile(String code, String kind, String path, String mime) async {
    files.add('$kind:$mime');
    final rows = [_m('in', kind == 'image' ? '[image]' : 'Panjabi dam koto'), _m('out', 'Panjabi 1200', ai: true)];
    msgs.addAll(rows);
    return {'ok': true, 'messages': rows};
  }

  @override
  Future<Map<String, dynamic>> talkToPerson(String code) async {
    person = true;
    final r = _m('out', 'Okay — a person from the shop will reply in this chat.', ai: true);
    msgs.add(r);
    return {'ok': true, 'with_person': true, 'messages': [r]};
  }

  @override
  Future<Map<String, dynamic>> shopLink(int? businessId) async => link;
  @override
  Future<Map<String, dynamic>> saveShopLink(int? businessId, Map<String, dynamic> body) async =>
      link = {...link, ...body};
  @override
  Future<Map<String, dynamic>> outcomes(int? businessId, {int days = 7}) async {
    if (fail) throw Exception('offline');
    return out;
  }
}


// bizai pillar 2 — win-back fake
class FakeWinback implements WinbackSource {
  final bool bn;
  FakeWinback({this.bn = false});
  bool on = false;
  Map<String, dynamic>? lastApprove;
  int ai = 0;
  List<Map<String, dynamic>> _stages() => [
        for (final st in ['wb30', 'wb60', 'wb90'])
          {'stage': st, 'enabled': on, 'audience': st == 'wb30' ? 4 : 0,
           'draft': bn ? '{name}, অনেক দিন দেখা হয়নি! {shop}-এ আসুন।' : '{name}, we miss you at {shop}.'}
      ];
  @override
  Future<Map<String, dynamic>> segments() async => {
        'total': 6,
        'segments': [
          {'key': 'champion', 'count': 1, 'members': [
            {'name': bn ? 'করিম' : 'Karim', 'days': 3, 'spend_poisha': 360000,
             'high_value': true, 'interest': bn ? 'পাঞ্জাবি' : 'Panjabi'}]},
          {'key': 'at_risk_30', 'count': 4, 'members': []},
          {'key': 'lost_90', 'count': 1, 'members': []},
        ],
      };
  @override
  Future<Map<String, dynamic>> ladder() async => {'stages': _stages()};
  @override
  Future<Map<String, dynamic>> approve(Map<String, dynamic> body) async {
    lastApprove = body;
    on = body['on'] != false;
    return {'stages': _stages()};
  }
  @override
  Future<Map<String, dynamic>> aiDraft(String stage, String text, String lang) async {
    ai++;
    return {'ok': true, 'text': '{name}, come back to {shop} soon!'};
  }
}

// bizai pillar 5 — weekly report payload
Map<String, dynamic> fakeWeekly({bool bn = false, bool empty = false}) => {
      'attribution': {
        'posts': empty
            ? []
            : [
                {'ref': 'PAB2C', 'title': bn ? 'পোস্ট: পাঞ্জাবি' : 'Post: Panjabi', 'chats': 5,
                 'orders': 2, 'bdt': '2400.00'}
              ],
        'best': null,
      },
      'best_hours': [20],
      'weekly': {
        'lines': [bn ? 'এই সপ্তাহে বিক্রি: ১২টি, মোট ৳১৮৫০০।' : 'Sales this week: 12, total ৳18500.'],
        'plan': [bn ? 'পোস্টের সেরা সময়: ২০:০০।' : 'Best time to post: 20:00.'],
      },
    };

// bizai pillar 4 — CCTV accuracy fake
class FakeCctvAcc implements CctvAccuracySource {
  final List<String> calls = [];
  int sessions = 0;
  @override
  Future<Map<String, dynamic>> accuracy(int? siteId) async => {
        'reviews': {
          'per_type': {
            'person': {'tp': 8, 'fp': 2, 'fn': 1, 'precision': 0.8, 'recall': 0.889,
                       'events': 11, 'enough': false, 'meets_target': false},
          },
          'unreviewed': 3,
        },
        'live_tests': {
          'sessions': sessions,
          'per_type': sessions == 0
              ? {}
              : {'person': {'tp': 19, 'fp': 1, 'fn': 1, 'precision': 0.95, 'recall': 0.95,
                            'events': 21, 'enough': true, 'meets_target': true}},
        },
      };
  @override
  Future<Map<String, dynamic>> startTest(int siteId) async {
    calls.add('start');
    return {'id': 7};
  }
  @override
  Future<Map<String, dynamic>> mark(int testId, String kind) async {
    calls.add('mark:$kind');
    return {'id': testId};
  }
  @override
  Future<Map<String, dynamic>> stop(int testId) async {
    calls.add('stop');
    sessions = 1;
    return {'id': testId};
  }
  @override
  Future<void> missed(int siteId, String kind) async => calls.add('missed');
}
