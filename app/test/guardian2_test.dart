// guardian2 (PART 6 two guardians): the child's "who can see me" (names +
// since when + requests that can NOT see yet), invite -> code sheet, join
// with a code, approve / reject, remove a co-guardian (confirm), SOS
// "I'm responding" + "<name> is responding", bn digits, 200 % font, dark,
// 48 dp targets.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/circle_guardians_screen.dart';
import 'package:assisto/screens/family_alerts_screen.dart';
import 'package:assisto/screens/guardian2_panel.dart';
import 'package:assisto/theme.dart';

Widget _app(Widget child, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    MaterialApp(
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
    );

Map<String, dynamic> _mine() => {
      'guardians': [
        {'id': 10, 'name': 'Mom', 'removable': false, 'since': '2026-09-01T08:00:00+00:00',
          'sources': [{'kind': 'school_mode', 'removable': false, 'set_up_by': 'Mom'}]},
        {'id': 11, 'name': 'Dad', 'removable': false, 'since': '2026-11-03T08:00:00+00:00',
          'sources': [{'kind': 'co_guardian', 'removable': false, 'set_up_by': 'Mom'}]},
      ],
      'pending': [
        {'id': 7, 'name': 'Uncle', 'requested_at': '2026-11-03T09:00:00+00:00'}
      ],
    };

Map<String, dynamic> _kids() => {
      'children': [
        {'key': 'u3', 'name': 'Rina', 'child_user_id': 3,
          'sources': [{'kind': 'school_mode'}], 'co_guardians': []},
      ]
    };

Map<String, dynamic> _links() => {
      'to_approve': [
        {'id': 5, 'state': 'pending', 'child_id': 3, 'child_name': 'Rina',
          'guardian_id': 11, 'guardian_name': 'Dad', 'max': 2}
      ],
      'invites': [],
      'co_guardians': [
        {'id': 6, 'state': 'approved', 'child_id': 3, 'child_name': 'Rina',
          'guardian_id': 12, 'guardian_name': 'Nanu',
          'approved_at': '2026-11-02T08:00:00+00:00'}
      ],
      'my_requests': [],
    };

void _tall(WidgetTester t, [Size s = const Size(420, 3000)]) {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

void main() {
  late List<String> calls;
  setUp(() {
    calls = [];
    guardiansLoaderOverride = (p) async => p.endsWith('mine') ? _mine() : _kids();
    guardian2ApiOverride = (method, path, body) async {
      calls.add('$method $path ${body ?? ''}');
      if (path == '/guardians/links') return _links();
      if (path == '/guardians/invites') {
        return {'id': 9, 'code': 'ABCDEFGH', 'link': 'https://lifeassisto.com/g/ABCDEFGH',
          'child_name': 'Rina', 'max': 2};
      }
      if (path == '/guardians/join') return {'id': 9, 'state': 'pending'};
      return {'ok': true, ..._links(), 'to_approve': [], 'co_guardians': []};
    };
  });
  tearDown(() {
    guardiansLoaderOverride = null;
    guardian2ApiOverride = null;
  });

  testWidgets('child sees every guardian, since when, and who can NOT see yet', (t) async {
    _tall(t);
    await t.pumpWidget(_app(const CircleGuardiansScreen()));
    await t.pumpAndSettle();
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text('Dad'), findsWidgets);
    expect(find.text(l.g2SrcCoGuardian), findsOneWidget);
    expect(find.byKey(const ValueKey('g2-since-11')), findsOneWidget);
    expect(find.text(l.g2Since('3/11/2026')), findsOneWidget);
    expect(find.byKey(const ValueKey('g2-pending-7')), findsOneWidget);
    expect(find.text(l.g2PendingBody('Uncle')), findsOneWidget);
  });

  testWidgets('approve a waiting request -> POST approve', (t) async {
    _tall(t);
    await t.pumpWidget(_app(const CircleGuardiansScreen()));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('g2-approve-card-5')), findsOneWidget);
    final sz = t.getSize(find.byKey(const ValueKey('g2-approve-5')));
    expect(sz.height, greaterThanOrEqualTo(48));
    await t.tap(find.byKey(const ValueKey('g2-approve-5')));
    await t.pumpAndSettle();
    expect(calls, contains('POST /guardians/links/5/approve '));
    expect(find.byKey(const ValueKey('g2-approve-card-5')), findsNothing);
  });

  testWidgets('reject a waiting request -> POST reject', (t) async {
    _tall(t);
    await t.pumpWidget(_app(const CircleGuardiansScreen()));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('g2-reject-5')));
    await t.pumpAndSettle();
    expect(calls, contains('POST /guardians/links/5/reject '));
  });

  testWidgets('remove a co-guardian asks first, then POST remove', (t) async {
    _tall(t);
    await t.pumpWidget(_app(const CircleGuardiansScreen()));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('g2-remove-6')));
    await t.pumpAndSettle();
    expect(calls.where((c) => c.contains('/remove')), isEmpty);
    await t.tap(find.byKey(const Key('g2-confirm-yes')));
    await t.pumpAndSettle();
    expect(calls, contains('POST /guardians/links/6/remove '));
  });

  testWidgets('invite a second guardian shows the code + share', (t) async {
    _tall(t);
    await t.pumpWidget(_app(const CircleGuardiansScreen()));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('g2-invite-btn-u3')));
    await t.pumpAndSettle();
    expect(calls, contains('POST /guardians/invites {child_id: 3}'));
    expect(find.byKey(const Key('g2-invite-code')), findsOneWidget);
    expect(find.text('ABCDEFGH'), findsOneWidget);
    expect(find.byKey(const Key('g2-invite-share')), findsOneWidget);
  });

  testWidgets('join with a code -> request waits for approval', (t) async {
    _tall(t);
    await t.pumpWidget(_app(const CircleGuardiansScreen()));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('g2-join')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('g2-join-field')), 'abcdefgh');
    await t.tap(find.byKey(const Key('g2-join-send')));
    await t.pumpAndSettle();
    expect(calls, contains('POST /guardians/join {code: abcdefgh}'));
  });

  testWidgets('bn, 200 % font, dark: Bangla digits, no overflow', (t) async {
    _tall(t, const Size(360, 5200));
    await t.pumpWidget(_app(const CircleGuardiansScreen(), lang: 'bn', scale: 2.0, dark: true));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    final l = await AppLocalizations.delegate.load(const Locale('bn'));
    expect(find.text(l.g2Since('৩/১১/২০২৬')), findsOneWidget);
    expect(find.byKey(const ValueKey('g2-approve-card-5')), findsOneWidget);
  });

  group('SOS responding', () {
    Map<String, dynamic> sos({bool mine = false, List? responders}) => {
          'id': 41, 'kind': 'sos', 'at': DateTime.now().toIso8601String(),
          'title': 'SOS: Rina needs help', 'body': 'Call now.', 'from_name': 'Rina',
          'lat': 23.75, 'lng': 90.39, 'seen': false, 'status': 'sent', 'active': true,
          'responding': mine, 'responders': responders ?? const [],
        };

    testWidgets('the other guardian sees "<name> is responding"', (t) async {
      _tall(t);
      await t.pumpWidget(_app(FamilyAlertsScreen(
          load: () async => {
                'received': [
                  sos(responders: [
                    {'name': 'Dad', 'at': '2026-11-03T09:00:00+00:00', 'me': false}
                  ])
                ],
                'sent': []
              },
          pushEnabled: () async => true)));
      await t.pumpAndSettle();
      expect(find.text('Dad is responding'), findsOneWidget);
    });

    testWidgets("I'm responding -> server + 'You are responding'", (t) async {
      _tall(t);
      final ids = <int>[];
      await t.pumpWidget(_app(FamilyAlertsScreen(
          load: () async => {'received': [sos()], 'sent': []},
          pushEnabled: () async => true,
          responding: (id) async {
            ids.add(id);
            return {
              'ok': true,
              'responders': [
                {'name': 'Mom', 'me': true}
              ]
            };
          })));
      await t.pumpAndSettle();
      final btn = find.byKey(const ValueKey('g2-responding-41'));
      expect(t.getSize(btn).height, greaterThanOrEqualTo(48));
      await t.tap(btn);
      await t.pumpAndSettle();
      expect(ids, [41]);
      expect(find.byKey(const ValueKey('g2-you-responding-41')), findsOneWidget);
    });

    testWidgets('bn dark 200 %: responder line in Bangla, no overflow', (t) async {
      _tall(t, const Size(360, 2400));
      await t.pumpWidget(_app(
          FamilyAlertsScreen(
              load: () async => {
                    'received': [
                      sos(responders: [
                        {'name': 'আব্বু', 'me': false}
                      ])
                    ],
                    'sent': []
                  },
              pushEnabled: () async => true),
          lang: 'bn',
          scale: 2.0,
          dark: true));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final l = await AppLocalizations.delegate.load(const Locale('bn'));
      expect(find.text(l.g2IsResponding('আব্বু')), findsOneWidget);
    });
  });
}
