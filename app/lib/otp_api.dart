import 'api.dart';
import 'models.dart';

/// o1-otp — SMS one-time-code client. Backend contract (core/views_otp.py):
///   GET  /auth/otp/status  -> {sms_enabled, password_only_signup, code_length,
///                              expires_in, resend_in}
///   POST /auth/otp/request {phone?, purpose} -> {ok, phone_masked, expires_in,
///                              resend_in} | {ok:false, reason, retry_after?}
///   POST /auth/otp/verify  {phone?, purpose, code} -> {ok, otp_proof}
///                              | {ok:false, reason, attempts_left?, retry_after?}
///   POST /auth/otp/login   {phone, otp_proof} -> {token, user}
///   POST /auth/otp/reset   {phone, otp_proof, password} -> {ok, message}
///
/// smsotp — email backup (same codes, same limits; verify via /auth/otp/verify):
///   POST /auth/otp/email/request {purpose, phone? | email?} -> {ok, channel,
///                              email_masked?, prefer_sms} | {ok:false, reason}
///   POST /auth/otp/email/confirm {email, code} -> {ok, email, verified}
///   GET  /auth/otp/email/me -> {email, verified, email_enabled}
///
/// Purposes: signup, login, password_reset, delete_account, section8.
/// Screens depend on [OtpBackend] (not ApiClient) so widget tests can inject a
/// fake without any network.

class OtpResult {
  final bool ok;
  final int status;
  final String reason; // '' when ok
  final String message; // server-localized human text (may be empty)
  final Map<String, dynamic> data;
  const OtpResult(
      {required this.ok,
      required this.status,
      this.reason = '',
      this.message = '',
      this.data = const {}});

  int? get retryAfter => _int(data['retry_after']);
  int? get attemptsLeft => _int(data['attempts_left']);
  int? get resendIn => _int(data['resend_in']);
  String get phoneMasked => '${data['phone_masked'] ?? ''}';
  // smsotp: email backup
  String get emailMasked => '${data['email_masked'] ?? ''}';
  bool get emailAvailable =>
      data['email_enabled'] == true || data['email_fallback'] == true;
  bool get emailOff => reason == 'email_not_configured';
  String? get proof => data['otp_proof'] as String?;
  bool get smsOff =>
      reason == 'sms_not_configured' || data['sms_enabled'] == false;

  static int? _int(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));

  factory OtpResult.fromRaw(Map<String, dynamic> raw) {
    final st = (raw['_status'] as int?) ?? 200;
    final ok = st >= 200 && st < 300 && raw['ok'] != false;
    return OtpResult(
      ok: ok,
      status: st,
      reason: ok ? '' : '${raw['reason'] ?? 'error'}',
      message: '${raw['message'] ?? raw['detail'] ?? ''}',
      data: raw,
    );
  }

  /// A network failure (no response at all).
  static const OtpResult network =
      OtpResult(ok: false, status: 0, reason: 'network');
}

class OtpStatus {
  final bool smsEnabled;
  final bool passwordOnlySignup;
  final int codeLength;
  final int resendIn;
  final bool emailEnabled; // smsotp
  const OtpStatus(
      {this.smsEnabled = false,
      this.passwordOnlySignup = true,
      this.codeLength = 6,
      this.resendIn = 60,
      this.emailEnabled = false});
}

/// smsotp — the signed-in user's email for codes.
class EmailState {
  final String email;
  final bool verified;
  final bool enabled; // the server can send email codes at all
  const EmailState({this.email = '', this.verified = false, this.enabled = false});
}

/// smsotp — purposes whose code may also be delivered by email.
const otpEmailPurposes = {
  'login', 'password_reset', 'delete_account', 'section8',
  'vault_reset', // vault100
};

abstract class OtpBackend {
  Future<OtpStatus> status();
  Future<OtpResult> request(String purpose, {String? phone});
  Future<OtpResult> verify(String purpose, String code, {String? phone});
  Future<({String token, AppUser user})?> loginWithProof(
      String phone, String proof);
  Future<OtpResult> resetPassword(String phone, String proof, String password);

  // smsotp — email backup
  Future<OtpResult> requestEmail(String purpose, {String? phone, String? email});
  Future<OtpResult> confirmEmail(String email, String code);
  Future<EmailState> emailState();
}

/// Real implementation over [ApiClient.postJsonRaw].
class ApiOtpBackend implements OtpBackend {
  final ApiClient api;
  ApiOtpBackend(this.api);

  Future<OtpResult> _post(String path, Map<String, dynamic> body) async {
    try {
      return OtpResult.fromRaw(await api.postJsonRaw(path, body));
    } catch (_) {
      return OtpResult.network;
    }
  }

  @override
  Future<OtpStatus> status() async {
    try {
      final j = await api.getJson('/auth/otp/status');
      return OtpStatus(
        smsEnabled: j['sms_enabled'] == true,
        passwordOnlySignup: j['password_only_signup'] != false,
        codeLength: (j['code_length'] as num?)?.toInt() ?? 6,
        resendIn: (j['resend_in'] as num?)?.toInt() ?? 60,
        emailEnabled: j['email_enabled'] == true,
      );
    } catch (_) {
      // Unknown -> behave like before OTP existed; the server still enforces.
      return const OtpStatus();
    }
  }

  @override
  Future<OtpResult> request(String purpose, {String? phone}) =>
      _post('/auth/otp/request', {
        'purpose': purpose,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
      });

  @override
  Future<OtpResult> verify(String purpose, String code, {String? phone}) =>
      _post('/auth/otp/verify', {
        'purpose': purpose,
        'code': code,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
      });

  @override
  Future<({String token, AppUser user})?> loginWithProof(
      String phone, String proof) async {
    final r = await _post('/auth/otp/login', {'phone': phone, 'otp_proof': proof});
    if (!r.ok || r.data['token'] == null || r.data['user'] is! Map) return null;
    return (
      token: r.data['token'] as String,
      user: AppUser.fromJson(
          Map<String, dynamic>.from(r.data['user'] as Map)),
    );
  }

  @override
  Future<OtpResult> resetPassword(String phone, String proof, String password) =>
      _post('/auth/otp/reset',
          {'phone': phone, 'otp_proof': proof, 'password': password});

  @override
  Future<OtpResult> requestEmail(String purpose, {String? phone, String? email}) =>
      _post('/auth/otp/email/request', {
        'purpose': purpose,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (email != null && email.isNotEmpty) 'email': email,
      });

  @override
  Future<OtpResult> confirmEmail(String email, String code) =>
      _post('/auth/otp/email/confirm', {'email': email, 'code': code});

  @override
  Future<EmailState> emailState() async {
    try {
      final j = await api.getJson('/auth/otp/email/me');
      return EmailState(
          email: '${j['email'] ?? ''}',
          verified: j['verified'] == true,
          enabled: j['email_enabled'] == true);
    } catch (_) {
      return const EmailState();
    }
  }
}

/// Client-side email shape check (the server is the authority).
bool looksLikeEmail(String raw) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(raw.trim());

/// Client-side Bangladeshi mobile check (server is the authority):
/// 01XXXXXXXXX, +8801XXXXXXXXX, 8801XXXXXXXXX.
bool looksLikeBdMobile(String raw) {
  var s = raw.replaceAll(RegExp(r'[\s\-().]'), '');
  if (s.startsWith('+')) s = s.substring(1);
  if (s.startsWith('00')) s = s.substring(2);
  if (s.startsWith('880')) {
    s = s.substring(3);
  } else if (s.startsWith('0')) {
    s = s.substring(1);
  }
  return RegExp(r'^1[3-9]\d{8}$').hasMatch(s);
}
