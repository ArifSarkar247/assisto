// c1-contacts: "Contacts on Assisto" with a FAKE ContactsSource (the real
// plugin ships in the next native build). Proves: the disclosure shows BEFORE
// anything is read, "On Assisto" comes first with Add to My Circle, everyone
// else gets Invite, only hashes are uploaded, search works in any format, the
// unavailable source is honest, and a phonebook change re-syncs.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/messenger/contacts_screen.dart';
import 'package:assisto/services/contacts_source.dart';
import 'package:assisto/services/phone_canon.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

const _salt = 'test-salt';

class _FakeSource implements ContactsSource {
  _FakeSource(this.contacts, {this.grant = ContactsPermission.granted});

  final List<DeviceContact> contacts;
  ContactsPermission grant;
  int requests = 0;
  int reads = 0;
  final events = <String>[];
  final _changes = StreamController<void>.broadcast();

  void change() => _changes.add(null);

  @override
  bool get available => true;

  @override
  Future<ContactsPermission> status() async => ContactsPermission.denied;

  @override
  Future<ContactsPermission> request() async {
    requests++;
    events.add('request');
    return grant;
  }

  @override
  Future<List<DeviceContact>> read() async {
    reads++;
    events.add('read');
    return contacts;
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<bool> openSettings() async => true;
}

/// A tiny in-memory server: registered numbers -> users.
class _Api extends ApiClient {
  _Api() {
    token = 't';
  }

  final Map<String, Map<String, dynamic>> users = {
    '+8801865052200': {
      'id': 2,
      'name': 'Rahim Uddin',
      'photo': '',
      'circle': {'state': 'none', 'member_id': null, 'member': null},
    },
    '+8801711000555': {
      'id': 3,
      'name': 'Karim',
      'photo': '',
      'circle': {
        'state': 'accepted',
        'member_id': 30,
        'member': {'id': 30, 'name': 'Karim', 'state': 'accepted'},
      },
    },
  };
  final List<Map<String, dynamic>> matchBodies = [];
  final List<String> lookups = [];
  final List<Map<String, dynamic>> circleRequests = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/messenger/contacts/contract') {
      return {'salt': _salt, 'hash_len': 32, 'country_code': '880'};
    }
    if (path == '/referral/balance') {
      return {'invite_link': 'https://example.com/i/abc', 'referral_code': 'abc'};
    }
    throw ApiException('nope', 404);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path == '/messenger/contacts/match') {
      matchBodies.add(body);
      final matches = <Map<String, dynamic>>[];
      for (final e in users.entries) {
        final h = PhoneCanon.hashCanonical(e.key, _salt);
        if ((body['hashes'] as List).contains(h)) {
          matches.add({'contact_hash': h, 'user': Map.of(e.value)});
        }
      }
      return {'ok': true, 'matches': matches, 'stored': false};
    }
    if (path == '/messenger/contacts/lookup') {
      final p = '${body['phone']}';
      lookups.add(p);
      final u = users[p];
      return u == null
          ? {'ok': true, 'found': false, 'phone': p, 'is_self': false}
          : {'ok': true, 'found': true, 'phone': p, 'user': Map.of(u)};
    }
    if (path == '/circle/request') {
      circleRequests.add(body);
      return {'id': 99, 'state': 'pending'};
    }
    return {'ok': true};
  }
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

Future<void> _pump(WidgetTester tester, _Api api, ContactsSource source,
    {String lang = 'en'}) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
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
      theme: AssistoTheme.light,
      home: ContactsScreen(source: source),
    ),
  ));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(ContactsScreen)));

final _book = [
  const DeviceContact(name: 'Rahim (office)', numbers: ['+880 1865-052200']),
  const DeviceContact(name: 'Karim', numbers: ['01711-000555']),
  const DeviceContact(name: 'Zara', numbers: ['01999 888777']),
  const DeviceContact(name: 'Broken', numbers: ['12']),
];

