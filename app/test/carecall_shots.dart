// carecall: gallery states for test/screenshots_test.dart — the owner's three
// Care Call screens (compare with the approved mockup), + empty / consent.
import 'package:flutter/material.dart';

import 'package:assisto/carecall/carecall_new_screen.dart';
import 'package:assisto/carecall/carecall_ring_screen.dart';
import 'package:assisto/carecall/carecall_screen.dart';

import 'carecall_fakes.dart';

final Map<String, Widget Function(String)> carecallShots = {
  // SCREEN 1 — setter, New Care Call (filled: Ammu, text, 9:00 daily, own voice)
  'cc_screen1': (l) => CareCallNewScreen(
      api: FakeCareCallApi(),
      person: ccPerson(l),
      debugText: l == 'bn' ? 'গ্যাসের ট্যাবলেটটা খাও' : 'Take your gas tablet',
      debugVoiceSec: 7),
  // SCREEN 1 — nothing picked yet (the example hint + chips)
  'cc_screen1_blank': (l) => CareCallNewScreen(api: FakeCareCallApi()),
  // SCREEN 2 — receiver, incoming Care Call (full screen)
  'cc_screen2': (l) => CareCallRingScreen(data: ccRing(l), sound: FakeSound(), autoPlay: false),
  // SCREEN 3 — setter notifications: confirmed + amber did-not-answer
  'cc_screen3': (l) => CareCallScreen(api: FakeCareCallApi(mine: ccMine(l)), debugMine: ccMine(l)),
  'cc_consent': (l) => CareCallScreen(
      api: FakeCareCallApi(mine: ccMine(l, invite: true)), debugMine: ccMine(l, invite: true, location: false)),
  'cc_empty': (l) => CareCallScreen(api: FakeCareCallApi(), debugMine: ccMine(l, empty: true)),
};
