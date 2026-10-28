// famcare (owner real-phone review 28 Oct) — Family Care:
//  1 the family alerts entry renders ONCE (Family tab only, never on others)
//  2 every empty tab: one-line benefit + big primary button (+ how-to)
//  3 members are picked from My Circle in one tap; already-added = tick;
//    adding by hand also sends a My Circle request
//  4 the Probashi tab is absent while its flag is off
//  5 family card saves on the phone; shopping list adds/ticks; bn digits;
//    onboarding offers the elderly simple home.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/feature_gates.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/family_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/fam_card_section.dart';
import 'package:assisto/widgets/onb_role.dart';

class _Fake extends ApiClient {
  _Fake({List<Map<String, dynamic>>? members, List<Map<String, dynamic>>? circle})
      : members = members ?? [],
        circle = circle ?? [] {
    token = 't';
  }

  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> circle;
  final List<Map<String, dynamic>> shop = [];
  final List<String> posts = [];
  final List<String> creates = [];

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async {
    if (path.startsWith('family')) return [for (final m in members) Map.of(m)];
    return [];
  }

  @override
  Future<Map<String, dynamic>> createItem(String path, Map<String, dynamic> body) async {
    creates.add(path);
    if (path == 'family') {
      final m = {'id': 100 + members.length, ...body, 'in_circle': false};
      members.add(m);
      return m;
    }
    return {'id': 1, ...body};
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/family/alerts') return {'received': [], 'sent': [], 'unseen': 0};
    if (path == '/family/limits') {
      return {'limit': 5, 'used': members.length, 'left': 5 - members.length, 'safety_free': true};
    }
    if (path == '/family/circle-pick') {
      return {
        'results': [
          for (final c in circle)
            {
              ...c,
              'family_id': members
                  .where((m) => m['circle_member'] == c['circle_id'])
                  .map((m) => m['id'])
                  .firstOrNull,
            }
        ]
      };
    }
    if (path == '/family/reminders') return {'assigned_by_me': [], 'assigned_to_me': []};
    if (path == '/family/shopping') {
      return {
        'lists': [
          {'owner_id': 1, 'owner_name': 'Me', 'mine': true, 'shared_with': 0, 'items': shop}
        ]
      };
    }
    if (path == '/family/docs') return {'shared_by_me': [], 'shared_with_me': []};
    if (path.startsWith('/family/sharing')) return {'rows': [], 'entries': []};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    if (path == '/family/from-circle') {
      final c = circle.firstWhere((x) => x['circle_id'] == body['circle_member_id']);
      final m = {
        'id': 200 + members.length, 'name': c['name'], 'relation': c['relation'],
        'phone': c['phone'], 'circle_member': c['circle_id'], 'in_circle': true,
      };
      members.add(m);
      return {'ok': true, 'created': true, 'member': m};
    }
    if (path == '/family/shopping') {
      final it = {'id': shop.length + 1, 'text': body['text'], 'qty': '', 'done': false,
          'added_by': 'Me', 'done_by': ''};
      shop.add(it);
      return {'ok': true, 'item': it};
    }
    if (path.startsWith('/family/shopping/') && path.endsWith('/toggle')) {
      final id = int.parse(path.split('/')[3]);
      final it = shop.firstWhere((x) => x['id'] == id);
      it['done'] = !(it['done'] == true);
      it['done_by'] = it['done'] == true ? 'Me' : '';
      return {'ok': true, 'item': it};
    }
    return {'ok': true};
  }
}

Widget _app(Widget child, ApiClient api,
    {String lang = 'en', bool dark = false, double scale = 1}) {
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
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
              child: w!),
      home: child,
    ),
  );
}

final _mom = {
  'id': 1, 'name': 'Mom', 'relation': 'mother', 'phone': '01710000000',
  'circle_member': 7, 'in_circle': true,
};
final _typed = {'id': 2, 'name': 'Uncle', 'relation': 'Uncle', 'phone': '', 'in_circle': false};
final _circleMom = {'circle_id': 7, 'name': 'Mom', 'relation': 'mother', 'phone': '01710000000'};
final _circleBro = {'circle_id': 8, 'name': 'Rafi', 'relation': 'brother', 'phone': '01810000000'};

