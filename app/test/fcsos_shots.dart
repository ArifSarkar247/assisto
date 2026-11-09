// fcsos: gallery states for test/screenshots_test.dart — Family Care v3
// SCREEN 2 (SOS sender: countdown / sent + recording / no internet) and
// SCREEN 3 (SOS receiver alarm: active / sent by mistake) + "Get SOS ready".
import 'package:flutter/material.dart';

import 'package:assisto/family_sos/sos_alarm_screen.dart';
import 'package:assisto/family_sos/sos_sender_screen.dart';
import 'package:assisto/family_sos/sos_setup_card.dart';
import 'package:assisto/family_sos/sos_sms.dart';

import 'fcsos_fakes.dart';

List<SosSmsContact> fcsSms(String l) => [
      SosSmsContact(l == 'bn' ? 'আম্মু' : 'Ammu', '01711200002'),
      SosSmsContact(l == 'bn' ? 'ভাইয়া' : 'Bhai', '01711200003'),
    ];

final Map<String, Widget Function(String)> fcsosShots = {
  'fcs_countdown': (l) => SosSenderScreen(
      api: FakeFcSosApi(lang: l),
      recorder: FakeSosRecorder(),
      country: 'BD',
      smsContacts: fcsSms(l),
      debugPhase: SosPhase.countdown),
  'fcs_sent': (l) => SosSenderScreen(
      api: FakeFcSosApi(lang: l)
        ..goingList = [
          {'name': l == 'bn' ? 'ভাইয়া' : 'Bhai', 'at': '2026-11-09T04:41:00Z', 'me': false}
        ],
      recorder: FakeSosRecorder(),
      country: 'BD',
      smsContacts: fcsSms(l),
      debugPhase: SosPhase.sent,
      debugRecipients: 3,
      debugRecState: 'recording'),
  'fcs_offline': (l) => SosSenderScreen(
      api: FakeFcSosApi(lang: l),
      recorder: FakeSosRecorder(),
      country: 'BD',
      smsContacts: fcsSms(l),
      debugPhase: SosPhase.offline),
  'fcs_alarm': (l) => SosAlarmScreen(
      data: fcsPush(l),
      api: FakeFcSosApi(lang: l),
      sound: FakeAlarmSound(),
      autoAlarm: false,
      pollEvery: const Duration(hours: 1)),
  'fcs_alarm_mistake': (l) => SosAlarmScreen(
      data: fcsPush(l),
      api: FakeFcSosApi(lang: l, ev: fcsEvent(l, state: 'mistake', info: false)),
      sound: FakeAlarmSound(),
      autoAlarm: false,
      pollEvery: const Duration(hours: 1)),
  'fcs_setup': (l) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            SosSetupCard(
              api: FakeFcSosApi(lang: l)..share = true,
              sms: fcsSms(l),
              dndGranted: () async => false,
              dndEnsure: (a, b) async => false,
              fullScreen: () async => false,
            ),
          ]),
        ),
      ),
};
