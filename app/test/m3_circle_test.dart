// m3-circle: My Circle "works like WhatsApp" — widget proofs.
//
//  * LoadingGate: a HANGING load ends in error + Retry at 15 s (fake clock).
//  * Phone Safety Check-up: reproduces the live device (SharedPreferences
//    throws PlatformException / hangs) -> content, never an endless spinner.
//  * My Circle home: FAB -> New chat (Add / New group / New community /
//    Invite a friend on top of the contacts), ⋮ menu (Add / Requests /
//    Invite), requests banner at the TOP with badge + Accept / Decline.
//  * Add to My Circle: any number format -> found -> relation -> Send ->
//    success; not on Assisto -> Invite; every failure shows a clear error.
//  * Chat commands "circle" / "my circle" / "add someone" -> circle_add; the
//    drawer search finds My Circle (was "No matching modules").
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/connect_flow.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/app_drawer.dart';
import 'package:assisto/screens/messenger/m3_add_to_circle_screen.dart';
import 'package:assisto/screens/messenger/messenger_home_screen.dart';
import 'package:assisto/screens/phone_safety_screen.dart';
import 'package:assisto/services/contacts_source.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/loading_gate.dart';

/// In-memory server for the My Circle endpoints.
class _Api extends ApiClient {
  _Api() {
    token = 't';
  }

  final Map<String, Map<String, dynamic>> users = {
    '+8801865052200': {
      'id': 2,
      'name': 'Nadia Rahman',
      'photo': '',
      'circle': {'state': 'none', 'member_id': null, 'member': null},
    },
  };
  List<Map<String, dynamic>> requests = [];
  final List<String> lookups = [];
  final List<Map<String, dynamic>> sent = [];
  final List<String> acts = [];

  /// Paths that fail with this exception (simulate the live server failing).
  final Map<String, Object> failures = {};

  /// Paths that never answer.
  final Set<String> hang = {};

  Future<Map<String, dynamic>> _gate(String path) async {
    for (final h in hang) {
      if (path.startsWith(h)) return Completer<Map<String, dynamic>>().future;
    }
    for (final e in failures.entries) {
      if (path.startsWith(e.key)) throw e.value;
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    await _gate(path);
    if (path == '/circle/requests') return {'results': requests};
    if (path.startsWith('/circle/invite')) {
      return {'token': 'tok', 'link': 'https://lifeassisto.com/i/tok'};
    }
    return {'results': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    await _gate(path);
    if (path == '/messenger/contacts/lookup') {
      final p = '${body['phone']}';
      lookups.add(p);
      final u = users[p];
      return u == null
          ? {'ok': true, 'found': false, 'phone': p, 'is_self': false}
          : {'ok': true, 'found': true, 'phone': p, 'user': Map.of(u)};
    }
    if (path == '/circle/request') {
      sent.add(body);
      return {'id': 99, 'state': 'pending', 'name': 'Nadia Rahman'};
    }
    if (path.startsWith('/circle/request/') && path.endsWith('/act')) {
      acts.add('$path ${body['event']}');
      final id = int.tryParse(path.split('/')[3]);
      requests = requests.where((r) => r['id'] != id).toList();
      return {'id': 1, 'state': 'accepted'};
    }
    if (path == '/messenger/invite/share-link') {
      return {
        'link': 'https://lifeassisto.com/i/abc',
        'share_text': {'en': 'Join me https://lifeassisto.com/i/abc', 'bn': 'x'},
      };
    }
    return {'ok': true};
  }
}

class _DeniedSource implements ContactsSource {
  @override
  bool get available => true;
  @override
  Future<ContactsPermission> status() async => ContactsPermission.denied;
  @override
  Future<ContactsPermission> request() async => ContactsPermission.denied;
  @override
  Future<List<DeviceContact>> read() async => const [];
  @override
  Stream<void> get changes => const Stream<void>.empty();
  @override
  Future<bool> openSettings() async => true;
}

AppState _state(_Api api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1,
      name: 'Me',
      phone: '+8801700000000',
      email: '',
      autonomyLevel: 2,
      language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Future<void> _pump(WidgetTester tester, Widget home,
    {_Api? api, String lang = 'en'}) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: _state(api ?? _Api(), lang),
    child: MaterialApp(
      locale: Locale(lang),
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
  ));
  await _settle(tester);
}

/// Let every guarded timer (8 s identity / 15 s load guards, snackbars) run
/// out so no Timer is left pending when the test ends.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 20));
}

