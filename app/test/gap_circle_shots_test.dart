// gap-circle: before/after gallery shots of the GROUP chat thread (time on
// every bubble, quoted reply, "edited", deleted line) and the call history.
// Uses only widgets/keys that exist on main too, so the same file renders
// the "before" state on origin/main. Writes PNGs to $ASSISTO_SHOT_DIR only
// when it is set; otherwise just renders (smoke).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/screens/circle_call_history_screen.dart';
import 'package:assisto/screens/circle_group_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_fonts.dart';

final _out = Platform.environment['ASSISTO_SHOT_DIR'];
final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _peer = _e2e.generateIdentity();

class _Api extends ApiClient {
  _Api(this.replies) {
    token = 't';
  }
  final Map<String, Map<String, dynamic>> replies;
  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      replies[path.split('?').first] ?? const {};
  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      const {'ok': true};
}

String _at(int min) => DateTime(2026, 11, 17, 20, 0)
    .subtract(Duration(minutes: min))
    .toUtc()
    .toIso8601String();

Map<String, dynamic> _peerMsg(int id, String text, int min, {Object? replyTo}) => {
      'id': id, 'sender_id': 2, 'mine': false, 'content_type': 'text',
      'created_at': _at(min), 'per_recipient': null,
      if (replyTo != null) 'reply_to': replyTo,
      ..._e2e
          .encrypt(self: _peer, recipientPublicKey: _me.publicKey, plaintext: text)
          .toEnvelopeFields(),
    };

Map<String, dynamic> _myMsg(int id, String text, int min, {bool edited = false}) {
  final ct = _e2e.encrypt(self: _me, recipientPublicKey: _peer.publicKey, plaintext: text);
  return {
    'id': id, 'sender_id': 1, 'mine': true, 'content_type': 'text',
    'created_at': _at(min), 'status': 'read', 'sender_key_id': _me.keyId,
    if (edited) 'edited_at': _at(min - 1),
    'per_recipient': {
      '2': {'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64}
    },
  };
}

Map<String, Map<String, dynamic>> _groupData(bool bn) => {
      '/circle/groups/7/members': {
        'results': [
          {'id': 1, 'user_id': 1, 'name': bn ? 'আমি' : 'Me', 'is_self': true,
           'public_key': _me.publicKeyB64},
          {'id': 2, 'user_id': 2, 'name': bn ? 'রিনা' : 'Rina',
           'public_key': _peer.publicKeyB64},
        ]
      },
      '/circle/groups/7/messages': {
        'results': [
          _peerMsg(101, bn ? 'আজ রাতে খাবার ৮টায়?' : 'Dinner at 8 tonight?', 30),
          _myMsg(102, bn ? 'হ্যাঁ, আমি আসছি' : "Yes, I'm coming", 25, edited: true),
          _peerMsg(103, bn ? 'দারুণ! মিষ্টি আনবে?' : 'Great! Bring sweets?', 20,
              replyTo: 102),
          {'id': 104, 'sender_id': 2, 'mine': false, 'content_type': 'text',
           'created_at': _at(15), 'deleted': 'everyone', 'per_recipient': null},
          _myMsg(105, bn ? 'ঠিক আছে 👍' : 'Sure 👍', 10),
        ]
      },
    };

Map<String, Map<String, dynamic>> _callData(bool bn) => {
      '/circle/calls': {
        'calls': [
          {'id': 9, 'kind': 'voice', 'state': 'missed', 'outgoing': false,
           'name': bn ? 'রিনা' : 'Rina', 'member_id': 4,
           'outcome': bn ? 'মিসড কল' : 'Missed call', 'started_at': _at(40)},
          {'id': 7, 'kind': 'video', 'state': 'ended', 'outgoing': true,
           'name': bn ? 'করিম' : 'Karim', 'member_id': 5,
           'outcome': bn ? 'আউটগোয়িং' : 'Outgoing', 'duration': '04:07',
           'started_at': _at(300)},
        ],
      },
    };

void main() {
  setUpAll(() async {
    await loadAppFonts();
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final l = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.view(b.buffer)));
      await l.load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Outbox.instance.stop();
  });

  final specs = <String, (Widget Function(), Map<String, Map<String, dynamic>> Function(bool))>{
    'gapc_group_chat': (
      () => CircleGroupChatScreen(
          group: const {'id': 7, 'name': 'Family', 'my_member_id': 1}, identity: _me),
      _groupData
    ),
    'gapc_call_history': (() => const CircleCallHistoryScreen(), _callData),
  };
  for (final e in specs.entries) {
    for (final lang in ['bn', 'en']) {
      for (final b in [Brightness.light, Brightness.dark]) {
        testWidgets('shot ${e.key} $lang ${b.name}', (tester) async {
          await tester.binding.setSurfaceSize(const Size(360, 760));
          final key = GlobalKey();
          final app = AppState()
            ..api = _Api(e.value.$2(lang == 'bn'))
            ..locale = Locale(lang)
            ..loading = false;
          await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
            value: app,
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
                theme: AssistoTheme.light,
                darkTheme: AssistoTheme.dark,
                themeMode: b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
                home: e.value.$1(),
              ),
            ),
          ));
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 80));
          }
          expect(tester.takeException(), isNull);
          if (_out != null) {
            final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
            final img = await tester.runAsync(() => rb.toImage(pixelRatio: 2)) as ui.Image;
            final bytes =
                await tester.runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
            Directory(_out!).createSync(recursive: true);
            File('$_out/${e.key}_${lang}_${b.name}.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            img.dispose();
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 1));
        });
      }
    }
  }
}
