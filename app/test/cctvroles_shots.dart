// cctvroles (CCTV Guard V3 I + J): gallery states for test/screenshots_test.dart
// — the owner's audit list (exports / changes / deletes), the role sheet with
// STAFF, the owner's installer screen + code sheet, and the technician's
// installer-partner screen (apply / pending / setup status only).
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/cctv_installer_screens.dart';
import 'package:assisto/screens/watchman/cctv_team_screens.dart';

import 'cctvteam_fakes.dart';

final Map<String, Widget Function(String)> cctvrolesShots = {
  'ctr_audit_log': (lang) => CctvAccessLogScreen(source: FakeCctvTeam('audit', lang: lang), siteId: 1),
  'ctr_role_staff': (lang) => Scaffold(
      body: CctvRoleSheet(
          source: FakeCctvTeam('data', lang: lang),
          siteId: 1,
          viewer: const {'user_id': 14, 'name': 'Sumon', 'role': 'staff', 'cameras': [], 'all_cameras': true, 'live_ok': false})),
  'ctr_installer_owner': (lang) => CctvInstallerScreen(source: FakeCctvTeam('data', lang: lang), siteId: 1),
  'ctr_installer_empty': (lang) => CctvInstallerScreen(source: FakeCctvTeam('empty', lang: lang), siteId: 1),
  'ctr_installer_code': (lang) => const Scaffold(
      body: CctvInstallerCodeSheet(code: 'K7MPQ2XR', qr: 'https://lifeassisto.com/install/K7MPQ2XR', hours: 48)),
  'ctr_partner_sites': (lang) => CctvPartnerScreen(source: FakeCctvTeam('data', lang: lang)),
  'ctr_partner_apply': (lang) => CctvPartnerScreen(source: FakeCctvTeam('empty', lang: lang)),
  'ctr_partner_pending': (lang) => CctvPartnerScreen(source: FakeCctvTeam('pending', lang: lang)),
};
