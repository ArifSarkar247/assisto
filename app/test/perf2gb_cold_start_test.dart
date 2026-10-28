// perf2gb: a signed-in cold start must not wait for the memory sync (a full
// server list + pending uploads) before home — on a slow 2G/3G link that was
// seconds of spinner. The sync still runs, right after.
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';

class _Api extends ApiClient {
  @override
  Future<AppUser> me() async =>
      AppUser(id: 7, name: 'Owner', autonomyLevel: 2, language: 'en');
}

class _HangingSync extends AppState {
  int syncCalls = 0;
  final never = Completer<void>();
  @override
  Future<void> sync() {
    syncCalls++;
    return never.future; // a server that never answers
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    FlutterSecureStorage.setMockInitialValues({'token': 'tok-perf'});
  });

  test('signed-in init finishes (home can show) while the sync is still running', () async {
    final app = _HangingSync()..api = _Api();
    await app.init().timeout(const Duration(seconds: 5));
    expect(app.loading, isFalse);
    expect(app.loggedIn, isTrue);
    expect(app.syncCalls, 1, reason: 'the sync is started, just not awaited');
  });
}
