import '../../api.dart';

/// amarket (flag `assisto_market`, default OFF): every server call the
/// Assisto Market screens make, behind ONE seam so widget tests inject a fake.
/// Shapes mirror backend/core/views_market.py + core/market.py. Money is in
/// POISHA in every response; the app sends whole taka.
abstract class MarketSource {
  Future<Map<String, dynamic>> overview();
  Future<Map<String, dynamic>> createNeed(Map<String, dynamic> body);
  Future<Map<String, dynamic>> need(int id);
  Future<Map<String, dynamic>> needAct(int id, String action,
      [Map<String, dynamic> body = const {}]);
  Future<List<Map<String, dynamic>>> group(String area);
  Future<Map<String, dynamic>> sell();
  Future<Map<String, dynamic>> applySeller(String area, List<String> categories);
  Future<List<Map<String, dynamic>>> deals();
  Future<Map<String, dynamic>> dealAct(int id, String action, {int? rating});
  Future<Map<String, dynamic>> dealChat(int id);
  Future<void> report(String kind, int id, String category);
  Future<void> block(String kind, int id);
}

List<Map<String, dynamic>> mkList(Object? v) =>
    [for (final x in (v as List? ?? const [])) (x as Map).cast<String, dynamic>()];

class ApiMarketSource implements MarketSource {
  final ApiClient api;
  ApiMarketSource(this.api);

  @override
  Future<Map<String, dynamic>> overview() => api.getJson('/market');
  @override
  Future<Map<String, dynamic>> createNeed(Map<String, dynamic> body) =>
      api.postJson('/market/needs', body);
  @override
  Future<Map<String, dynamic>> need(int id) async =>
      ((await api.getJson('/market/needs/$id'))['need'] as Map).cast<String, dynamic>();
  @override
  Future<Map<String, dynamic>> needAct(int id, String action,
          [Map<String, dynamic> body = const {}]) =>
      api.postJson('/market/needs/$id/$action', body);
  @override
  Future<List<Map<String, dynamic>>> group(String area) async =>
      mkList((await api.getJson('/market/group?area=${Uri.encodeQueryComponent(area)}'))['needs']);
  @override
  Future<Map<String, dynamic>> sell() => api.getJson('/market/sell');
  @override
  Future<Map<String, dynamic>> applySeller(String area, List<String> categories) =>
      api.postJson('/market/seller', {'area': area, 'categories': categories});
  @override
  Future<List<Map<String, dynamic>>> deals() async =>
      mkList((await api.getJson('/market/deals'))['deals']);
  @override
  Future<Map<String, dynamic>> dealAct(int id, String action, {int? rating}) =>
      api.postJson('/market/deals/$id/act', {'action': action, if (rating != null) 'rating': rating});
  @override
  Future<Map<String, dynamic>> dealChat(int id) => api.postJson('/market/deals/$id/chat');
  @override
  Future<void> report(String kind, int id, String category) async {
    await api.postJson('/market/report', {'kind': kind, 'id': id, 'category': category});
  }

  @override
  Future<void> block(String kind, int id) async {
    await api.postJson('/market/block', {'kind': kind, 'id': id});
  }
}
