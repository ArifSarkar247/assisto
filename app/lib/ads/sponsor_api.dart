/// p2-money: the app's calls to the monetization endpoints. One seam
/// ([SponsorBackend]) so screens and the screenshot gallery can inject a
/// fake; the real one is [ApiSponsorBackend] over the signed-in [ApiClient].
library;

import '../api.dart';
import 'sponsor_models.dart';

abstract class SponsorBackend {
  Future<AdSlot> slot(String placement,
      {String screen = 'home', String entry = '', String ctxKind = '', int? ctxId});
  Future<void> event(String token, String kind);
  Future<Map<String, dynamic>> why(String token);

  Future<Map<String, dynamic>> offerPrefs();
  Future<Map<String, dynamic>> saveOfferPrefs(Map<String, dynamic> body);
  Future<List<SponsorCreative>> offersFeed();
  Future<List<Map<String, dynamic>>> brands();
  Future<void> muteBrand(int sponsorId, bool muted);

  Future<Map<String, dynamic>> premiumOffer(String reason);
  Future<Map<String, dynamic>> startTrial();

  Future<Map<String, dynamic>> rewardTicket();
  Future<Map<String, dynamic>> rewardTicketState(String nonce);
}

class ApiSponsorBackend implements SponsorBackend {
  ApiSponsorBackend(this.api);
  final ApiClient api;

  @override
  Future<AdSlot> slot(String placement,
      {String screen = 'home', String entry = '', String ctxKind = '', int? ctxId}) async {
    final q = Uri(queryParameters: {
      'placement': placement,
      'screen': screen,
      if (entry.isNotEmpty) 'entry': entry,
      if (ctxKind.isNotEmpty) 'ctx_kind': ctxKind,
      if (ctxId != null) 'ctx_id': '$ctxId',
    }).query;
    return AdSlot.fromJson(await api.getJson('/ads/slot?$q'));
  }

  @override
  Future<void> event(String token, String kind) async {
    if (token.isEmpty) return;
    try {
      await api.postJson('/ads/sponsor/event', {'token': token, 'kind': kind});
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>> why(String token) => api
      .getJson('/ads/why?${Uri(queryParameters: {'token': token}).query}');

  @override
  Future<Map<String, dynamic>> offerPrefs() => api.getJson('/offers/prefs');

  @override
  Future<Map<String, dynamic>> saveOfferPrefs(Map<String, dynamic> body) =>
      api.postJson('/offers/prefs', body);

  @override
  Future<List<SponsorCreative>> offersFeed() async {
    final j = await api.getJson('/offers/feed');
    return ((j['offers'] as List?) ?? const [])
        .map(SponsorCreative.fromJson)
        .whereType<SponsorCreative>()
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> brands() async {
    final j = await api.getJson('/offers/brands');
    return ((j['brands'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  @override
  Future<void> muteBrand(int sponsorId, bool muted) async {
    await api.postJson('/offers/brands/$sponsorId/mute', {'muted': muted});
  }

  @override
  Future<Map<String, dynamic>> premiumOffer(String reason) => api.getJson(
      '/premium/offer?${Uri(queryParameters: {'reason': reason}).query}');

  @override
  Future<Map<String, dynamic>> startTrial() async {
    try {
      return await api.postJson('/plans/trial/start');
    } on ApiException catch (e) {
      return {'ok': false, 'reason': 'trial_used', 'msg': e.message};
    }
  }

  @override
  Future<Map<String, dynamic>> rewardTicket() =>
      api.postJson('/credits/rewarded/ticket');

  @override
  Future<Map<String, dynamic>> rewardTicketState(String nonce) =>
      api.getJson('/credits/rewarded/ticket/$nonce');
}
