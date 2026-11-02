// bubbles2 gallery states for test/screenshots_test.dart (bn + en): the
// install-day "Turn on floating chat bubbles?" step, its success line, the
// honest "this phone blocks bubbles" line, My Circle settings with Turn on,
// My Circle's row of floating chats, and the in-call bubbles (stack + the
// row of round photos) over a call.
import 'package:flutter/material.dart';

import 'package:assisto/messaging/bubble_ask.dart';
import 'package:assisto/messaging/bubble_card.dart';
import 'package:assisto/messaging/in_call_bubbles.dart';
import 'package:assisto/messaging/msg_settings_section.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/bubble_chats_row.dart';

BubbleStatus _st(String pref, {bool lowRam = false}) => BubbleStatus.fromMap(
    {'sdk': 33, 'pref': pref, 'notifs': true, 'lowRam': lowRam, 'page': true});

Widget _call(bool expanded) {
  final bus = InCallBubbles()..attach();
  bus.onMessage('member:1', name: 'Rina', msgId: 'g1');
  bus.onMessage('member:2', name: 'Karim', msgId: 'g2');
  bus.onMessage('member:1', name: 'Rina', msgId: 'g3');
  return InCallBubbleHost(
    enabled: true,
    bus: bus,
    initiallyExpanded: expanded,
    resolve: (k) async => null,
    onOpen: (_) {},
    child: const Scaffold(
      backgroundColor: Brand.ink,
      body: DecoratedBox(
          decoration: BoxDecoration(gradient: Brand.heroDark),
          child: SizedBox.expand()),
    ),
  );
}

final Map<String, Widget Function(String)> bubbles2Shots = {
  'bbl2_install_day': (l) => BubbleOnboardingScreen(initial: _st('none')),
  'bbl2_install_day_on': (l) => BubbleOnboardingScreen(initial: _st('all')),
  'bbl2_phone_blocks': (l) =>
      BubbleOnboardingScreen(initial: _st('none', lowRam: true)),
  'bbl2_settings_turn_on': (l) => Scaffold(
      appBar: AppBar(),
      body: SingleChildScrollView(child: BubbleStatusTile(initial: _st('none')))),
  // the row opens a chat: in the gallery, a plain route named after it
  'bbl2_circle_row': (l) => Scaffold(
        appBar: AppBar(),
        body: Builder(
          builder: (ctx) => Column(children: [
            BubbleChatsRow(
              entries: const [
                BubbleRowEntry(key: 'member:1', name: 'Rina', unread: 2, floating: true),
                BubbleRowEntry(key: 'member:2', name: 'Karim', unread: 1, floating: true),
                BubbleRowEntry(key: 'group:3', name: 'Family', group: true, unread: 5),
              ],
              onOpen: (k) => Navigator.of(ctx).push(MaterialPageRoute<void>(
                  builder: (_) => Scaffold(appBar: AppBar(title: Text(k))))),
            ),
          ]),
        ),
      ),
  'bbl2_in_call_stack': (l) => _call(false),
  'bbl2_in_call_row': (l) => _call(true),
};
