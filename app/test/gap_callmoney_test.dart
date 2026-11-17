// gap-callmoney (17 Nov) — board row 18 gaps, each one a test:
//  P0 the NATIVE pre-filter dropped real payments ("Tk. 500", "৫০০ টাকা",
//     bank alerts ending "Never share your PIN/OTP") — its regexes are read
//     from NotifListenCore.kt and run here, so Kotlin and Dart cannot drift;
//  P1 Dart parser: "BDT. 850", "Tk: 750", safety tips are not OTPs;
//  P1 privacy: a person's mobile number is masked in the saved khata note;
//  P1 review: SMS + app notification of one payment = ONE card; an unclear
//     amount can be typed (no dead end);
//  P1 after-call due: a name can be typed when the person is not in My Circle.
// Samples are written for Assisto (no real user data).
import 'dart:io';
import 'dart:math' as math;

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/notiflisten/callmoney_screens.dart';
import 'package:assisto/notiflisten/callnote_drafts.dart';
import 'package:assisto/notiflisten/money_notif_parser.dart';
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

const _core = 'android_overlay/app/src/main/kotlin/com/assisto/assisto/notiflisten/NotifListenCore.kt';

/// A Kotlin (non-raw) string literal body -> the runtime string.
String _ktLiteral(String body) {
  final b = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c == r'\' && i + 1 < body.length) {
      final n = body[i + 1];
      if (n == 'u') {
        b.writeCharCode(int.parse(body.substring(i + 2, i + 6), radix: 16));
        i += 5;
      } else {
        b.write(switch (n) { 'n' => '\n', 't' => '\t', _ => n });
        i++;
      }
      continue;
    }
    b.write(c);
  }
  return b.toString();
}

/// The native filter, rebuilt from the Kotlin source (same regexes, same steps).
class _Native {
  final Map<String, RegExp> rx;
  _Native(this.rx);

  factory _Native.load() {
    final src = File(_core).readAsStringSync();
    final out = <String, RegExp>{};
    for (final m in RegExp(r'val (\w+) = Regex\("((?:[^"\\]|\\.)*)"').allMatches(src)) {
      out[m.group(1)!] = RegExp(_ktLiteral(m.group(2)!), caseSensitive: false);
    }
    return _Native(out);
  }

  String strip(String t) => t
      .split(rx['SENTENCE_RX']!)
      .where((s) => !(rx['WARN_RX']!.hasMatch(s) && !rx['CODE_GIVEN_RX']!.hasMatch(s)))
      .join(' ');

  bool looksLikeTxn(String t) =>
      rx['AMOUNT_RX']!.hasMatch(t) && rx['PROOF_RX']!.hasMatch(t) && !rx['SECRET_RX']!.hasMatch(strip(t));

  String? amountHint(String t) {
    for (final m in rx['AMOUNT_RX']!.allMatches(t)) {
      final before = t.substring(math.max(0, m.start - 24), m.start);
      if (rx['NOT_AMOUNT_RX']!.hasMatch(before)) continue;
      final raw = MoneyNotifParser.normalizeDigits(m.group(1) ?? m.group(2) ?? '');
      final v = raw.replaceAll(RegExp(r'[.,]+$'), '');
      if ((double.tryParse(v.replaceAll(',', '')) ?? 0) > 0) return v;
    }
    return null;
  }
}

