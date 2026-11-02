// cctvguard: gallery states — "this month's use" card (allowance on / only
// counted) and the Imou/EZVIZ cloud live screen (SD first, idle timer, data
// estimate) plus its honest error state.
import 'package:flutter/material.dart';

import 'package:assisto/api.dart';
import 'package:assisto/cctvguard/cctv_usage_card.dart';
import 'package:assisto/cctvguard/vendor_live_screen.dart';
import 'package:assisto/messaging/media/video_ctl.dart';

import 'cctvguard_fakes.dart';

Widget _card(String lang, {bool enforced = true}) => Scaffold(
      body: ListView(children: [
        CctvUsageCard(
            initiallyOpen: true,
            load: () async => cgUsage(enforced: enforced, lang: lang)),
      ]),
    );

Widget _vendor(String lang, {bool fail = false}) {
  VideoCtls.networkFactory = (_) async => FakeNetCtl();
  final api = FakeVendorLive();
  if (fail) {
    api.failWith = ApiException(
        lang == 'bn'
            ? 'ক্যামেরা কোম্পানির ক্লাউড এখন লাইভ দিচ্ছে না — ক্যামেরা অনলাইনে আছে কিনা দেখুন, একটু পরে আবার চেষ্টা করুন।'
            : "The camera maker's cloud did not give a live view — check the camera is online and try again shortly.",
        502);
  }
  return VendorLiveScreen(
      cameraId: 11, cameraName: lang == 'bn' ? 'সামনের দরজা' : 'Front door', api: api);
}

final Map<String, Widget Function(String)> cctvguardShots = {
  'cg_usage_card': (l) => _card(l),
  'cg_usage_counting': (l) => _card(l, enforced: false),
  'cg_vendor_live': (l) => _vendor(l),
  'cg_vendor_error': (l) => _vendor(l, fail: true),
};
