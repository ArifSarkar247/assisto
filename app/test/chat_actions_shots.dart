// chat-actions review shots (owner 26 Oct) — NOT part of the CI suite (no
// _test suffix). Run on demand:
//   flutter test test/chat_actions_shots.dart
// Writes bn/en × light/dark PNGs to owner_actions/chat_actions/.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/unread_store.dart';
import 'package:assisto/models.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/screens/messenger/msgr_set_privacy_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/msgr_hub_chat_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_fonts.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _rahim = _e2e.generateIdentity();
final _out = Platform.environment['ASSISTO_SHOT_DIR'] ??
    '${Directory.current.path}/../owner_actions/chat_actions';

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }

  Map<String, dynamic> _row(String id, String name, String text,
      {int unread = 0, int timer = 0, Duration ago = Duration.zero}) {
    final ct = _e2e.encrypt(
        self: _rahim, recipientPublicKey: _me.publicKey, plaintext: text);
    return {
      'id': id,
      'kind': 'member',
      'member': {'id': int.parse(id), 'name': name},
      'unread': unread,
      'disappearing_sec': timer,
      'at': DateTime.now().subtract(ago).toUtc().toIso8601String(),
      'last': {
        'id': 50 + int.parse(id),
        'mine': false,
        'content_type': 'text',
        'peer_public_key': base64Encode(_rahim.publicKey),
        'ciphertext': ct.ciphertextB64,
        'nonce': ct.nonceB64,
        'sender_key_id': ct.senderKeyId,
        'scheme': ct.scheme,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/circle/chats') {
      return {
        'results': [
          _row('1', 'Rahim Uddin', 'Are you coming tonight?', unread: 3, timer: 604800),
          _row('2', 'Karim', 'Thanks, see you', ago: const Duration(hours: 3)),
          _row('3', 'Nasrin Akter', 'Photo sent', ago: const Duration(days: 1), timer: 86400),
          {
            'id': 'g7', 'kind': 'group', 'is_group': true, 'group_id': 7,
            'group': {'id': 7, 'name': 'Family', 'my_member_id': 3},
            'member': {'id': null, 'name': 'Family'}, 'unread': 0,
            'at': DateTime.now().subtract(const Duration(days: 2)).toUtc().toIso8601String(),
            'last': null,
          },
        ]
      };
    }
    if (path == '/circle/settings/default-timer') return {'disappearing_sec': 604800};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => const [];
}

AppState _state(_Api api, String lang) => AppState()
  ..api = api
  ..user = AppUser(
      id: 9, name: 'Me', phone: '+8801700000000', email: '', autonomyLevel: 2, language: lang)
  ..locale = Locale(lang)
  ..loading = false;

typedef _Act = Future<void> Function(WidgetTester tester);

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _longPress(WidgetTester t, String name) async {
  await t.longPress(find.text(name));
  await _settle(t);
}

Future<void> _scrollSheet(WidgetTester t) async {
  final s = find
      .descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable))
      .first;
  await t.drag(s, const Offset(0, -600));
  await _settle(t);
}

final Map<String, (Widget Function(), _Act)> _scenes = {
  'list_timer_icons': (() => MsgrHubChatList(identity: _me, members: const []), (t) async {}),
  'sheet_top': (() => MsgrHubChatList(identity: _me, members: const []),
      (t) => _longPress(t, 'Karim')),
  'sheet_bottom': (() => MsgrHubChatList(identity: _me, members: const []), (t) async {
    await _longPress(t, 'Karim');
    await _scrollSheet(t);
  }),
  'delete_dialog': (() => MsgrHubChatList(identity: _me, members: const []), (t) async {
    await _longPress(t, 'Karim');
    await _scrollSheet(t);
    await t.tap(find.byKey(const Key('ca-delete')));
    await _settle(t);
  }),
  'clear_dialog': (() => MsgrHubChatList(identity: _me, members: const []), (t) async {
    await _longPress(t, 'Karim');
    await _scrollSheet(t);
    await t.tap(find.byKey(const Key('ca-clear')));
    await _settle(t);
  }),
  'select_mode': (() => MsgrHubChatList(identity: _me, members: const []), (t) async {
    await _longPress(t, 'Karim');
    await _scrollSheet(t);
    await t.tap(find.byKey(const Key('ca-select')));
    await _settle(t);
    await t.tap(find.text('Family'));
    await _settle(t);
  }),
  'settings_privacy_default_timer': (() => const MsgrSetPrivacyScreen(), (t) async {
    await t.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await _settle(t);
  }),
};

void main() {
  setUpAll(() async {
    await loadAppFonts();
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons = '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(icons).existsSync()) {
      final l = FontLoader('MaterialIcons')
        ..addFont(File(icons).readAsBytes().then((b) => ByteData.view(b.buffer)));
      await l.load();
    }
    Directory(_out).createSync(recursive: true);
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UnreadStore.instance.reset();
    RealtimeChannel.instance.resetForTest();
  });

  for (final e in _scenes.entries) {
    for (final lang in ['bn', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('shot ${e.key} $lang ${dark ? 'dark' : 'light'}', (t) async {
          debugDisableShadows = false;
          await t.binding.setSurfaceSize(const Size(360, 780));
          final key = GlobalKey();
          final api = _Api();
          await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
            value: _state(api, lang),
            child: RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: Locale(lang),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                theme: dark ? AssistoTheme.dark : AssistoTheme.light,
                home: e.key.startsWith('settings')
                    ? e.value.$1()
                    : Scaffold(body: SafeArea(child: e.value.$1())),
              ),
            ),
          ));
          await _settle(t);
          // the chips use Bangla text in bn; tap targets are names (ASCII)
          await e.value.$2(t);
          final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final img = await t.runAsync(() => b.toImage(pixelRatio: 2)) as ui.Image;
          final bytes = await t.runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
          File('$_out/${e.key}_${lang}_${dark ? 'dark' : 'light'}.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          img.dispose();
          await t.pumpWidget(const SizedBox());
          await t.pump(const Duration(seconds: 20));
          debugDisableShadows = true;
          await t.binding.setSurfaceSize(null);
        });
      }
    }
  }
}
