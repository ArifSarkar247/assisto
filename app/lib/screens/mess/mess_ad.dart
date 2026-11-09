import 'package:flutter/material.dart';

import '../../ads/ad_banner_slot.dart';

/// messv2 (owner order L): ONE small banner at the bottom of the mess
/// screens for FREE users only. AdBannerSlot already hides it for Premium /
/// Business, when the server switch is off, while a keyboard is open, and it
/// takes no space without a fill. Never inside the mess group chat (that is a
/// conversation screen with no ad slot at all).
class MessAdBanner extends StatelessWidget {
  const MessAdBanner({super.key});

  @override
  Widget build(BuildContext context) => const AdBannerSlot(screen: 'mess');
}
