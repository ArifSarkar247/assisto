// offline1st (owner order 10 Nov 00:55): "without internet he cannot get in
// or see My Circle chats". Every owner-found failure becomes a test:
//   * a signed-in cold start with NO network opens signed in (cached profile)
//     and never waits for /me; only a REAL server 401 signs out;
//   * NetStatus: network failure -> offline, any answer -> online + the
//     back-online hooks (outbox flush, quiet session refresh);
//   * the local stores are encrypted at rest (SecretStore), never plaintext
//     SharedPreferences: offline copies, outbox, chat-list previews;
//   * the Offline strip shows only offline and never rebuilds the screens.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/messaging/preview_cache.dart';
import 'package:assisto/models.dart';
import 'package:assisto/offline/net_status.dart';
import 'package:assisto/offline/offline_store.dart';
import 'package:assisto/offline/offline_strip.dart';
import 'package:assisto/security/secret_store.dart';
import 'package:assisto/state.dart';

AppUser _u() => AppUser(id: 7, name: 'Rahim Test', autonomyLevel: 2, language: 'en');

class _Api extends ApiClient {
  _Api(this.answer);
  Future<AppUser> Function() answer;
  int meCalls = 0;
  // the memory sync that follows a confirmed session (empty server list)
  @override
  Future<List<Map<String, dynamic>>> listMemory() async => [];
  @override
  Future<AppUser> me() {
    meCalls++;
    return answer();
  }
}

Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 150));

