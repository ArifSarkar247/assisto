import 'package:flutter/material.dart';

import '../feature_flags.dart';
import '../screens/family_screen.dart';
import 'family_v3_screen.dart';

/// fcscreen — the ONE entry to Family (drawer, ChatNav 'family', reminders,
/// onboarding, widget tap). Switch `family_v3` (default ON) shows the v3
/// screen; turning it off on the server brings back the old 6-tab screen
/// at once (one-tap rollback, nothing lost — the old sections are shared).
class FamilyEntry extends StatelessWidget {
  const FamilyEntry({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: FeatureFlags.instance,
        builder: (context, _) => FeatureFlags.instance.isOn('family_v3')
            ? const FamilyV3Screen()
            : const FamilyScreen(),
      );
}
