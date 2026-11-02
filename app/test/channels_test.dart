// channels (2 Nov) — owner phone-test bug: My Circle channels / communities
// were invisible to other people. Client side: links (/ch/ + /cm/), push
// routing for channel posts, the ChatNav entries, and the screens (my
// channels + search entry, directory, a channel, communities home, a
// community, the join-link page) in bn/en, dark and 200% text without
// layout errors.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/invite/space_link.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/push/channel_post_notification.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/messenger/channel_detail_screen.dart';
import 'package:assisto/screens/messenger/channel_list_screen.dart';
import 'package:assisto/screens/messenger/communities_home_screen.dart';
import 'package:assisto/screens/messenger/community_detail_screen.dart';
import 'package:assisto/screens/messenger/discover_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/chatnav.dart';

import 'fake_api.dart';

final IdentityKeyPair _id = SoftwareE2E().generateIdentity();

AppState _app(String lang, FakeMode mode) {
  final s = AppState();
  s.api = FakeApi(mode: mode, lang: lang);
  s.user = AppUser(
      id: 1, name: lang == 'bn' ? 'রহিম' : 'Rahim', phone: '01700000000',
      email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _wrap(Widget home,
        {String lang = 'en',
        double scale = 1.0,
        bool dark = false,
        FakeMode mode = FakeMode.data}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _app(lang, mode),
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SpaceLink', () {
    test('channel link with private code', () {
      final l = SpaceLink.parse(
          'https://lifeassisto.com/ch/Dhaka_Bazar?k=k7m2p9q4rt')!;
      expect(l.isChannel, isTrue);
      expect(l.handle, 'dhaka_bazar');
      expect(l.code, 'k7m2p9q4rt');
      expect(SpaceLink.parse('/ch/dhaka_bazar')!.code, '');
    });
    test('community link and bare code', () {
      final l = SpaceLink.parse('https://lifeassisto.com/cm/K7M2P9Q4RT')!;
      expect(l.isChannel, isFalse);
      expect(l.code, 'k7m2p9q4rt');
      expect(SpaceLink.parse('k7m2p9q4rt')!.kind, 'community');
    });
    test('foreign hosts, circle invites and junk are not ours', () {
      expect(SpaceLink.parse('https://evil.com/ch/dhaka'), isNull);
      expect(SpaceLink.parse('https://lifeassisto.com/i/ABCDEFGHJK'), isNull);
      expect(SpaceLink.parse('hello world'), isNull);
      expect(SpaceLink.parse(''), isNull);
      expect(SpaceLink.isSpacePath('/cm/k7m2p9q4rt'), isTrue);
      expect(SpaceLink.isSpacePath('/i/ABCDEFGHJK'), isFalse);
    });
  });

  group('channel-post push', () {
    test('known kind, messages channel, opens Channels, one per channel', () {
      final p = PushPayload.fromData({
        'kind': 'channel_post', 'route': 'channels', 'channel_id': '11',
        'title': 'Dhaka Market Prices', 'body': 'Potato 40 tk today',
      });
      expect(p.isKnownKind, isTrue);
      expect(PushChannels.byKind['channel_post'], PushChannels.messages);
      expect(PushRouting.targetFor(p)!.chatNavRoute, 'channels');
      final q = PushPayload.fromData({
        'kind': 'channel_post', 'channel_id': '11', 'title': 'x', 'body': 'y'});
      expect(p.notificationId, q.notificationId);
      final c = channelPostNotificationContent(p);
      expect(c.title, 'Dhaka Market Prices');
      expect(c.body, 'Potato 40 tk today');
      final long = channelPostNotificationContent(PushPayload.fromData(
          {'kind': 'channel_post', 'title': '', 'body': 'a' * 300}));
      expect(long.title, 'Assisto');
      expect(long.body.length, 138);
    });
    test('community join push opens Communities', () {
      final p = PushPayload.fromData({'kind': 'community_join', 'route': 'communities'});
      expect(PushRouting.targetFor(p)!.chatNavRoute, 'communities');
    });
    test('ChatNav + feature map know the new routes', () {
      for (final r in ['channels', 'communities']) {
        expect(ChatNav.builderFor(r), isNotNull, reason: r);
        expect(kRouteFeature[r], 'my_circle');
      }
    });
  });

  group('screens', () {
    final screens = <String, Widget Function()>{
      'channels': () => const ChannelListScreen(),
      'directory': () => const DiscoverScreen(),
      'channel': () => const ChannelDetailScreen(channelId: 11),
      'communities': () => CommunitiesHomeScreen(identity: _id),
      'community': () => CommunityDetailScreen(
          community: <String, dynamic>{'id': 31, 'name': 'Mirpur 10', 'viewer_role': 'admin'},
          identity: _id),
      'join_link': () => SpaceLinkScreen(
          link: SpaceLink.parse('https://lifeassisto.com/cm/k7m2p9q4rt')!),
    };
    for (final e in screens.entries) {
      for (final lang in ['bn', 'en']) {
        for (final v in [(1.0, false), (2.0, true)]) {
          testWidgets('${e.key} $lang x${v.$1} dark=${v.$2} lays out', (tester) async {
            await tester.binding.setSurfaceSize(const Size(400, 860));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            // launchsweep: name the overflowing widget (file:line), not just
            // "RenderFlex overflowed".
            final where = <String>[];
            final orig = FlutterError.onError;
            FlutterError.onError = (d) {
              where.add('${d.exceptionAsString().split('\n').first} '
                  '${RegExp(r'lib/[A-Za-z0-9_/]+\.dart:\d+').firstMatch(d.toString())?.group(0) ?? ''}');
            };
            try {
              await tester.pumpWidget(
                  _wrap(e.value(), lang: lang, scale: v.$1, dark: v.$2));
              await _settle(tester);
            } finally {
              FlutterError.onError = orig;
            }
            expect(where, isEmpty);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('My channels + search entry; search opens the directory',
        (tester) async {
      await tester.pumpWidget(_wrap(const ChannelListScreen()));
      await _settle(tester);
      expect(find.text('My channels'), findsOneWidget);
      expect(find.text("Rahim's shop offers"), findsOneWidget);
      expect(find.byIcon(Icons.lock_rounded), findsWidgets); // private one
      await tester.tap(find.byKey(const Key('chx-search-entry')));
      await _settle(tester);
      expect(find.byType(DiscoverScreen), findsOneWidget);
    });

    testWidgets('empty channels: find + create buttons', (tester) async {
      await tester.pumpWidget(
          _wrap(const ChannelListScreen(), mode: FakeMode.empty));
      await _settle(tester);
      expect(find.byKey(const Key('chx-empty-find')), findsOneWidget);
      expect(find.byKey(const Key('chx-search-entry')), findsOneWidget);
    });

    testWidgets('create sheet: handle optional, public by default',
        (tester) async {
      await tester.pumpWidget(_wrap(const ChannelListScreen()));
      await _settle(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await _settle(tester);
      expect(find.text('@handle (optional)'), findsOneWidget);
      final pub = tester.widget<RadioListTile<bool>>(
          find.byKey(const Key('chx-create-public')));
      expect(pub.value, isTrue);
      expect(find.byKey(const Key('chx-create-private')), findsOneWidget);
    });

    testWidgets('channel page: share opens link + QR sheet', (tester) async {
      await tester.pumpWidget(_wrap(const ChannelDetailScreen(channelId: 11)));
      await _settle(tester);
      await tester.tap(find.byIcon(Icons.share_rounded));
      await _settle(tester);
      expect(find.byKey(const Key('space-invite-qr')), findsOneWidget);
      expect(find.byKey(const Key('space-invite-share')), findsOneWidget);
    });

    testWidgets('communities: list, waiting, join-with-link entry',
        (tester) async {
      await tester.pumpWidget(_wrap(CommunitiesHomeScreen(identity: _id)));
      await _settle(tester);
      expect(find.text('Mirpur 10 neighbours'), findsOneWidget);
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.byKey(const Key('chx-community-join')), findsOneWidget);
    });

    testWidgets('communities empty: benefit + big create button',
        (tester) async {
      await tester.pumpWidget(_wrap(CommunitiesHomeScreen(identity: _id),
          mode: FakeMode.empty));
      await _settle(tester);
      expect(find.byKey(const Key('chx-community-empty-create')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chx-community-empty-create')));
      await _settle(tester);
      expect(find.byKey(const Key('chx-community-name')), findsOneWidget);
    });

    testWidgets('join link: preview + ask to join -> request sent',
        (tester) async {
      await tester.pumpWidget(_wrap(SpaceLinkScreen(
          link: SpaceLink.parse('https://lifeassisto.com/cm/k7m2p9q4rt')!)));
      await _settle(tester);
      expect(find.text('Banani mosque committee'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chx-ask-join')));
      await _settle(tester);
      expect(find.textContaining('Request sent'), findsOneWidget);
    });

    testWidgets('community admin sees join request + joinable group',
        (tester) async {
      await tester.pumpWidget(_wrap(CommunityDetailScreen(
          community: <String, dynamic>{'id': 31, 'name': 'Mirpur 10', 'viewer_role': 'member'},
          identity: _id)));
      await _settle(tester);
      expect(find.text('Salma Akter'), findsOneWidget); // server says admin
      expect(find.text('Night security'), findsOneWidget);
    });
  });
}