/// Real-time wait (plain `test`, not fake async) until [cond] holds.
Future<void> _until(bool Function() cond, {int ms = 4000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    FlutterSecureStorage.setMockInitialValues({'token': 'tok-test'});
  });

  group('cold start offline (AppState.init)', () {
    test('cached profile + no network -> signed in at once, never logged out', () async {
      await CachedSession.writeUser(_u().toJson());
      final app = AppState()
        ..api = _Api(() async => throw http.ClientException('Failed host lookup'));
      await app.init().timeout(const Duration(seconds: 2));
      expect(app.loading, isFalse);
      expect(app.loggedIn, isTrue, reason: 'offline must never show the login screen');
      expect(app.user!.name, 'Rahim Test');
      await _flush();
      expect(app.loggedIn, isTrue);
      expect(app.online, isFalse);
      expect(await SecretStore.instance.read('token'), 'tok-test');
    });

    test('a server that never answers does not hold the start', () async {
      await CachedSession.writeUser(_u().toJson());
      final never = Completer<AppUser>();
      final app = AppState()..api = _Api(() => never.future);
      await app.init().timeout(const Duration(milliseconds: 800));
      expect(app.loading, isFalse);
      expect(app.loggedIn, isTrue);
      expect(app.sessionFromCache, isTrue);
    });

    test('a REAL revoked session (401 + server JSON) signs out after reconnect', () async {
      await CachedSession.writeUser(_u().toJson());
      final app = AppState()
        ..api = _Api(() async =>
            throw ApiException('Invalid token.', 401, null, null, {'detail': 'Invalid token.'}));
      await app.init();
      await _until(() => !app.loggedIn);
      expect(app.loggedIn, isFalse);
      await _flush();
      for (var i = 0; i < 100 && await CachedSession.readUser() != null; i++) {
        await _flush();
      }
      expect(await SecretStore.instance.read('token'), isNull);
      expect(await CachedSession.readUser(), isNull, reason: 'cached profile wiped');
    });

    test('a 401 page without the server JSON (Wi-Fi portal) is NOT a sign-out', () async {
      await CachedSession.writeUser(_u().toJson());
      final app = AppState()..api = _Api(() async => throw ApiException('portal', 401));
      await app.init();
      await _flush();
      expect(app.loggedIn, isTrue);
    });

    test('online start confirms and caches the profile for the next offline start', () async {
      final app = AppState()..api = _Api(() async => _u());
      await app.init();
      await _flush();
      expect(app.loggedIn, isTrue);
      expect(app.sessionFromCache, isFalse);
      final cached = await CachedSession.readUser();
      expect(cached?['id'], 7);
      // the cache is in the encrypted store, never SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().any((k) => (prefs.get(k)?.toString() ?? '').contains('Rahim Test')),
          isFalse);
    });

    test('back online -> the quiet refresh replaces the cached profile', () async {
      await CachedSession.writeUser(_u().toJson());
      var up = false;
      final api = _Api(() async {
        if (!up) throw http.ClientException('offline');
        return AppUser(id: 7, name: 'Rahim New', autonomyLevel: 2, language: 'en');
      });
      final app = AppState()..api = api;
      await app.init();
      await _flush();
      expect(app.user!.name, 'Rahim Test');
      NetStatus.instance.reportFailure(const SocketException('down'));
      expect(app.online, isFalse);
      up = true;
      NetStatus.instance.reportAnswer();
      await _until(() => app.user!.name == 'Rahim New');
      expect(app.online, isTrue);
      expect(app.user!.name, 'Rahim New');
      expect(app.sessionFromCache, isFalse);
    });

    test('logout wipes the cached profile and the offline copies', () async {
      await CachedSession.writeUser(_u().toJson());
      final app = AppState()..api = _Api(() async => _u());
      await app.init();
      await _flush();
      await OfflineStore.instance.write(7, OfflineStore.chatList, [{'id': 1}]);
      await app.logout();
      expect(await CachedSession.readUser(), isNull);
      expect(await OfflineStore.instance.read(7, OfflineStore.chatList), isNull);
    });
  });

  group('NetStatus', () {
    test('network failure -> offline; any answer -> online + back-online hooks', () async {
      final ns = NetStatus.instance;
      var backs = 0;
      ns.onBackOnline(() => backs++);
      var fail = true;
      final c = NetWatchClient(MockClient((req) async {
        if (fail) throw http.ClientException('Connection refused');
        return http.Response('{"detail":"nope"}', 500);
      }));
      await expectLater(c.get(Uri.parse('https://x.test/a')), throwsA(isA<http.ClientException>()));
      expect(ns.online.value, isFalse);
      expect(backs, 0);
      fail = false;
      final r = await c.get(Uri.parse('https://x.test/a'));
      expect(r.statusCode, 500); // an HTTP error still proves the network is up
      expect(ns.online.value, isTrue);
      expect(backs, 1);
    });

    test('timeouts / programming errors never flip to offline', () {
      final ns = NetStatus.instance;
      ns.reportFailure(TimeoutException('slow'));
      ns.reportFailure(const FormatException('bad json'));
      expect(ns.online.value, isTrue);
    });
  });

  group('encrypted at rest', () {
    test('OfflineStore: per account, LRU-capped chat pages, wiped on clearAccount', () async {
      final s = OfflineStore(store: SecretStore.instance);
      await s.write(7, OfflineStore.chatList, [{'id': 1, 'ciphertext': 'AAA'}]);
      for (var i = 0; i < OfflineStore.maxChats + 3; i++) {
        await s.write(7, OfflineStore.chatSlot('member', i), {'raw': []});
      }
      final fresh = OfflineStore(store: SecretStore.instance); // "restart"
      expect(await fresh.read(7, OfflineStore.chatList), isNotNull);
      expect(await fresh.read(8, OfflineStore.chatList), isNull, reason: 'other account');
      expect(await fresh.read(7, OfflineStore.chatSlot('member', 0)), isNull,
          reason: 'oldest page dropped by the cap');
      expect(await fresh.read(7, OfflineStore.chatSlot('member', OfflineStore.maxChats + 2)),
          isNotNull);
      await fresh.clearAccount(7);
      expect(await OfflineStore(store: SecretStore.instance).read(7, OfflineStore.chatList),
          isNull);
    });

    test('dropChat: a cleared chat never comes back from the offline copy', () async {
      final s = OfflineStore.instance..currentUid = 7;
      await s.write(7, OfflineStore.chatSlot('member', 5), {'raw': [{'id': 1}]});
      await s.dropChat('member:5');
      expect(await s.read(7, OfflineStore.chatSlot('member', 5)), isNull);
    });

    test('SecretOutboxStore: an older plaintext queue moves into the encrypted store', () async {
      SharedPreferences.setMockInitialValues({
        PrefsOutboxStore.key: jsonEncode([
          {'id': 'local-1', 'kind': 'member', 'chat': 5, 'text': 'typed offline', 'at': '2026-11-09T10:00:00Z'}
        ]),
      });
      final ob = Outbox(store: const SecretOutboxStore());
      final items = await ob.all();
      expect(items.single.text, 'typed offline');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefsOutboxStore.key), isNull, reason: 'plaintext copy removed');
      expect(await SecretStore.instance.read(SecretOutboxStore.slot), contains('typed offline'));
      await ob.add(OutboxItem(id: 'local-2', chatId: 5, text: 'second', at: DateTime(2026, 11, 9, 11)));
      final again = await Outbox(store: const SecretOutboxStore()).forChat('member', 5);
      expect(again.map((i) => i.id), ['local-1', 'local-2'], reason: 'order kept');
    });

    test('PreviewCache: decrypted previews live in SecretStore, not SharedPreferences', () async {
      PreviewCache.encrypted = true;
      addTearDown(() {
        PreviewCache.encrypted = false;
        PreviewCache.instance.resetForTest();
      });
      SharedPreferences.setMockInitialValues({
        'a1_preview_cache_v1': jsonEncode({'member:3': {'id': '9', 'text': 'old preview'}}),
      });
      PreviewCache.instance.resetForTest();
      await PreviewCache.instance.put('member:5', '12', 'secret hello');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('a1_preview_cache_v1'), isNull);
      PreviewCache.instance.resetForTest(); // restart
      expect(await PreviewCache.instance.textFor('member:5', '12'), 'secret hello');
      expect(await PreviewCache.instance.textFor('member:3', '9'), 'old preview');
    });
  });

  group('Offline strip', () {
    testWidgets('shows only offline, keeps the screen below alive', (tester) async {
      final ns = NetStatus.instance;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        builder: (context, child) => OfflineStrip(child: child!),
        home: const _Counter(),
      ));
      expect(find.byKey(const Key('offline-strip')), findsNothing);
      await tester.tap(find.byKey(const Key('inc')));
      await tester.pump();
      expect(find.text('count 1'), findsOneWidget);
      ns.reportFailure(const SocketException('airplane'));
      await tester.pump();
      expect(find.byKey(const Key('offline-strip')), findsOneWidget);
      expect(find.textContaining('No internet'), findsOneWidget);
      expect(find.text('count 1'), findsOneWidget, reason: 'state survives');
      ns.reportAnswer();
      await tester.pump();
      expect(find.byKey(const Key('offline-strip')), findsNothing);
      expect(find.text('count 1'), findsOneWidget);
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            key: const Key('inc'),
            onPressed: () => setState(() => n++),
            child: Text('count $n'),
          ),
        ),
      );
}
