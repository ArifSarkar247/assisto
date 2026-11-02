// cctvteam (W11): gallery states for test/screenshots_test.dart (and the
// a11y + dead-button sweeps) — multi-site grid, roles, share links, access
// log, private neighbourhood watch.
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/cctv_grid_screen.dart';
import 'package:assisto/screens/watchman/cctv_team_screens.dart';
import 'package:assisto/screens/watchman/cctv_watch_screen.dart';

import 'cctvteam_fakes.dart';

final Map<String, Widget Function(String)> cctvteamShots = {
  'ctm_grid_owner': (lang) => CctvGridScreen(source: FakeCctvTeam('data', lang: lang)),
  'ctm_grid_guard': (lang) => CctvGridScreen(source: FakeCctvTeam('guard', lang: lang)),
  'ctm_grid_empty': (lang) => CctvGridScreen(source: FakeCctvTeam('empty', lang: lang)),
  'ctm_grid_error': (lang) => CctvGridScreen(source: FakeCctvTeam('fail', lang: lang)),
  'ctm_links': (lang) => CctvShareLinksScreen(source: FakeCctvTeam('data', lang: lang), siteId: 1, siteName: 'Rahim Store'),
  'ctm_links_empty': (lang) => CctvShareLinksScreen(source: FakeCctvTeam('empty', lang: lang), siteId: 1),
  'ctm_access_log': (lang) => CctvAccessLogScreen(source: FakeCctvTeam('data', lang: lang), siteId: 1),
  'ctm_access_log_empty': (lang) => CctvAccessLogScreen(source: FakeCctvTeam('empty', lang: lang), siteId: 1),
  'ctm_watch_groups': (lang) => CctvWatchScreen(source: FakeCctvTeam('data', lang: lang)),
  'ctm_watch_empty': (lang) => CctvWatchScreen(source: FakeCctvTeam('empty', lang: lang)),
  'ctm_watch_posts': (lang) =>
      CctvWatchGroupScreen(source: FakeCctvTeam('data', lang: lang), groupId: 21, name: lang == 'bn' ? 'রোড ৩ পাহারা' : 'Road 3 watch'),
  'ctm_role_sheet': (lang) => Scaffold(
      body: CctvRoleSheet(
          source: FakeCctvTeam('data', lang: lang),
          siteId: 1,
          viewer: const {'user_id': 12, 'name': 'Jamal', 'role': 'guard', 'cameras': [5], 'all_cameras': false, 'live_ok': true})),
  'ctm_watch_share_sheet': (lang) => Scaffold(body: CctvWatchShareSheet(source: FakeCctvTeam('data', lang: lang), camera: 5)),
  'ctm_camera_sheet': (lang) => Scaffold(
      body: CctvCameraSheet(
          source: FakeCctvTeam('data', lang: lang),
          site: const {'id': 1, 'name': 'Rahim Store'},
          camera: const {'id': 5, 'name': 'Gate', 'status': 'online', 'still_url': 'mem://gate',
            'still_at': null, 'still_source': 'check', 'fresh_supported': true, 'live_capable': true, 'live_ok': true})),
};
