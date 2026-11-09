import 'api.dart';
import 'otp_api.dart' show OtpResult;

/// recovery (owner order Part 8) — Account & security client.
/// Backend contract (core/views_account_security.py):
///   GET  /account/security -> overview (phone, email, devices, nudge, requests)
///   POST /account/security/password {current_password, new_password} -> {ok, token?}
///   POST /account/security/devices/<id>/signout
///   POST /account/security/devices/signout-others -> {ok, token?}
///   POST /account/security/nudge {action: later|added}
///   POST /account/security/recovery/<id>/cancel
///   POST /account/security/recovery/family/<id> {decision: confirm|deny}
///   POST /auth/recovery/options {phone} -> {sms, email, email_masked}
///   POST /auth/recovery/support/start|status|complete
/// Screens depend on [AccountSecurityBackend] so widget tests inject a fake.

class SignedInDevice {
  final String id;
  final String kind; // device | legacy
  final String name;
  final DateTime? lastSeen;
  final DateTime? created;
  final bool current;
  const SignedInDevice(
      {required this.id,
      this.kind = 'device',
      this.name = '',
      this.lastSeen,
      this.created,
      this.current = false});

  factory SignedInDevice.fromJson(Map<String, dynamic> j) => SignedInDevice(
        id: '${j['id'] ?? ''}',
        kind: '${j['kind'] ?? 'device'}',
        name: '${j['name'] ?? ''}',
        lastSeen: DateTime.tryParse('${j['last_seen_at'] ?? ''}'),
        created: DateTime.tryParse('${j['created_at'] ?? ''}'),
        current: j['current'] == true,
      );
}

class RecoveryAsk {
  final int id;
  final String name; // family: whose account
  final String contactMasked; // owner: the new number they gave
  final DateTime? holdUntil;
  const RecoveryAsk(
      {required this.id, this.name = '', this.contactMasked = '', this.holdUntil});

  factory RecoveryAsk.fromJson(Map<String, dynamic> j) => RecoveryAsk(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        contactMasked: '${j['contact_masked'] ?? ''}',
        holdUntil: DateTime.tryParse('${j['hold_until'] ?? ''}'),
      );
}

class AccountSecurity {
  final String phone;
  final bool phoneVerified;
  final String email;
  final bool emailVerified;
  final bool emailEnabled;
  final bool hasPassword;
  final bool googleAvailable;
  final List<SignedInDevice> devices;
  final bool nudge;
  final String blockedReason; // '' | identity_locked | identity_cooldown
  final List<RecoveryAsk> myRecoveryRequests;
  final List<RecoveryAsk> familyRequests;
  const AccountSecurity({
    this.phone = '',
    this.phoneVerified = false,
    this.email = '',
    this.emailVerified = false,
    this.emailEnabled = false,
    this.hasPassword = true,
    this.googleAvailable = false,
    this.devices = const [],
    this.nudge = false,
    this.blockedReason = '',
    this.myRecoveryRequests = const [],
    this.familyRequests = const [],
  });

  factory AccountSecurity.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(Object? v, T Function(Map<String, dynamic>) f) => v is List
        ? v.whereType<Map>().map((e) => f(Map<String, dynamic>.from(e))).toList()
        : <T>[];
    final g = j['google'];
    final n = j['nudge'];
    return AccountSecurity(
      phone: '${j['phone'] ?? ''}',
      phoneVerified: j['phone_verified'] == true,
      email: '${j['email'] ?? ''}',
      emailVerified: j['email_verified'] == true,
      emailEnabled: j['email_enabled'] == true,
      hasPassword: j['has_password'] != false,
      googleAvailable: g is Map && g['available'] == true,
      devices: list(j['devices'], SignedInDevice.fromJson),
      nudge: n is Map && n['show'] == true,
      blockedReason: '${j['email_change_blocked'] ?? ''}'.isNotEmpty
          ? '${j['email_change_blocked']}'
          : '${j['phone_change_blocked'] ?? ''}',
      myRecoveryRequests: list(j['recovery_requests'], RecoveryAsk.fromJson),
      familyRequests: list(j['family_requests'], RecoveryAsk.fromJson),
    );
  }
}

class RecoveryOptions {
  final bool sms;
  final bool email;
  final String emailMasked;
  const RecoveryOptions({this.sms = false, this.email = false, this.emailMasked = ''});
}

abstract class AccountSecurityBackend {
  Future<AccountSecurity?> load();
  Future<OtpResult> changePassword(String current, String next);
  Future<OtpResult> signOutDevice(String id);
  Future<OtpResult> signOutOthers();
  Future<void> nudge(String action);
  Future<OtpResult> cancelRecovery(int id);
  Future<OtpResult> familyDecide(int id, bool confirm);
  Future<RecoveryOptions?> options(String phone);
  Future<OtpResult> supportStart(Map<String, dynamic> body);
  Future<OtpResult> supportStatus(String ref, String secret);
  Future<OtpResult> supportComplete(
      String ref, String secret, String proof, String password);
}

class ApiAccountSecurityBackend implements AccountSecurityBackend {
  final ApiClient api;
  ApiAccountSecurityBackend(this.api);

  Future<OtpResult> _post(String path, [Map<String, dynamic> body = const {}]) async {
    try {
      return OtpResult.fromRaw(await api.postJsonRaw(path, body));
    } catch (_) {
      return OtpResult.network;
    }
  }

  @override
  Future<AccountSecurity?> load() async {
    try {
      return AccountSecurity.fromJson(await api.getJson('/account/security'));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<OtpResult> changePassword(String current, String next) =>
      _post('/account/security/password',
          {'current_password': current, 'new_password': next});

  @override
  Future<OtpResult> signOutDevice(String id) =>
      _post('/account/security/devices/${Uri.encodeComponent(id)}/signout');

  @override
  Future<OtpResult> signOutOthers() => _post('/account/security/devices/signout-others');

  @override
  Future<void> nudge(String action) async {
    await _post('/account/security/nudge', {'action': action});
  }

  @override
  Future<OtpResult> cancelRecovery(int id) =>
      _post('/account/security/recovery/$id/cancel');

  @override
  Future<OtpResult> familyDecide(int id, bool confirm) =>
      _post('/account/security/recovery/family/$id',
          {'decision': confirm ? 'confirm' : 'deny'});

  @override
  Future<RecoveryOptions?> options(String phone) async {
    final r = await _post('/auth/recovery/options', {'phone': phone});
    if (!r.ok) return null;
    return RecoveryOptions(
        sms: r.data['sms'] == true,
        email: r.data['email'] == true,
        emailMasked: '${r.data['email_masked'] ?? ''}');
  }

  @override
  Future<OtpResult> supportStart(Map<String, dynamic> body) =>
      _post('/auth/recovery/support/start', body);

  @override
  Future<OtpResult> supportStatus(String ref, String secret) =>
      _post('/auth/recovery/support/status', {'ref': ref, 'secret': secret});

  @override
  Future<OtpResult> supportComplete(
          String ref, String secret, String proof, String password) =>
      _post('/auth/recovery/support/complete',
          {'ref': ref, 'secret': secret, 'otp_proof': proof, 'password': password});
}
