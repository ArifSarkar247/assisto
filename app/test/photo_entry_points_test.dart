// Owner order (21 Oct): the old enhance tool is removed; EVERY entry point
// (home button, sidebar, Discover card, saved quick buttons, chat commands)
// opens Photo Studio, so no image can leave without the ad/credit rule.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/sidebar_sections.dart';

void main() {
  testWidgets('route keys used by home/Discover/chat open Photo Studio',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }));
    for (final key in ['photo_enhance', 'photo_studio']) {
      expect(ChatNav.routes[key]!(ctx), isA<PhotoStudioScreen>(), reason: key);
    }
  });

  testWidgets('the sidebar has exactly one photo tool: Photo Studio',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }));
    final photo = [
      for (final s in SidebarSections.all)
        for (final i in s.items)
          if (i.synonyms.contains('enhance') || i.synonyms.contains('photo')) i
    ];
    expect(photo, hasLength(1));
    expect(photo.single.builder(ctx), isA<PhotoStudioScreen>());
  });
}
