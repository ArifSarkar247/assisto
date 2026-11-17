// gap-familycare (Family Care gap lane, 17 Nov) — one test per fixed gap
// (owner_actions/gaps/familycare_BN.md):
//  1 elder "Talk to Assisto": the answer is SHOWN big and READ OUT (before:
//    dropped as "could not"); offline = an honest line; markdown stripped;
//    the spoken part ends at a full sentence
//  2 member card "Location": the person is picked already; not in My Circle =
//    a plain note
//  3/4 a failed refresh shows "what you see is from HH:MM" (never fresh-looking)
//  5 tasks: undo a mistaken "done"; delete (confirm first)
//  6 Important papers opens the papers pane; Today's bazar row the bazar pane
//  7 family ledger money in Bangla digits
//  8 a paused member: "paused sharing", not "no news"
// 13 Add member with an empty My Circle: a big "Add to My Circle", no dead end
// 14 Probashi page on a phone in Bangladesh: THEIR clock, not "my time" twice
// 11 shared family ledger + named goals (family=<id> on every call)
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/eldercare/elder_common.dart';
import 'package:assisto/eldercare/elder_easy_home.dart';
import 'package:assisto/eldercare/silent_watch_client.dart';
import 'package:assisto/famacct_api.dart';
import 'package:assisto/family_v3/family_v3_screen.dart';
import 'package:assisto/family_v3/fc_add_member.dart';
import 'package:assisto/family_v3/fc_slots.dart';
import 'package:assisto/family_v3/fc_slots_register.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/guardian_request_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/fam_probashi_section.dart';
import 'package:assisto/widgets/famacct_section.dart';
import 'package:assisto/widgets/money_digits.dart';

import 'fake_api.dart';
import 'fake_fcscreen.dart';
import 'fcelder_fakes.dart';

class _Api extends ApiClient {
  _Api({this.scene = 'mixed'});
  String scene;
  final List<String> posts = [];
  bool failBoard = false;
  void Function(Map<String, dynamic> board)? edit;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final p = path.startsWith('/') ? path.substring(1) : path;
    if (p == 'family/v3/families') return fcFakeFamilies(scene: scene);
    if (p.endsWith('/board')) {
      if (failBoard) throw Exception('offline');
      final b = fcFakeBoard(scene: scene);
      edit?.call(b);
      return b;
    }
    if (p.startsWith('family/v3/members/')) return fcFakeMemberPage(4);
    if (p == 'family/circle-pick') return {'results': []};
    gets.add(p);
    if (p.startsWith('family/accounting/summary')) return _ledger;
    if (p.startsWith('family/accounting/expenses')) return {'expenses': []};
    return {};
  }

  static final Map<String, dynamic> _ledger = {
    'total_poisha': 125000, 'members': [
      {'member': 'self', 'name': 'Rina', 'net_poisha': 0},
      {'member': 'u3', 'name': 'Rafi', 'net_poisha': 0},
    ],
    'settlements': [], 'family': {'id': 10, 'name': 'My family'}, 'pool': {},
    'goals': [
      {'id': 5, 'name': 'Eid fund', 'target_poisha': 1000000, 'collected_poisha': 300001,
       'remaining_poisha': 699999, 'pct': 30, 'state': 'open', 'closed': false, 'can_close': true,
       'breakdown': [{'member': 'u3', 'name': 'Rafi', 'amount_poisha': 300001}]},
    ],
  };

  final List<Map<String, dynamic>> bodies = [];
  final List<String> gets = [];

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    bodies.add(body);
    return {'ok': true, 'text': ''};
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => [];
}

Widget _app(Widget child, ApiClient api, {String lang = 'en', double scale = 1}) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 2, name: 'Rahima Begum', phone: '01711000002', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
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

