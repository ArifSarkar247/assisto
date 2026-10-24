import 'dart:convert';
import '../state.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;

/// Shared OFFLINE-FIRST cache helper (feature #12, SPEC v2.1 §21 —
/// good -> advanced). A tiny, reusable write-through store on top of the
/// existing [Settings] (SharedPreferences) layer that every module can adopt
/// WITHOUT touching shared state.dart, api.dart, models or the sidebar.
///
/// What it adds over ad-hoc per-module stores (dict_store, meddb_store, …):
///   • write-through: [save] persists immediately so the data survives a cold
///     start with no network;
///   • a LAST-SYNCED timestamp stored alongside every payload, so a screen can
///     honestly tell the user how fresh the offline copy is;
///   • an optional TTL so a screen can treat very old data as stale (the data
///     is still returned — we never hide it — a caller just learns it is old);
///   • one namespaced key per module, registered in [OfflineModules] so the
///     "Offline & data" screen can enumerate, inspect and CLEAR every module's
///     cache from one place.
///
/// HONEST STATES: this helper never fabricates data. [read] returns exactly
/// what was last written, or null when nothing was ever cached. [isStale] and
/// [lastSynced] let the UI label the copy truthfully.
///
/// NO Bangla glyphs live in this file (SPEC §21): it stores opaque JSON only.

/// One module's write-through cache of a JSON-serialisable value of type [T].
///
/// [T] is the in-memory shape (e.g. `List<Map<String,dynamic>>`, a model, …).
/// [encode]/[decode] bridge it to the JSON actually stored. Keys are namespaced
/// under `oc_<id>_v1` so they never collide with other modules or legacy stores.
class OfflineCache<T> {
  /// Stable module id (e.g. 'notes'); also the key the status screen shows.
  final String id;

  /// How long a cached copy is considered fresh. `null` => never goes stale.
  final Duration? ttl;

  final T Function(Object? json) decode;
  final Object? Function(T value) encode;

  OfflineCache({
    required this.id,
    required this.decode,
    required this.encode,
    this.ttl,
  });

  String get _dataKey => 'oc_${id}_v1';
  String get _stampKey => 'oc_${id}_synced_v1';

  /// Write-through: persist [value] and stamp "now" as the last-synced time.
  /// Best-effort — a storage failure never throws into the caller's happy path.
  Future<void> save(T value) async {
    try {
      await Settings.setString(_dataKey, jsonEncode(encode(value)));
      await Settings.setString(_stampKey, DateTime.now().toIso8601String());
    } catch (_) {/* best-effort; stay offline-capable */}
  }

  /// The last written value, or `null` if nothing was ever cached (or it is
  /// unreadable). Never throws. This is what makes a screen work OFFLINE.
  Future<T?> read() async {
    try {
      final raw = await Settings.getString(_dataKey);
      if (raw == null || raw.isEmpty) return null;
      return decode(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// When the cache was last written (via [save]), or `null` if never.
  Future<DateTime?> lastSynced() async {
    final raw = await Settings.getString(_stampKey);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// True when something is cached. (The timestamp is the source of truth so a
  /// cleared cache reports `false` even if a stray payload lingers.)
  Future<bool> hasData() async => (await lastSynced()) != null;

  /// True when a copy exists but is older than [ttl]. False when fresh, when
  /// there is no TTL, or when nothing is cached. The DATA is still returned by
  /// [read] regardless — staleness is only a label for the UI.
  Future<bool> isStale() async {
    if (ttl == null) return false;
    final ts = await lastSynced();
    if (ts == null) return false;
    return DateTime.now().difference(ts) > ttl!;
  }

  /// Rough on-device size of the cached payload, in bytes (0 if none). Lets the
  /// status screen show an honest "data usage" figure without guessing.
  Future<int> sizeBytes() async {
    final raw = await Settings.getString(_dataKey);
    return raw == null ? 0 : raw.length;
  }

  /// Forget this module's offline copy entirely (data + timestamp).
  Future<void> clear() async {
    try {
      await Settings.setString(_dataKey, '');
      await Settings.setString(_stampKey, '');
    } catch (_) {}
  }
}

/// A module's offline capability, surfaced on the "Offline & data" screen.
/// [cache] is optional: some modules (e.g. finance calculators) work offline
/// with NO stored data at all — their row shows a "works offline" badge but no
/// last-synced line, which is the honest state.
class OfflineModule {
  /// Stable id used as the string-table key for the module's display name.
  final String id;

  /// true => the module is usable with no network (cached data or pure-local).
  final bool worksOffline;

  /// The backing cache, or null for pure-local modules with nothing to clear.
  final OfflineCache<dynamic>? cache;

  const OfflineModule({
    required this.id,
    required this.worksOffline,
    this.cache,
  });
}

/// Central registry the "Offline & data" screen enumerates. Adding a module to
/// its own offline cache is a ONE-LINE change here — see up_offline note.
///
/// The spec's expanded offline set is listed first (notes, contacts, reminders,
/// supply-list, to-do), followed by the already-offline library/content
/// modules so the screen reflects the real app, not an aspiration.
class OfflineModules {
  OfflineModules._();

  /// Factory so a fresh, independent cache object is returned each read — these
  /// are stateless handles over SharedPreferences, cheap to re-create.
  static OfflineCache<dynamic> _cache(String id, {Duration? ttl}) =>
      OfflineCache<dynamic>(
        id: id,
        ttl: ttl,
        // The status screen only needs size / timestamp / clear, so a passthrough
        // codec is enough; adopting modules supply typed codecs of their own.
        decode: (j) => j,
        encode: (v) => v,
      );

  static List<OfflineModule> all() => [
        // --- expanded offline cache (SPEC v2.1 §21) ---
        OfflineModule(
            id: 'notes', worksOffline: true, cache: _cache('notes')),
        OfflineModule(
            id: 'contacts', worksOffline: true, cache: _cache('contacts')),
        OfflineModule(
            id: 'reminders', worksOffline: true, cache: _cache('reminders')),
        OfflineModule(
            id: 'supplyList', worksOffline: true, cache: _cache('supply_list')),
        OfflineModule(
            id: 'todo', worksOffline: true, cache: _cache('todo')),
        // --- already-offline content libraries ---
        OfflineModule(
            id: 'dictionary',
            worksOffline: true,
            cache: _cache('dictionary', ttl: Duration(days: 30))),
        // play-nomed: medical libraries are not offered in the Play flavour.
        if (kMedicalFeaturesAllowed)
        OfflineModule(
            id: 'medicineDb',
            worksOffline: true,
            cache: _cache('medicine_db', ttl: Duration(days: 30))),
        if (kMedicalFeaturesAllowed)
        OfflineModule(
            id: 'healthTips',
            worksOffline: true,
            cache: _cache('health_tips', ttl: Duration(days: 14))),
        // --- pure-local, no stored payload to clear ---
        const OfflineModule(id: 'financeCalc', worksOffline: true, cache: null),
      ];
}
