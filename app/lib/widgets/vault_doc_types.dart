import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Per-document-type schema for the Documents vault: localised label, icon,
/// the type-specific fields it captures, a default expiry rule, and the
/// matching govt-service guide key for renewal steps.
///
/// Type-specific fields are stored in a dedicated `details` JSON map on the
/// Document model (see MIGRATION NOTE in the report) and the user's free text
/// stays in `note`. The two are NEVER packed into one delimited string, so a
/// value containing ';', '|' or '=' can no longer corrupt the record.
class VaultDocType {
  final String key;
  final IconData icon;
  final List<VaultField> fields;

  /// Default validity in years from issue, when the type has a standard one
  /// (used to pre-fill the expiry picker). null = no standard rule.
  final int? defaultValidityYears;

  /// Govt-service guide key (see backend core/logic/guides.py GOVT_SERVICES)
  /// used to show renewal steps. null = no linked guide.
  final String? guideKey;

  const VaultDocType(this.key, this.icon, this.fields,
      {this.defaultValidityYears, this.guideKey});

  /// Localised how-to helper shown on the add/detail UI for types that need a
  /// short honest explanation (e.g. how to find the phone IMEI by hand). A
  /// METHOD (not a field) so [kVaultDocTypes] stays const. Returns null when the
  /// type has no guide text.
  String? helpText(AppLocalizations t) {
    switch (key) {
      case 'device':
        // Original IMEI how-to + the anti-theft evidence-pack guidance: also
        // record the serial number and photograph the box label, SIM-tray
        // label and any unique physical marks; plus the honest note on what
        // changing an IMEI does (and doesn't) defeat.
        return '${t.vaultDeviceImeiHelp}\n\n'
            '${t.vaultDeviceEvidenceHelp}\n\n'
            '${t.imeiHonestNote}';
      default:
        return null;
    }
  }

  String label(AppLocalizations t) {
    switch (key) {
      case 'passport':
        return t.docTypePassport;
      case 'nid':
        return 'NID';
      case 'licence':
        return t.docTypeLicence;
      case 'certificate':
        return t.docTypeCertificate;
      case 'insurance':
        return t.docTypeInsurance;
      case 'warranty':
        return t.docTypeWarranty;
      case 'device':
        return t.docTypeDevice;
      default:
        return t.docTypeOther;
    }
  }
}

/// A single type-specific field. `labelFor` returns the localised label.
class VaultField {
  final String key;
  final bool isDate;
  const VaultField(this.key, {this.isDate = false});

  String label(AppLocalizations t) {
    switch (key) {
      case 'number':
        return t.vaultFieldNumber;
      case 'issue_date':
        return t.vaultFieldIssueDate;
      case 'issuing_authority':
        return t.vaultFieldIssuingAuthority;
      case 'holder_name':
        return t.vaultFieldHolderName;
      case 'provider':
        return t.vaultFieldProvider;
      case 'policy_no':
        return t.vaultFieldPolicyNo;
      case 'coverage':
        return t.vaultFieldCoverage;
      case 'purchase_date':
        return t.vaultFieldPurchaseDate;
      case 'seller':
        return t.vaultFieldSeller;
      case 'imei1':
        return t.vaultFieldImei1;
      case 'imei2':
        return t.vaultFieldImei2;
      case 'model':
        return t.vaultFieldModel;
      case 'sim1':
        return t.vaultFieldSim1;
      case 'sim2':
        return t.vaultFieldSim2;
      case 'serial':
        return t.vaultFieldSerial;
      default:
        return key;
    }
  }
}

