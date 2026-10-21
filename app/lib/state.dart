import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart' show ThemeMode, Locale;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'home_api.dart';
import 'db.dart';
import 'models.dart';
import 'sync_repo.dart';
import 'background.dart';

class AppState extends ChangeNotifier {
  final _secure = const FlutterSecureStorage();
  ApiClient api = ApiClient(); // non-final so tests/previews can inject a fake
  final LocalDb db = LocalDb.instance;

  bool loading = true;
  bool syncing = false;
  bool online = true;
  String? lastError;

  // --- app-wide preferences (theme + language) ---
  ThemeMode themeMode = ThemeMode.system;
  Locale? locale; // null => first-launch not chosen yet / follow default
  bool onboarded = true; // shown once on first login

  void markOnboarded() {
    onboarded = true;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    await Settings.setString('theme_mode', m.name);
    notifyListeners();
  }

  // Why the first-run language gate could come back on every launch: the
  // choice lived ONLY in SharedPreferences, and every read/write failure was
  // swallowed. If that store fails on a device (the login token, in secure
  // storage, survived), locale stayed null at each cold start → gate again.
  // Now the choice is kept in THREE places — SharedPreferences, secure storage
  // and the user's server profile — and any one of them is enough.
  static const _localeKey = 'locale';
  static const _ioTimeout = Duration(seconds: 3);

  /// Last local-storage failure (sent once as a diagnostic when logged in).
  String? prefsError;

  Future<void> setLocale(Locale? l, {bool syncServer = true}) async {
    locale = l;
    api.lang = l?.languageCode;
    // Advance the UI IMMEDIATELY. The chosen language is already live in memory,
    // so the first-run gate (locale == null) clears right away and "Continue"
    // always works — even offline or if local storage is slow/unavailable.
    // Persistence is best-effort and must NEVER block or throw past this point;
    // a hung/failing SharedPreferences write used to freeze the language screen
    // (notifyListeners sat behind the await, so the tap did nothing).
    notifyListeners();
    final code = l?.languageCode ?? '';
    try {
      await Settings.setString(_localeKey, code).timeout(_ioTimeout);
    } catch (e) {
      prefsError ??= 'prefs write locale: $e';
    }
    try {
      await _secure.write(key: _localeKey, value: code).timeout(_ioTimeout);
    } catch (e) {
      prefsError ??= 'secure write locale: $e';
    }
    if (syncServer) unawaited(_pushLanguageToServer());
  }

  /// Keep the server profile in step with the local choice (best-effort).
  Future<void> _pushLanguageToServer() async {
    final code = locale?.languageCode;
    final u = user;
    if (code == null || u == null || api.token == null) return;
    if (u.language == code) return;
    try {
      user = await api.updateProfile({'language': code});
    } catch (_) {/* offline — the next launch/login retries */}
  }

  /// After the profile loads: a phone with no saved choice (new phone,
  /// reinstall, or broken local storage) takes the server language, so a
  /// logged-in user never sees the gate. A local choice made on this phone
  /// (e.g. at the gate just before logging in) is pushed to the server.
  Future<void> reconcileLanguage() async {
    final server = user?.language;
    if (server != 'bn' && server != 'en') return;
    if (locale == null) {
      await setLocale(Locale(server!), syncServer: false);
    } else if (locale!.languageCode != server) {
      await _pushLanguageToServer();
    }
  }

  Future<String?> _readLocale() async {
    try {
      final v = await Settings.getString(_localeKey).timeout(_ioTimeout);
      if (v != null && v.isNotEmpty) return v;
    } catch (e) {
      prefsError ??= 'prefs read locale: $e';
    }
    try {
      final v = await _secure.read(key: _localeKey).timeout(_ioTimeout);
      if (v != null && v.isNotEmpty) {
        // heal the primary store when it lost the value
        unawaited(Settings.setString(_localeKey, v)
            .timeout(_ioTimeout)
            .catchError((_) {}));
        return v;
      }
    } catch (e) {
      prefsError ??= 'secure read locale: $e';
    }
    return null;
  }

