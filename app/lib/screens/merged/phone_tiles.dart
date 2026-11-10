import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../lost_stolen_screen.dart';
import '../my_lost_phone_screen.dart';
import '../phone_safety_screen.dart';
import '../security_screen.dart';
import '../sell_my_phone_screen.dart';
import '../used_phone_check_screen.dart';
import 'service_sections_screen.dart';

/// svcclean — LOST PHONE (one tile): "My lost phone" (act now) first, then
/// "Lost or Stolen Pro" (protect before). Old routes `my_lost_phone` and
/// `lost_stolen` open this and then that section (see [ServiceSectionsScreen]).
class LostPhoneTileScreen extends StatelessWidget {
  final String? open;
  const LostPhoneTileScreen({super.key, this.open});

  /// The canonical route of this tile (ChatNav key kept from before).
  static const route = 'lost_stolen';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ServiceSectionsScreen(
      title: t.svcLostPhone,
      intro: t.svcLostIntro,
      open: open,
      sections: [
        ServiceSection(
            id: 'my_lost_phone',
            icon: Icons.travel_explore_rounded,
            title: t.svcLostNowTitle,
            subtitle: t.svcLostNowSub,
            builder: (_) => const MyLostPhoneScreen()),
        ServiceSection(
            id: 'lost_stolen',
            icon: Icons.phonelink_lock_rounded,
            title: t.svcLostProtTitle,
            subtitle: t.svcLostProtSub,
            builder: (_) => const LostStolenScreen()),
      ],
    );
  }
}

/// svcclean — PHONE SAFETY (one tile): Safety check-up, Ownership
/// protection, Sell my phone safely, Used phone check as sections. Old routes
/// `phone_safety`, `security`, `sell_phone`, `used_phone_check` land here.
class PhoneSafetyTileScreen extends StatelessWidget {
  final String? open;
  const PhoneSafetyTileScreen({super.key, this.open});

  static const route = 'phone_safety';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ServiceSectionsScreen(
      title: t.svcPhoneSafety,
      intro: t.svcSafetyIntro,
      open: open,
      sections: [
        ServiceSection(
            id: 'phone_safety',
            icon: Icons.security_rounded,
            title: t.phoneSafetyTitle,
            subtitle: t.svcSafetyCheckSub,
            builder: (_) => const PhoneSafetyScreen()),
        ServiceSection(
            id: 'security',
            icon: Icons.shield_rounded,
            title: t.securityTitle,
            subtitle: t.svcSafetyOwnSub,
            builder: (_) => const SecurityScreen()),
        ServiceSection(
            id: 'sell_phone',
            icon: Icons.sell_rounded,
            title: t.upSellTitle,
            subtitle: t.svcSafetySellSub,
            builder: (_) => const SellMyPhoneScreen()),
        ServiceSection(
            id: 'used_phone_check',
            icon: Icons.phonelink_setup_rounded,
            title: t.upCheckTitle,
            subtitle: t.svcSafetyUsedSub,
            builder: (_) => const UsedPhoneCheckScreen()),
      ],
    );
  }
}
