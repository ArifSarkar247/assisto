// launchsweep (2 Nov): Flutter's built-in TextField counter is always
// '$current/$max' in ASCII digits — "0/120" on a Bangla screen. Every
// TextField with a maxLength passes `buildCounter: localCounter` instead
// (guarded by test/local_counter_guard_test.dart).
import 'package:flutter/material.dart';

import '../messaging/date_separators.dart' show localDigits;

/// The TextField counter in the screen's digits (Bangla digits in Bangla),
/// with the same look and TalkBack text as Flutter's own counter.
Widget? localCounter(BuildContext context,
    {required int currentLength, required bool isFocused, required int? maxLength}) {
  final lang = Localizations.localeOf(context).languageCode;
  final hasMax = maxLength != null && maxLength > 0;
  final text = hasMax ? '$currentLength/$maxLength' : '$currentLength';
  final ml = MaterialLocalizations.of(context);
  return Semantics(
    liveRegion: isFocused,
    label: hasMax
        ? ml.remainingTextFieldCharacterCount((maxLength - currentLength).clamp(0, maxLength))
        : null,
    excludeSemantics: hasMax,
    child: Text(localDigits(text, lang)),
  );
}
