// m1-messenger: widget tests that TAP a ⋮ / settings option on the real screen
// and check the resulting state — the request that reached the API layer and
// what the user then sees (success toast, honest refusal, disabled item).
import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/circle_group_chat_screen.dart';
import 'package:assisto/screens/messenger/community_detail_screen.dart';
import 'package:assisto/screens/messenger/contact_info_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_change_number_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_notifications_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_storage_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_twostep_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every call; answers from [replies] (path -> body or ApiException).
class _RecApi extends ApiClient {
  final Map<String, Object> replies;
  final calls = <(String, String, Map<String, dynamic>)>[];
  _RecApi(this.replies) {
    token = 'test';
  }

  Map<String, dynamic> _answer(String path) {
    final key = path.split('?').first;
    final r = replies[key] ?? replies['*'] ?? const <String, dynamic>{};
    if (r is ApiException) throw r;
    return Map<String, dynamic>.from(r as Map);
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(('GET', path, const {}));
    return _answer(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    calls.add(('POST', path, body));
    return _answer(path);
  }

  bool posted(String path, [Map<String, dynamic>? body]) => calls.any((c) =>
      c.$1 == 'POST' &&
      c.$2 == path &&
      (body == null ||
          body.entries.every((e) => '${c.$3[e.key]}' == '${e.value}')));
}

late AppLocalizations t;

Future<void> _pump(WidgetTester tester, _RecApi api, Widget screen,
    {Size size = const Size(400, 900)}) async {
  await tester.binding.setSurfaceSize(size);
  final app = AppState()..api = api;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: screen,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

final _identity = SoftwareE2E().generateIdentity();

void main() {
  setUpAll(() async {
    t = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ------------------------------------------------------------ GROUP ⋮
  group('group chat ⋮', () {
    Map<String, Object> base() => {
          '/circle/groups/7/members': {'results': []},
          '/circle/groups/7/messages': {
            'results': [
              {'id': 1, 'sender_id': 2, 'ciphertext': 'Q1Q=', 'nonce': 'Tg=='}
            ]
          },
        };

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byTooltip(t.grpMenuMore));
      await _settle(tester);
    }

    testWidgets('Mute -> 8 hours posts duration and confirms', (tester) async {
      final api = _RecApi({...base(),
        '/circle/groups/7/mute': {'ok': true, 'mute': '8h', 'muted': true}});
      final g = <String, dynamic>{'id': 7, 'name': 'Family', 'mute': 'off'};
      await _pump(tester, api,
          CircleGroupChatScreen(group: g, identity: _identity));
      await openMenu(tester);
      await tester.tap(find.text(t.grpMenuMute));
      await _settle(tester);
      expect(find.text(t.msgGrpUnmute), findsNothing); // not muted yet
      await tester.tap(find.text(t.grpMute8h));
      await _settle(tester);
      expect(api.posted('/circle/groups/7/mute', {'duration': '8h'}), isTrue);
      expect(g['mute'], '8h');
      expect(find.text(t.grpMuted), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('Unmute is offered when muted', (tester) async {
      final api = _RecApi({...base(),
        '/circle/groups/7/mute': {'ok': true, 'mute': 'off', 'muted': false}});
      final g = <String, dynamic>{'id': 7, 'name': 'Family', 'mute': '8h'};
      await _pump(tester, api,
          CircleGroupChatScreen(group: g, identity: _identity));
      await openMenu(tester);
      await tester.tap(find.text(t.grpMenuMute));
      await _settle(tester);
      await tester.tap(find.text(t.msgGrpUnmute));
      await _settle(tester);
      expect(api.posted('/circle/groups/7/mute', {'duration': 'off'}), isTrue);
      expect(find.text(t.msgGrpUnmuted), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('Disappearing -> 7 days', (tester) async {
      final api = _RecApi({...base(),
        '/circle/groups/7/disappearing': {'ok': true, 'disappearing_sec': 604800}});
      final g = <String, dynamic>{'id': 7, 'name': 'Family'};
      await _pump(tester, api,
          CircleGroupChatScreen(group: g, identity: _identity));
      await openMenu(tester);
      await tester.tap(find.text(t.grpMenuDisappearing));
      await _settle(tester);
      await tester.tap(find.text(t.grpDisappear7d));
      await _settle(tester);
      expect(api.posted('/circle/groups/7/disappearing', {'ttl': '7d'}), isTrue);
      expect(g['disappearing'], '7d');
      await _dispose(tester);
    });

    testWidgets('Favourite toggles the menu label', (tester) async {
      final api = _RecApi({...base(),
        '/circle/groups/7/favourite': {'ok': true, 'favourite': true}});
      final g = <String, dynamic>{'id': 7, 'name': 'Family'};
      await _pump(tester, api,
          CircleGroupChatScreen(group: g, identity: _identity));
      await openMenu(tester);
      await tester.tap(find.text(t.grpMenuAddFavourite));
      await _settle(tester);
      expect(api.posted('/circle/groups/7/favourite', {'on': true}), isTrue);
      await openMenu(tester);
      expect(find.text(t.grpMenuRemoveFavourite), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('a server refusal is shown, not a fake "pending"',
        (tester) async {
      final api = _RecApi({...base(),
        '/circle/groups/7/theme': ApiException('bad_color', 400)});
      final g = <String, dynamic>{'id': 7, 'name': 'Family'};
      await _pump(tester, api,
          CircleGroupChatScreen(group: g, identity: _identity));
      await openMenu(tester);
      await tester.tap(find.text(t.grpMenuChatTheme));
      await _settle(tester);
      await tester.tap(find.text(t.grpThemeOcean));
      await _settle(tester);
      expect(find.text('bad_color'), findsOneWidget);
      expect(find.text(t.circleBackendPending), findsNothing);
      expect(g['theme'], isNull);
      await _dispose(tester);
    });

    testWidgets('Clear chat empties the thread after the server confirms',
        (tester) async {
      final api = _RecApi({...base(), '/circle/groups/7/clear': {'ok': true}});
      final g = <String, dynamic>{'id': 7, 'name': 'Family'};
      await _pump(tester, api,
          CircleGroupChatScreen(group: g, identity: _identity));
      await openMenu(tester);
      await tester.ensureVisible(find.text(t.grpMenuClearChat));
      await tester.tap(find.text(t.grpMenuClearChat));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, t.grpMenuClearChat));
      await _settle(tester);
      expect(api.posted('/circle/groups/7/clear'), isTrue);
      await _dispose(tester);
    });

    testWidgets('Exit group: last-admin refusal (403) explains',
        (tester) async {
      final api = _RecApi({...base(),
        '/circle/groups/7/leave': ApiException('promote', 403)});
      final g = <String, dynamic>{'id': 7, 'name': 'Family'};
      await _pump(tester, api,
          CircleGroupChatScreen(group: g, identity: _identity));
      await openMenu(tester);
      await tester.ensureVisible(find.text(t.grpMenuExitGroup));
      await tester.tap(find.text(t.grpMenuExitGroup));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, t.grpMenuExitGroup));
      await _settle(tester);
      expect(find.text(t.grpExitLastAdmin), findsOneWidget);
      await _dispose(tester);
    });
  });

  // ------------------------------------------------------------ 1:1 ⋮
  testWidgets('1:1 ⋮ Clear chat posts the per-user clear', (tester) async {
    final api = _RecApi({
      '/circle/5/messages': {'results': []},
      '/circle/5/settings': {'disappearing_sec': 0},
      '/circle/5/clear': {'ok': true},
      '*': <String, dynamic>{},
    });
    await _pump(
        tester,
        api,
        CircleChatScreen(
            member: const {'id': 5, 'name': 'Bilal', 'public_key': ''},
            identity: _identity),
        size: const Size(400, 2000));
    await tester.tap(find.byTooltip(t.msgrChatMore));
    await _settle(tester);
    await tester.scrollUntilVisible(find.text(t.msgrChatClear), 150,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text(t.msgrChatClear));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, t.msgrChatClear));
    await _settle(tester);
    expect(api.posted('/circle/5/clear'), isTrue);
    await _dispose(tester);
  });

  // ------------------------------------------------------------ contact info
  testWidgets('contact info: real counts, block toggles, no dead tiles',
      (tester) async {
    final api = _RecApi({
      '/circle/5/info': {
        'id': 5, 'media_count': 3, 'link_count': 1, 'doc_count': 0,
        'starred_count': 2, 'groups_in_common': [{'id': 7, 'name': 'Family'}],
        'blocked': false, 'disappearing_sec': 0, 'relation': 'friend',
      },
      '/circle/5/controls': {'ok': true, 'blocked': true},
    });
    await _pump(tester, api,
        const ContactInfoScreen(member: {'id': 5, 'name': 'Bilal'}));
    expect(find.text(t.msgrContactCustomNotif), findsNothing);
    expect(find.text(t.msgrContactChatLock), findsNothing);
    expect(find.text('Family'), findsOneWidget);
    await tester.scrollUntilVisible(find.text(t.circleBlock), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text(t.circleBlock));
    await _settle(tester);
    expect(api.posted('/circle/5/controls', {'blocked': true}), isTrue);
    expect(find.text(t.circleUnblock), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('contact info: load failure shows retry, not a fake profile',
      (tester) async {
    final api = _RecApi({'/circle/5/info': ApiException('down', 503)});
    await _pump(tester, api,
        const ContactInfoScreen(member: {'id': 5, 'name': 'Bilal'}));
    // qa2: a 503 is our server — say so, not "check your connection"
    expect(find.text(t.m3ErrServer), findsOneWidget);
    expect(find.text(t.msgLoadFailed), findsNothing);
    expect(find.text(t.retry), findsOneWidget);
    await _dispose(tester);
  });

  // ------------------------------------------------------------ community ⋮
  testWidgets('community ⋮: alerts item is hidden (f6 no showpieces); Leave refusal',
      (tester) async {
    final api = _RecApi({
      '/community/3/groups': {'joined': [], 'joinable': [],
        'notifications_muted': false},
      '/community/3/leave': {'allowed': false, 'left': false,
        'reason': 'promote_before_leaving'},
    });
    await _pump(
        tester,
        api,
        CommunityDetailScreen(
            community: const {'id': 3, 'name': 'Para', 'viewer_role': 'admin'},
            identity: _identity));
    await tester.tap(find.byTooltip(t.grpMenuMore));
    await _settle(tester);
    expect(find.text(t.msgCommunityAlertsNotYet), findsNothing); // f6: hidden
    expect(find.text(t.communityMuteNotifications), findsNothing);
    await tester.tap(find.text(t.communityLeave).last);
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, t.communityLeave));
    await _settle(tester);
    expect(api.posted('/community/3/leave'), isTrue);
    expect(find.text(t.communityLeaveLastAdmin), findsOneWidget);
    await _dispose(tester);
  });

  // ------------------------------------------------------------ settings
  testWidgets('two-step: turning on sends the PIN to the server only',
      (tester) async {
    final api = _RecApi({
      '/circle/account/two-step': {'enabled': false, 'ok': true},
    });
    await _pump(tester, api, const MsgrSetTwoStepScreen());
    await tester.tap(find.byType(Switch));
    await _settle(tester);
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.text(t.msgrSetSave));
    await _settle(tester);
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.text(t.msgrSetSave));
    await _settle(tester);
    expect(api.posted('/circle/account/two-step',
        {'enabled': true, 'pin': '123456'}), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('msgr_twostep_pin'), isNull); // never on device
    await _dispose(tester);
  });

  testWidgets('change number: no SMS service -> honest disabled state',
      (tester) async {
    final api = _RecApi({
      '/circle/account/change-number': {'sms_enabled': false,
        'two_step_required': false},
    });
    await _pump(tester, api, const MsgrSetChangeNumberScreen());
    expect(find.text(t.msgChangeNumberSmsOff), findsOneWidget);
    expect(find.text(t.msgrSetChangeNumberSendCode), findsNothing);
    await _dispose(tester);
  });

  testWidgets('change number: request -> code step (with PIN field)',
      (tester) async {
    final api = _RecApi({
      '/circle/account/change-number': {'sms_enabled': true,
        'two_step_required': true},
      '/circle/account/change-number/request': {'ok': true, 'sent': true},
    });
    await _pump(tester, api, const MsgrSetChangeNumberScreen());
    await tester.enterText(find.byType(TextField).first, '01799999999');
    await tester.tap(find.text(t.msgrSetChangeNumberSendCode));
    await _settle(tester);
    expect(api.posted('/circle/account/change-number/request',
        {'new_phone': '01799999999'}), isTrue);
    expect(find.text(t.msgTwoStepCurrentPin), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('notifications: toggling Groups posts only that key; in-app '
      'sound rows are hidden (f6 no showpieces)', (tester) async {
    final api = _RecApi({
      '/circle/settings/notifications': {'messages': true, 'groups': true,
        'calls': true, 'show_preview': true, 'ok': true},
    });
    await _pump(tester, api, const MsgrSetNotificationsScreen());
    expect(find.text(t.msgNotifInAppNotYet), findsNothing); // f6: hidden
    expect(find.text(t.msgrSetNotifSound), findsNothing);
    await tester.tap(find.text(t.msgrSetNotifGroups));
    await _settle(tester);
    expect(api.posted('/circle/settings/notifications', {'groups': false}),
        isTrue);
    await _dispose(tester);
  });

  // md1: My Circle media is real now, so the device-level auto-download
  // switches exist (and really change MediaPrefs); the old server-side
  // auto-download section stays gone.
  testWidgets('storage: real usage rows + live md1 auto-download switches',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _RecApi({
      '/circle/settings/storage': {'total_bytes': 5 * 1024 * 1024,
        'quota_bytes': 1024 * 1024 * 1024, 'media_bytes': 0,
        'docs_bytes': 0, 'backup_bytes': 0, 'auto_download': {}},
    });
    await _pump(tester, api, const MsgrSetStorageScreen());
    expect(find.text(t.msgStorageBackups), findsOneWidget);
    expect(find.text(t.msgStorageQuota), findsOneWidget);
    expect(find.text(t.msgrSetStorageAutoDlSection), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(4));
    expect(await MediaPrefs.mobileAuto('photo'), isFalse);
    await tester.tap(find.byKey(const Key('md1-auto-mobile-photo')));
    await tester.pump();
    expect(await MediaPrefs.mobileAuto('photo'), isTrue);
    await _dispose(tester);
  });
}
