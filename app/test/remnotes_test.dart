// remnotes (owner Reminders & Notes review 28 Oct):
//  1 notification Done / Snooze: the patches, the pending queue, the buttons
//    in the app's language, every old alarm re-handed once (sig |a1)
//  2 bn/en: weekday names + digits in the app language; "every N" shown;
//    the owner's own phrases parse ("kal sokal 8tay oshudh", "proti
//    shukrobar bazar")
//  3 empty states: benefit + big button + 3-step how-to (bn/en)
//  4 notes: colour, label filter, shared-from, vault attachments, share to
//    My Circle; to-dos repeat; reminders pick a person from My Circle and
//    give a family task; 200% text + dark render clean.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/notifications.dart';
import 'package:assisto/reminders/alarm_plan.dart';
import 'package:assisto/reminders/reminder_actions.dart';
import 'package:assisto/screens/notes_todos_screen.dart';
import 'package:assisto/screens/reminders_quick_add.dart' show pickLink;
import 'package:assisto/screens/reminders_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/rem_notes.dart';
import 'package:assisto/widgets/reminders_nlp.dart';
import 'package:assisto/widgets/rn_bits.dart';

class _Fake extends ApiClient {
  _Fake({this.members = const [], this.docs = const []}) {
    token = 't';
  }
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> docs;
  final List<String> posts = [];
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async {
    if (path.startsWith('family')) return [for (final m in members) Map.of(m)];
    return [];
  }

  @override
  Future<List<Map<String, dynamic>>> listDocuments() async =>
      [for (final d in docs) Map.of(d)];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/family/circle-pick') {
      return {
        'results': [
          {'circle_id': 7, 'name': 'Mom', 'relation': 'mother', 'phone': '01710000000'},
        ]
      };
    }
    if (path == '/family/limits') {
      return {'limit': 5, 'used': members.length, 'left': 5, 'safety_free': true};
    }
    if (path == '/family/reminders') return {'assigned_by_me': [], 'assigned_to_me': []};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    bodies.add(Map.of(body));
    return {'ok': true, 'shared_id': 99, 'attachments_dropped': 0};
  }
}

AppState _state(ApiClient api, String lang,
    {List<Map<String, dynamic>> reminders = const [],
    List<Map<String, dynamic>> notes = const [],
    List<Map<String, dynamic>> todos = const []}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
  s.reminders.items = [for (final r in reminders) _copy(r)];
  s.notes.items = [for (final r in notes) _copy(r)];
  s.todos.items = [for (final r in todos) _copy(r)];
  return s;
}

Map<String, dynamic> _copy(Map<String, dynamic> m) =>
    {...m, 'data': Map<String, dynamic>.from(m['data'] as Map)};

