// home_v2 gallery states for test/screenshots_test.dart (and so for the
// dead-button + a11y sweeps): the new home with badges, the All Services
// catalogue, the AI chat screen and the shortcut picker.
import 'package:flutter/material.dart';

import 'package:assisto/home_api.dart';
import 'package:assisto/screens/home_v2/all_services_screen.dart';
import 'package:assisto/screens/home_v2/assisto_chat_screen.dart';
import 'package:assisto/screens/home_v2/home_v2_screen.dart';
import 'package:assisto/screens/home_v2/home_v2_shortcuts.dart';
import 'package:assisto/widgets/circle_badges.dart';
import 'package:assisto/widgets/home_hero.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';

import 'h1_home_fakes.dart';

/// The home as the owner sees it in the reference: 09:00, 2 new
/// notifications, 3 unread in My Circle + a missed call.
Widget homeV2Shot({bool free = false, String? size, DateTime? now}) {
  HomeHero.debugReset();
  HomeHero.debugBridge = FakeHeroBridge();
  HomeHero.debugLoadConfig =
      () async => heroConfig(plan: free ? 'free' : 'premium', size: size);
  return HomeV2Screen(
    debugNow: now ?? DateTime(2026, 10, 26, 9),
    debugBadges: const HomeBadges(myCircleUnread: 3, notifUnseen: 2),
    debugCircle: const CircleBadgeState(unread: 3, missed: true),
  );
}

final Map<String, Widget Function(String)> homeV2Shots = {
  'home_v2': (_) => homeV2Shot(),
  'home_v2_free_ad': (_) => homeV2Shot(free: true),
  'home_v2_all_services': (_) => const AllServicesScreen(),
  'home_v2_chat': (_) => const AssistoChatScreen(fresh: true),
  'home_v2_picker': (_) => Scaffold(
        body: Builder(builder: (_) {
          final cat = HomeV2Shortcuts.catalog;
          return QuickButtonsPicker(
            current: HomeV2Shortcuts.defaults(),
            resetTo: HomeV2Shortcuts.defaults(),
            max: HomeV2Shortcuts.max,
            catalog: cat,
            lookup: (r) => HomeV2Shortcuts.byRoute(r, cat),
            title: (t) => t.hv2PickTitle,
            hint: (t, n) => t.hv2PickHint(circleBadgeLabel(n, t.localeName)),
            requireFull: false,
          );
        }),
      ),
};
