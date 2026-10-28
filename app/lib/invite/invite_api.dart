import '../api.dart';

/// invite-join client (backend core/views_invite_join.py). Every call here
/// returns the raw reply map (never throws on 4xx — `_status`, `ok`,
/// `reason`, `detail` describe the failure); a network failure throws, and
/// the screens turn that into the offline state with Retry.
///
///   POST /circle/invite/code   {relation, label?, max_uses?}
///   GET  /circle/invite/sent
///   POST /circle/invite/<id>/resend | /revoke
///   POST /invite/preview       {code}
///   POST /invite/join          {code, via}
///   POST /invite/signup        {code, name, phone?, email?, otp_proof?, via, device_id}
///   POST /auth/set-password    {password}
abstract class InviteBackend {
  Future<Map<String, dynamic>> preview(String code);
  Future<Map<String, dynamic>> join(String code, {String via = 'link'});
  Future<Map<String, dynamic>> signup({
    required String code,
    required String name,
    String phone = '',
    String email = '',
    String? otpProof,
    String via = 'link',
    String deviceId = '',
  });
  Future<Map<String, dynamic>> create(
      {String relation = 'friend', String label = '', int maxUses = 1});
  Future<List<Map<String, dynamic>>> sent();
  Future<Map<String, dynamic>> resend(int id);
  Future<Map<String, dynamic>> revoke(int id);
}

class ApiInviteBackend implements InviteBackend {
  final ApiClient api;
  ApiInviteBackend(this.api);

  @override
  Future<Map<String, dynamic>> preview(String code) =>
      api.postJsonRaw('/invite/preview', {'code': code});

  @override
  Future<Map<String, dynamic>> join(String code, {String via = 'link'}) =>
      api.postJsonRaw('/invite/join', {'code': code, 'via': via});

  @override
  Future<Map<String, dynamic>> signup({
    required String code,
    required String name,
    String phone = '',
    String email = '',
    String? otpProof,
    String via = 'link',
    String deviceId = '',
  }) =>
      api.postJsonRaw('/invite/signup', {
        'code': code,
        'name': name,
        if (phone.isNotEmpty) 'phone': phone,
        if (email.isNotEmpty) 'email': email,
        if (otpProof != null) 'otp_proof': otpProof,
        'via': via,
        if (deviceId.isNotEmpty) 'device_id': deviceId,
      });

  @override
  Future<Map<String, dynamic>> create(
          {String relation = 'friend', String label = '', int maxUses = 1}) =>
      api.postJsonRaw('/circle/invite/code', {
        'relation': relation,
        if (label.isNotEmpty) 'label': label,
        'max_uses': maxUses,
      });

  @override
  Future<List<Map<String, dynamic>>> sent() async {
    final r = await api.getJson('/circle/invite/sent');
    return ((r['results'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  @override
  Future<Map<String, dynamic>> resend(int id) =>
      api.postJsonRaw('/circle/invite/$id/resend');

  @override
  Future<Map<String, dynamic>> revoke(int id) =>
      api.postJsonRaw('/circle/invite/$id/revoke');
}

/// True when a raw reply is a success.
bool inviteOk(Map<String, dynamic> r) {
  final st = (r['_status'] as int?) ?? 200;
  return st >= 200 && st < 300 && r['ok'] != false;
}
