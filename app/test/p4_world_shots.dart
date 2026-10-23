// p4-world: Unseen World gallery states for test/screenshots_test.dart — the
// hub (search connected), Today cards, an answered web question with sources,
// the jobs hub, the Expats / Government / Farmers hubs and BCS practice.
import 'package:flutter/material.dart';

import 'package:assisto/screens/world/world_ask_screen.dart';
import 'package:assisto/screens/world/world_guide_hub_screen.dart';
import 'package:assisto/screens/world/world_hub_screen.dart';
import 'package:assisto/screens/world/world_jobs_screen.dart';
import 'package:assisto/screens/world/world_mcq_screen.dart';
import 'package:assisto/screens/world/world_today_screen.dart';

import 'world_fake.dart';

Map<String, dynamic> _answer(String lang) {
  final bn = lang == 'bn';
  return {
    '_status': 200,
    'ok': true,
    'question':
        bn ? 'ই-পাসপোর্ট কীভাবে নবায়ন করব?' : 'How do I renew an e-passport?',
    'answer': bn
        ? 'ই-পাসপোর্ট নবায়নের আবেদন অনলাইনে করা যায় [1]। ফি পাতা ও মেয়াদ অনুযায়ী আলাদা [2]।'
        : 'You can apply to renew an e-passport online [1]. The fee depends on pages and validity [2].',
    'sources': [
      {
        'n': 1,
        'title': 'e-Passport Online Registration',
        'url': 'https://www.epassport.gov.bd',
        'site': 'epassport.gov.bd'
      },
      {
        'n': 2,
        'title': 'Passport fees',
        'url': 'https://www.epassport.gov.bd/instructions/passport-fees',
        'site': 'epassport.gov.bd'
      },
    ],
    'caution': <String>[],
    'cached': false,
    'charged': 4,
  };
}

final Map<String, Widget Function(String)> p4WorldShots = {
  'p4_world_hub': (l) => WorldHubScreen(api: FakeWorldApi(lang: l)),
  'p4_world_today': (l) => WorldTodayScreen(api: FakeWorldApi(lang: l)),
  'p4_world_ask_welcome': (l) =>
      WorldAskScreen(api: FakeWorldApi(lang: l), credits: 4),
  'p4_world_ask_answer': (l) => WorldAskScreen(
      api: FakeWorldApi(lang: l), credits: 4, initial: _answer(l)),
  'p4_world_jobs': (l) =>
      WorldJobsScreen(api: FakeWorldApi(lang: l, alertsReady: true)),
  'p4_world_expat': (l) =>
      WorldGuideHubScreen(hubId: 'expat', api: FakeWorldApi(lang: l)),
  'p4_world_gov': (l) =>
      WorldGuideHubScreen(hubId: 'gov', api: FakeWorldApi(lang: l)),
  'p4_world_farmers': (l) => WorldGuideHubScreen(
      hubId: 'farmers', api: FakeWorldApi(lang: l, aiReady: false)),
  'p4_world_mcq': (l) => WorldMcqScreen(api: FakeWorldApi(lang: l)),
};
