// cctvprice: gallery states for test/screenshots_test.dart — the CCTV plan
// screen: new user with the free-trial badge, 3 cameras picked, an active
// yearly plan with the video add-on, the unpaid notice, website APK.
import 'package:flutter/material.dart';

import 'package:assisto/billing/cctv_plan_screen.dart';

import 'cctvprice_fakes.dart';

final Map<String, Widget Function(String)> cctvpriceShots = {
  'cpl_new_trial': (_) => CctvPlanScreen(
      api: FakeCctvApi(), preview: cctvPlanPayload(), previewOffers: kCctvOffers),
  'cpl_active_addon': (_) => CctvPlanScreen(
      api: FakeCctvApi(),
      preview: cctvPlanPayload(
          trial: false,
          used: 3,
          status: cctvActiveStatus(cams: 3, yearly: true, addon: true),
          addonCams: const [11, 12],
          cameras: const [
            {'id': 11, 'name': 'Gate', 'vendor': 'imou'},
            {'id': 12, 'name': 'Shop counter', 'vendor': 'ezviz'},
            {'id': 13, 'name': 'Old phone', 'vendor': 'phone'},
          ]),
      previewOffers: kCctvOffers),
  'cpl_ended_notice': (_) => CctvPlanScreen(
      api: FakeCctvApi(),
      preview: cctvPlanPayload(
          trial: false,
          notice: const {
            'title_bn': 'সিসিটিভি প্ল্যান শেষ হয়েছে',
            'title_en': 'Your CCTV plan has ended',
            'bn': 'পেমেন্ট ছাড়া প্ল্যান শেষ। ০৬/১১/২০২৬ তারিখে ক্যামেরাগুলো Assisto থেকে খুলে দেওয়া হবে।',
            'en': 'The plan ended without payment. On 06 Nov 2026 the cameras will be released from Assisto.',
          }),
      previewOffers: kCctvOffers),
  'cpl_apk': (_) => CctvPlanScreen(api: FakeCctvApi(), preview: cctvPlanPayload()),
};
