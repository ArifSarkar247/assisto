// fcrest (Family Care V3 rest, 9 Nov) — the pieces wired / built on top of
// fcscreen + fcelder + fcsos + fcbrain:
//  1 slots: fcRegisterSlots fills every Family hook (5-second SOS sender,
//    night news, phone ask parser, server ask, privacy, elder More rows) and
//    the elder Danger button's SOS hook — test fakes are never overwritten
//  2 Probashi: both clocks on the card of a member who lives abroad
//  3 15 % battery: last place line + Open map; hidden while paused
//  4 area from the phone Geocoder shows as "Around …"; areaNow() is null
//    inside a saved place and never asks the Geocoder then
//  5 member page settings: Where I live (self) posts abroad_tz; admin sees
//    name + remove (confirm first); a plain member sees no settings
//  6 admin More row renames the family
//  7 Bangla digits + 200 % font without overflow, dark theme
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/eldercare/elder_common.dart';
import 'package:assisto/family_v3/brain/fc_watch.dart';
import 'package:assisto/family_v3/family_v3_screen.dart';
import 'package:assisto/family_v3/fc_member_card.dart';
import 'package:assisto/family_v3/fc_member_page.dart';
import 'package:assisto/family_v3/fc_slots.dart';
import 'package:assisto/family_v3/fc_slots_register.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/maps/address_resolver.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_fcscreen.dart';

class _Api extends ApiClient {
  _Api({this.scene = 'mixed'});
  String scene;
  final List<String> posts = [];
  final List<Map<String, dynamic>> bodies = [];
  bool bn = false;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final p = path.startsWith('/') ? path.substring(1) : path;
    if (p == 'family/v3/families') return fcFakeFamilies(bn: bn, scene: scene);
    if (p.endsWith('/board')) return fcFakeBoard(bn: bn, scene: scene);
    final mp = RegExp(r'^family/v3/members/(\d+)').firstMatch(p);
    if (mp != null) return fcFakeMemberPage(int.parse(mp.group(1)!), bn: bn);
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    bodies.add(body);
    return {'ok': true, 'text': ''};
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => [];
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

Future<void> _pump(WidgetTester t, Widget w, ApiClient api,
    {String lang = 'en', bool dark = false, double scale = 1}) async {
  t.view.physicalSize = const Size(1080, 4800);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(w, api, lang: lang, dark: dark, scale: scale));
  await t.pumpAndSettle();
}

Position _pos(double lat, double lng) => Position(
    latitude: lat,
    longitude: lng,
    timestamp: DateTime.now(),
    accuracy: 20,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0);

