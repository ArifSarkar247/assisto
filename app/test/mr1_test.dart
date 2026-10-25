// mr1 — finishing My Circle:
//  1. MESSAGE REQUESTS like WhatsApp: message anyone found by number; the
//     recipient's "Message requests" section + read-only conversation with
//     Accept / Block / Report / Delete; the sender's neutral waiting line;
//     no call buttons until accepted; the pre-accept limit note.
//  2. FULL last-seen time (today / yesterday / weekday / date / other year,
//     12/24-hour, Bangla digits + day-period words, Dhaka vs other zones,
//     midnight boundaries) in the chat header and contact info.
//  3. NO media showpieces: the attach button is hidden while nothing can
//     really be sent; the media viewer has no "saving soon" Save.
import 'dart:typed_data';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/date_separators.dart';
import 'package:assisto/messaging/msg_request_widgets.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/messaging/presence_label.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/messenger/m3_add_to_circle_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/circle_attach_sheet.dart';
import 'package:assisto/widgets/circle_media_viewer.dart';
import 'package:assisto/widgets/m3_circle_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _peer = _e2e.generateIdentity();

late AppLocalizations en;
late AppLocalizations bn;

bool _hasLatinDigit(String s) => RegExp(r'[0-9]').hasMatch(s);

class _Api extends ApiClient {
  _Api() {
    token = 'test';
  }
  final Map<String, Object> replies = {};
  final calls = <(String, String, Map<String, dynamic>)>[];

