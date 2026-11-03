import 'dart:async';
import 'dart:math';

/// mapscost — destination search the cheap way (owner order 3 Nov 18:40):
///  * nothing is sent before 2 characters (jsearch, owner 4 Nov: like the
///    Google Maps app);
///  * typing waits 300 ms of quiet before ONE request (debounce);
///  * every request of one search carries the same session token, and the
///    session ends with ONE Place Details — then a fresh token starts;
///  * an answer that arrives after a newer one was asked for is dropped.
/// Pure Dart (no widgets) so it is unit-tested with fake time.
class PlaceSearchView {
  final String state; // idle | short | loading | ok | none | off | user_cap | global_cap | failed | legacy
  final List<Map<String, dynamic>> rows;
  const PlaceSearchView(this.state, [this.rows = const []]);
}

typedef SuggestFn = Future<Map<String, dynamic>> Function(String q, String session);
typedef DetailsFn = Future<Map<String, dynamic>> Function(String placeId, String session);

class PlaceSearchController {
  static const minChars = 2;
  static const debounce = Duration(milliseconds: 300);

  final SuggestFn suggest;
  final DetailsFn details;
  final void Function(PlaceSearchView) onView;
  final Random _rng;
  Timer? _timer;
  int _seq = 0;
  late String _session = _newToken();
  bool _disposed = false;

  PlaceSearchController({required this.suggest, required this.details,
      required this.onView, Random? rng})
      : _rng = rng ?? Random.secure();

  String get session => _session;

  String _newToken() {
    const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    return List.generate(32, (_) => abc[_rng.nextInt(abc.length)]).join();
  }

  /// Every keystroke. Sends at most one request per 300 ms pause.
  void onChanged(String text) {
    _timer?.cancel();
    final q = text.trim();
    if (q.length < minChars) {
      _seq++; // drop answers still on the way
      onView(PlaceSearchView(q.isEmpty ? 'idle' : 'short'));
      return;
    }
    _timer = Timer(debounce, () => _run(q));
  }

  /// The keyboard's search key: ask now (no waiting).
  Future<void> submit(String text) async {
    _timer?.cancel();
    final q = text.trim();
    if (q.length < minChars) {
      onView(PlaceSearchView(q.isEmpty ? 'idle' : 'short'));
      return;
    }
    await _run(q);
  }

  Future<void> _run(String q) async {
    final my = ++_seq;
    onView(const PlaceSearchView('loading'));
    Map<String, dynamic> r;
    try {
      r = await suggest(q, _session);
    } catch (_) {
      r = const {'state': 'failed'};
    }
    if (_disposed || my != _seq) return;
    final state = '${r['state'] ?? ''}';
    if (state.isEmpty) {
      onView(const PlaceSearchView('legacy')); // an older server: no Autocomplete
      return;
    }
    final rows = ((r['results'] ?? const []) as List)
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .where((m) => '${m['place_id'] ?? ''}'.isNotEmpty)
        .toList();
    onView(PlaceSearchView(state == 'ok' && rows.isEmpty ? 'none' : state, rows));
  }

  /// The user tapped a suggestion: ONE Place Details, then a new session.
  /// -> {lat, lng, address} or null (with the state in `error`).
  Future<({double lat, double lng, String address})?> select(String placeId,
      {void Function(String state)? error}) async {
    _timer?.cancel();
    Map<String, dynamic> r;
    try {
      r = await details(placeId, _session);
    } catch (_) {
      r = const {'state': 'failed'};
    }
    _session = _newToken();
    final lat = r['lat'], lng = r['lng'];
    if (lat is num && lng is num) {
      return (lat: lat.toDouble(), lng: lng.toDouble(), address: '${r['address'] ?? ''}');
    }
    error?.call('${r['state'] ?? 'failed'}');
    return null;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
