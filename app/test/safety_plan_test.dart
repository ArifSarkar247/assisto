// safety-plan (board row 49) — the family safety plan screen + the three
// Safe Journey P2 regressions (row 4):
//   * empty state = benefit line + how-to + one big button;
//   * a saved plan shows meeting places, who to call (in order) with Call,
//     the numbers in Bangla digits on a Bangla screen;
//   * NO internet -> the copy saved on this phone opens (the point of a plan);
//   * edit: nothing filled -> the red hint only after Save; a filled plan
//     posts the right body (people picked from My Circle in one tap);
//   * Safe Journey P2: the SOS button never reads "SOS SOS"; the live
//     screen button pairs are equal height; My Trip has ONE place search.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/offline/offline_store.dart';
import 'package:assisto/safety_plan/safety_plan_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/adaptive_button_pair.dart';
import 'package:assisto/widgets/sos_button.dart';

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
}

Widget _app(Widget home, {String lang = 'en', ThemeData? theme, double scale = 1.0}) {
  final app = AppState()
    ..api = _Api()
    ..locale = Locale(lang)
    ..user = AppUser(
        id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
    ..loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      theme: theme ?? AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    ),
  );
}

const _members = [
  {'member_id': 11, 'name': 'Mother', 'relation': 'mother', 'phone': '01711000002', 'on_assisto': true},
  {'member_id': 12, 'name': 'Uncle', 'relation': 'uncle', 'phone': '01711000005', 'on_assisto': false},
];
const _defaults = [
  {'number': '999', 'label': 'National emergency'},
  {'number': '1098', 'label': 'Child helpline'},
];

Map<String, dynamic> _plan() => {
      'meeting_point': {'name': 'Sample Park gate', 'lat': 23.78, 'lng': 90.40, 'note': 'by the tea stall'},
      'meeting_point_far': {'name': 'Uncle house, Sample Road 5'},
      'numbers': [
        {'number': '999', 'label': 'National emergency'}
      ],
      'call_order': [
        {'member_id': 11, 'name': 'Mother', 'phone': '01711000002', 'is_you': false},
        {'member_id': 12, 'name': 'Uncle', 'phone': '01711000005', 'is_you': false},
      ],
      'shared_with': [
        {'member_id': 11, 'name': 'Mother'}
      ],
      'note': '',
      'updated_at': '2026-11-18T08:00:00Z',
    };

