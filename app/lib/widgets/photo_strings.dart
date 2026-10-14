// Photo Enhance (ADVANCED, SPEC v2.1 §21) — Bangla-aware digit helpers.
//
// The photo copy now lives entirely in `app_*.arb` (folded via gen-l10n) and is
// read through `AppLocalizations`. The former bn/en string table + `pStr`
// lookup have been removed. This file keeps only the Bangla digit helpers
// (`pNum` / `pIsBn`) plus `phLabel`, a tiny resolver that maps a dynamic
// `ph*` key — used where the key is chosen at runtime (sliders, presets, AI
// ops) — to its generated `AppLocalizations` getter.
//
// HARD RULE: ZERO Bangla glyphs in any .dart file (pNum uses codepoints only).
import 'package:flutter/widgets.dart';
import '../l10n/app_localizations.dart';

/// Returns true when the active locale is Bangla.
bool pIsBn(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'bn';

/// Bangla-aware digit rendering (so numbers never show as ASCII in bn).
String pNum(BuildContext context, int n) {
  if (!pIsBn(context)) return '$n';
  const bn = [
    '\u09e6', '\u09e7', '\u09e8', '\u09e9', '\u09ea',
    '\u09eb', '\u09ec', '\u09ed', '\u09ee', '\u09ef'
  ];
  final buf = StringBuffer();
  for (final ch in n.toString().split('')) {
    final code = ch.codeUnitAt(0);
    if (code >= 0x30 && code <= 0x39) {
      buf.write(bn[code - 0x30]);
    } else {
      buf.write(ch);
    }
  }
  return buf.toString();
}

/// Resolves a dynamically-chosen `ph*` key to its `AppLocalizations` getter.
/// Used only where the key is picked at runtime (slider labels, preset
/// labels/descriptions, AI-op labels). Unknown keys fall back to the key
/// string (never throws / never blank).
String phLabel(BuildContext context, String key) {
  final t = AppLocalizations.of(context);
  switch (key) {
    // slider labels
    case 'phBrightness':
      return t.phBrightness;
    case 'phContrast':
      return t.phContrast;
    case 'phSaturation':
      return t.phSaturation;
    case 'phSharpness':
      return t.phSharpness;
    case 'phStraighten':
      return t.phStraighten;
    // preset labels / descriptions
    case 'phPresetDoc':
      return t.phPresetDoc;
    case 'phPresetDocDesc':
      return t.phPresetDocDesc;
    case 'phPresetPortrait':
      return t.phPresetPortrait;
    case 'phPresetPortraitDesc':
      return t.phPresetPortraitDesc;
    case 'phPresetPassport':
      return t.phPresetPassport;
    case 'phPresetPassportDesc':
      return t.phPresetPassportDesc;
    // AI-op labels
    case 'phAiUpscale':
      return t.phAiUpscale;
    case 'phAiDenoise':
      return t.phAiDenoise;
    case 'phAiBg':
      return t.phAiBg;
    default:
      return key;
  }
}