Future<void> _pump(WidgetTester t, Widget w, ApiClient api, {String lang = 'en', double scale = 1}) async {
  t.view.physicalSize = const Size(1080, 4800);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(w, api, lang: lang, scale: scale));
  await t.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester t, Finder f) async {
  // the Family list (not the horizontal family switcher inside it)
  final list = find.descendant(
      of: find.byKey(const ValueKey('fc3-list')), matching: find.byType(Scrollable));
  await t.scrollUntilVisible(f, 300,
      scrollable: list.evaluate().isNotEmpty ? list.first : find.byType(Scrollable).first);
  await t.pumpAndSettle();
}

void main() {
  late SpokenRecorder voice;
  setUp(() {
    SharedPreferences.setMockInitialValues({SilentWatchClient.kEnabled: true});
    fcRegisterSlots();
    FcSlots.openSosSender = null;
    FcSlots.askParser = null;
    FcSlots.nightNewsCard = null;
    FcSlots.moreRows = null;
    FcSlots.serverAsk = null;
    FcSlots.journeyTile = null;
    FcSlots.privacyScreen = null;
    voice = SpokenRecorder();
    ElderHooks.voice = voice;
    ElderHooks.apiOverride = FakeSilentWatchApi();
    SilentWatchClient.native = FakeSwNative();
    ElderHooks.listenOverride = null;
    ElderHooks.agentOverride = null;
  });
  tearDown(() {
    ElderHooks.listenOverride = null;
    ElderHooks.agentOverride = null;
    setMoneyDigitsBn(false);
    FamProbashiSection.debugMyOffsetMin = null;
  });

  group('1 elder Talk to Assisto', () {
    testWidgets('a real question: the answer is shown big and read out loud', (t) async {
      ElderHooks.listenOverride = (_) async => 'will it rain today';
      ElderHooks.agentOverride = (_, q) async => {
            'reply': '## Weather\n**Rain** is likely in Dhaka this afternoon. Take an umbrella.\n\n- Keep medicines dry',
          };
      await _pump(t, const ElderEasyHome(debugFamily: fceFamily), FakeApi());
      await t.ensureVisible(find.byKey(const Key('fce-talk')));
      await t.tap(find.byKey(const Key('fce-talk')));
      await t.pumpAndSettle();
      final reply = t.widget<Text>(find.byKey(const Key('fce-reply'))).data!;
      expect(reply, contains('Rain is likely in Dhaka'));
      expect(reply.contains('**') || reply.contains('##'), isFalse, reason: reply);
      expect(find.textContaining('will it rain today'), findsOneWidget);
      expect(find.text('Sorry, couldn\'t do that now. Please try again.'), findsNothing);
      expect(voice.said.any((s) => s.contains('Take an umbrella.')), isTrue, reason: '${voice.said}');
      final n = voice.said.length;
      await t.tap(find.byKey(const Key('fce-reply-again')));
      await t.pumpAndSettle();
      expect(voice.said.length, n + 1);
      await t.tap(find.byKey(const Key('fce-reply-close')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('fce-reply')), findsNothing);
    });

    testWidgets('offline: an honest line (calls and Danger still work)', (t) async {
      ElderHooks.listenOverride = (_) async => 'will it rain today';
      ElderHooks.agentOverride = (_, q) async => throw Exception('offline');
      await _pump(t, const ElderEasyHome(debugFamily: fceFamily), FakeApi());
      await t.ensureVisible(find.byKey(const Key('fce-talk')));
      await t.tap(find.byKey(const Key('fce-talk')));
      await t.pumpAndSettle();
      expect(find.textContaining('needs the internet'), findsOneWidget);
      expect(voice.said.any((s) => s.contains('needs the internet')), isTrue);
    });

    testWidgets('Bangla answer at 200 % font: no overflow, Bangla title', (t) async {
      ElderHooks.listenOverride = (_) async => 'আজ কি বৃষ্টি হবে';
      ElderHooks.agentOverride = (_, q) async => {
            'reply': '**সংক্ষেপে:** আজ বিকেলে ঢাকায় বৃষ্টি হতে পারে। ছাতা নিয়ে বের হন।',
          };
      await _pump(t, const ElderEasyHome(debugFamily: fceFamily), FakeApi(), lang: 'bn', scale: 2);
      await t.scrollUntilVisible(find.byKey(const Key('fce-talk')), 200,
          scrollable: find.byType(Scrollable).first);
      await t.ensureVisible(find.byKey(const Key('fce-talk')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('fce-talk')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.textContaining('আপনি জিজ্ঞেস করেছেন'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const Key('fce-reply'))).data, startsWith('সংক্ষেপে:'));
    });

    test('plain reply + spoken part end at a full sentence', () {
      expect(elderPlainReply('# Title\n**bold** and `code`\n\n\n- one\n* two'),
          'Title\nbold and code\n\n• one\n• two');
      final long = List.generate(30, (i) => 'Sentence number $i is here.').join(' ');
      final sp = elderSpokenPart(long, max: 120);
      expect(sp.length, lessThanOrEqualTo(120));
      expect(sp.endsWith('.'), isTrue, reason: sp);
      expect(elderSpokenPart('প্রথম বাক্য। দ্বিতীয় বাক্য অনেক লম্বা', max: 20), 'প্রথম বাক্য।');
    });
  });

  group('2 Location picks the person', () {
    final people = [
      {'member_id': 7, 'peer_user_id': 3, 'name': 'Rafi', 'relation': 'son', 'child': false},
      {'member_id': 8, 'peer_user_id': 5, 'name': 'Sakib', 'relation': 'brother', 'child': false},
    ];
    testWidgets('from a member card: that person is selected already', (t) async {
      await _pump(t, GuardianRequestScreen(people: people, locationOnly: true, preselectUserId: 5), _Api());
      final chip = t.widget<ChoiceChip>(find.byKey(const ValueKey('gj_person_8')));
      expect(chip.selected, isTrue);
      expect(t.widget<ChoiceChip>(find.byKey(const ValueKey('gj_person_7'))).selected, isFalse);
      expect(find.byKey(const ValueKey('gj_preselect_missing')), findsNothing);
    });
    testWidgets('not in My Circle: a plain note, nobody picked', (t) async {
      await _pump(t, GuardianRequestScreen(people: people, locationOnly: true, preselectUserId: 99), _Api());
      expect(find.byKey(const ValueKey('gj_preselect_missing')), findsOneWidget);
      expect(t.widget<ChoiceChip>(find.byKey(const ValueKey('gj_person_8'))).selected, isFalse);
    });
  });

  group('Family screen', () {
    testWidgets('3/4 failed refresh: labelled old data + retry; success clears it', (t) async {
      final api = _Api();
      await _pump(t, const FamilyV3Screen(), api);
      expect(find.byKey(const ValueKey('fcg-stale-banner')), findsNothing);
      api.failBoard = true;
      await t.tap(find.byIcon(Icons.sync_rounded));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('fcg-stale-banner')), findsOneWidget);
      expect(find.textContaining("Couldn't get new news"), findsOneWidget);
      // the old cards are still there (honest, not blank)
      expect(find.byKey(const ValueKey('fc3-list')), findsOneWidget);
      api.failBoard = false;
      await t.tap(find.byKey(const ValueKey('fcg-stale-retry')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('fcg-stale-banner')), findsNothing);
    });

    testWidgets('5 tasks: undo a mistaken done; delete asks first', (t) async {
      final api = _Api()
        ..edit = (b) => (b['tasks'] as List).add({
              'id': 73, 'title': 'Pay gas bill', 'kind': 'bill', 'due_date': null,
              'taken_by': 1, 'taken_by_name': 'Rina', 'mine': true, 'done': true,
              'done_by_name': 'Rina', 'created_by': 1,
            });
      await _pump(t, const FamilyV3Screen(), api);
      await _scrollTo(t, find.byKey(const ValueKey('fcg-task-delete-71')));
      await t.tap(find.byKey(const ValueKey('fcg-task-delete-71')));
      await t.pumpAndSettle();
      expect(find.text('Delete this task for everyone?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(api.posts.where((p) => p.endsWith('/delete')), isEmpty);
      await t.tap(find.byKey(const ValueKey('fcg-task-delete-71')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('fcg-task-delete-ok')));
      await t.pumpAndSettle();
      expect(api.posts, contains('/family/v3/tasks/71/delete'));

      await _scrollTo(t, find.byKey(const ValueKey('fcg-task-undo-73')));
      await t.tap(find.byKey(const ValueKey('fcg-task-undo-73')));
      await t.pumpAndSettle();
      expect(api.posts, contains('/family/v3/tasks/73/undo'));
    });

    testWidgets('6 Important papers opens papers; Today bazar opens the bazar list', (t) async {
      await _pump(t, const FamilyV3Screen(), _Api());
      await _scrollTo(t, find.byKey(const ValueKey('fc3-more-papers')));
      await t.tap(find.byKey(const ValueKey('fc3-more-papers')));
      await t.pumpAndSettle();
      var seg = t.widget<SegmentedButton<String>>(find.byKey(const ValueKey('fc-share-panes')));
      expect(seg.selected, {'docs'});
      expect(find.text('Important papers'), findsWidgets);
      await t.pageBack();
      await t.pumpAndSettle();
      await _scrollTo(t, find.textContaining('Bazar list'));
      await t.tap(find.textContaining('Bazar list'));
      await t.pumpAndSettle();
      seg = t.widget<SegmentedButton<String>>(find.byKey(const ValueKey('fc-share-panes')));
      expect(seg.selected, {'list'});
    });

    testWidgets('8 a paused member: "paused sharing", not "no news"', (t) async {
      final api = _Api(scene: 'ok')
        ..edit = (b) {
          final m = (b['members'] as List).firstWhere((x) => x['user_id'] == 3) as Map;
          final until = DateTime.now().add(const Duration(hours: 2)).toUtc().toIso8601String();
          (m['brain'] as Map)['paused_until'] = until;
          m['status'] = {'state': 'paused', 'reason': 'paused', 'fresh_until': null};
          m['chip'] = {'kind': 'paused', 'until': until};
        };
      await _pump(t, const FamilyV3Screen(), api);
      expect(find.text('Rafi has paused sharing for now'), findsOneWidget);
      expect(find.text('No news from Rafi'), findsNothing);
    });

    testWidgets('Bangla + 200 %: banner and task buttons fit', (t) async {
      final api = _Api();
      await _pump(t, const FamilyV3Screen(), api, lang: 'bn', scale: 2);
      api.failBoard = true;
      await t.tap(find.byIcon(Icons.sync_rounded));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final s = t.widget<Text>(find.descendant(
          of: find.byKey(const ValueKey('fcg-stale-banner')), matching: find.byType(Text)).first);
      expect(RegExp(r'[0-9]').hasMatch(s.data!), isFalse, reason: s.data);
    });
  });

  test('7 family ledger money: Bangla digits in Bangla', () {
    setMoneyDigitsBn(true);
    expect(FamAcctLocal.fmtPoisha(125000), '৳১,২৫০.০০');
    setMoneyDigitsBn(false);
    expect(FamAcctLocal.fmtPoisha(125000), '৳1,250.00');
  });

  testWidgets('13 empty My Circle: Add member offers "Add to My Circle"', (t) async {
    await _pump(t, const Scaffold(body: SafeArea(child: FcAddMemberSheet(familyId: 10, inFamily: {}))), _Api());
    expect(find.byKey(const ValueKey('fc3-add-empty')), findsOneWidget);
    final b = find.byKey(const ValueKey('fcg-add-to-circle'));
    expect(b, findsOneWidget);
    expect(t.getSize(b).height, greaterThanOrEqualTo(48));
    expect(find.text('Add to My Circle'), findsOneWidget);
  });

  group('14 Probashi clocks', () {
    const sakib = [{'name': 'Sakib', 'tz': 'Asia/Riyadh'}];
    testWidgets('parents in Bangladesh see Sakib\'s time, 3 h behind', (t) async {
      FamProbashiSection.debugMyOffsetMin = 360;
      await _pump(t, const Scaffold(body: FamProbashiSection(abroad: sakib)), _Api());
      expect(find.text("Sakib's time"), findsWidgets);
      expect(find.text('Same time'), findsNothing);
      expect(find.text('Bangladesh is 3h ahead'), findsOneWidget);
    });
    testWidgets('the person abroad keeps "My time"', (t) async {
      FamProbashiSection.debugMyOffsetMin = 180;
      await _pump(t, const Scaffold(body: FamProbashiSection()), _Api());
      expect(find.text('My time'), findsWidgets);
      expect(find.text('Bangladesh is 3h ahead'), findsOneWidget);
    });
    testWidgets('two people abroad: pick whose clock', (t) async {
      FamProbashiSection.debugMyOffsetMin = 360;
      await _pump(t, const Scaffold(body: FamProbashiSection(abroad: [
        {'name': 'Sakib', 'tz': 'Asia/Riyadh'},
        {'name': 'Mitu', 'tz': 'Europe/London'},
      ])), _Api());
      await t.tap(find.byKey(const ValueKey('fcg-probashi-who-1')));
      await t.pumpAndSettle();
      expect(find.text("Mitu's time"), findsWidgets);
    });
  });

  group('11 shared family ledger + goals', () {
    Future<void> openGoals(WidgetTester t, _Api api, {String lang = 'en'}) async {
      await _pump(t, const Scaffold(body: FamAcctSection(
          familyId: 10, members: [{'id': 'u3', 'name': 'Rafi'}])), api, lang: lang);
      await t.tap(find.byKey(const ValueKey('fcg-goals-tab')));
      await t.pumpAndSettle();
    }

    testWidgets('every call carries the family; goal shows progress; Add money posts', (t) async {
      final api = _Api();
      await openGoals(t, api);
      expect(api.gets.where((g) => g.startsWith('family/accounting/') && !g.contains('family=10')),
          isEmpty, reason: '${api.gets}');
      expect(find.text('My family — everyone sees and adds'), findsOneWidget);
      expect(find.text('Eid fund'), findsOneWidget);
      expect(find.byKey(const ValueKey('fcg-goal-progress-5')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('fcg-goal-add-5')));
      await t.pumpAndSettle();
      await t.tap(find.text('Rafi').last);
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('fa-amount-field')), '500');
      await t.tap(find.byKey(const ValueKey('fa-amount-save')));
      await t.pumpAndSettle();
      expect(api.posts, contains('/family/accounting/goals/5/contribute'));
      expect(api.bodies.last, {'member': 'u3', 'amount_poisha': 50000});
    });

    testWidgets('close asks first', (t) async {
      final api = _Api();
      await openGoals(t, api);
      await t.tap(find.byKey(const ValueKey('fcg-goal-close-5')));
      await t.pumpAndSettle();
      expect(api.posts.where((p) => p.endsWith('/close')), isEmpty);
      await t.tap(find.byKey(const ValueKey('fcg-goal-close-ok')));
      await t.pumpAndSettle();
      expect(api.posts, contains('/family/accounting/goals/5/close'));
    });

    testWidgets('Bangla: goal money in Bangla digits', (t) async {
      await openGoals(t, _Api(), lang: 'bn');
      final txt = t.widget<Text>(find.byKey(const ValueKey('fcg-goal-progress-5'))).data!;
      expect(RegExp(r'[0-9]').hasMatch(txt), isFalse, reason: txt);
      expect(txt, contains('৳'));
    });
  });
}
