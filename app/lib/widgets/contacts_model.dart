import 'package:flutter/material.dart';
import '../theme.dart';

/// Personal-CRM contact model + bilingual string helpers + pure list ops.
/// Mirrors backend/core/logic/personal_contacts.py so the app and server agree.
///
/// NO Bangla glyphs live in this file (SPEC §21): every localized string comes
/// from the ARB (AppLocalizations) where one exists, else from [cStr] which
/// carries [bn, en] pairs that are ALSO emitted to up_contacts_arb.json for the
/// next ARB sync. Bangla DIGITS use codepoints only (see [localeNum]).

bool isBn(BuildContext c) =>
    Localizations.localeOf(c).languageCode == 'bn';

/// Localized integer: Western digits, or Bangla digits via codepoints when bn.
/// Integer-safe — accepts any int, formats the magnitude, keeps the sign.
String localeNum(BuildContext c, int n) {
  if (!isBn(c)) return '$n';
  const zeroBn = 0x09E6; // Bengali digit zero codepoint
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Bilingual string table for keys NOT in the ARB yet. Keep every entry in sync
/// with up_contacts_arb.json. [bn, en]; picked by the active locale. This keeps
/// the screen fully bilingual TODAY without editing app_*.arb (per task rules).
const Map<String, List<String>> _strings = {
  // groups / labels
  'cGroupFamily': ['\u09AA\u09B0\u09BF\u09AC\u09BE\u09B0', 'Family'],
  'cGroupWork': ['\u0995\u09B0\u09CD\u09AE\u0995\u09CD\u09B7\u09C7\u09A4\u09CD\u09B0', 'Work'],
  'cGroupFriends': ['\u09AC\u09A8\u09CD\u09A7\u09C1', 'Friends'],
  'cGroupAcquaintance': ['\u09AA\u09B0\u09BF\u099A\u09BF\u09A4', 'Acquaintance'],
  'cGroupOther': ['\u0985\u09A8\u09CD\u09AF\u09BE\u09A8\u09CD\u09AF', 'Other'],
  // filters / sort
  'cAll': ['\u09B8\u09AC', 'All'],
  'cFavourites': ['\u09AA\u09CD\u09B0\u09BF\u09AF\u09BC', 'Favourites'],
  'cSortName': ['\u09A8\u09BE\u09AE (\u0985-\u0995\u09CD\u09B0\u09AE)', 'Name (A–Z)'],
  'cSortRecent': ['\u09B8\u09BE\u09AE\u09CD\u09AA\u09CD\u09B0\u09A4\u09BF\u0995 \u09AF\u09CB\u0997\u09BE\u09AF\u09CB\u0997', 'Recent contact'],
  'cSortFavourite': ['\u09AA\u09CD\u09B0\u09BF\u09AF\u09BC \u0986\u0997\u09C7', 'Favourites first'],
  'cSortBy': ['\u09B8\u09BE\u099C\u09BE\u09A8', 'Sort by'],
  'cFilter': ['\u09AB\u09BF\u09B2\u09CD\u099F\u09BE\u09B0', 'Filter'],
  // rich fields
  'cPhones': ['\u09AB\u09CB\u09A8', 'Phone numbers'],
  'cEmails': ['\u0987\u09AE\u09C7\u0987\u09B2', 'Emails'],
  'cAddresses': ['\u09A0\u09BF\u0995\u09BE\u09A8\u09BE', 'Addresses'],
  'cBirthday': ['\u099C\u09A8\u09CD\u09AE\u09A6\u09BF\u09A8', 'Birthday'],
  'cRelationship': ['\u09B8\u09AE\u09CD\u09AA\u09B0\u09CD\u0995', 'Relationship'],
  'cGroups': ['\u0997\u09CD\u09B0\u09C1\u09AA', 'Groups'],
  'cLabels': ['\u09B2\u09C7\u09AC\u09C7\u09B2', 'Labels'],
  'cAddPhone': ['\u09AB\u09CB\u09A8 \u09AF\u09CB\u0997 \u0995\u09B0\u09C1\u09A8', 'Add phone'],
  'cAddEmail': ['\u0987\u09AE\u09C7\u0987\u09B2 \u09AF\u09CB\u0997 \u0995\u09B0\u09C1\u09A8', 'Add email'],
  'cAddAddress': ['\u09A0\u09BF\u0995\u09BE\u09A8\u09BE \u09AF\u09CB\u0997 \u0995\u09B0\u09C1\u09A8', 'Add address'],
  'cLabelHint': ['\u09B2\u09C7\u09AC\u09C7\u09B2 (\u09AF\u09C7\u09AE\u09A8 \u099C\u09BF\u09AE, \u09AA\u09CD\u09B0\u09A4\u09BF\u09AC\u09C7\u09B6\u09C0)', 'Label (e.g. gym, neighbour)'],
  'cFavourite': ['\u09AA\u09CD\u09B0\u09BF\u09AF\u09BC', 'Favourite'],
  'cNotFavourite': ['\u09AA\u09CD\u09B0\u09BF\u09AF\u09BC\u09A4\u09C7 \u09AF\u09CB\u0997 \u0995\u09B0\u09C1\u09A8', 'Add to favourites'],
  // quick actions
  'cCall': ['\u0995\u09B2', 'Call'],
  'cSms': ['\u098F\u09B8\u098F\u09AE\u098F\u09B8', 'SMS'],
  'cWhatsapp': ['\u09B9\u09CB\u09AF\u09BC\u09BE\u099F\u09B8\u0985\u09CD\u09AF\u09BE\u09AA', 'WhatsApp'],
  'cEmailAction': ['\u0987\u09AE\u09C7\u0987\u09B2', 'Email'],
  'cShareVcard': ['\u0995\u09A8\u09CD\u099F\u09BE\u0995\u09CD\u099F \u09B6\u09C7\u09AF\u09BC\u09BE\u09B0 (vCard)', 'Share contact (vCard)'],
  // stay in touch
  'cStayInTouch': ['\u09AF\u09CB\u0997\u09BE\u09AF\u09CB\u0997 \u09B0\u09BE\u0996\u09C1\u09A8', 'Stay in touch'],
  'cCadence': ['\u0995\u09A4\u09A6\u09BF\u09A8 \u09AA\u09B0\u09AA\u09B0', 'How often'],
  'cCadenceNone': ['\u09AE\u09A8\u09C7 \u0995\u09B0\u09BF\u09AF\u09BC\u09C7 \u09A6\u09C7\u0993\u09AF\u09BC\u09BE \u09B9\u09AC\u09C7 \u09A8\u09BE', 'No reminder'],
  'cCadenceWeekly': ['\u09B8\u09BE\u09AA\u09CD\u09A4\u09BE\u09B9\u09BF\u0995', 'Weekly'],
  'cCadenceFortnightly': ['\u09AA\u09BE\u0995\u09CD\u09B7\u09BF\u0995', 'Fortnightly'],
  'cCadenceMonthly': ['\u09AE\u09BE\u09B8\u09BF\u0995', 'Monthly'],
  'cCadenceQuarterly': ['\u09A4\u09CD\u09B0\u09C8\u09AE\u09BE\u09B8\u09BF\u0995', 'Quarterly'],
  'cCadenceYearly': ['\u09AC\u09BE\u09B0\u09CD\u09B7\u09BF\u0995', 'Yearly'],
  'cDueToReach': ['\u09AF\u09CB\u0997\u09BE\u09AF\u09CB\u0997\u09C7\u09B0 \u09B8\u09AE\u09AF\u09BC \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Time to reach out'],
  'cLastTalkedDays': ['%d \u09A6\u09BF\u09A8 \u0986\u0997\u09C7 \u0995\u09A5\u09BE \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Talked %d days ago'],
  'cNeverTalked': ['\u098F\u0996\u09A8\u09CB \u09AF\u09CB\u0997\u09BE\u09AF\u09CB\u0997 \u09B9\u09AF\u09BC\u09A8\u09BF', 'No contact logged yet'],
  'cLogContact': ['\u09AF\u09CB\u0997\u09BE\u09AF\u09CB\u0997 \u09B2\u09BF\u09AA\u09BF\u09AC\u09A6\u09CD\u09A7 \u0995\u09B0\u09C1\u09A8', 'Log a contact'],
  'cLoggedContact': ['\u09AF\u09CB\u0997\u09BE\u09AF\u09CB\u0997 \u09B2\u09BF\u09AA\u09BF\u09AC\u09A6\u09CD\u09A7 \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Logged — nice!'],
  'cReachOutTitle': ['\u098F\u09A6\u09C7\u09B0 \u09B8\u09BE\u09A5\u09C7 \u09AF\u09CB\u0997\u09BE\u09AF\u09CB\u0997 \u09B0\u09BE\u0996\u09C1\u09A8', 'People to reach out to'],
  // merge / dedupe
  'cMergeDuplicates': ['\u09A1\u09C1\u09AA\u09CD\u09B2\u09BF\u0995\u09C7\u099F \u098F\u0995\u09A4\u09CD\u09B0 \u0995\u09B0\u09C1\u09A8', 'Merge duplicates'],
  'cDuplicatesFound': ['%d \u09B8\u09AE\u09CD\u09AD\u09BE\u09AC\u09CD\u09AF \u09A1\u09C1\u09AA\u09CD\u09B2\u09BF\u0995\u09C7\u099F', '%d possible duplicates'],
  'cNoDuplicates': ['\u0995\u09CB\u09A8\u09CB \u09A1\u09C1\u09AA\u09CD\u09B2\u09BF\u0995\u09C7\u099F \u09A8\u09C7\u0987', 'No duplicates found'],
  'cMerge': ['\u098F\u0995\u09A4\u09CD\u09B0 \u0995\u09B0\u09C1\u09A8', 'Merge'],
  'cMerged': ['\u098F\u0995\u09A4\u09CD\u09B0 \u0995\u09B0\u09BE \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Merged'],
  'cMergePreview': ['\u098F\u0995\u09A4\u09CD\u09B0 \u0995\u09B0\u09B2\u09C7 \u09B8\u09AC \u09AB\u09CB\u09A8/\u0987\u09AE\u09C7\u0987\u09B2 \u09B0\u09BE\u0996\u09BE \u09B9\u09AC\u09C7।',
      'Merging keeps every phone and email.'],
  // import / export
  'cImportFromPhone': ['\u09AB\u09CB\u09A8 \u09A5\u09C7\u0995\u09C7 \u0986\u09A8\u09C1\u09A8', 'Import from phone'],
  'cImportPrivacy': [
    '\u0986\u09AE\u09B0\u09BE \u09B6\u09C1\u09A7\u09C1 \u09AE\u09BF\u09B2 \u09AF\u09BE\u099A\u09BE\u0987 \u0995\u09B0\u09BF — \u09A8\u09AE\u09CD\u09AC\u09B0 \u09B8\u09BE\u09B0\u09CD\u09AD\u09BE\u09B0\u09C7 \u09B0\u09BE\u0996\u09BE \u09B9\u09AF\u09BC \u09A8\u09BE।',
    'We only match — numbers are never stored on our server.'
  ],
  'cExportAll': ['\u09B8\u09AC \u098F\u0995\u09CD\u09B8\u09AA\u09CB\u09B0\u09CD\u099F (vCard)', 'Export all (vCard)'],
  'cExported': ['\u098F\u0995\u09CD\u09B8\u09AA\u09CB\u09B0\u09CD\u099F \u09AA\u09CD\u09B0\u09B8\u09CD\u09A4\u09C1\u09A4', 'Export ready'],
  // link to circle
  'cLinkCircle': ['\u09B8\u09BE\u09B0\u09CD\u0995\u09C7\u09B2\u09C7 \u09AF\u09C1\u0995\u09CD\u09A4 \u0995\u09B0\u09C1\u09A8', 'Link to Circle'],
  'cLinkedCircle': ['\u09B8\u09BE\u09B0\u09CD\u0995\u09C7\u09B2\u09C7 \u09AF\u09C1\u0995\u09CD\u09A4', 'Linked in Circle'],
  // misc
  'cUnnamed': ['\u09A8\u09BE\u09AE\u09B9\u09C0\u09A8 \u09AA\u09B0\u09BF\u099A\u09BF\u09A4\u09BF', 'Unnamed contact'],
  'cContactSaved': ['\u0995\u09A8\u09CD\u099F\u09BE\u0995\u09CD\u099F \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4', 'Contact saved'],
  'cContactDeleted': ['\u0995\u09A8\u09CD\u099F\u09BE\u0995\u09CD\u099F \u09AE\u09C1\u099B\u09C7 \u09AB\u09C7\u09B2\u09BE \u09B9\u09AF\u09BC\u09C7\u099B\u09C7', 'Contact deleted'],
  'cDeleteContactQ': ['\u098F\u0987 \u0995\u09A8\u09CD\u099F\u09BE\u0995\u09CD\u099F \u09AE\u09C1\u099B\u09AC\u09C7\u09A8?', 'Delete this contact?'],
  'cEditContact': ['\u0995\u09A8\u09CD\u099F\u09BE\u0995\u09CD\u099F \u09B8\u09AE\u09CD\u09AA\u09BE\u09A6\u09A8\u09BE', 'Edit contact'],
  'cEmptyBody': [
    '\u0986\u09AA\u09A8\u09BE\u09B0 \u099C\u09C0\u09AC\u09A8\u09C7\u09B0 \u09AE\u09BE\u09A8\u09C1\u09B7\u09A6\u09C7\u09B0 \u098F\u0996\u09BE\u09A8\u09C7 \u09B0\u09BE\u0996\u09C1\u09A8 — \u09AA\u09B0\u09BF\u09AC\u09BE\u09B0, \u09AC\u09A8\u09CD\u09A7\u09C1, \u09B8\u09B9\u0995\u09B0\u09CD\u09AE\u09C0।',
    'Keep the people in your life here — family, friends, colleagues.'
  ],
  'cSearchHint': ['\u09A8\u09BE\u09AE, \u09AB\u09CB\u09A8, \u0987\u09AE\u09C7\u0987\u09B2 \u0996\u09C1\u0981\u099C\u09C1\u09A8', 'Search name, phone, email'],
  'cNoSearchResults': ['\u0995\u09BF\u099B\u09C1 \u09AA\u09BE\u0993\u09AF\u09BC\u09BE \u09AF\u09BE\u09AF\u09BC\u09A8\u09BF', 'Nothing matched'],
  'cOfflineShowingCached': [
    '\u0985\u09AB\u09B2\u09BE\u0987\u09A8 — \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4 \u09A4\u09BE\u09B2\u09BF\u0995\u09BE \u09A6\u09C7\u0996\u09BE\u09A8\u09CB \u09B9\u099A\u09CD\u099B\u09C7।',
    'Offline — showing your saved list.'
  ],
  'cSavedOffline': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8\u09C7 \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4, \u09AA\u09B0\u09C7 \u09B8\u09BF\u0999\u09CD\u0995 \u09B9\u09AC\u09C7।',
      'Saved offline — will sync later.'],
  'cQuickActions': ['\u09A6\u09CD\u09B0\u09C1\u09A4 \u0995\u09BE\u099C', 'Quick actions'],
  'cDetails': ['\u09AC\u09BF\u09B8\u09CD\u09A4\u09BE\u09B0\u09BF\u09A4', 'Details'],
};

