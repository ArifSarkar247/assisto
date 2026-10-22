import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';

/// The UI's locale tag for DISPLAY-only DateFormat calls (QA qa1: formatters
/// without a locale printed "22 Oct, 8:00 PM" in the Bangla UI). Never use it
/// for API keys like yyyy-MM-dd — the Bangla locale writes Bangla digits.
String appDateLocale(BuildContext context) =>
    Localizations.localeOf(context).toLanguageTag();

/// QA qa1: CLDR's Bangla date data spells the day period in English
/// (Bangla digits followed by a Latin "PM"), so every `DateFormat.jm()` / `add_jm()` in the Bangla UI showed
/// a Latin "AM"/"PM" next to Bangla digits. This delegate — listed AFTER
/// GlobalMaterialLocalizations.delegate, which loads intl's date data —
/// replaces the Bangla day-period names with the app's own ARB words
/// (mr1Am and mr1Pm, the same words the last-seen line uses), once, for every
/// formatter in the app.
class BnDayPeriods {
  const BnDayPeriods._();

  static const LocalizationsDelegate<BnDayPeriods> delegate = _Delegate();

  static bool _done = false;

  /// Idempotent; safe to call before the date data exists (it just retries
  /// on the next locale load).
  static void apply() {
    if (_done) return;
    try {
      final t = lookupAppLocalizations(const Locale('bn'));
      DateFormat('a', 'bn').dateSymbols.AMPMS = [t.mr1Am, t.mr1Pm];
      _done = true;
    } on Object catch (e) {
      debugPrint('BnDayPeriods: Bangla date data not ready yet ($e)');
    }
  }
}

class _Delegate extends LocalizationsDelegate<BnDayPeriods> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<BnDayPeriods> load(Locale locale) {
    if (locale.languageCode == 'bn') BnDayPeriods.apply();
    return SynchronousFuture(const BnDayPeriods._());
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<BnDayPeriods> old) => false;
}
