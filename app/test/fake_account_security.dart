// recovery — in-memory Account & security backend for widget tests + the
// screenshot gallery (no network).
import 'package:assisto/account_security_api.dart';
import 'package:assisto/otp_api.dart';
import 'package:assisto/screens/account_recovery_screens.dart';

class FakeAccountSecurity implements AccountSecurityBackend {
  AccountSecurity? state;
  bool emailOnAccount;
  bool smsOn;
  String supportState;
  final List<String> calls = [];
  Map<String, dynamic>? lastStart;

  FakeAccountSecurity({
    AccountSecurity? state,
    this.emailOnAccount = true,
    this.smsOn = true,
    this.supportState = 'pending',
  }) : state = state ?? sample();

  static AccountSecurity sample({bool alerts = false, bool email = false}) => AccountSecurity(
        phone: '+8801712345678',
        phoneVerified: true,
        email: email ? 'rahim@example.com' : '',
        emailVerified: email,
        emailEnabled: true,
        hasPassword: true,
        devices: [
          SignedInDevice(
              id: 's1', name: 'Realme Narzo', current: true, lastSeen: DateTime(2026, 11, 3, 9)),
          SignedInDevice(id: 's2', name: 'Samsung Galaxy', lastSeen: DateTime(2026, 11, 1, 20, 15)),
          SignedInDevice(id: 'legacy', kind: 'legacy', created: DateTime(2026, 10, 2, 8)),
        ],
        nudge: !email,
        myRecoveryRequests: alerts
            ? [RecoveryAsk(id: 7, contactMasked: '+88016••••••04', holdUntil: DateTime(2026, 11, 5, 10))]
            : const [],
        familyRequests: alerts ? const [RecoveryAsk(id: 9, name: 'Karim Ahmed')] : const [],
      );

  OtpResult _ok([Map<String, dynamic> extra = const {}]) =>
      OtpResult.fromRaw({'_status': 200, 'ok': true, ...extra});

  @override
  Future<AccountSecurity?> load() async {
    calls.add('load');
    return state;
  }

  @override
  Future<OtpResult> changePassword(String current, String next) async {
    calls.add('password:$current:$next');
    if (current != 'oldpass123') {
      return OtpResult.fromRaw(const {
        '_status': 400,
        'ok': false,
        'reason': 'wrong_password',
        'message': "Your current password didn't match."
      });
    }
    return _ok({'token': 'rotated-token'});
  }

  @override
  Future<OtpResult> signOutDevice(String id) async {
    calls.add('signout:$id');
    final s = state!;
    state = AccountSecurity(
        phone: s.phone,
        phoneVerified: s.phoneVerified,
        email: s.email,
        emailVerified: s.emailVerified,
        devices: s.devices.where((d) => d.id != id).toList());
    return _ok();
  }

  @override
  Future<OtpResult> signOutOthers() async {
    calls.add('signout-others');
    final s = state!;
    state = AccountSecurity(
        phone: s.phone,
        phoneVerified: s.phoneVerified,
        devices: s.devices.where((d) => d.current).toList());
    return _ok();
  }

  @override
  Future<void> nudge(String action) async => calls.add('nudge:$action');

  @override
  Future<OtpResult> cancelRecovery(int id) async {
    calls.add('cancel:$id');
    return _ok();
  }

  @override
  Future<OtpResult> familyDecide(int id, bool confirm) async {
    calls.add('family:$id:$confirm');
    return _ok();
  }

  @override
  Future<RecoveryOptions?> options(String phone) async {
    calls.add('options:$phone');
    return RecoveryOptions(
        sms: smsOn, email: emailOnAccount, emailMasked: emailOnAccount ? 'ra•••@example.com' : '');
  }

  @override
  Future<OtpResult> supportStart(Map<String, dynamic> body) async {
    calls.add('start');
    lastStart = body;
    return OtpResult.fromRaw(
        {'_status': 201, 'ok': true, 'ref': 'AB12CD34', 'secret': 's3cret', 'hold_hours': 48});
  }

  @override
  Future<OtpResult> supportStatus(String ref, String secret) async {
    calls.add('status:$ref');
    return _ok({
      'ref': ref,
      'state': supportState,
      'hold_until': '2026-11-05T10:00:00+06:00',
      'family_state': 'pending',
    });
  }

  @override
  Future<OtpResult> supportComplete(
      String ref, String secret, String proof, String password) async {
    calls.add('complete:$ref:$proof');
    return _ok({
      'token': 'new-token',
      'user': {'id': 1, 'name': 'Rahim', 'phone': '+8801611000004', 'email': ''}
    });
  }
}

class MemoryRefStore implements RecoveryRefStore {
  Map<String, String>? v;
  MemoryRefStore([this.v]);
  @override
  Future<Map<String, String>?> read() async => v;
  @override
  Future<void> write(Map<String, String> x) async => v = x;
  @override
  Future<void> clear() async => v = null;
}
