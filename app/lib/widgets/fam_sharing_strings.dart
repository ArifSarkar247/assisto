import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Localization helpers for the FAMILY ADVANCED bundle (SPEC v2.1 §21):
///   #67 Selective sharing · #73 Family card · #75 Probashi family.
///
/// All copy now lives in the ARB (AppLocalizations); the former bilingual
/// `_fStrings` table was merged into app_en.arb / app_bn.arb. [famLabel] maps a
/// static `fam*` key to its generated getter so the sections can still look a
/// string up by key (including dynamic keys such as the per-item consent
/// labels). Parameterized keys (famShareSharedCount, famCardMembers,
/// famProbashiHours — `{count}`; famProbashiDiff*, famProbashiRemit* — `{value}`)
/// are called via their generated placeholder methods directly, not here.
/// [famNum] gives locale-formatted digits (Bangla codepoints under bn).

bool _isBn(BuildContext c) =>
    Localizations.localeOf(c).languageCode == 'bn';

/// Western or Bangla digits (codepoints only — no Bangla glyph literal).
String famNum(BuildContext c, int n) {
  if (!_isBn(c)) return '$n';
  const zeroBn = 0x09E6;
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Resolve a static (non-parameterized) `fam*` bundle key to its ARB getter.
String famLabel(BuildContext c, String key) {
  final t = AppLocalizations.of(c);
  switch (key) {
    case 'famShareTabSelective':
      return t.famShareTabSelective;
    case 'famShareTabCard':
      return t.famShareTabCard;
    case 'famShareTabProbashi':
      return t.famShareTabProbashi;
    case 'famShareTitle':
      return t.famShareTitle;
    case 'famShareIntro':
      return t.famShareIntro;
    case 'famShareEmpty':
      return t.famShareEmpty;
    case 'famShareServerNote':
      return t.famShareServerNote;
    case 'famShareConsentTitle':
      return t.famShareConsentTitle;
    case 'famShareConsentBody':
      return t.famShareConsentBody;
    case 'famShareNothing':
      return t.famShareNothing;
    case 'famShareRevokeMember':
      return t.famShareRevokeMember;
    case 'famShareRevokeAll':
      return t.famShareRevokeAll;
    case 'famShareRevokeQ':
      return t.famShareRevokeQ;
    case 'famShareRevokeAllQ':
      return t.famShareRevokeAllQ;
    case 'famShareRevoked':
      return t.famShareRevoked;
    case 'famShareAuditTitle':
      return t.famShareAuditTitle;
    case 'famShareAuditEmpty':
      return t.famShareAuditEmpty;
    case 'famShareAuditGrant':
      return t.famShareAuditGrant;
    case 'famShareAuditRevoke':
      return t.famShareAuditRevoke;
    case 'famItemLocation':
      return t.famItemLocation;
    case 'famItemMedicine':
      return t.famItemMedicine;
    case 'famItemMoney':
      return t.famItemMoney;
    case 'famItemDocuments':
      return t.famItemDocuments;
    case 'famItemJourney':
      return t.famItemJourney;
    case 'famCardTitle':
      return t.famCardTitle;
    case 'famCardMyFamily':
      return t.famCardMyFamily;
    case 'famCardShareImage':
      return t.famCardShareImage;
    case 'famCardPrint':
      return t.famCardPrint;
    case 'famCardLight':
      return t.famCardLight;
    case 'famCardDark':
      return t.famCardDark;
    case 'famCardEmergency':
      return t.famCardEmergency;
    case 'famCardBlood':
      return t.famCardBlood;
    case 'famCardAddress':
      return t.famCardAddress;
    case 'famCardEmContact':
      return t.famCardEmContact;
    case 'famCardEmpty':
      return t.famCardEmpty;
    case 'famCardShareFailed':
      return t.famCardShareFailed;
    case 'famCardEditEmergency':
      return t.famCardEditEmergency;
    case 'famProbashiTitle':
      return t.famProbashiTitle;
    case 'famProbashiIntro':
      return t.famProbashiIntro;
    case 'famProbashiMyTime':
      return t.famProbashiMyTime;
    case 'famProbashiBdTime':
      return t.famProbashiBdTime;
    case 'famProbashiTzNote':
      return t.famProbashiTzNote;
    case 'famProbashiDiffSame':
      return t.famProbashiDiffSame;
    case 'famProbashiCallsTitle':
      return t.famProbashiCallsTitle;
    case 'famProbashiCallsBody':
      return t.famProbashiCallsBody;
    case 'famProbashiCallsEmpty':
      return t.famProbashiCallsEmpty;
    case 'famProbashiScheduleCall':
      return t.famProbashiScheduleCall;
    case 'famProbashiScheduleNote':
      return t.famProbashiScheduleNote;
    case 'famProbashiRemitTitle':
      return t.famProbashiRemitTitle;
    case 'famProbashiRemitBody':
      return t.famProbashiRemitBody;
    case 'famProbashiNeverWallet':
      return t.famProbashiNeverWallet;
    case 'famProbashiRemitAmount':
      return t.famProbashiRemitAmount;
    case 'famProbashiRemitCadenceM':
      return t.famProbashiRemitCadenceM;
    case 'famProbashiRemitCadenceW':
      return t.famProbashiRemitCadenceW;
    case 'famProbashiRemitMarkSent':
      return t.famProbashiRemitMarkSent;
    case 'famProbashiShareCard':
      return t.famProbashiShareCard;
    default:
      return key;
  }
}
