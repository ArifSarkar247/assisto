// bizai: gallery states for test/screenshots_test.dart (and therefore the
// launch Bangla sweep, a11y sweep and dead-button sweep) — shop chat,
// My shops, outcome card, shop-link card.
import 'package:flutter/material.dart';

import 'package:assisto/bizai/my_shops_screen.dart';
import 'package:assisto/bizai/outcome_card.dart';
import 'package:assisto/bizai/shop_chat_screen.dart';

import 'bizai_fakes.dart';

FakeBizai _f(String l) => FakeBizai(bn: l == 'bn');

final Map<String, Widget Function(String)> bizaiShots = {
  'bizai_shop_chat_first': (l) => ShopChatScreen(code: '12-ab34cd56', source: _f(l)),
  'bizai_shop_chat_off': (l) => ShopChatScreen(code: '12-ab34cd56', source: _f(l)..chatOk = false),
  'bizai_my_shops_empty': (l) => MyShopsScreen(source: _f(l)),
  'bizai_outcome_card': (l) => Scaffold(
      body: ListView(padding: const EdgeInsets.all(16), children: [OutcomeCard(source: _f(l))])),
  'bizai_outcome_empty': (l) => Scaffold(
      body: ListView(padding: const EdgeInsets.all(16), children: [
        OutcomeCard(source: _f(l)..out = {'empty': true, 'total_bdt': '0', 'rows': []})
      ])),
  'bizai_shop_link_card': (l) => Scaffold(
      body: ListView(padding: const EdgeInsets.all(16), children: [ShopLinkCard(source: _f(l))])),
};
