import '../api.dart';

/// p5-growth client surface (backend core/views_p5_growth.py).
///
///   GET  /growth/me      -> {code, link, share_text, rules{...}, stats{...},
///                            my_claim|null, can_claim, founding{...}}
///   POST /growth/claim   {code, device_id} -> {ok, reason, detail, me?}
///   POST /growth/install {install_id, app_version, platform, device_id}
///
/// Every number shown on the invite screen comes from these replies; the
/// client never invents a reward amount, a cap or a seat count.
extension GrowthApi on ApiClient {
  Future<Map<String, dynamic>> growthMe() => getJson('/growth/me');

  /// Never throws on a 4xx (the reply carries a localised `detail`).
  Future<Map<String, dynamic>> growthClaim(String code, {String deviceId = ''}) =>
      postJsonRaw('/growth/claim', {'code': code, 'device_id': deviceId});

  Future<Map<String, dynamic>> growthInstall(String installId,
          {String appVersion = '', String ref = ''}) =>
      postJsonRaw('/growth/install', {
        'install_id': installId,
        'device_id': installId,
        'app_version': appVersion,
        'platform': 'android',
        if (ref.isNotEmpty) 'ref': ref,
      });
}
