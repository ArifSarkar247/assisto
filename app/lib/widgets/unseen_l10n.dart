import '../l10n/app_localizations.dart';
import 'unseen_data.dart';

/// lifebar: the curated destinations' prose in the app language. The data
/// file keeps romanized English (DATA); a Bangla UI used to show that English
/// ("Dhaka to Noakhali, then boat…") — now every visible field is translated
/// through ARB. Unknown ids fall back to the data (English UI only).
class UwText {
  final String name, best, how, near, tip;
  const UwText(this.name, this.best, this.how, this.near, this.tip);
}

UwText uwText(AppLocalizations t, Destination d, bool bn) {
  if (bn) {
    final x = _bn(t, d.id);
    if (x != null) return x;
  }
  return UwText(d.name, d.bestTime, d.howToGet, d.nearby.join(', '), d.tip);
}

UwText? _bn(AppLocalizations t, String id) {
  switch (id) {
    case 'nijhum-dwip':
      return UwText(t.lbUwNameNijhumDwip, t.lbUwBestNijhumDwip, t.lbUwHowNijhumDwip, t.lbUwNearNijhumDwip, t.lbUwTipNijhumDwip);
    case 'jaflong':
      return UwText(t.lbUwNameJaflong, t.lbUwBestJaflong, t.lbUwHowJaflong, t.lbUwNearJaflong, t.lbUwTipJaflong);
    case 'ratargul':
      return UwText(t.lbUwNameRatargul, t.lbUwBestRatargul, t.lbUwHowRatargul, t.lbUwNearRatargul, t.lbUwTipRatargul);
    case 'nafakhum':
      return UwText(t.lbUwNameNafakhum, t.lbUwBestNafakhum, t.lbUwHowNafakhum, t.lbUwNearNafakhum, t.lbUwTipNafakhum);
    case 'sajek':
      return UwText(t.lbUwNameSajek, t.lbUwBestSajek, t.lbUwHowSajek, t.lbUwNearSajek, t.lbUwTipSajek);
    case 'kuakata':
      return UwText(t.lbUwNameKuakata, t.lbUwBestKuakata, t.lbUwHowKuakata, t.lbUwNearKuakata, t.lbUwTipKuakata);
    case 'paharpur':
      return UwText(t.lbUwNamePaharpur, t.lbUwBestPaharpur, t.lbUwHowPaharpur, t.lbUwNearPaharpur, t.lbUwTipPaharpur);
    case 'mahasthangarh':
      return UwText(t.lbUwNameMahasthangarh, t.lbUwBestMahasthangarh, t.lbUwHowMahasthangarh, t.lbUwNearMahasthangarh, t.lbUwTipMahasthangarh);
    case 'srimangal':
      return UwText(t.lbUwNameSrimangal, t.lbUwBestSrimangal, t.lbUwHowSrimangal, t.lbUwNearSrimangal, t.lbUwTipSrimangal);
    case 'sundarbans':
      return UwText(t.lbUwNameSundarbans, t.lbUwBestSundarbans, t.lbUwHowSundarbans, t.lbUwNearSundarbans, t.lbUwTipSundarbans);
    case 'mainamati':
      return UwText(t.lbUwNameMainamati, t.lbUwBestMainamati, t.lbUwHowMainamati, t.lbUwNearMainamati, t.lbUwTipMainamati);
    case 'bisnakandi':
      return UwText(t.lbUwNameBisnakandi, t.lbUwBestBisnakandi, t.lbUwHowBisnakandi, t.lbUwNearBisnakandi, t.lbUwTipBisnakandi);
  }
  return null;
}

/// Every curated id has a Bangla text (checked by test/lifebar_daily_test).
const kUwTranslatedIds = ['nijhum-dwip', 'jaflong', 'ratargul', 'nafakhum', 'sajek', 'kuakata', 'paharpur', 'mahasthangarh', 'srimangal', 'sundarbans', 'mainamati', 'bisnakandi'];
