// kidaudio (owner 2 Nov PART 1 b) — child emergency audio:
//  1 the child-phone CONTRACT: the visible notice goes up FIRST; no notice
//    -> the server is told notice_shown=false and NO call opens; the call
//    opens only after the server re-check says ok; nothing pending -> nothing;
//  2 the notice text (bn/en) says a parent is listening + has Stop;
//  3 no new mic path in the kid-audio sources (audio = the ordinary call);
//  4 parent: Listen -> phone channel; a refusal shows the honest reason;
//    Call the watch -> the parent's own dialer with the watch SIM number;
//  5 child: agree needs the birth year; the log shows who asked + why refused;
//  6 empty state: benefit line + big button + how-to;
//  7 Bangla 200% text, light + dark: no overflow.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/kid_audio_child.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/kid_audio/kid_audio_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

Map<String, dynamic> _consent(int id, String role,
        {bool active = true, bool childOk = true, bool watch = false}) =>
    {
      'id': id,
      'role': role,
      'other_id': 9,
      'other_name': role == 'guardian' ? 'Rina' : 'Baba',
      'birth_year': 2014,
      'minor': true,
      'parent_ok_at': '2026-11-01T10:00:00Z',
      'child_ok_at': childOk ? '2026-11-01T10:05:00Z' : null,
      'revoked_at': null,
      'revoked_by': '',
      'active': active,
      'watch_id': watch ? 4 : null,
      'has_watch_phone': watch,
    };

class _Fake extends ApiClient {
  _Fake({this.role = 'guardian', this.empty = false, this.listenReason}) {
    token = 't';
  }

  final String role;
  final bool empty;
  final String? listenReason;
  final List<(String, Map<String, dynamic>)> posts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/kid-audio/config') {
      if (empty) {
        return {'enabled': true, 'children': const [], 'watches': const [], 'consents': const []};
      }
      return {
        'enabled': true,
        'max_session_s': 180,
        'children': [
          {'id': 9, 'name': 'Rina'}
        ],
        'watches': const [],
        'consents': role == 'guardian'
            ? [_consent(1, 'guardian', watch: true)]
            : [_consent(2, 'child', active: false, childOk: false)],
      };
    }
    if (path == '/kid-audio/log') {
      if (empty) return {'sessions': const []};
      return {
        'sessions': [
          {
            'id': 7,
            'channel': 'phone',
            'status': 'refused',
            'reason': 'no_emergency',
            'role': role,
            'guardian_name': 'Baba',
            'child_name': 'Rina',
            'requested_at': '2026-11-02T08:00:00Z',
            'seconds': null,
          },
          {
            'id': 8,
            'channel': 'phone',
            'status': 'ended',
            'reason': 'time_limit',
            'role': role,
            'guardian_name': 'Baba',
            'child_name': 'Rina',
            'requested_at': '2026-11-02T09:00:00Z',
            'seconds': 180,
          },
        ]
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    if (path == '/kid-audio/listen') {
      if (listenReason != null) return {'ok': false, 'reason': listenReason, '_status': 403};
      return {
        'ok': true,
        'session': {'id': 11, 'status': body['channel'] == 'watch' ? 'dialled' : 'requested'},
        if (body['channel'] == 'watch') 'dial': '01711000001',
      };
    }
    return {'ok': true};
  }
}

