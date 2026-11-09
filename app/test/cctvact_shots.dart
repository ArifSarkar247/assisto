// cctvact: gallery states (test/screenshots_test.dart) — CCTV GUARD V3:
// alert actions with Live / box siren / own warning / thana / wrong alert /
// lock question, the hub, closing report, ask, sales match (+ POS link),
// automations (empty + linked). Prefix cv3_ is in the Bangla launch sweep.
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/cctv_act_screens.dart';
import 'package:assisto/screens/watchman/cctvx_actions.dart';

import 'cashguard_fakes.dart';
import 'cctvact_fakes.dart';
import 'cctvx_fakes.dart';

final Map<String, Widget Function(String)> cctvactShots = {
  'cv3_alert_actions': (lang) => Scaffold(
      body: AlertActionsSheet(
          source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(),
          act: FakeCctvAct(lang: lang), preview: actEventActions())),
  'cv3_hub': (lang) => CctvActHubScreen(
      source: FakeCctvAct(lang: lang), siteId: 1, siteName: lang == 'en' ? 'Rahim Store' : 'রহিম স্টোর',
      owner: true),
  'cv3_closing_report': (lang) => CctvClosingReportScreen(
      source: FakeCctvAct(lang: lang), siteId: 1, owner: true, preview: fakeReport(lang)),
  'cv3_ask': (lang) => CctvAskScreen(
      source: FakeCctvAct(lang: lang), siteId: 1, preview: fakeAsk(lang)),
  'cv3_ask_empty': (lang) => CctvAskScreen(source: FakeCctvAct(lang: lang), siteId: 1),
  'cv3_sales_match': (lang) => CctvSalesMatchScreen(
      source: FakeCctvAct(lang: lang), siteId: 1, preview: fakeSales(lang), previewKey: fakeKey()),
  'cv3_sales_empty': (lang) => CctvSalesMatchScreen(
      source: FakeCctvAct(lang: lang), siteId: 1, preview: fakeSales(lang, empty: true),
      previewKey: fakeKey(has: false)),
  'cv3_automations_empty': (lang) => CctvAutomationsScreen(
      source: FakeCctvAct(lang: lang), siteId: 1, preview: fakeAuto(linked: false, lang: lang)),
  'cv3_automations': (lang) => CctvAutomationsScreen(
      source: FakeCctvAct(lang: lang), siteId: 1, preview: fakeAuto(lang: lang)),
};