Map<String, dynamic> _member({String tz = '', Map? lastLoc, String state = 'check', String pk = '', String pl = ''}) {
  final m = fcFakeMember(5, 'Sakib',
      ago: const Duration(minutes: 5), battery: 14, state: state, reason: state == 'paused' ? 'paused' : 'battery_low',
      placeKind: pk, placeLabel: pl, abroadTz: tz, now: DateTime.utc(2026, 11, 9, 7));
  if (lastLoc != null) (m['brain'] as Map)['last_location'] = lastLoc;
  if (state == 'paused') {
    (m['brain'] as Map)['paused_until'] = DateTime.utc(2026, 11, 9, 9).toIso8601String();
  }
  return m;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AddressResolver.debugArea = null;
  });

  test('slots: every Family hook + the elder SOS hook are registered', () {
    FcSlots.openSosSender = null;
    FcSlots.nightNewsCard = null;
    FcSlots.askParser = null;
    FcSlots.serverAsk = null;
    FcSlots.privacyScreen = null;
    FcSlots.moreRows = null;
    FcSlots.journeyTile = null;
    ElderHooks.openSos = null;
    fcResetSlotsForTest();
    fcRegisterSlots();
    expect(FcSlots.openSosSender, isNotNull);
    expect(FcSlots.nightNewsCard, isNotNull);
    expect(FcSlots.askParser, isNotNull);
    expect(FcSlots.serverAsk, isNotNull);
    expect(FcSlots.privacyScreen, isNotNull);
    expect(FcSlots.moreRows, isNotNull);
    expect(FcSlots.journeyTile, isNotNull);
    expect(ElderHooks.openSos, isNotNull);
    // the phone parser answers from the board members (free, offline)
    final a = FcSlots.askParser!('Is Ammu OK?', const FcAskContext(10, [
      {'userId': 2, 'name': 'Nasrin', 'label': 'Ammu', 'relation': 'mother', 'state': 'ok',
       'placeLabel': 'Home', 'lastSeen': '2026-11-09T07:00:00Z', 'battery': 60},
    ]));
    expect(a, isNotNull);
    expect(a!.memberUserId, 2);
    // a second call never overwrites what a test (or another module) set
    FcSlots.moreRows = null;
    fcRegisterSlots();
    expect(FcSlots.moreRows, isNull);
  });

  testWidgets('elder Danger opens the SOS hook registered by fcrest', (t) async {
    var opened = 0;
    ElderHooks.openSos = (_) async => opened++;
    await _pump(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => ElderHooks.sos(c), child: const Text('Danger')))), _Api());
    await t.tap(find.text('Danger'));
    await t.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('Probashi: both clocks on the card (en + bn digits)', (t) async {
    final now = DateTime.utc(2026, 11, 9, 7); // Riyadh = UTC+3 -> 10:00 AM
    await _pump(t, Scaffold(body: FcMemberCard(member: _member(tz: 'Asia/Riyadh'), now: now)), _Api());
    expect(find.byKey(const ValueKey('fcr-clocks-5')), findsOneWidget);
    expect(find.textContaining('Saudi Arabia'), findsOneWidget);
    expect(find.textContaining('Their time 10:00 AM'), findsOneWidget);
    await _pump(t, Scaffold(body: FcMemberCard(member: _member(tz: 'Asia/Riyadh'), now: now)), _Api(), lang: 'bn');
    final txt = t.widget<Text>(find.byKey(const ValueKey('fcr-clocks-5'))).data!;
    expect(txt, contains('সৌদি আরব'));
    expect(txt, contains('১০:০০'));
    expect(RegExp(r'[0-9]').hasMatch(txt), isFalse, reason: txt);
    // lives in Bangladesh: no clock line
    await _pump(t, Scaffold(body: FcMemberCard(member: _member(), now: now)), _Api());
    expect(find.byKey(const ValueKey('fcr-clocks-5')), findsNothing);
  });

  testWidgets('15 % battery: last place + Open map; hidden while paused', (t) async {
    final now = DateTime.utc(2026, 11, 9, 7);
    final loc = {'lat': 23.8, 'lng': 90.36, 'pct': 15, 'why': 'battery_low', 'at': '2026-11-09T06:40:00Z'};
    await _pump(t, Scaffold(body: FcMemberCard(member: _member(lastLoc: loc), now: now)), _Api());
    expect(find.byKey(const ValueKey('fcr-lastloc-5')), findsOneWidget);
    expect(find.textContaining('Battery was 15%'), findsOneWidget);
    expect(find.byKey(const ValueKey('fcr-map-5')), findsOneWidget);
    expect(t.getSize(find.byKey(const ValueKey('fcr-map-5'))).height, greaterThanOrEqualTo(48));
    await _pump(t, Scaffold(body: FcMemberCard(member: _member(lastLoc: loc, state: 'paused'), now: now)), _Api());
    expect(find.byKey(const ValueKey('fcr-lastloc-5')), findsNothing);
  });

  testWidgets('area from the phone Geocoder reads "Around …"', (t) async {
    final now = DateTime.utc(2026, 11, 9, 7);
    await _pump(t, Scaffold(body: FcMemberCard(member: _member(state: 'ok', pk: 'area', pl: 'Dhanmondi'), now: now)), _Api());
    expect(find.text('Around Dhanmondi'), findsOneWidget);
  });

  test('areaNow: name outside saved places, null inside one (no Geocoder call)', () async {
    var asked = 0;
    AddressResolver.debugArea = (lat, lng, lang) async {
      asked++;
      return 'Dhanmondi, Dhaka';
    };
    SharedPreferences.setMockInitialValues({
      'fcb_fences': jsonEncode([
        {'id': 1, 'kind': 'home', 'lat': 23.7500, 'lng': 90.3900, 'r': 150}
      ]),
    });
    final p = await SharedPreferences.getInstance();
    expect(await FcWatch.areaNow(p, locate: () async => _pos(23.7600, 90.3700)), 'Dhanmondi, Dhaka');
    expect(asked, 1);
    expect(await FcWatch.areaNow(p, locate: () async => _pos(23.7501, 90.3901)), isNull);
    expect(asked, 1);
    expect(await FcWatch.areaNow(p, locate: () async => null), isNull);
    await p.setString('fcb_inside', jsonEncode([1]));
    expect(await FcWatch.areaNow(p, locate: () async => _pos(23.7600, 90.3700)), isNull);
    expect(asked, 1);
  });

  testWidgets('member page: Where I live posts abroad_tz (self only)', (t) async {
    final api = _Api();
    await _pump(t, FcMemberPage(familyId: 10, userId: 1, seed: fcFakeMembers().last, myRole: 'adult'), api);
    final live = find.byKey(const ValueKey('fcr-live'));
    await t.scrollUntilVisible(live, 300, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const ValueKey('fcr-remove')), findsNothing); // never on myself
    await t.tap(live);
    await t.pumpAndSettle();
    final riyadh = find.byKey(const ValueKey('fcr-zone-Asia/Riyadh'));
    await t.scrollUntilVisible(riyadh, 200, scrollable: find.descendant(
        of: find.byKey(const ValueKey('fcr-zone-list')), matching: find.byType(Scrollable)).first);
    await t.tap(riyadh);
    await t.pumpAndSettle();
    expect(api.posts, contains('/family/v3/families/10/members/1'));
    expect(api.bodies.last, {'abroad_tz': 'Asia/Riyadh'});
  });

  testWidgets('member page: admin edits the name and removes after confirming', (t) async {
    final api = _Api();
    await _pump(t, FcMemberPage(familyId: 10, userId: 5, seed: fcFakeMembers()[1], myRole: 'admin'), api);
    expect(find.byKey(const ValueKey('fcr-live')), findsNothing); // not my zone to set
    final label = find.byKey(const ValueKey('fcr-label'));
    await t.scrollUntilVisible(label, 300, scrollable: find.byType(Scrollable).first);
    await t.tap(label);
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('fcr-label-field')), 'Bhaiya');
    await t.tap(find.byKey(const ValueKey('fcr-text-save')));
    await t.pumpAndSettle();
    expect(api.bodies.last, {'label': 'Bhaiya'});
    final rm = find.byKey(const ValueKey('fcr-remove'));
    await t.scrollUntilVisible(rm, 300, scrollable: find.byType(Scrollable).first);
    await t.tap(rm);
    await t.pumpAndSettle();
    expect(api.posts.where((p) => p.contains('/remove/')), isEmpty); // confirm first
    await t.tap(find.byKey(const ValueKey('fcr-remove-yes')));
    await t.pumpAndSettle();
    expect(api.posts, contains('/family/v3/families/10/remove/5'));
  });

  testWidgets('member page: a plain member sees no settings for someone else', (t) async {
    await _pump(t, FcMemberPage(familyId: 10, userId: 5, seed: fcFakeMembers()[1], myRole: 'adult'), _Api());
    expect(find.byKey(const ValueKey('fcr-manage')), findsNothing);
  });

  testWidgets('admin More row renames the family', (t) async {
    fcRegisterSlots();
    FcSlots.moreRows = null;
    FcSlots.nightNewsCard = null;
    FcSlots.journeyTile = null;
    final api = _Api();
    await _pump(t, const FamilyV3Screen(), api);
    final row = find.byKey(const ValueKey('fcr-more-rename'));
    await t.scrollUntilVisible(row, 400, scrollable: find.byType(Scrollable).first);
    // gap-familycare: keep the row clear of the red SOS bar at the bottom
    await t.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await t.pumpAndSettle();
    await t.tap(row);
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('fcr-rename-field')), "Parents' home");
    await t.tap(find.byKey(const ValueKey('fcr-text-save')));
    await t.pumpAndSettle();
    expect(api.posts, contains('/family/v3/families/10/rename'));
    expect(api.bodies[api.posts.indexOf('/family/v3/families/10/rename')], {'name': "Parents' home"});
  });

  for (final dark in [false, true]) {
    testWidgets('200 % font, Bangla, dark=$dark: card + member page without overflow', (t) async {
      final now = DateTime.utc(2026, 11, 9, 7);
      final loc = {'lat': 23.8, 'lng': 90.36, 'pct': 15, 'why': 'battery_low', 'at': '2026-11-09T06:40:00Z'};
      await _pump(
          t,
          Scaffold(body: SingleChildScrollView(child: FcMemberCard(
              member: _member(tz: 'Asia/Riyadh', lastLoc: loc, pk: 'area', pl: 'মিরপুর'), now: now))),
          _Api(),
          lang: 'bn', dark: dark, scale: 2);
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('fcr-lastloc-5')), findsOneWidget);
      final api = _Api()..bn = true;
      await _pump(t, FcMemberPage(familyId: 10, userId: 1, seed: fcFakeMembers(bn: true).last, myRole: 'admin'), api,
          lang: 'bn', dark: dark, scale: 2);
      expect(t.takeException(), isNull);
    });
  }
}