Widget _app(Widget child, ApiClient api, {String lang = 'en', bool dark = false, double scale = 1}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
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
      builder: scale == 1
          ? null
          : (ctx, w) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: child,
    ),
  );
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 6400);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    KidAudioChild.resetForTest();
  });

  group('child phone contract', () {
    late List<String> order;
    late List<Map<String, dynamic>> events;
    late Map<String, dynamic>? opened;
    const texts = KidAudioNoticeText(
        channel: 'Emergency audio', title: 'Emergency: your parent is listening',
        text: 'Baba is listening', stop: 'Stop');

    Future<String> go({required bool shown, bool serverOk = true, bool pending = true}) {
      order = [];
      events = [];
      opened = null;
      KidAudioChild.showNotice = (n, onStop) async {
        order.add('notice:${n.title}');
        return shown;
      };
      KidAudioChild.openCall = (m) async {
        order.add('call');
        opened = m;
      };
      return KidAudioChild.run(
        fetchPending: () async => pending
            ? {
                'pending': {'id': 5, 'member_id': 77, 'guardian_name': 'Baba'}
              }
            : {'pending': null},
        postEvent: (id, body) async {
          order.add('event:${body['event']}:${body['notice_shown']}');
          events.add(body);
          return {'ok': serverOk};
        },
        texts: (_) => texts,
      );
    }

    test('notice first, then the server re-check, then the ordinary call', () async {
      expect(await go(shown: true), 'started');
      expect(order, [
        'notice:Emergency: your parent is listening',
        'event:started:true',
        'call',
      ]);
      expect(opened, {'id': 77, 'name': 'Baba'});
    });

    test('no visible notice -> no call, the server is told', () async {
      expect(await go(shown: false), 'notice_failed');
      expect(order.contains('call'), isFalse);
      expect(events.single, {'event': 'started', 'notice_shown': false});
    });

    test('server says no (emergency over) -> no call', () async {
      expect(await go(shown: true, serverOk: false), 'refused');
      expect(order.contains('call'), isFalse);
    });

    test('nothing pending -> nothing at all', () async {
      expect(await go(shown: true, pending: false), 'none');
      expect(order, isEmpty);
    });

    test('the same session never starts twice', () async {
      expect(await go(shown: true), 'started');
      expect(await go(shown: true), 'none');
    });
  });

  test('notice text says a parent is listening and has Stop (bn + en)', () async {
    final en = KidAudioNoticeText.of(await AppLocalizations.delegate.load(const Locale('en')), 'Baba');
    final bn = KidAudioNoticeText.of(await AppLocalizations.delegate.load(const Locale('bn')), 'বাবা');
    expect(en.valid && bn.valid, isTrue);
    expect(en.title.toLowerCase(), contains('listening'));
    expect(bn.title, 'জরুরি অবস্থায় বাবা/মা শুনছেন');
    expect(bn.stop, 'বন্ধ করুন');
    expect(en.text, contains('Baba'));
    expect(const KidAudioNoticeText(channel: 'c', title: '', text: '', stop: '').valid, isFalse);
  });

  test('no new microphone path in the kid-audio sources', () {
    for (final f in ['lib/calls/kid_audio_child.dart', 'lib/screens/kid_audio/kid_audio_screen.dart',
        'lib/kid_audio_api.dart']) {
      final src = File(f).readAsStringSync();
      for (final bad in ['getUserMedia', 'AudioRecorder', 'record(', 'MediaRecorder', 'startRecorder']) {
        expect(src.contains(bad), isFalse, reason: '$f uses $bad');
      }
    }
    // the call goes through the existing call screen (calls / WebRTC stack)
    expect(File('lib/calls/kid_audio_child.dart').readAsStringSync(), contains('CircleCallScreen('));
  });

  testWidgets('parent: listen asks for the phone channel; refusal shows the reason', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake(listenReason: 'no_emergency');
    await t.pumpWidget(_app(const KidAudioScreen(), api));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('kau-rules')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('kau-listen-1')));
    await t.pumpAndSettle();
    expect(api.posts.first.$1, '/kid-audio/listen');
    expect(api.posts.first.$2, {'consent_id': 1, 'channel': 'phone'});
    expect(find.text(l.kauRNoEmergency), findsWidgets);
  });

  testWidgets('parent: call the watch dials the watch SIM on the parent phone', (t) async {
    _tall(t);
    final api = _Fake();
    String? dialled;
    await t.pumpWidget(_app(KidAudioScreen(dial: (n) async => dialled = n), api));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('kau-watch-1')));
    await t.pumpAndSettle();
    expect(api.posts.first.$2['channel'], 'watch');
    expect(dialled, '01711000001');
  });

  testWidgets('child: agree needs the birth year; the log shows who asked and why', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake(role: 'child');
    await t.pumpWidget(_app(const KidAudioScreen(), api));
    await t.pumpAndSettle();
    expect(find.text(l.kauAskTitle('Baba')), findsOneWidget);
    final agree = find.byKey(const ValueKey('kau-agree-2'));
    await t.tap(agree);
    await t.pumpAndSettle();
    expect(api.posts, isEmpty); // disabled until the year is confirmed
    await t.tap(find.byKey(const ValueKey('kau-confirm-year-2')));
    await t.pumpAndSettle();
    await t.tap(find.text('${DateTime.now().year - 12}').last);
    await t.pumpAndSettle();
    await t.tap(agree);
    await t.pumpAndSettle();
    expect(api.posts.single.$1, '/kid-audio/consent/2/agree');
    expect(api.posts.single.$2, {'birth_year': DateTime.now().year - 12});
    expect(find.text(l.kauLogBy('Baba')), findsNWidgets(2));
    expect(find.textContaining(l.kauRNoEmergency), findsOneWidget);
    expect(find.textContaining(l.kauEndLimit), findsOneWidget);
  });

  testWidgets('empty: benefit line, big button, how-to', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const KidAudioScreen(), _Fake(empty: true)));
    await t.pumpAndSettle();
    expect(find.text(l.kauEmptyBenefit), findsOneWidget);
    expect(find.text(l.kauEmptyHow), findsOneWidget);
    expect(t.getSize(find.byKey(const ValueKey('kau-open-circle'))).height, greaterThanOrEqualTo(48));
    expect(find.byKey(const ValueKey('kau-log-empty')), findsOneWidget);
  });

  for (final dark in [false, true]) {
    for (final role in ['guardian', 'child']) {
      testWidgets('Bangla 200% ${dark ? 'dark' : 'light'} $role: no overflow', (t) async {
        _tall(t);
        await t.pumpWidget(_app(const KidAudioScreen(), _Fake(role: role), lang: 'bn', dark: dark, scale: 2));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(find.byType(KidAudioScreen), findsOneWidget);
      });
    }
  }
}
