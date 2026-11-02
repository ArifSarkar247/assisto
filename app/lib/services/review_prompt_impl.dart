// missing (owner 2 Nov): the ONLY file that imports in_app_review. Loaded as
// a deferred library by review_prompt.dart, in the Play build only.
import 'package:in_app_review/in_app_review.dart';

/// Asks Google Play to show its own review card. Play decides whether it is
/// shown (quota); nothing here asks "do you like the app?" first.
Future<void> requestReview() async {
  final r = InAppReview.instance;
  if (await r.isAvailable()) {
    await r.requestReview();
  }
}
