// callmoney — AFTER CALL NOTE + MONEY FROM NOTIFICATIONS.
// Parser (many real-format samples written for Assisto, no real user data),
// allow-list (Dart == Kotlin), consent gating, confirm-before-write and the
// no-recording / no-READ_SMS guarantees.
import 'dart:io';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/notiflisten/callmoney_screens.dart';
import 'package:assisto/notiflisten/callnote_drafts.dart';
import 'package:assisto/notiflisten/money_notif_parser.dart';
import 'package:assisto/notiflisten/notif_allow_list.dart';
import 'package:assisto/notiflisten/notif_listen_channel.dart';
import 'package:assisto/notiflisten/notif_listen_service.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'callmoney_fake.dart';
import 'fake_api.dart' show FakeMode;
import 'screenshots_test.dart' as gallery;

const _kt = 'android_overlay/app/src/main/kotlin/com/assisto/assisto/notiflisten';

typedef _S = ({String wallet, String text, String? type, num? amount, String? who, String? trx});

final List<_S> _samples = [
  // ---- bKash, English
  (wallet: 'bkash', text: 'You have received Tk 1,500.00 from 01712345678. Fee Tk 0.00. Balance Tk 3,250.50. TrxID BK7Q2M9XAA at 03/11/2026 14:22', type: 'income', amount: 1500, who: '01712345678', trx: 'BK7Q2M9XAA'),
  (wallet: 'bkash', text: 'Cash Out Tk 1,000.00 to 01812345678 successful. Fee Tk 18.50. Balance Tk 231.50. TrxID AB12CD34EF at 03/11/2026 10:05', type: 'expense', amount: 1000, who: '01812345678', trx: 'AB12CD34EF'),
  (wallet: 'bkash', text: 'Send Money Tk 300.00 to 01912345678 successful. Ref rent. Fee Tk 5.00. Balance Tk 945.00. TrxID 8HG5FD3SA1 at 02/11/2026 20:11', type: 'expense', amount: 300, who: '01912345678', trx: '8HG5FD3SA1'),
  (wallet: 'bkash', text: 'Payment Tk 1,200.00 to Shwapno (01700000000) successful. Balance Tk 2,300.00. TrxID 7AB3CD9EFG at 02/11/2026 18:40', type: 'expense', amount: 1200, who: 'Shwapno', trx: '7AB3CD9EFG'),
  (wallet: 'bkash', text: 'Cash In Tk 2,000.00 from 01611111111 successful. Fee Tk 0.00. Balance Tk 2,500.00. TrxID 6CI8DD1XYZ at 01/11/2026 09:00', type: 'income', amount: 2000, who: '01611111111', trx: '6CI8DD1XYZ'),
  (wallet: 'bkash', text: 'Mobile Recharge Tk 50.00 to 01711111111 successful. Balance Tk 950.00. TrxID 9RC1234ABC', type: 'expense', amount: 50, who: '01711111111', trx: '9RC1234ABC'),
  (wallet: 'bkash', text: 'Cashback Tk 10.00 received for Payment to Daraz. Balance Tk 510.00. TrxID 5CB2KK8QWE', type: 'income', amount: 10, who: 'Daraz', trx: '5CB2KK8QWE'),
  (wallet: 'bkash', text: 'Bill successfully paid. Biller: DESCO Postpaid Amount: Tk 1,050.00 Fee: Tk 0.00 TrxID 4BL7NN2RTY Balance Tk 940.00', type: 'expense', amount: 1050, who: 'DESCO Postpaid', trx: '4BL7NN2RTY'),
  // ---- bKash, Bangla
  (wallet: 'bkash', text: 'আপনি ০১৭১২৩৪৫৬৭৮ থেকে ৳৫০০.০০ পেয়েছেন। ফি ৳০.০০। ব্যালেন্স ৳১,২৫০.৫০। TrxID 9JK7AB12CD ০৩/১১/২০২৬ ১৪:২২', type: 'income', amount: 500, who: '01712345678', trx: '9JK7AB12CD'),
  (wallet: 'bkash', text: 'ক্যাশ আউট ৳১,০০০.০০ সফল। ফি ৳১৮.৫০। ব্যালেন্স ৳২৩১.৫০। TrxID AB12CD34EF', type: 'expense', amount: 1000, who: null, trx: 'AB12CD34EF'),
  (wallet: 'bkash', text: 'সেন্ড মানি ৳৩০০.০০ ০১৯১২৩৪৫৬৭৮ নম্বরে সফল হয়েছে। ফি ৳৫.০০। ব্যালেন্স ৳৯৪৫.০০। TrxID 8HG5FD3SA1', type: 'expense', amount: 300, who: '01912345678', trx: '8HG5FD3SA1'),
  (wallet: 'bkash', text: 'পেমেন্ট ৳৮৫০ সফল। ব্যালেন্স ৳১,১৫০। TrxID 3PM9QQ1ZZA', type: 'expense', amount: 850, who: null, trx: '3PM9QQ1ZZA'),
  // ---- Nagad, English + Bangla
  (wallet: 'nagad', text: 'Money Received. Amount: Tk 750.00 Sender: 01712345678 Ref: N/A TxnID: 71ABCD12 Balance: Tk 1,500.00 03/11/2026 09:30', type: 'income', amount: 750, who: '01712345678', trx: '71ABCD12'),
  (wallet: 'nagad', text: 'Cash Out Successful. Amount: Tk 2,000.00 Agent: 01812345678 Charge: Tk 25.00 TxnID: 71NG3K2PQ Balance: Tk 480.00 03/11/2026 10:05', type: 'expense', amount: 2000, who: '01812345678', trx: '71NG3K2PQ'),
  (wallet: 'nagad', text: 'Send Money Successful. Amount: Tk 400.00 Receiver: 01987654321 TxnID: 72SM9P1QR Balance: Tk 1,100.00', type: 'expense', amount: 400, who: '01987654321', trx: '72SM9P1QR'),
  (wallet: 'nagad', text: 'টাকা গ্রহণ সফল। পরিমাণ: ৳৭৫০.০০ প্রেরক: ০১৭১২৩৪৫৬৭৮ TxnID: 71ABCD12 ব্যালেন্স: ৳১,৫০০.০০', type: 'income', amount: 750, who: '01712345678', trx: '71ABCD12'),
  // ---- Rocket (DBBL)
  (wallet: 'rocket', text: 'Tk500.00 received from A/C:01712345678-5 Fee:Tk0.00, Your A/C Balance: Tk1,250.00 TxnId:1234567890 Date:03-NOV-26 02:22:34 pm.', type: 'income', amount: 500, who: '01712345678', trx: '1234567890'),
  (wallet: 'rocket', text: 'Tk1,000.00 sent to A/C:01812345678-3 successfully. Fee:Tk5.00, Your A/C Balance: Tk250.00 TxnId:2234567891 Date:03-NOV-26 11:02:10 am.', type: 'expense', amount: 1000, who: '01812345678', trx: '2234567891'),
  // ---- Upay
  (wallet: 'upay', text: 'Payment of Tk 320.00 to Bashundhara Gas successful. TrxID UP93KD02LL. Balance Tk 1,180.00', type: 'expense', amount: 320, who: 'Bashundhara Gas', trx: 'UP93KD02LL'),
  // ---- banks
  (wallet: 'bank', text: 'Dear Customer, your A/C XXXX1234 has been debited by BDT 850.00 on 02-Nov-2026 (POS purchase at SHWAPNO). Available Balance BDT 20,150.00', type: 'expense', amount: 850, who: 'SHWAPNO', trx: null),
  (wallet: 'bank', text: 'Your A/C ****5678 is credited with BDT 45,000.00 on 01-11-2026 for SALARY. Avl Bal: BDT 60,500.00', type: 'income', amount: 45000, who: null, trx: null),
  (wallet: 'bank', text: 'BDT 2,500.00 withdrawn from A/C ...1234 by ATM on 02-NOV-26. Bal BDT 7,500.00', type: 'expense', amount: 2500, who: null, trx: null),
  (wallet: 'bank', text: 'আপনার হিসাব ...১২৩৪ এ ৳১০,০০০.০০ জমা হয়েছে। ব্যালেন্স ৳২৫,০০০.০০', type: 'income', amount: 10000, who: null, trx: null),
  (wallet: 'bank', text: 'আপনার হিসাব ...১২৩৪ থেকে ৳৫,০০০.০০ উত্তোলন করা হয়েছে। ব্যালেন্স ৳২০,০০০.০০', type: 'expense', amount: 5000, who: null, trx: null),
];

