// p2plan (owner PART 2, 3 Nov): Task manager model (subtasks, repeat mirror
// of task_manager.py, shared-list detection), AI daily planner screen (plan /
// honest empty day / AI advice, bn digits, 200% font at 360 dp, dark).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/day_planner_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/task_manager_model.dart';

import 'fake_api.dart';

class _Api extends FakeApi {
  _Api({FakeMode mode = FakeMode.data, String lang = 'en'}) : super(mode: mode, lang: lang);
  final posts = <String>[];

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) {
    posts.add(path);
    return super.postJson(path, body);
  }
}

AppState _stub(ApiClient api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'Arif', phone: '01700000000', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(AppState s, Widget home, {String lang = 'en', double scale = 1, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: s,
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
        darkTheme: AssistoTheme.dark,
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (ctx, w) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _hasAsciiDigit(String s) => RegExp(r'[0-9]').hasMatch(s);

void main() {
  group('task model (mirror of task_manager.py)', () {
    test('nextDue daily / weekly / monthly clamps to month end', () {
      expect(nextDue('2026-11-03T09:00', 'daily'), '2026-11-04T09:00');
      expect(nextDue('2026-11-03T09:00', 'weekly'), '2026-11-10T09:00');
      expect(nextDue('2026-01-31T08:30', 'monthly'), '2026-02-28T08:30');
      expect(nextDue('2026-12-15T08:00', 'monthly'), '2027-01-15T08:00');
      expect(nextDue('2026-11-03T09:00', ''), '');
      expect(nextDue('', 'daily'), '');
    });

    test('spawnNext rolls past now, keeps the rest, never for steps', () {
      final t = TaskItem(id: 4, title: 'Bazar', repeat: 'daily', due: '2026-10-30T08:00',
          status: kStatusDone, progress: 100, priority: kPriorityUrgent, estMin: 30);
      final n = spawnNext(t, DateTime(2026, 11, 3, 9))!;
      expect(n.due, '2026-11-04T08:00');
      expect(n.id, isNull);
      expect(n.status, kStatusTodo);
      expect(n.progress, 0);
      expect(n.priority, kPriorityUrgent);
      expect(n.estMin, 30);
      expect(spawnNext(TaskItem(title: 'x', due: '2026-11-03T08:00'), DateTime(2026, 11, 3)), isNull);
      expect(
          spawnNext(TaskItem(title: 'x', repeat: 'daily', due: '2026-11-03T08:00', parentId: 3),
              DateTime(2026, 11, 3)),
          isNull);
    });

    test('steps: top level, count, round-trip', () {
      final tasks = [
        TaskItem(id: 1, title: 'Paint'),
        TaskItem(id: 2, title: 'a', parentId: 1, status: kStatusDone),
        TaskItem(id: 3, title: 'b', parentId: 1),
      ];
      expect(topLevel(tasks).map((t) => t.id), [1]);
      expect(stepCount(tasks, 1), (1, 2));
      expect(stepCount(tasks, 9), (0, 0));
      final j = TaskItem.fromJson({'id': 2, 'title': 'a', 'parent_id': '1', 'repeat': 'yearly',
        'est_min': 9999, 'assignee_uid': 'x'});
      expect(j.parentId, 1);
      expect(j.repeat, '');
      expect(j.estMin, kMaxEstMin);
      expect(j.assigneeUid, isNull);
      expect(TaskItem(title: 'x', repeat: 'weekly', estMin: 45).toJson()['est_min'], 45);
    });

    test('shared list detection', () {
      expect(Project.fromJson({'id': 1, 'name': 'Mine'}).isShared, isFalse);
      final owned = Project.fromJson({'id': 1, 'name': 'Mine', 'shared_with': [
        {'uid': 8, 'name': 'Karim'}
      ]});
      expect(owned.isShared, isTrue);
      expect(owned.sharedCount, 1);
      expect(owned.role, 'owner');
      final theirs = Project.fromJson({'id': 2, 'name': 'Theirs', 'role': 'member',
        'owner': {'uid': 7, 'name': 'Rina'}, 'people': []});
      expect(theirs.isShared, isTrue);
      expect(theirs.ownerName, 'Rina');
    });
  });

  group('AI daily planner screen', () {
    testWidgets('plan: blocks, bills, tips; tasks tappable; English', (tester) async {
      final api = _Api();
      await tester.pumpWidget(_app(_stub(api, 'en'), const DayPlannerScreen()));
      await _settle(tester);
      expect(find.text('Pay the power bill'), findsOneWidget);
      expect(find.text('Bank meeting'), findsOneWidget);
      expect(find.text('Dhuhr'), findsOneWidget);
      expect(find.text('Does not fit today'), findsOneWidget);
      expect(find.text('To pay today'), findsOneWidget);
      expect(find.textContaining('2 credits'), findsOneWidget);
    });

    testWidgets('Bangla: no English digits anywhere, Bangla prayer name', (tester) async {
      final api = _Api(lang: 'bn');
      await tester.pumpWidget(_app(_stub(api, 'bn'), const DayPlannerScreen(), lang: 'bn'));
      await _settle(tester);
      expect(find.text('যোহর'), findsOneWidget);
      final texts = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').toList();
      final bad = texts.where(_hasAsciiDigit).toList();
      expect(bad, isEmpty, reason: 'ASCII digits on a Bangla screen: $bad');
    });

    testWidgets('AI advice is shown on top of the plan (blocks stay)', (tester) async {
      final api = _Api();
      await tester.pumpWidget(_app(_stub(api, 'en'), const DayPlannerScreen()));
      await _settle(tester);
      await tester.tap(find.textContaining('Polish with AI'));
      await _settle(tester);
      expect(api.posts, contains('/planner/today/polish'));
      expect(find.text('Pay the urgent bill first.'), findsOneWidget);
      expect(find.text('Pay the power bill'), findsOneWidget);
    });

    testWidgets('empty day: benefit + big button + how-to (no dead end)', (tester) async {
      final api = _Api(mode: FakeMode.empty);
      await tester.pumpWidget(_app(_stub(api, 'en'), const DayPlannerScreen()));
      await _settle(tester);
      expect(find.text('Plan your day in one tap'), findsOneWidget);
      expect(find.text('Add your first task'), findsOneWidget);
      expect(find.textContaining('How:'), findsOneWidget);
    });

    testWidgets('load failure: honest message + retry', (tester) async {
      final api = _Api(mode: FakeMode.fail);
      await tester.pumpWidget(_app(_stub(api, 'en'), const DayPlannerScreen()));
      await _settle(tester);
      expect(find.text('Could not load the plan'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    for (final lang in ['bn', 'en']) {
      testWidgets('200% font at 360 dp, dark ($lang): no overflow', (tester) async {
        tester.view.physicalSize = const Size(360 * 3, 800 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final api = _Api(lang: lang);
        await tester.pumpWidget(
            _app(_stub(api, lang), const DayPlannerScreen(), lang: lang, scale: 2, dark: true));
        await _settle(tester);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
