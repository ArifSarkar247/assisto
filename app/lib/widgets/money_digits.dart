import 'package:flutter/widgets.dart';

/// moneybar: Bangla digits for the money-tool screens.
///
/// The calculators and money tools format numbers in many small pure helpers
/// (fmtTaka, fmtPoisha, fmtBdt, …) that have no BuildContext. Each money-tool
/// screen calls [syncMoneyDigits] at the top of its build(); the helpers then
/// pass their output through [moneyDigits], which swaps Latin digits for
/// Bangla ones while the UI is Bangla. Only one locale is active app-wide, so
/// one flag is correct for every screen. Default (no screen synced yet, or
/// English UI) = Latin digits, so pure-function callers and tests are
/// unchanged. No Bangla glyph lives in source (code points only).
bool _moneyBn = false;

/// Remember whether the UI is Bangla. Call at the top of a screen's build().
void syncMoneyDigits(BuildContext context) {
  _moneyBn = Localizations.maybeLocaleOf(context)?.languageCode == 'bn';
}

/// For tests: force the digit script.
@visibleForTesting
void setMoneyDigitsBn(bool bn) => _moneyBn = bn;

bool get moneyDigitsBn => _moneyBn;

/// Latin 0-9 → Bangla U+09E6..U+09EF while the UI is Bangla; else unchanged.
String moneyDigits(String s) => _moneyBn ? toBanglaDigits(s) : s;

/// Always-convert helper (pure).
String toBanglaDigits(String s) {
  final b = StringBuffer();
  for (final cu in s.codeUnits) {
    b.writeCharCode(cu >= 0x30 && cu <= 0x39 ? 0x09E6 + (cu - 0x30) : cu);
  }
  return b.toString();
}
