// bizai: fake server for test/bizai_test.dart + gallery shots (bizai_shots.dart).
// bn=true gives Bangla shop data (the launch Bangla sweep reads bn shots).
import 'package:assisto/bizai/bizai_source.dart';

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