/// Pick a bilingual string by key for the active locale. Falls back to the
/// English entry, then the key itself (never throws, never blank).
String cStr(BuildContext c, String key) {
  final pair = _strings[key];
  if (pair == null) return key;
  return isBn(c) ? pair[0] : pair[1];
}

/// Fill a single %d placeholder with a locale-formatted integer.
String cStrNum(BuildContext c, String key, int n) =>
    cStr(c, key).replaceFirst('%d', localeNum(c, n));

// ---------------------------------------------------------------------------
// Groups
// ---------------------------------------------------------------------------
const kGroupFamily = 'family';
const kGroupWork = 'work';
const kGroupFriends = 'friends';
const kGroupAcquaintance = 'acquaintance';
const kGroupOther = 'other';
const kGroupOrder = [
  kGroupFamily,
  kGroupWork,
  kGroupFriends,
  kGroupAcquaintance,
  kGroupOther
];

String groupLabel(BuildContext c, String code) {
  switch (code) {
    case kGroupFamily:
      return cStr(c, 'cGroupFamily');
    case kGroupWork:
      return cStr(c, 'cGroupWork');
    case kGroupFriends:
      return cStr(c, 'cGroupFriends');
    case kGroupAcquaintance:
      return cStr(c, 'cGroupAcquaintance');
    default:
      return cStr(c, 'cGroupOther');
  }
}

