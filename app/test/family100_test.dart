// family100: family alerts by server push, on the phone (no plugins):
// a tapped SOS / family-alert push opens the Family alerts screen, the
// receipt ack posts the delivery id, the notifications-off banner, empty /
// error / retry states, "I've seen it", the sender's per-member statuses,
// "I'm safe now", bn digits + bn/en strings, dark mode, 48dp targets.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/family_alert_receipt.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/family_alerts_screen.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/family_push_banner.dart';

Widget _app(Widget child, {String lang = 'en', bool dark = false}) =>
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
      home: child,
    );

Map<String, dynamic> _sosRow({bool seen = false}) => {
      'id': 41,
      'kind': 'sos',
      'at': DateTime.now().toIso8601String(),
      'title': 'SOS: Rina needs help',
      'body': 'Call them now.',
      'from_name': 'Rina',
      'lat': 23.75,
      'lng': 90.39,
      'seen': seen,
      'status': 'sent',
      'active': true,
    };

void main() {
  group('push deep link', () {
    PushTarget? go(Map<String, String> d) =>
        PushRouting.targetFor(PushPayload.fromData(d));

    test('SOS and family alerts open the Family alerts screen', () {
      expect(go({'kind': 'sos', 'route': 'safety/sos'})!.chatNavRoute,
          'family_alerts');
      expect(go({'kind': 'family_alert', 'route': 'family/alerts'})!
          .chatNavRoute, 'family_alerts');
      expect(go({'kind': 'sos'})!.chatNavRoute, 'family_alerts');
      expect(go({'kind': 'family_alert', 'route': 'security/lost-phone'})!
          .chatNavRoute, 'my_lost_phone');
      expect(ChatNav.builderFor('family_alerts'), isNotNull);
    });

    test('an SOS always takes over the screen on the family phone', () {
      final p = PushPayload.fromData(
          {'kind': 'sos', 'silent': 'false', 'duress': 'true'});
      expect(p.wantsFullScreen, isTrue);
      expect(p.silent, isFalse);
      expect(p.channel, PushChannels.sos);
    });
  });

  group('receipt ack', () {
    test('delivery id only for family kinds', () {
      expect(familyDeliveryId({'kind': 'sos', 'delivery_id': '7'}), 7);
      expect(familyDeliveryId({'kind': 'family_alert', 'delivery_id': 9}), 9);
      expect(familyDeliveryId({'kind': 'message', 'delivery_id': '7'}), isNull);
      expect(familyDeliveryId({'kind': 'sos', 'delivery_id': ''}), isNull);
    });

    test('posts the id with the stored token', () async {
      http.Request? got;
      final c = MockClient((r) async {
        got = r;
        return http.Response('{"ok":true,"updated":1}', 200);
      });
      final ok = await ackFamilyAlertReceipt(
          {'kind': 'sos', 'delivery_id': '12'},
          token: () async => 'tok', client: c);
      expect(ok, isTrue);
      expect(got!.url.path, endsWith('/family/alerts/received'));
      expect(jsonDecode(got!.body), {
        'ids': [12]
      });
      expect(got!.headers['Authorization'], 'Token tok');
    });

    test('no token / offline never throws', () async {
      final c = MockClient((r) async => throw Exception('offline'));
      expect(
          await ackFamilyAlertReceipt({'kind': 'sos', 'delivery_id': '1'},
              token: () async => null, client: c),
          isFalse);
      expect(
          await ackFamilyAlertReceipt({'kind': 'sos', 'delivery_id': '1'},
              token: () async => 't', client: c),
          isFalse);
    });
  });

  group('Family alerts screen', () {
    testWidgets('empty state (en) with notifications on: no banner',
        (t) async {
      await t.pumpWidget(_app(FamilyAlertsScreen(
          load: () async => {'received': [], 'sent': [], 'unseen': 0},
          pushEnabled: () async => true)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('fa100-empty')), findsOneWidget);
      expect(find.text('Family alerts'), findsOneWidget);
      expect(find.byKey(const ValueKey('fa100-push-off')), findsNothing);
    });

    testWidgets('notifications off -> honest banner with Turn on + guide',
        (t) async {
      await t.pumpWidget(_app(FamilyAlertsScreen(
          load: () async => {'received': [], 'sent': []},
          pushEnabled: () async => false)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('fa100-push-off')), findsOneWidget);
      expect(find.text('Turn on'), findsOneWidget);
      expect(find.textContaining('Battery settings guide'), findsOneWidget);
    });

    testWidgets('banner Turn on re-checks and hides once allowed', (t) async {
      var on = false;
      await t.pumpWidget(_app(Scaffold(
          body: FamilyPushBanner(
              isEnabled: () async => on,
              request: () async {
                on = true;
                return true;
              }))));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('fa100-push-off')), findsOneWidget);
      await t.tap(find.text('Turn on'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('fa100-push-off')), findsNothing);
    });

    testWidgets('error -> retry loads', (t) async {
      var calls = 0;
      await t.pumpWidget(_app(FamilyAlertsScreen(
          load: () async {
            calls++;
            if (calls == 1) throw Exception('offline');
            return {'received': [], 'sent': []};
          },
          pushEnabled: () async => true)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('fa100-error')), findsOneWidget);
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('fa100-empty')), findsOneWidget);
    });

    testWidgets('SOS card: map + I\'ve seen it marks seen', (t) async {
      final seen = <int>[];
      await t.pumpWidget(_app(FamilyAlertsScreen(
          load: () async => {
                'received': [_sosRow()],
                'sent': []
              },
          seen: (id) async => seen.add(id),
          pushEnabled: () async => true)));
      await t.pumpAndSettle();
      expect(find.text('SOS: Rina needs help'), findsOneWidget);
      expect(find.text('See on map'), findsOneWidget);
      final btn = find.byKey(const ValueKey('fa100-seen-41'));
      expect(t.getSize(btn).height, greaterThanOrEqualTo(48));
      await t.tap(btn);
      await t.pumpAndSettle();
      expect(seen, [41]);
      expect(find.text('Seen'), findsOneWidget);
    });

    testWidgets('sender sees each member\'s status + I\'m safe now',
        (t) async {
      var resolved = 0;
      await t.pumpWidget(_app(FamilyAlertsScreen(
          load: () async => {
                'received': [],
                'sent': [
                  {
                    'kind': 'sos',
                    'at': DateTime.now().toIso8601String(),
                    'recipients': [
                      {'name': 'Mother', 'status': 'sent', 'seen': true},
                      {'name': 'Brother', 'status': 'no_device'},
                      {'name': 'Aunt', 'status': 'sent', 'received': true},
                    ]
                  }
                ]
              },
          resolve: () async {
            resolved++;
            return {'ok': true};
          },
          pushEnabled: () async => true)));
      await t.pumpAndSettle();
      expect(find.text('Mother: seen'), findsOneWidget);
      expect(find.textContaining('Brother: no notification'), findsOneWidget);
      expect(find.text('Aunt: reached the phone'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('fa100-safe-now')));
      await t.pumpAndSettle();
      expect(resolved, 1);
      expect(find.text('Your family has been told you are safe.'),
          findsOneWidget);
    });

    testWidgets('Bangla: only Bangla strings, dark mode renders', (t) async {
      await t.pumpWidget(_app(
          FamilyAlertsScreen(
              load: () async => {
                    'received': [_sosRow(seen: true)],
                    'sent': []
                  },
              pushEnabled: () async => false),
          lang: 'bn',
          dark: true));
      await t.pumpAndSettle();
      expect(find.text('পরিবারের সতর্কতা'), findsOneWidget);
      expect(find.text('জরুরি ডাক'), findsOneWidget);
      expect(find.text('দেখা হয়েছে'), findsOneWidget);
      expect(find.text('চালু করুন'), findsOneWidget);
      expect(find.text('Family alerts'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('TalkBack: section headers are headers', (t) async {
      final h = t.ensureSemantics();
      await t.pumpWidget(_app(FamilyAlertsScreen(
          load: () async => {
                'received': [_sosRow()],
                'sent': []
              },
          pushEnabled: () async => true)));
      await t.pumpAndSettle();
      expect(
          t.getSemantics(find.text('Alerts for you')),
          containsSemantics(isHeader: true));
      h.dispose();
    });
  });
}
