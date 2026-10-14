// FAMILY ACCOUNTING strings (#61, SPEC v2.1 §21).
//
// The bilingual `faStr`/`faStrS` temp-string table that once lived here has been
// folded into the real ARB (`app_en.arb` / `app_bn.arb`, the `fa*` keys) and is
// now consumed via `AppLocalizations.of(context).fa*`. Dynamic `%s` fills are
// done inline with `.replaceFirst('%s', value)` at the call sites. This file is
// intentionally left as a no-op placeholder; there is no digit helper to retain.
