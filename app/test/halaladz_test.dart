// halaladz (owner order 23 Nov) — "Link HalalAdz account": the deep link
// parser, the code / url rules, the link screen (type code -> linked name ->
// unlink), the server's honest error shown under the field, the feature-off
// state, the Settings tile hidden while the server has HalalAdz off, the
// support chat empty state + bubbles, and bn / en / 200% text / dark without
// layout errors. All data is made up.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/halaladz/halaladz_api.dart';
import 'package:assisto/halaladz/halaladz_link.dart';
import 'package:assisto/halaladz/halaladz_screen.dart';
import 'package:assisto/halaladz/halaladz_support_screen.dart';
import 'package:assisto/halaladz/halaladz_tile.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/theme.dart';

class _HzApi extends ApiClient {
  _HzApi({this.enabled = true, this.linkAnswer});

  bool enabled;
  bool linked = false;
  String name = 'Karim Shop';
  Map<String, dynamic>? linkAnswer;
  final List<String> calls = [];
  List<Map<String, dynamic>> msgs = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add('GET $path');
    if (path == '/halaladz/status') {
      if (!enabled) return {'enabled': false, 'linked': false};
      return {
        'enabled': true,
        'linked': linked,
        'account': linked ? {'hz_account_id': 'hz-1', 'display_name': name} : null,
        'official': {
          'channel_url': 'https://lifeassisto.com/ch/halaladz?k=abcdefghjk',
          'community_url': 'https://lifeassisto.com/cm/abcdefghjk',
        },
        'support_unread': 2,
      };
    }
    if (path == '/halaladz/support') {
      return {'ticket': null, 'messages': msgs};
    }
    throw ApiException('unexpected $path', 404);
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    calls.add('POST $path ${body['code'] ?? ''}');
    if (path == '/halaladz/link') {
      final a = linkAnswer;
      if (a != null) return a;
      linked = true;
      return {'_status': 200, 'linked': true};
    }
    return {'_status': 201};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    calls.add('POST $path');
    if (path == '/halaladz/unlink') linked = false;
    return {'linked': false};
  }
}

