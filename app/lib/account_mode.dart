import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'state.dart' show Settings;

/// acctmode (owner order 2 Nov, PART 1 e): accounts & finance mode —
/// personal only / business only / personal + business.
///
/// A VIEW PREFERENCE ONLY. Personal books (money) and business books (khata,
/// products) are separate server tables, so a switch in ANY direction never
/// deletes, moves or re-tags an entry: it only decides which areas the menus
/// (sidebar / All Services) list. Search, chat and direct links still open
/// every area, and a hidden area's screen offers "Show in menu again".
///
/// Users who never chose stay on [AccountMode.both] = exactly the app they had.
enum AccountMode { personal, business, both }

/// The two areas a menu entry can belong to (null = shown in every mode).
enum AcctArea { personal, business }

AccountMode? accountModeFromCode(Object? s) => switch ('${s ?? ''}') {
      'personal' => AccountMode.personal,
      'business' => AccountMode.business,
      'both' => AccountMode.both,
      _ => null,
    };

/// Does [mode] list [area] in the menus?
bool accountModeShows(AccountMode mode, AcctArea area) =>
    mode == AccountMode.both ||
    (area == AcctArea.personal
        ? mode == AccountMode.personal
        : mode == AccountMode.business);

/// Areas [mode] hides that still hold entries (from the server usage map).
List<AcctArea> accountModeHiddenWithData(
    AccountMode mode, Map<String, dynamic> usage) {
  bool used(String k) => (usage[k] is Map) && usage[k]['used'] == true;
  return [
    if (!accountModeShows(mode, AcctArea.personal) && used('personal'))
      AcctArea.personal,
    if (!accountModeShows(mode, AcctArea.business) && used('business'))
      AcctArea.business,
  ];
}

extension AccountModeApi on ApiClient {
  /// GET /account-mode -> {mode, chosen, suggested, usage, hidden_with_data}.
  Future<Map<String, dynamic>> accountModeGet() => getJson('/account-mode');

  /// POST /account-mode {mode, source} — touches ONLY the preference row.
  Future<Map<String, dynamic>> accountModeSet(AccountMode m,
          {String source = 'settings'}) =>
      postJson('/account-mode', {'mode': m.name, 'source': source});
}

class AccountModeController extends ChangeNotifier {
  AccountModeController._();
  static final AccountModeController instance = AccountModeController._();

  static const prefsKey = 'acct_mode_v1';

  AccountMode _mode = AccountMode.both;
  bool _chosen = false;
  bool _synced = true;
  AccountMode? _suggested;
  Map<String, dynamic> _usage = const {};
  bool _localLoaded = false;
  Future<void>? _inFlight;

  AccountMode get mode => _mode;
  bool get chosen => _chosen;
  AccountMode? get suggested => _suggested;
  Map<String, dynamic> get usage => _usage;

  /// True while a local choice has not reached the server yet.
  bool get pendingSync => !_synced;

  bool shows(AcctArea? area) => area == null || accountModeShows(_mode, area);

  int get personalEntries => _count('personal', 'entries');
  int get businessParties => _count('business', 'parties');
  int get businessProducts => _count('business', 'products');

  int _count(String area, String k) {
    final a = _usage[area];
    return a is Map ? ((a[k] as num?)?.toInt() ?? 0) : 0;
  }

  Future<void> _loadLocal() async {
    if (_localLoaded) return;
    _localLoaded = true;
    try {
      final raw = await Settings.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final m = accountModeFromCode(j['m']);
      if (m == null) return;
      _mode = m;
      _chosen = j['c'] == true;
      _synced = j['s'] != false;
      notifyListeners();
    } catch (_) {/* corrupt cache -> stay on both (nothing hidden) */}
  }

  Future<void> _saveLocal() => Settings.setString(
      prefsKey, jsonEncode({'m': _mode.name, 'c': _chosen, 's': _synced}));

  /// Cached choice first (instant menus), then the server (cross-device).
  /// A local choice not yet synced (e.g. made offline) is pushed up instead
  /// of being overwritten. Safe to call often; one request at a time.
  Future<void> refresh(ApiClient api) =>
      _inFlight ??= _refresh(api).whenComplete(() => _inFlight = null);

  Future<void> _refresh(ApiClient api) async {
    await _loadLocal();
    try {
      if (_chosen && !_synced) {
        _applyServer(await api.accountModeSet(_mode, source: 'resync'));
      } else {
        _applyServer(await api.accountModeGet());
      }
    } catch (_) {/* offline: keep the cached mode */}
  }

  void _applyServer(Map<String, dynamic> j) {
    final m = accountModeFromCode(j['mode']);
    if (m != null) {
      _mode = m;
      _chosen = j['chosen'] == true;
      _synced = true;
    }
    _suggested = accountModeFromCode(j['suggested']);
    final u = j['usage'];
    if (u is Map) _usage = Map<String, dynamic>.from(u);
    _saveLocal();
    notifyListeners();
  }

  /// Switch mode. Applied locally at once (menus update immediately), then
  /// saved on the server; offline it stays local and syncs on the next
  /// [refresh]. Never touches any entry. Returns false if not yet synced.
  Future<bool> set(AccountMode m,
      {ApiClient? api, String source = 'settings'}) async {
    await _loadLocal();
    _mode = m;
    _chosen = true;
    _synced = false;
    await _saveLocal();
    notifyListeners();
    if (api == null) return false;
    try {
      _applyServer(await api.accountModeSet(m, source: source));
      return true;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  void resetForTest() {
    _mode = AccountMode.both;
    _chosen = false;
    _synced = true;
    _suggested = null;
    _usage = const {};
    _localLoaded = false;
    _inFlight = null;
    notifyListeners();
  }

  @visibleForTesting
  void debugSet(AccountMode m, {Map<String, dynamic>? usage}) {
    _localLoaded = true;
    _mode = m;
    _chosen = true;
    if (usage != null) _usage = usage;
    notifyListeners();
  }
}
