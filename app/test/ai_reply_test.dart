// ai-reply-core (owner order 17 Nov, part H): My Circle AI reply — app side.
// Pure rules (state parsing, the local Busy timer, which message an auto
// reply answers, the loop guard on the phone) + the AI reply sheet (4 modes,
// group = suggest only, child refused, the Busy timer picker, the tag switch,
// Bangla digits, 200 % font, dark) + the suggestion chips (one tap sends).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/ai_reply/ai_reply.dart';
import 'package:assisto/messaging/ai_reply/ai_reply_widgets.dart';
import 'package:assisto/theme.dart';

Map<String, dynamic> _state({
  String mode = 'off',
  List<String> allowed = const ['off', 'suggest', 'busy', 'auto'],
  bool group = false,
  bool child = false,
  bool label = true,
  String? busyUntil,
  int freeLeft = 12,
}) =>
    {
      'ok': true,
      'enabled': true,
      'mode': mode,
      'allowed_modes': allowed,
      'busy_until': busyUntil,
      'label_on': label,
      'is_group': group,
      'child': child,
      'style_consent': false,
      'credits_per_reply': 1,
      'free_left': freeLeft,
      'unlock': 'ad',
      'unlock_ad_placement': 'ai_reply_unlock',
      'ads_per_reply': 1,
      'held': const [],
    };

class _Api extends ApiClient {
  _Api(this.body) {
    token = 't';
  }
  Map<String, dynamic> body;
  final posts = <(String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async => body;

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> b = const {}]) async {
    posts.add((path, b));
    if (path.startsWith('/ai/reply/settings/')) {
      final mode = b['mode'] as String? ?? body['mode'] as String;
      body = {
        ...body,
        'mode': mode,
        if (b.containsKey('label_on')) 'label_on': b['label_on'],
        if (mode == 'busy')
          'busy_until': b['busy_minutes'] == 0 ? null : '2026-11-17T15:30:00',
      };
      return body;
    }
    return {'ok': true};
  }
}

Widget _app(Widget child, {String lang = 'en', bool dark = false, double scale = 1}) =>
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
      builder: (ctx, w) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: Scaffold(body: child),
    );

