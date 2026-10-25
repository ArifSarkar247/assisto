// chat-actions (owner 26 Oct) — WhatsApp-style chat actions in My Circle:
// the chat-list long-press sheet (bn/en), Delete chat / Clear chat confirm
// dialogs, multi-select bulk actions, Block / Report, the timer icon, the
// message delete menu (for-everyone only on my messages inside the window),
// the "This message was deleted" tombstone and Settings ▸ Privacy default
// timer.
import 'dart:convert';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_actions.dart';
import 'package:assisto/messaging/unread_store.dart';
import 'package:assisto/models.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/circle_bubble.dart';
import 'package:assisto/widgets/circle_message_actions.dart';
import 'package:assisto/widgets/default_timer_row.dart';
import 'package:assisto/widgets/msgr_hub_chat_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _rahim = _e2e.generateIdentity();

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
  final bodies = <String, Map<String, dynamic>>{};
  final deleted = <String>{};
  int defaultSec = 0;

  List<Map<String, dynamic>> get rows => [
        {
          'id': '1',
          'kind': 'member',
          'member': {'id': 1, 'name': 'Rahim', 'public_key': base64Encode(_rahim.publicKey)},
          'unread': 3,
          'at': DateTime.now().toUtc().toIso8601String(),
          'disappearing_sec': 604800,
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
          'member': {'id': 2, 'name': 'Karim'},
          'unread': 0,
          'at': DateTime.now().subtract(const Duration(hours: 2)).toUtc().toIso8601String(),
          'last': null,
        },
        {
          'id': 'g7',
          'kind': 'group',
          'is_group': true,
          'group_id': 7,
          'group': {'id': 7, 'name': 'Family', 'my_member_id': 3},
          'member': {'id': null, 'name': 'Family'},
          'unread': 0,
          'at': DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(),
          'last': null,
        },
      ].where((r) => !deleted.contains('${r['id']}')).toList();

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/circle/chats') return {'results': rows};
    if (path == '/circle/settings/default-timer') {
      return {'disappearing_sec': defaultSec};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    bodies[path] = body;
    if (path.endsWith('/delete-chat')) {
      deleted.add(path.contains('groups') ? 'g7' : path.split('/')[2]);
      return {'ok': true, 'media_refs': const []};
    }
    return {'ok': true};
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => const [];
}

