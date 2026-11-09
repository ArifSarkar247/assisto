// offline1st: a My Circle chat read once opens again with NO network — the
// newest page comes from this phone's encrypted copy (E2E ciphertext,
// decrypted on the phone), no "couldn't load" error; a message typed offline
// waits in the outbox with the clock and is never shown as sent.
import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/models.dart';
import 'package:assisto/offline/net_status.dart';
import 'package:assisto/offline/offline_store.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _peer = _e2e.generateIdentity();

class _Api extends ApiClient {
  _Api() {
    token = 'test';
  }
  bool offline = false;
  final posted = <Map<String, dynamic>>[];
  final Map<String, Map<String, dynamic>> replies = {};

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (offline) throw http.ClientException('Failed host lookup');
    return Map<String, dynamic>.from(replies[path.split('?').first] ?? const {});
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (offline) throw http.ClientException('Failed host lookup');
    if (path == '/circle/5/messages') posted.add(body);
    return const {};
  }
}

Map<String, dynamic> _fromPeer(int id, String text) => {
      'id': id,
      'sender_id': 2,
      'mine': false,
      'content_type': 'text',
      'created_at': DateTime(2026, 11, 9, 9).add(Duration(minutes: id)).toIso8601String(),
      ..._e2e
          .encrypt(self: _peer, recipientPublicKey: _me.publicKey, plaintext: text)
          .toEnvelopeFields(),
    };

Map<String, dynamic> _member() => {
      'id': 5,
      'name': 'Karim Test',
      'relation': 'friend',
      'state': 'accepted',
      'public_key': _peer.publicKeyB64,
    };

late AppLocalizations t;

Future<void> _open(WidgetTester tester, _Api api) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  final app = AppState()..api = api;
  app.user = AppUser(id: 7, name: 'Rahim Test', autonomyLevel: 2, language: 'en');
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: CircleChatScreen(member: _member(), identity: _me),
    ),
  ));
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() async {
    t = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Outbox.instance.stop();
  });

  testWidgets('a chat read once opens offline from the encrypted copy', (tester) async {
    final api = _Api();
    api.replies['/circle/5/messages'] = {
      'results': [
        _fromPeer(1, 'Assalamu alaikum'),
        _fromPeer(2, 'Bazar theke dim anbo?'),
      ],
    };
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    await _open(tester, api);
    expect(find.text('Bazar theke dim anbo?'), findsWidgets);
    await _close(tester);

    // the copy on the phone is the server's CIPHERTEXT, never the plaintext
    final saved = await OfflineStore.instance.read(7, OfflineStore.chatSlot('member', 5));
    expect('$saved', isNot(contains('Bazar theke')));

    // airplane mode: every request fails
    api.offline = true;
    await _open(tester, api);
    expect(find.text('Assalamu alaikum'), findsWidgets);
    expect(find.text('Bazar theke dim anbo?'), findsWidgets);
    expect(find.text(t.msgLoadFailed), findsNothing,
        reason: 'the saved copy is on screen; the Offline strip says the rest');
    await _close(tester);
  });

  testWidgets('typed offline: clock + outbox; back online: sent in order, E2E', (tester) async {
    final api = _Api();
    api.replies['/circle/5/messages'] = {'results': [_fromPeer(1, 'Kemon acho?')]};
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    await _open(tester, api);
    await _close(tester);
    api.offline = true;
    await _open(tester, api);
    for (final text in ['Bhalo achi', 'Tumi?']) {
      await tester.enterText(find.byType(TextField).last, text);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // the "will send when online" snackbar covers the input bar for 4 s
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byIcon(Icons.schedule_rounded), findsWidgets); // honest clock
    final q = await Outbox.instance.forChat('member', 5);
    expect(q.map((i) => i.text), ['Bhalo achi', 'Tumi?']);
    expect(q[0].id, isNot(q[1].id), reason: 'each has its own dedupe id');

    // the outbox driver runs while offline (nothing goes) ...
    Outbox.instance.start(
        transport: FnOutboxTransport(get: api.getJson, post: api.postJson),
        identity: () async => _me);
    await tester.pump(const Duration(milliseconds: 200));
    expect(api.posted, isEmpty);
    // ... and the moment the server answers again, both go, in order
    NetStatus.instance.reportFailure(http.ClientException('offline'));
    api.offline = false;
    NetStatus.instance.reportAnswer();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(api.posted.map((b) => b['client_msg_id']), [q[0].id, q[1].id]);
    for (final b in api.posted) {
      expect(b.containsKey('text'), isFalse, reason: 'ciphertext only');
      final pt = _e2e.decrypt(
          self: _peer,
          senderPublicKey: _me.publicKey,
          ct: Ciphertext(
              scheme: '${b['scheme']}',
              ciphertextB64: '${b['ciphertext']}',
              nonceB64: '${b['nonce']}',
              senderKeyId: '${b['sender_key_id']}'));
      expect(pt, isNotNull);
    }
    expect(await Outbox.instance.all(), isEmpty);
    Outbox.instance.stop();
    await _close(tester);
  });
}
