// cctvcap: gallery states — caps on the camera screen (AI used up + relay at
// 80 %, with the extra-pack button) and the extra-pack sheet.
import 'package:flutter/material.dart';

import 'package:assisto/cctvguard/cctv_cap_section.dart';
import 'package:assisto/cctvguard/cctv_usage_card.dart';

import 'cctvcap_fakes.dart';

Widget _card(String lang) => Scaffold(
      body: ListView(children: [
        CctvUsageCard(load: () async => cgUsageCap(lang: lang), buy: FakePackBuyer(lang: lang).call),
      ]),
    );

Widget _sheet(String lang) => Scaffold(
      body: ExtraPackSheet(cap: cgCap(lang: lang), buy: FakePackBuyer(lang: lang).call),
    );

final Map<String, Widget Function(String)> cctvcapShots = {
  'cap_usage_card': (l) => _card(l),
  'cap_pack_sheet': (l) => _sheet(l),
};
