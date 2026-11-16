import 'package:flutter/material.dart';

import 'ad_spot_card.dart';

/// adwire (owner ads order 10 Nov 03:45, part D): the after-call review
/// native card — the ONE ad the call screen may show, and only on the
/// ENDED screen next to the "How was the call?" row (never during a call).
/// The call screen decides the never-cases first ([afterCallAdAllowed] in
/// lib/calls/call_rating.dart: no SOS / emergency / Care Call call, no call
/// under 10 s, no missed / declined / dropped call); this card then needs a
/// Free user and the owner's switch `after_call_review` on with type native
/// ([AdControl]). Premium / Plus never. No fill = no space.
class AfterCallReviewAd extends StatelessWidget {
  const AfterCallReviewAd({super.key, this.onResult});

  /// true = an ad is showing; false = none (the screen may close).
  final ValueChanged<bool>? onResult;

  static const placement = 'after_call_review';

  @override
  Widget build(BuildContext context) =>
      AdSpotCard(placement: 'after_call_review', onResult: onResult);
}
