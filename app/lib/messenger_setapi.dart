import 'api.dart';

/// Messenger HUB SETTINGS — client surface (Settings full-spec build).
///
/// Implemented as an EXTENSION built ONLY on the public [ApiClient.getJson] /
/// [ApiClient.postJson] helpers, so it ships WITHOUT editing the shared
/// api.dart. Every route exists on the backend (core/views_m1_messenger.py);
/// a failure is an [ApiException] the screen shows honestly — no silent
/// fallback to defaults.
///
/// SERVER IS AUTHORITATIVE. The two-step PIN lives ONLY on the server, as a
/// Django password hash; verify is rate-limited (5 tries, then a 15-minute
/// lock) and changing / turning off an enabled PIN needs the current one.
extension MessengerSettingsApi on ApiClient {
  // ==========================================================================
  // ACCOUNT — two-step verification PIN (server-held hash)
  // ==========================================================================

  /// GET /circle/account/two-step -> {enabled, email_set, locked,
  /// retry_after_sec}.
  Future<Map<String, dynamic>> twoStepStatus() =>
      getJson('/circle/account/two-step');

  /// POST /circle/account/two-step {enabled, pin?, current_pin?,
  /// recovery_email?} -> {ok, enabled}. `pin` is the new 6-digit PIN (omitted
  /// when disabling); `current_pin` is required when a PIN is already on
  /// (403 {reason: current_pin_required|bad_pin, attempts_left} / 429 locked).
  Future<Map<String, dynamic>> twoStepSet({
    required bool enabled,
    String? pin,
    String? currentPin,
    String? recoveryEmail,
  }) =>
      postJson('/circle/account/two-step', {
        'enabled': enabled,
        if (pin != null && pin.isNotEmpty) 'pin': pin,
        if (currentPin != null && currentPin.isNotEmpty)
          'current_pin': currentPin,
        if (recoveryEmail != null && recoveryEmail.trim().isNotEmpty)
          'recovery_email': recoveryEmail.trim(),
      });

  /// POST /circle/account/two-step/verify {pin} -> 200 {ok:true} |
  /// 403 {ok:false, attempts_left} | 429 {locked, retry_after_sec}.
  Future<Map<String, dynamic>> twoStepVerify(String pin) =>
      postJson('/circle/account/two-step/verify', {'pin': pin});

  // ==========================================================================
  // ACCOUNT — change number (request code -> confirm), via the server OTP
  // ==========================================================================

  /// GET /circle/account/change-number -> {sms_enabled, two_step_required,
  /// current_phone, pending_phone}. When sms_enabled is false the screen shows
  /// an honest disabled state (no SMS service is connected on the server).
  Future<Map<String, dynamic>> changeNumberStatus() =>
      getJson('/circle/account/change-number');

  /// POST /circle/account/change-number/request {new_phone} -> {ok, sent,
  /// expires_in_sec}. 503 {code:'sms_not_configured'}, 409 number_in_use,
  /// 429 wait_before_resend, 400 invalid_phone.
  Future<Map<String, dynamic>> changeNumberRequest(String newPhone) =>
      postJson('/circle/account/change-number/request', {
        'new_phone': newPhone.trim(),
      });

  /// POST /circle/account/change-number/confirm {new_phone, code, pin?}
  /// -> {ok, phone}. `pin` is required when two-step is on.
  Future<Map<String, dynamic>> changeNumberConfirm({
    required String newPhone,
    required String code,
    String? pin,
  }) =>
      postJson('/circle/account/change-number/confirm', {
        'new_phone': newPhone.trim(),
        'code': code.trim(),
        if (pin != null && pin.isNotEmpty) 'pin': pin,
      });

  // ==========================================================================
  // PRIVACY — blocked list + message requests (who-can-message gate)
  // ==========================================================================

  /// GET /circle/blocked -> {blocked:[{id, name, phone, photo}]}.
  Future<Map<String, dynamic>> blockedList() => getJson('/circle/blocked');

  /// POST /circle/<member>/controls {blocked:false} to UNBLOCK.
  Future<Map<String, dynamic>> unblock(int memberId) =>
      postJson('/circle/$memberId/controls', {'blocked': false});

  /// GET /circle/message-requests -> {requests:[{id, sender_id, name, phone,
  /// photo, preview, ciphertext, nonce, sender_key_id, community_name, at}]}.
  /// Pending first messages from people outside the circle (only possible
  /// when who-can-message is `everyone`). Ciphertext only.
  Future<Map<String, dynamic>> messageRequests() =>
      getJson('/circle/message-requests');

  /// POST /circle/message-requests/<id>
  /// {action: accept|decline|block|report, reason?, also_block?}
  /// -> {ok, action, state, blocked}.
  Future<Map<String, dynamic>> messageRequestAct(
    String id,
    String action, {
    String? reason,
    bool? alsoBlock,
  }) =>
      postJson('/circle/message-requests/$id', {
        'action': action,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
        if (alsoBlock != null) 'also_block': alsoBlock,
      });

  /// GET /circle/settings/message-privacy
  /// -> {who_can_message: my_circle|everyone|nobody, phone_hidden: bool}.
  /// my_circle (default) REFUSES strangers; everyone lets a stranger in a
  /// shared community send ONE first message that waits in Requests.
  Future<Map<String, dynamic>> messagePrivacy() =>
      getJson('/circle/settings/message-privacy');

  /// POST /circle/settings/message-privacy {who_can_message, phone_hidden}.
  Future<Map<String, dynamic>> setMessagePrivacy(Map<String, dynamic> body) =>
      postJson('/circle/settings/message-privacy', body);

  // ==========================================================================
  // NOTIFICATIONS + CALLS prefs (server-enforced)
  // ==========================================================================

  /// GET /circle/settings/notifications -> {messages, groups, calls,
  /// show_preview, in_app_sound, in_app_vibrate}. messages/groups/calls gate
  /// the server's pushes; show_preview=false sends a name-free push.
  Future<Map<String, dynamic>> notificationPrefs() =>
      getJson('/circle/settings/notifications');

  /// POST /circle/settings/notifications {...toggles} -> {ok, ...toggles}.
  Future<Map<String, dynamic>> setNotificationPrefs(
          Map<String, dynamic> body) =>
      postJson('/circle/settings/notifications', body);

  /// GET /circle/settings/calls -> {incoming_calls, silence_unknown}.
  /// incoming_calls=false: the server refuses calls to you; silence_unknown:
  /// no ring unless the caller is in your accepted circle.
  Future<Map<String, dynamic>> callPrefs() =>
      getJson('/circle/settings/calls');

  /// POST /circle/settings/calls {incoming_calls, silence_unknown} -> {ok,...}.
  Future<Map<String, dynamic>> setCallPrefs(Map<String, dynamic> body) =>
      postJson('/circle/settings/calls', body);

  // ==========================================================================
  // STORAGE & DATA
  // ==========================================================================

  /// GET /circle/settings/storage -> {total_bytes, quota_bytes, pct, full,
  /// media_bytes, docs_bytes, backup_bytes, auto_download:{photos, audio,
  /// video, docs}} — real server usage from the storage meter.
  Future<Map<String, dynamic>> storageUsage() =>
      getJson('/circle/settings/storage');

  /// POST /circle/settings/storage {auto_download:{...}} -> {ok, auto_download}.
  Future<Map<String, dynamic>> setStoragePrefs(Map<String, dynamic> body) =>
      postJson('/circle/settings/storage', body);
}
