// cctvescalate: gallery states (test/screenshots_test.dart) — alert actions
// with light / recorded warning / 999 card, the police card, the camera
// capability table, the warning recorder, the CCTV alarm call page.
import 'package:flutter/material.dart';

import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/watchman/cctv_alarm_call_screen.dart';
import 'package:assisto/screens/watchman/cctv_escalate.dart';
import 'package:assisto/screens/watchman/cctvx_actions.dart';

import 'cashguard_fakes.dart';
import 'cctvescalate_fakes.dart';
import 'cctvx_fakes.dart';

PushPayload kFakeAlarmCall([String lang = 'bn']) => PushPayload.fromData({
      'kind': 'call', 'call_id': 'cctv-201-21-0', 'caller_name': 'Assisto সতর্কতা',
      'video': 'false', 'cctv_event_id': '201', 'snapshot_url': '',
      'site_name': lang == 'en' ? 'Rahim Store' : 'রহিম স্টোর',
      'camera_name': lang == 'en' ? 'Door' : 'দরজা', 'lang': lang,
    });

final Map<String, Widget Function(String)> cctvescalateShots = {
  'cesc_alert_actions': (_) => Scaffold(
      body: AlertActionsSheet(
          source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(),
          escalate: FakeEscalate(), preview: escalateActions())),
  'cesc_alert_actions_ezviz': (_) => Scaffold(
      body: AlertActionsSheet(
          source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(),
          escalate: FakeEscalate(hasClip: true),
          preview: escalateActions(deter: kFakeDeterEzviz))),
  'cesc_police_card': (_) =>
      Scaffold(body: PoliceCardSheet(source: FakeCctvx(), police: kFakePolice)),
  'cesc_police_card_no_address': (_) => Scaffold(
      body: PoliceCardSheet(
          source: FakeCctvx(),
          police: {...kFakePolice, 'address_missing': true})),
  'cesc_capability_table': (lang) => Scaffold(
      body: CapabilityTable(rows: deterRows(kFakeDeter, lang))),
  'cesc_warn_clip': (_) => Scaffold(
      body: WarnClipSheet(
          source: FakeEscalate(), siteId: 1,
          preview: const {'site': 1, 'has_clip': false, 'max_seconds': 20, 'lines': [
            'সতর্কতা! এই জায়গা ক্যামেরায় রেকর্ড হচ্ছে। মালিককে জানানো হয়েছে। এখনই চলে যান।',
            'দোকান বন্ধ। ভেতরে ঢোকা নিষেধ। ক্যামেরা চালু আছে।',
          ]})),
  'cesc_alarm_call': (lang) =>
      CctvAlarmCallScreen(payload: kFakeAlarmCall(lang), onOpen: (_, __) {}),
};
