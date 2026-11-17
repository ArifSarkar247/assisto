// bizai2: gallery states for test/screenshots_test.dart (and so the launch
// Bangla sweep, a11y sweep and dead-button sweep) — the owner's daily shop
// summary (full + empty) and the win-back ladder on a non-Business plan.
import 'package:flutter/material.dart';

import 'package:assisto/bizai/biz_daily_screen.dart';
import 'package:assisto/bizai/winback_screen.dart';

import 'bizai_fakes.dart';

/// Server-shaped GET bizai/daily payload (lines come localised from the server).
Map<String, dynamic> fakeDaily({bool bn = false, bool empty = false, bool on = true}) => empty
    ? {
        'title': bn ? 'আজকের দোকানের হিসাব' : "Today's shop summary",
        'lines': [bn ? 'আজ অ্যাপে কোনো বিক্রি লেখা হয়নি।' : 'No sales were recorded in the app today.'],
        'chase': [], 'stock': [], 'outcomes': [], 'empty': true, 'enabled': on,
        'next': bn
            ? 'কাল প্রতিটি বিক্রি অ্যাপে লিখুন — তাহলে সন্ধ্যায় পুরো হিসাব এখানে পাবেন।'
            : 'Tomorrow, ring up every sale in the app — then the full picture comes here each evening.',
        'switch_note': bn
            ? 'প্রতিদিন রাত ৯টায় এই হিসাব একটি নোটিফিকেশনে আসে।'
            : 'This summary comes as one notification every day at 9 pm.',
      }
    : {
        'title': bn ? 'আজকের দোকানের হিসাব' : "Today's shop summary",
        'lines': bn
            ? ['আজ বিক্রি: ২টি, মোট ৳৮০০.০০।', 'ভাগ: ক্যাশ ৳৫০০.০০, বিকাশ ৳৩০০.০০।',
               'গত সপ্তাহের এই দিনের চেয়ে ১০০% বেশি।', 'আজ খাতায় বাকি আদায়: ৳২০০.০০।',
               'মোট পাওনা: ৳১৩০০.০০ (২ জনের কাছে)।']
            : ['Sales today: 2, total ৳800.00.', 'Split: cash ৳500.00, bKash ৳300.00.',
               '100% more than the same day last week.', 'Dues collected today: ৳200.00.',
               'Total owed to you: ৳1300.00 (2 customers).'],
        'chase': [
          {'party_id': 1, 'name': 'Karim', 'due_poisha': 100000,
           'line': bn ? 'করিম — ৳১০০০.০০ · ১৫ দিন ধরে বাকি' : 'Karim — ৳1000.00 · owing for 15 days'},
        ],
        'stock': [
          {'name': 'Chal 5kg', 'stock': 2, 'days_left': 2, 'reorder': 5,
           'line': bn
               ? 'চাল ৫ কেজি — ২টি আছে, প্রায় ২ দিনে শেষ হবে; এক সপ্তাহের জন্য আরও ৫টি আনুন।'
               : 'Rice 5kg — 2 left, runs out in about 2 days; get 5 more for a week.'},
        ],
        'outcomes': [bn ? 'এই সপ্তাহে তাগাদার পরে আদায়: ৳২০০ (১টি জমা)।'
            : 'Collected after reminders this week: ৳200 (1 payments).'],
        'next': bn
            ? 'কাল সকালে আগে চাল ৫ কেজি আনার ব্যবস্থা করুন — বিক্রি থামবে না।'
            : 'Tomorrow morning, restock Rice 5kg first so sales do not stop.',
        'empty': false, 'enabled': on,
        'switch_note': bn
            ? 'প্রতিদিন রাত ৯টায় এই হিসাব একটি নোটিফিকেশনে আসে।'
            : 'This summary comes as one notification every day at 9 pm.',
      };

/// The ladder as a Free-plan owner sees it (GET is free; switching on is not).
class FakeWinbackFree extends FakeWinback {
  FakeWinbackFree({super.bn});
  @override
  Future<Map<String, dynamic>> ladder() async => {
        ...await super.ladder(),
        'plan_ok': false,
        'plan_required': 'business',
        'plan_note': bn
            ? 'দেখা ফ্রি। চালু করতে বিজনেস প্ল্যান লাগবে — তখন এই মেসেজগুলো নিজে থেকে যাবে।'
            : 'Looking is free. Switching it on needs the Business plan — then these messages go out by themselves.',
      };
}

// gap-bizai: win-back with an honest in-app reach (2 of 4 use Assisto)
class FakeWinbackReach extends FakeWinback {
  FakeWinbackReach({super.bn});
  Map<String, dynamic> _reach(Map<String, dynamic> r) => {
        'stages': [
          for (final s in (r['stages'] as List).cast<Map<String, dynamic>>())
            {...s, 'on_assisto': s['stage'] == 'wb30' ? 2 : 0}
        ]
      };
  @override
  Future<Map<String, dynamic>> ladder() async => _reach(await super.ladder());
  @override
  Future<Map<String, dynamic>> approve(Map<String, dynamic> body) async =>
      _reach(await super.approve(body));
}

final Map<String, Widget Function(String)> bizai2Shots = {
  'bizai2_daily': (l) => BizDailyScreen(
      load: () async => fakeDaily(bn: l == 'bn'), setOn: (on) async => {'enabled': on}),
  'bizai2_daily_empty': (l) => BizDailyScreen(
      load: () async => fakeDaily(bn: l == 'bn', empty: true),
      setOn: (on) async => {'enabled': on}),
  'bizai2_winback_free': (l) => WinbackScreen(source: FakeWinbackFree(bn: l == 'bn')),
  // gap-bizai
  'gbz_winback_reach': (l) => WinbackScreen(source: FakeWinbackReach(bn: l == 'bn')),
  'gbz_daily_actions': (l) => BizDailyScreen(
      load: () async => {
            ...fakeDaily(bn: l == 'bn'),
            'chase': [
              {'party_id': 1, 'name': l == 'bn' ? 'করিম' : 'Karim', 'due_poisha': 100000,
               'line': l == 'bn' ? 'করিম — ৳১০০০.০০ · ১৫ দিন ধরে বাকি' : 'Karim — ৳1000.00 · owing for 15 days'},
              {'party_id': 2, 'name': l == 'bn' ? 'সেলিম' : 'Selim', 'due_poisha': 50000,
               'line': l == 'bn' ? 'সেলিম — ৳৫০০.০০ · ৩ দিন ধরে বাকি' : 'Selim — ৳500.00 · owing for 3 days'},
            ],
          },
      setOn: (on) async => {'enabled': on}),
};