// real payments the native filter must KEEP (and the Dart parser must read)
const _keep = <({String text, String wallet, num amount, String type})>[
  (text: 'You have received Tk 1,500.00 from 01712345678. Fee Tk 0.00. Balance Tk 3,250.50. TrxID BK7Q2M9XAA at 03/11/2026 14:22', wallet: 'bkash', amount: 1500, type: 'income'),
  (text: 'You have received Tk. 500.00 from 01712345678. Fee Tk. 0.00. Balance Tk. 1,250.50. TrxID 9JK7AB12CD at 03/11/2026 14:22', wallet: 'bkash', amount: 500, type: 'income'),
  (text: 'আপনি ০১৭১২৩৪৫৬৭৮ নম্বর থেকে ৫০০ টাকা পেয়েছেন। ফি ০ টাকা। ব্যালেন্স ১,২৫০ টাকা। TrxID 9JK7AB12CD', wallet: 'bkash', amount: 500, type: 'income'),
  (text: 'Money Received. Amount: Tk: 750.00 Sender: 01712345678 TxnID: 71ABCD12 Balance: Tk: 1,500.00', wallet: 'nagad', amount: 750, type: 'income'),
  (text: 'Your A/C XXXX1234 has been debited by BDT. 850.00 for POS purchase at SHWAPNO. Avl Bal BDT. 20,150.00. Never share your card PIN/OTP with anyone.', wallet: 'bank', amount: 850, type: 'expense'),
  (text: 'BDT 2,500.00 withdrawn from A/C ...1234 by ATM. Bal BDT 7,500.00. Do not share your OTP or PIN with anyone. Call 16234 if not done by you.', wallet: 'bank', amount: 2500, type: 'expense'),
  (text: 'আপনার হিসাব ...১২৩৪ থেকে ৳৫,০০০.০০ উত্তোলন করা হয়েছে। ব্যালেন্স ৳২০,০০০.০০। পিন/ওটিপি কাউকে বলবেন না।', wallet: 'bank', amount: 5000, type: 'expense'),
  (text: 'Tk500.00 received from A/C:01712345678-5 Fee:Tk0.00, Your A/C Balance: Tk1,250.00 TxnId:1234567890', wallet: 'rocket', amount: 500, type: 'income'),
];

// codes / secrets: dropped on the phone, never stored
const _otp = [
  'Your bKash verification code is 482913. Never share it with anyone. Balance Tk 500',
  'Do not share OTP 482913 with anyone. Payment of Tk 500 needs it. A/C 1234',
  'আপনার বিকাশ যাচাই কোড ৪৮২৯১৩। কাউকে বলবেন না। ব্যালেন্স ৳৫০০',
  'Your OTP for card XXXX1234 transaction of BDT 1,000.00 is 739201. Never share your OTP.',
];