Future<void> _hub(WidgetTester tester, {_Api? api}) async {
  await _pump(tester, const MessengerHomeScreen(), api: api);
  await tester.pump(const Duration(seconds: 9));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await _settle(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    ContactsSources.factory = () => _DeniedSource();
  });

  // ------------------------------------------------------------ global rule
  group('LoadingGate (no endless spinner)', () {
    testWidgets('a hanging load ends in error + Retry within 15 s',
        (tester) async {
      var calls = 0;
      final hang = Completer<String>();
      await _pump(
          tester,
          Scaffold(
            body: LoadingGate<String>(
              load: () {
                calls++;
                return calls == 1 ? hang.future : Future.value('hello');
              },
              builder: (_, d, __) => Text(d),
            ),
          ));
      expect(find.byKey(const Key('load-spinner')), findsOneWidget);
      await tester.pump(const Duration(seconds: 14));
      expect(find.byKey(const Key('load-spinner')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1, milliseconds: 10));
      await tester.pump();
      expect(find.byKey(const Key('load-error')), findsOneWidget);
      expect(find.byKey(const Key('load-retry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('load-retry')));
      await _settle(tester);
      expect(find.text('hello'), findsOneWidget);
      expect(calls, 2);
      await _drain(tester);
    });

    testWidgets('empty state is shown for empty data', (tester) async {
      await _pump(
          tester,
          Scaffold(
            body: LoadingGate<List<int>>(
              load: () async => <int>[],
              isEmpty: (d) => d.isEmpty,
              emptyBuilder: (_) => const Text('nothing'),
              builder: (_, d, __) => Text('${d.length}'),
            ),
          ));
      expect(find.text('nothing'), findsOneWidget);
      await _drain(tester);
    });
  });

  // ------------------------------------------------------- Phone Safety bug
  group('Phone Safety Check-up', () {
    testWidgets(
        'live-device behaviour: SharedPreferences THROWS -> content, not a '
        'spinner', (tester) async {
      // Exactly what the owner's phone reported (client crash log).
      Settings.prefsProvider = () async => throw PlatformException(
          code: 'PlatformException',
          message: 'java.lang.NoSuchMethodError: no non-static method '
              '"Lio/flutter/plugins/sharedpreferences/'
              'SharedPreferencesApiRegistrar;.getAll"');
      await _pump(tester, const PhoneSafetyScreen());
      expect(find.text(_t(tester).phoneSafeHonestNote), findsOneWidget);
      // honest: ticks only last this session
      expect(find.byKey(const Key('phonesafe-degraded')), findsOneWidget);
      expect(Settings.degraded, isTrue);
      expect(Settings.lastError, contains('NoSuchMethodError'));
      await _drain(tester);
    });

    testWidgets('storage that HANGS still ends in content (fake clock)',
        (tester) async {
      Settings.prefsProvider =
          () => Completer<SharedPreferences>().future; // never answers
      await _pump(tester, const PhoneSafetyScreen());
      expect(find.text(_t(tester).phoneSafeHonestNote), findsNothing);
      await tester.pump(const Duration(seconds: 15));
      await _settle(tester);
      expect(
          find.byKey(const Key('load-error')).evaluate().isNotEmpty ||
              find.text(_t(tester).phoneSafeHonestNote).evaluate().isNotEmpty,
          isTrue);
      await _drain(tester);
    });

    testWidgets('healthy storage: content and no degraded banner',
        (tester) async {
      await _pump(tester, const PhoneSafetyScreen());
      expect(find.text(_t(tester).phoneSafeHonestNote), findsOneWidget);
      expect(find.byKey(const Key('phonesafe-degraded')), findsNothing);
      await _drain(tester);
    });
  });

  // ----------------------------------------------------------- My Circle home
  group('My Circle home', () {
    testWidgets('FAB opens New chat: 4 actions on top, then contacts',
        (tester) async {
      await _hub(tester);
      final t = _t(tester);
      await _tapKey(tester, 'm3-fab');
      expect(find.text(t.msgrNewChat), findsWidgets);
      final keys = ['m3-new-add', 'm3-new-group', 'm3-new-community', 'm3-new-invite'];
      double last = -1;
      for (final k in keys) {
        final f = find.byKey(Key(k));
        expect(f, findsOneWidget, reason: k);
        final y = tester.getTopLeft(f).dy;
        expect(y, greaterThan(last), reason: 'order $k');
        last = y;
      }
      // honest contacts state (permission not granted -> disclosure) BELOW
      expect(find.byKey(const Key('c1-disclosure')), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const Key('c1-disclosure'))).dy,
          greaterThan(last));
      expect(find.text(t.m3AddToCircle), findsOneWidget);
      expect(find.text(t.m3InviteFriend), findsOneWidget);
      // Add to My Circle from New chat -> the add flow
      await _tapKey(tester, 'm3-new-add');
      expect(find.byType(M3AddToCircleScreen), findsOneWidget);
      await _drain(tester);
    });

    testWidgets('⋮ menu has Add to My Circle, Requests (count), Invite',
        (tester) async {
      final api = _Api()
        ..requests = [
          {'id': 7, 'direction': 'incoming', 'display_name': 'Karim',
           'actions': ['accept', 'decline', 'block']},
        ];
      await _hub(tester, api: api);
      final t = _t(tester);
      await tester.tap(find.byKey(const Key('m3-hub-menu')));
      await _settle(tester);
      expect(find.byKey(const Key('m3-menu-add')), findsOneWidget);
      expect(find.text(t.m3RequestsCount(1)), findsOneWidget);
      expect(find.text(t.m3InviteFriend), findsOneWidget);
      // menu order: Add, Requests, Invite before the old items
      final yAdd = tester.getTopLeft(find.byKey(const Key('m3-menu-add'))).dy;
      final yReq = tester.getTopLeft(find.byKey(const Key('m3-menu-requests'))).dy;
      final yInv = tester.getTopLeft(find.byKey(const Key('m3-menu-invite'))).dy;
      expect(yAdd < yReq && yReq < yInv, isTrue);
      expect(tester.getTopLeft(find.text(t.msgrHubNewGroup)).dy, greaterThan(yInv));
      await tester.tap(find.byKey(const Key('m3-menu-add')));
      await _settle(tester);
      expect(find.byType(M3AddToCircleScreen), findsOneWidget);
      await _drain(tester);
    });

    testWidgets('incoming requests sit at the TOP with a badge; Accept works',
        (tester) async {
      final api = _Api()
        ..requests = [
          {'id': 7, 'direction': 'incoming', 'display_name': 'Karim',
           'note': 'Hi, it is Karim', 'actions': ['accept', 'decline', 'block']},
          {'id': 8, 'direction': 'outgoing', 'display_name': 'Sent one',
           'actions': ['cancel', 'block']},
        ];
      await _hub(tester, api: api);
      final t = _t(tester);
      expect(find.byKey(const Key('m3-requests-banner')), findsOneWidget);
      expect(find.text('Karim'), findsOneWidget);
      expect(find.text('Sent one'), findsNothing); // sent ones live in Requests
      expect(find.byType(Badge), findsWidgets);
      await tester.tap(find.byKey(const Key('m3-accept-7')));
      await _settle(tester);
      expect(api.acts, ['/circle/request/7/act accept']);
      expect(find.text(t.m3AcceptedName('Karim')), findsOneWidget);
      expect(find.byKey(const Key('m3-requests-banner')), findsNothing);
      await _drain(tester);
    });

    testWidgets('Decline works; a failed accept shows a clear error',
        (tester) async {
      final api = _Api()
        ..requests = [
          {'id': 7, 'direction': 'incoming', 'display_name': 'Karim',
           'actions': ['accept', 'decline']},
          {'id': 9, 'direction': 'incoming', 'display_name': 'Selina',
           'actions': ['accept', 'decline']},
        ];
      await _hub(tester, api: api);
      final t = _t(tester);
      await tester.tap(find.byKey(const Key('m3-decline-7')));
      await _settle(tester);
      expect(api.acts, ['/circle/request/7/act decline']);
      expect(find.text(t.m3Declined), findsOneWidget);
      expect(find.text('Karim'), findsNothing);
      api.failures['/circle/request/9/act'] = ApiException('down', 503);
      await tester.tap(find.byKey(const Key('m3-accept-9')));
      await _settle(tester);
      expect(find.text(t.m3ErrServer), findsOneWidget);
      expect(find.text('Selina'), findsOneWidget); // still there to retry
      await _drain(tester);
    });

    testWidgets('requests that fail to load show Retry (never silent)',
        (tester) async {
      final api = _Api()..failures['/circle/requests'] = ApiException('x', 500);
      await _hub(tester, api: api);
      expect(find.byKey(const Key('load-error')), findsOneWidget);
      api.failures.clear();
      api.requests = [
        {'id': 7, 'direction': 'incoming', 'display_name': 'Karim',
         'actions': ['accept', 'decline']},
      ];
      await tester.tap(find.byKey(const Key('load-retry')));
      await _settle(tester);
      expect(find.text('Karim'), findsOneWidget);
      await _drain(tester);
    });
  });

  // ------------------------------------------------------- Add to My Circle
  group('Add to My Circle', () {
    testWidgets('any format -> found -> relation -> Send -> the chat opens',
        (tester) async {
      final opened = <Map<String, dynamic>>[];
      ConnectFlow.chatOverride = (_, m) async => opened.add(m);
      addTearDown(() => ConnectFlow.chatOverride = null);
      final api = _Api();
      await _pump(tester, const M3AddToCircleScreen(), api: api);
      final t = _t(tester);
      await tester.enterText(find.byKey(const Key('m3-number')), '+880 1865-052200');
      await _tapKey(tester, 'm3-find');
      expect(api.lookups, ['+8801865052200']);
      expect(find.byKey(const Key('m3-found')), findsOneWidget);
      expect(find.text('Nadia Rahman'), findsOneWidget);
      // relation is required
      await _tapKey(tester, 'm3-send');
      expect(find.text(t.msgrRelationRequired), findsOneWidget);
      expect(api.sent, isEmpty);
      await _tapKey(tester, 'm3-rel-friend');
      await _tapKey(tester, 'm3-send');
      expect(api.sent.single['to_user_id'], 2);
      expect(api.sent.single['relation'], 'friend');
      // connect-flow: no dead end — the chat opens with the banner
      // (the chat itself + banner: connect_flow_test.dart)
      expect(opened.single['id'], 99);
      expect(find.byKey(const Key('m3-sent')), findsNothing);
      expect(t.connRequestSentBanner, isNotEmpty);
      await _drain(tester);
    });

    testWidgets('family maps to a real server code; custom needs a label',
        (tester) async {
      final api = _Api();
      await _pump(tester, const M3AddToCircleScreen(initialNumber: '8801865052200'),
          api: api);
      await _tapKey(tester, 'm3-rel-custom');
      await _tapKey(tester, 'm3-send');
      expect(api.sent, isEmpty);
      await tester.enterText(find.byKey(const Key('m3-rel-custom-text')), 'Neighbour');
      await _settle(tester);
      await _tapKey(tester, 'm3-send');
      expect(api.sent.single['relation'], 'custom');
      expect(api.sent.single['custom_label'], 'Neighbour');
      await _drain(tester);
    });

    testWidgets('not on Assisto -> clear message + Invite them', (tester) async {
      await _pump(tester, const M3AddToCircleScreen());
      final t = _t(tester);
      await tester.enterText(find.byKey(const Key('m3-number')), '01999 888 777');
      await _tapKey(tester, 'm3-find');
      expect(find.byKey(const Key('m3-notfound')), findsOneWidget);
      expect(find.text(t.m3NotOnAssisto('01999888777')), findsOneWidget);
      expect(find.byKey(const Key('m3-invite-sms')), findsOneWidget);
      expect(find.byKey(const Key('m3-invite-whatsapp')), findsOneWidget);
      expect(find.byKey(const Key('m3-invite-share')), findsOneWidget);
      await _drain(tester);
    });

    testWidgets('invalid number, server failure and send failure are explained',
        (tester) async {
      final api = _Api();
      await _pump(tester, const M3AddToCircleScreen(), api: api);
      final t = _t(tester);
      await tester.enterText(find.byKey(const Key('m3-number')), '12345');
      await _tapKey(tester, 'm3-find');
      expect(find.text(t.c1SearchInvalid), findsOneWidget);
      expect(api.lookups, isEmpty);

      api.failures['/messenger/contacts/lookup'] = ApiException('boom', 502);
      await tester.enterText(find.byKey(const Key('m3-number')), '01865052200');
      await _tapKey(tester, 'm3-find');
      expect(find.byKey(const Key('m3-error')), findsOneWidget);
      expect(find.text(t.m3ErrServer), findsOneWidget);
      api.failures.clear();
      await tester.tap(find.text(t.retry));
      await _settle(tester);
      expect(find.byKey(const Key('m3-found')), findsOneWidget);

      api.failures['/circle/request'] = Exception('socket closed');
      await _tapKey(tester, 'm3-rel-colleague');
      await _tapKey(tester, 'm3-send');
      expect(find.byKey(const Key('m3-send-error')), findsOneWidget);
      expect(find.text(t.m3ErrOffline), findsWidgets);
      expect(find.byKey(const Key('m3-sent')), findsNothing);
      await _drain(tester);
    });

    testWidgets('a lookup that hangs ends in an error with Retry (15 s)',
        (tester) async {
      final api = _Api()..hang.add('/messenger/contacts/lookup');
      await _pump(tester, const M3AddToCircleScreen(), api: api);
      await tester.enterText(find.byKey(const Key('m3-number')), '01865052200');
      await tester.tap(find.byKey(const Key('m3-find')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 15, milliseconds: 10));
      await _settle(tester);
      expect(find.byKey(const Key('m3-error')), findsOneWidget);
      expect(find.text(_t(tester).m3ErrTimeout), findsOneWidget);
      await _drain(tester);
    });

    testWidgets('Bangla: the add screen renders without clipping at 360 px',
        (tester) async {
      await _pump(tester, const M3AddToCircleScreen(initialNumber: '01865052200'),
          lang: 'bn');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('m3-found')), findsOneWidget);
      await _drain(tester);
    });
  });

  // ------------------------------------------------- chat + drawer commands
  group('"circle" commands', () {
    test('whole-message commands route to My Circle add', () {
      for (final s in ['circle', 'My Circle', 'my circle!', 'add someone',
          'Add to my circle', 'open my circle', 'please add someone']) {
        expect(ChatNav.detectRoute(s), 'circle_add', reason: s);
      }
      expect(ChatNav.detectRoute('I spent 500 on food'), isNull);
      expect(ChatNav.routes.containsKey('circle_add'), isTrue);
      expect(ChatNav.routes.containsKey('circle'), isTrue);
    });

    testWidgets('drawer search "circle" finds My Circle (no "no match")',
        (tester) async {
      final key = GlobalKey<ScaffoldState>();
      await _pump(tester,
          Scaffold(key: key, drawer: const AppDrawer(), body: const SizedBox()));
      key.currentState!.openDrawer();
      await _settle(tester);
      final t = _t(tester);
      final search = find.descendant(
          of: find.byType(Drawer), matching: find.byType(TextField));
      await tester.enterText(search, 'circle');
      await _settle(tester);
      expect(find.byKey(const ValueKey('drawer_search_my_circle')), findsOneWidget);
      expect(find.text(t.sidebarNoResults), findsNothing);
      await _drain(tester);
    });
  });
}
