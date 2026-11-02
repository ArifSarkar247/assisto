// remhbar (2 Nov): gallery states for test/screenshots_test.dart (and so the
// a11y guideline sweep + dead-button sweep) — Reminders & Notes launch bar.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:assisto/reminders/exact_alarm_ui.dart';
import 'package:assisto/screens/notes_todos_screen.dart';
import 'package:assisto/state.dart';

final Map<String, Widget Function(String)> remhbarShots = {
  // "will it ring on time?" with the restart / Autostart line
  'remhbar_delivery': (_) => const ReminderDeliverySheet(),
  // a note changed on two phones: both copies kept + the honest strip
  'remhbar_notes_conflict': (_) => Builder(builder: (c) {
        c.read<AppState>().notes.conflicts = 1;
        return const NotesTodosScreen();
      }),
};