  Map<String, dynamic> _answer(String path) {
    final r = replies[path] ?? replies[path.split('?').first] ?? const {};
    if (r is Map<String, dynamic> Function()) return r();
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

  List<Map<String, dynamic>> posts(String path) => [
        for (final c in calls)
          if (c.$1 == 'POST' && c.$2 == path) c.$3
      ];
}

Map<String, dynamic> _msg(int id, String text, {required bool mine}) {
  final ct = _e2e.encrypt(
      self: mine ? _me : _peer,
      recipientPublicKey: mine ? _peer.publicKey : _me.publicKey,
      plaintext: text);
  return {
    'id': id,
    'sender_id': mine ? 1 : 2,
    'mine': mine,
    'content_type': 'text',
    if (mine) 'status': 'delivered',
    'created_at': DateTime(2026, 10, 22, 9, id).toIso8601String(),
    ...ct.toEnvelopeFields(),
  };
}

Map<String, dynamic> _member(String state, String dir,
        {Map<String, dynamic>? request, String phone = ''}) =>
    {
      'id': 5,
      'name': 'Nadia Rahman',
      'relation': 'friend',
      'state': state,
      'direction': dir,
      'public_key': _peer.publicKeyB64,
      if (request != null) 'request': request,
      if (phone.isNotEmpty) 'request_phone': phone,
    };

Future<void> _host(WidgetTester tester, _Api api, Widget screen,
    {bool use24h = false, String lang = 'en'}) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  final app = AppState()..api = api;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: use24h),
          child: child!),
      home: screen,
    ),
  ));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('bn');
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    Outbox.instance.stop();
    RealtimeChannel.instance.states.value = const {};
  });

  // -------------------------------------------------------------------------
  group('2. full last seen', () {
    final now = DateTime(2026, 10, 22, 18, 0); // Thursday
    String l(DateTime ls, {bool h24 = false, String lang = 'en', DateTime? n}) =>
        lastSeenLabel(lang == 'bn' ? bn : en, ls,
            lang: lang, now: n ?? now, use24h: h24);

    test('en 12-hour: today / yesterday / weekday / date / other year', () {
      expect(l(DateTime(2026, 10, 22, 21, 40), n: DateTime(2026, 10, 22, 23)),
          'last seen today at 9:40 pm');
      expect(l(DateTime(2026, 10, 21, 8, 15)), 'last seen yesterday at 8:15 am');
      expect(l(DateTime(2026, 10, 19, 21, 40)), 'last seen Monday at 9:40 pm');
      expect(l(DateTime(2026, 10, 16, 21, 40)), 'last seen Friday at 9:40 pm');
      expect(l(DateTime(2026, 10, 15, 21, 40)), 'last seen 15 Oct at 9:40 pm');
      expect(l(DateTime(2026, 10, 1, 7, 5)), 'last seen 1 Oct at 7:05 am');
      expect(l(DateTime(2025, 10, 18, 21, 40)),
          'last seen 18 Oct 2025 at 9:40 pm');
    });

    test('en noon / midnight are 12 (never 0)', () {
      expect(l(DateTime(2026, 10, 22, 12, 5)), 'last seen today at 12:05 pm');
      expect(l(DateTime(2026, 10, 22, 0, 0)), 'last seen today at 12:00 am');
    });

    test('24-hour setting (MediaQuery.alwaysUse24HourFormat)', () {
      expect(l(DateTime(2026, 10, 22, 9, 40), h24: true),
          'last seen today at 09:40');
      expect(l(DateTime(2026, 10, 21, 21, 40), h24: true),
          'last seen yesterday at 21:40');
      final b = l(DateTime(2026, 10, 21, 21, 40), h24: true, lang: 'bn');
      expect(b, bn.c3LastSeenYesterday(localDigits('21:40', 'bn')));
      expect(b.contains(bn.mr1PeriodNight), isFalse);
    });

    test('bn: Bangla digits + natural day-period words', () {
      expect(l(DateTime(2026, 10, 22, 21, 40), lang: 'bn',
              n: DateTime(2026, 10, 22, 23)),
          bn.c3LastSeenToday('${bn.mr1PeriodNight} ${localDigits('9:40', 'bn')}'));
      expect(l(DateTime(2026, 10, 21, 8, 15), lang: 'bn'),
          bn.c3LastSeenYesterday('${bn.mr1PeriodMorning} ${localDigits('8:15', 'bn')}'));
      final cases = {
        2: bn.mr1PeriodNight, 5: bn.mr1PeriodMorning, 11: bn.mr1PeriodMorning,
        12: bn.mr1PeriodNoon, 14: bn.mr1PeriodNoon, 15: bn.mr1PeriodAfternoon,
        17: bn.mr1PeriodAfternoon, 18: bn.mr1PeriodEvening,
        19: bn.mr1PeriodEvening, 20: bn.mr1PeriodNight, 23: bn.mr1PeriodNight,
      };
      cases.forEach((h, p) => expect(dayPeriod(bn, h), p, reason: 'hour $h'));
      for (final d in [
        DateTime(2026, 10, 22, 13, 5),
        DateTime(2026, 10, 19, 16, 30),
        DateTime(2026, 10, 2, 18, 45),
        DateTime(2025, 3, 9, 6, 1),
      ]) {
        final s = l(d, lang: 'bn');
        expect(_hasLatinDigit(s), isFalse, reason: s);
        expect(s.contains('last seen'), isFalse);
      }
      // older: day + Bangla month + time
      final old = l(DateTime(2026, 10, 15, 21, 40), lang: 'bn');
      expect(old, contains(localDigits('15', 'bn')));
      expect(old, contains(localDigits('9:40', 'bn')));
      expect(old, contains(bn.mr1PeriodNight));
    });

    test('midnight boundaries', () {
      final justAfter = DateTime(2026, 10, 22, 0, 1);
      expect(l(DateTime(2026, 10, 21, 23, 59), n: justAfter),
          'last seen yesterday at 11:59 pm');
      expect(l(DateTime(2026, 10, 22, 0, 0), n: justAfter),
          'last seen today at 12:00 am');
      // exactly 7 calendar days ago -> a date, 6 -> the weekday
      expect(l(DateTime(2026, 10, 16, 0, 0), n: DateTime(2026, 10, 22, 23, 59)),
          'last seen Friday at 12:00 am');
      expect(l(DateTime(2026, 10, 15, 23, 59), n: DateTime(2026, 10, 22, 0, 0)),
          'last seen 15 Oct at 11:59 pm');
      // new year: yesterday is last year's 31 Dec
      expect(l(DateTime(2025, 12, 31, 23, 30), n: DateTime(2026, 1, 1, 0, 10)),
          'last seen yesterday at 11:30 pm');
    });

    test('Asia/Dhaka vs other time zones (same instant)', () {
      final seen = DateTime.utc(2026, 10, 21, 18, 30); // 00:30 22 Oct in Dhaka
      final nowU = DateTime.utc(2026, 10, 22, 4, 0); //  10:00 22 Oct in Dhaka
      expect(
          lastSeenLabel(en, seen,
              lang: 'en', now: nowU, toLocal: dhakaWallClock),
          'last seen today at 12:30 am');
      DateTime utcWall(DateTime d) {
        final u = d.toUtc();
        return DateTime(u.year, u.month, u.day, u.hour, u.minute);
      }
      expect(lastSeenLabel(en, seen, lang: 'en', now: nowU, toLocal: utcWall),
          'last seen yesterday at 6:30 pm');
      DateTime london(DateTime d) => utcWall(d.toUtc().add(const Duration(hours: 1)));
      expect(lastSeenLabel(en, seen, lang: 'en', now: nowU, toLocal: london),
          'last seen yesterday at 7:30 pm');
      final b = lastSeenLabel(bn, seen,
          lang: 'bn', now: nowU, toLocal: dhakaWallClock);
      expect(b, bn.c3LastSeenToday('${bn.mr1PeriodNight} ${localDigits('12:30', 'bn')}'));
    });

    test('presence: online / typing win; hidden by privacy -> no line', () {
      expect(presenceLabel(en, const RtChatState(online: true), lang: 'en'),
          'online');
      expect(presenceLabel(en, const RtChatState(), lang: 'en'), isNull);
      expect(
          presenceLabel(en, RtChatState(lastSeen: DateTime(2026, 10, 22, 9, 40)),
              lang: 'en', now: now, use24h: true),
          'last seen today at 09:40');
    });

    testWidgets('chat header uses the phone 24-hour setting', (tester) async {
      final api = _Api()
        ..replies['/circle/5/messages'] = {'results': <dynamic>[]};
      final ls = DateTime.now().subtract(const Duration(minutes: 1));
      RealtimeChannel.instance.states.value = {
        'member:5': RtChatState(online: false, lastSeen: ls),
      };
      await _host(tester, api,
          CircleChatScreen(member: _member('accepted', 'outgoing'), identity: _me),
          use24h: true);
      await _settle(tester);
      final hm = DateFormatHm.of(ls);
      expect(find.text(en.c3LastSeenToday(hm)), findsOneWidget);
      await _dispose(tester);
    });
  });

  // -------------------------------------------------------------------------
  group('3. no media showpieces', () {
    // md1: E2E photo / voice / document; mc-media2: video, contact card,
    // location and live location really send now (GIFs / video notes: not
    // built, not offered).
    test('only the kinds that work end to end can be attached', () {
      expect(circleAttachKinds(), [
        CircleAttachKind.gallery,
        CircleAttachKind.camera,
        CircleAttachKind.voice,
        CircleAttachKind.video,
        CircleAttachKind.document,
        CircleAttachKind.contact,
        CircleAttachKind.location,
        CircleAttachKind.liveLocation,
      ]);
      expect(circleAttachKinds(kinds: const {}), isEmpty);
    });

    testWidgets('a message request has NO attach button (media after accept)',
        (tester) async {
      final api = _Api()
        ..replies['/circle/5/messages'] = {'results': <dynamic>[]};
      await _host(tester, api,
          CircleChatScreen(member: _member('pending', 'outgoing'), identity: _me));
      await _settle(tester);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byTooltip(en.circleAttach), findsNothing);
      expect(find.byIcon(Icons.add_circle_outline_rounded), findsNothing);
      expect(find.text(en.circleMediaGenericGated), findsNothing);
      await _dispose(tester);
    });

    testWidgets('an accepted chat shows "+" with only the working kinds',
        (tester) async {
      final api = _Api()
        ..replies['/circle/5/messages'] = {'results': <dynamic>[]};
      await _host(tester, api,
          CircleChatScreen(member: _member('accepted', 'outgoing'), identity: _me));
      await _settle(tester);
      await tester.tap(find.byTooltip(en.circleAttach));
      await _settle(tester);
      expect(find.byKey(const Key('attach-gallery')), findsOneWidget);
      expect(find.byKey(const Key('attach-camera')), findsOneWidget);
      expect(find.byKey(const Key('attach-voice')), findsOneWidget);
      expect(find.byKey(const Key('attach-document')), findsOneWidget);
      // mc-media2: these really send now
      for (final k in ['video', 'contact', 'location', 'liveLocation']) {
        expect(find.byKey(Key('attach-$k')), findsOneWidget, reason: k);
      }
      await _dispose(tester);
    });

    testWidgets('media viewer: no Save / Forward for an item that is not here',
        (tester) async {
      await _host(tester, _Api(), CircleMediaViewer(
          items: const [MediaViewerItem(id: '1', gated: true)],
          onSave: (_) {}, onForward: (_) {}));
      await _settle(tester);
      expect(find.byKey(const Key('mv-save')), findsNothing);
      expect(find.byKey(const Key('mv-forward')), findsNothing);
      expect(find.text(en.circleMediaSavingSoon), findsNothing);
      expect(find.text(en.mr1MediaNotShown), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('media viewer: a real decrypted item keeps Save / Forward',
        (tester) async {
      MediaViewerItem? saved;
      await _host(tester, _Api(), CircleMediaViewer(
          items: [MediaViewerItem(id: '1', bytes: Uint8List.fromList(_png))],
          onSave: (i) => saved = i, onForward: (_) {}));
      await tester.pump();
      expect(find.byKey(const Key('mv-forward')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mv-save')));
      expect(saved?.id, '1');
      await _dispose(tester);
    });
  });

  // -------------------------------------------------------------------------
  group('1. message requests', () {
    testWidgets('recipient: read-only, no calls, Accept opens text + calls',
        (tester) async {
      final api = _Api()
        ..replies['/circle/5/messages'] = {
          'results': [_msg(1, 'Hello, I got your number from Karim', mine: false)],
          'edge': {'state': 'pending', 'direction': 'incoming'},
        }
        ..replies['/circle/request/5/act'] = {'id': 5, 'state': 'accepted'};
      await _host(tester, api, CircleChatScreen(
          member: _member('pending', 'incoming'), identity: _me));
      await _settle(tester);
      expect(find.text('Hello, I got your number from Karim'), findsOneWidget);
      expect(find.byKey(const Key('mr1-request-bar')), findsOneWidget);
      expect(find.text(en.mr1NotInContacts), findsOneWidget);
      expect(find.byType(TextField), findsNothing); // read-only
      expect(find.byIcon(Icons.call_rounded), findsNothing);
      expect(find.byIcon(Icons.videocam_rounded), findsNothing);
      expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
      await tester.tap(find.byKey(const Key('mr1-accept')));
      await _settle(tester);
      expect(api.posts('/circle/request/5/act').single['event'], 'accept');
      expect(find.text(en.mr1AcceptedToast('Nadia Rahman')), findsOneWidget);
      expect(find.byKey(const Key('mr1-request-bar')), findsNothing);
      expect(find.byType(TextField), findsOneWidget); // text right away
      expect(find.byIcon(Icons.call_rounded), findsOneWidget); // and call
      expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('recipient: the number shows only when the sender allows it',
        (tester) async {
      final api = _Api()
        ..replies['/circle/5/messages'] = {'results': <dynamic>[]};
      await _host(tester, api, CircleChatScreen(
          member: _member('pending', 'incoming', phone: '+8801711000001'),
          identity: _me));
      await _settle(tester);
      expect(find.text('+8801711000001'), findsOneWidget);
      expect(find.text(en.mr1NotInContacts), findsNothing);
      await _dispose(tester);
    });

    for (final action in ['block', 'report', 'delete']) {
      testWidgets('recipient: $action confirms, posts and closes', (tester) async {
        final api = _Api()
          ..replies['/circle/5/messages'] = {'results': <dynamic>[]}
          ..replies['/circle/request/5/msgreq'] = {'ok': true};
        await _host(tester, api, Builder(
            builder: (ctx) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () => Navigator.of(ctx).push(
                            MaterialPageRoute(
                                builder: (_) => CircleChatScreen(
                                    member: _member('pending', 'incoming'),
                                    identity: _me))),
                        child: const Text('open'))))));
        await tester.tap(find.text('open'));
        await _settle(tester);
        await tester.tap(find.byKey(Key('mr1-$action')));
        await _settle(tester);
        // cancel first: nothing is sent
        await tester.tap(find.text(en.cancel));
        await _settle(tester);
        expect(api.posts('/circle/request/5/msgreq'), isEmpty);
        await tester.tap(find.byKey(Key('mr1-$action')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('mr1-confirm')));
        await _settle(tester);
        expect(api.posts('/circle/request/5/msgreq').single['action'], action);
        expect(find.byType(CircleChatScreen), findsNothing); // back to the list
        await _dispose(tester);
      });
    }

    testWidgets('sender: waiting line, composer, NO call buttons',
        (tester) async {
      final api = _Api()
        ..replies['/circle/5/messages'] = {
          'results': [_msg(1, 'Hi Nadia, this is Amina', mine: true)],
          'edge': {
            'state': 'pending', 'direction': 'outgoing',
            'request': {'limit': 5, 'sent': 1, 'can_send': true},
          },
        };
      await _host(tester, api, CircleChatScreen(
          member: _member('pending', 'outgoing',
              request: {'limit': 5, 'sent': 1, 'can_send': true}),
          identity: _me));
      await _settle(tester);
      expect(find.byKey(const Key('mr1-waiting')), findsOneWidget);
      expect(find.text(en.connRequestSentBanner), findsOneWidget); // connect-flow
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.call_rounded), findsNothing);
      expect(find.byIcon(Icons.videocam_rounded), findsNothing);
      await _dispose(tester);
    });

    testWidgets('sender: after the limit a note replaces the composer',
        (tester) async {
      final api = _Api()
        ..replies['/circle/5/messages'] = {'results': <dynamic>[]};
      await _host(tester, api, CircleChatScreen(
          member: _member('pending', 'outgoing',
              request: {'limit': 5, 'sent': 5, 'can_send': false}),
          identity: _me));
      await _settle(tester);
      expect(find.byKey(const Key('mr1-limit')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await _dispose(tester);
    });

    testWidgets('sender: accepted on the other phone -> calls appear live',
        (tester) async {
      final api = _Api()
        ..replies['/circle/5/messages'] = {
          'results': <dynamic>[],
          'edge': {'state': 'accepted', 'direction': 'outgoing'},
        };
      await _host(tester, api, CircleChatScreen(
          member: _member('pending', 'outgoing',
              request: {'limit': 5, 'sent': 1, 'can_send': true}),
          identity: _me));
      await _settle(tester);
      expect(find.byKey(const Key('mr1-waiting')), findsNothing);
      expect(find.byIcon(Icons.call_rounded), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('requests section: name, not-in-contacts, decrypted preview',
        (tester) async {
      final last = _msg(1, 'Are you selling the bike?', mine: false);
      final api = _Api()
        ..replies['/circle/requests'] = {
          'results': [
            {
              'id': 5, 'direction': 'incoming', 'display_name': 'Nadia Rahman',
              'phone': '', 'msg_count': 1, 'not_in_contacts': true,
              'at': last['created_at'],
              'last': {...last, 'peer_public_key': _peer.publicKeyB64},
              'member': _member('pending', 'incoming'),
              'actions': ['accept', 'decline', 'block'],
            },
            {
              'id': 6, 'direction': 'incoming', 'display_name': 'Karim',
              'actions': ['accept', 'decline', 'block'],
            },
          ],
        }
        ..replies['/circle/5/messages'] = {'results': [last]};
      int? count;
      await _host(tester, api, Scaffold(
          body: M3RequestsBanner(
              identity: _me, onChanged: (n, _) => count = n)));
      await _settle(tester);
      expect(find.text(en.mr1RequestsTitle), findsOneWidget);
      expect(count, 2);
      expect(find.text('Nadia Rahman'), findsOneWidget);
      expect(find.text(en.mr1NotInContacts), findsOneWidget);
      expect(find.text('Are you selling the bike?'), findsOneWidget);
      // a plain add-me request keeps inline Accept / Decline
      expect(find.byKey(const Key('m3-accept-6')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mr1-req-5')));
      await _settle(tester);
      expect(find.byType(CircleChatScreen), findsOneWidget);
      expect(find.byKey(const Key('mr1-request-bar')), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('find by number -> Message opens the chat right away',
        (tester) async {
      final api = _Api()
        ..replies['/messenger/contacts/lookup'] = {
          'ok': true, 'found': true, 'phone': '+8801865052200',
          'user': {'id': 2, 'name': 'Nadia Rahman',
                   'circle': {'state': 'none'}},
        }
        ..replies['/circle/message-request/start'] = {
          'ok': true, 'state': 'pending',
          'member': _member('pending', 'outgoing',
              request: {'limit': 5, 'sent': 0, 'can_send': true}),
        }
        ..replies['/circle/5/messages'] = {'results': <dynamic>[]};
      await _host(tester, api,
          const M3AddToCircleScreen(initialNumber: '01865-052200'));
      await _settle(tester);
      expect(find.byKey(const Key('mr1-msg-found')), findsOneWidget);
      expect(find.text(en.mr1MessageNowHint), findsOneWidget);
      await tester.tap(find.byKey(const Key('mr1-msg-found')));
      await _settle(tester);
      expect(api.posts('/circle/message-request/start').single['to_user_id'], 2);
      expect(find.byType(CircleChatScreen), findsOneWidget);
      expect(find.byKey(const Key('mr1-waiting')), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('a refused start says why (server sentence)', (tester) async {
      final api = _RefusingApi();
      await _host(tester, api, Builder(builder: (ctx) => Scaffold(
          body: TextButton(
              onPressed: () => openMessageRequestChat(ctx, toUserId: 2),
              child: const Text('go')))));
      await tester.tap(find.text('go'));
      await _settle(tester);
      expect(find.text('This person only takes messages from their circle.'),
          findsOneWidget);
      expect(find.byType(CircleChatScreen), findsNothing);
      await _dispose(tester);
    });

    test('push: one notification per sender, routes to My Circle', () {
      PushPayload p(String mid) => PushPayload.fromData({
            'kind': 'message_request', 'sender_id': '7', 'message_id': mid,
            'route': 'circle/requests', 'title': 'Message request from Amina',
          });
      expect(p('1').isKnownKind, isTrue);
      expect(p('1').channel, PushChannels.messages);
      expect(p('1').notificationId, p('2').notificationId);
      expect(PushRouting.targetFor(p('1'))?.chatNavRoute, 'messages');
    });
  });
}

class _RefusingApi extends _Api {
  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path == '/circle/message-request/start') {
      throw ApiException(
          'This person only takes messages from their circle.', 403);
    }
    return super.postJson(path, body);
  }
}

/// "09:40" for [d] (the 24-hour header format, Latin digits for en).
class DateFormatHm {
  static String of(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];
