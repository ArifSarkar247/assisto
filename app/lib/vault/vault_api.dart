// vault100 — HTTP surface for vault recovery + per-document expiry opt-out.
// Backend: core/vault_recovery.py, core/views.DocumentViewSet. The PIN, the
// recovery code and the offline key are NEVER part of any request here.
import '../api.dart';

/// Abstract so screens/tests can inject a fake (no network in tests).
abstract class VaultBackend {
  /// {sms, phone_masked, email, email_masked, email_verified, password, any,
  ///  end_to_end_encrypted, pin_on_server, last_reset_at, resets_left_today}
  /// or throws on no network.
  Future<Map<String, dynamic>> recoveryStatus();

  /// {method:'otp', otp_proof} | {method:'password', password} -> raw body
  /// with `_status`. Never throws on an HTTP error (network still throws).
  Future<Map<String, dynamic>> recoveryVerify(Map<String, dynamic> body);

  Future<void> setExpiryAlerts(int docId, bool on);
}

class ApiVaultBackend implements VaultBackend {
  final ApiClient api;
  ApiVaultBackend(this.api);

  @override
  Future<Map<String, dynamic>> recoveryStatus() => api.getJson('/vault/recovery/status');

  @override
  Future<Map<String, dynamic>> recoveryVerify(Map<String, dynamic> body) =>
      api.postJsonRaw('/vault/recovery/verify', body);

  @override
  Future<void> setExpiryAlerts(int docId, bool on) async {
    await api.patchJson('/documents/$docId/', {'expiry_alerts': on});
  }
}