Future<void> _allow(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('c1-allow')));
  await tester.tap(find.byKey(const Key('c1-allow')));
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('disclosure is shown BEFORE the permission prompt or any read',
      (tester) async {
    final src = _FakeSource(_book);
    final api = _Api();
    await _pump(tester, api, src);
    expect(find.byKey(const Key('c1-disclosure')), findsOneWidget);
    expect(find.text(_t(tester).c1DisclosureLead), findsOneWidget);
    expect(src.requests, 0);
    expect(src.reads, 0);
    expect(api.matchBodies, isEmpty);
    await _allow(tester);
    expect(src.events, ['request', 'read']);
    expect(find.byKey(const Key('c1-disclosure')), findsNothing);
  });

  testWidgets('"On Assisto" first with Add to My Circle, others get Invite',
      (tester) async {
    final src = _FakeSource(_book);
    final api = _Api();
    await _pump(tester, api, src);
    await _allow(tester);
    final t = _t(tester);
    final on = tester.getTopLeft(find.byKey(const Key('c1-section-on')));
    final inv = tester.getTopLeft(find.byKey(const Key('c1-section-invite')));
    expect(on.dy, lessThan(inv.dy));
    // the matched phonebook contact, under its phonebook name
    expect(find.text('Rahim (office)'), findsOneWidget);
    expect(find.text(t.c1OnAssistoAs('Rahim Uddin')), findsOneWidget);
    expect(find.byKey(const Key('c1-add-2')), findsOneWidget);
    // an accepted circle member gets Message + Call
    expect(find.byKey(const Key('c1-msg-3')), findsOneWidget);
    expect(find.text(t.c1Call), findsOneWidget);
    // the non-user is below with Invite; the invalid number is dropped
    final zara = tester.getTopLeft(find.text('Zara'));
    expect(zara.dy, greaterThan(inv.dy));
    expect(find.text('Broken'), findsNothing);
    expect(find.text(t.c1Invite), findsWidgets);
    // only salted hashes left the device — never a raw number
    final hashes = (api.matchBodies.single['hashes'] as List).cast<String>();
    expect(hashes, hasLength(3));
    for (final h in hashes) {
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(h), isTrue);
    }
    expect(api.matchBodies.single.toString().contains('1865052200'), isFalse);
  });

  testWidgets('Add to My Circle sends a circle request for that user',
      (tester) async {
    final src = _FakeSource(_book);
    final api = _Api();
    await _pump(tester, api, src);
    await _allow(tester);
    await tester.tap(find.byKey(const Key('c1-add-2')));
    await _settle(tester);
    // the relation sheet: pick a relation, then Send request
    await tester.tap(find.byType(ChoiceChip).first);
    await _settle(tester);
    final send = find.text(_t(tester).msgrSendRequest);
    await tester.ensureVisible(send);
    await tester.tap(send);
    await _settle(tester);
    expect(api.circleRequests, hasLength(1));
    expect(api.circleRequests.single['to_user_id'], 2);
    expect(api.circleRequests.single['relation'], isNotEmpty);
    expect(find.text(_t(tester).c1Requested), findsOneWidget);
    expect(find.byKey(const Key('c1-add-2')), findsNothing);
  });

  testWidgets('manual search finds the user in ANY format', (tester) async {
    final src = _FakeSource(const []);
    final api = _Api();
    await _pump(tester, api, src);
    final notNow = find.text(_t(tester).msgrContactsDeny);
    await tester.ensureVisible(notNow);
    await tester.tap(notNow); // "Not now" -> straight to search
    await _settle(tester);
    for (final raw in [
      '+880 1865-052200',
      '8801865052200',
      '01865052200',
      '০১৮৬৫০৫২২০০',
    ]) {
      await tester.enterText(find.byKey(const Key('c1-search')), raw);
      await tester.tap(find.byKey(const Key('c1-search-go')));
      await _settle(tester);
      expect(api.lookups.last, '+8801865052200', reason: raw);
      expect(find.byKey(const Key('c1-search-found')), findsOneWidget);
      expect(find.text('Rahim Uddin'), findsOneWidget);
      expect(find.byKey(const Key('c1-add-2')), findsOneWidget);
    }
    // not on Assisto -> Invite
    await tester.enterText(find.byKey(const Key('c1-search')), '01999888777');
    await tester.tap(find.byKey(const Key('c1-search-go')));
    await _settle(tester);
    expect(find.byKey(const Key('c1-search-notfound')), findsOneWidget);
    expect(find.text(_t(tester).c1SearchNotFound('01999888777')), findsOneWidget);
    // invalid -> honest error, no server call
    final before = api.lookups.length;
    await tester.enterText(find.byKey(const Key('c1-search')), '123');
    await tester.tap(find.byKey(const Key('c1-search-go')));
    await _settle(tester);
    expect(find.text(_t(tester).c1SearchInvalid), findsOneWidget);
    expect(api.lookups.length, before);
  });

  testWidgets('reader refused on this phone: honest reason, no Allow loop',
      (tester) async {
    final src = _FakeSource(_book, grant: ContactsPermission.unavailable);
    final api = _Api();
    await _pump(tester, api, src);
    await _allow(tester);
    final t = _t(tester);
    expect(find.byKey(const Key('c1-unavailable')), findsOneWidget);
    expect(find.text(t.c1PhonebookCantReadTitle), findsOneWidget);
    expect(find.text(t.msgrContactsAllow), findsNothing);
    expect(src.reads, 0);
    expect(api.matchBodies, isEmpty);
  });

  testWidgets('unavailable source is honest: no disclosure, no fake read',
      (tester) async {
    final api = _Api();
    await _pump(tester, api, const UnavailableContactsSource());
    final t = _t(tester);
    expect(find.byKey(const Key('c1-disclosure')), findsNothing);
    expect(find.byKey(const Key('c1-unavailable')), findsOneWidget);
    expect(find.text(t.c1PhonebookCantReadTitle), findsOneWidget);
    expect(find.byKey(const Key('c1-section-on')), findsNothing);
    expect(api.matchBodies, isEmpty);
    // search still works
    await tester.enterText(find.byKey(const Key('c1-search')), '01865052200');
    await tester.tap(find.byKey(const Key('c1-search-go')));
    await _settle(tester);
    expect(find.byKey(const Key('c1-search-found')), findsOneWidget);
  });

  testWidgets('permission denied -> recoverable denied state', (tester) async {
    final src = _FakeSource(_book, grant: ContactsPermission.denied);
    await _pump(tester, _Api(), src);
    await _allow(tester);
    expect(src.reads, 0);
    expect(find.text(_t(tester).c1SearchInstead), findsOneWidget);
  });

  testWidgets('a phonebook change re-syncs (and Bangla renders)',
      (tester) async {
    final src = _FakeSource(_book);
    final api = _Api();
    await _pump(tester, api, src, lang: 'bn');
    await _allow(tester);
    expect(src.reads, 1);
    expect(find.byKey(const Key('c1-section-on')), findsOneWidget);
    src.change();
    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);
    expect(src.reads, 2);
    expect(api.matchBodies, hasLength(2));
  });
}
