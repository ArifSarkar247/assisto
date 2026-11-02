// finish1 (2 Nov) — My Circle + blood donor finishing:
//  * preview pictures are SHRUNK on the phone (not dropped) — JPEG <= 48 KB,
//    transparency on white, garbage / absurd sizes refused;
//  * GROUP link previews: sealed per member next to the text (lp_ciphertext),
//    the URL never travels in clear; the receiver opens the card;
//  * Guardians screen: a bag / shoe tracker chip shows as its own source;
//  * blood banks: honest source-pending, the official list with source +
//    filters + honest no-match; donor push-area card with "still here?".
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imglib;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/link_preview_client.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/screens/blood/blood_banks_screen.dart';
import 'package:assisto/screens/blood/blood_donor_entry.dart';
import 'package:assisto/screens/blood/blood_request_detail_screen.dart';
import 'package:assisto/widgets/success_share.dart';
import 'package:assisto/screens/blood/blood_hub_screen.dart';
import 'package:assisto/screens/circle_group_chat_screen.dart';
import 'package:assisto/screens/circle_guardians_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_blood.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _peer = _e2e.generateIdentity();

Uint8List _noisyPng(int w, int h, {bool alpha = false}) {
  final im = imglib.Image(width: w, height: h, numChannels: alpha ? 4 : 3);
  var seed = 7;
  for (final p in im) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    p
      ..r = seed & 0xff
      ..g = (seed >> 8) & 0xff
      ..b = (seed >> 16) & 0xff;
    if (alpha) p.a = (p.x < w ~/ 2) ? 0 : 255;
  }
  return imglib.encodePng(im);
}

class _Api extends ApiClient {
  _Api() {
    token = 'test';
  }
  final Map<String, Object> replies = {};
  final calls = <(String, String, Map<String, dynamic>)>[];

  Map<String, dynamic> _answer(String path) {
    final r = replies[path] ?? replies[path.split('?').first] ?? const {};
    return Map<String, dynamic>.from(r as Map);
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(('GET', path, const {}));
    return _answer(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    calls.add(('POST', path, body));
    return _answer(path);
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    calls.add(('POST', path, body));
    return fakeBloodPost(path, bn: false) ?? {'ok': true};
  }
}

class _BloodApi extends ApiClient {
  _BloodApi({this.stale = false, this.share}) {
    token = 't';
  }
  final bool stale;
  final Map<String, dynamic>? share; // a fulfilled request's share state
  final posts = <(String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final r = fakeBloodGet(path, bn: false, empty: false) ?? <String, dynamic>{};
    if (share != null && path == '/blood-panel/requests/31') {
      return {...r, 'state': 'fulfilled', 'share': share};
    }
    if (stale && path == '/blood-panel/config') {
      final me = Map<String, dynamic>.from(r['me'] as Map)
        ..['details_stale'] = true
        ..['details_checked'] = '2026-03-01';
      return {...r, 'me': me};
    }
    return r;
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    return fakeBloodPost(path, bn: false) ?? {'ok': true};
  }
}

Widget _app(Widget child,
    {ApiClient? api, String lang = 'en', double scale = 1.0, bool dark = false}) {
  final s = AppState()
    ..api = api ?? _Api()
    ..locale = Locale(lang)
    ..loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, c) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
      home: child,
    ),
  );
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 6000);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

