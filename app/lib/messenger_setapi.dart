import 'api.dart';

/// Messenger HUB SETTINGS — client surface (Settings full-spec build).
///
/// Everything the expanded hub Settings needs that isn't already on [ApiClient]
/// or another extension. Implemented as an EXTENSION built ONLY on the public
/// [ApiClient.getJson] / [ApiClient.postJson] / [ApiClient.exportRaw] helpers,
/// so it ships WITHOUT editing the shared api.dart (same pattern as
/// messenger_admin_api.dart). Paths match the circle backend (`api/v1/` prefix
/// is applied by AppConfig; no trailing slash).
///
/// SERVER IS AUTHORITATIVE. The two-step PIN is set BOTH locally (fast gate on
/// app open) and on the server (so a re-install / new device is challenged).
/// The client can only change its own *request*; the server decides.
extension MessengerSettingsApi on ApiClient {
  // ==========================================================================
  // ACCOUNT — two-step verification PIN (local + server)
  // ==========================================================================

  /// GET /circle/account/two-step -> {enabled, email_set}. Best-effort: if the
  /// backend has no such route yet, callers treat a thrown [ApiException] as
  /// "server copy unavailable" and fall back to the on-device PIN only.
  // TODO(backend): no `messenger/account/two-step` route exists yet; this path
  // intentionally 404s so the screen shows the honest "server copy unavailable"
  // state and falls back to the on-device PIN.
  Future<Map<String, dynamic>> twoStepStatus() =>
      getJson('/circle/account/two-step');

  /// POST /circle/account/two-step {enabled, pin?, recovery_email?}.
  /// `pin` is the new 6-digit PIN (null when disabling). The server stores only
  /// a salted hash; it never returns the PIN. -> {ok, enabled}.
  Future<Map<String, dynamic>> twoStepSet({
    required bool enabled,
    String? pin,
    String? recoveryEmail,
  }) =>
      // TODO(backend): no `messenger/account/two-step` route; degrades to
      // on-device PIN only until the server endpoint lands.
      postJson('/circle/account/two-step', {
        'enabled': enabled,
        if (pin != null && pin.isNotEmpty) 'pin': pin,
        if (recoveryEmail != null && recoveryEmail.trim().isNotEmpty)
          'recovery_email': recoveryEmail.trim(),
      });

  // ==========================================================================
  // ACCOUNT — change number (two-step flow: request code -> confirm)
  // ==========================================================================

  /// POST /circle/account/change-number/request {new_phone} -> {ok, sent}.
  /// Sends a verification code to the NEW number. The old number keeps the
  /// account until the code is confirmed.
  // TODO(backend): no `messenger/account/change-number/request` route exists;
  // degrades to an honest error until the server endpoint lands.
  Future<Map<String, dynamic>> changeNumberRequest(String newPhone) =>
      postJson('/circle/account/change-number/request', {
        'new_phone': newPhone.trim(),
      });

  /// POST /circle/account/change-number/confirm {new_phone, code}
  /// -> {ok, phone}. On success the circle + chats migrate server-side; the
  /// client refreshes /me.
  Future<Map<String, dynamic>> changeNumberConfirm({
    required String newPhone,
    required String code,
  }) =>
      // TODO(backend): no `messenger/account/change-number/confirm` route;
      // degrades to an honest error until the server endpoint lands.
      postJson('/circle/account/change-number/confirm', {
        'new_phone': newPhone.trim(),
        'code': code.trim(),
      });

  // ==========================================================================
  // PRIVACY — blocked list + message requests (who-can-message gate)
  // ==========================================================================

  /// GET /circle/blocked -> {blocked:[{id, name, phone, photo}]}.
  // TODO(backend): no `messenger/blocked` route exists; degrades to an empty
  // "no blocked contacts" state until the server endpoint lands.
  Future<Map<String, dynamic>> blockedList() => getJson('/circle/blocked');

  /// POST /circle/<member>/controls {blocked:false} to UNBLOCK. Reuses the
  /// existing controls endpoint (see ApiClient.circleSetMemberControls) so no
  /// new backend surface is needed — kept here as a named convenience.
  Future<Map<String, dynamic>> unblock(int memberId) =>
      postJson('/circle/$memberId/controls', {'blocked': false});

  /// GET /circle/message-requests -> {requests:[{id, name, phone, photo,
  /// preview, at}]}. Requests from people outside the circle when
  /// "who can message" is restricted.
  // TODO(backend): no `messenger/message-requests` route exists; degrades to an
  // empty "no requests" state until the server endpoint lands.
  Future<Map<String, dynamic>> messageRequests() =>
      getJson('/circle/message-requests');

  /// POST /circle/message-requests/<id> {action: accept|decline|block}
  /// -> {ok}.
  // TODO(backend): no `messenger/message-requests/<id>` route exists; degrades
  // to an honest error until the server endpoint lands.
  Future<Map<String, dynamic>> messageRequestAct(String id, String action) =>
      postJson('/circle/message-requests/$id', {'action': action});

  // ==========================================================================
  // NOTIFICATIONS + CALLS prefs (device + server mirror)
  // ==========================================================================

  /// GET /circle/settings/notifications -> {messages, groups, calls,
  /// in_app_sound, in_app_vibrate, show_preview}. Falls back to defaults on
  /// error.
  // TODO(backend): no `messenger/settings/notifications` route exists; degrades
  // to on-device default toggles until the server endpoint lands.
  Future<Map<String, dynamic>> notificationPrefs() =>
      getJson('/circle/settings/notifications');

  /// POST /circle/settings/notifications {...toggles} -> {ok}.
  // TODO(backend): no `messenger/settings/notifications` route exists; degrades
  // to an honest error until the server endpoint lands.
  Future<Map<String, dynamic>> setNotificationPrefs(
          Map<String, dynamic> body) =>
      postJson('/circle/settings/notifications', body);

  /// GET /circle/settings/calls -> {incoming_calls, silence_unknown}.
  // TODO(backend): no `messenger/settings/calls` route exists; degrades to
  // on-device default toggles until the server endpoint lands.
  Future<Map<String, dynamic>> callPrefs() =>
      getJson('/circle/settings/calls');

  /// POST /circle/settings/calls {incoming_calls, silence_unknown} -> {ok}.
  // TODO(backend): no `messenger/settings/calls` route exists; degrades to an
  // honest error until the server endpoint lands.
  Future<Map<String, dynamic>> setCallPrefs(Map<String, dynamic> body) =>
      postJson('/circle/settings/calls', body);

  // ==========================================================================
  // STORAGE & DATA
  // ==========================================================================

  /// GET /circle/settings/storage -> {total_bytes, media_bytes, docs_bytes,
  /// cache_bytes, auto_download:{photos, audio, video, docs}}. Best-effort.
  // TODO(backend): no `messenger/settings/storage` route exists; degrades to an
  // empty/zero usage state until the server endpoint lands.
  Future<Map<String, dynamic>> storageUsage() =>
      getJson('/circle/settings/storage');

  /// POST /circle/settings/storage {auto_download:{...}} -> {ok}. Persists the
  /// media auto-download policy.
  // TODO(backend): no `messenger/settings/storage` route exists; degrades to an
  // honest error until the server endpoint lands.
  Future<Map<String, dynamic>> setStoragePrefs(Map<String, dynamic> body) =>
      postJson('/circle/settings/storage', body);
}
