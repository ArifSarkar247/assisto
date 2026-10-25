import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart' show ThemeMode, Locale;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'home_api.dart';
import 'db.dart';
import 'models.dart';
import 'sync_repo.dart';
import 'background.dart';
import 'push/push_service.dart';
import 'security/secret_store.dart';
import 'services/error_report.dart';
import 'services/own_device_guard.dart'; // grab-guard
import 'crypto/e2e.dart';
import 'crypto/key_service.dart';
import 'crypto/identity_vault.dart';

class AppState extends ChangeNotifier {
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
      await SecretStore.instance.write(_localeKey, code).timeout(_ioTimeout);
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
      final v = await SecretStore.instance.read(_localeKey).timeout(_ioTimeout);
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
    // Settings never throws now; keep reporting a broken store once.
    final se = Settings.lastError;
    if (se != null) prefsError ??= 'prefs read theme: $se';
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

  // ---------- dl1: signed in during an account-deletion grace period ----------
  /// Set right after a sign-in when the account has a PENDING deletion: the
  /// root then shows the grace screen ("Restore account" / "Delete now and
  /// start fresh") before anything else. Null = nothing pending.
  DateTime? deletionGraceAt;

  /// Whether "Delete now and start fresh" will also ask for an SMS code
  /// (server: SMS connected + a BD mobile on the account).
  bool deletionGraceOtp = false;

  /// Best-effort: never blocks or fails a sign-in.
  Future<void> _checkDeletionGrace() async {
    deletionGraceAt = null;
    deletionGraceOtp = false;
    try {
      final st = await api
          .accountDeleteStatus()
          .timeout(const Duration(seconds: 8));
      if ('${st['state']}' == 'pending') {
        deletionGraceAt =
            DateTime.tryParse('${st['effective_at']}')?.toLocal() ??
                DateTime.now();
        deletionGraceOtp = st['otp_required'] == true;
      }
    } catch (_) {}
  }

  /// The user restored the account: leave the grace screen and continue
  /// into the app.
  void clearDeletionGrace() {
    deletionGraceAt = null;
    deletionGraceOtp = false;
    notifyListeners();
  }

  /// "Delete now and start fresh" succeeded: the old account is gone on the
  /// server, so drop its local data and adopt the new, empty account.
  Future<void> adoptFreshAccount(String token, AppUser fresh) async {
    try {
      await db.clearAll();
      for (final r in _repos) {
        await r.clear();
      }
    } catch (_) {}
    memory = [];
    deletionGraceAt = null;
    deletionGraceOtp = false;
    await adoptSession(token, fresh, checkGrace: false);
  }

  Future<void> init() async {
    // Startup must ALWAYS finish (loading=false) even if storage/db/network
    // misbehave — otherwise the app hangs on the splash spinner. Each piece is
    // guarded independently so one failure never blocks the rest.
    try {
      await _loadPrefs();
    } catch (_) {}
    String? t;
    try {
      t = await SecretStore.instance.read('token');
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
        unawaited(OwnDeviceGuard.rememberUser(user?.id)); // grab-guard
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
    String? otpProof,
  }) async {
    final res = await api.register(
        name: name,
        phone: phone,
        email: email,
        password: password,
        otpProof: otpProof);
    await _finishSignIn(res.token, res.user);
  }

  Future<void> login(
      {required String identifier, required String password}) async {
    final res = await api.login(identifier: identifier, password: password);
    await _finishSignIn(res.token, res.user);
  }

  /// o1-otp: adopt a session issued by a non-password sign-in (OTP login).
  /// [checkGrace] false = the start-fresh flow (dl1), already decided.
  Future<void> adoptSession(String token, AppUser signedIn,
          {bool checkGrace = true}) =>
      _finishSignIn(token, signedIn, checkGrace: checkGrace);

  /// Shared post-sign-in steps. The token goes to the app-sandbox
  /// [SecretStore] (never fails because of the Keystore), and sign-in is not
  /// done until our E2E public key is on the server (owner rule 22 Oct).
  Future<void> _finishSignIn(String token, AppUser signedIn,
      {bool checkGrace = true}) async {
    api.token = token;
    user = signedIn;
    unawaited(OwnDeviceGuard.rememberUser(signedIn.id)); // grab-guard
    if (!await SecretStore.instance.write('token', token)) {
      reportNonFatal('auth.token_write', SecretStore.instance.lastError);
    }
    if (checkGrace) await _checkDeletionGrace();
    await _publishIdentityKey();
    await reconcileLanguage();
    unawaited(Background.start());
    await sync();
    _syncAll();
    notifyListeners();
  }

