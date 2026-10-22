// b2-badges — the home My Circle badge follows the SERVER (14 → open chats →
// 0; a new message → 1 → open → 0; survives an app kill / relaunch), it
// refreshes on route return, on a chat-seen poke and on the realtime
// `badges.update` event; the bell badge clears when the notification centre
// is opened (POST notif/opened) while items stay unread; tab badges.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/badges_bus.dart';
import 'package:assisto/models.dart';
import 'package:assisto/realtime/realtime_transport.dart';
import 'package:assisto/screens/home_screen.dart';
import 'package:assisto/screens/notification_centre_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/widgets/home_badge_icon.dart';

import 'fake_api.dart';

/// A tiny in-memory "server": unread per chat + notification items.
class _Server extends FakeApi {
  _Server() : super(mode: FakeMode.data, lang: 'en');

  Map<String, int> chatUnread = {};
  int bellNew = 0;          // unseen items newer than the bell watermark
  int urgent = 0;           // SOS / family alerts — never cleared by opening
  int feedBadge = 0;
  int remindersBadge = 0;
  final List<List<String>> opened = [];
  int badgeCalls = 0;

  void openChat(String key) => chatUnread[key] = 0;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/home/badges') {
      badgeCalls++;
      return {
        'my_circle_unread': chatUnread.values.fold<int>(0, (a, b) => a + b),
        'notif_unseen': bellNew + urgent,
      };
    }
    if (path.startsWith('/notif/feed')) {
      final j = await super.getJson(path);
      return {...j, 'badge': feedBadge};
    }
    if (path.startsWith('/notif/reminders')) {
      final j = await super.getJson(path);
      return {...j, 'badge': remindersBadge};
    }
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path == '/notif/opened') {
      final scopes = ((body['scopes'] as List?) ?? const []).cast<String>();
      opened.add(scopes);
      if (scopes.contains('bell')) bellNew = 0;
      if (scopes.contains('feed')) feedBadge = 0;
      if (scopes.contains('reminders')) remindersBadge = 0;
      return {'ok': true};
    }
    return super.postJson(path, body);
  }
}

AppState _state(_Server api) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'Arif', phone: '01700000000', email: '',
      autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _wrap(AppState app, Widget home) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<Updater>(create: (_) => Updater()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

int _circleCount(WidgetTester tester) => tester
    .widget<HomeBadgeIcon>(find.byWidgetPredicate((w) =>
        w is HomeBadgeIcon && w.icon == Icons.diversity_3_outlined))
    .count;

int _bellCount(WidgetTester tester) => tester
    .widget<HomeBadgeIcon>(find.byWidgetPredicate((w) =>
        w is HomeBadgeIcon && w.icon == Icons.notifications_outlined))
    .count;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BadgesBus.instance.reset();
    BadgesBus.instance.debounce = Duration.zero;
  });

  testWidgets('My Circle: 14 → open chats → 0; new message → 1 → open → 0; '
      'relaunch reads the server', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    final api = _Server()..chatUnread = {'member:7': 14};
    await tester.pumpWidget(_wrap(_state(api), const HomeScreen()));
    await _settle(tester);
    expect(_circleCount(tester), 14);
    expect(find.text('14'), findsOneWidget);

    // the chat screen's seen call succeeded → it pokes the bus
    api.openChat('member:7');
    BadgesBus.instance.poke();
    await _settle(tester);
    expect(_circleCount(tester), 0);
    expect(find.text('14'), findsNothing);

    // a new message from the other side arrives on the realtime loop
    final rt = PollRealtimeTransport(
        get: (_) async => {'events': [], 'seq': 0},
        post: (_, __) async => {});
    BadgesBus.instance.attach(rt.events);
    api.chatUnread['member:7'] = 1;
    rt.inject(RealtimeEvent(1, BadgesBus.topic, const {}, DateTime(2026)));
    await _settle(tester);
    expect(_circleCount(tester), 1);

    api.openChat('member:7');
    BadgesBus.instance.poke();
    await _settle(tester);
    expect(_circleCount(tester), 0);

    // "app kill / relaunch": a brand-new home reads the same server state
    await tester.pumpWidget(const SizedBox());
    BadgesBus.instance.reset();
    api.chatUnread['group:3'] = 2;
    await tester.pumpWidget(_wrap(_state(api), const HomeScreen()));
    await _settle(tester);
    expect(_circleCount(tester), 2);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Bell: opening the centre clears the badge; SOS keeps counting; '
      'refreshes on route return', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    final api = _Server()
      ..bellNew = 4
      ..urgent = 1;
    await tester.pumpWidget(_wrap(_state(api), const HomeScreen()));
    await _settle(tester);
    expect(_bellCount(tester), 5);

    await tester.tap(find.byWidgetPredicate((w) =>
        w is HomeBadgeIcon && w.icon == Icons.notifications_outlined));
    await _settle(tester);
    expect(find.byType(NotificationCentreScreen), findsOneWidget);
    expect(api.opened.first, ['bell']);

    // back to home → re-fetched: only the SOS still counts
    Navigator.of(tester.element(find.byType(NotificationCentreScreen))).pop();
    await _settle(tester);
    expect(_bellCount(tester), 1);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Centre tabs: the visible tab shows no badge and is marked '
      'opened; the other shows its count until visited; items stay unread',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    final api = _Server()
      ..feedBadge = 2
      ..remindersBadge = 3;
    await tester.pumpWidget(
        _wrap(_state(api), const NotificationCentreScreen()));
    await _settle(tester);
    expect(api.opened, containsAll([
      ['bell'],
      ['reminders']
    ]));
    // reminders tab (visible) shows none; notifications tab shows 2
    final badges = find.byKey(const ValueKey('notifTabBadge'));
    expect(badges, findsOneWidget);
    expect(find.descendant(of: badges, matching: find.text('2')),
        findsOneWidget);

    final t = AppLocalizations.of(
        tester.element(find.byType(NotificationCentreScreen)));
    await tester.tap(find.descendant(
        of: find.byType(TabBar), matching: find.text(t.notifTabNotifications)));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(api.opened.last, ['feed']);
    expect(find.byKey(const ValueKey('notifTabBadge')), findsNothing);
    // opening never marks items seen: "Mark all read" is still enabled
    final btn = tester.widget<TextButton>(find.ancestor(
        of: find.text(t.notifMarkAllRead), matching: find.byType(TextButton)));
    expect(btn.onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
