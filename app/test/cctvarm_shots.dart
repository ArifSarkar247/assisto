// cctvarm: gallery states for test/screenshots_test.dart — Auto guard
// (owner: armed by family / someone home + privacy / first run, member
// consent, SOS home live + its empty state).
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/auto_guard_screen.dart';

import 'cctvarm_fakes.dart';

Future<void> _noop() async {}

final Map<String, Widget Function(String)> cctvarmShots = {
  'carm_owner_armed': (_) => AutoGuardScreen(
      source: FakeAutoGuard(data: FakeAutoGuard.ownerData(armed: true, summary: 'all_away')),
      siteId: 1,
      onConsentYes: _noop),
  'carm_owner_privacy': (_) => AutoGuardScreen(
      source: FakeAutoGuard(data: FakeAutoGuard.ownerData(summary: 'someone_home', privacy: true)),
      siteId: 1,
      onConsentYes: _noop),
  'carm_owner_unknown': (_) => AutoGuardScreen(source: FakeAutoGuard(), siteId: 1, onConsentYes: _noop),
  'carm_owner_first': (_) => AutoGuardScreen(
      source: FakeAutoGuard(
          data: FakeAutoGuard.ownerData(familyOn: false, summary: 'off', cams: false, people: false, log: false)),
      siteId: 1,
      onConsentYes: _noop),
  'carm_member_ask': (_) => AutoGuardScreen(
      source: FakeAutoGuard(mine: {
        'sites': [
          {'site': 1, 'name': 'Home', 'owner_name': 'Rahim', 'consent': false, 'state': 'no_consent'}
        ]
      }),
      siteId: 1,
      owner: false,
      onConsentYes: _noop),
  'carm_sos_live': (_) => SosLiveScreen(
      source: FakeAutoGuard(sos: {
        'grants': [
          {
            'site': 1,
            'name': 'Home',
            'by_name': 'Karima',
            'until': '2026-11-03T09:00:00+06:00',
            'cameras': [
              {'id': 11, 'name': 'Living room', 'online': true, 'live': true},
              {'id': 12, 'name': 'Gate', 'online': false, 'live': true},
            ]
          }
        ]
      })),
  'carm_sos_none': (_) => SosLiveScreen(source: FakeAutoGuard()),
};
