import 'package:assisto/models.dart';
import 'package:assisto/otp_api.dart';

/// o1-otp — in-memory OTP backend for widget tests + the screenshot gallery.
/// The "right" code is [goodCode]; anything else is invalid (attempts count
/// down, then locked). [smsEnabled]=false simulates no gateway connected.
class FakeOtpBackend implements OtpBackend {
  bool smsEnabled;
  bool passwordOnlySignup;
  String goodCode;
  int attemptsLeft;
  bool loginSucceeds;
  final List<String> calls = [];
  String? lastPurpose;
  String? lastPhone;
  String? lastResetPassword;

  FakeOtpBackend({
    this.smsEnabled = true,
    this.passwordOnlySignup = true,
    this.goodCode = '123456',
    this.attemptsLeft = 5,
    this.loginSucceeds = false,
  });

  @override
  Future<OtpStatus> status() async {
    calls.add('status');
    return OtpStatus(
        smsEnabled: smsEnabled, passwordOnlySignup: passwordOnlySignup);
  }

  @override
  Future<OtpResult> request(String purpose, {String? phone}) async {
    calls.add('request:$purpose');
    lastPurpose = purpose;
    lastPhone = phone;
    if (!smsEnabled) {
      return OtpResult.fromRaw(const {
        '_status': 503,
        'ok': false,
        'reason': 'sms_not_configured',
        'sms_enabled': false,
      });
    }
    return OtpResult.fromRaw(const {
      '_status': 200,
      'ok': true,
      'phone_masked': '017•••••678',
      'expires_in': 300,
      'resend_in': 60,
    });
  }

  @override
  Future<OtpResult> verify(String purpose, String code, {String? phone}) async {
    calls.add('verify:$purpose:$code');
    if (code == goodCode) {
      return OtpResult.fromRaw({
        '_status': 200,
        'ok': true,
        'otp_proof': 'proof-$purpose',
      });
    }
    attemptsLeft -= 1;
    if (attemptsLeft <= 0) {
      return OtpResult.fromRaw(const {
        '_status': 423,
        'ok': false,
        'reason': 'locked',
        'retry_after': 1800,
      });
    }
    return OtpResult.fromRaw({
      '_status': 400,
      'ok': false,
      'reason': 'invalid_code',
      'attempts_left': attemptsLeft,
    });
  }

  @override
  Future<({String token, AppUser user})?> loginWithProof(
      String phone, String proof) async {
    calls.add('login:$phone:$proof');
    if (!loginSucceeds) return null;
    return (
      token: 'tok',
      user: AppUser(
          id: 1,
          name: 'A',
          phone: phone,
          email: '',
          autonomyLevel: 2,
          language: 'en'),
    );
  }

  @override
  Future<OtpResult> resetPassword(
      String phone, String proof, String password) async {
    calls.add('reset:$phone:$proof');
    lastResetPassword = password;
    return OtpResult.fromRaw(const {'_status': 200, 'ok': true});
  }
}
