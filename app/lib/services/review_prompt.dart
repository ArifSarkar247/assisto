import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'review_prompt_impl.dart' deferred as impl;

/// Google Play In-App Review at a happy moment (missing person FOUND and the
/// family chose to share thanks; the blood-donor "blood found" flow reuses it).
///
/// Play policy, kept on purpose:
///  * never ask "do you like the app?" (or any question) before the card;
///  * never offer anything (credits, rewards) for a review or a post;
///  * Play itself decides whether the card shows (it has its own quota).
/// Lazy (deferred library, Play build only) and crash-guarded: any failure
/// (sideloaded APK, no Play account, old Play Store) is ignored.
class ReviewPrompt {
  ReviewPrompt._();

  static const _key = 'review_prompt_last_ms';
  static const minGap = Duration(days: 120);

  /// Tests replace the Play call.
  static Future<void> Function()? debugRequest;

  /// Returns true when the Play card was requested.
  static Future<bool> maybeAsk({DateTime? now}) async {
    try {
      if (!AppConfig.playStore && debugRequest == null) return false;
      final prefs = await SharedPreferences.getInstance();
      final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
      final last = prefs.getInt(_key) ?? 0;
      if (last > 0 && at - last < minGap.inMilliseconds) return false;
      await prefs.setInt(_key, at);
      if (debugRequest != null) {
        await debugRequest!();
      } else {
        await impl.loadLibrary();
        await impl.requestReview();
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