  Future<void> _loadPrefs() async {
    // Each read is guarded on its own: one failing key must never wipe the
    // others (the old single try/catch around all of them lost the language).
    try {
      final tm = await Settings.getString('theme_mode').timeout(_ioTimeout);
      themeMode = ThemeMode.values.firstWhere(
        (m) => m.name == tm,
        orElse: () => ThemeMode.system,
      );
    } catch (e) {
      prefsError ??= 'prefs read theme: $e';
    }
    final lc = await _readLocale();
    if (lc != null) locale = Locale(lc);
    api.lang = locale?.languageCode;
    try {
      onboarded = await Settings.getBool('onboarded', false).timeout(_ioTimeout);
    } catch (e) {
      prefsError ??= 'prefs read onboarded: $e';
    }
  }

  AppUser? user;
  List<MemoryItem> memory = [];

  late final SyncedRepo reminders = SyncedRepo('reminder', 'reminders', api, db);
  late final SyncedRepo notes = SyncedRepo('note', 'notes', api, db);
  late final SyncedRepo todos = SyncedRepo('todo', 'todos', api, db);
  late final SyncedRepo accounts = SyncedRepo('account', 'accounts', api, db);
  late final SyncedRepo txns = SyncedRepo('txn', 'transactions', api, db);
  late final SyncedRepo budgets = SyncedRepo('budget', 'budgets', api, db);
  late final SyncedRepo loans = SyncedRepo('loan', 'loans', api, db);
  late final SyncedRepo goals = SyncedRepo('goal', 'goals', api, db);

  List<SyncedRepo> get _repos =>
      [reminders, notes, todos, accounts, txns, budgets, loans, goals];

  AppState() {
    for (final r in _repos) {
      r.addListener(notifyListeners);
    }
  }

  void _syncAll() {
    for (final r in _repos) {
      r.sync();
    }
  }

  Future<bool> undoLast() async {
    final ok = await api.undo();
    if (ok) {
      _syncAll();
    }
    return ok;
  }

  bool get loggedIn => api.token != null && user != null;

  Future<void> init() async {
    // Startup must ALWAYS finish (loading=false) even if storage/db/network
    // misbehave — otherwise the app hangs on the splash spinner. Each piece is
    // guarded independently so one failure never blocks the rest.
    try {
      await _loadPrefs();
    } catch (_) {}
    String? t;
    try {
      t = await _secure.read(key: 'token');
      api.token = t;
    } catch (_) {}
    try {
      memory = await db.allMemory();
      for (final r in _repos) {
        await r.load();
      }
    } catch (_) {}
    if (t != null) {
      try {
        user = await api.me();
        await reconcileLanguage();
        await sync();
        _syncAll();
        // Background poller must never block or crash startup.
        unawaited(Background.start());
      } catch (e) {
        // offline or token issue — stay with whatever we have locally
        online = false;
        if (e is ApiException && e.status == 401) {
          await _clearSession();
        }
      }
    }
    loading = false;
    notifyListeners();
    // Tell us (once per launch) when local storage misbehaves on a device, so
    // a real root cause shows up in the server log instead of being swallowed.
    final pe = prefsError;
    if (pe != null && loggedIn) {
      unawaited(api.reportStartupCrash('[prefs] $pe').catchError((_) {}));
    }
  }

  // ---------- auth ----------
  Future<void> register({
    required String name,
    String? phone,
    String? email,
    required String password,
  }) async {
    final res = await api.register(
        name: name, phone: phone, email: email, password: password);
    api.token = res.token;
    user = res.user;
    await _secure.write(key: 'token', value: res.token);
    await reconcileLanguage();
    unawaited(Background.start());
    await sync();
    _syncAll();
    notifyListeners();
  }

  Future<void> login(
      {required String identifier, required String password}) async {
    final res = await api.login(identifier: identifier, password: password);
    api.token = res.token;
    user = res.user;
    await _secure.write(key: 'token', value: res.token);
    await reconcileLanguage();
    unawaited(Background.start());
    await sync();
    _syncAll();
    notifyListeners();
  }

  Future<void> logout() async {
    await api.logout();
    await _clearSession();
    await db.clearAll();
    for (final r in _repos) {
      await r.clear();
    }
    memory = [];
    notifyListeners();
  }

  Future<void> _clearSession() async {
    api.token = null;
    user = null;
    await _secure.delete(key: 'token');
    await Background.stop();
  }