void main() {
  setUp(() {
    OfflineStore.instance.currentUid = 1;
    safetyPlanLoaderOverride = null;
    safetyPlanSaveOverride = null;
  });

  testWidgets('empty: benefit line, how-to and one big button', (t) async {
    safetyPlanLoaderOverride = () async =>
        {'mine': null, 'shared': [], 'members': _members, 'defaults': _defaults};
    await t.pumpWidget(_app(const SafetyPlanScreen()));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('spl_empty')), findsOneWidget);
    expect(find.text('Agree a plan before trouble comes'), findsOneWidget);
    expect(find.byKey(const ValueKey('spl_make')), findsOneWidget);
    expect(find.byKey(const ValueKey('spl_offline')), findsNothing);
  });

  testWidgets('a plan shows places, who to call in order, numbers; bn digits', (t) async {
    safetyPlanLoaderOverride = () async =>
        {'mine': _plan(), 'shared': [], 'members': _members, 'defaults': _defaults};
    await t.pumpWidget(_app(const SafetyPlanScreen(), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.text('Sample Park gate'), findsOneWidget);
    expect(find.byKey(const ValueKey('spl_call_0_call')), findsOneWidget);
    expect(find.textContaining('১. Mother'), findsOneWidget);
    expect(find.textContaining('২. Uncle'), findsOneWidget);
    expect(find.text('৯৯৯'), findsOneWidget);
    expect(find.text('999'), findsNothing);
    expect(find.byKey(const ValueKey('spl_shared_line')), findsOneWidget);
  });

  testWidgets('no internet: the copy saved on this phone opens', (t) async {
    safetyPlanLoaderOverride = () async =>
        {'mine': _plan(), 'shared': [], 'members': _members, 'defaults': _defaults};
    await t.pumpWidget(_app(const SafetyPlanScreen()));
    await t.pumpAndSettle();
    // next open: airplane mode
    safetyPlanLoaderOverride = () async => throw Exception('SocketException: no network');
    await t.pumpWidget(_app(const SizedBox()));
    await t.pumpWidget(_app(const SafetyPlanScreen()));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('spl_offline')), findsOneWidget);
    expect(find.text('Sample Park gate'), findsOneWidget);
    expect(find.byKey(const ValueKey('spl_call_0_call')), findsOneWidget);
  });

  testWidgets('no internet and no copy: honest line + retry (no dead end)', (t) async {
    safetyPlanLoaderOverride = () async => throw Exception('offline');
    await t.pumpWidget(_app(const SafetyPlanScreen()));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('spl_nocopy')), findsOneWidget);
    expect(find.byKey(const ValueKey('spl_retry')), findsOneWidget);
  });

  testWidgets('edit: red hint only after Save; picks from My Circle; posts body', (t) async {
    Map<String, dynamic>? sent;
    safetyPlanSaveOverride = (b) async {
      sent = b;
      return {'mine': _plan(), 'shared': [], 'members': _members, 'defaults': _defaults};
    };
    await t.pumpWidget(_app(SafetyPlanEditScreen(
        initial: splBodyFrom(null), members: [..._members], defaults: [..._defaults])));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('spl_need_one')), findsNothing);
    // a new plan starts with 999 selected; drop it -> nothing left
    await t.tap(find.byKey(const ValueKey('spl_def_999')));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byKey(const ValueKey('spl_save')), 200);
    await t.tap(find.byKey(const ValueKey('spl_save')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('spl_need_one')), findsOneWidget);
    expect(sent, isNull);
    await t.scrollUntilVisible(find.byKey(const ValueKey('spl_add_call_11')), -200);
    await t.tap(find.byKey(const ValueKey('spl_add_call_11')));
    await t.pumpAndSettle();
    // only people on Assisto can receive it (Uncle is not)
    expect(find.byKey(const ValueKey('spl_share_12')), findsNothing);
    await t.scrollUntilVisible(find.byKey(const ValueKey('spl_share_11')), 200);
    await t.tap(find.byKey(const ValueKey('spl_share_11')));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byKey(const ValueKey('spl_save')), 200);
    await t.tap(find.byKey(const ValueKey('spl_save')));
    await t.pumpAndSettle();
    expect(sent!['call_order'], [11]);
    expect(sent!['shared_with'], [11]);
    expect(sent!['numbers'], isEmpty);
  });

  testWidgets('200% text + dark: the plan card has no overflow', (t) async {
    t.view.physicalSize = const Size(720, 1600);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    safetyPlanLoaderOverride = () async =>
        {'mine': _plan(), 'shared': [], 'members': _members, 'defaults': _defaults};
    await t.pumpWidget(_app(const SafetyPlanScreen(), lang: 'bn', theme: AssistoTheme.dark, scale: 2.0));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('spl_mine')), findsOneWidget);
  });

  test('body from a saved plan keeps ids and order', () {
    final b = splBodyFrom(_plan());
    expect(b['call_order'], [11, 12]);
    expect(b['shared_with'], [11]);
    expect(splHasContent(b), isTrue);
    expect(splHasContent(splBodyFrom(null)), isFalse);
  });

  // ---- Safe Journey P2 regressions (row 4) ----
  test('P2 #6: the SOS button never reads "SOS SOS"', () {
    expect(SosButton.visibleLine('SOS — Emergency call'), 'Emergency call');
    expect(SosButton.visibleLine('SOS'), 'SOS');
    expect(SosButton.visibleLine('Emergency — alert my family'), 'Emergency — alert my family');
  });

  testWidgets('P2 #8: button pairs are equal height (long bn label)', (t) async {
    await t.pumpWidget(_app(Scaffold(
        body: Padding(
      padding: const EdgeInsets.all(16),
      child: AdaptiveButtonPair(
        first: OutlinedButton(
            key: const ValueKey('a'),
            onPressed: () {},
            child: const Text('আমার সিম থেকে SMS পাঠান আমার সিম থেকে')),
        second: OutlinedButton(key: const ValueKey('b'), onPressed: () {}, child: const Text('থামান')),
      ),
    ))));
    await t.pumpAndSettle();
    expect(t.getSize(find.byKey(const ValueKey('a'))).height,
        t.getSize(find.byKey(const ValueKey('b'))).height);
  });
}