IconData groupIcon(String code) {
  switch (code) {
    case kGroupFamily:
      return Icons.family_restroom;
    case kGroupWork:
      return Icons.work_outline;
    case kGroupFriends:
      return Icons.groups_2_outlined;
    case kGroupAcquaintance:
      return Icons.person_outline;
    default:
      return Icons.label_outline;
  }
}

// ---------------------------------------------------------------------------
// Cadence (stay in touch)
// ---------------------------------------------------------------------------
const kCadenceOrder = [
  '',
  'weekly',
  'fortnightly',
  'monthly',
  'quarterly',
  'yearly'
];

String cadenceLabel(BuildContext c, String code) {
  switch (code) {
    case 'weekly':
      return cStr(c, 'cCadenceWeekly');
    case 'fortnightly':
      return cStr(c, 'cCadenceFortnightly');
    case 'monthly':
      return cStr(c, 'cCadenceMonthly');
    case 'quarterly':
      return cStr(c, 'cCadenceQuarterly');
    case 'yearly':
      return cStr(c, 'cCadenceYearly');
    default:
      return cStr(c, 'cCadenceNone');
  }
}

int cadenceDays(String code) {
  switch (code) {
    case 'weekly':
      return 7;
    case 'fortnightly':
      return 14;
    case 'monthly':
      return 30;
    case 'quarterly':
      return 90;
    case 'yearly':
      return 365;
    default:
      return 0;
  }
}

