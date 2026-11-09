// cctvconnect (CCTV Guard V3 A1 + B): gallery states — brand list with a
// linked DVR, the same-Wi-Fi empty state, the serial + code sheet, the
// channel picker, and the daily DVR check (green / red).
import 'package:flutter/material.dart';

import 'package:assisto/cctvconnect/cctv_connect_screen.dart';
import 'package:assisto/cctvconnect/dvr_health_card.dart';
import 'package:assisto/cctvconnect/link_devices_screen.dart';

import 'cctvconnect_fakes.dart';

Widget _health(String lang, String status) => Scaffold(
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DvrHealthCard(
            siteId: 1,
            initiallyOpen: true,
            source: FakeCctvConnect(lang: lang, healthStatus: status)),
      ]),
    );

final Map<String, Widget Function(String)> cctvconnectShots = {
  'ccn_brands': (l) => CctvConnectScreen(
      siteId: 1, source: FakeCctvConnect(lang: l), onFindOnWifi: () {}),
  'ccn_wifi_empty': (l) => CctvConnectScreen(
      siteId: 1, source: FakeCctvConnect(lang: l, noProviders: true, noLinks: true),
      onFindOnWifi: () {}),
  'ccn_link_sheet': (l) => Scaffold(
        body: SafeArea(
          child: CctvLinkSheet(
              source: FakeCctvConnect(lang: l),
              siteId: 1,
              provider: const {
                'id': 'hikconnect',
                'name': 'Hikvision Hik-Connect',
                'code_label_bn': 'লেবেলের ৬ অক্ষরের Verification Code',
                'code_label_en': '6-letter Verification Code on the label',
              }),
        ),
      ),
  'ccn_devices': (l) => CctvLinkDevicesScreen(
      source: FakeCctvConnect(lang: l), linkId: 5, title: 'Hikvision Hik-Connect'),
  'ccn_health_green': (l) => _health(l, 'green'),
  'ccn_health_red': (l) => _health(l, 'red'),
};
