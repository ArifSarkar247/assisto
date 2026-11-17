// fcelder: gallery states for test/screenshots_test.dart — Screen 4 Elder
// Easy Home, the Are-you-OK screen, setup by a child (form + QR), the elder's
// spoken consent, and the family's Silent Watch (alert / no alert / empty).
import 'package:flutter/material.dart';

import 'package:assisto/eldercare/are_you_ok_screen.dart';
import 'package:assisto/eldercare/elder_common.dart';
import 'package:assisto/eldercare/elder_easy_home.dart';
import 'package:assisto/eldercare/elder_join_screen.dart';
import 'package:assisto/eldercare/elder_setup_screen.dart';
import 'package:assisto/eldercare/elder_watch_screen.dart';

import 'fcelder_fakes.dart';

Widget _with(Widget w, {Map<String, dynamic>? status}) {
  ElderHooks.apiOverride = FakeSilentWatchApi(statusBody: status);
  ElderHooks.voice = SpokenRecorder();
  return w;
}

final Map<String, Widget Function(String)> fcelderShots = {
  'fce_easy_home': (l) => _with(ElderEasyHome(
      debugFamily: fceFamily, debugName: l == 'bn' ? 'রহিমা' : 'Rahima')),
  'fce_easy_home_empty': (l) => _with(ElderEasyHome(debugFamily: const [], debugName: 'Rahima')),
  'fce_are_you_ok': (l) => _with(const AreYouOkScreen()),
  // gap-familycare: "Talk to Assisto" now SHOWS and SAYS the answer
  'fcg_elder_reply': (l) => _with(ElderEasyHome(
      debugFamily: fceFamily,
      debugName: l == 'bn' ? 'রহিমা' : 'Rahima',
      debugReply: l == 'bn'
          ? ('আজ কি বৃষ্টি হবে?',
              '**সংক্ষেপে:** আজ বিকেলে ঢাকায় বৃষ্টি হতে পারে।\n\n- বাইরে গেলে ছাতা নিন\n- ওষুধ শুকনো জায়গায় রাখুন\n\nআর কিছু জানতে চাইলে আবার বলুন।')
          : ('Will it rain today?',
              '**In short:** rain is likely in Dhaka this afternoon.\n\n- Take an umbrella if you go out\n- Keep your medicines dry\n\nAsk me again if you want to know more.'))),
  'fce_setup_form': (l) => _with(const ElderSetupScreen(debugPeople: [
        {'user_id': 2, 'name': 'Ammu', 'relation': 'mother'},
        {'user_id': 3, 'name': 'Bina', 'relation': 'sister'},
      ])),
  'fce_setup_empty': (l) => _with(const ElderSetupScreen(debugPeople: [])),
  'fce_setup_qr': (l) => _with(const ElderSetupScreen(debugPeople: [], debugPair: {
        'code': 'KQ7M2XPA', 'url': 'https://lifeassisto.com/e/KQ7M2XPA', 'ttl_s': 900,
        'elder_name': 'Ammu', 'plan': {'easy_home': true},
      })),
  'fce_consent': (l) => _with(const ElderJoinScreen(debugPreview: {
        'child_name': 'Arif', 'hours': 4,
        'plan': {'easy_home': true, 'carecall': true, 'silent_watch': true},
      })),
  'fce_watch_alert': (l) => _with(ElderWatchScreen(debugStatus: fceWatching())),
  'fce_watch_none': (l) => _with(ElderWatchScreen(debugStatus: fceWatching(status: ''))),
  'fce_watch_empty': (l) =>
      _with(const ElderWatchScreen(debugStatus: {'mine': null, 'watching': [], 'family': []})),
};
