import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'feature_registry.dart';
import 'state.dart' show Settings;

/// One answer of GET /features (status 200 with a body, or 304 = unchanged).
typedef FeaturesFetch
    = Future<({int status, Map<String, dynamic>? body, String? etag})> Function(
        String? etag);

/// feature-flags — the ONE central "may this user see feature X?" check
/// (owner rule 26 Oct: a feature is visible only when all 9 Definition-of-Done
/// checks pass; until then its server flag hides it, and the Play build can
/// hide it separately).
///
/// Every entry point asks this: the drawer ([SidebarItem.visible]), ChatNav
/// routes (chat replies, Discover / home suggestions, quick buttons, watch
/// feed, notification centre, pushes, voice), the My Circle quick-link, the
/// business-hub AI sales agent card and the live-tracking buttons. A hidden
/// feature therefore has no entry anywhere; a stale link to it shows the
/// friendly "not available" notice instead (ChatNav.push / builderFor).
///
/// Source of truth, in order: a test override -> the last server answer
/// (GET /features, cached in prefs; offline = last known) -> the shipped
/// registry defaults ([kFeatureDefaults] = today's behaviour, used on a first
/// run with no network). Fetched after sign-in and on every app open/resume
/// (throttled), with an ETag so an unchanged set costs a tiny 304. The owner
/// and allow-listed testers get hidden features too (server "preview" list),
/// so a hidden feature can be tested on a real phone.
class FeatureFlags extends ChangeNotifier {
  FeatureFlags._();
  static final FeatureFlags instance = FeatureFlags._();

  static const prefsKey = 'feature_flags_v1';
  static const minRefreshGap = Duration(seconds: 60);

  Map<String, bool>? _server;
  Set<String> _preview = {};
  String? _etag;
  DateTime? _fetchedAt;
  Future<bool>? _inFlight;

  /// Test-only per-key override (wins over everything).
  @visibleForTesting
  Map<String, bool>? debugOverride;

  /// True when [key] may be shown. A null / unknown key is a core entry and
  /// is always visible (a typo never hides a feature).
  bool isOn(String? key) {
    if (key == null) return true;
    final o = debugOverride?[key];
    if (o != null) return o;
    final s = _server?[key];
    if (s != null) return s;
    return kFeatureDefaults[key] ?? true;
  }

  /// Visible only because this user is the owner / staff / a listed tester.
  bool isPreview(String key) => _preview.contains(key);

  /// The flag that owns a ChatNav [route] (null = never flag-hidden).
  static String? featureOf(String? route) =>
      route == null ? null : kRouteFeature[route];

  /// May a ChatNav [route] open? (medical gating is separate: feature_gates.)
  bool routeAllowed(String? route) => isOn(featureOf(route));

  /// A route that exists but whose feature is hidden for this user.
  bool isHiddenRoute(String? route) =>
      featureOf(route) != null && !routeAllowed(route);

  /// Last known server answer from prefs (call once at startup). Never
  /// throws: a broken store just means "registry defaults".
  Future<void> load() async {
    try {
      final raw = await Settings.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _apply(j, notify: false);
      _etag = j['_etag'] as String?;
    } catch (_) {}
  }

  /// Ask the server (throttled unless [force]). Offline / any error keeps the
  /// last known set. Returns true when the visible set changed.
  Future<bool> refresh(FeaturesFetch fetch, {bool force = false}) {
    final last = _fetchedAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < minRefreshGap) {
      return Future.value(false);
    }
    return _inFlight ??= _refresh(fetch).whenComplete(() => _inFlight = null);
  }

  Future<bool> _refresh(FeaturesFetch fetch) async {
    try {
      final r = await fetch(_etag).timeout(const Duration(seconds: 10));
      _fetchedAt = DateTime.now();
      if (r.status == 304 || r.body == null) return false;
      final before = _snapshot();
      _apply(r.body!, notify: false);
      _etag = r.etag;
      unawaited(
          Settings.setString(prefsKey, jsonEncode({...r.body!, '_etag': _etag}))
              .catchError((_) {}));
      final changed = !mapEquals(before, _snapshot());
      if (changed) notifyListeners();
      return changed;
    } catch (_) {
      return false; // offline / server trouble: keep the last known set
    }
  }

  /// Convenience for the app: GET /features through the shared client.
  Future<bool> refreshWith(ApiClient api, {bool force = false}) =>
      refresh((etag) => api.getJsonEtag('/features?fv=$kFeaturesVersion', etag),
          force: force);

  /// Sign-out: the next person on this phone must not keep the owner's /
  /// tester's preview of hidden features, and the next fetch is fresh.
  void forgetUser() {
    final s = _server;
    if (s != null) {
      for (final k in _preview) {
        s[k] = false;
      }
    }
    _preview = {};
    _etag = null;
    _fetchedAt = null;
    unawaited(Settings.setString(
        prefsKey,
        jsonEncode({
          'features': _server ?? const <String, bool>{},
          'preview': const <String>[],
        })).catchError((_) {}));
    notifyListeners();
  }

  void _apply(Map<String, dynamic> j, {bool notify = true}) {
    final f = j['features'];
    // unseen-rename: an answer WITHOUT the new key comes from a server (or a
    // prefs cache) of before the rename, where `unseen_world` meant the daily
    // info hub. Read it as `daily_info`, and drop `unseen_world` so the new
    // travel feature keeps its own default (hidden) until a fresh answer.
    final legacy = f is Map && !f.containsKey('daily_info');
    if (f is Map) {
      _server = {
        for (final e in f.entries)
          if (e.value is bool) '${e.key}': e.value as bool,
      };
      if (legacy) {
        for (final e in kLegacyFeatureKeys.entries) {
          final v = _server!.remove(e.key);
          if (v != null) _server![e.value] = v;
        }
      }
    }
    final p = j['preview'];
    _preview = p is List ? {for (final k in p) '$k'} : {};
    if (legacy) {
      for (final e in kLegacyFeatureKeys.entries) {
        if (_preview.remove(e.key)) _preview.add(e.value);
      }
    }
    if (notify) notifyListeners();
  }

  Map<String, bool> _snapshot() =>
      {for (final k in kFeatureDefaults.keys) k: isOn(k)};

  @visibleForTesting
  void resetForTest() {
    _server = null;
    _preview = {};
    _etag = null;
    _fetchedAt = null;
    _inFlight = null;
    debugOverride = null;
  }

  @visibleForTesting
  void applyForTest(Map<String, dynamic> j) => _apply(j);
}
