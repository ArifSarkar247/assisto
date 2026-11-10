// buyinside: gallery states for test/screenshots_test.dart (bn/en, light/dark)
// — the locked CCTV screen, the plan buy screen with the 7-day trial, the
// credits-finished sheet inside a task, and the Plans page additions.
import 'package:flutter/material.dart';

import 'package:assisto/payments/credits_out_sheet.dart';
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/plans_v2/cctv_locked_sheet.dart';
import 'package:assisto/plans_v2/plans_buy_section.dart';
import 'package:assisto/plans_v2/plans_v2.dart';
import 'package:assisto/plans_v2/upgrade_sheet.dart';

import 'cctvprice_fakes.dart';
import 'pay1_fakes.dart';

PayConfig _cfg() => PayConfig.fromJson({
      'channels': [
        {'id': 'gateway', 'enabled': true, 'ready': true, 'label': 'EPS'},
      ],
      'products': {
        'gateway': [
          pay1Product('c50', price: 179, kind: 'pack', credits: 60),
          pay1Product('c120', price: 399, kind: 'pack', credits: 140),
          pay1Product('c300', price: 949, kind: 'pack', credits: 330),
          {...pay1Product('business_monthly', price: 1299), 'plan': 'business'},
        ],
      },
    });

Widget _sheet(Widget child) =>
    Scaffold(body: SafeArea(child: SingleChildScrollView(child: child)));

final Map<String, Widget Function(String)> buyinsideShots = {
  'bi_cctv_locked': (_) => _sheet(CctvLockedSheet(
      api: FakeCctvApi(), preview: cctvPlanPayload(), previewOffers: kCctvOffers)),
  'bi_business_locked': (_) => _sheet(UpgradeSheet(
        reason: const UpgradeReason(feature: 'reports', neededPlan: 'business'),
        backend: FakePaymentsBackend(cfg: _cfg()),
        flavour: 'apk',
        loadState: () async => PlansV2State.fromJson(const {
          'on': true,
          'tier': 'free',
          'trial_available': true,
          'trial_days': 7,
          'trial_plan': 'business',
        }),
      )),
  'bi_credits_in_task': (_) => _sheet(CreditsOutSheet(
      screen: 'ai_chat',
      draftKept: true,
      backend: FakePaymentsBackend(cfg: _cfg()),
      flavour: 'apk',
      adsAvailable: (_) async => true)),
  'bi_plans_recommend': (l) => _sheet(PlansBuySection(flavour: 'play', preview: {
        'recommend': const {'plan': 'premium', 'price': 449, 'saves_bdt': 129},
        'text': l == 'bn'
            ? 'গত ৩০ দিনে আপনি ১৫০ ক্রেডিট খরচ করেছেন এবং মোট ৳৫৭৮ দিয়েছেন। প্রিমিয়াম প্ল্যানে (১৬০ ক্রেডিট/মাস) ৳৪৪৯ — প্রতি মাসে প্রায় ৳১২৯ বাঁচবে।'
            : 'In the last 30 days you used 150 credits and paid ৳578 in total. Premium (160 credits a month) costs ৳449 — about ৳129 less every month.',
      })),
};
