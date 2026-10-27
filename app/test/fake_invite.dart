// invite-join — in-memory InviteBackend for widget tests + the gallery.
import 'package:assisto/invite/invite_api.dart';

class FakeInviteBackend implements InviteBackend {
  /// preview state: ok | expired | used | invalid | self | already | offline
  String state;
  bool smsEnabled;
  String inviter;
  final List<String> calls = [];
  Map<String, dynamic>? lastSignup;
  String signupReason; // '' = success
  List<Map<String, dynamic>> sentRows;

  FakeInviteBackend({
    this.state = 'ok',
    this.smsEnabled = false,
    this.inviter = 'Rahim',
    this.signupReason = '',
    List<Map<String, dynamic>>? sent,
  }) : sentRows = sent ?? [];

  static const _detail = {
    'expired': 'This invite has expired. Ask them to send it again.',
    'used': 'This invite was already used. Ask for a new link.',
    'invalid': "This invite link isn't valid. Ask the person who sent it for a new one.",
    'self': "This is your own invite — send it to the person you want to add.",
    'circle_full': 'This circle is full — no one else can join right now.',
    'has_account': 'This number already has an account — sign in, then open the link again.',
  };

  Map<String, dynamic> _member() => {
        'id': 77, 'name': inviter, 'display_name': inviter, 'state': 'accepted',
        'relation': 'brother',
      };

  @override
  Future<Map<String, dynamic>> preview(String code) async {
    calls.add('preview:$code');
    if (state == 'offline') throw Exception('offline');
    final ok = state == 'ok' || state == 'already';
    return {
      '_status': state == 'invalid' ? 404 : 200,
      'ok': ok,
      'state': state,
      if (!ok) 'detail': _detail[state] ?? '',
      'inviter_name': inviter,
      'inviter_initial': inviter.isEmpty ? 'A' : inviter.substring(0, 1),
      'sms_enabled': smsEnabled,
      'email_enabled': false,
      'signup_open': true,
    };
  }

  @override
  Future<Map<String, dynamic>> join(String code, {String via = 'link'}) async {
    calls.add('join:$code:$via');
    return {'_status': 200, 'ok': true, 'already': state == 'already',
            'member': _member(), 'inviter': {'name': inviter}};
  }

  @override
  Future<Map<String, dynamic>> signup({
    required String code,
    required String name,
    String phone = '',
    String email = '',
    String? otpProof,
    String via = 'link',
    String deviceId = '',
  }) async {
    lastSignup = {'code': code, 'name': name, 'phone': phone, 'email': email,
                  'otp_proof': otpProof, 'via': via};
    calls.add('signup:$code');
    if (signupReason.isNotEmpty) {
      return {'_status': 409, 'ok': false, 'reason': signupReason,
              'detail': _detail[signupReason] ?? signupReason};
    }
    // a token makes AppState try secure storage; tests stop here via onJoined
    return {'_status': 201, 'ok': true, 'token': 'tok-123',
            'user': {'id': 9, 'name': name, 'phone': phone, 'email': email,
                     'autonomy_level': 2, 'language': 'en'},
            'member': _member(), 'inviter': {'name': inviter},
            'has_password': false};
  }

  @override
  Future<Map<String, dynamic>> create(
      {String relation = 'friend', String label = '', int maxUses = 1}) async {
    calls.add('create:$relation:$label:$maxUses');
    return {'_status': 201, 'ok': true, 'id': 5, 'code': 'K7QF2M9PAB',
            'link': 'https://lifeassisto.com/i/K7QF2M9PAB',
            'share_text': 'Rahim আপনাকে Assisto-তে “আমার সার্কেল”-এ ডেকেছেন — চ্যাট, কল আর পরিবারের নিরাপত্তা এক অ্যাপে। যোগ দিতে ট্যাপ করুন:\nhttps://lifeassisto.com/i/K7QF2M9PAB',
            'max_uses': maxUses, 'expires_at': '2026-11-03T10:00:00Z'};
  }

  @override
  Future<List<Map<String, dynamic>>> sent() async {
    calls.add('sent');
    if (state == 'offline') throw Exception('offline');
    return sentRows;
  }

  @override
  Future<Map<String, dynamic>> resend(int id) async {
    calls.add('resend:$id');
    return {'_status': 200, 'ok': true, 'share_text': 'again'};
  }

  @override
  Future<Map<String, dynamic>> revoke(int id) async {
    calls.add('revoke:$id');
    return {'_status': 200, 'ok': true};
  }
}

List<Map<String, dynamic>> fakeSentRows(String lang) => [
      {'id': 1, 'label': lang == 'bn' ? 'আম্মু' : 'Ammu', 'status': 'joined',
       'joined': [{'name': lang == 'bn' ? 'নাসিমা' : 'Nasima'}], 'share_text': 'x'},
      {'id': 2, 'label': lang == 'bn' ? 'ছোট ভাই' : 'Little brother', 'status': 'waiting',
       'joined': [], 'share_text': 'x'},
      {'id': 3, 'label': '', 'status': 'expired', 'joined': [], 'share_text': 'x'},
    ];