  /// Create (if needed) and upload the E2E public key, with retry. If the
  /// network keeps failing, the key service carries on with its backoff and
  /// every app start publishes again — never a silent empty identity.
  Future<void> _publishIdentityKey() async {
    const waits = [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)];
    for (var attempt = 0; attempt <= waits.length; attempt++) {
      try {
        final id = await IdentityVault.instance.get();
        await api.postJson('/circle/keys', {
          'public_key': id.publicKeyB64,
          'key_id': id.keyId,
          'scheme': SoftwareE2E().scheme,
        }).timeout(const Duration(seconds: 8));
        return;
      } catch (e) {
        reportNonFatal('auth.key_publish', e);
        if (attempt < waits.length) await Future<void>.delayed(waits[attempt]);
      }
    }
    unawaited(KeyService.instance
        .publish((p, b) => api.postJson(p, b), reason: 'login'));
  }

  /// Local sign-out ALWAYS completes and the login screen shows at once —
  /// on every phone, even when the network or the Keystore hangs (owner bug:
  /// logout did nothing on OPPO). Server + push cleanup run afterwards in the
  /// background, each step time-boxed and independent.
  Future<void> logout() async {
    final oldToken = api.token;
    await _signOutLocally();
    unawaited(_serverSignOut(oldToken));
  }

  /// Uses its OWN client carrying the old token, so the app's shared client
  /// never gets a signed-out token back.
  Future<void> _serverSignOut(String? oldToken) async {
    if (oldToken == null) return;
    final cleanup = ApiClient.detached(oldToken);
    try {
      await PushService.instance
          .onLogout(api: cleanup)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      reportNonFatal('logout.push', e);
    }
    try {
      await cleanup.logout().timeout(const Duration(seconds: 8));
    } catch (e) {
      reportNonFatal('logout.server', e);
    }
  }

  /// Clear this phone's session + local data. Every step is independent and
  /// time-boxed; the UI is told first so the login screen appears at once.
  Future<void> _signOutLocally() async {
    api.token = null;
    user = null;
    unawaited(OwnDeviceGuard.forget()); // grab-guard
    deletionGraceAt = null;
    deletionGraceOtp = false;
    memory = [];
    notifyListeners();
    await _step('logout.token', SecretStore.instance.delete('token'));
    await _step('logout.background', Background.stop());
    await _step('logout.db', db.clearAll());
    for (final r in _repos) {
      await _step('logout.repo', r.clear());
    }
    notifyListeners();
  }

  Future<void> _step(String where, Future<void> f) async {
    try {
      await f.timeout(const Duration(seconds: 2));
    } catch (e) {
      reportNonFatal(where, e);
    }
  }

  Future<void> _clearSession() => _signOutLocally();

  Future<void> deleteAccount() async {
    // The server must accept the deletion first (that can fail — the caller
    // shows the honest error); after that the local wipe always completes.
    await api.deleteAccount().timeout(const Duration(seconds: 20));
    await _signOutLocally();
  }


  /// Patch profile fields (safety settings, elderly mode, etc.) via /me.
  /// Returns false when the server did not take the change (q1-seams: callers
  /// that show a setting as saved must check this — it used to be swallowed).
  Future<bool> saveProfile(Map<String, dynamic> fields) async {
    try {
      user = await api.updateProfile(fields);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
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
          language: prev.language,
          photoUrl: prev.photoUrl,
          isFounder: prev.isFounder,
          founderSince: prev.founderSince,
          founderPremiumUntil: prev.founderPremiumUntil);
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
///
/// m3-circle (owner bug "Phone Safety Check-up spins forever"): on real
/// release builds SharedPreferences.getInstance() THROWS (client crash log:
/// `PlatformException ... NoSuchMethodError ... SharedPreferencesApiRegistrar
/// .getAll`), and every screen that awaited a Settings read without its own
/// try/catch (Phone Safety's `_load`) never left its spinner. Settings now
/// NEVER throws and NEVER hangs: each call has a short timeout and falls back
/// to an in-memory copy for this app session. [degraded] says honestly that
/// values will not survive an app restart; [lastError] is reported once.
class Settings {
  /// Swappable for tests (simulate the device's broken / hanging store).
  @visibleForTesting
  static Future<SharedPreferences> Function() prefsProvider =
      SharedPreferences.getInstance;

  static const Duration _timeout = Duration(seconds: 3);
  static final Map<String, Object> _memory = {};

  /// True once the persistent store failed in this session.
  static bool degraded = false;

  /// The first storage error seen (for the startup crash report).
  static String? lastError;

  @visibleForTesting
  static void resetForTest() {
    _memory.clear();
    degraded = false;
    lastError = null;
    prefsProvider = SharedPreferences.getInstance;
  }

  static Future<SharedPreferences?> _prefs() async {
    try {
      return await prefsProvider().timeout(_timeout);
    } catch (e) {
      degraded = true;
      if (lastError == null) {
        // Release builds too: the CI launch smoke fails on this marker, so a
        // broken settings store can never ship silently again.
        // ignore: avoid_print
        print('ASSISTO_PREFS_FAIL $e');
      }
      lastError ??= '$e';
      return null;
    }
  }

  // The in-memory copy is ONLY a fallback for a store that failed; a healthy
  // store is always the source of truth (so a cleared store reads as empty).
  static Future<bool> getBool(String k, bool def) async {
    final p = await _prefs();
    if (p != null) {
      try {
        return p.getBool(k) ?? def;
      } catch (e) {
        lastError ??= '$e';
      }
    }
    final m = _memory[k];
    return m is bool ? m : def;
  }

  static Future<void> setBool(String k, bool v) async {
    _memory[k] = v;
    final p = await _prefs();
    if (p == null) return;
    try {
      await p.setBool(k, v).timeout(_timeout);
    } catch (e) {
      degraded = true;
      lastError ??= '$e';
    }
  }

  static Future<String?> getString(String k) async {
    final p = await _prefs();
    if (p != null) {
      try {
        return p.getString(k);
      } catch (e) {
        lastError ??= '$e';
      }
    }
    final m = _memory[k];
    return m is String ? m : null;
  }

  static Future<void> setString(String k, String v) async {
    _memory[k] = v;
    final p = await _prefs();
    if (p == null) return;
    try {
      await p.setString(k, v).timeout(_timeout);
    } catch (e) {
      degraded = true;
      lastError ??= '$e';
    }
  }
}
