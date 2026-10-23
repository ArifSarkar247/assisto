// P3 — pure logic: @Assisto parsing, E2E cards + ledger, bill split math,
// on-device scam rules (bn / Banglish / en + false positives), medicine
// status, story/note privacy + per-viewer sealing.
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/p3/assisto_card.dart';
import 'package:assisto/p3/assisto_intent.dart';
import 'package:assisto/p3/assisto_sheet.dart' show medicineStatus;
import 'package:assisto/p3/scam_guard.dart';
import 'package:assisto/p3/story_crypto.dart';

void main() {
  group('@Assisto intent', () {
    test('mention detection', () {
      expect(hasAssistoMention('@Assisto summarize'), isTrue);
      expect(hasAssistoMention('  @assisto'), isTrue);
      expect(hasAssistoMention('@অ্যাসিস্টো সারাংশ দাও'), isTrue);
      expect(hasAssistoMention('hi @Assisto'), isFalse); // only at the start
      expect(hasAssistoMention('@Assistant'), isFalse);
      expect(isTypingMention('@ass'), isTrue);
      expect(isTypingMention('@rahim'), isFalse);
      expect(parseAssisto('hello there'), isNull);
    });

    test('bare mention opens the menu', () {
      expect(parseAssisto('@Assisto')!.action, AssistoAction.menu);
    });

    test('summarize in en / Banglish / bn', () {
      for (final s in [
        '@Assisto summarize unread',
        '@assisto what did i miss',
        '@Assisto ki holo eto khon',
        '@Assisto সারাংশ দাও',
      ]) {
        expect(parseAssisto(s)!.action, AssistoAction.summarize, reason: s);
      }
    });

    test('reminder for everyone vs me', () {
      final a = parseAssisto('@Assisto remind everyone tomorrow 9am pay electricity bill')!;
      expect(a.action, AssistoAction.remind);
      expect(a.everyone, isTrue);
      expect(a.rest.toLowerCase(), contains('electricity'));
      final b = parseAssisto('@Assisto remind me at 8pm call Abba')!;
      expect(b.everyone, isFalse);
      final c = parseAssisto('@Assisto sobaike mone koriye dio kal bazar')!;
      expect(c.action, AssistoAction.remind);
      expect(c.everyone, isTrue);
      final d = parseAssisto('@Assisto সবাইকে মনে করিয়ে দাও কাল সকালে মিটিং')!;
      expect(d.action, AssistoAction.remind);
      expect(d.everyone, isTrue);
    });

    test('split amount incl. Bangla digits', () {
      final a = parseAssisto('@Assisto split 1,200 tk dinner')!;
      expect(a.action, AssistoAction.split);
      expect(a.poisha, 120000);
      final b = parseAssisto('@Assisto বিল ভাগ করো ৯৫০ টাকা')!;
      expect(b.action, AssistoAction.split);
      expect(b.poisha, 95000);
    });

    test('shopping list items', () {
      final a = parseAssisto('@Assisto shopping list: rice, oil and eggs')!;
      expect(a.action, AssistoAction.list);
      expect(a.items, ['rice', 'oil', 'eggs']);
      final b = parseAssisto('@Assisto বাজারের লিস্ট: চাল, ডাল আর তেল')!;
      expect(b.action, AssistoAction.list);
      expect(b.items, ['চাল', 'ডাল', 'তেল']);
    });

    test('translate target', () {
      final a = parseAssisto('@Assisto translate to english: ami ashchi')!;
      expect(a.action, AssistoAction.translate);
      expect(a.target, 'en');
      expect(a.rest, 'ami ashchi');
      expect(parseAssisto('@Assisto অনুবাদ করো বাংলায়')!.target, 'bn');
    });

    test('anything else is a question', () {
      final a = parseAssisto('@Assisto how do I renew my NID?')!;
      expect(a.action, AssistoAction.ask);
      expect(a.rest, 'how do I renew my NID?');
    });
  });

  group('cards', () {
    test('encode / decode / fallback', () {
      final c = reminderCard(
          title: 'Pay bill', at: DateTime.utc(2026, 10, 24, 3), forEveryone: true, by: 'Arif');
      final pt = encodeCard(c, 'Reminder: Pay bill');
      expect(pt.startsWith('Reminder: Pay bill\n'), isTrue);
      expect(isCardText(pt), isTrue);
      expect(cardFallback(pt), 'Reminder: Pay bill');
      final back = decodeCard(pt)!;
      expect(back.type, CardType.reminder);
      expect(back.id, c.id);
      expect(back.str('scope'), 'all');
      expect(back.str('title'), 'Pay bill');
    });

    test('ordinary text and junk are not cards', () {
      expect(decodeCard('hello'), isNull);
      expect(decodeCard('x\n⁣AC1:not-base64!!'), isNull);
      expect(cardFallback('plain message'), 'plain message');
      final unknown = encodeCard(const AssistoCard('bogus', 'i', {}), 'fb');
      expect(decodeCard(unknown), isNull);
    });

    test('ledger folds ticks (last wins) and acks', () {
      final list = listCard('Bazar', ['Rice', 'Oil', 'Eggs']);
      final t0 = DateTime(2026, 10, 23, 10);
      final events = [
        CardEvent(list, '', true, t0),
        CardEvent(tickCard(list.id, 0, true, 'Rahim'), 'Rahim', false, t0.add(const Duration(minutes: 1))),
        CardEvent(tickCard(list.id, 1, true, 'Nadia'), 'Nadia', false, t0.add(const Duration(minutes: 2))),
        CardEvent(tickCard(list.id, 1, false, 'Arif'), '', true, t0.add(const Duration(minutes: 3))),
      ];
      final l = CardLedger.fold(events.reversed); // order-independent
      expect(l.itemState(list.id, 0).done, isTrue);
      expect(l.itemState(list.id, 0).by, 'Rahim');
      expect(l.itemState(list.id, 1).done, isFalse);
      expect(l.doneCount(list.id, 3), 1);
      final rem = reminderCard(title: 'x', at: t0, forEveryone: true, by: 'A');
      final l2 = CardLedger.fold([
        CardEvent(ackCard(rem.id, 'Rahim'), 'Rahim', false, t0),
        CardEvent(ackCard(rem.id, 'Rahim'), 'Rahim', false, t0),
        CardEvent(ackCard(rem.id, 'Arif'), '', true, t0),
      ]);
      expect(l2.acks[rem.id], ['Rahim', 'Arif']);
      expect(l2.ackedByMe.contains(rem.id), isTrue);
      expect(ackCard('r', 'n').hidden, isTrue);
      expect(rem.hidden, isFalse);
    });

    test('split shares always add up', () {
      expect(equalShares(100000, 3), [33334, 33333, 33333]);
      expect(equalShares(100, 0), isEmpty);
      final c = splitCard(title: 'Dinner', totalPoisha: 125050, payer: 'Arif', names: ['Arif', 'Rahim']);
      final sum = c.list('shares').fold<int>(0, (a, s) => a + ((s as Map)['amount'] as int));
      expect(sum, 125050);
      expect(takaOf(125050), '1,250.50');
      expect(poishaOf('৳ ১,২০০'), 120000);
      expect(poishaOf('abc'), 0);
    });
  });

  group('scam guard (on-device)', () {
    final scams = <String, ScamReason>{
      // OTP / PIN requests
      'Your bKash account will be blocked. Send me the OTP now': ScamReason.otpRequest,
      'bhai otp ta dao please, vul kore apnar number e chole geche': ScamReason.otpRequest,
      'আপনার মোবাইলে একটি কোড গেছে, কোডটা দিন': ScamReason.otpRequest,
      'ওটিপি নম্বরটা বলুন, আপনার পুরস্কার পাঠাবো': ScamReason.otpRequest,
      // bKash / Nagad agent fraud
      'আমি বিকাশ এজেন্ট বলছি, আপনার একাউন্ট বন্ধ হয়ে যাবে': ScamReason.mfsAgent,
      'Nagad customer care: taka bhul kore apnar number e geche, ferot din': ScamReason.mfsAgent,
      'bkash theke vul kore 5000 taka pathiyechi, please ferot den': ScamReason.mfsAgent,
      // prize / lottery
      'Congratulations! You have won 5 lakh in our lucky draw. Pay 500 tk fee to claim': ScamReason.prize,
      'অভিনন্দন! আপনি লটারিতে জিতেছেন, ফি ১০০০ টাকা পাঠান': ScamReason.prize,
      'apni lottery jitechen! claim korte link e click korun': ScamReason.prize,
      // look-alike links
      'Update your wallet: http://bkash-verify.xyz/login': ScamReason.lookalikeLink,
      'see this faceb00k.com/photo/123': ScamReason.lookalikeLink,
      'login: https://nagad.com.bd.secure-login.top': ScamReason.lookalikeLink,
      // urgent money (new number)
      'Ami tomar mama, notun number. Hospital e achi, ekhoni 5000 taka bkash koro': ScamReason.urgentMoney,
      'মা, আমার নতুন নম্বর। খুব বিপদে আছি, এখনই টাকা পাঠাও': ScamReason.urgentMoney,
    };
    scams.forEach((text, reason) {
      test('flags: $text', () {
        final v = checkScam(text);
        expect(v.flagged, isTrue, reason: text);
        expect(v.reasons, contains(reason), reason: '$text -> ${v.reasons}');
      });
    });

    test('urgent money needs a NEW contact (or "new number")', () {
      const t = 'Urgent! please send money right now, taka lagbe';
      expect(checkScam(t).reasons, isNot(contains(ScamReason.urgentMoney)));
      expect(checkScam(t, newContact: true).reasons, contains(ScamReason.urgentMoney));
    });

    final safe = [
      'Your OTP is 482913. Do not share it with anyone.',
      'আপনার ওটিপি ৪৮২৯১৩। কাউকে দেবেন না।',
      "I'll send the code tomorrow, ok?",
      'Ami bkash e taka pathiye dilam, check koro',
      'Kal bazar korte hobe, chal dal tel',
      'Pin the location please',
      'Check https://www.bkash.com/en/help for the fees',
      'nagad.com.bd e login korlam',
      'Abba hospital e checkup e gechen, chinta koro na',
      'Did you win the match? Congratulations!',
      'আজ সন্ধ্যায় বাসায় আসবে?',
      'Lottery ticket kinechi mela theke, haha',
      'urgent meeting at 5, please come',
      'facebook.com/groups/ourfamily',
    ];
    for (final s in safe) {
      test('does not flag: $s', () {
        expect(checkScam(s).flagged, isFalse, reason: '$s -> ${checkScam(s).reasons}');
      });
    }

    test('look-alike domain helper', () {
      expect(lookalikeDomain('go to bkash.com.login-help.cc now'), 'bkash.com.login-help.cc');
      expect(lookalikeDomain('https://dutchbanglabank.com/rocket'), '');
      expect(lookalikeDomain('xn--bkas-x0a.com'), 'xn--bkas-x0a.com');
    });
  });

  test('medicine status: missed vs taken (PRN ignored)', () {
    final now = DateTime(2026, 10, 23, 14, 0);
    final s = medicineStatus([
      {'name': 'Napa', 'slot': '08:00', 'taken': true},
      {'name': 'Seclo', 'slot': '09:00', 'taken': false},
      {'name': 'Losectil', 'slot': '13:50', 'taken': false}, // within 30 min grace
      {'name': 'Ace', 'slot': '20:00', 'taken': false}, // later today
      {'name': 'Sergel', 'slot': 'prn', 'prn': true, 'taken': false},
      {'name': 'Fexo', 'slot': '07:00', 'skipped': true},
    ], now);
    expect(s.taken.map((m) => m['name']), ['Napa']);
    expect(s.missed.map((m) => m['name']), ['Seclo', 'Fexo']);
  });

  group('stories / notes E2E', () {
    final e2e = SoftwareE2E();
    final me = e2e.generateIdentity();
    final rahim = e2e.generateIdentity();
    final nadia = e2e.generateIdentity();
    String b64(IdentityKeyPair k) => k.publicKeyB64;
    final members = [
      {'id': 11, 'name': 'Rahim', 'peer_user_id': 2, 'public_key': b64(rahim)},
      {'id': 12, 'name': 'Nadia', 'peer_user_id': 3, 'public_key': b64(nadia)},
      {'id': 13, 'name': 'NoKey', 'peer_user_id': 4, 'public_key': ''},
    ];

    test('privacy modes resolve the audience', () {
      expect(audienceOf(members, StoryPrivacy.contacts).length, 2); // no-key skipped
      expect(audienceOf(members, const StoryPrivacy('except', exclude: [2]))
          .map((m) => m['name']), ['Nadia']);
      expect(audienceOf(members, const StoryPrivacy('chosen', allow: [2]))
          .map((m) => m['name']), ['Rahim']);
      final p = StoryPrivacy.fromJson({'mode': 'chosen', 'allow_ids': ['2', 'x']});
      expect(p.allow, [2]);
      expect(StoryPrivacy.fromJson({'mode': 'nonsense'}).mode, 'everyone');
    });

    test('each viewer opens only their own copy; others cannot', () {
      final per = sealForAudience(
          e2e: e2e, me: me, myUserId: 1,
          audience: audienceOf(members, StoryPrivacy.contacts),
          plaintext: StoryContent.encodeText('Eid Mubarak', 2));
      expect(per.keys.toSet(), {'1', '2', '3'});
      final rahimRow = {...(per['2'] as Map).cast<String, dynamic>(), 'sender_key_id': me.keyId};
      final mine = {...(per['1'] as Map).cast<String, dynamic>(), 'sender_key_id': me.keyId};
      final pt = openSealed(e2e: e2e, me: rahim, senderKeys: [me.publicKey], row: rahimRow);
      expect(StoryContent.parse(pt!)!.text, 'Eid Mubarak');
      expect(StoryContent.parse(pt)!.bg, 2);
      // Nadia cannot open Rahim's copy
      expect(openSealed(e2e: e2e, me: nadia, senderKeys: [me.publicKey], row: rahimRow), isNull);
      // my self copy opens with my own key
      expect(openSealed(e2e: e2e, me: me, senderKeys: [me.publicKey], row: mine), isNotNull);
      // nothing readable in the payload
      expect(per.toString().contains('Eid'), isFalse);
    });
  });
}
