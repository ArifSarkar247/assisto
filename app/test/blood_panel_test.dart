// blood (owner 2 Nov) — Blood donor panel screens:
//  1 find: donor cards show area + rounded km + eligibility; a private number
//    is never shown (message only); Call / SMS only for a public number;
//  2 empty: benefit + one big action; "Me" tab -> become a donor;
//  3 setup: nothing is sent without BOTH consent boxes; the body carries the
//    group chosen here (never the Family card) and coarse data only;
//  4 request form: "real need" box required; the body has no contact fields;
//  5 requester: responders, Found -> share ONLY when the family agrees;
//  6 donor: "I can donate" posts the answer;
//  7 thread: the seeker can only ASK for My Circle;
//  8 banks: honest "source pending" state, no invented entries;
//  9 Bangla 200% text, light + dark: no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/blood_panel_api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/blood/blood_banks_screen.dart';
import 'package:assisto/screens/blood/blood_donor_setup_screen.dart';
import 'package:assisto/screens/blood/blood_hub_screen.dart';
import 'package:assisto/screens/blood/blood_request_detail_screen.dart';
import 'package:assisto/screens/blood/blood_request_form_screen.dart';
import 'package:assisto/screens/blood/blood_thread_screen.dart';
import 'package:assisto/services/review_prompt.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/success_share.dart';

import 'fake_blood.dart';

class _Fake extends ApiClient {
  _Fake({this.empty = false, this.bn = false}) {
    token = 't';
  }

