// offline2 — first offline start right after an app update: a valid session
// token exists but this phone has no cached profile yet. The app must open
// Home on a MINIMAL profile (refreshed quietly later), never the login
// screen; only a real server 401 carrying the server's JSON logs out.
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/models.dart';
import 'package:assisto/offline/net_status.dart';
import 'package:assisto/offline/offline_store.dart';
import 'package:assisto/security/secret_store.dart';
import 'package:assisto/state.dart';

class _Api extends ApiClient {
  _Api(this.answer);
  Future<AppUser> Function() answer;
  int meCalls = 0;
  @override
  Future<List<Map<String, dynamic>>> listMemory() async => [];
  @override
  Future<AppUser> me() {
    meCalls++;
    return answer();
  }
}

Future<void> _until(bool Function() cond, {int ms = 4000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // an older build: token + the remembered account id, NO cached profile
    SharedPreferences.setMockInitialValues({'onboarded': true, 'own_guard_uid': 7});
    FlutterSecureStorage.setMockInitialValues({'token': 'tok-test'});
  });

  group('no cached profile (first start after an update)', () {
    test('offline -> Home on a minimal profile, never the login screen', () async {
      expect(await CachedSession.readUser(), isNull);
      final app = AppState()
        ..api = _Api(() async => throw http.ClientException('Failed host lookup'));
      await app.init().timeout(const Duration(seconds: 3));
      expect(app.loading, isFalse);
      expect(app.loggedIn, isTrue, reason: 'offline must never show the login screen');
      expect(app.user!.id, 7, reason: 'the account this phone last confirmed');
      expect(app.sessionFromCache, isTrue);
      expect(await SecretStore.instance.read('token'), 'tok-test');
      expect(await CachedSession.readUser(), isNull,
          reason: 'the minimal profile is never cached as the real one');
    });

    test('a server that never answers does not hold the start', () async {
      final never = Completer<AppUser>();
      final app = AppState()..api = _Api(() => never.future);
      await app.init().timeout(const Duration(seconds: 3));
      expect(app.loading, isFalse);
      expect(app.loggedIn, isTrue);
    });

    test('a 401 without the server JSON (Wi-Fi portal) is NOT a sign-out', () async {
      final app = AppState()..api = _Api(() async => throw ApiException('portal', 401));
      await app.init();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(app.loggedIn, isTrue);
      expect(await SecretStore.instance.read('token'), 'tok-test');
    });

    test('a REAL 401 with the server JSON logs out', () async {
      final app = AppState()
        ..api = _Api(() async =>
            throw ApiException('Invalid token.', 401, null, null, {'detail': 'Invalid token.'}));
      await app.init();
      await _until(() => !app.loggedIn);
      expect(app.loggedIn, isFalse);
      for (var i = 0; i < 100 && await SecretStore.instance.read('token') != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(await SecretStore.instance.read('token'), isNull);
    });

    test('back online -> the quiet refresh replaces the minimal profile and caches it', () async {
      var up = false;
      final app = AppState()
        ..api = _Api(() async {
          if (!up) throw http.ClientException('offline');
          return AppUser(id: 7, name: 'Rahim New', autonomyLevel: 2, language: 'en');
        });
      await app.init();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(app.user!.name, '');
      NetStatus.instance.reportFailure(http.ClientException('down'));
      up = true;
      NetStatus.instance.reportAnswer();
      await _until(() => app.user!.name == 'Rahim New');
      expect(app.user!.name, 'Rahim New');
      expect(app.sessionFromCache, isFalse);
      expect((await CachedSession.readUser())?['name'], 'Rahim New');
    });

    test('minimalUser: unknown account -> id 0, language follows the app', () async {
      SharedPreferences.setMockInitialValues({});
      final u = await AppState.minimalUser(lang: 'en');
      expect(u.id, 0);
      expect(u.name, '');
      expect(u.language, 'en');
      expect((await AppState.minimalUser()).language, 'bn');
    });
  });
}