Widget _wrap(Widget home, {String lang = 'en', double scale = 1, bool dark = false}) =>
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('rules', () {
    test('deep link parse (cold full URI + warm path form)', () {
      expect(HalalAdzDeepLink.parse('assisto://link-halaladz?code=ab12cd34'), 'AB12CD34');
      expect(HalalAdzDeepLink.parse('/link-halaladz?code=AB12CD34'), 'AB12CD34');
      expect(HalalAdzDeepLink.parse('assisto://link-halaladz/link-halaladz?code=AB12CD34'),
          'AB12CD34');
      expect(HalalAdzDeepLink.parse('assisto://link-halaladz?code=bad'), '');
      expect(HalalAdzDeepLink.parse('https://lifeassisto.com/cm/abc'), isNull);
      expect(HalalAdzDeepLink.parse('/ch/halaladz'), isNull);
    });

    test('code + safe url rules match the server', () {
      expect(normHzCode(' ab12-cd34 '), 'AB12CD34');
      expect(normHzCode('AB12CD3'), isNull);
      expect(hzSafeUri('https://halaladz.com/o/1'), isNotNull);
      expect(hzSafeUri('https://app.halaladz.com/o/1'), isNotNull);
      for (final bad in [
        'http://halaladz.com/',
        'https://evilhalaladz.com/',
        'https://halaladz.com.evil.io/',
        'javascript:alert(1)',
        'https://u@halaladz.com/',
        'https://halaladz.com:8443/',
      ]) {
        expect(hzSafeUri(bad), isNull, reason: bad);
      }
    });

    test('push kind is known (drawn on the alerts channel)', () {
      expect(PushChannels.byKind['halaladz'], PushChannels.alerts);
    });
  });

  testWidgets('link with a typed code, see the name, unlink', (tester) async {
    final api = _HzApi();
    await tester.pumpWidget(_wrap(HalalAdzScreen(api: api)));
    await _settle(tester);
    expect(find.byKey(const Key('hz-link-form')), findsOneWidget);
    // a wrong-format code never reaches the server
    await tester.enterText(find.byKey(const Key('hz-code')), '12');
    await tester.tap(find.byKey(const Key('hz-link-btn')));
    await _settle(tester);
    expect(find.text('The code must be 8 letters or numbers.'), findsOneWidget);
    expect(api.calls.where((c) => c.startsWith('POST /halaladz/link')), isEmpty);
    await tester.enterText(find.byKey(const Key('hz-code')), 'ab12cd34');
    await tester.tap(find.byKey(const Key('hz-link-btn')));
    await _settle(tester);
    expect(api.calls, contains('POST /halaladz/link AB12CD34'));
    expect(find.byKey(const Key('hz-linked')), findsOneWidget);
    expect(find.text('Linked: Karim Shop'), findsOneWidget);
    // official community + support chat with the unread count
    expect(find.byKey(const Key('hz-channel')), findsOneWidget);
    expect(find.byKey(const Key('hz-community')), findsOneWidget);
    expect(find.byKey(const Key('hz-support')), findsOneWidget);
    await tester.tap(find.byKey(const Key('hz-unlink')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('hz-unlink-confirm')));
    await _settle(tester);
    expect(api.calls, contains('POST /halaladz/unlink'));
    expect(find.byKey(const Key('hz-link-form')), findsOneWidget);
  });

  testWidgets('deep link prefills the code; the person still confirms',
      (tester) async {
    final api = _HzApi();
    await tester.pumpWidget(_wrap(HalalAdzScreen(api: api, initialCode: 'AB12CD34')));
    await _settle(tester);
    expect(find.byKey(const Key('hz-deeplink-note')), findsOneWidget);
    expect(api.calls.where((c) => c.startsWith('POST')), isEmpty);
  });

  testWidgets('server error message is shown under the field (Bangla)',
      (tester) async {
    final api = _HzApi(linkAnswer: {
      '_status': 400,
      'detail': 'bad_code',
      'message': 'সার্ভারের বার্তা',
    });
    await tester.pumpWidget(_wrap(HalalAdzScreen(api: api), lang: 'bn'));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('hz-code')), 'AB12CD34');
    await tester.tap(find.byKey(const Key('hz-link-btn')));
    await _settle(tester);
    expect(find.text('সার্ভারের বার্তা'), findsOneWidget);
    expect(find.byKey(const Key('hz-linked')), findsNothing);
  });

  testWidgets('feature off: screen says so, Settings tile draws nothing',
      (tester) async {
    final api = _HzApi(enabled: false);
    await tester.pumpWidget(_wrap(HalalAdzScreen(api: api)));
    await _settle(tester);
    expect(find.byKey(const Key('hz-off')), findsOneWidget);
    await tester.pumpWidget(_wrap(Scaffold(body: HalalAdzSettingsTile(api: api))));
    await _settle(tester);
    expect(find.byKey(const Key('settings-halaladz')), findsNothing);
    api.enabled = true;
    await tester.pumpWidget(_wrap(Scaffold(body: HalalAdzSettingsTile(key: UniqueKey(), api: api))));
    await _settle(tester);
    expect(find.byKey(const Key('settings-halaladz')), findsOneWidget);
  });

  testWidgets('support chat: empty state, then user + team bubbles',
      (tester) async {
    final api = _HzApi();
    await tester.pumpWidget(_wrap(HalalAdzSupportScreen(api: api)));
    await _settle(tester);
    expect(find.byKey(const Key('hz-support-empty')), findsOneWidget);
    api.msgs = [
      {'id': 1, 'sender': 'user', 'text': 'My ad is not showing', 'kind': 'text'},
      {'id': 2, 'sender': 'user', 'text': '', 'kind': 'voice', 'duration_ms': 4200},
      {'id': 3, 'sender': 'owner', 'text': 'Fixed now', 'kind': 'text'},
    ];
    await tester.pumpWidget(_wrap(HalalAdzSupportScreen(key: UniqueKey(), api: api)));
    await _settle(tester);
    expect(find.text('Fixed now'), findsOneWidget);
    expect(find.text('HalalAdz team'), findsOneWidget);
    expect(find.text('Voice message · 4 s'), findsOneWidget);
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('no layout errors at 200% text, dark ($lang)', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 740 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final api = _HzApi()..linked = true;
      await tester.pumpWidget(
          _wrap(HalalAdzScreen(api: api), lang: lang, scale: 2, dark: true));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      api.msgs = [
        {'id': 1, 'sender': 'user', 'text': 'x' * 300, 'kind': 'text'},
        {'id': 2, 'sender': 'owner', 'text': 'ok', 'kind': 'text'},
      ];
      await tester.pumpWidget(_wrap(HalalAdzSupportScreen(api: api),
          lang: lang, scale: 2, dark: true));
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  }
}