// ---------------------------------------------------------------------------
// Rich contact model (round-trips the server dict; tolerant of legacy rows)
// ---------------------------------------------------------------------------
class Contact {
  int? id;
  String name;
  List<String> phones;
  List<String> emails;
  List<String> addresses;
  String org;
  String note;
  String birthday; // '' | 'YYYY-MM-DD' | 'MM-DD'
  String relation; // circle relation code or ''
  List<String> groups;
  List<String> labels;
  bool favourite;
  String cadence; // '' | weekly | ... | yearly
  String lastInteraction; // ISO string or ''
  int? linkedUserId;
  int? linkedCircleId;

  Contact({
    this.id,
    this.name = '',
    List<String>? phones,
    List<String>? emails,
    List<String>? addresses,
    this.org = '',
    this.note = '',
    this.birthday = '',
    this.relation = '',
    List<String>? groups,
    List<String>? labels,
    this.favourite = false,
    this.cadence = '',
    this.lastInteraction = '',
    this.linkedUserId,
    this.linkedCircleId,
  })  : phones = phones ?? [],
        emails = emails ?? [],
        addresses = addresses ?? [],
        groups = groups ?? [],
        labels = labels ?? [];

  static List<String> _list(dynamic v, {dynamic legacy}) {
    final out = <String>[];
    void add(dynamic x) {
      final s = (x ?? '').toString().trim();
      if (s.isNotEmpty) out.add(s);
    }

    if (v is List) {
      for (final e in v) {
        add(e);
      }
    } else {
      add(v);
    }
    add(legacy);
    // de-dup, keep order, case-insensitive
    final seen = <String>{};
    return out.where((e) => seen.add(e.toLowerCase())).toList();
  }

