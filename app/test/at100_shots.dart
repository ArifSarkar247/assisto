// at100 gallery states for test/screenshots_test.dart: the remote switches
// (owner online / phone offline / trusted contact before + after lost mode),
// the trusted contact's watched phones (list + empty) and the intruder-photo
// consent screen.
import 'package:flutter/material.dart';

import 'package:assisto/screens/intruder_consent_screen.dart';
import 'package:assisto/screens/watched_phones_screen.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/remote_switches_card.dart';

import 'at100_fakes.dart';

Widget _card(String title, Map<String, dynamic> d) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        RemoteSwitchesCard(load: () async => d),
      ]),
    );

final Map<String, Widget Function(String)> at100Shots = {
  'at100_switches_owner': (l) => _card(l == 'bn' ? 'হারানো/চুরি ফোন' : 'Lost / stolen phone',
      at100FakeCommands(bn: l == 'bn')),
  'at100_switches_offline': (l) => _card(l == 'bn' ? 'হারানো/চুরি ফোন' : 'Lost / stolen phone',
      at100FakeCommands(bn: l == 'bn', online: false, lostMode: true)),
  'at100_switches_trusted_before': (l) => _card(l == 'bn' ? 'আরিফ-এর ফোন' : "Arif's phone",
      at100FakeCommands(bn: l == 'bn', trusted: true, empty: true, active: false)),
  'at100_switches_trusted_lost': (l) => _card(l == 'bn' ? 'আরিফ-এর ফোন' : "Arif's phone",
      at100FakeCommands(bn: l == 'bn', trusted: true, lostMode: true)),
  'at100_watch_list': (l) => WatchedPhonesScreen(
      load: () async => {'watching': at100FakeWatching(l == 'bn')}),
  'at100_watch_empty': (l) =>
      WatchedPhonesScreen(load: () async => {'watching': <Map>[]}),
  'at100_consent': (l) => const IntruderConsentScreen(),
};