Widget _app(Widget child, AppState s,
    {String lang = 'en', bool dark = false, double scale = 1}) {
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

Map<String, dynamic> _rem(String lid, int? sid, Map<String, dynamic> d) =>
    {'localId': lid, 'serverId': sid, 'pendingOp': 'none', 'data': d};

final _friday = _rem('r1', 6, {
  'title': 'Groceries',
  'due_at': '2030-01-04T02:00:00Z',
  'done': false,
  'recurrence': 'weekly',
  'recurrence_rule': {'freq': 'weekly', 'interval': 1, 'weekday': 4, 'time': '08:00'},
  'priority': 'high',
});

final _notes = [
  _rem('n1', 3, {
    'title': 'Market list', 'body': 'Friday', 'pinned': true, 'color': 'green',
    'tags': ['groceries'],
    'checklist': [
      {'text': 'Rice', 'done': true}, {'text': 'Lentils', 'done': false},
      {'text': 'Oil', 'done': false}, {'text': 'Eggs', 'done': false},
    ],
  }),
  _rem('n2', 7, {
    'title': 'Rent agreement', 'body': 'Renew', 'color': 'blue', 'tags': ['house'],
    'attachments': [{'doc_id': 1, 'title': 'NID'}],
    'shared_from': {'user': 2, 'name': 'Mom'},
  }),
  _rem('n3', null, {'title': 'Plain', 'body': 'no colour'}),
];

final _rentTodo = _rem('t1', 8, {
  'title': 'Pay rent', 'done': false, 'due_at': '2030-01-05T04:00:00Z',
  'recurrence_rule': {'freq': 'monthly', 'interval': 1, 'day_of_month': 5, 'time': '10:00'},
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  // ------------------------------------------------ 1 notification actions
  group('notification Done / Snooze', () {
    test('Done: one-off ends; recurring moves to its next time and stays open', () {
      final now = DateTime(2026, 10, 28, 8, 1);
      expect(ReminderActions.donePatch({'title': 'x', 'due_at': '2026-10-28T02:00:00Z'}, now),
          {'done': true});
      final p = ReminderActions.donePatch({
        'title': 'pill',
        'due_at': DateTime(2026, 10, 28, 8).toUtc().toIso8601String(),
        'recurrence': 'daily',
        'recurrence_rule': {'freq': 'daily', 'interval': 1, 'time': '08:00'},
      }, now);
      expect(p['done'], isFalse);
      expect(DateTime.parse(p['due_at'] as String).toLocal(), DateTime(2026, 10, 29, 8));
    });

    test('Snooze patch = 10 minutes after the tap', () {
      final tap = DateTime(2026, 10, 28, 8, 0);
      expect(DateTime.parse(ReminderActions.snoozePatch(tap)['due_at'] as String).toLocal(),
          DateTime(2026, 10, 28, 8, 10));
    });

    test('pending actions (tapped with the app closed) apply once on next open',
        () async {
      final t0 = DateTime(2026, 10, 28, 8).millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        ReminderActions.pendingKey: '[{"a":"rem_done","k":"rem-1","t":$t0},'
            '{"a":"rem_snooze","k":"rem-2","t":$t0},'
            '{"a":"rem_snooze","k":"rem-3","t":$t0},'
            '{"a":"rem_done","k":"rem-404","t":$t0},'
            '{"bad":true}]',
      });
      final items = [
        _rem('srv-1', 1, {'title': 'bill', 'due_at': '2026-10-28T02:00:00Z'}),
        _rem('srv-2', 2, {'title': 'call', 'due_at': '2026-10-28T02:00:00Z'}),
        _rem('srv-3', 3, {
          'title': 'pill', 'due_at': '2026-10-28T02:00:00Z', 'recurrence': 'daily',
          'recurrence_rule': {'freq': 'daily', 'interval': 1, 'time': '08:00'},
        }),
      ];
      final patched = <String, Map<String, dynamic>>{};
      final n = await ReminderActions.applyTo(items, (it, p) async {
        patched[it['localId'] as String] = p;
      }, now: DateTime(2026, 10, 28, 8, 2));
      expect(n, 3); // done, one-off snooze, recurring snooze (stand-in only)
      expect(patched['srv-1'], {'done': true});
      expect(DateTime.parse(patched['srv-2']!['due_at'] as String).toLocal(),
          DateTime(2026, 10, 28, 8, 10));
      expect(patched.containsKey('srv-3'), isFalse,
          reason: 'a recurring reminder keeps its schedule; the stand-in rings');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ReminderActions.pendingKey), isNull);
      expect(await ReminderActions.applyTo(items, (a, b) async {}), 0);
    });

    test('buttons are on reminder alarms only, in the app language', () async {
      Notifications.actionLang = 'bn';
      final bn = await AppLocalizations.delegate.load(const Locale('bn'));
      final d = Notifications.detailsFor('remalarm:rem-1').android!;
      expect(d.actions!.map((a) => a.id), [ReminderActions.done, ReminderActions.snooze]);
      expect(d.actions!.map((a) => a.title), [bn.rnNotifDone, bn.rnNotifSnooze10]);
      expect(d.actions!.every((a) => a.showsUserInterface == false), isTrue);
      Notifications.actionLang = 'en';
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      expect(Notifications.detailsFor('remalarm:x').android!.actions!.first.title,
          en.rnNotifDone);
      expect(Notifications.detailsFor(null).android!.actions, isNull);
      expect(Notifications.detailsFor('{"kind":"x"}').android!.actions, isNull);
      expect(Notifications.actionDone, ReminderActions.done);
      expect(Notifications.actionSnooze, ReminderActions.snooze);
    });

    test('every existing alarm is re-handed once (now carries the buttons)', () {
      final p = AlarmPlan(key: 'rem-1', at: DateTime(2030), title: 't', body: '');
      expect(p.sig(AlarmMode.exact), endsWith('|a1'));
      expect(ReminderActions.keyOf('remalarm:rem-9'), 'rem-9');
      expect(ReminderActions.keyOf('{"kind":"reminder"}'), '');
      expect(ReminderActions.snoozeIdFor('rem-9'), isNot(alarmIdFor('rem-9')));
    });
  });

  // ------------------------------------------------ 2 language
  group('bn/en', () {
    setUpAll(() async {
      await initializeDateFormatting('bn');
      await initializeDateFormatting('en');
    });

    test('weekday names and digits follow the app language', () async {
      final bn = await AppLocalizations.delegate.load(const Locale('bn'));
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      const fri = RecurrenceRule(freq: 'weekly', weekday: 4);
      final b = recurrenceLabel(bn, fri);
      expect(b, isNot(contains('Friday')));
      expect(RegExp(r'[A-Za-z]').hasMatch(b), isFalse, reason: b);
      expect(recurrenceLabel(en, fri), contains('Friday'));
      // "every 2 weeks" used to read as plain "weekly"
      final two = recurrenceLabel(bn, const RecurrenceRule(freq: 'weekly', interval: 2, weekday: 4));
      expect(two, contains('২')); // Bangla 2
      expect(recurrenceLabel(en, const RecurrenceRule(freq: 'daily', interval: 3)),
          contains('3'));
      expect(recurrenceLabel(bn, const RecurrenceRule(freq: 'monthly', dayOfMonth: 15)),
          contains('১৫'));
      expect(rnDigits(bn, '3/12'), '৩/১২');
      expect(rnDigits(en, '3/12'), '3/12');
    });

    test("the owner's phrases parse, with a preview before saving", () {
      final now = DateTime(2026, 10, 28, 20, 0); // a Wednesday evening
      final a = parseReminder('কাল সকাল ৮টায় ওষুধ', now: now);
      expect(a.dateTime, DateTime(2026, 10, 29, 8));
      expect(a.dateOnly, isFalse);
      expect(a.cleanTitle, contains('ওষুধ'));
      final b = parseReminder('প্রতি শুক্রবার বাজার', now: now);
      expect(b.recurrence?.freq, 'weekly');
      expect(b.recurrence?.weekday, 4); // Friday
      expect(b.dateTime?.weekday, DateTime.friday);
      expect(b.cleanTitle, contains('বাজার'));
    });
  });

  // ------------------------------------------------ to-do repeat (pure)
  test('repeating to-do: rule shape + next date after a tick', () {
    final due = DateTime(2026, 11, 5, 10);
    final rule = todoRule('monthly', due);
    expect(rule['freq'], 'monthly');
    expect(rule['day_of_month'], 5);
    expect(rule['time'], '10:00');
    expect(todoRule('none', due), isEmpty);
    expect(todoRule('weekly', null), isEmpty);
    final d = {'due_at': due.toUtc().toIso8601String(), 'recurrence_rule': rule};
    expect(todoNextDue(d, now: DateTime(2026, 11, 5, 11)), DateTime(2026, 12, 5, 10));
    // ticked early (before the due date): still the NEXT month, not the same day
    expect(todoNextDue(d, now: DateTime(2026, 11, 1)), DateTime(2026, 12, 5, 10));
    expect(todoNextDue({'due_at': null, 'recurrence_rule': rule}), isNull);
    expect(todoNextDue({'due_at': '2026-11-05T04:00:00Z', 'recurrence_rule': {}}), isNull);
  });

  test('note as text keeps the checklist ticks', () {
    final s = noteAsText(_notes.first['data'] as Map<String, dynamic>);
    expect(s.split('\n').first, 'Market list');
    expect(s, contains('☑ Rice'));
    expect(s, contains('☐ Oil'));
  });

  // ------------------------------------------------ 3 empty states
  for (final lang in ['en', 'bn']) {
    testWidgets('Reminders empty: benefit + big button + how-to ($lang)', (t) async {
      final l = await AppLocalizations.delegate.load(Locale(lang));
      await t.pumpWidget(_app(const RemindersScreen(), _state(_Fake(), lang), lang: lang));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rn-rem-empty')), findsOneWidget);
      expect(find.text(l.rnRemBenefit), findsOneWidget);
      expect(find.text(l.rnRemStep1), findsOneWidget);
      expect(find.text(l.rnRemStep3), findsOneWidget);
      final btn = find.byKey(const ValueKey('fam-empty-primary'));
      expect(t.getSize(btn).height, greaterThanOrEqualTo(48));
      await t.tap(btn);
      await t.pumpAndSettle();
      expect(find.text(l.remNewReminder), findsOneWidget);
    });

    testWidgets('Notes + To-do empty: benefit + big button ($lang)', (t) async {
      final l = await AppLocalizations.delegate.load(Locale(lang));
      await t.pumpWidget(_app(const NotesTodosScreen(), _state(_Fake(), lang), lang: lang));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rn-notes-empty')), findsOneWidget);
      expect(find.text(l.rnNotesBenefit), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing,
          reason: 'one primary action, not two');
      await t.tap(find.text(l.notesTabTodos));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rn-todos-empty')), findsOneWidget);
      expect(find.text(l.rnTodosBenefit), findsOneWidget);
    });
  }

  // ------------------------------------------------ 4 filled screens
  testWidgets('Reminders (bn): Friday in Bangla, no English weekday', (t) async {
    await t.pumpWidget(_app(const RemindersScreen(),
        _state(_Fake(), 'bn', reminders: [_friday]), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.textContaining('Friday'), findsNothing);
    expect(find.textContaining('শুক্রবার'), findsWidgets);
  });

  testWidgets('Notes: colour fill, shared-from, label filter, Bangla progress', (t) async {
    t.view.physicalSize = const Size(1080, 3000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    final l = await AppLocalizations.delegate.load(const Locale('bn'));
    await t.pumpWidget(_app(const NotesTodosScreen(),
        _state(_Fake(), 'bn', notes: _notes), lang: 'bn'));
    await t.pumpAndSettle();
    final ctx = t.element(find.byType(NotesTodosScreen));
    final cards = t.widgetList<Card>(find.byType(Card)).toList();
    expect(cards.where((c) => c.color == noteFill(ctx, 'green')).length, 1);
    expect(cards.where((c) => c.color == noteFill(ctx, 'blue')).length, 1);
    expect(find.text(l.rnSharedFrom('Mom')), findsOneWidget);
    expect(find.text('১/৪'), findsOneWidget); // 1/4 in Bangla digits
    expect(find.byKey(const ValueKey('rn-label-row')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('rn-label-house')));
    await t.pumpAndSettle();
    expect(find.text('Rent agreement'), findsOneWidget);
    expect(find.text('Market list'), findsNothing);
    await t.tap(find.text(l.rnAllLabels));
    await t.pumpAndSettle();
    expect(find.text('Market list'), findsOneWidget);
  });

  testWidgets('To-do: a repeating task shows its repeat', (t) async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(const NotesTodosScreen(initialIndex: 1),
        _state(_Fake(), 'en', todos: [_rentTodo]), lang: 'en'));
    await t.pumpAndSettle();
    expect(find.text('Pay rent'), findsOneWidget);
    expect(find.text(l.remRecurMonthly), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('200% text, dark=$dark: reminders + notes render clean', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.6;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(const RemindersScreen(),
          _state(_Fake(), 'bn', reminders: [_friday]),
          lang: 'bn', dark: dark, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(_app(const NotesTodosScreen(),
          _state(_Fake(), 'bn', notes: _notes), lang: 'bn', dark: dark, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(_app(const NotesTodosScreen(),
          _state(_Fake(), 'en'), lang: 'en', dark: dark, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('TalkBack: colour swatches are labelled buttons', (t) async {
    final h = t.ensureSemantics();
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    await t.pumpWidget(_app(
        Scaffold(body: NoteColorPicker(value: 'green', onChanged: (_) {})),
        _state(_Fake(), 'en')));
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel(l.rnColorGreen), findsOneWidget);
    expect(find.bySemanticsLabel(l.rnColorNone), findsOneWidget);
    h.dispose();
  });

  // ------------------------------------------------ My Circle, family, vault
  testWidgets('link a person from My Circle in one tap (no typing)', (t) async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    Map<String, dynamic>? got;
    await t.pumpWidget(_app(Builder(
        builder: (c) => Scaffold(
            body: Center(
                child: TextButton(
                    onPressed: () async => got = await pickLink(c),
                    child: const Text('open'))))), _state(_Fake(), 'en')));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('rn-link-circle')));
    await t.pumpAndSettle();
    expect(find.text(l.rnFromCircle), findsWidgets);
    await t.tap(find.byKey(const ValueKey('rn-circle-7')));
    await t.pumpAndSettle();
    expect(got, {'type': 'person', 'id': 7, 'label': 'Mom', 'source': 'circle'});
  });

  testWidgets('give a family task from Reminders (famcare form)', (t) async {
    final api = _Fake(members: [
      {'id': 1, 'name': 'Mom', 'relation': 'mother', 'circle_member': 7, 'in_circle': true},
    ]);
    await t.pumpWidget(_app(const RemindersScreen(),
        _state(api, 'en', reminders: [_friday]), lang: 'en'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('rn-give-family')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('fc-task-save')), findsOneWidget);
  });

  testWidgets('share a note to My Circle: a copy is sent, sender told', (t) async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake();
    final s = _state(api, 'en', notes: _notes);
    await t.pumpWidget(_app(Builder(
        builder: (c) => Scaffold(
            body: Column(children: [
              TextButton(
                  onPressed: () => shareNote(c, s.notes.items.firstWhere((n) => n['localId'] == 'n1')),
                  child: const Text('synced')),
              TextButton(
                  onPressed: () => shareNote(c, s.notes.items.firstWhere((n) => n['localId'] == 'n3')),
                  child: const Text('unsynced')),
            ]))), s));
    await t.tap(find.text('synced'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('rn-share-circle')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('rn-circle-7')));
    await t.pumpAndSettle();
    expect(api.posts, ['/notes/3/share/']);
    expect(api.bodies.single, {'circle_id': 7});
    expect(find.text(l.rnShareSent('Mom')), findsOneWidget);
    // not on the server yet -> honest message, nothing sent
    await t.tap(find.text('unsynced'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('rn-share-circle')));
    await t.pumpAndSettle();
    expect(api.posts.length, 1);
    expect(find.text(l.rnShareNeedsSync), findsOneWidget);
  });

  testWidgets('note editor: colour + attach a vault paper', (t) async {
    t.view.physicalSize = const Size(1080, 3000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final api = _Fake(docs: [
      {'id': 11, 'title': 'Passport'},
      {'id': 12, 'title': 'NID'},
    ]);
    await t.pumpWidget(_app(Builder(
        builder: (c) => Scaffold(
            body: Center(
                child: TextButton(
                    onPressed: () => editNote(c), child: const Text('new'))))),
        _state(api, 'en')));
    await t.tap(find.text('new'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('rn-color-green')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('rn-color-green')));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const ValueKey('rn-attach')));
    await t.tap(find.byKey(const ValueKey('rn-attach')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('rn-vault-11')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('rn-vault-attach')));
    await t.pumpAndSettle();
    expect(find.text('Passport'), findsOneWidget);
    expect(find.text(l.rnAttach), findsOneWidget); // can add more (limit 10)
  });

  testWidgets('vault empty -> honest line + Open Vault, never a dead end', (t) async {
    final l = await AppLocalizations.delegate.load(const Locale('bn'));
    await t.pumpWidget(_app(Builder(
        builder: (c) => Scaffold(
            body: Center(
                child: TextButton(
                    onPressed: () => pickVaultDocs(c), child: const Text('pick'))))),
        _state(_Fake(), 'bn'), lang: 'bn'));
    await t.tap(find.text('pick'));
    await t.pumpAndSettle();
    expect(find.text(l.rnAttachEmpty), findsOneWidget);
    expect(find.text(l.rnAttachOpen), findsOneWidget);
  });
}
