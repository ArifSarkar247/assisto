/// L3 — Google UMP (User Messaging Platform) consent gate for AdMob.
///
/// Google requires a certified consent message (GDPR/TCF) before any ad
/// request in the EEA, the UK and Switzerland. This file is the app's single
/// gate in front of EVERY AdMob request (app-open, rewarded, home hero native,
/// Photo Studio):
///
///  * ON for the Android APK (admob, owner 25 Oct): it carries Assisto's REAL
///    AdMob app id (manifest APPLICATION_ID = [AdIds.ownerAppId]), so UMP
///    runs before the first ad — GDPR message in the EEA/UK/CH and the US
///    state-regulations message, both configured in AdMob -> Privacy &
///    messaging. Host tests / iOS: no AdMob -> inactive, nothing runs.
///  * LAZY: nothing here runs at launch. The first call is made after the
///    first frame by AdsService (Free users only), or right before the first
///    ad request, and on Settings for a Free user (to know whether the "Ad
///    privacy choices" entry is required). No ContentProvider, no
///    WorkManager, no plugin work before the first frame.
///  * FAIL CLOSED: a real app id with no linked UMP SDK, an error, or
///    `canRequestAds() == false` -> no ad request at all.
///  * CRASH-GUARDED: every bridge call is try/caught and time-boxed.
///
/// The UMP SDK ships inside google_mobile_ads; the real [ConsentBridge] is
/// `admob_consent_bridge.dart`, bound in `consent_binding.dart` wherever the
/// AdMob bridge is (they always go live together).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ad_rules.dart' show AdIds;
import 'admob_platform.dart';
import 'consent_binding.dart';

/// Mirror of UMP's PrivacyOptionsRequirementStatus (no plugin import here).
enum PrivacyOptionsStatus { notRequired, required, unknown }

/// Mirror of UMP's ConsentStatus. `obtained` only means the user ANSWERED
/// the form — the plugin does not say whether it was "Consent" or "Do not
/// consent", so the app treats every status except [notRequired] as "no
/// personalised ads" (admobump, owner 2 Nov: never personalise without
/// consent).
enum UmpConsentStatus { unknown, required, notRequired, obtained }

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

  /// ConsentInformation.getConsentStatus.
  Future<UmpConsentStatus> consentStatus();
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
  @override
  Future<UmpConsentStatus> consentStatus() async => UmpConsentStatus.unknown;
}

class AdConsent {
  AdConsent._();
  static final AdConsent instance = AdConsent._();

  /// admob (owner 25 Oct): the APK carries Assisto's REAL AdMob app id in
  /// its manifest, so on Android the UMP consent flow is live. Elsewhere
  /// (host tests, iOS) there is no AdMob -> Google's test id -> inactive.
  static const _defineAppId = String.fromEnvironment('ADMOB_APP_ID');
  static String get _builtAppId => _defineAppId.isNotEmpty
      ? _defineAppId
      : (admobSupported() ? AdIds.ownerAppId : AdIds.testAppId);

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

  /// The last privacy-options status UMP reported (unknown until asked).
  /// Settings shows the tappable row on `required` and an honest info line
  /// on `notRequired`.
  final ValueNotifier<PrivacyOptionsStatus> privacyStatus =
      ValueNotifier<PrivacyOptionsStatus>(PrivacyOptionsStatus.unknown);

  /// The last UMP consent status of this session.
  UmpConsentStatus consentStatus = UmpConsentStatus.unknown;

  bool _canServe = false;

  /// THE gate state every ad request checks ([AdmobSdk.request] refuses to
  /// build one while this is false): true only after [allowsAds] said yes in
  /// this session (UMP update + form + canRequestAds), or when this APK has
  /// no real AdMob app id (Google test ads only, no UMP).
  bool get canServe => _canServe;

  /// Personalised ads are allowed ONLY where UMP says no consent is needed
  /// at all (e.g. Bangladesh). EEA/UK/CH and US-state users always get
  /// non-personalised requests (we cannot read "Consent" vs "Do not
  /// consent" from the plugin, so we take the safe side).
  bool get mayPersonalise =>
      _canServe && active && consentStatus == UmpConsentStatus.notRequired;

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
    if (!active) return _canServe = true;
    if (!bridge.linked) return _canServe = false;
    final ok = await (_inFlight ??= _gather(showForm: true)
        .whenComplete(() => _inFlight = null));
    _canServe = ok;
    return ok;
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
      // the user may have changed or withdrawn consent: re-read both, the
      // next ad request follows the new answer
      await _readConsentStatus();
      if (_canServe) {
        _canServe = await bridge
            .canRequestAds()
            .timeout(const Duration(seconds: 5), onTimeout: () => false);
      }
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
      await _readConsentStatus();
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
      privacyStatus.value = s;
    } catch (_) {
      // best-effort: status unknown -> the Settings entry stays hidden
      privacyOptionsRequired.value = false;
      privacyStatus.value = PrivacyOptionsStatus.unknown;
    }
  }

  Future<void> _readConsentStatus() async {
    try {
      consentStatus = await bridge
          .consentStatus()
          .timeout(const Duration(seconds: 5),
              onTimeout: () => UmpConsentStatus.unknown);
    } catch (_) {
      consentStatus = UmpConsentStatus.unknown; // -> non-personalised
    }
  }

  @visibleForTesting
  void resetForTest({String? appId, ConsentBridge? bridge}) {
    this.appId = appId ?? _builtAppId;
    this.bridge = bridge ?? createConsentBridge();
    debugEea = false;
    testDeviceIds = const [];
    privacyOptionsRequired.value = false;
    privacyStatus.value = PrivacyOptionsStatus.unknown;
    consentStatus = UmpConsentStatus.unknown;
    _canServe = false;
    _updatedThisSession = false;
    _inFlight = null;
  }
}