Future<void> _tab(WidgetTester t, String label) async {
  await t.tap(find.descendant(of: find.byType(TabBar), matching: find.text(label)));
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    debugMedicalFeaturesOverride = false; // the Play build's 6 tabs
    FeatureFlags.instance.debugOverride = {'probashi_plan': false};
  });
  tearDown(() {
    debugMedicalFeaturesOverride = null;
    FeatureFlags.instance.debugOverride = null;
  });

  testWidgets('alerts entry shows exactly once — on the Family tab only', (t) async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const FamilyScreen(), _Fake(members: [Map.of(_mom)])));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('fa100-tile')), findsOneWidget);
    for (final tab in [l.faTitle, l.familySchoolTitle, l.famShareTabSelective, l.famShareTabCard]) {
      await _tab(t, tab);
      expect(find.byKey(const ValueKey('fa100-tile')), findsNothing, reason: tab);
    }
    await _tab(t, l.moduleFamily);
    expect(find.byKey(const ValueKey('fa100-tile')), findsOneWidget);
  });

  testWidgets('Probashi tab is absent while its flag is off, present when on', (t) async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const FamilyScreen(), _Fake()));
    await t.pumpAndSettle();
    expect(find.text(l.famShareTabProbashi), findsNothing);
    expect(find.descendant(of: find.byType(TabBar), matching: find.byType(Tab)), findsNWidgets(5));
    FeatureFlags.instance.debugOverride = {'probashi_plan': true};
    await t.pumpWidget(_app(const FamilyScreen(), _Fake(), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.descendant(of: find.byType(TabBar), matching: find.byType(Tab)), findsNWidgets(6));
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('every empty tab has a benefit line + big primary button ($lang)', (t) async {
      final l = await AppLocalizations.delegate.load(Locale(lang));
      await t.pumpWidget(_app(const FamilyScreen(), _Fake(), lang: lang));
      await t.pumpAndSettle();
      // Family
      expect(find.text(l.fcFamilyEmptyBenefit), findsOneWidget);
      expect(find.byKey(const ValueKey('fam-empty-primary')), findsOneWidget);
      expect(find.text(l.fcFamilyStep1), findsOneWidget);
      // the alerts entry sits on the empty Family tab too — once
      expect(find.byKey(const ValueKey('fa100-tile')), findsOneWidget);
      // School
      await _tab(t, l.familySchoolTitle);
      expect(find.text(l.fcSchoolEmptyBenefit), findsOneWidget);
      expect(find.byKey(const ValueKey('fam-empty-primary')), findsOneWidget);
      expect(find.byKey(const ValueKey('fa100-tile')), findsNothing);
      // Sharing (shopping pane first)
      await _tab(t, l.famShareTabSelective);
      expect(find.text(l.fcShopEmptyBenefit), findsOneWidget);
      expect(find.byKey(const ValueKey('fam-empty-primary')), findsOneWidget);
      // Family card — no longer a dead end
      await _tab(t, l.famShareTabCard);
      expect(find.text(l.fcCardEmptyBenefit), findsOneWidget);
      expect(find.byKey(const ValueKey('fam-empty-primary')), findsOneWidget);
      expect(find.byKey(const ValueKey('fam-empty-secondary')), findsOneWidget);
    });
  }

  testWidgets('pick from My Circle: one tap adds, tick after, member gets SOS', (t) async {
    final api = _Fake(circle: [Map.of(_circleMom), Map.of(_circleBro)]);
    await t.pumpWidget(_app(const FamilyScreen(), api));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('fam-empty-primary')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('fc-pick-7')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('fc-pick-7')));
    await t.pumpAndSettle();
    expect(api.posts.where((p) => p == '/family/from-circle').length, 1);
    // ticked now: a second tap does nothing
    await t.tap(find.byKey(const ValueKey('fc-pick-7')));
    await t.pumpAndSettle();
    expect(api.posts.where((p) => p == '/family/from-circle').length, 1);
    await t.tap(find.byKey(const ValueKey('fc-pick-done')));
    await t.pumpAndSettle();
    expect(find.text('Mom'), findsWidgets);
    expect(find.byKey(const ValueKey('fc-sos-yes')), findsOneWidget);
    expect(api.creates.contains('family'), isFalse, reason: 'never typed twice');
  });

  testWidgets('adding by hand also sends a My Circle request', (t) async {
    final api = _Fake(members: [Map.of(_mom)]);
    await t.pumpWidget(_app(const FamilyScreen(), api));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('fc-hand-btn')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('fc-form-name')), 'Rafi');
    await t.enterText(find.byKey(const ValueKey('fc-form-phone')), '01810000000');
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('fc-form-save')));
    await t.pumpAndSettle();
    expect(api.creates, contains('family'));
    expect(api.posts, contains('/circle/request'));
  });

  testWidgets('a hand-typed member says honestly they do not get the SOS', (t) async {
    await t.pumpWidget(_app(const FamilyScreen(), _Fake(members: [Map.of(_mom), Map.of(_typed)])));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('fc-sos-yes')), findsOneWidget);
    expect(find.byKey(const ValueKey('fc-sos-no')), findsOneWidget);
  });

  testWidgets('bn: the members line uses Bangla digits', (t) async {
    await t.pumpWidget(_app(const FamilyScreen(), _Fake(members: [Map.of(_mom)]), lang: 'bn'));
    await t.pumpAndSettle();
    final line = t.widget<Text>(find.byKey(const ValueKey('fc-limit-line'))).data!;
    expect(line, contains('৫'));
    expect(line, contains('১'));
    expect(RegExp(r'[0-9]').hasMatch(line), isFalse);
  });

  testWidgets('family card: emergency info is saved on the phone and reopens', (t) async {
    final api = _Fake();
    await t.pumpWidget(_app(const Scaffold(body: FamCardSection(members: [])), api));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('fam-empty-primary')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('fc-card-c0-name')), 'Karim');
    await t.enterText(find.byKey(const ValueKey('fc-card-c0-phone')), '01911000000');
    await t.tap(find.byKey(const ValueKey('fc-card-save')));
    await t.pumpAndSettle();
    expect(find.textContaining('Karim', findRichText: true), findsWidgets);
    // a fresh open (e.g. offline) still has it
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(_app(const Scaffold(body: FamCardSection(members: null)), api));
    await t.pumpAndSettle();
    expect(find.textContaining('Karim', findRichText: true), findsWidgets);
    expect(find.byKey(const ValueKey('fc-card-offline')), findsOneWidget);
  });

  testWidgets('shopping list: add then tick an item', (t) async {
    final api = _Fake(members: [Map.of(_mom)]);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const FamilyScreen(), api));
    await t.pumpAndSettle();
    await _tab(t, l.famShareTabSelective);
    await t.enterText(find.byKey(const ValueKey('fc-shop-input')), 'Rice');
    await t.tap(find.byKey(const ValueKey('fc-shop-add')));
    await t.pumpAndSettle();
    expect(find.text('Rice'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('fc-shop-1')));
    await t.pumpAndSettle();
    expect(api.shop.first['done'], isTrue);
    expect(find.text(l.fcShopBoughtBy('Me')), findsOneWidget);
  });

  testWidgets('dark + 200% text: Family tab renders without overflow', (t) async {
    t.view.physicalSize = const Size(360 * 3, 760 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(const FamilyScreen(), _Fake(), dark: true, lang: 'bn', scale: 2));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    final btn = t.getSize(find.byKey(const ValueKey('fam-empty-primary')));
    expect(btn.height, greaterThanOrEqualTo(48));
  });

  testWidgets('onboarding offers the elderly simple home', (t) async {
    var on = false;
    await t.pumpWidget(_app(
        StatefulBuilder(builder: (ctx, set) => Scaffold(
            body: OnbRoleStep(selected: null, onPick: (_) {}, simpleHome: on,
                onSimpleHome: (v) => set(() => on = v)))),
        _Fake()));
    await t.pumpAndSettle();
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.scrollUntilVisible(find.text(l.onbSimpleHome), 200);
    await t.tap(find.text(l.onbSimpleHome));
    await t.pumpAndSettle();
    expect(on, isTrue);
  });
}
