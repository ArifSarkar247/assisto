import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'elder_join_screen.dart';
import 'elder_setup_screen.dart';
import 'elder_watch_screen.dart';

/// fcelder — the Family screen's "More" rows (fcscreen FcSlots.moreRows):
/// Silent Watch, set up a parent's phone (QR), set up MY phone (code).
/// Registered in app/lib/family_v3/fc_slots_register.dart (one line).
List<Widget> fcelderMoreRows(BuildContext context, int familyId) {
  final t = AppLocalizations.of(context);
  void go(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
  return [
    ListTile(
      key: const Key('fce-more-watch'),
      leading: const Icon(Icons.shield_moon_rounded),
      title: Text(t.fceWatchTitle),
      subtitle: Text(t.fceMoreWatchSub),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => go(const ElderWatchScreen()),
    ),
    ListTile(
      key: const Key('fce-more-setup'),
      leading: const Icon(Icons.qr_code_2_rounded),
      title: Text(t.fceMoreSetupParent),
      subtitle: Text(t.fceSetupBenefit),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => go(const ElderSetupScreen()),
    ),
    ListTile(
      key: const Key('fce-more-mine'),
      leading: const Icon(Icons.phone_android_rounded),
      title: Text(t.fceMoreSetupMine),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => go(const ElderJoinScreen()),
    ),
  ];
}
