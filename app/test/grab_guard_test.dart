import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/services/own_device_guard.dart';
import 'package:assisto/widgets/grab_check_dialog.dart';

/// grab-guard (owner 25 Oct): the owner's own phone never shows an anti-theft
/// alert about itself; a grab on it asks "Was this you?" (Security PIN).
void main() {
  group('OwnDeviceGuard.isOwn', () {
    test('push about my own phone (owner_id == me) is dropped', () {
      final d = {
        'kind': 'family_alert',
        'alert_kind': 'antitheft',
        'antitheft_kind': 'snatch',
        'phone_id': '9',
        'owner_id': '42',
      };
      expect(OwnDeviceGuard.isOwn(d, me: 42), isTrue);
      expect(OwnDeviceGuard.isOwn(d, me: 7), isFalse); // family member: shows
    });

    test('my protected phone id matches even without owner_id', () {
      final d = {'alert_kind': 'antitheft', 'antitheft_kind': 'low_battery',
        'phone_id': '9'};
      expect(OwnDeviceGuard.isOwn(d, me: 1, phoneIds: {9}), isTrue);
      expect(OwnDeviceGuard.isOwn(d, me: 1, phoneIds: {3}), isFalse);
    });

    test('the owner-only test alarm and non-antitheft pushes still show', () {
      expect(
          OwnDeviceGuard.isOwn(
              {'alert_kind': 'antitheft', 'antitheft_kind': 'test',
                'owner_id': 42},
              me: 42),
          isFalse);
      expect(
          OwnDeviceGuard.isOwn(
              {'kind': 'family_alert', 'owner_id': 42}, me: 42),
          isFalse);
      expect(OwnDeviceGuard.isOwn({'kind': 'message'}, me: 42), isFalse);
    });

    test('/alerts rows (type antitheft, own_device flag)', () {
      expect(
          OwnDeviceGuard.isOwn(
              {'type': 'antitheft', 'kind': 'offline', 'owner_id': 42},
              me: 42),
          isTrue);
      expect(
          OwnDeviceGuard.isOwn(
              {'type': 'antitheft', 'kind': 'offline', 'own_device': true},
              me: null),
          isTrue);
    });
  });

  group('OwnDeviceGuard store', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      OwnDeviceGuard.resetForTest();
    });

    test('background isolate reads the stored ids', () async {
      await OwnDeviceGuard.rememberUser(42);
      await OwnDeviceGuard.rememberPhone(9);
      OwnDeviceGuard.resetForTest(); // fresh isolate: nothing in memory
      expect(
          await OwnDeviceGuard.isOwnPush(
              {'alert_kind': 'antitheft', 'antitheft_kind': 'snatch',
                'phone_id': '9'}),
          isTrue);
      expect(
          await OwnDeviceGuard.isOwnPush(
              {'alert_kind': 'antitheft', 'antitheft_kind': 'snatch',
                'owner_id': '42'}),
          isTrue);
      expect(await OwnDeviceGuard.isOwnPush({'kind': 'reminder'}), isFalse);
    });

    test('filterAlerts drops only my own phone rows', () async {
      await OwnDeviceGuard.rememberUser(42);
      final rows = <Map<String, dynamic>>[
        {'type': 'antitheft', 'kind': 'low_battery', 'owner_id': 42},
        {'type': 'antitheft', 'kind': 'snatch', 'owner_id': 7},
        {'type': 'bill', 'text': 'Electricity due'},
      ];
      final out = await OwnDeviceGuard.filterAlerts(rows);
      expect(out.length, 2);
      expect(out.any((r) => r['owner_id'] == 42), isFalse);
    });

    test('signing out / another account forgets the phones', () async {
      await OwnDeviceGuard.rememberUser(42);
      await OwnDeviceGuard.rememberPhone(9);
      await OwnDeviceGuard.rememberUser(43); // different account
      OwnDeviceGuard.resetForTest();
      expect(
          await OwnDeviceGuard.isOwnPush(
              {'alert_kind': 'antitheft', 'antitheft_kind': 'x',
                'phone_id': '9'}),
          isFalse);
      await OwnDeviceGuard.forget();
      expect(
          await OwnDeviceGuard.isOwnPush(
              {'alert_kind': 'antitheft', 'antitheft_kind': 'x',
                'owner_id': '43'}),
          isFalse);
    });
  });

  group('GrabCheck dialog', () {
    late int? pendingMs;
    late int cancels;
    late int sendNows;
    late List<String> sentPins;
    late List<String> escalations;

    setUp(() {
      GrabCheck.resetForTest();
      pendingMs = 42000;
      cancels = 0;
      sendNows = 0;
      sentPins = [];
      escalations = [];
      GrabCheck.pending = () async => pendingMs;
      GrabCheck.cancelNative = () async {
        cancels++;
        return true;
      };
      GrabCheck.sendNow = () async => sendNows++;
    });

    Future<void> open(WidgetTester tester, String lang,
        Map<String, dynamic> reply) async {
      await tester.pumpWidget(MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => GrabCheck.maybeShow(ctx,
                  askPin: (_) async => '1234',
                  send: (pin) async {
                    sentPins.add(pin);
                    return reply;
                  },
                  escalate: (r) async {
                    escalations.add(r);
                    return {'ok': true};
                  }),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    for (final lang in ['en', 'bn']) {
      testWidgets('$lang: "I\'m OK" + PIN drops the held grab',
          (tester) async {
        await open(tester, lang, {'ok': true, 'cleared': 0});
        final tr = lookupAppLocalizations(Locale(lang));
        // antitheft2: "Are you OK? / আপনি ঠিক আছেন?"
        expect(find.text(tr.at2OkTitle), findsOneWidget);
        expect(find.text(tr.at2OkBody), findsOneWidget);
        await tester.tap(find.byKey(const Key('grab-yes')));
        await tester.pumpAndSettle();
        expect(sentPins, ['1234']);
        expect(cancels, 1);
        expect(sendNows, 0);
        expect(escalations, isEmpty);
        expect(find.text(tr.grabCleared), findsOneWidget);
      });
    }

    testWidgets('wrong PIN: never dropped, owner told it escalates',
        (tester) async {
      await open(tester, 'en', {'_status': 403, 'reason': 'bad_pin'});
      await tester.tap(find.byKey(const Key('grab-yes')));
      await tester.pumpAndSettle();
      expect(cancels, 0);
      final tr = lookupAppLocalizations(const Locale('en'));
      // the SERVER escalates a held grab on a wrong PIN
      expect(find.text(tr.at2OkWrongPin), findsOneWidget);
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('$lang: "I need help" escalates at once', (tester) async {
        await open(tester, lang, {'ok': true});
        final tr = lookupAppLocalizations(Locale(lang));
        expect(find.text(tr.at2OkNo), findsOneWidget);
        await tester.tap(find.byKey(const Key('grab-no')));
        await tester.pumpAndSettle();
        expect(sendNows, 1);
        expect(escalations, ['not_ok']);
        expect(cancels, 0);
        expect(sentPins, isEmpty);
        expect(find.text(tr.at2OkSent), findsOneWidget);
      });
    }

    testWidgets('dialog buttons are at least 48 dp tall', (tester) async {
      await open(tester, 'en', {'ok': true});
      expect(tester.getSize(find.byKey(const Key('grab-yes'))).height,
          greaterThanOrEqualTo(48));
      expect(tester.getSize(find.byKey(const Key('grab-no'))).height,
          greaterThanOrEqualTo(48));
    });

    testWidgets('nothing pending -> no dialog', (tester) async {
      pendingMs = null;
      await open(tester, 'en', {'ok': true});
      final tr = lookupAppLocalizations(const Locale('en'));
      expect(find.text(tr.at2OkTitle), findsNothing);
    });
  });
}