AppState _state(_Api api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 9, name: 'Me', phone: '+8801700000000', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(_Api api, Widget home, {String lang = 'en', bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(api, lang),
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        home: Scaffold(body: home),
      ),
    );

Future<void> _pump(WidgetTester tester, _Api api, {String lang = 'en'}) async {
  // tall enough that the whole long-press sheet is built (it scrolls on a
  // shorter phone)
  await tester.binding.setSurfaceSize(const Size(360, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
      _app(api, MsgrHubChatList(identity: _me, members: const []), lang: lang));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// The long-press sheet scrolls on a phone: bring [f] into view first.
Future<Finder> _inSheet(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 80,
      scrollable: find
          .descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable))
          .first);
  await tester.ensureVisible(f);
  await tester.pump(const Duration(milliseconds: 200));
  return f;
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

  testWidgets('long-press sheet: every WhatsApp action (en)', (tester) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.longPress(find.text('Karim'));
    await _settle(tester);
    for (final s in [
      'View contact', 'Pin chat', 'Mute', 'Add to favourites', 'Archive',
      'Select chats', 'Clear chat', 'Delete chat', 'Block', 'Report',
    ]) {
      expect(await _inSheet(tester, find.text(s)), findsOneWidget, reason: s);
    }
    await _drain(tester);
  });

  testWidgets('long-press sheet in Bangla; a group has Group info, no Block',
      (tester) async {
    final api = _Api();
    await _pump(tester, api, lang: 'bn');
    await tester.longPress(find.text('Family'));
    await _settle(tester);
    expect(find.text('গ্রুপের তথ্য'), findsOneWidget);
    for (final s in ['চ্যাট বাছাই করুন', 'চ্যাট খালি করুন', 'চ্যাট ডিলিট করুন', 'রিপোর্ট করুন']) {
      expect(await _inSheet(tester, find.text(s)), findsOneWidget, reason: s);
    }
    expect(find.byKey(const Key('ca-block')), findsNothing);
    await _drain(tester);
  });

  testWidgets('Delete chat: confirm + "Also delete media", row leaves, '
      'membership never touched', (tester) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.longPress(find.text('Karim'));
    await _settle(tester);
    await tester.tap(await _inSheet(tester, find.byKey(const Key('ca-delete'))));
    await _settle(tester);
    expect(find.byKey(const Key('ca-delete-dialog')), findsOneWidget);
    expect(find.text('Messages are removed from your list and this phone only. '
        'Karim stays in your My Circle.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ca-delete-media')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ca-delete-confirm')));
    await _settle(tester);
    expect(api.posts, contains('/circle/2/delete-chat'));
    expect(api.bodies['/circle/2/delete-chat'], {'delete_media': true});
    expect(find.text('Karim'), findsNothing);
    expect(find.text('Chat deleted'), findsOneWidget);
    // no membership / block / leave call — only the per-user hide
    expect(api.posts.where((p) => p.contains('controls') || p.contains('leave')),
        isEmpty);
    await _drain(tester);
  });

  testWidgets('Delete chat: cancel does nothing', (tester) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.longPress(find.text('Karim'));
    await _settle(tester);
    await tester.tap(await _inSheet(tester, find.byKey(const Key('ca-delete'))));
    await _settle(tester);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(api.posts, isEmpty);
    expect(find.text('Karim'), findsOneWidget);
    await _drain(tester);
  });

  testWidgets('Clear chat: "Keep starred messages" (on by default)',
      (tester) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.longPress(find.text('Rahim'));
    await _settle(tester);
    await tester.tap(await _inSheet(tester, find.byKey(const Key('ca-clear'))));
    await _settle(tester);
    expect(find.text('Keep starred messages'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ca-clear-confirm')));
    await _settle(tester);
    expect(api.bodies['/circle/1/clear'], {'keep_starred': true});
    expect(find.text('Rahim'), findsOneWidget); // the row stays
    // without starred
    await tester.longPress(find.text('Rahim'));
    await _settle(tester);
    await tester.tap(await _inSheet(tester, find.byKey(const Key('ca-clear'))));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('ca-keep-starred')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ca-clear-confirm')));
    await _settle(tester);
    expect(api.bodies['/circle/1/clear'], {'keep_starred': false});
    await _drain(tester);
  });

  testWidgets('Select chats: bulk mark read, bulk delete (group stays a '
      'member)', (tester) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.longPress(find.text('Rahim'));
    await _settle(tester);
    await tester.tap(await _inSheet(tester, find.byKey(const Key('ca-select'))));
    await _settle(tester);
    expect(find.byKey(const Key('ca-selection-bar')), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Family'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byKey(const Key('ca-row-selected')), findsNWidgets(2));
    // a tap in select mode never opens the chat
    expect(find.byType(MsgrHubChatList), findsOneWidget);
    await tester.tap(find.byKey(const Key('ca-bulk-delete')));
    await _settle(tester);
    expect(find.text('Delete 2 chats?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ca-delete-confirm')));
    await _settle(tester);
    expect(api.posts, containsAll(['/circle/1/delete-chat', '/circle/groups/7/delete-chat']));
    expect(find.byKey(const Key('ca-selection-bar')), findsNothing);
    expect(find.text('Karim'), findsOneWidget);
    expect(find.text('Family'), findsNothing);
    await _drain(tester);
  });

  testWidgets('Select chats: bulk pin / archive / mark read', (tester) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.longPress(find.text('Rahim'));
    await _settle(tester);
    await tester.tap(await _inSheet(tester, find.byKey(const Key('ca-select'))));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('ca-bulk-read')));
    await _settle(tester);
    expect(api.posts, contains('/circle/chats/unread'));
    await tester.longPress(find.text('Karim'));
    await _settle(tester);
    await tester.tap(await _inSheet(tester, find.byKey(const Key('ca-select'))));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('ca-bulk-pin')));
    await _settle(tester);
    expect(api.posts, contains('messenger/chats/2/pin'));
    await tester.longPress(find.text('Karim'));
    await _settle(tester);
    await tester.tap(await _inSheet(tester, find.byKey(const Key('ca-select'))));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('ca-bulk-archive')));
    await _settle(tester);
    expect(api.posts, contains('messenger/chats/2/archive'));
    await _drain(tester);
  });

  testWidgets('Block from the list asks first, then blocks', (tester) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.longPress(find.text('Karim'));
    await _settle(tester);
    await tester.tap(await _inSheet(tester, find.byKey(const Key('ca-block'))));
    await _settle(tester);
    expect(find.text('Block Karim?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ca-block-confirm')));
    await _settle(tester);
    expect(api.bodies['/circle/2/controls'], {'blocked': true});
    await _drain(tester);
  });

  testWidgets('Favourite from the list feeds the Favourites chip',
      (tester) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.longPress(find.text('Karim'));
    await _settle(tester);
    await tester.tap(await _inSheet(tester, find.byKey(const Key('ca-favourite'))));
    await _settle(tester);
    expect(api.bodies['/circle/2/controls'], {'favourite': true});
    await tester.tap(find.text('Favourites'));
    await _settle(tester);
    expect(find.text('Karim'), findsOneWidget);
    expect(find.text('Rahim'), findsNothing);
    await _drain(tester);
  });

  testWidgets('timer icon on a chat with disappearing messages',
      (tester) async {
    final api = _Api();
    await _pump(tester, api);
    expect(find.byKey(const Key('ca-timer-icon')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Disappearing messages on')),
        findsOneWidget);
    await _drain(tester);
  });

  testWidgets('message menu: for everyone only on MY message in the window',
      (tester) async {
    final api = _Api();
    Future<void> open(bool mine, bool can) async {
      await tester.pumpWidget(const SizedBox()); // close the previous sheet
      await tester.pumpWidget(_app(api, Builder(builder: (ctx) {
        return TextButton(
            onPressed: () => showCircleMessageActions(ctx,
                mine: mine,
                canEdit: false,
                isStarred: false,
                isPinned: false,
                canDeleteEveryone: can,
                onReact: (_) {}),
            child: const Text('open'));
      })));
      await tester.tap(find.text('open'));
      await _settle(tester);
    }

    await open(true, true);
    expect(find.text('Delete for everyone'), findsOneWidget);
    expect(find.text('Delete for me'), findsOneWidget);
    await open(true, false); // outside the window
    expect(find.text('Delete for everyone'), findsNothing);
    await open(false, true); // someone else's message
    expect(find.text('Delete for everyone'), findsNothing);
    expect(find.text('Delete for me'), findsOneWidget);
    await _drain(tester);
  });

  testWidgets('tombstone bubble: "This message was deleted." (en + bn)',
      (tester) async {
    final api = _Api();
    final m = CircleMessage(
        id: '9', text: '', mine: false, at: DateTime.now(), deleted: 'everyone');
    await tester.pumpWidget(_app(api, CircleBubble(msg: m)));
    await tester.pump();
    expect(find.text('This message was deleted.'), findsOneWidget);
    await tester.pumpWidget(_app(api, CircleBubble(msg: m), lang: 'bn'));
    await tester.pump();
    expect(find.text('এই মেসেজটি মুছে ফেলা হয়েছে।'), findsOneWidget);
  });

  testWidgets('Settings ▸ Privacy: default timer for new chats', (tester) async {
    final api = _Api();
    await tester.pumpWidget(_app(api, DefaultTimerRow(api: api)));
    await _settle(tester);
    expect(find.text('Default message timer'), findsOneWidget);
    expect(find.textContaining('New chats you start: Off'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ca-default-timer')));
    await _settle(tester);
    await tester.tap(find.text('7 days').last);
    await _settle(tester);
    expect(api.bodies['/circle/settings/default-timer'], {'ttl': '7d'});
    expect(find.textContaining('New chats you start: 7 days'), findsOneWidget);
    expect(find.text('Default timer saved'), findsOneWidget);
    // Bangla
    api.defaultSec = 86400;
    await tester.pumpWidget(_app(api, DefaultTimerRow(api: api, key: UniqueKey()), lang: 'bn'));
    await _settle(tester);
    expect(find.text('ডিফল্ট মেসেজ টাইমার'), findsOneWidget);
    expect(find.textContaining('২৪ ঘণ্টা'), findsOneWidget);
  });

  test('chat action routes + timer tokens', () {
    expect(chatActionBase('member:12'), '/circle/12');
    expect(chatActionBase('group:5'), '/circle/groups/5');
    expect(timerTokenOf(604800), '7d');
    expect(timerTokenOf(0), 'off');
    expect(mediaRefsOf({'media_refs': ['a', 'b']}), ['a', 'b']);
  });
}