  static int? _int(dynamic v) {
    if (v is int) return v;
    final s = (v ?? '').toString().trim();
    return int.tryParse(s);
  }

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
        id: _int(j['id']),
        name: (j['name'] ?? '').toString().trim(),
        phones: _list(j['phones'], legacy: j['phone']),
        emails: _list(j['emails'], legacy: j['email']),
        addresses: _list(j['addresses'], legacy: j['address']),
        org: (j['org'] ?? j['organization'] ?? '').toString().trim(),
        note: (j['note'] ?? j['notes'] ?? '').toString().trim(),
        birthday: (j['birthday'] ?? '').toString().trim(),
        relation: (j['relation'] ?? '').toString().trim(),
        groups: _list(j['groups']),
        labels: _list(j['labels']),
        favourite: (j['favourite'] ?? j['favorite'] ?? false) == true,
        cadence: (j['cadence'] ?? '').toString().trim(),
        lastInteraction: (j['last_interaction'] ?? '').toString().trim(),
        linkedUserId: _int(j['linked_user_id']),
        linkedCircleId: _int(j['linked_circle_id']),
      );

  /// Server payload. Legacy scalar mirrors kept so older rows/endpoints that
  /// only read 'phone'/'org'/'note' still show something.
  Map<String, dynamic> toJson() => {
        'name': name.trim(),
        'phones': phones,
        'phone': phones.isNotEmpty ? phones.first : '',
        'emails': emails,
        'email': emails.isNotEmpty ? emails.first : '',
        'addresses': addresses,
        'org': org.trim(),
        'note': note.trim(),
        'birthday': birthday.trim(),
        'relation': relation.trim(),
        'groups': groups,
        'labels': labels,
        'favourite': favourite,
        'cadence': cadence.trim(),
        'last_interaction': lastInteraction.trim(),
        if (linkedUserId != null) 'linked_user_id': linkedUserId,
        if (linkedCircleId != null) 'linked_circle_id': linkedCircleId,
      };

  String displayName(BuildContext c) {
    if (name.trim().isNotEmpty) return name.trim();
    if (phones.isNotEmpty) return phones.first;
    if (emails.isNotEmpty) return emails.first;
    return cStr(c, 'cUnnamed');
  }

  String initial(BuildContext c) {
    final s = displayName(c).trim();
    return s.isEmpty ? '?' : s.characters.first.toUpperCase();
  }

  String? bestPhone() => phones.isNotEmpty ? phones.first : null;
  String? bestEmail() => emails.isNotEmpty ? emails.first : null;

  /// Whole days since the last interaction, or null if never logged.
  int? daysSinceInteraction([DateTime? now]) {
    if (lastInteraction.trim().isEmpty) return null;
    final dt = DateTime.tryParse(lastInteraction.trim());
    if (dt == null) return null;
    final diff = (now ?? DateTime.now()).difference(dt).inDays;
    return diff < 0 ? 0 : diff;
  }

  /// Stay-in-touch reminder due? Opt-in: no cadence ⇒ never due.
  bool touchDue([DateTime? now]) {
    final d = cadenceDays(cadence);
    if (d <= 0) return false;
    final since = daysSinceInteraction(now);
    if (since == null) return true; // cadence set, never touched
    return since >= d;
  }

  /// vCard 3.0 for this contact (mirrors personal_contacts.to_vcard).
  String toVcard(BuildContext c) {
    String esc(String s) => s
        .replaceAll('\\', '\\\\')
        .replaceAll(';', '\\;')
        .replaceAll(',', '\\,')
        .replaceAll('\n', '\\n');
    final n = name.trim().isNotEmpty ? name.trim() : displayName(c);
    final lines = <String>['BEGIN:VCARD', 'VERSION:3.0'];
    lines.add('N:${esc(n)};;;;');
    lines.add('FN:${esc(n)}');
    if (org.trim().isNotEmpty) lines.add('ORG:${esc(org.trim())}');
    for (final p in phones) {
      lines.add('TEL;TYPE=CELL:${esc(p)}');
    }
    for (final e in emails) {
      lines.add('EMAIL;TYPE=INTERNET:${esc(e)}');
    }
    for (final a in addresses) {
      lines.add('ADR;TYPE=HOME:;;${esc(a)};;;;');
    }
    if (birthday.trim().isNotEmpty) {
      final b = birthday.trim();
      lines.add('BDAY:${b.length == 10 ? b : '--$b'}');
    }
    final cats = [...groups.map((g) => groupLabel(c, g)), ...labels];
    if (cats.isNotEmpty) {
      lines.add('CATEGORIES:${cats.map(esc).join(',')}');
    }
    if (note.trim().isNotEmpty) lines.add('NOTE:${esc(note.trim())}');
    lines.add('END:VCARD');
    return '${lines.join('\r\n')}\r\n';
  }
}

