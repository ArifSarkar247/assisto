import 'api.dart';

/// b6-antitheft — HTTP surface for the native always-on Lost/Stolen engine.
///
/// An extension on [ApiClient] (built only on its public getJson/postJson) so
/// it ships without editing the shared api.dart. Paths are authoritative:
/// see backend/core/views_antitheft.py.
extension AntiTheftApi on ApiClient {
  /// GET security/engine/state -> owner settings + honest status.
  Future<Map<String, dynamic>> engineState() =>
      getJson('/security/engine/state');

  /// POST security/engine/enable {pin, snatch_lock?, intruder_photo?,
  /// failed_unlock_threshold?, alert_member_ids?, capabilities?} ->
  /// {ok, engine_token, ingest_path, photo_path, config} on success.
  /// Returns the parsed 4xx body (with _status) on bad pin / no pin so the
  /// caller can explain, rather than throwing.
  Future<Map<String, dynamic>> engineEnable({
    required String pin,
    bool? snatchLock,
    bool? intruderPhoto,
    int? failedUnlockThreshold,
    List<int>? alertMemberIds,
    Map<String, dynamic>? capabilities,
    String? otpProof,
  }) =>
      postJsonRaw('/security/engine/enable', {
        'pin': pin,
        if (snatchLock != null) 'snatch_lock': snatchLock,
        if (intruderPhoto != null) 'intruder_photo': intruderPhoto,
        if (failedUnlockThreshold != null)
          'failed_unlock_threshold': failedUnlockThreshold,
        if (alertMemberIds != null) 'alert_member_ids': alertMemberIds,
        if (capabilities != null) 'capabilities': capabilities,
        if (otpProof != null && otpProof.isNotEmpty) 'otp_proof': otpProof,
      });

  /// POST security/engine/disable {pin, otp_proof?} — Security PIN (Section 8).
  Future<Map<String, dynamic>> engineDisable({
    required String pin,
    String? otpProof,
  }) =>
      postJsonRaw('/security/engine/disable', {
        'pin': pin,
        if (otpProof != null && otpProof.isNotEmpty) 'otp_proof': otpProof,
      });

  /// at-falsealarm: POST security/engine/false-alarm {pin} — the owner's
  /// "It was me". Server verifies the Security PIN (wrong PIN counts toward
  /// the lock), lifts the freeze, removes recent theft signals and sends the
  /// family one all-clear. -> {ok, cleared} | 403 {reason:'bad_pin'|locked}
  /// | 429 {reason:'rate_limited'}.
  Future<Map<String, dynamic>> engineFalseAlarm({required String pin}) =>
      postJsonRaw('/security/engine/false-alarm', {'pin': pin});

  /// antitheft2: POST security/engine/escalate {reason: not_ok|duress} — the
  /// owner answered "I need help" on "Are you OK?": the held grab goes to
  /// the trusted contacts now. -> {ok, escalated, recipients}.
  Future<Map<String, dynamic>> engineEscalate({String reason = 'not_ok'}) =>
      postJsonRaw('/security/engine/escalate', {'reason': reason});

  /// POST security/engine/settings {pin, ...} -> {ok, config, alert_members}.
  /// antitheft2: [nightGuard]; [homeWifi] 'save_current' (with [wifiHash]
  /// from the engine, never the name) | 'clear'.
  Future<Map<String, dynamic>> engineSettings({
    required String pin,
    bool? snatchLock,
    bool? intruderPhoto,
    int? intruderConsent, // at100: the consent screen's version ("I agree")
    int? failedUnlockThreshold,
    List<int>? alertMemberIds,
    bool? nightGuard,
    String? homeWifi,
    String? wifiHash,
  }) =>
      postJsonRaw('/security/engine/settings', {
        'pin': pin,
        if (snatchLock != null) 'snatch_lock': snatchLock,
        if (intruderPhoto != null) 'intruder_photo': intruderPhoto,
        if (intruderConsent != null) 'intruder_consent': intruderConsent,
        if (failedUnlockThreshold != null)
          'failed_unlock_threshold': failedUnlockThreshold,
        if (alertMemberIds != null) 'alert_member_ids': alertMemberIds,
        if (nightGuard != null) 'night_guard': nightGuard,
        if (homeWifi != null) 'home_wifi': homeWifi,
        if (wifiHash != null && wifiHash.isNotEmpty) 'wifi_hash': wifiHash,
      });

  /// GET security/engine/timeline[?phone_id] — owner or approved family only.
  Future<Map<String, dynamic>> engineTimeline({int? phoneId}) => getJson(
      '/security/engine/timeline${phoneId != null ? '?phone_id=$phoneId' : ''}');

  /// GET security/engine/watching — phones whose alerts I (family) receive.
  Future<Map<String, dynamic>> engineWatching() =>
      getJson('/security/engine/watching');

  /// at100: POST security/engine/command {kind, phone_id?, message?, contact?}
  /// kind: lost_mode | alarm | alarm_stop | lock | message. -> 201 {ok,
  /// command:{id, state, ...}, phone:{online, last_seen, ...}} or the 4xx
  /// body (_status): 403 not_active, 404, 409 protection_off, 429
  /// rate_limited, 400 message_required / wipe_not_supported.
  Future<Map<String, dynamic>> engineCommand(String kind,
          {int? phoneId, String? message, String? contact}) =>
      postJsonRaw('/security/engine/command', {
        'kind': kind,
        if (phoneId != null) 'phone_id': phoneId,
        if (message != null && message.isNotEmpty) 'message': message,
        if (contact != null && contact.isNotEmpty) 'contact': contact,
      });

  /// at100: GET security/engine/commands[?phone_id] -> {role, owner, phone,
  /// can:{kind:bool}, commands:[...], in_flight, wipe:{supported, use}}.
  Future<Map<String, dynamic>> engineCommands({int? phoneId}) => getJson(
      '/security/engine/commands${phoneId != null ? '?phone_id=$phoneId' : ''}');

  /// at100: POST security/engine/command/<id>/cancel (before it reached the phone).
  Future<Map<String, dynamic>> engineCommandCancel(int id) =>
      postJsonRaw('/security/engine/command/$id/cancel', const {});

  /// GET security/engine/event/<id>/photo-link -> {url} (short-lived, scoped).
  Future<Map<String, dynamic>> enginePhotoLink(int eventId) =>
      getJson('/security/engine/event/$eventId/photo-link');
}
