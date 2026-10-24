// p5-growth: gallery states for test/screenshots_test.dart — Invite friends
// (new account that can enter a code; a friend's code pending + Founding
// seat holder) and the branded share sheet for an AI answer.
import 'package:flutter/material.dart';

import 'package:assisto/growth/branded_share.dart';
import 'package:assisto/growth/invite_screen.dart';

Map<String, dynamic> p5Me({bool claimed = false, bool seat = false}) => {
      'code': 'K7QF2M9P',
      'link': 'https://lifeassisto.com/i/K7QF2M9P',
      'share_text': 'Assisto — K7QF2M9P\nhttps://lifeassisto.com/i/K7QF2M9P',
      'rules': {
        'inviter_credits': 20, 'invitee_credits': 10, 'monthly_cap': 10,
        'claim_days': 14, 'activation_days': 2, 'activation_window_days': 14,
        'phone_otp': false,
      },
      'stats': {'joined': 3, 'pending': 1, 'rewarded': 2, 'credits_earned': 40,
                'month_used': 2},
      'my_claim': claimed
          ? {'state': 'pending', 'reason': '', 'credits': 0, 'days': 1, 'need': 2,
             'phone_ok': true}
          : null,
      'can_claim': !claimed,
      'founding': {
        'enabled': true, 'seats': 500, 'taken': 137,
        'number': seat ? 42 : null, 'credits': 20, 'my_credits': seat ? 20 : 0,
        'activation': {'days': 1, 'need': 2, 'phone_ok': true},
      },
    };

Widget _sheetLike(Widget child) => Scaffold(
      backgroundColor: Colors.black54,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: const EdgeInsets.only(top: 24), child: child),
        ),
      ),
    );

String _answer(String l) => l == 'bn'
    ? 'বিদ্যুৎ বিল কমাতে: ১) দিনের আলো বেশি ব্যবহার করুন, ২) এসি ২৬° সেলসিয়াসে রাখুন, ৩) পুরোনো বাল্ব বদলে LED লাগান, ৪) ব্যবহার না করলে প্লাগ খুলে রাখুন। এতে মাসে উল্লেখযোগ্য খরচ কমতে পারে।'
    : 'To cut your electricity bill: 1) use daylight more, 2) keep the AC at 26°C, 3) replace old bulbs with LEDs, 4) unplug devices you are not using. Together these can noticeably lower the monthly cost.';

final Map<String, Widget Function(String)> p5Shots = {
  'p5_invite': (_) => InviteScreen(loader: () async => p5Me()),
  'p5_invite_claimed_bottom': (_) =>
      InviteScreen(loader: () async => p5Me(claimed: true, seat: true)),
  'p5_share_sheet': (l) => _sheetLike(BrandedShareSheet(
      body: _answer(l),
      inviteLoader: () async => p5Me())),
};
