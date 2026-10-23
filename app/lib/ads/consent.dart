/// L3 — Google UMP (User Messaging Platform) consent gate for AdMob.
///
/// Google requires a certified consent message (GDPR/TCF) before any ad
/// request in the EEA, the UK and Switzerland. This file is the app's single
/// gate in front of EVERY AdMob request (app-open, rewarded, home hero native,
/// Photo Studio):
///
///  * OFF without an AdMob app id: the flow exists only when this APK was
///    built with a REAL AdMob app id (`--dart-define=ADMOB_APP_ID=` from the
///    CI secret, the same value as the manifest APPLICATION_ID). Today there
///    is none, so [allowsAds] returns true at once (only Google's TEST ads can
///    play, in debug / QA test mode — the rule engine already guarantees
///    that) and NO consent call, network request or UI ever happens.
///  * LAZY: nothing here runs at launch. The first call is made right before
///    the first ad request (and on Settings for a Free user, to know whether
///    the "Ad privacy choices" entry is required). No ContentProvider, no
///    WorkManager, no plugin work before the first frame.
///  * FAIL CLOSED: a real app id with no linked UMP SDK, an error, or
///    `canRequestAds() == false` -> no ad request at all.
///  * CRASH-GUARDED: every bridge call is try/caught and time-boxed.
///
/// The UMP SDK ships inside google_mobile_ads; the real [ConsentBridge] is
/// `admob_consent_bridge.dart.pending` and is bound in `consent_binding.dart`
/// by the same apply script as the AdMob bridge (they go live together).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ad_rules.dart' show AdIds;
import 'consent_binding.dart';

/// Mirror of UMP's PrivacyOptionsRequirementStatus (no plugin import here).
enum PrivacyOptionsStatus { notRequired, required, unknown }

/// The plugin seam. Tests use a fake; the app uses [NoopConsentBridge] until
/// google_mobile_ads is linked. Implementations must never throw.
abstract class ConsentBridge {
  bool get linked;

  /// ConsentInformation.requestConsentInfoUpdate. true on success.
  Future<bool> requestUpdate(
      {required bool debugEea, required List<String> testDeviceIds});

  /// ConsentForm.loadAndShowConsentFormIfRequired — shows Google's form only
  /// when UMP says consent is required; completes when it is dismissed.
  Future<void> loadAndShowIfRequired();

  /// ConsentInformation.canRequestAds.
  Future<bool> canRequestAds();

  /// ConsentInformation.getPrivacyOptionsRequirementStatus.
  Future<PrivacyOptionsStatus> privacyOptionsStatus();

  /// ConsentForm.showPrivacyOptionsForm. true when the form was shown and
  /// dismissed without an error.
  Future<bool> showPrivacyOptionsForm();
}

class NoopConsentBridge implements ConsentBridge {
  const NoopConsentBridge();
  @override
  bool get linked => false;
  @override
  Future<bool> requestUpdate(
          {required bool debugEea, required List<String> testDeviceIds}) async =>
      false;
  @override
  Future<void> loadAndShowIfRequired() async {}
  @override
  Future<bool> canRequestAds() async => false;
  @override
  Future<PrivacyOptionsStatus> privacyOptionsStatus() async =>
      PrivacyOptionsStatus.unknown;
  @override
  Future<bool> showPrivacyOptionsForm() async => false;
}

class AdConsent {
  AdConsent._();
  static final AdConsent instance = AdConsent._();

  static const _builtAppId =
      String.fromEnvironment('ADMOB_APP_ID', defaultValue: AdIds.testAppId);

  static final _appIdRe = RegExp(r'^ca-app-pub-\d{16}~\d{6,12}$');
  static const _testPublisher = 'ca-app-pub-3940256099942544';

  /// A real (owner's) AdMob app id — never Google's public test app id.
  static bool isRealAppId(String id) =>
      _appIdRe.hasMatch(id.trim()) && !id.trim().startsWith(_testPublisher);

  /// The AdMob app id this APK carries (tests may override).
  String appId = _builtAppId;
  ConsentBridge bridge = createConsentBridge();