Map<String, dynamic> _banks({bool empty = false}) => {
      'source': {'name': 'Example list (test)', 'url': 'https://example.gov.bd/blood',
        'date': '2026-10-01'},
      'source_pending': false,
      'districts': [
        {'code': 'dhaka', 'name': 'Dhaka'},
        {'code': 'chattogram', 'name': 'Chattogram'},
      ],
      'total': empty ? 0 : 2,
      'banks': empty
          ? const []
          : [
              {'name': 'Example blood bank 1', 'district': 'dhaka', 'district_name': 'Dhaka',
                'area': 'Shahbag', 'address': 'Example road 1', 'hours': '24 hours',
                'phone': '01700-000001, 01700-000002', 'km': 2.4, 'km_from_district': false},
              {'name': 'Example blood bank 2', 'district': 'chattogram',
                'district_name': 'Chattogram', 'area': '', 'address': 'Example road 2',
                'hours': '', 'phone': ''},
            ],
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    Outbox.instance.stop();
    linkPreviewFetchOverride = null;
    guardiansLoaderOverride = null;
    guardianRemoveOverride = null;
    bloodBanksLoaderOverride = null;
  });

  // ------------------------------------------------- preview picture shrink
  group('preview picture shrink', () {
    test('a big picture is shrunk under 48 KB, not dropped', () {
      final big = _noisyPng(1200, 630);
      expect(big.length, greaterThan(kMaxPreviewImage));
      final out = shrinkPreviewImage(big)!;
      expect(out.length, lessThanOrEqualTo(kMaxPreviewImage));
      final back = imglib.decodeJpg(out)!;
      expect(back.width, lessThanOrEqualTo(kPreviewImageSide));
      expect(back.width / back.height, closeTo(1200 / 630, 0.05)); // aspect kept
    });

    test('small stays as is; garbage and absurd sizes refused', () {
      final small = _noisyPng(40, 30);
      expect(identical(shrinkPreviewImage(small), small), isTrue);
      expect(shrinkPreviewImage(Uint8List.fromList(List.filled(60000, 0x41))), isNull);
      expect(shrinkPreviewImage(Uint8List(0)), isNull);
    });

    test('transparent picture lands on white (never black)', () {
      final out = shrinkPreviewImageTo((_noisyPng(600, 300, alpha: true), 20 * 1024))!;
      expect(out.length, lessThanOrEqualTo(20 * 1024));
      final px = imglib.decodeJpg(out)!.getPixel(5, 5);
      expect(px.r, greaterThan(200));
      expect(px.g, greaterThan(200));
    });

    test('group budget shrinks with the group; tiny share = no picture', () {
      expect(groupPreviewImageBudget(1), kMaxPreviewImage);
      expect(groupPreviewImageBudget(10), 16 * 1024);
      expect(groupPreviewImageBudget(100), 0);
      expect(groupPreviewImageBudget(0), 0);
    });
  });

  // ----------------------------------------------------- group link previews
  group('group link previews (sealed per member)', () {
    Map<String, dynamic> members() => {
          'results': [
            {'id': 1, 'user_id': 1, 'name': 'Me', 'is_self': true, 'public_key': ''},
            {'id': 2, 'user_id': 2, 'name': 'Abul', 'is_self': false,
              'public_key': _peer.publicKeyB64},
          ]
        };

    Widget screen() => CircleGroupChatScreen(
        group: const {'id': 7, 'name': 'Family', 'my_member_id': 1}, identity: _me);

    testWidgets('a received preview opens on this phone', (tester) async {
      _tall(tester);
      const pv = LinkPreviewData(
          url: 'https://www.youtube.com/watch?v=1', title: 'A song', site: 'YouTube');
      final text = _e2e.encrypt(
          self: _peer, recipientPublicKey: _me.publicKey,
          plaintext: 'look https://www.youtube.com/watch?v=1');
      final lp = _e2e.encrypt(self: _peer, recipientPublicKey: _me.publicKey,
          plaintext: pv.encode());
      final api = _Api()
        ..replies['/circle/groups/7/members'] = members()
        ..replies['/circle/groups/7/messages'] = {
          'results': [
            {
              'id': 11, 'sender_id': 2, 'mine': false, 'content_type': 'text',
              'created_at': DateTime(2026, 11, 2).toIso8601String(),
              'scheme': text.scheme, 'sender_key_id': _peer.keyId, // AAD
              'ciphertext': text.ciphertextB64, 'nonce': text.nonceB64,
              'per_recipient': {
                '1': {'ciphertext': text.ciphertextB64, 'nonce': text.nonceB64,
                  'lp_ciphertext': lp.ciphertextB64, 'lp_nonce': lp.nonceB64},
              },
            }
          ],
        };
      await tester.pumpWidget(_app(screen(), api: api));
      for (var i = 0; i < 60 && find.text('A song').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('grp-lp-11')), findsOneWidget);
      expect(find.text('A song'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('typing a link shows the card; sent sealed, never in clear', (tester) async {
      _tall(tester);
      linkPreviewFetchOverride = (u) async => LinkPreviewData(
          url: u, title: 'News title', site: 'Example', image: _noisyPng(8, 8));
      final api = _Api()
        ..replies['/circle/groups/7/members'] = members()
        ..replies['/circle/groups/7/messages'] = {'results': const []};
      await tester.pumpWidget(_app(screen(), api: api));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.enterText(find.byType(TextField).last, 'read https://example.com/a');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.byKey(const Key('grp-draft-preview')), findsOneWidget);
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l.send));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final sent = api.calls
          .where((c) => c.$1 == 'POST' && c.$2 == '/circle/groups/7/messages')
          .map((c) => c.$3)
          .toList();
      expect(sent, hasLength(1));
      expect(jsonEncode(sent.single).contains('example.com'), isFalse); // never in clear
      final entry = (sent.single['per_recipient'] as Map)['2'] as Map;
      final opened = _e2e.decrypt(
          self: _peer,
          senderPublicKey: _me.publicKey,
          ct: Ciphertext(
              scheme: '${sent.single['scheme']}',
              ciphertextB64: '${entry['lp_ciphertext']}',
              nonceB64: '${entry['lp_nonce']}',
              senderKeyId: '${sent.single['sender_key_id']}'));
      final d = LinkPreviewData.tryDecode(opened)!;
      expect(d.title, 'News title');
      expect(d.url, 'https://example.com/a');
      expect(find.byKey(const Key('grp-draft-preview')), findsNothing); // cleared after send
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  // -------------------------------------------------------------- guardians
  testWidgets('guardians: a tracker chip is its own source + who can change it',
      (tester) async {
    _tall(tester);
    guardiansLoaderOverride = (p) async => p.endsWith('mine')
        ? {
            'guardians': [
              {'id': 10, 'name': 'Mom', 'removable': false, 'sources': [
                {'kind': 'chip', 'removable': false, 'set_up_by': 'Mom'},
              ]},
            ]
          }
        : {'children': []};
    await tester.pumpWidget(_app(const CircleGuardiansScreen()));
    await tester.pumpAndSettle();
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l.cgaSrcChip), findsOneWidget);
    expect(find.text(l.cgaChipOnlyOwner('Mom')), findsOneWidget);
    expect(find.byIcon(Icons.backpack_rounded), findsOneWidget);
  });

  // ------------------------------------------------------------ blood banks
  group('blood banks', () {
    testWidgets('pending: honest, no entries', (tester) async {
      _tall(tester);
      bloodBanksLoaderOverride = (_) async =>
          {'banks': const [], 'source': null, 'source_pending': true};
      await tester.pumpWidget(_app(const BloodBanksScreen()));
      await tester.pumpAndSettle();
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l.bpBanksPending), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(find.byKey(const ValueKey('bp-banks-find')), findsOneWidget);
    });

    testWidgets('official list: source first, filters, honest no-match', (tester) async {
      _tall(tester);
      final asked = <Map<String, String>>[];
      bloodBanksLoaderOverride = (q) async {
        asked.add(q);
        return _banks(empty: (q['q'] ?? '') == 'zzz');
      };
      await tester.pumpWidget(_app(const BloodBanksScreen()));
      await tester.pumpAndSettle();
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.byKey(const ValueKey('bp-banks-source')), findsOneWidget);
      expect(find.text(l.bpBanksCallFirst), findsOneWidget);
      expect(find.text('Example blood bank 1'), findsOneWidget);
      expect(find.byTooltip(l.bpCall), findsOneWidget); // only the bank with a number
      expect(find.textContaining(l.bpBanksKm('2.4')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('bp-banks-search')), 'zzz');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(asked.last['q'], 'zzz');
      expect(find.text(l.bpBanksNoMatch), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bp-banks-show-all')));
      await tester.pumpAndSettle();
      expect(asked.last.containsKey('q'), isFalse);
      expect(find.text('Example blood bank 2'), findsOneWidget);
    });

    for (final dark in [false, true]) {
      testWidgets('200% Bangla ${dark ? 'dark' : 'light'}: list, no overflow', (tester) async {
        _tall(tester);
        bloodBanksLoaderOverride = (_) async => _banks();
        await tester.pumpWidget(
            _app(const BloodBanksScreen(), lang: 'bn', scale: 2.0, dark: dark));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byKey(const ValueKey('bp-banks-near'))).height,
            greaterThanOrEqualTo(48));
      });
    }
  });

  // ------------------------------------------------ donor push-area honesty
  testWidgets('donor: push area said plainly; stale -> one tap keeps it', (tester) async {
    _tall(tester);
    final api = _BloodApi(stale: true);
    await tester.pumpWidget(_app(const BloodHubScreen(initialTab: 2), api: api));
    await tester.pumpAndSettle();
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.byKey(const ValueKey('bp-push-area')), findsOneWidget);
    expect(find.text(l.bpPushAreaHonest), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('bp-area-still')));
    await tester.tap(find.byKey(const ValueKey('bp-area-still')));
    await tester.pumpAndSettle();
    expect(api.posts.any((p) => p.$1 == '/blood-panel/me' && p.$2['area_confirmed'] == true),
        isTrue);
  });

  testWidgets('donor: fresh details -> no "still here" nag', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(const BloodHubScreen(initialTab: 2), api: _BloodApi()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bp-push-area')), findsOneWidget);
    expect(find.byKey(const ValueKey('bp-area-still')), findsNothing);
    expect(find.byKey(const ValueKey('bp-area-update')), findsOneWidget);
  });

  // ------------------------------------- owner final blood list (2 Nov)
  testWidgets('list: never hidden, status + days left, counts, doctor line', (tester) async {
    _tall(tester);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(_app(const BloodHubScreen(), api: _BloodApi()));
    await tester.pumpAndSettle();
    expect(find.text(l.bpListCounts(4, 2, 1)), findsOneWidget);
    expect(find.byKey(const ValueKey('bp-donor-6')), findsOneWidget);       // paused, shown
    expect(find.text(l.bpStPaused), findsOneWidget);
    expect(find.text(l.bpStAgoLeft(82, 38)), findsOneWidget);
    expect(find.text(l.bpCanNow), findsNWidgets(2));
    expect(find.byKey(const ValueKey('bp-doctor-decides')), findsOneWidget);
    expect(find.byKey(const ValueKey('bp-banks')), findsNothing);           // no bank list at launch
    expect(find.byKey(const ValueKey('bp-now-only')), findsNothing);        // nothing hides a donor
  });

  testWidgets('share: both sides — ask, wait, then share', (tester) async {
    _tall(tester);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final ask = _BloodApi(share: {'possible': true, 'family_ok': false, 'donor_ok': true,
      'me_ok': false, 'can_share': false});
    await tester.pumpWidget(_app(const BloodRequestDetailScreen(requestId: 31), api: ask));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bp-share-agree')), findsOneWidget);
    expect(find.byKey(const ValueKey('bp-share-again')), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('bp-share-agree')));
    await tester.tap(find.byKey(const ValueKey('bp-share-agree')));
    await tester.pumpAndSettle();
    expect(ask.posts.last.$1, '/blood-panel/requests/31/share');
    final both = _BloodApi(share: {'possible': true, 'family_ok': true, 'donor_ok': true,
      'me_ok': true, 'can_share': true});
    await tester.pumpWidget(_app(
        const BloodRequestDetailScreen(key: ValueKey('both'), requestId: 31), api: both));
    await tester.pumpAndSettle();
    expect(find.text(l.bpShareBothAgreed), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('bp-share-again')));
    await tester.tap(find.byKey(const ValueKey('bp-share-again')));
    await tester.pumpAndSettle();
    expect(find.byType(SuccessShareScreen), findsOneWidget);
  });

  testWidgets('profile switch: hidden when the flag is off; shows listed state', (tester) async {
    bloodDonorEntryLoaderOverride = () async => {'enabled': true, 'available': true};
    addTearDown(() => bloodDonorEntryLoaderOverride = null);
    FeatureFlags.instance.debugOverride = {'blood_donors': false};
    addTearDown(() => FeatureFlags.instance.debugOverride = null);
    await tester.pumpWidget(_app(const Scaffold(body: BloodDonorSwitchTile())));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bp-donor-switch')), findsNothing);
    FeatureFlags.instance.debugOverride = {'blood_donors': true};
    await tester.pumpWidget(_app(const Scaffold(body: BloodDonorSwitchTile(key: ValueKey('x')))));
    await tester.pumpAndSettle();
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l.bpIAmDonor), findsOneWidget);
    expect(find.text(l.bpListed), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('bp-donor-switch'))).value, isTrue);
  });
}