  final bool empty;
  final bool bn;
  final List<String> gets = [];
  final List<(String, Map<String, dynamic>)> posts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    return fakeBloodGet(path, bn: bn, empty: empty) ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    return fakeBloodPost(path, bn: bn) ?? {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> deleteJson(String path) async => {'ok': true};
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
  t.view.physicalSize = const Size(1080, 7000);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

Future<void> _tap(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
}

Map<String, dynamic> _cfg() => fakeBloodGet('/blood-panel/config', bn: false, empty: false)!;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ReviewPrompt.debugRequest = null;
  });

  test('coarse rounding + groups', () {
    expect(bpCoarse(23.806912), 23.81);
    expect(kBloodGroups.length, 8);
  });

  testWidgets('find: area + km + eligibility; private number never shown', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    await t.pumpWidget(_app(const BloodHubScreen(), api));
    await t.pumpAndSettle();
    expect(api.gets.any((p) => p.startsWith('/blood-panel/donors') && p.contains('district=dhaka')), isTrue);
    expect(find.byKey(const ValueKey('bp-donor-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('bp-donor-call-3')), findsNothing);   // private
    expect(find.byKey(const ValueKey('bp-donor-call-4')), findsOneWidget); // public by choice
    expect(find.byKey(const ValueKey('bp-donor-sms-4')), findsOneWidget);
    expect(find.text(l.bpNumberPrivate), findsNWidgets(3)); // finish1: + a paused donor (shown)
    expect(find.text('01711000000'), findsNothing);                        // number not printed
    expect(find.textContaining(l.bpAboutKm(2)), findsOneWidget);
    expect(find.text(l.bpVerified), findsOneWidget);
    expect(find.text(l.bpPrivacyBody), findsOneWidget);
  });

  testWidgets('empty: benefit + one action; Me tab opens become-a-donor', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const BloodHubScreen(), _Fake(empty: true)));
    await t.pumpAndSettle();
    expect(find.text(l.bpFindEmptyTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('bp-find-cta')), findsOneWidget);
    await _tap(t, 'bp-tab-requests');
    await t.pumpAndSettle();
    expect(find.text(l.bpReqEmptyTitle), findsOneWidget);
    await _tap(t, 'bp-tab-me');
    await t.pumpAndSettle();
    expect(find.text(l.bpBecomeLead), findsOneWidget);
    await _tap(t, 'bp-become');
    await t.pumpAndSettle();
    expect(find.byType(BloodDonorSetupScreen), findsOneWidget);
  });

  testWidgets('setup: nothing sent without both consents; body is the group chosen here', (t) async {
    _tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(
        BloodDonorSetupScreen(initial: const {'district': 'dhaka'}, config: _cfg()), api));
    await t.pumpAndSettle();
    await _tap(t, 'bp-setup-g-O-');
    await _tap(t, 'bp-last-never');
    await t.pump();
    await _tap(t, 'bp-setup-save');
    await t.pumpAndSettle();
    expect(api.posts, isEmpty);
    await _tap(t, 'bp-consent');
    await _tap(t, 'bp-basics');
    await t.pump();
    await _tap(t, 'bp-setup-save');
    await t.pumpAndSettle();
    final p = api.posts.single;
    expect(p.$1, '/blood-panel/me');
    expect(p.$2['consent'], isTrue);
    expect(p.$2['enabled'], isTrue);
    expect(p.$2['blood_group'], 'O-');
    expect(p.$2['phone_public'], isFalse);
    expect(p.$2['email_public'], isFalse);
    expect(p.$2['last_donation'], isNull);
    expect(p.$2.containsKey('lat'), isFalse);
  });

  testWidgets('request form: real-need box required; no contact fields sent', (t) async {
    _tall(t);
    final api = _Fake();
    int? popped;
    await t.pumpWidget(_app(Builder(builder: (ctx) => Scaffold(
          body: Center(child: FilledButton(
            onPressed: () async {
              popped = await Navigator.of(ctx).push<int>(MaterialPageRoute(
                  builder: (_) => BloodRequestFormScreen(config: _cfg())));
            },
            child: const Text('open'),
          )),
        )), api));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await _tap(t, 'bp-req-g-B+');
    await t.ensureVisible(find.byKey(const ValueKey('bp-req-hospital')));
    await t.enterText(find.byKey(const ValueKey('bp-req-hospital')), 'Dhaka Medical College Hospital');
    await _tap(t, 'bp-req-submit');
    await t.pumpAndSettle();
    expect(api.posts, isEmpty);
    await _tap(t, 'bp-req-real');
    await t.pump();
    await _tap(t, 'bp-req-submit');
    await t.pumpAndSettle();
    final p = api.posts.single;
    expect(p.$1, '/blood-panel/requests');
    expect(p.$2['blood_group'], 'B+');
    expect(p.$2['district'], 'dhaka');
    expect(p.$2['radius_km'], 5);
    expect(DateTime.parse(p.$2['needed_by'] as String).isAfter(DateTime.now().toUtc()), isTrue);
    expect(p.$2.keys.any((k) => k.contains('phone') || k.contains('email')), isFalse);
    expect(popped, 31);
  });

  testWidgets('requester: responders; Found + agree asks the donor first (both sides)', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    await t.pumpWidget(_app(const BloodRequestDetailScreen(requestId: 31), api));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('bp-resp-3')), findsOneWidget);
    expect(find.text(l.bpRespondersTitle), findsOneWidget);
    await _tap(t, 'bp-found');
    await t.pumpAndSettle();
    await _tap(t, 'bp-found-share');
    await t.pump();
    await _tap(t, 'bp-found-confirm');
    await t.pumpAndSettle();
    // finish1 (owner final): the family's yes is recorded; the card opens
    // only once a donor who helped agrees too
    expect(api.posts.map((p) => p.$1).toList(),
        ['/blood-panel/requests/31/found', '/blood-panel/requests/31/share']);
    expect(find.byType(SuccessShareScreen), findsNothing);
  });

  testWidgets('requester: Found without agreeing does not open the share', (t) async {
    _tall(t);
    await t.pumpWidget(_app(const BloodRequestDetailScreen(requestId: 31), _Fake()));
    await t.pumpAndSettle();
    await _tap(t, 'bp-found');
    await t.pumpAndSettle();
    await _tap(t, 'bp-found-confirm');
    await t.pumpAndSettle();
    expect(find.byType(SuccessShareScreen), findsNothing);
  });

  testWidgets('donor: I can donate posts the answer; report is available', (t) async {
    _tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(const BloodRequestDetailScreen(requestId: 41), api));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('bp-report')), findsOneWidget);
    await _tap(t, 'bp-can');
    await t.pumpAndSettle();
    final p = api.posts.single;
    expect(p.$1, '/blood-panel/requests/41/respond');
    expect(p.$2, {'answer': 'can'});
  });

  testWidgets('thread: the seeker can only ask for My Circle', (t) async {
    _tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(const BloodThreadScreen(threadId: 7), api));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('bp-circle-accept')), findsNothing);
    await _tap(t, 'bp-circle-ask');
    await t.pumpAndSettle();
    expect(api.posts.single.$1, '/blood-panel/threads/7/circle');
    expect(api.posts.single.$2, {'action': 'ask'});
  });

  testWidgets('banks: honest source-pending state, no invented entries', (t) async {
    _tall(t);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const BloodBanksScreen(), _Fake()));
    await t.pumpAndSettle();
    expect(find.text(l.bpBanksPending), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  for (final dark in [false, true]) {
    testWidgets('200% Bangla ${dark ? 'dark' : 'light'}: hub, detail, form, setup, thread — no overflow',
        (t) async {
      _tall(t);
      final screens = <Widget>[
        const BloodHubScreen(),
        const BloodRequestDetailScreen(requestId: 31),
        const BloodRequestDetailScreen(requestId: 41),
        BloodRequestFormScreen(config: _cfg()),
        BloodDonorSetupScreen(initial: const {'district': 'dhaka'}, config: _cfg()),
        const BloodThreadScreen(threadId: 7),
        const BloodBanksScreen(),
      ];
      for (final w in screens) {
        await t.pumpWidget(_app(w, _Fake(bn: true), lang: 'bn', dark: dark, scale: 2));
        await t.pumpAndSettle();
        final e = t.takeException();
        if (e != null) fail('${w.runtimeType}: ${e is FlutterError ? e.toStringDeep() : e}');
      }
    });
  }

  // flipready (owner 2 Nov): on a 360 dp Bangla phone at 200% text the old
  // floating "জরুরি রক্তের অনুরোধ" button covered the empty state's big button
  // until the user scrolled. The request bar now sits below the list: every
  // empty-state button is tappable and never under the bar.
  for (final scale in [1.0, 2.0]) {
    testWidgets('360 dp Bangla ${scale}x: request bar never covers an empty-state button', (t) async {
      t.view.physicalSize = const Size(360 * 3, 760 * 3);
      t.view.devicePixelRatio = 3;
      t.view.padding = const FakeViewPadding(bottom: 48 * 3); // gesture/nav bar
      addTearDown(t.view.reset);
      final api = _Fake(empty: true, bn: true);
      await t.pumpWidget(_app(const BloodHubScreen(), api, lang: 'bn', scale: scale));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final bar = find.byKey(const ValueKey('bp-request-fab'));
      expect(bar, findsOneWidget);
      final barRect = t.getRect(bar);
      expect(barRect.bottom, lessThanOrEqualTo(760 - 48 + 0.5)); // clear of the nav bar
      Future<void> check(List<String> keys) async {
        // the list is lazy: at 200% text the card starts below the fold
        Finder? hit;
        for (var i = 0; i < 40 && hit == null; i++) {
          for (final k in keys) {
            final f = find.byKey(ValueKey(k));
            if (f.evaluate().isNotEmpty) hit = f;
          }
          if (hit == null) {
            await t.drag(find.byType(ListView).hitTestable().first, const Offset(0, -150));
            await t.pumpAndSettle();
          }
        }
        expect(hit, isNotNull, reason: 'none of $keys built');
        final f = hit!;
        final key = (f.evaluate().first.widget.key as ValueKey).value;
        await t.ensureVisible(f);
        await t.pumpAndSettle();
        final r = t.getRect(f);
        expect(r.overlaps(barRect), isFalse, reason: '$key under the request bar: $r vs $barRect');
        expect(r.bottom, lessThanOrEqualTo(barRect.top + 0.5));
        // the centre of the empty-state button really receives the tap
        final res = t.hitTestOnBinding(r.center);
        final target = t.renderObject(f);
        expect(res.path.any((e) => identical(e.target, target) ||
            (e.target is RenderObject && _isDescendant(e.target as RenderObject, target))), isTrue,
            reason: '$key is covered');
      }
      // find tab: before a search "use my location"; after an empty search
      // (the owner's case) the big "জরুরি রক্তের অনুরোধ" button
      await check(['bp-nodonor-cta', 'bp-find-cta']);
      await _tap(t, 'bp-tab-requests');
      await t.pumpAndSettle();
      await check(['bp-req-empty-cta']);
      await _tap(t, 'bp-tab-me');
      await t.pumpAndSettle();
      await check(['bp-become']);
      expect(t.takeException(), isNull);
    });
  }
}

bool _isDescendant(RenderObject child, RenderObject ancestor) {
  RenderObject? n = child;
  while (n != null) {
    if (identical(n, ancestor)) return true;
    n = n.parent;
  }
  return false;
}
