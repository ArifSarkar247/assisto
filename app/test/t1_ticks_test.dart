// t1-ticks — date separators (pure, Asia/Dhaka + other zones), date chip
// labels (en/bn, Bangla digits), floating date chip, WhatsApp header (360 px,
// large font, en/bn: no clipping), legacy Message info, version gate.
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_header.dart';
import 'package:assisto/messaging/date_separators.dart';
import 'package:assisto/messaging/mc_version_gate.dart';
import 'package:assisto/messaging/msg_widgets.dart';
import 'package:assisto/messaging/presence_label.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

Widget _app(Widget home,
        {String lang = 'en',
        Brightness b = Brightness.light,
        double scale = 1.0}) =>
    MaterialApp(
      theme: ThemeData(brightness: b, useMaterial3: true),
      locale: Locale(lang),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('bn')],
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    );

class _M {
  final String id;
  final DateTime? at;
  const _M(this.id, this.at);
}

bool _hasBangla(String s) => RegExp('[ঀ-৿]').hasMatch(s);
bool _hasLatinDigit(String s) => RegExp('[0-9]').hasMatch(s);

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('bn');
  });
  final en = lookupAppLocalizations(const Locale('en'));
  final bn = lookupAppLocalizations(const Locale('bn'));

  group('insertDateSeparators (pure)', () {
    List<String> shape(List<ChatRow<_M>> rows) => [
          for (final r in rows)
            switch (r) {
              ChatDateRow(:final day) => 'D${day.month}-${day.day}',
              ChatItemRow(:final item) => item.id,
              ChatNoticeRow() => 'E2E',
            }
        ];

    test('one chip before each local day (Asia/Dhaka, UTC+6)', () {
      final items = [
        _M('a', DateTime.utc(2026, 10, 20, 10)), // 16:00 Dhaka 20 Oct
        _M('b', DateTime.utc(2026, 10, 20, 17, 59)), // 23:59 Dhaka 20 Oct
        _M('c', DateTime.utc(2026, 10, 20, 18, 0)), // 00:00 Dhaka 21 Oct
        _M('d', DateTime.utc(2026, 10, 21, 3)), // 09:00 Dhaka 21 Oct
        _M('e', DateTime.utc(2026, 10, 22, 1)), // 07:00 Dhaka 22 Oct
      ];
      final rows = insertDateSeparators<_M>(items, (m) => m.at,
          toLocal: dhakaWallClock);
      expect(shape(rows),
          ['D10-20', 'a', 'b', 'D10-21', 'c', 'd', 'D10-22', 'e']);
    });

    test('same instants in UTC-5 split differently', () {
      final items = [
        _M('b', DateTime.utc(2026, 10, 20, 17, 59)),
        _M('c', DateTime.utc(2026, 10, 20, 18, 0)),
        _M('x', DateTime.utc(2026, 10, 21, 4, 30)), // 23:30 20 Oct in UTC-5
        _M('y', DateTime.utc(2026, 10, 21, 5, 30)), // 00:30 21 Oct in UTC-5
      ];
      DateTime minus5(DateTime d) {
        final u = d.toUtc().subtract(const Duration(hours: 5));
        return DateTime(u.year, u.month, u.day, u.hour, u.minute);
      }

      expect(
          shape(insertDateSeparators<_M>(items, (m) => m.at,
              toLocal: minus5)),
          ['D10-20', 'b', 'c', 'x', 'D10-21', 'y']);
      expect(
          shape(insertDateSeparators<_M>(items, (m) => m.at,
              toLocal: dhakaWallClock)),
          ['D10-20', 'b', 'D10-21', 'c', 'x', 'y']);
    });

    test('newest-first (reversed list): chip after each day\'s oldest', () {
      final items = [
        _M('e', DateTime.utc(2026, 10, 22, 1)),
        _M('d', DateTime.utc(2026, 10, 21, 3)),
        _M('c', DateTime.utc(2026, 10, 20, 18, 0)),
        _M('a', DateTime.utc(2026, 10, 20, 10)),
      ];
      final rows = insertDateSeparators<_M>(items, (m) => m.at,
          newestFirst: true, toLocal: dhakaWallClock);
      expect(shape(rows), ['e', 'D10-22', 'd', 'c', 'D10-21', 'a', 'D10-20']);
    });

    test('unknown time stays with the previous day; empty list', () {
      final items = [
        _M('a', DateTime.utc(2026, 10, 20, 10)),
        const _M('poll', null),
        _M('b', DateTime.utc(2026, 10, 21, 10)),
      ];
      final rows = insertDateSeparators<_M>(items, (m) => m.at,
          toLocal: dhakaWallClock);
      expect(shape(rows), ['D10-20', 'a', 'poll', 'D10-21', 'b']);
      expect((rows[2] as ChatItemRow<_M>).day, DateTime(2026, 10, 20));
      expect(insertDateSeparators<_M>(const [], (m) => m.at), isEmpty);
      // a leading unknown-time item gets no chip and no day
      final r2 = insertDateSeparators<_M>(const [_M('p', null)], (m) => m.at);
      expect(r2.length, 1);
      expect((r2.first as ChatItemRow<_M>).day, isNull);
    });
  });

  group('E2E notice = first history item (not pinned)', () {
    test('pure: notice first (oldest end), both list orders', () {
      final items = [
        _M('a', DateTime.utc(2026, 10, 20, 10)),
        _M('b', DateTime.utc(2026, 10, 21, 10)),
      ];
      final rows = insertDateSeparators<_M>(items, (m) => m.at,
          e2eNotice: true, toLocal: dhakaWallClock);
      expect(rows.first, isA<ChatNoticeRow<_M>>());
      expect(rows[1], isA<ChatDateRow<_M>>());
      final rev = insertDateSeparators<_M>(items.reversed.toList(), (m) => m.at,
          e2eNotice: true, newestFirst: true, toLocal: dhakaWallClock);
      expect(rev.last, isA<ChatNoticeRow<_M>>());
      expect(rows.whereType<ChatNoticeRow<_M>>().length, 1);
      expect(
          insertDateSeparators<_M>(items, (m) => m.at)
              .whereType<ChatNoticeRow<_M>>(),
          isEmpty);
    });

    testWidgets('scrolls away with the history; tap = info', (tester) async {
      final rows = insertDateSeparators<_M>([
        for (var i = 0; i < 30; i++)
          _M('m$i', DateTime.now().subtract(Duration(minutes: 60 - i)))
      ], (m) => m.at, e2eNotice: true);
      await tester.pumpWidget(_app(Scaffold(
        body: ChatDateScope(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) => buildChatRow<_M>(
                rows[i], (m) => SizedBox(height: 60, child: Text(m.id))),
          ),
        ),
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('t1-e2e-notice')), findsOneWidget);
      await tester.tap(find.byKey(const Key('t1-e2e-notice')));
      await tester.pumpAndSettle();
      expect(find.text(en.t1E2eInfoBody), findsOneWidget);
      await tester.tap(find.text(en.close));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('t1-e2e-notice')), findsNothing);
    });
  });

  group('date chip labels', () {
    final now = DateTime(2026, 10, 22, 15); // Thursday
    test('en: Today / Yesterday / weekday / 18 Oct 2026', () {
      expect(dateChipLabel(en, DateTime(2026, 10, 22), lang: 'en', now: now),
          'Today');
      expect(dateChipLabel(en, DateTime(2026, 10, 21), lang: 'en', now: now),
          'Yesterday');
      expect(dateChipLabel(en, DateTime(2026, 10, 19), lang: 'en', now: now),
          'Monday');
      expect(dateChipLabel(en, DateTime(2026, 10, 16), lang: 'en', now: now),
          'Friday');
      expect(dateChipLabel(en, DateTime(2026, 10, 15), lang: 'en', now: now),
          '15 Oct 2026');
      expect(dateChipLabel(en, DateTime(2026, 10, 18), lang: 'en', now: now),
          'Sunday');
      expect(dateChipLabel(en, DateTime(2025, 1, 3), lang: 'en', now: now),
          '3 Jan 2025');
    });

    test('bn: Bangla words, weekday, month and digits', () {
      expect(dateChipLabel(bn, DateTime(2026, 10, 22), lang: 'bn', now: now),
          bn.t1Today);
      expect(dateChipLabel(bn, DateTime(2026, 10, 21), lang: 'bn', now: now),
          bn.t1Yesterday);
      final mon =
          dateChipLabel(bn, DateTime(2026, 10, 19), lang: 'bn', now: now);
      expect(_hasBangla(mon), isTrue);
      final old =
          dateChipLabel(bn, DateTime(2026, 10, 18 - 3), lang: 'bn', now: now);
      expect(_hasBangla(old), isTrue);
      expect(_hasLatinDigit(old), isFalse, reason: old);
      expect(old, contains(localDigits('15', 'bn')));
      expect(old, contains(localDigits('2026', 'bn')));
    });

    test('Bangla digits helper', () {
      expect(localDigits('12:45', 'bn'), '১২:৪৫');
      expect(localDigits('12:45', 'en'), '12:45');
      expect(_hasLatinDigit(fmtTime(DateTime(2026, 1, 1, 21, 10), 'bn')),
          isFalse);
    });
  });

  group('header status line', () {
    final now = DateTime(2026, 10, 22, 18, 0);
    test('en: last seen today / yesterday / 18 Oct', () {
      expect(
          presenceLabel(en, RtChatState(lastSeen: DateTime(2026, 10, 22, 12, 45)),
              lang: 'en', now: now),
          'last seen today at 12:45 pm');
      expect(
          presenceLabel(en, RtChatState(lastSeen: DateTime(2026, 10, 21, 21, 10)),
              lang: 'en', now: now),
          'last seen yesterday at 9:10 pm');
      expect(
          presenceLabel(en, RtChatState(lastSeen: DateTime(2026, 10, 18, 9)),
              lang: 'en', now: now),
          'last seen Sunday at 9:00 am');
      expect(
          presenceLabel(en, RtChatState(lastSeen: DateTime(2025, 12, 30, 9)),
              lang: 'en', now: now),
          'last seen 30 Dec 2025 at 9:00 am');
    });
    test('bn: Bangla digits, no Latin digits', () {
      final today = presenceLabel(
          bn, RtChatState(lastSeen: DateTime(2026, 10, 22, 12, 45)),
          lang: 'bn', now: now)!;
      expect(today, bn.c3LastSeenToday('${bn.mr1PeriodNoon} ${localDigits('12:45', 'bn')}')); // mr1
      final old = presenceLabel(
          bn, RtChatState(lastSeen: DateTime(2026, 9, 18, 9)), // mr1: a date
          lang: 'bn', now: now)!;
      expect(_hasLatinDigit(old), isFalse, reason: old);
      expect(old, contains(localDigits('18', 'bn')));
    });
    test('group members line', () {
      expect(groupMembersLine(['Rahim', ' ', 'Karim'], 'You'),
          'Rahim, Karim, You');
      expect(groupMembersLine(const [], 'You'), isNull);
    });
  });

  group('header widget: 360 px, large font, no clipping', () {
    for (final lang in ['en', 'bn']) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('$lang scale $scale', (tester) async {
          tester.view.physicalSize = const Size(360, 720);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final t = lang == 'bn' ? bn : en;
          var tapped = 0;
          await tester.pumpWidget(_app(
            Builder(builder: (ctx) {
              return Scaffold(
                appBar: AppBar(
                  titleSpacing: 0,
                  title: ChatHeaderTitle(
                    name: 'T Shanto',
                    status: t.c3LastSeenYesterday(fmtTime(
                        DateTime(2026, 10, 21, 21, 10), lang)),
                    avatar: const HeaderInitialAvatar(name: 'T Shanto'),
                    onTap: () => tapped++,
                  ),
                  actions: [
                    IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.videocam_rounded)),
                    IconButton(
                        onPressed: () {}, icon: const Icon(Icons.call_rounded)),
                    IconButton(
                        onPressed: () {}, icon: const Icon(Icons.more_vert_rounded)),
                  ],
                ),
              );
            }),
            lang: lang,
            scale: scale,
          ));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull); // no overflow
          final name = tester.renderObject<RenderParagraph>(
              find.byKey(const Key('t1-header-name')));
          final status = tester.renderObject<RenderParagraph>(
              find.byKey(const Key('t1-header-status')));
          // the name gets the whole width up to the call icons (no Search
          // icon any more) and fits on one line at 360 px (not "T Shan…").
          // The test font draws every glyph a full em wide, so the fit check
          // runs at 1.0x.
          if (scale == 1.0) expect(name.didExceedMaxLines, isFalse);
          final video = tester.getRect(find.byIcon(Icons.videocam_rounded));
          final title = tester.getRect(find.byKey(const Key('t1-header')));
          expect(video.left - title.right, lessThan(24));
          expect(find.byIcon(Icons.search_rounded), findsNothing);
          expect(status, isNotNull); // single line, ellipsis-guarded
          // both lines inside the 56 px toolbar
          final bar = tester.getRect(find.byType(AppBar));
          expect(tester.getRect(find.byKey(const Key('t1-header-status'))).bottom,
              lessThanOrEqualTo(bar.bottom));
          await tester.tap(find.byKey(const Key('t1-header')));
          expect(tapped, 1);
        });
      }
    }

    testWidgets('privacy hidden -> one line only; group typing wins',
        (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        appBar: AppBar(title: const ChatHeaderTitle(name: 'Amina')),
        body: const GroupHeaderTitle(
            name: 'Family', memberNames: ['Rahim', 'Karim']),
      )));
      await tester.pumpAndSettle();
      expect(find.text('Rahim, Karim, You'), findsOneWidget);
      // the 1:1 header with no status has no second line
      expect(
          find.descendant(
              of: find.byType(AppBar),
              matching: find.byKey(const Key('t1-header-status'))),
          findsNothing);
      await tester.pumpWidget(_app(const Scaffold(
          body: GroupHeaderTitle(
              name: 'Family',
              memberNames: ['Rahim'],
              activity: 'Rahim is typing…'))));
      await tester.pumpAndSettle();
      expect(find.text('Rahim is typing…'), findsOneWidget);
      expect(find.text('Rahim, You'), findsNothing);
    });
  });

  group('chips + floating date widget', () {
    testWidgets('separators render; floating chip shows then fades',
        (tester) async {
      final now = DateTime.now();
      final days = [
        DateTime(now.year, now.month, now.day).subtract(const Duration(days: 9)),
        DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1)),
        DateTime(now.year, now.month, now.day),
      ];
      final items = <_M>[
        for (final d in days)
          for (var i = 0; i < 15; i++)
            _M('${d.day}-$i', d.add(Duration(hours: 8, minutes: i))),
      ];
      final rows = insertDateSeparators<_M>(items, (m) => m.at);
      final key = GlobalKey<ChatDateScopeState>();
      await tester.pumpWidget(_app(Scaffold(
        body: ChatDateScope(
          key: key,
          idle: const Duration(milliseconds: 300),
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) => buildChatRow<_M>(
                rows[i],
                (m) => SizedBox(
                    height: 60, child: Text(m.id, key: ValueKey(m.id)))),
          ),
        ),
      )));
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsNothing); // far below
      expect(key.currentState!.floatingDay, isNull);
      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(key.currentState!.floatingDay, isNotNull);
      expect(find.text('Yesterday'), findsWidgets);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(key.currentState!.floatingDay, isNull); // faded out when idle
    });
  });

  group('message info: legacy', () {
    testWidgets('legacy -> "Sent before read receipts…", never "Not yet"',
        (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        body: MessageInfoView(
            load: () async => {
                  'id': 1,
                  'group': false,
                  'receipts_legacy': true,
                  'status': 'sent',
                  'recipients': [
                    {'user_id': 2, 'name': 'B', 'delivered_at': null,
                     'seen_at': null}
                  ]
                }),
      )));
      await tester.pumpAndSettle();
      expect(find.text(en.t1InfoLegacy), findsOneWidget);
      expect(find.text(en.c3InfoPending), findsNothing);
    });

    testWidgets('new message -> real times (bn digits)', (tester) async {
      final at = DateTime.now().subtract(const Duration(minutes: 3));
      await tester.pumpWidget(_app(
          Scaffold(
            body: MessageInfoView(
                load: () async => {
                      'id': 1,
                      'group': false,
                      'receipts_legacy': false,
                      'status': 'read',
                      'recipients': [
                        {'user_id': 2, 'name': 'B',
                         'delivered_at': at.toUtc().toIso8601String(),
                         'seen_at': at.toUtc().toIso8601String()}
                      ]
                    }),
          ),
          lang: 'bn'));
      await tester.pumpAndSettle();
      expect(find.text(bn.t1InfoLegacy), findsNothing);
      final want = bn.c3InfoToday(fmtTime(at, 'bn'));
      expect(find.text(want), findsNWidgets(2));
      expect(_hasLatinDigit(want), isFalse);
    });
  });

  group('version gate', () {
    test('state from server json', () {
      final s = McGateState.fromJson({
        'min_version': 183,
        'me_outdated': false,
        'peers_outdated': [
          {'user_id': 2, 'name': 'Bilal', 'build': 150}
        ],
        'peers_outdated_count': 1
      }, myBuild: 184);
      expect(s.meOutdated, isFalse);
      expect(s.peersOutdated, isTrue);
      expect(peerOutdatedText(en, s, group: false, lang: 'en'),
          'Bilal needs to update Assisto for ticks and calls');
      expect(McGateState.fromJson({'min_version': 183}, myBuild: 182).meOutdated,
          isTrue);
      expect(peerOutdatedText(en, McGateState.none, group: false, lang: 'en'),
          isNull);
      final g = McGateState.fromJson({
        'min_version': 183,
        'peers_outdated': [
          {'name': 'A'},
          {'name': 'B'},
          {'name': 'C'}
        ],
        'peers_outdated_count': 5
      });
      expect(peerOutdatedText(en, g, group: true, lang: 'en'),
          'A, B, C and 2 more need to update Assisto for ticks and calls');
      expect(
          _hasLatinDigit(peerOutdatedText(bn, g, group: true, lang: 'bn')!),
          isFalse);
    });

    testWidgets('banners + update screen (360 px, bn, large font)',
        (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
          Scaffold(
            body: ListView(children: const [
              McVersionBanner(
                  kind: 'member',
                  chatId: 1,
                  fixed: McGateState(
                      minVersion: 183,
                      outdatedNames: ['Bilal'],
                      outdatedCount: 1)),
              McVersionBanner(
                  kind: 'member',
                  chatId: 1,
                  fixed: McGateState(minVersion: 190, meOutdated: true)),
            ]),
          ),
          lang: 'bn',
          scale: 1.5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('t1-peer-outdated')), findsOneWidget);
      expect(find.byKey(const Key('t1-me-outdated')), findsOneWidget);
      await tester.pumpWidget(_app(const McUpdateScreen(), lang: 'bn', scale: 1.5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(bn.t1UpdateTitle), findsOneWidget);
      expect(find.byKey(const Key('t1-update-now')), findsOneWidget);
    });
  });
}