Widget _sheet(_Api api, {bool group = false, String lang = 'en', bool dark = false, double scale = 1}) =>
    _app(
      AiReplySheet(
          api: AiReplyApi(api),
          chatId: 7,
          group: group,
          name: 'Bilal',
          initial: AiReplyState.fromJson(api.body)),
      lang: lang,
      dark: dark,
      scale: scale,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pure rules', () {
    test('state parsing keeps only known modes; label defaults ON', () {
      final s = AiReplyState.fromJson({
        'enabled': true,
        'mode': 'weird',
        'allowed_modes': ['off', 'suggest', 'bogus'],
      });
      expect(s.mode, 'off');
      expect(s.allowedModes, ['off', 'suggest']);
      expect(s.labelOn, isTrue);
    });

    test('busy timer: on until it expires; until-off stays on; auto always', () {
      final now = DateTime(2026, 11, 17, 15);
      final later = now.add(const Duration(minutes: 30)).millisecondsSinceEpoch;
      final earlier = now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch;
      expect(AiReplyLocal.autoOnFrom({'mode': 'busy', 'until': later}, now), isTrue);
      expect(AiReplyLocal.autoOnFrom({'mode': 'busy', 'until': earlier}, now), isFalse);
      expect(AiReplyLocal.autoOnFrom({'mode': 'busy', 'until': null}, now), isTrue);
      expect(AiReplyLocal.autoOnFrom({'mode': 'auto'}, now), isTrue);
      expect(AiReplyLocal.autoOnFrom({'mode': 'suggest'}, now), isFalse);
    });

    test('local cache: only Busy / Full auto with the flag on is remembered', () async {
      await AiReplyLocal.save(3, AiReplyState.fromJson(_state(mode: 'auto')));
      expect(await AiReplyLocal.autoOn(3), isTrue);
      await AiReplyLocal.save(3, AiReplyState.fromJson(_state(mode: 'suggest')));
      expect(await AiReplyLocal.autoOn(3), isFalse);
    });

    test('auto reply answers only the newest plain text from them', () {
      Map<String, dynamic> r(int id, {bool mine = false, String ct = 'text', bool ai = false}) =>
          {'id': id, 'mine': mine, 'content_type': ct, 'ai_reply': ai, 'deleted': ''};
      expect(aiIncomingToAnswer([r(1), r(2)])?['id'], 2);
      expect(aiIncomingToAnswer([r(1), r(2, mine: true)]), isNull); // I already answered
      expect(aiIncomingToAnswer([r(1, ct: 'photo')]), isNull);
      expect(aiIncomingToAnswer([r(1, ai: true)]), isNull); // ping-pong guard
      expect(aiIncomingToAnswer(const []), isNull);
    });

    test('context: earlier text lines as me / them', () {
      final rows = [
        {'id': 1, 'mine': true, 'content_type': 'text', 't': 'ki khobor'},
        {'id': 2, 'mine': false, 'content_type': 'photo', 't': 'x'},
        {'id': 3, 'mine': false, 'content_type': 'text', 't': 'valo'},
        {'id': 4, 'mine': false, 'content_type': 'text', 't': 'tumi?'},
      ];
      final ctx = aiContext(rows, (m) => m['t'] as String?);
      expect(ctx, [
        {'from': 'me', 'text': 'ki khobor'},
        {'from': 'them', 'text': 'valo'},
      ]);
    });

    test('suggest result: blocked = needs you, no chips', () {
      final r = AiSuggestResult.fromJson(
          {'ok': false, 'reason': 'blocked', 'needs_you': true, 'category': 'money'});
      expect(r.needsYou, isTrue);
      expect(r.suggestions, isEmpty);
    });
  });

  group('sheet', () {
    testWidgets('four modes for a person; choosing Full auto saves it', (t) async {
      final api = _Api(_state());
      await t.pumpWidget(_sheet(api));
      await t.pumpAndSettle();
      for (final m in ['off', 'suggest', 'busy', 'auto']) {
        expect(find.byKey(Key('aireply-mode-$m')), findsOneWidget, reason: m);
      }
      await t.tap(find.byKey(const Key('aireply-mode-auto')));
      await t.pumpAndSettle();
      expect(api.posts.last.$1, '/ai/reply/settings/member/7');
      expect(api.posts.last.$2['mode'], 'auto');
      expect(find.byKey(const Key('aireply-label')), findsOneWidget);
    });

    testWidgets('busy timer: 30 min / 1 h / 2 h / until off', (t) async {
      final api = _Api(_state());
      await t.pumpWidget(_sheet(api));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('aireply-busy-30')));
      await t.tap(find.byKey(const Key('aireply-busy-30')));
      await t.pumpAndSettle();
      expect(api.posts.last.$2, {'mode': 'busy', 'busy_minutes': 30});
      expect(find.byKey(const Key('aireply-busy-until')), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('aireply-busy-0')));
      await t.tap(find.byKey(const Key('aireply-busy-0')));
      await t.pumpAndSettle();
      expect(api.posts.last.$2['busy_minutes'], 0);
    });

    testWidgets('tag switch turns the label off for this person', (t) async {
      final api = _Api(_state(mode: 'auto'));
      await t.pumpWidget(_sheet(api));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('aireply-label')));
      await t.tap(find.byKey(const Key('aireply-label')));
      await t.pumpAndSettle();
      expect(api.posts.last.$2, {'label_on': false});
    });

    testWidgets('group: only Off / Suggest', (t) async {
      final api = _Api(_state(group: true, allowed: ['off', 'suggest']));
      await t.pumpWidget(_sheet(api, group: true));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('aireply-mode-suggest')), findsOneWidget);
      expect(find.byKey(const Key('aireply-mode-busy')), findsNothing);
      expect(find.byKey(const Key('aireply-mode-auto')), findsNothing);
      expect(find.byKey(const Key('aireply-label')), findsNothing);
    });

    testWidgets('child account: no modes, an honest line', (t) async {
      final api = _Api(_state(child: true, allowed: ['off']));
      await t.pumpWidget(_sheet(api));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('aireply-mode-auto')), findsNothing);
      expect(find.byKey(const Key('aireply-done')), findsOneWidget);
    });

    testWidgets('Bangla, dark, 200 % font: Bangla digits, no overflow', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final api = _Api(_state(mode: 'busy', busyUntil: '2026-11-17T15:30:00', freeLeft: 12));
      await t.pumpWidget(_sheet(api, lang: 'bn', dark: true, scale: 2));
      await t.pumpAndSettle();
      final cost = t.widget<Text>(find.byKey(const Key('aireply-cost'))).data!;
      expect(cost, contains('১২'));
      expect(RegExp(r'[0-9]').hasMatch(cost), isFalse);
      final until = t.widget<Text>(find.byKey(const Key('aireply-busy-until'))).data!;
      expect(RegExp(r'[0-9]').hasMatch(until), isFalse);
      expect(t.takeException(), isNull);
    });
  });

  group('chips', () {
    testWidgets('one tap sends the chosen reply', (t) async {
      String? sent;
      await t.pumpWidget(_app(AiSuggestionStrip(
        suggestions: const ['Valo achi, tumi?', 'Ha bolo'],
        onTap: (s) => sent = s,
      )));
      await t.tap(find.byKey(const Key('aireply-chip-1')));
      expect(sent, 'Ha bolo');
      final chip = t.getSize(find.byKey(const Key('aireply-chip-0')));
      expect(chip.height, greaterThanOrEqualTo(48));
    });

    testWidgets('held topic: no chips, "needs you"', (t) async {
      await t.pumpWidget(_app(AiSuggestionStrip(
          suggestions: const [], needsYou: true, onTap: (_) {})));
      expect(find.byKey(const Key('aireply-needs-you')), findsOneWidget);
      expect(find.byKey(const Key('aireply-chip-0')), findsNothing);
    });

    testWidgets('the AI tag text', (t) async {
      await t.pumpWidget(_app(const AiReplyTag(color: Colors.grey)));
      expect(find.text('Assisto AI reply'), findsOneWidget);
    });
  });
}