Future<void> _pump(WidgetTester tester, Widget w, {String lang = 'en'}) async {
  final app = gallery.galleryStub(lang: lang, mode: FakeMode.data);
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: w,
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('P0 native pre-filter (regexes read from NotifListenCore.kt)', () {
    final n = _Native.load();

    test('every regex the filter uses is found in the Kotlin source', () {
      for (final k in ['AMOUNT_RX', 'NOT_AMOUNT_RX', 'PROOF_RX', 'SECRET_RX', 'WARN_RX', 'CODE_GIVEN_RX', 'SENTENCE_RX']) {
        expect(n.rx.containsKey(k), isTrue, reason: k);
      }
      final src = File(_core).readAsStringSync();
      final looks = src.substring(src.indexOf('fun looksLikeTxn'), src.indexOf('fun amountHint'));
      expect(looks, contains('AMOUNT_RX.containsMatchIn(text)'));
      expect(looks, contains('!SECRET_RX.containsMatchIn(withoutSafetyTips(text))'));
      final hint = src.substring(src.indexOf('fun amountHint'));
      expect(hint, contains('NOT_AMOUNT_RX.containsMatchIn(before)'));
      expect(hint, contains('m.range.first - 24'));
    });

    test('real payments are KEPT on the phone (Tk. / ৫০০ টাকা / safety tips)', () {
      for (final s in _keep) {
        expect(n.looksLikeTxn(s.text), isTrue, reason: s.text);
      }
    });

    test('the prompt amount is the payment, never the fee or the balance', () {
      for (final s in _keep) {
        final h = n.amountHint(s.text);
        expect(num.parse(h!.replaceAll(',', '')), s.amount, reason: s.text);
      }
      expect(n.amountHint('Balance Tk 2,000.00 before. You received Tk 300.00. TrxID AB12CD34EF'), '300.00');
      expect(n.amountHint('আপনার হিসাব ...৯৮৭৬ এ বেতন জমা হয়েছে। ব্যালেন্স ৳৬০,৫০০.০০'), isNull);
    });

    test('OTPs and codes are still DROPPED unread-into-queue', () {
      for (final t in _otp) {
        expect(n.looksLikeTxn(t), isFalse, reason: t);
      }
    });
  });

  group('P1 Dart parser', () {
    test('the same payments parse with the right amount and type', () {
      // fee + balance with "BDT." / "Tk:" are read as fee / balance, not the amount
      final b = MoneyNotifParser.parse(_keep[4].text, wallet: 'bank');
      expect(b.balance, 20150);
      final g = MoneyNotifParser.parse(_keep[3].text, wallet: 'nagad');
      expect(g.balance, 1500);
      for (final s in _keep) {
        final p = MoneyNotifParser.parse(s.text, wallet: s.wallet, postedAt: DateTime(2026, 11, 3));
        expect(p.ok, isTrue, reason: '${p.reason}: ${s.text}');
        expect(p.amount, s.amount, reason: s.text);
        expect(p.type, s.type, reason: s.text);
      }
    });

    test('codes stay OTPs', () {
      for (final t in _otp) {
        final p = MoneyNotifParser.parse(t, wallet: 'bkash');
        expect(p.ok, isFalse, reason: t);
        expect(p.reason, 'otp', reason: t);
      }
    });

    test('a safety tip is removed only for the OTP check', () {
      expect(MoneyNotifParser.withoutSafetyTips('Paid Tk 5. Never share your PIN. TrxID AB12CD34'),
          'Paid Tk 5. TrxID AB12CD34');
      expect(MoneyNotifParser.withoutSafetyTips('Your OTP 482913. Never share it.'), contains('482913'));
    });
  });

  group('P1 privacy: no full phone number in the khata note', () {
    test('mobile numbers are masked, names are kept', () {
      expect(NotifListenService.maskPhone('01712345678'), '017*****678');
      expect(NotifListenService.maskPhone('+8801712345678'), '017*****678');
      expect(NotifListenService.maskPhone('Shwapno'), 'Shwapno');
      expect(NotifListenService.maskPhone(''), '');
    });
  });

  group('P1 review screen', () {
    setUp(() => SharedPreferences.setMockInitialValues({'cm_consent_money_v1': 'x', 'cm_money_on': true}));

    testWidgets('SMS + app of one payment = one card; unclear amount can be typed', (tester) async {
      final fake = FakeNotifBridge(queue: fakeMoneyQueueGaps());
      NotifListenChannel.instance = fake;
      await _pump(tester, const MoneyNotifReviewScreen(focusId: 11));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cmn_row_11')), findsOneWidget);
      expect(find.byKey(const ValueKey('cmn_row_12')), findsNothing); // the SMS twin
      expect(fake.done, contains(12));
      expect(find.byKey(const ValueKey('cmn_row_13')), findsOneWidget);
      // unclear: no amount -> Save disabled until typed + kind chosen
      await tester.ensureVisible(find.byKey(const ValueKey('cmn_amt_13')));
      await tester.pumpAndSettle();
      FilledButton save() => tester.widget<FilledButton>(find.byKey(const ValueKey('cmn_save_13')));
      expect(save().onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('cmn_amt_13')), '৬০০০০');
      await tester.pump();
      expect(save().onPressed, isNull); // kind not chosen yet
      await tester.tap(find.byKey(const ValueKey('cmn_inc_13')));
      await tester.pump();
      expect(save().onPressed, isNotNull);
      await tester.enterText(find.byKey(const ValueKey('cmn_amt_13')), 'abc');
      await tester.pump();
      expect(save().onPressed, isNull); // a non-number is never saved
    });
  });

  group('P1 after-call due: type a name', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('a person not in My Circle can be typed, then Confirm saves', (tester) async {
      final writes = <CallNoteDraft>[];
      await _pump(
          tester,
          Scaffold(
              body: CallNoteSheet(
                  launch: const NotifLaunch(kind: 'callnote', mode: 'type', source: 'sim'),
                  offline: true,
                  writer: (d) async => writes.add(d))));
      await tester.enterText(find.byKey(const ValueKey('cmn_callnote_text')), 'Rahim will pay 500 taka tomorrow at 5 pm');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cmn_callnote_go')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('cmn_draft_ok_0'))).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('cmn_draft_person_type_0')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('cmn_name_field')), '  Rahim  ');
      await tester.tap(find.byKey(const ValueKey('cmn_name_ok')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cmn_draft_ok_0')));
      await tester.pumpAndSettle();
      expect(writes.single.kind, CallNoteKind.due);
      expect(writes.single.person, 'Rahim');
      expect(CallNoteSaver.duePayload(writes.single, DateTime(2026, 11, 3))['person'], 'Rahim');
    });
  });
}
