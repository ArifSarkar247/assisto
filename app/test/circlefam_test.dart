// circlefam — My Circle "Family / Others" + search, and the Facebook share
// review:
//  * peopleTextMatches: Bangla / English digits, phone numbers with dashes,
//    no false phone hits from words with a few digits;
//  * chat list search finds a person by relation label, phone typed in
//    Bangla digits and the (on-device decrypted) last message; Family chip
//    keeps only family rows;
//  * marketing engine: posting on the shop's Facebook Page asks first —
//    "Not now" posts nothing; "Share" copies the text first (Facebook drops
//    shared text).
import 'dart:convert';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/unread_store.dart';
import 'package:assisto/models.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/screens/mktengine/mkt_engine_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/circle_people_filter.dart';
import 'package:assisto/widgets/msgr_hub_chat_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';
import 'mktengine_fakes.dart';

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

  List<Map<String, dynamic>> get rows => [
        {
          'id': '1',
          'kind': 'member',
          'member': {
            'id': 1,
            'name': 'Rahim',
            'phone': '+8801711-223344',
            'relation_label': 'Brother',
            'circle_group': 'family',
            'public_key': base64Encode(_rahim.publicKey),
          },
          'unread': 0,
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
          'member': {
            'id': 2,
            'name': 'Karim',
            'phone': '+8801999-000111',
            'circle_group': 'others',
            'public_key': base64Encode(_karim.publicKey),
          },
          'unread': 0,
          'at': DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(),
          'last': {
            'id': 40,
            'mine': true,
            'content_type': 'text',
            'peer_public_key': base64Encode(_karim.publicKey),
            ..._env('Invoice 500 sent', _me, _karim),
          },
        },
      ];

  final gets = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (path == '/circle/chats') return {'results': rows};
    if (path.contains('/messages')) return {'results': const []};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => const [];
}

AppState _state(ApiClient api) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 9, name: 'Me', phone: '+8801700000000', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(ApiClient api, Widget home) => ChangeNotifierProvider<AppState>.value(
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
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 20));
}

class _PubMkt extends FakeMkt {
  _PubMkt() : super('data', false);
  @override
  Future<Map<String, dynamic>> overview() async {
    final m = Map<String, dynamic>.of(await super.overview());
    m['publish'] = {'facebook': true, 'instagram': false, 'reason': '', 'page': 'Rina Store'};
    return m;
  }
}

void main() {
  group('peopleTextMatches', () {
    test('case-insensitive substring; empty query matches', () {
      expect(peopleTextMatches('Rahim Brother', 'brother'), isTrue);
      expect(peopleTextMatches('Rahim', ''), isTrue);
      expect(peopleTextMatches('Rahim', 'karim'), isFalse);
    });
    test('Bangla digits find English digits and back', () {
      expect(peopleTextMatches('+8801711-223344', '০১৭১১'), isTrue);
      expect(peopleTextMatches('ফোন ০১৭১১২২৩৩৪৪', '01711'), isTrue);
      expect(peopleTextMatches('৫০০ টাকা পাঠালাম', '500 টাকা'), isTrue);
      expect(peopleTextMatches('Invoice 500 sent', '৫০০'), isTrue);
    });
    test('phone typed with spaces / dashes still matches', () {
      expect(peopleTextMatches('+880 1711 223344', '01711-22'), isTrue);
    });
    test('a word with digits is not treated as a phone number', () {
      // old rule stripped every digit from the haystack: "room 1 2 3"
      // matched "abc123"; now only phone-like queries go digits-only
      expect(peopleTextMatches('room 1 2 3', 'abc123'), isFalse);
      expect(peopleTextMatches('room 1 2 3', '123'), isTrue);
    });
  });

  group('chat list: Family / Others + search', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      UnreadStore.instance.reset();
      RealtimeChannel.instance.resetForTest();
    });

    Future<_Api> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Api();
      await tester.pumpWidget(
          _app(api, Scaffold(body: MsgrHubChatList(identity: _me, members: const []))));
      await _settle(tester);
      return api;
    }

    testWidgets('relation label, Bangla-digit phone, decrypted last message', (tester) async {
      await pump(tester);
      expect(find.text('Rahim'), findsOneWidget);
      expect(find.text('Karim'), findsOneWidget);
      final box = find.byType(TextField).first;

      await tester.enterText(box, 'brother');
      await _settle(tester, 2);
      expect(find.text('Rahim'), findsOneWidget);
      expect(find.text('Karim'), findsNothing);

      await tester.enterText(box, '০১৯৯৯');
      await _settle(tester, 2);
      expect(find.text('Karim'), findsOneWidget);
      expect(find.text('Rahim'), findsNothing);

      // the last message, decrypted on this phone; Bangla digits match
      await tester.enterText(box, '৫০০');
      await _settle(tester, 2);
      expect(find.text('Karim'), findsOneWidget);
      expect(find.text('Rahim'), findsNothing);
      await _drain(tester);
    });

    testWidgets('search text never goes to the server', (tester) async {
      final api = await pump(tester);
      await tester.enterText(find.byType(TextField).first, 'coming');
      await _settle(tester, 2);
      expect(find.text('Rahim'), findsOneWidget);
      expect(api.gets.where((p) => p.contains('coming')), isEmpty);
      await _drain(tester);
    });

    testWidgets('Family chip keeps family rows only; Others the rest', (tester) async {
      await pump(tester);
      final fam = find.byKey(const Key('msgr-chip-family'));
      await tester.ensureVisible(fam);
      await tester.tap(fam);
      await _settle(tester, 2);
      expect(find.text('Rahim'), findsOneWidget);
      expect(find.text('Karim'), findsNothing);
      final oth = find.byKey(const Key('msgr-chip-others'));
      await tester.ensureVisible(oth);
      await tester.tap(oth);
      await _settle(tester, 2);
      expect(find.text('Karim'), findsOneWidget);
      expect(find.text('Rahim'), findsNothing);
      await _drain(tester);
    });
  });

  group('marketing engine: Facebook Page post asks first', () {
    late AppLocalizations en;
    setUpAll(() async {
      en = await AppLocalizations.delegate.load(const Locale('en'));
    });

    testWidgets('Not now posts nothing; Post now posts once', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      final f = _PubMkt();
      await tester.pumpWidget(_app(FakeApi(), MktEngineScreen(source: f)));
      await _settle(tester, 8);
      final btn = find.text(en.mktPublishFb);
      await tester.scrollUntilVisible(btn, 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(btn);
      await _settle(tester, 4);
      expect(find.text(en.cfPublishConfirmTitle), findsOneWidget);
      await tester.tap(find.byKey(const Key('cf-publish-no')));
      await _settle(tester, 4);
      expect(f.calls.where((c) => c.startsWith('publish:')), isEmpty);

      await tester.tap(btn);
      await _settle(tester, 4);
      await tester.tap(find.byKey(const Key('cf-publish-yes')));
      await _settle(tester, 6);
      expect(f.calls.where((c) => c.startsWith('publish:')).length, 1);
    });
  });
}