String vcardBundle(BuildContext c, List<Contact> list) =>
    list.map((x) => x.toVcard(c)).join();

// ---------------------------------------------------------------------------
// Pure list operations (mirror the backend so the UI is instant + offline)
// ---------------------------------------------------------------------------
String _digits(String s) =>
    s.split('').where((ch) => '0123456789'.contains(ch)).join();

List<Contact> searchContacts(List<Contact> list, String query, BuildContext c) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return List.of(list);
  final qd = _digits(q);
  return list.where((x) {
    final hay = [
      x.name,
      x.org,
      x.note,
      ...x.phones,
      ...x.emails,
      ...x.labels,
      if (x.relation.isNotEmpty) relationDisplay(c, x.relation),
    ].join(' ').toLowerCase();
    if (hay.contains(q)) return true;
    if (qd.isNotEmpty) {
      final blob = x.phones.map(_digits).join();
      if (blob.contains(qd)) return true;
    }
    return false;
  }).toList();
}

List<Contact> filterContacts(
  List<Contact> list, {
  String? group,
  bool favouritesOnly = false,
}) {
  return list.where((x) {
    if (group != null && group.isNotEmpty && !x.groups.contains(group)) {
      return false;
    }
    if (favouritesOnly && !x.favourite) return false;
    return true;
  }).toList();
}

