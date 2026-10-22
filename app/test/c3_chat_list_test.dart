// c3-msg — chat list: decrypted preview / time / tick / group sender / live
// typing, and the owner's UNREAD-BADGE regression: receive 10 → open chat →
// 0 everywhere (row, tab badge source, app-badge source) + the server is told
// (seen → the sender's blue ticks).
import 'dart:convert';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/unread_store.dart';
import 'package:assisto/models.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/msgr_hub_chat_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _rahim = _e2e.generateIdentity();
final _karim = _e2e.generateIdentity();

Map<String, dynamic> _env(String text, IdentityKeyPair from, IdentityKeyPair to) {
  final ct = _e2e.encrypt(self: from, recipientPublicKey: to.publicKey, plaintext: text);
  return {
    'ciphertext': ct.ciphertextB64,
    'nonce': ct.nonceB64,
    'sender_key_id': ct.senderKeyId,
    'scheme': ct.scheme,
  };
}

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final posts = <String>[];
  final bodies = <Map<String, dynamic>>[];
  bool rahimRead = false;
  bool karimMarkedUnread = false;

  List<Map<String, dynamic>> get rows => [
        {
          'id': '1',
          'kind': 'member',
          'member': {'id': 1, 'name': 'Rahim', 'public_key': base64Encode(_rahim.publicKey)},
          'last_text': '',
          'unread': rahimRead ? 0 : 10,
          'at': DateTime.now().toUtc().toIso8601String(),
          'last': {
            'id': 50,
            'mine': false,
            'content_type': 'text',
            'peer_public_key': base64Encode(_rahim.publicKey),
            ..._env('Are you coming?', _rahim, _me),
          },
        },
        {
          'id': '2',
          'kind': 'member',
          'member': {'id': 2, 'name': 'Karim', 'public_key': base64Encode(_karim.publicKey)},
          'last_text': '',
          'unread': 0,
          'marked_unread': karimMarkedUnread,
          'at': DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(),
          'last': {
            'id': 40,
            'mine': true,
            'status': 'read',
            'content_type': 'text',
            'peer_public_key': base64Encode(_karim.publicKey),
            ..._env('Done, thanks', _me, _karim),
          },
        },
        {
          'id': 'g7',
          'kind': 'group',
          'is_group': true,
          'group_id': 7,
          'group': {'id': 7, 'name': 'Family', 'my_member_id': 3},
          'member': {'id': null, 'name': 'Family'},
          'unread': 2,
          'at': DateTime.now().subtract(const Duration(days: 3)).toUtc().toIso8601String(),
          'last': {
            'id': 30,
            'mine': false,
            'sender_name': 'Rahim',
            'content_type': 'text',
            'peer_public_key': base64Encode(_rahim.publicKey),
            ..._env('Dinner at 8', _rahim, _me),
          },
        },
      ];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/circle/chats') return {'results': rows};
    if (path.contains('/messages')) return {'results': const []};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    bodies.add(body);
    if (path == '/circle/1/seen') rahimRead = true;
    if (path == '/circle/chats/unread' && body['chat_id'] == 2) {
      karimMarkedUnread = body['unread'] == true;
    }
    return {'ok': true};
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => const [];
}

AppState _state(_Api api) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 9, name: 'Me', phone: '+8801700000000', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Future<void> _pump(WidgetTester tester, _Api api) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: _state(api),
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: Scaffold(body: MsgrHubChatList(identity: _me, members: const [])),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 20));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UnreadStore.instance.reset();
    RealtimeChannel.instance.resetForTest();
  });

  testWidgets('previews are decrypted on device — never "No messages yet"',
      (tester) async {
    final api = _Api();
    await _pump(tester, api);
    expect(find.text('Are you coming?'), findsOneWidget);
    expect(find.text('Done, thanks'), findsOneWidget); // 1:1 mine: no "You:"
    expect(find.text('Rahim: Dinner at 8'), findsOneWidget); // group sender
    expect(find.text('No messages yet'), findsNothing);
    // my last message to Karim was read → blue double tick in the row
    expect(find.byKey(const ValueKey('tick-read')), findsOneWidget);
    // times: today → HH:mm, yesterday → "Yesterday"
    expect(find.text('Yesterday'), findsOneWidget);
    await _drain(tester);
  });

  testWidgets('REGRESSION: 10 unread → open chat → 0 everywhere + server seen',
      (tester) async {
    final api = _Api();
    await _pump(tester, api);
    expect(find.text('10'), findsOneWidget);
    expect(UnreadStore.instance.total.value, 12); // tab + app badge source
    expect(UnreadStore.instance.of('member:1'), 10);

    await tester.tap(find.text('Rahim'));
    await tester.pump(); // same frame as the tap
    expect(UnreadStore.instance.of('member:1'), 0);
    expect(UnreadStore.instance.total.value, 2);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    // the open chat told the server (receipts + read_by → other devices,
    // sender's blue ✓✓)
    expect(api.posts, contains('/circle/1/seen'));
    // back to the list: the reload shows 0 (no restart, no pull-to-refresh)
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.pop();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('10'), findsNothing);
    expect(UnreadStore.instance.total.value, 2);
    await _drain(tester);
  });

  testWidgets('long-press: Mark as unread, then Mark as read', (tester) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.longPress(find.text('Karim'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('c3-mark-unread')));
    await tester.pumpAndSettle();
    expect(api.posts, contains('/circle/chats/unread'));
    expect(api.bodies.last['unread'], true);
    expect(find.byKey(const Key('c3-unread-dot')), findsOneWidget);
    expect(UnreadStore.instance.of('member:2'), 1);

    await tester.longPress(find.text('Karim'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('c3-mark-read')));
    await tester.pumpAndSettle();
    expect(api.bodies.last['unread'], false);
    expect(find.byKey(const Key('c3-unread-dot')), findsNothing);
    expect(UnreadStore.instance.of('member:2'), 0);
    await _drain(tester);
  });

  testWidgets('live "typing…" replaces the preview (groups name who)',
      (tester) async {
    final api = _Api();
    await _pump(tester, api);
    RealtimeChannel.instance.states.value = {
      'member:1': const RtChatState(activity: 'typing', online: true),
      'group:7': const RtChatState(activity: 'recording', who: 'Rahim'),
    };
    await tester.pump();
    expect(find.text('typing…'), findsOneWidget);
    expect(find.text('Rahim is recording audio…'), findsOneWidget);
    expect(find.text('Are you coming?'), findsNothing);
    RealtimeChannel.instance.states.value = const {};
    await tester.pump();
    expect(find.text('Are you coming?'), findsOneWidget);
    await _drain(tester);
  });
}