/// The maintained schema. Keep in sync with backend guide keys for renewal.
const List<VaultDocType> kVaultDocTypes = [
  VaultDocType('nid', Icons.badge_rounded, [
    VaultField('number'),
    VaultField('holder_name'),
  ], guideKey: 'nid'),
  VaultDocType('passport', Icons.menu_book_rounded, [
    VaultField('number'),
    VaultField('holder_name'),
    VaultField('issue_date', isDate: true),
  ], defaultValidityYears: 10, guideKey: 'passport'),
  VaultDocType('licence', Icons.directions_car_rounded, [
    VaultField('number'),
    VaultField('issue_date', isDate: true),
  ], defaultValidityYears: 10, guideKey: 'driving'),
  VaultDocType('certificate', Icons.school_rounded, [
    VaultField('issuing_authority'),
    VaultField('issue_date', isDate: true),
  ]),
  VaultDocType('insurance', Icons.verified_user_rounded, [
    VaultField('provider'),
    VaultField('policy_no'),
    VaultField('coverage'),
  ], defaultValidityYears: 1),
  VaultDocType('warranty', Icons.handyman_rounded, [
    VaultField('seller'),
    VaultField('purchase_date', isDate: true),
  ], defaultValidityYears: 1),
  // Anti-theft phone record. Fields are recorded BY HAND — Android 10+ blocks
  // apps from reading the IMEI (privacy), so the helpText explains how to find
  // it. Box/receipt photos attach via the existing file-attach flow.
  VaultDocType('device', Icons.smartphone_rounded, [
    VaultField('imei1'),
    VaultField('imei2'),
    VaultField('serial'),
    VaultField('model'),
    VaultField('sim1'),
    VaultField('sim2'),
    VaultField('purchase_date', isDate: true),
  ]),
  VaultDocType('other', Icons.description_rounded, []),
];

VaultDocType vaultTypeOf(String? key) =>
    kVaultDocTypes.firstWhere((d) => d.key == key,
        orElse: () => kVaultDocTypes.last);

/// Build the clean `details` map that is sent to the API as its own JSON
/// field (never merged into `note`). Blank values are dropped.
Map<String, String> cleanDetails(Map<String, String> details) {
  final out = <String, String>{};
  details.forEach((k, v) {
    if (v.trim().isNotEmpty) out[k] = v.trim();
  });
  return out;
}

/// Read a document's structured fields + free note out of the API item.
///
/// Source of truth is the separate `details` map (JSONField) and `note`
/// string. For documents created by an OLDER build (which packed
/// "k=v; k=v | freeNote" into `note` and had no `details`), we best-effort
/// decode that legacy form ONCE for backward compatibility — but only when it
/// unambiguously looks structured. If parsing is at all ambiguous we keep the
/// entire original string as the free note so no data is ever lost.
({Map<String, String> details, String note}) readDocDetails(
    Map<String, dynamic> item) {
  // Preferred: structured map stored separately.
  final rawDetails = item['details'];
  if (rawDetails is Map) {
    final details = <String, String>{};
    rawDetails.forEach((k, v) => details['$k'] = v == null ? '' : '$v');
    final note = (item['note'] ?? '').toString();
    return (details: details, note: note);
  }
  // Backward-compat: decode a legacy note, never losing data.
  return _decodeLegacyNote(item['note']);
}

/// Legacy "k=v; k=v | freeNote" decoder kept only for old records.
/// Conservative: a part is treated as structured ONLY if EVERY ';'-separated
/// chunk before the first '|' is a clean "key=value" with a simple key
/// (letters/digits/underscore) and no stray delimiters. Otherwise the whole
/// raw string is returned verbatim as the free note.
({Map<String, String> details, String note}) _decodeLegacyNote(dynamic raw) {
  final s = (raw ?? '').toString().trim();
  if (s.isEmpty) return (details: <String, String>{}, note: '');
  final pipe = s.indexOf('|');
  final kvPart = (pipe >= 0 ? s.substring(0, pipe) : s).trim();
  final free = pipe >= 0 ? s.substring(pipe + 1).trim() : '';
  if (!kvPart.contains('=')) {
    return (details: <String, String>{}, note: s);
  }
  final details = <String, String>{};
  final keyRe = RegExp(r'^[A-Za-z0-9_]+$');
  for (final chunk in kvPart.split(';')) {
    final c = chunk.trim();
    if (c.isEmpty) continue;
    final i = c.indexOf('=');
    final key = i > 0 ? c.substring(0, i).trim() : '';
    final val = i > 0 ? c.substring(i + 1).trim() : '';
    // Ambiguous (no '=', bad key, or a '=' inside the value) => bail out and
    // treat the ORIGINAL string as a plain note so nothing is lost.
    if (i <= 0 || !keyRe.hasMatch(key) || val.contains('=')) {
      return (details: <String, String>{}, note: s);
    }
    details[key] = val;
  }
  if (details.isEmpty) return (details: <String, String>{}, note: s);
  return (details: details, note: free);
}
