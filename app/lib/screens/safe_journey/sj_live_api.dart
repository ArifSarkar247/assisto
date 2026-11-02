import '../../api.dart';

/// sjlive — the API surface of Safe Journey card 1 "Live Location" (owner
/// order 3 Nov). Built only on ApiClient's public helpers (no api.dart edit).
extension SjLiveApi on ApiClient {
  /// "Share for a while": an ordinary journey with no destination that ends
  /// by itself after [minutes] (15 min .. 24 h). POST /journey/start
  Future<Map<String, dynamic>> sjShareStart(
          {required int minutes, required List<int> watcherIds}) =>
      postJson('/journey/start', {
        'share_minutes': minutes,
        'watcher_ids': watcherIds,
        'destination': <String, dynamic>{},
      });

  /// "Who is where now": live trips / shares / location requests I may see
  /// + my School Mode children's last known place. GET /journey/where-now
  Future<List<Map<String, dynamic>>> sjWhereNow() async {
    final r = await getJson('/journey/where-now');
    return sjRows(r['people']);
  }

  /// Child School: the CCTV gate snapshot nearest today's [event]
  /// (arrived_school | left_school | left_home | reached_home).
  Future<Map<String, dynamic>> sjGateSnapshot(int planId, String event) =>
      getJson('/school-mode/plans/$planId/gate-snapshot?event=$event');

  /// Cameras I own (for linking a school gate camera). Never throws: no
  /// CCTV set up -> empty list (the picker is then hidden).
  Future<List<Map<String, dynamic>>> sjMyCameras() async {
    try {
      final r = await getJson('/shop/watchman');
      final out = <Map<String, dynamic>>[];
      for (final s in sjRows(r['sites'])) {
        for (final c in sjRows(s['cameras_list'] ?? s['cameras'])) {
          out.add({...c, 'site': s['name'] ?? ''});
        }
      }
      return out;
    } catch (_) {
      return const []; // best-effort: no CCTV feature / offline -> no picker
    }
  }
}

List<Map<String, dynamic>> sjRows(Object? raw) => raw is List
    ? raw.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList()
    : <Map<String, dynamic>>[];
