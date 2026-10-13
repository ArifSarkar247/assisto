import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Per-document-type schema for the Documents vault: localised label, icon,
/// the type-specific fields it captures, a default expiry rule, and the
/// matching govt-service guide key for renewal steps.
///
/// Type-specific fields are stored inside the document `note` as a compact
/// "key=value; key=value" string (the backend note field already exists), so
/// no model change is required to ship. The integrator MAY later promote these
/// to a JSONField (see MIGRATION NOTE in the report).
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
      default:
        return key;
    }
  }
}

/// The maintained schema. Keep in sync with backend guide keys for renewal.
const List<VaultDocType> kVaultDocTypes = [
  VaultDocType('nid', Icons.badge_outlined, [
    VaultField('number'),
    VaultField('holder_name'),
  ], guideKey: 'nid'),
  VaultDocType('passport', Icons.menu_book_outlined, [
    VaultField('number'),
    VaultField('holder_name'),
    VaultField('issue_date', isDate: true),
  ], defaultValidityYears: 10, guideKey: 'passport'),
  VaultDocType('licence', Icons.directions_car_outlined, [
    VaultField('number'),
    VaultField('issue_date', isDate: true),
  ], defaultValidityYears: 10, guideKey: 'driving'),
  VaultDocType('certificate', Icons.school_outlined, [
    VaultField('issuing_authority'),
    VaultField('issue_date', isDate: true),
  ]),
  VaultDocType('insurance', Icons.verified_user_outlined, [
    VaultField('provider'),
    VaultField('policy_no'),
    VaultField('coverage'),
  ], defaultValidityYears: 1),
  VaultDocType('warranty', Icons.handyman_outlined, [
    VaultField('seller'),
    VaultField('purchase_date', isDate: true),
  ], defaultValidityYears: 1),
  VaultDocType('other', Icons.description_outlined, []),
];

VaultDocType vaultTypeOf(String? key) =>
    kVaultDocTypes.firstWhere((d) => d.key == key,
        orElse: () => kVaultDocTypes.last);

/// Encode type-specific fields into the note string: "k=v; k=v | freeNote".
String encodeDetails(Map<String, String> details, String freeNote) {
  final kv = details.entries
      .where((e) => e.value.trim().isNotEmpty)
      .map((e) => '${e.key}=${e.value.trim()}')
      .join('; ');
  if (kv.isEmpty) return freeNote.trim();
  if (freeNote.trim().isEmpty) return kv;
  return '$kv | ${freeNote.trim()}';
}

/// Decode the note string back into (details, freeNote).
({Map<String, String> details, String note}) decodeDetails(String? raw) {
  final s = (raw ?? '').trim();
  if (s.isEmpty) return (details: <String, String>{}, note: '');
  final parts = s.split('|');
  final kvPart = parts.first.trim();
  final free = parts.length > 1 ? parts.sublist(1).join('|').trim() : '';
  final details = <String, String>{};
  // only treat as structured if it looks like k=v pairs
  if (kvPart.contains('=')) {
    for (final chunk in kvPart.split(';')) {
      final i = chunk.indexOf('=');
      if (i > 0) {
        details[chunk.substring(0, i).trim()] = chunk.substring(i + 1).trim();
      }
    }
    return (details: details, note: free);
  }
  return (details: <String, String>{}, note: s);
}