List<Contact> sortContacts(List<Contact> list, String by, BuildContext c) {
  final items = List.of(list);
  int byName(Contact a, Contact b) =>
      a.displayName(c).toLowerCase().compareTo(b.displayName(c).toLowerCase());
  switch (by) {
    case 'recent':
      items.sort((a, b) {
        final da = a.daysSinceInteraction() ?? 1 << 30;
        final db = b.daysSinceInteraction() ?? 1 << 30;
        final cmp = da.compareTo(db);
        return cmp != 0 ? cmp : byName(a, b);
      });
      break;
    case 'favourite':
      items.sort((a, b) {
        final fa = a.favourite ? 0 : 1;
        final fb = b.favourite ? 0 : 1;
        final cmp = fa.compareTo(fb);
        return cmp != 0 ? cmp : byName(a, b);
      });
      break;
    default:
      items.sort(byName);
  }
  return items;
}

/// Duplicate groups by shared phone (last 9 digits) or shared email.
List<List<Contact>> findDuplicateGroups(List<Contact> list) {
  final n = list.length;
  final parent = List<int>.generate(n, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  void union(int a, int b) {
    final ra = find(a), rb = find(b);
    if (ra != rb) parent[ra < rb ? rb : ra] = ra < rb ? ra : rb;
  }

  final strong = <String, int>{};
  for (var i = 0; i < n; i++) {
    final keys = <String>{};
    for (final p in list[i].phones) {
      final d = _digits(p);
      if (d.length >= 7) keys.add('p:${d.substring(d.length - 9 > 0 ? d.length - 9 : 0)}');
    }
    for (final e in list[i].emails) {
      final s = e.trim().toLowerCase();
      if (s.isNotEmpty) keys.add('e:$s');
    }
    for (final k in keys) {
      if (strong.containsKey(k)) {
        union(strong[k]!, i);
      } else {
        strong[k] = i;
      }
    }
  }
  final groups = <int, List<Contact>>{};
  for (var i = 0; i < n; i++) {
    groups.putIfAbsent(find(i), () => []).add(list[i]);
  }
  final keys = groups.keys.toList()..sort();
  return [for (final k in keys) if (groups[k]!.length >= 2) groups[k]!];
}

/// Non-destructive merge (mirrors personal_contacts.merge_contacts).
Contact mergeContacts(List<Contact> group) {
  final primary = group.first;
  String firstNonEmpty(String Function(Contact) f) {
    for (final c in group) {
      final v = f(c);
      if (v.trim().isNotEmpty) return v;
    }
    return '';
  }

  List<String> union(List<String> Function(Contact) f, {bool lower = false}) {
    final out = <String>[];
    final seen = <String>{};
    for (final c in group) {
      for (final v in f(c)) {
        final key = v.toLowerCase();
        if (seen.add(key)) out.add(lower ? key : v);
      }
    }
    return out;
  }

  final notes = <String>[];
  final seenN = <String>{};
  for (final c in group) {
    final nt = c.note.trim();
    if (nt.isNotEmpty && seenN.add(nt)) notes.add(nt);
  }

  return Contact(
    id: primary.id,
    name: firstNonEmpty((c) => c.name),
    org: firstNonEmpty((c) => c.org),
    relation: firstNonEmpty((c) => c.relation),
    birthday: firstNonEmpty((c) => c.birthday),
    cadence: firstNonEmpty((c) => c.cadence),
    phones: union((c) => c.phones),
    emails: union((c) => c.emails, lower: true),
    addresses: union((c) => c.addresses),
    groups: union((c) => c.groups),
    labels: union((c) => c.labels),
    favourite: group.any((c) => c.favourite),
    note: notes.join('\n'),
    lastInteraction: group
        .map((c) => c.lastInteraction)
        .where((s) => s.trim().isNotEmpty)
        .fold<String>('', (a, b) => a.compareTo(b) >= 0 ? a : b),
    linkedUserId: group.map((c) => c.linkedUserId).firstWhere(
          (v) => v != null,
          orElse: () => null,
        ),
    linkedCircleId: group.map((c) => c.linkedCircleId).firstWhere(
          (v) => v != null,
          orElse: () => null,
        ),
  );
}

/// Contacts whose stay-in-touch reminder is due, most-overdue first.
List<Contact> touchDueContacts(List<Contact> list, [DateTime? now]) {
  final due = list.where((x) => x.touchDue(now)).toList();
  due.sort((a, b) {
    int over(Contact c) {
      final since = c.daysSinceInteraction(now);
      if (since == null) return 1 << 30;
      return since - cadenceDays(c.cadence);
    }

    return over(b).compareTo(over(a));
  });
  return due;
}

// ---------------------------------------------------------------------------
// Relationship vocabulary (mirrors circle.RELATIONS, EN labels; bn from table)
// ---------------------------------------------------------------------------
const relationOrder = [
  'father',
  'mother',
  'child',
  'husband',
  'wife',
  'brother',
  'sister',
  'relative',
  'friend',
  'colleague',
  'custom',
];

const Map<String, List<String>> _relationStrings = {
  'father': ['\u0986\u09AC\u09CD\u09AC\u09BE', 'Father'],
  'mother': ['\u0986\u09AE\u09CD\u09AE\u09BE', 'Mother'],
  'child': ['\u09B8\u09A8\u09CD\u09A4\u09BE\u09A8', 'Child'],
  'husband': ['\u09B8\u09CD\u09AC\u09BE\u09AE\u09C0', 'Husband'],
  'wife': ['\u09B8\u09CD\u09A4\u09CD\u09B0\u09C0', 'Wife'],
  'brother': ['\u09AD\u09BE\u0987', 'Brother'],
  'sister': ['\u09AC\u09CB\u09A8', 'Sister'],
  'relative': ['\u0986\u09A4\u09CD\u09AE\u09C0\u09AF\u09BC', 'Relative'],
  'friend': ['\u09AC\u09A8\u09CD\u09A7\u09C1', 'Friend'],
  'colleague': ['\u09B8\u09B9\u0995\u09B0\u09CD\u09AE\u09C0', 'Colleague'],
  'custom': ['\u0985\u09A8\u09CD\u09AF\u09BE\u09A8\u09CD\u09AF', 'Other'],
};

String relationDisplay(BuildContext c, String code) {
  final pair = _relationStrings[code];
  if (pair == null) return code;
  return isBn(c) ? pair[0] : pair[1];
}

// ---------------------------------------------------------------------------
// Small shared chrome
// ---------------------------------------------------------------------------
/// A rounded group/label chip used across the screen + sheets.
class ContactTag extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color? color;
  const ContactTag({super.key, required this.text, this.icon, this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: 4),
        ],
        Text(text,
            style: TextStyle(
                color: tint, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
