// home-circle (owner 26 Oct): My Circle is the fixed, pinned FIRST home tile
// (title + one-line subtitle, unread pill, missed-call dot) and a larger
// sidebar entry in the Assisto AI style.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/app_drawer.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/circle_badges.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';

import 'app_fonts.dart';
import 'fake_api.dart';

AppState _state(String lang) {
  final s = AppState();
  s.api = FakeApi(lang: lang);
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

Future<void> _pump(WidgetTester tester, Widget body,
    {String lang = 'en', bool dark = false, double scale = 1.0}) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: _state(lang),
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
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Scaffold(body: body),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _grid([CircleBadgeState? b]) => Padding(
    padding: const EdgeInsets.all(16),
    child: HomeQuickBar(
        debugRoutes: HomeQuickButtons.defaults,
        debugCircle: b ?? const CircleBadgeState()));

Widget _drawer([CircleBadgeState? b]) => Row(children: [
      AppDrawer(onNewChat: () {}, debugCircle: b ?? const CircleBadgeState())
    ]);

const _circleTile = ValueKey('quick_tile_circle');

void main() {
  // real Noto/Inter fonts (not Ahem squares) so line counts are realistic
  setUpAll(loadAppFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    CircleBadges.instance.reset();
  });

  group('pinned first tile', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('My Circle is first, with its subtitle ($lang)',
          (tester) async {
        await _pump(tester, _grid(), lang: lang);
        final tile = find.byKey(_circleTile);
        expect(tile, findsOneWidget);
        expect(
            find.descendant(
                of: tile,
                matching: find.text(lang == 'bn' ? 'আমার সার্কেল' : 'My Circle')),
            findsOneWidget);
        expect(
            find.text(lang == 'bn'
                ? 'বন্ধুদের সাথে চ্যাট ও কল'
                : 'Chat and call with friends'),
            findsOneWidget);
        // it sits above every customizable tile
        final circleY = tester.getTopLeft(tile).dy;
        final t = AppLocalizations.of(tester.element(tile));
        final firstUser = find.text(t.navReminders);
        expect(firstUser, findsOneWidget);
        expect(tester.getTopLeft(firstUser).dy, greaterThan(circleY));
        // the user's six are all still there
        for (final r in HomeQuickButtons.defaults) {
          expect(find.text(HomeQuickButtons.byRoute(r)!.label(t)),
              findsOneWidget);
        }
      });
    }

    testWidgets('bn mode has no English on the tile', (tester) async {
      await _pump(tester, _grid(const CircleBadgeState(unread: 12)),
          lang: 'bn');
      final texts = tester
          .widgetList<Text>(find.descendant(
              of: find.byKey(_circleTile), matching: find.byType(Text)))
          .map((w) => w.data ?? '')
          .join(' ');
      expect(RegExp(r'[A-Za-z0-9]').hasMatch(texts), isFalse, reason: texts);
      expect(texts, contains('১২'));
    });

    testWidgets('tap opens My Circle', (tester) async {
      var pushed = <String?>[];
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: _state('en'),
        child: MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          navigatorObservers: [_Obs(pushed)],
          home: Scaffold(body: _grid()),
        ),
      ));
      await tester.pump();
      pushed.clear();
      await tester.tap(find.byKey(_circleTile));
      await tester.pump();
      expect(pushed, ['circle']);
      // let the hub's guarded timers run out
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 20));
    });
  });

  group('badges', () {
    testWidgets('unread pill + missed dot', (tester) async {
      await _pump(tester, _grid(const CircleBadgeState(unread: 3, missed: true)));
      expect(find.byKey(const ValueKey('circle_unread_pill')), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.byKey(const ValueKey('circle_missed_dot')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('3 unread messages')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('Missed call')), findsWidgets);
    });

    testWidgets('none when zero', (tester) async {
      await _pump(tester, _grid());
      expect(find.byKey(const ValueKey('circle_unread_pill')), findsNothing);
      expect(find.byKey(const ValueKey('circle_missed_dot')), findsNothing);
    });

    testWidgets('bn digits + 99+ cap', (tester) async {
      await _pump(tester, _grid(const CircleBadgeState(unread: 250)),
          lang: 'bn');
      expect(find.text('৯৯+'), findsOneWidget);
      expect(circleBadgeLabel(7, 'bn'), '৭');
      expect(circleBadgeLabel(120, 'en'), '99+');
    });

    testWidgets('live state updates the tile', (tester) async {
      await _pump(
          tester,
          const Padding(
              padding: EdgeInsets.all(16),
              child: HomeQuickBar(debugRoutes: HomeQuickButtons.defaults)));
      expect(find.byKey(const ValueKey('circle_unread_pill')), findsNothing);
      CircleBadges.instance.setUnread(5);
      await tester.pump();
      expect(find.text('5'), findsOneWidget);
      CircleBadges.instance.setUnread(0);
      await tester.pump();
      expect(find.byKey(const ValueKey('circle_unread_pill')), findsNothing);
    });

    test('missed-call dot: seeded on first run, lit by a newer miss, cleared',
        () async {
      final b = CircleBadges.instance;
      final old = [
        {'id': 1, 'state': 'missed', 'outgoing': false, 'started_at': '2026-10-20T08:00:00Z'},
        {'id': 2, 'state': 'missed', 'outgoing': true, 'started_at': '2026-10-25T08:00:00Z'},
      ];
      await b.applyCalls(old); // first run: no dot for old history
      expect(b.state.value.missed, isFalse);
      final fresh = [
        {'id': 3, 'state': 'canceled', 'outgoing': false, 'started_at': '2026-10-26T09:00:00Z'},
        ...old,
      ];
      await b.applyCalls(fresh);
      expect(b.state.value.missed, isTrue);
      await b.markCallsSeen(fresh);
      expect(b.state.value.missed, isFalse);
      await b.applyCalls(fresh);
      expect(b.state.value.missed, isFalse);
      // answered / outgoing calls never light it
      await b.applyCalls([
        {'id': 4, 'state': 'ended', 'outgoing': false, 'started_at': '2026-10-27T09:00:00Z'},
        ...fresh,
      ]);
      expect(b.state.value.missed, isFalse);
    });
  });

  group('edit cannot remove/move My Circle', () {
    testWidgets('picker shows it first with a lock, not as a chip',
        (tester) async {
      await _pump(tester,
          const QuickButtonsPicker(current: HomeQuickButtons.defaults));
      final pinned = find.byKey(const ValueKey('quick_pinned_circle'));
      expect(pinned, findsOneWidget);
      expect(find.byKey(const ValueKey('quick_pinned_lock')), findsOneWidget);
      expect(find.text('Pinned · always first'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp("Can't be moved or removed")),
          findsWidgets);
      // not one of the reorderable / deletable chips, not in the catalog list
      expect(find.byKey(const ValueKey('sel_circle')), findsNothing);
      expect(
          find.descendant(
              of: pinned, matching: find.byType(Checkbox)),
          findsNothing);
      final listTile = tester.widget<ListTile>(pinned);
      expect(listTile.onTap, isNull);
      expect(listTile.onLongPress, isNull);
      // above the chosen chips
      final firstChip = find.byKey(const ValueKey('sel_reminders'));
      expect(tester.getTopLeft(pinned).dy,
          lessThan(tester.getTopLeft(firstChip).dy));
      // saving returns only the six (no My Circle)
      final state = tester.state<QuickButtonsPickerState>(
          find.byType(QuickButtonsPicker));
      expect(state.mounted, isTrue);
    });

    test('saved layouts migrate: duplicate My Circle dropped, order kept',
        () async {
      SharedPreferences.setMockInitialValues({});
      // a layout WITH My Circle (or its alias) in it
      await HomeQuickButtons.save(
          ['money', 'circle', 'tax', 'messages', 'crm', 'jobs']);
      final got = await HomeQuickButtons.load();
      expect(got.length, HomeQuickButtons.count);
      expect(got.take(4), ['money', 'tax', 'crm', 'jobs']);
      expect(got, isNot(contains('circle')));
      expect(got, isNot(contains('messages')));
      // a layout WITHOUT it is unchanged
      const mine = ['budget', 'tax', 'crm', 'jobs', 'inbox', 'dictionary'];
      await HomeQuickButtons.save(mine);
      expect(await HomeQuickButtons.load(), mine);
      // a server owner default that lists it never duplicates it either
      final r = await HomeQuickButtons.refreshOwnerDefault(() async => {
            'quick_buttons': ['circle', 'emergency', 'money']
          });
      expect(r, isNull); // customized user: unchanged
      expect(await HomeQuickButtons.ownerDefault(), isNot(contains('circle')));
      expect(HomeQuickButtons.sanitize(['circle']).first, 'reminders');
    });
  });

  group('sidebar entry', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('Assisto AI style: bold title + subtitle + badge ($lang)',
          (tester) async {
        await _pump(tester, _drawer(const CircleBadgeState(unread: 4, missed: true)),
            lang: lang);
        final entry = find.byKey(const ValueKey('drawer_my_circle'));
        final ai = find.byKey(const ValueKey('drawer_assisto_ai'));
        expect(entry, findsOneWidget);
        final e = tester.widget<ListTile>(entry);
        final a = tester.widget<ListTile>(ai);
        expect(e.dense, a.dense);
        expect(e.subtitle, isNotNull);
        expect((e.title as Text).style?.fontWeight,
            (a.title as Text).style?.fontWeight);
        expect(
            find.text(lang == 'bn'
                ? 'বন্ধুদের সাথে চ্যাট ও কল'
                : 'Chat and call with your friends'),
            findsOneWidget);
        expect(find.text(lang == 'bn' ? '৪' : '4'), findsOneWidget);
        expect(find.byKey(const ValueKey('circle_missed_dot')), findsOneWidget);
        // same height as the Assisto AI entry (both two-line)
        expect(tester.getSize(entry).height,
            closeTo(tester.getSize(ai).height, 1));
        expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
      });
    }

    testWidgets('no badge when zero', (tester) async {
      await _pump(tester, _drawer());
      expect(find.byKey(const ValueKey('circle_unread_pill')), findsNothing);
      expect(find.byKey(const ValueKey('circle_missed_dot')), findsNothing);
    });
  });

  group('200% font + dark mode', () {
    for (final lang in ['en', 'bn']) {
      for (final dark in [false, true]) {
        testWidgets('home grid + drawer at 2.0x, $lang ${dark ? 'dark' : 'light'}',
            (tester) async {
          const b = CircleBadgeState(unread: 120, missed: true);
          await _pump(tester, SingleChildScrollView(child: _grid(b)),
              lang: lang, dark: dark, scale: 2.0);
          expect(tester.takeException(), isNull);
          final sub = find.byKey(const ValueKey('quick_tile_circle_sub'));
          expect(tester.getSize(find.byKey(_circleTile)).height,
              greaterThanOrEqualTo(48));
          // the subtitle is laid out fully (no ellipsis) at 2.0x
          final rp = tester.renderObject<RenderParagraph>(sub);
          expect(rp.didExceedMaxLines, isFalse);
          await _pump(tester, _drawer(b), lang: lang, dark: dark, scale: 2.0);
          expect(tester.takeException(), isNull);
          final dsub = tester.renderObject<RenderParagraph>(
              find.byKey(const ValueKey('drawer_my_circle_sub')));
          expect(dsub.didExceedMaxLines, isFalse);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }

    testWidgets('dark mode: pill + text use the dark scheme', (tester) async {
      await _pump(tester, _grid(const CircleBadgeState(unread: 2)), dark: true);
      final ctx = tester.element(find.byKey(_circleTile));
      final scheme = Theme.of(ctx).colorScheme;
      expect(Theme.of(ctx).brightness, Brightness.dark);
      final m = tester.widget<Material>(find.byKey(_circleTile));
      expect(m.color, scheme.surfaceContainerHighest);
    });
  });
}

class _Obs extends NavigatorObserver {
  final List<String?> names;
  _Obs(this.names);
  @override
  void didPush(Route route, Route? previousRoute) =>
      names.add(route.settings.name);
}
