// Owner bug: the first-run language gate came back on EVERY app open.
//
// The choice lived only in SharedPreferences and every read/write failure was
// swallowed, so a device whose prefs store misbehaved (while the login token in
// secure storage survived) started each launch with locale == null → gate.
// The fix keeps the choice in SharedPreferences + secure storage + the user's
// server profile; any one of them is enough. These tests pin that the gate
// never returns after cold starts, an app update, lost prefs, or logout, and
// that a logged-in user with a server language never sees it.
import 'package:flutter/material.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';

/// The first-run gate in main.dart is exactly `app.locale == null`.
bool gateShows(AppState app) => app.locale == null;

/// A cold start: a brand-new AppState that loads from whatever is persisted.
Future<AppState> coldStart() async {
  final app = AppState();
  await app.init();
  return app;
}

class _ProfileApi extends ApiClient {
  _ProfileApi(this.serverLanguage);
  String serverLanguage;
  final patches = <Map<String, dynamic>>[];

  AppUser _user() => AppUser(
      id: 7, name: 'Owner', autonomyLevel: 2, language: serverLanguage);

  @override
  Future<AppUser> me() async => _user();

  @override
  Future<AppUser> updateProfile(Map<String, dynamic> fields) async {
    patches.add(fields);
    serverLanguage = (fields['language'] ?? serverLanguage) as String;
    return _user();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('pick language → 3 cold starts → gate never shows', () async {
    final first = await coldStart();
    expect(gateShows(first), isTrue, reason: 'true first install shows it once');
    await first.setLocale(const Locale('en'));

    for (var i = 1; i <= 3; i++) {
      final app = await coldStart();
      expect(gateShows(app), isFalse, reason: 'cold start #$i');
      expect(app.locale, const Locale('en'));
    }
  });

  test('app update (new version keys, same data) → gate never shows', () async {
    final app = await coldStart();
    await app.setLocale(const Locale('bn'));
    // An update keeps the app's data and adds whatever the new version writes.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_version_seen', '1.0.147');
    await prefs.setBool('some_new_feature_flag', true);

    final updated = await coldStart();
    expect(gateShows(updated), isFalse);
    expect(updated.locale, const Locale('bn'));
  });

  test('prefs store lost/broken → secure-storage copy keeps the choice and heals prefs',
      () async {
    final app = await coldStart();
    await app.setLocale(const Locale('en'));

    // Simulate the device's SharedPreferences coming back empty.
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    final next = await coldStart();
    expect(gateShows(next), isFalse);
    expect(next.locale, const Locale('en'));
    await Future<void>.delayed(Duration.zero); // let the heal write land
    expect(prefs.getString('locale'), 'en', reason: 'primary store healed');
  });

  test('logged-in user with a server language never sees the gate (new phone / reinstall)',
      () async {
    final app = AppState()..api = _ProfileApi('en');
    // nothing saved locally at all
    expect(gateShows(app), isTrue);
    app.user = await app.api.me();
    await app.reconcileLanguage();
    expect(gateShows(app), isFalse);
    expect(app.locale, const Locale('en'));

    // and it is now cached locally, so an offline cold start keeps it too
    final offline = await coldStart();
    expect(offline.locale, const Locale('en'));
  });

  test('choice made on this phone is pushed to the server profile', () async {
    final api = _ProfileApi('bn');
    final app = AppState()..api = api;
    app.api.token = 'tok';
    app.user = await api.me();
    await app.setLocale(const Locale('en'));
    await Future<void>.delayed(Duration.zero);
    expect(api.patches, [
      {'language': 'en'}
    ]);
    expect(api.serverLanguage, 'en');
  });

  test('logout/login never brings the gate back', () async {
    final app = await coldStart();
    await app.setLocale(const Locale('bn'));
    // logout clears the session + synced data, never the language (the local
    // db isn't available in a unit test, so tolerate its part failing)
    try {
      await app.logout();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('locale'), 'bn');
    final after = await coldStart();
    expect(gateShows(after), isFalse);
  });
}
