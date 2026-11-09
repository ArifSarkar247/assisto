// fcscreen (Family Care v3, owner order 9 Nov 10:50) — the Family screen.
//  1 E2E reality path: the SAME board turns from green to a gray DASHED card
//    with a plain reason + fix button when the phone clock passes the
//    member's fresh-until (no network) — zero false green
//  2 status line priority (SOS > check > no news > All OK), alerts first
//  3 family switcher (multi-family) + invite Join posts accept
//  4 More keeps every old feature; Probashi only when someone is abroad
//  5 shared task "I will do it" posts take
//  6 SOS button: 56 dp, red, opens the fcsos sender slot
//  7 fix guide: per-brand chips (7 BD brands), steps, send
//  8 widget snapshot: gray + "No news" when time runs out; never stale green
//  9 Bangla digits + 200 % font without overflow, dark theme
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/family_v3/family_v3_screen.dart';
import 'package:assisto/family_v3/fc_fix_guide.dart';
import 'package:assisto/family_v3/fc_slots.dart';
import 'package:assisto/family_v3/fc_widget_sync.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_fcscreen.dart';

class _Api extends ApiClient {
  _Api({this.scene = 'mixed', this.now});
  String scene;
  final DateTime? now;
  final List<String> posts = [];
  bool bn = false;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final p = path.startsWith('/') ? path.substring(1) : path;
    if (p == 'family/v3/families') return fcFakeFamilies(bn: bn, scene: scene);
    if (p.endsWith('/board')) return fcFakeBoard(bn: bn, scene: scene, now: now);
    if (p.startsWith('family/v3/members/')) return fcFakeMemberPage(4, bn: bn);
    if (p == 'family/circle-pick') return {'results': []};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    return {'ok': true, 'text': ''};
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => [];
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

Future<void> _pump(WidgetTester t, Widget w, ApiClient api,
    {String lang = 'en', bool dark = false, double scale = 1}) async {
  t.view.physicalSize = const Size(1080, 4800);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(w, api, lang: lang, dark: dark, scale: scale));
  await t.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester t, Finder f) async {
  await t.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FcSlots.openSosSender = null;
    FcSlots.askParser = null;
    FcSlots.nightNewsCard = null;
    FcSlots.moreRows = null;
  });

  testWidgets('E2E: fresh green turns gray dashed with a reason when data gets old',
      (t) async {
    final t0 = DateTime.now();
    final api = _Api(scene: 'ok', now: t0);
    // same server answer, phone clock 10 minutes later: green
    await _pump(t, FamilyV3Screen(debugNow: t0.add(const Duration(minutes: 10))), api);
    expect(find.byKey(const ValueKey('fc3-line-ok')), findsOneWidget);
    expect(find.text('All OK'), findsOneWidget);
    expect(find.byKey(const ValueKey('fc3-member-2-ok')), findsOneWidget);
    expect(find.byKey(const ValueKey('fc3-dashed-2')), findsNothing);

    // same server answer, phone clock 3 h 30 min later: NOT green any more
    await _pump(t, FamilyV3Screen(debugNow: t0.add(const Duration(hours: 3, minutes: 30))), api);
    expect(find.byKey(const ValueKey('fc3-line-ok')), findsNothing);
    expect(find.byKey(const ValueKey('fc3-line-stale')), findsOneWidget);
    expect(find.byKey(const ValueKey('fc3-member-2-stale')), findsOneWidget);
    expect(find.byKey(const ValueKey('fc3-dashed-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('fc3-reason-2')), findsOneWidget);
    expect(find.text('This phone may be stopping Assisto in the background'), findsWidgets);
    expect(find.byKey(const ValueKey('fc3-fix-2')), findsOneWidget);
    expect(find.text('All OK'), findsNothing);
  });

  testWidgets('status line: no news beats all-OK; alerts first; reason in plain words',
      (t) async {
    await _pump(t, const FamilyV3Screen(), _Api());
    // mixed: Sakib amber (battery 11 %) beats Abbu gray
    expect(find.byKey(const ValueKey('fc3-line-check')), findsOneWidget);
    expect(find.textContaining('Check on Sakib'), findsOneWidget);
    expect(find.text('Battery was 4% — the phone may be off'), findsOneWidget);
    // Abbu's gray dashed card comes before the green ones
    final yAbbu = t.getTopLeft(find.byKey(const ValueKey('fc3-member-4-stale'))).dy;
    final yAmmu = t.getTopLeft(find.byKey(const ValueKey('fc3-member-2-ok'))).dy;
    expect(yAbbu < yAmmu, isTrue);
    expect(find.byKey(const ValueKey('fc3-dashed-4')), findsOneWidget);
  });

  testWidgets('SOS line is red and on top', (t) async {
    await _pump(t, const FamilyV3Screen(), _Api(scene: 'sos'));
    expect(find.byKey(const ValueKey('fc3-line-sos')), findsOneWidget);
  });

  testWidgets('multi-family switcher + invite Join', (t) async {
    final api = _Api(scene: 'empty');
    await _pump(t, const FamilyV3Screen(), api);
    expect(find.byKey(const ValueKey('fc3-fam-10')), findsOneWidget);
    expect(find.byKey(const ValueKey('fc3-new-family')), findsOneWidget);
    expect(find.byKey(const ValueKey('fc3-empty-add')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('fc3-join-31')));
    await t.pumpAndSettle();
    expect(api.posts, contains('/family/v3/invites/31/accept'));

    api.scene = 'mixed';
    await _pump(t, const FamilyV3Screen(), api);
    expect(find.byKey(const ValueKey('fc3-fam-11')), findsOneWidget);
  });

  testWidgets('More keeps every old feature; Probashi only when abroad', (t) async {
    await _pump(t, const FamilyV3Screen(), _Api());
    for (final k in ['fc3-more-add', 'fc3-more-kids', 'fc3-more-ledger', 'fc3-more-papers',
        'fc3-more-card', 'fc3-more-members', 'fa100-tile', 'cga-tile', 'fc3-more-scam',
        'fc3-more-leave']) {
      await _scrollTo(t, find.byKey(ValueKey(k)));
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('fc3-more-probashi')), findsNothing);

    await _pump(t, const FamilyV3Screen(), _Api(scene: 'abroad'));
    await _scrollTo(t, find.byKey(const ValueKey('fc3-more-probashi')));
    expect(find.byKey(const ValueKey('fc3-more-probashi')), findsOneWidget);
  });

  testWidgets('shared task: I will do it posts take; who took it is shown', (t) async {
    final api = _Api();
    await _pump(t, const FamilyV3Screen(), api);
    await _scrollTo(t, find.byKey(const ValueKey('fc3-task-take-71')));
    expect(find.text('Sakib will do it'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('fc3-task-take-71')));
    await t.pumpAndSettle();
    expect(api.posts, contains('/family/v3/tasks/71/take'));
  });

  testWidgets('SOS button: 56 dp, red, opens the fcsos sender slot', (t) async {
    int? opened;
    FcSlots.openSosSender = (ctx, {familyId}) async => opened = familyId;
    await _pump(t, const FamilyV3Screen(), _Api());
    final sos = find.byKey(const ValueKey('fc3-sos'));
    expect(sos, findsOneWidget);
    expect(t.getSize(sos).height, greaterThanOrEqualTo(56));
    final style = t.widget<FilledButton>(sos).style;
    expect(style?.backgroundColor?.resolve({}), Brand.danger);
    await t.tap(sos);
    await t.pumpAndSettle();
    expect(opened, 10);
  });

  testWidgets('ask bar: the fcbrain parser answer opens the member', (t) async {
    FcSlots.askParser = (q, ctx) => q.contains('Ammu')
        ? FcAskAnswer('Ammu is OK', memberUserId: 2, action: 'open_member')
        : null;
    await _pump(t, const FamilyV3Screen(), _Api());
    await t.enterText(find.byKey(const ValueKey('fc3-ask')), 'Is Ammu OK?');
    await t.tap(find.byKey(const ValueKey('fc3-ask-send')));
    await t.pumpAndSettle();
    expect(find.text('Ammu is OK'), findsOneWidget);
    // no parser + empty server answer -> offline name match from the board
    FcSlots.askParser = null;
    await t.enterText(find.byKey(const ValueKey('fc3-ask')), 'where is Abbu');
    await t.tap(find.byKey(const ValueKey('fc3-ask-send')));
    await t.pumpAndSettle();
    expect(find.textContaining('Abbu · No news'), findsOneWidget);
  });

  testWidgets('fix guide: 7 BD brands, steps, send', (t) async {
    await _pump(
        t,
        const Scaffold(
            body: FcFixGuide(name: 'Abbu', reason: 'background_killed', brain: {'brand': 'Xiaomi'})),
        _Api());
    for (final b in ['Xiaomi', 'Realme', 'Oppo', 'Vivo', 'Samsung', 'Tecno', 'Infinix']) {
      expect(find.byKey(ValueKey('fc3-brand-$b')), findsOneWidget, reason: b);
    }
    expect(t.widget<ChoiceChip>(find.byKey(const ValueKey('fc3-brand-Xiaomi'))).selected, isTrue);
    expect(find.byKey(const ValueKey('fc3-fix-send')), findsOneWidget);
    expect(fcBrandIndex('Redmi Note 12'), 0);
    expect(fcBrandIndex('INFINIX'), 6);
    expect(fcBrandIndex(''), isNull);
  });

  testWidgets('widget snapshot: gray + No news when fresh-until passes', (t) async {
    late BuildContext ctx;
    await _pump(t, Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }), _Api());
    final t0 = DateTime.now();
    final board = fcFakeBoard(scene: 'ok', now: t0);
    final fresh = FcWidgetSync.snapshot(ctx, board, t0.add(const Duration(minutes: 5)));
    expect(fresh['line_state'], 'ok');
    expect((fresh['members'] as List).length, 2); // me excluded
    for (final m in fresh['members'] as List) {
      expect(m['fu'], greaterThan(t0.millisecondsSinceEpoch));
      expect(m['g'], startsWith('No news from'));
    }
    final old = FcWidgetSync.snapshot(ctx, board, t0.add(const Duration(hours: 4)));
    expect(old['line_state'], 'stale');
    for (final m in old['members'] as List) {
      expect(m['s'], 'stale');
    }
  });

  testWidgets('Bangla: Bangla digits, 200% font, dark — no overflow', (t) async {
    final api = _Api()..bn = true;
    await _pump(t, const FamilyV3Screen(), api, lang: 'bn', dark: true, scale: 2);
    expect(t.takeException(), isNull);
    final texts = t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join(' ');
    expect(texts.contains('৪%'), isTrue, reason: 'battery in Bangla digits');
    expect(RegExp(r'[0-9]').hasMatch(texts.replaceAll(RegExp(r'Assisto|SOS'), '')), isFalse,
        reason: texts);
  });
}