  Future<void> deleteAccount() async {
    await api.deleteAccount();
    await _clearSession();
    await db.clearAll();
    memory = [];
    notifyListeners();
  }

  /// Patch profile fields (safety settings, elderly mode, etc.) via /me.
  Future<void> saveProfile(Map<String, dynamic> fields) async {
    try {
      user = await api.updateProfile(fields);
      notifyListeners();
    } catch (_) {}
  }

  /// Adopt an authoritative user returned by the backend (e.g. after the
  /// profile editor saves) so every surface that reads [user] — the Settings
  /// profile card, avatars — refreshes immediately without a second upload.
  void setUser(AppUser u) {
    user = u;
    notifyListeners();
  }

  Future<void> setAutonomy(int level) async {
    final prev = user;
    if (prev == null) return;
    try {
      user = await api.updateProfile({'autonomy_level': level});
    } catch (_) {
      // keep local optimistic value offline
      user = AppUser(
          id: prev.id,
          name: prev.name,
          phone: prev.phone,
          email: prev.email,
          autonomyLevel: level,
          language: prev.language);
    }
    notifyListeners();
  }

  // ---------- memory (offline-first) ----------
  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  Future<void> addMemory(
      {required String title, String category = '', String detail = ''}) async {
    final m = MemoryItem(
      localId: _newId(),
      title: title,
      category: category,
      detail: detail,
      source: 'manual',
      updatedAt: DateTime.now(),
      pendingOp: 'create',
    );
    await db.upsert(m);
    memory = await db.allMemory();
    notifyListeners();
    await sync();
  }

  Future<void> editMemory(MemoryItem m,
      {required String title, String category = '', String detail = ''}) async {
    m.title = title;
    m.category = category;
    m.detail = detail;
    m.updatedAt = DateTime.now();
    m.pendingOp = m.pendingOp == 'create' ? 'create' : 'update';
    await db.upsert(m);
    memory = await db.allMemory();
    notifyListeners();
    await sync();
  }

  Future<void> removeMemory(MemoryItem m) async {
    if (m.serverId == null) {
      // never synced — just drop it
      await db.hardDelete(m.localId);
    } else {
      m.pendingOp = 'delete';
      await db.upsert(m);
    }
    memory = await db.allMemory();
    notifyListeners();
    await sync();
  }

  /// Push local pending changes, then pull the server set. Best-effort; silently
  /// stays offline-capable if the network is down.
  Future<void> sync() async {
    if (api.token == null || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      for (final m in await db.pendingMemory()) {
        if (m.pendingOp == 'create') {
          final j = await api.createMemory(m.toServerJson());
          m.serverId = j['id'] as int;
          m.pendingOp = 'none';
          await db.upsert(m);
        } else if (m.pendingOp == 'update' && m.serverId != null) {
          await api.updateMemory(m.serverId!, m.toServerJson());
          m.pendingOp = 'none';
          await db.upsert(m);
        } else if (m.pendingOp == 'delete' && m.serverId != null) {
          await api.deleteMemory(m.serverId!);
          await db.hardDelete(m.localId);
        }
      }
      final server = await api.listMemory();
      final items = server
          .map((j) => MemoryItem(
                localId: 'srv-${j['id']}',
                serverId: j['id'] as int,
                category: (j['category'] ?? '') as String,
                title: (j['title'] ?? '') as String,
                detail: (j['detail'] ?? '') as String,
                source: (j['source'] ?? 'manual') as String,
                needsReview: (j['needs_review'] ?? false) as bool,
                updatedAt: DateTime.tryParse(
                        (j['updated_at'] ?? '') as String) ??
                    DateTime.now(),
                pendingOp: 'none',
              ))
          .toList();
      await db.replaceSynced(items);
      memory = await db.allMemory();
      online = true;
      lastError = null;
    } catch (e) {
      online = false;
      lastError = e.toString();
    } finally {
      syncing = false;
      notifyListeners();
    }
  }
}

/// Simple settings store (shared_preferences) for non-sensitive prefs.
class Settings {
  static Future<bool> getBool(String k, bool def) async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(k) ?? def;
  }

  static Future<void> setBool(String k, bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(k, v);
  }

  static Future<String?> getString(String k) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(k);
  }

  static Future<void> setString(String k, String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(k, v);
  }
}