  /// Owner Admin -> Ads -> "Force EEA consent (testing)" and the AdMob
  /// integration's UMP test-device ids; fed from `/ads/config`. Google only
  /// honours debug geography on the listed test devices.
  bool debugEea = false;
  List<String> testDeviceIds = const [];

  /// true only when UMP says the privacy-options entry point is REQUIRED —
  /// Settings shows "Ad privacy choices" only then.
  final ValueNotifier<bool> privacyOptionsRequired = ValueNotifier<bool>(false);

  bool _updatedThisSession = false;
  Future<bool>? _inFlight;

  /// The consent flow can exist at all in this APK.
  bool get active => isRealAppId(appId);

  /// Feed the debug knobs from the server's `/ads/config` JSON.
  void applyServerConfig(Map<String, dynamic>? j) {
    if (j == null) return;
    debugEea = j['consent_debug_eea'] == true;
    final ids = j['consent_test_devices'];
    testDeviceIds = ids is List
        ? ids.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList()
        : const [];
  }

  /// Call RIGHT BEFORE any ad request (and before MobileAds.initialize).
  /// true = the ad may be requested.
  ///  * no real app id -> true, nothing runs (no-op; TEST ads only).
  ///  * real app id, UMP not linked -> false (fail closed).
  ///  * else: requestConsentInfoUpdate (once per session), show Google's form
  ///    if required, then canRequestAds().
  Future<bool> allowsAds() async {
    if (!active) return true;
    if (!bridge.linked) return false;
    return _inFlight ??= _gather(showForm: true)
        .whenComplete(() => _inFlight = null);
  }

  /// Settings (Free users only): learn whether "Ad privacy choices" is
  /// required, without showing any form. No-op without a real app id.
  Future<void> refreshPrivacyStatus() async {
    if (!active || !bridge.linked) return;
    try {
      await (_inFlight ??= _gather(showForm: false)
          .whenComplete(() => _inFlight = null));
    } catch (e) {
      if (kDebugMode) debugPrint('consent status skipped: $e');
    }
  }

  /// "Ad privacy choices" tapped: re-open Google's privacy options form.
  /// true when it was shown. Never throws.
  Future<bool> showPrivacyOptions() async {
    if (!active || !bridge.linked) return false;
    try {
      final ok = await bridge.showPrivacyOptionsForm();
      await _readPrivacyStatus();
      return ok;
    } catch (e) {
      if (kDebugMode) debugPrint('privacy options failed: $e');
      return false;
    }
  }

  Future<bool> _gather({required bool showForm}) async {
    try {
      if (!_updatedThisSession) {
        final ok = await bridge
            .requestUpdate(debugEea: debugEea, testDeviceIds: testDeviceIds)
            .timeout(const Duration(seconds: 12), onTimeout: () => false);
        _updatedThisSession = ok;
      }
      // The form waits for the user, so no timeout on it. Shown only when
      // UMP says consent is required (EEA/UK/CH); elsewhere it returns at once.
      if (showForm && _updatedThisSession) await bridge.loadAndShowIfRequired();
      await _readPrivacyStatus();
      // Google: even when the update failed, a consent given in an earlier
      // session may still allow requests — canRequestAds() decides.
      return await bridge
          .canRequestAds()
          .timeout(const Duration(seconds: 5), onTimeout: () => false);
    } catch (e) {
      if (kDebugMode) debugPrint('consent gate closed: $e');
      return false;
    }
  }

  Future<void> _readPrivacyStatus() async {
    try {
      final s = await bridge
          .privacyOptionsStatus()
          .timeout(const Duration(seconds: 5),
              onTimeout: () => PrivacyOptionsStatus.unknown);
      privacyOptionsRequired.value = s == PrivacyOptionsStatus.required;
    } catch (_) {
      // best-effort: status unknown -> the Settings entry stays hidden
      privacyOptionsRequired.value = false;
    }
  }

  @visibleForTesting
  void resetForTest({String? appId, ConsentBridge? bridge}) {
    this.appId = appId ?? _builtAppId;
    this.bridge = bridge ?? createConsentBridge();
    debugEea = false;
    testDeviceIds = const [];
    privacyOptionsRequired.value = false;
    _updatedThisSession = false;
    _inFlight = null;
  }
}
