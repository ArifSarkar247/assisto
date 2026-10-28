// tagada2 — the tagada2 server faked in its real response shape (shared by
// tagada2_test.dart and tagada2_shots_test.dart).
import 'package:assisto/api.dart';

import 'fake_api.dart';
import 'fake_khata.dart' show fmtPair;

Map<String, String> tg2Pr(String bn, String en) => {'bn': bn, 'en': en};

Map<String, dynamic> tg2Wallet({int allowance = 30, int pack = 0, bool low = false}) =>
    {
      'ready': true,
      'available': true,
      'owner_only': false,
      'allowance_total': 30,
      'allowance_left': allowance,
      'pack_left': pack,
      'parts_left': allowance + pack,
      'balance': allowance + pack,
      'low': low,
      'packs_on_sale': false,
    };

Map<String, dynamic> tg2Rem(int id, String name, String phone,
        {bool assisto = false,
        bool reachable = true,
        bool today = false,
        int parts = 2,
        String invite = 'none'}) =>
    {
      'party_id': id,
      'name': name,
      'phone': phone,
      'phone_ok': phone.isNotEmpty,
      'balance_poisha': 150000,
      'balance_display': fmtPair(150000),
      'message': 'Hello $name. Your due at Rahim Store is 1500.',
      'wa_url': phone.isEmpty ? '' : 'https://wa.me/88$phone?text=x',
      'sms_uri': phone.isEmpty ? '' : 'sms:+88$phone?body=x',
      'sms_segments': parts,
      'sms_credits': parts,
      'assisto_user': assisto,
      'reachable': reachable,
      'sent_today': today,
      'sent_today_channel': today ? 'whatsapp' : '',
      'route': assisto ? 'assisto' : 'share',
      'sms_parts': parts,
      'invite_status': invite,
    };

/// The tagada2 server, faked in its real response shape.
class Tg2Api extends FakeApi {
  Tg2Api({super.lang = 'en'});
  final posts = <String, List<Map<String, dynamic>>>{};
  List<Map<String, dynamic>> reminders = [];
  Map<String, dynamic> wallet = tg2Wallet();
  Map<String, dynamic>? balance;
  Map<String, dynamic>? dues;
  Map<String, dynamic>? shop;
  bool failDues = false;
  final chat = <Map<String, dynamic>>[];

  void _log(String path, Map<String, dynamic> body) =>
      posts.putIfAbsent(path.split('?').first, () => []).add(body);

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/business/sms/balance')) return balance ?? {};
    if (path == '/me/dues') {
      if (failDues) throw ApiException('server', 500);
      return dues ?? {};
    }
    if (RegExp(r'^/me/dues/\d+/chat').hasMatch(path)) {
      return {'messages': chat};
    }
    if (RegExp(r'^/me/dues/\d+$').hasMatch(path)) return shop ?? {};
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path == '/business/khata/tagada/bulk') {
      _log(path, body);
      return {
        'reminders': [for (final r in reminders) Map<String, dynamic>.from(r)],
        'skipped': const [],
        'sms': wallet,
      };
    }
    if (path.startsWith('/me/dues/') && path.endsWith('/prefs')) {
      _log(path, body);
      return {
        'muted': body['muted'] ?? shop?['muted'] ?? false,
        'blocked': body['blocked'] ?? shop?['blocked'] ?? false,
      };
    }
    return super.postJson(path, body);
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path.startsWith('/business/khata/tagada/send/')) {
      _log(path, body);
      final ch = '${body['channel']}';
      return {
        'ok': true,
        'channel': ch,
        if (ch == 'whatsapp') 'url': 'https://wa.me/8801712345678?text=x',
        'sms': wallet,
        '_status': 200,
      };
    }
    if (RegExp(r'^/me/dues/\d+/chat$').hasMatch(path)) {
      _log(path, body);
      final m = {
        'id': chat.length + 1,
        'from': 'customer',
        'kind': 'text',
        'text': body['text'],
        'at': '2026-10-28T10:00:00+06:00',
        'read': false,
      };
      return {'ok': true, 'message': m, '_status': 200};
    }
    return super.postJsonRaw(path, body);
  }
}