Future<void> _pump(WidgetTester tester, Widget w) async {
  final app = gallery.galleryStub(lang: 'en', mode: FakeMode.data);
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
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
      theme: AssistoTheme.light,
      home: Scaffold(body: w),
    ),
  ));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('money parser (on the phone, bn + en)', () {
    for (final s in _samples) {
      test('${s.wallet}: ${s.text.substring(0, 28)}', () {
        final p = MoneyNotifParser.parse(s.text, wallet: s.wallet, postedAt: DateTime(2026, 11, 3));
        expect(p.ok, isTrue, reason: p.reason);
        expect(p.type, s.type);
        expect(p.amount, s.amount);
        expect(p.counterparty, s.who);
        expect(p.trxId, s.trx);
        expect(p.wallet, s.wallet);
      });
    }

    test('fee and balance are never taken as the amount', () {
      final p = MoneyNotifParser.parse(
          'Cash Out Tk 18.50 to 01812345678 successful. Fee Tk 18.50. Balance Tk 18.50. TrxID ZZ12CD34EF',
          wallet: 'bkash');
      expect(p.amount, 18.5);
      expect(p.fee, 18.5);
      expect(p.balance, 18.5);
    });

    test('"Recharge" is not a fee (owner-style regression)', () {
      final p = MoneyNotifParser.parse('Mobile Recharge Tk 50.00 to 01711111111 successful. Balance Tk 950.00. TrxID 9RC1234ABC', wallet: 'bkash');
      expect(p.amount, 50);
      expect(p.fee, isNull);
    });

    test('dates: dd/mm/yyyy, dd-MMM-yy pm, else the post time', () {
      expect(MoneyNotifParser.parse(_samples[0].text, wallet: 'bkash').date, DateTime(2026, 11, 3, 14, 22));
      expect(MoneyNotifParser.parse(_samples[16].text, wallet: 'rocket').date, DateTime(2026, 11, 3, 14, 22));
      final at = DateTime(2026, 11, 4, 8);
      expect(MoneyNotifParser.parse(_samples[5].text, wallet: 'bkash', postedAt: at).date, at);
    });

    test('OTP / PIN / promotions / no proof are NEVER a transaction', () {
      final cases = {
        'Your bKash verification code is 482913. Never share it with anyone.': 'otp',
        'আপনার বিকাশ যাচাই কোড ৪৮২৯১৩। কাউকে বলবেন না।': 'otp',
        'Your Nagad PIN has been changed successfully.': 'otp',
        'Get 10% cashback up to Tk 50 on payment at Daraz with bKash! T&C apply.': 'promo',
        'বিকাশে পেমেন্ট করে ৫০ টাকা পর্যন্ত ক্যাশব্যাক জিতুন! অফার চলবে ৩০ নভেম্বর পর্যন্ত।': 'promo',
        'Dear customer, Tk 500 will be charged for card renewal next month.': 'no_proof',
        'Your A/C XXXX1234 statement for October is ready.': 'no_amount',
        '': 'empty',
      };
      cases.forEach((text, why) {
        final p = MoneyNotifParser.parse(text, wallet: 'bkash');
        expect(p.ok, isFalse, reason: text);
        expect(p.reason, why, reason: text);
      });
    });

    test('the SMS and the wallet-app notification of one payment dedupe', () {
      final a = MoneyNotifParser.parse(_samples[0].text, wallet: 'bkash');
      final b = MoneyNotifParser.parse(
          'Received Tk 1,500.00 from 01712345678. TrxID BK7Q2M9XAA. Balance Tk 3,250.50', wallet: 'bkash');
      expect(a.dedupeKey, b.dedupeKey);
    });
  });

  group('allow-list (only these are ever read)', () {
    test('wallet/bank apps and allowed SMS senders only', () {
      expect(NotifAllowList.moneyWalletFor('com.bKash.customerapp'), 'bkash');
      expect(NotifAllowList.moneyWalletFor('com.konasl.nagad'), 'nagad');
      expect(NotifAllowList.moneyWalletFor('com.dbbl.mbs.apps.main'), 'rocket');
      const sms = 'com.google.android.apps.messaging';
      expect(NotifAllowList.moneyWalletFor(sms, defaultSms: sms, smsTitle: 'bKash'), 'bkash');
      expect(NotifAllowList.moneyWalletFor(sms, defaultSms: sms, smsTitle: 'NAGAD'), 'nagad');
      expect(NotifAllowList.moneyWalletFor(sms, defaultSms: sms, smsTitle: '16216'), 'rocket');
      expect(NotifAllowList.moneyWalletFor(sms, defaultSms: sms, smsTitle: 'BRAC-BANK'), 'bank');
      // a person's SMS, a saved contact name, a phone number: never read
      expect(NotifAllowList.moneyWalletFor(sms, defaultSms: sms, smsTitle: 'Rahim Bhai'), isNull);
      expect(NotifAllowList.moneyWalletFor(sms, defaultSms: sms, smsTitle: '+8801712345678'), isNull);
      expect(NotifAllowList.moneyWalletFor(sms, defaultSms: sms, smsTitle: 'bKash Agent Karim'), isNull);
      // a non-default SMS app and every other app: ignored unread
      expect(NotifAllowList.moneyWalletFor(sms, defaultSms: 'com.other.sms', smsTitle: 'bKash'), isNull);
      for (final pkg in ['com.whatsapp', 'com.facebook.orca', 'com.facebook.katana', 'com.google.android.gm', 'com.imo.android.imoim']) {
        expect(NotifAllowList.moneyWalletFor(pkg, defaultSms: sms, smsTitle: 'bKash'), isNull, reason: pkg);
      }
    });

    test('calls: SIM dialers, WhatsApp, Messenger only', () {
      expect(NotifAllowList.callSource('com.whatsapp'), 'whatsapp');
      expect(NotifAllowList.callSource('com.facebook.orca'), 'messenger');
      expect(NotifAllowList.callSource('com.google.android.dialer'), 'sim');
      expect(NotifAllowList.callSource('com.realme.phone', defaultDialer: 'com.realme.phone'), 'sim');
      expect(NotifAllowList.callSource('com.bKash.customerapp'), isNull);
      expect(NotifAllowList.callSource('com.imo.android.imoim'), isNull);
    });

    Map<String, String> ktMap(String src, String name) {
      final start = src.indexOf('val $name');
      final end = src.indexOf(')\n', start);
      return {
        for (final m in RegExp(r'"([^"]+)" to "([^"]+)"').allMatches(src.substring(start, end)))
          m.group(1)!: m.group(2)!
      };
    }

    test('Kotlin gate == Dart mirror (no drift)', () {
      final kt = File('$_kt/NotifAllow.kt').readAsStringSync();
      expect(ktMap(kt, 'MONEY_APPS'), NotifAllowList.moneyApps);
      expect(ktMap(kt, 'MONEY_SMS_SENDERS'), NotifAllowList.moneySmsSenders);
      expect(ktMap(kt, 'VOIP_CALL_APPS'), NotifAllowList.voipCallApps);
      final s = kt.indexOf('val DIALER_APPS');
      final dial = RegExp(r'"([^"]+)"').allMatches(kt.substring(s, kt.indexOf(')\n', s))).map((m) => m.group(1)!).toSet();
      expect(dial, NotifAllowList.dialerApps);
    });

    test('native listener: content read only AFTER the allow-list, calls by flags only', () {
      final k = File('$_kt/AssistoNotifListener.kt').readAsStringSync();
      final read = k.indexOf('private fun readMoney');
      final comp = k.indexOf('companion object');
      for (final x in ['EXTRA_TEXT', 'EXTRA_BIG_TEXT', 'EXTRA_TITLE']) {
        for (final m in RegExp(x).allMatches(k)) {
          expect(m.start > read && m.start < comp, isTrue, reason: '$x read outside readMoney');
        }
      }
      final body = k.substring(read, comp);
      expect(body.indexOf('smsSenderWallet(title) ?: return') < body.indexOf('EXTRA_BIG_TEXT'), isTrue);
      final posted = k.substring(k.indexOf('private fun handlePosted'), k.indexOf('// ---------------------------------------------------------------- calls'));
      expect(posted.indexOf('anyOn(ctx)) return') < posted.indexOf('moneyPackageKind('), isTrue);
      expect(posted.indexOf('moneyPackageKind(') < posted.indexOf('readMoney('), isTrue);
      // every callback is crash-guarded
      expect(RegExp(r'onNotificationPosted\(sbn: StatusBarNotification\?\) \{\s*try \{').hasMatch(k), isTrue);
      expect(RegExp(r'onNotificationRemoved\(sbn: StatusBarNotification\?\) \{\s*try \{').hasMatch(k), isTrue);
    });
  });

  group('no recording, no READ_SMS, no READ_PHONE_STATE', () {
    test('no audio capture anywhere in the feature', () {
      final files = [
        ...Directory(_kt).listSync().whereType<File>(),
        ...Directory('lib/notiflisten').listSync().whereType<File>(),
      ];
      expect(files.length, greaterThanOrEqualTo(8));
      for (final f in files) {
        final s = f.readAsStringSync();
        for (final bad in ['MediaRecorder', 'AudioRecord', 'RECORD_AUDIO', 'startRecording', 'package:record/']) {
          expect(s.contains(bad), isFalse, reason: '${f.path} uses $bad');
        }
      }
    });

    test('the manifest block adds the listener service and NO permission', () {
      final ci = File('../.github/workflows/android.yml').readAsStringSync();
      final b = ci.substring(ci.indexOf('# ---- callmoney ----'), ci.indexOf('# ---- /callmoney ----'));
      expect(b, contains('android.permission.BIND_NOTIFICATION_LISTENER_SERVICE'));
      expect(b, contains('notiflisten.AssistoNotifListener'));
      expect(b.contains('uses-permission'), isFalse);
      final play = ci.substring(ci.indexOf('Build + sign release AAB (Google Play)'));
      for (final p in ['READ_SMS', 'RECEIVE_SMS', 'READ_PHONE_STATE', 'READ_CALL_LOG']) {
        expect(play, contains(p), reason: 'Play gate still forbids $p');
      }
    });
  });

  group('consent gating', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a switch stays OFF until its disclosure was agreed', () async {
      final fake = FakeNotifBridge();
      NotifListenChannel.instance = fake;
      final t = lookupAppLocalizations(const Locale('en'));
      var r = await NotifListenService.apply(t, 'en', callNote: true, money: true, auto: true);
      expect((r.callNote, r.money, r.auto), (false, false, false));
      expect(fake.configs.last['money'], isFalse);
      await NotifListenService.recordConsent(NotifListenPrefs.consentMoney, true);
      r = await NotifListenService.apply(t, 'en', callNote: true, money: true, auto: true);
      expect((r.callNote, r.money, r.auto), (false, true, true));
      await NotifListenService.recordConsent(NotifListenPrefs.consentCall, true);
      r = await NotifListenService.apply(t, 'en', callNote: true, money: false, auto: true);
      expect((r.callNote, r.money, r.auto), (true, false, false)); // auto needs money
      expect(fake.configs.last['strings']['callTitle'], t.clnCallEndedTitle);
    });

    testWidgets('turning a switch on opens the disclosure first', (tester) async {
      NotifListenChannel.instance = FakeNotifBridge();
      await _pump(tester, const CallMoneySettingsScreen());
      await tester.tap(find.byKey(const ValueKey('cmn_switch_money')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cmn_consent_money')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cmn_decline_money')));
      await tester.pumpAndSettle();
      expect((await NotifListenService.load()).money, isFalse);
    });

    test('auto-save does nothing unless the user turned it on', () async {
      final fake = FakeNotifBridge(queue: fakeMoneyQueue());
      NotifListenChannel.instance = fake;
      final app = gallery.galleryStub(lang: 'en');
      final t = lookupAppLocalizations(const Locale('en'));
      expect(await NotifListenService.autoSave(app, t), 0);
      expect(fake.done, isEmpty);
      expect(fake.queue.length, 3);
    });
  });

  group('confirm before write', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('the khata row carries parsed fields only, never the message', () {
      final p = MoneyNotifParser.parse(_samples[0].text, wallet: 'bkash');
      final row = NotifListenService.txnPayload(p, 7, 'income', 'bKash');
      expect(row.keys.toSet(), {'account', 'kind', 'amount', 'category', 'note', 'date', 'source', 'ref'});
      expect(row.values.any((v) => '$v'.contains('Balance')), isFalse);
      expect(row['ref'], 'BK7Q2M9XAA');
      expect(row['source'], 'notification');
    });

    testWidgets('call note: nothing is written until Confirm', (tester) async {
      final writes = <CallNoteDraft>[];
      await _pump(
          tester,
          CallNoteSheet(
              launch: const NotifLaunch(kind: 'callnote', mode: 'type', source: 'sim'),
              offline: true,
              writer: (d) async => writes.add(d)));
      expect(find.text('This call was not recorded.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('cmn_callnote_text')), 'Rahim will pay 500 taka tomorrow at 5 pm');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cmn_callnote_go')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cmn_draft_0')), findsOneWidget); // due
      expect(find.byKey(const ValueKey('cmn_draft_1')), findsOneWidget); // reminder
      expect(writes, isEmpty);
      // a due without a person cannot be confirmed
      final ok0 = tester.widget<FilledButton>(find.byKey(const ValueKey('cmn_draft_ok_0')));
      expect(ok0.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('cmn_draft_skip_0')));
      await tester.pump();
      expect(writes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('cmn_draft_ok_1')));
      await tester.pumpAndSettle();
      expect(writes.length, 1);
      expect(writes.single.kind, CallNoteKind.reminder);
    });

    test('on-device fallback: due / reminder / note, Bangla too', () {
      final now = DateTime(2026, 11, 3, 10);
      var d = CallNoteUnderstand.onDevice('রহিম কাল ৫০০ টাকা দেবে', now: now);
      expect(d.first.kind, CallNoteKind.due);
      expect(d.first.amount, 500);
      expect(d.first.theyOwe, isTrue);
      d = CallNoteUnderstand.onDevice('I owe Karim 1,200 taka', now: now);
      expect(d.first.kind, CallNoteKind.due);
      expect(d.first.theyOwe, isFalse);
      d = CallNoteUnderstand.onDevice('Shop opens at the new address', now: now);
      expect(d.single.kind, CallNoteKind.note);
      expect(CallNoteUnderstand.onDevice('   '), isEmpty);
    });

    test('server drafts: unknown kinds dropped, max three, payloads tagged', () {
      final d = CallNoteUnderstand.fromServer([
        {'kind': 'due', 'title': 'Rahim', 'amount': 500, 'person': 'Rahim', 'direction': 'they_owe', 'due_date': '2026-11-05'},
        {'kind': 'record_call', 'title': 'x'},
        {'kind': 'reminder', 'title': 'Call back', 'due_at': '2026-11-05T16:00'},
        {'kind': 'note', 'title': 'a'},
        {'kind': 'note', 'title': 'b'},
      ], fallbackTitle: 'f');
      expect(d.map((e) => e.kind), [CallNoteKind.due, CallNoteKind.reminder, CallNoteKind.note]);
      final loan = CallNoteSaver.duePayload(d[0], DateTime(2026, 11, 3));
      expect(loan['kind'], 'given');
      expect(loan['person'], 'Rahim');
      expect(loan['due_date'], '2026-11-05');
      expect(CallNoteSaver.reminderPayload(d[1])['source'], 'callnote');
    });
  });
}
