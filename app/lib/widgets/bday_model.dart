import 'package:flutter/material.dart';

/// Birthdays & memorable-days ADVANCED model + bilingual string table + pure
/// client-side helpers (one-tap-send URIs, next-occurrence/age math) that mirror
/// backend/core/logic/birthdays.py so the app and server agree offline.
///
/// SPEC v2.1 §21: NO Bangla glyphs live in this file. Every localized string
/// either comes from the ARB (AppLocalizations) where one already exists, or
/// from [bStr] below whose Bangla side is written as \u codepoints only. Those
/// pairs are ALSO emitted to .phaseB/up_bday_arb.json for the next ARB sync
/// (per task rules we do NOT edit app_*.arb here). Bangla DIGITS use codepoints
/// via [bNum].

bool bIsBn(BuildContext c) =>
    Localizations.localeOf(c).languageCode == 'bn';

/// Localized integer: Western digits, or Bangla digits via codepoints when bn.
String bNum(BuildContext c, int n) {
  if (!bIsBn(c)) return '$n';
  const zeroBn = 0x09E6; // Bengali digit zero
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Bilingual string table for keys NOT in the ARB yet. Keep every entry in sync
/// with .phaseB/up_bday_arb.json. [bn, en]; picked by the active locale.
const Map<String, List<String>> _strings = {
  'bKindBirthday': ['\u099C\u09A8\u09CD\u09AE\u09A6\u09BF\u09A8', 'Birthday'],
  'bKindAnniversary': ['\u09AC\u09BF\u09AC\u09BE\u09B9\u09AC\u09BE\u09B0\u09CD\u09B7\u09BF\u0995\u09C0', 'Anniversary'],
  'bKindDeath': ['\u09AE\u09C3\u09A4\u09CD\u09AF\u09C1\u09AC\u09BE\u09B0\u09CD\u09B7\u09BF\u0995\u09C0', 'Remembrance day'],
  'bKindMemorable': ['\u09B8\u09CD\u09AE\u09B0\u09A3\u09C0\u09AF\u09BC \u09A6\u09BF\u09A8', 'Memorable day'],
  'bThisWeek': ['\u098F\u0987 \u09B8\u09AA\u09CD\u09A4\u09BE\u09B9\u09C7', 'This week'],
  'bUpcoming': ['\u0986\u09B8\u099B\u09C7', 'Upcoming'],
  'bAllOccasions': ['\u09B8\u09AC \u09A6\u09BF\u09A8', 'All days'],
  'bThisWeekHighlight': ['\u098F\u0987 \u09B8\u09AA\u09CD\u09A4\u09BE\u09B9\u09C7\u09B0 \u09AC\u09BF\u09B6\u09C7\u09B7 \u09A6\u09BF\u09A8', 'This week\'s special days'],
  'bEdit': ['\u09B8\u09AE\u09CD\u09AA\u09BE\u09A6\u09A8\u09BE', 'Edit'],
  'bRelationLabel': ['\u09B8\u09AE\u09CD\u09AA\u09B0\u09CD\u0995 (\u0990\u099A\u09CD\u099B\u09BF\u0995)', 'Relation (optional)'],
  'bNotesLabel': ['\u09A8\u09CB\u099F (\u0990\u099A\u09CD\u099B\u09BF\u0995)', 'Notes (optional)'],
  'bYearly': ['\u09AA\u09CD\u09B0\u09A4\u09BF \u09AC\u099B\u09B0 \u09AB\u09BF\u09B0\u09C7 \u0986\u09B8\u09C7', 'Repeats every year'],
  'bPreReminders': ['\u0986\u0997\u09BE\u09AE \u09AE\u09A8\u09C7 \u0995\u09B0\u09BF\u09AF\u09BC\u09C7 \u09A6\u09BE\u0993', 'Pre-reminders'],
  'bRemind1Week': ['\u09E7 \u09B8\u09AA\u09CD\u09A4\u09BE\u09B9 \u0986\u0997\u09C7', '1 week before'],
  'bRemind3Days': ['\u09E9 \u09A6\u09BF\u09A8 \u0986\u0997\u09C7', '3 days before'],
  'bRemind1Day': ['\u09E7 \u09A6\u09BF\u09A8 \u0986\u0997\u09C7', '1 day before'],
  'bRemindOnDay': ['\u0990 \u09A6\u09BF\u09A8\u09C7', 'On the day'],
  'bPhoneLabel': ['\u09AB\u09CB\u09A8 (\u098F\u0995-\u099F\u09CD\u09AF\u09BE\u09AA \u09B6\u09C1\u09AD\u09C7\u099A\u09CD\u099B\u09BE\u09B0 \u099C\u09A8\u09CD\u09AF)', 'Phone (for one-tap wish)'],
  'bRelMom': ['\u09AE\u09BE', 'Mom'],
  'bRelDad': ['\u09AC\u09BE\u09AC\u09BE', 'Dad'],
  'bRelSpouse': ['\u09B8\u0999\u09CD\u0997\u09C0', 'Spouse'],
  'bRelChild': ['\u09B8\u09A8\u09CD\u09A4\u09BE\u09A8', 'Child'],
  'bRelSibling': ['\u09AD\u09BE\u0987/\u09AC\u09CB\u09A8', 'Sibling'],
  'bRelFriend': ['\u09AC\u09A8\u09CD\u09A7\u09C1', 'Friend'],
  'bRelColleague': ['\u09B8\u09B9\u0995\u09B0\u09CD\u09AE\u09C0', 'Colleague'],
  'bImportContacts': ['\u0995\u09A8\u09CD\u099F\u09BE\u0995\u09CD\u099F \u09A5\u09C7\u0995\u09C7 \u0986\u09A8\u09C1\u09A8', 'Import from contacts'],
  'bImportTitle': ['\u0995\u09A8\u09CD\u099F\u09BE\u0995\u09CD\u099F \u09A5\u09C7\u0995\u09C7 \u099C\u09A8\u09CD\u09AE\u09A6\u09BF\u09A8', 'Birthdays from contacts'],
  'bImportSubtitle': ['\u099C\u09A8\u09CD\u09AE\u09A6\u09BF\u09A8 \u0986\u099B\u09C7 \u098F\u09AE\u09A8 \u0995\u09A8\u09CD\u099F\u09BE\u0995\u09CD\u099F \u09AC\u09C7\u099B\u09C7 \u09AF\u09CB\u0997 \u0995\u09B0\u09C1\u09A8\u2014\u09AB\u09CB\u09A8 \u09A5\u09C7\u0995\u09C7\u0987, \u09A8\u09BF\u09B0\u09BE\u09AA\u09A6\u09C7\u0964', 'Pick contacts that have a birthday \u2014 on-device, privately.'],
  'bImportNone': ['\u099C\u09A8\u09CD\u09AE\u09A6\u09BF\u09A8 \u09B8\u09B9 \u0995\u09CB\u09A8\u09CB \u0995\u09A8\u09CD\u099F\u09BE\u0995\u09CD\u099F \u09AA\u09BE\u0993\u09AF\u09BC\u09BE \u09AF\u09BE\u09AF\u09BC\u09A8\u09BF\u0964', 'No contacts with a birthday found.'],
  'bImportAdd': ['\u09AF\u09CB\u0997 \u0995\u09B0\u09C1\u09A8', 'Add'],
  'bLinkCircle': ['\u09B8\u09BE\u09B0\u09CD\u0995\u09C7\u09B2\u09C7 \u09AF\u09C1\u0995\u09CD\u09A4 \u0995\u09B0\u09C1\u09A8', 'Link to Circle'],
  'bLinked': ['\u09B8\u09BE\u09B0\u09CD\u0995\u09C7\u09B2\u09C7 \u09AF\u09C1\u0995\u09CD\u09A4', 'Linked in Circle'],
  'bWishTitle': ['\u09B6\u09C1\u09AD\u09C7\u099A\u09CD\u099B\u09BE \u09AA\u09BE\u09A0\u09BE\u09A8', 'Send a wish'],
  'bWishSubtitle': ['\u0996\u09B8\u09A1\u09BC\u09BE \u09AC\u09C7\u099B\u09C7 \u09AA\u09BE\u09A0\u09BE\u09A8\u2014\u09B8\u09CD\u09AC\u09AF\u09BC\u0982\u0995\u09CD\u09B0\u09BF\u09AF\u09BC\u09AD\u09BE\u09AC\u09C7 \u09AA\u09BE\u09A0\u09BE\u09A8\u09CB \u09B9\u09AC\u09C7 \u09A8\u09BE\u0964', 'Pick a draft and send \u2014 nothing is sent automatically.'],
  'bAiWish': ['AI \u09B6\u09C1\u09AD\u09C7\u099A\u09CD\u099B\u09BE', 'AI wish'],
  'bAiPreview': ['AI \u09AA\u09CD\u09B0\u09BF\u09AD\u09BF\u0989 (\u0995\u09C0 \u099B\u09BE\u09A1\u09BC\u09BE \u09AE\u0995)', 'AI preview (mock, no key)'],
  'bAiGenerate': ['AI \u09A6\u09BF\u09AF\u09BC\u09C7 \u09B2\u09BF\u0996\u09C1\u09A8', 'Write with AI'],
  'bCardTitle': ['\u09B6\u09C1\u09AD\u09C7\u099A\u09CD\u099B\u09BE \u0995\u09BE\u09B0\u09CD\u09A1', 'Greeting card'],
  'bStyleShort': ['\u099B\u09CB\u099F', 'Short'],
  'bStyleWarm': ['\u0986\u09A8\u09CD\u09A4\u09B0\u09BF\u0995', 'Warm'],
  'bStyleFormal': ['\u0986\u09A8\u09C1\u09B7\u09CD\u09A0\u09BE\u09A8\u09BF\u0995', 'Formal'],
  'bSendWhatsApp': ['\u09B9\u09CB\u09AF\u09BC\u09BE\u099F\u09B8\u0985\u09CD\u09AF\u09BE\u09AA', 'WhatsApp'],
  'bSendSms': ['\u098F\u09B8\u098F\u09AE\u098F\u09B8', 'SMS'],
  'bSendCall': ['\u0995\u09B2', 'Call'],
  'bOffline': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8\u2014\u09B8\u09B0\u09CD\u09AC\u09B6\u09C7\u09B7 \u09B8\u0982\u09B0\u0995\u09CD\u09B7\u09BF\u09A4 \u09A6\u09BF\u09A8\u0997\u09C1\u09B2\u09CB \u09A6\u09C7\u0996\u09BE\u09A8\u09CB \u09B9\u099A\u09CD\u099B\u09C7\u0964', 'Offline \u2014 showing your saved days.'],
  'bOfflineAddBlocked': ['\u0985\u09AB\u09B2\u09BE\u0987\u09A8\u09C7 \u09A8\u09A4\u09C1\u09A8 \u09A6\u09BF\u09A8 \u09AF\u09CB\u0997 \u0995\u09B0\u09BE \u09AF\u09BE\u09AC\u09C7 \u09A8\u09BE\u0964', 'Can\'t add a new day while offline.'],
  'bSendOpenError': ['\u0985\u09CD\u09AF\u09BE\u09AA\u099F\u09BF \u0996\u09CB\u09B2\u09BE \u0997\u09C7\u09B2 \u09A8\u09BE\u0964', 'Couldn\'t open the app.'],
  'bAgeLabel': ['{age} \u09AC\u099B\u09B0 \u09B9\u099A\u09CD\u099B\u09C7', 'turning {age}'],
  'bYearsLabel': ['{years} \u09AC\u099B\u09B0 \u09AA\u09C2\u09B0\u09CD\u09A3 \u09B9\u099A\u09CD\u099B\u09C7', '{years} years'],
};

/// Pick a bilingual string by key for the active locale. Falls back to the key
/// if it is ever missing (never crashes, never shows a raw blank).
String bStr(BuildContext c, String key) {
  final pair = _strings[key];
  if (pair == null) return key;
  return bIsBn(c) ? pair[0] : pair[1];
}

/// Pre-reminder lead-day option used by the Add/Edit sheet. Maps a friendly
/// chip (1 week / 3 days / 1 day / on-the-day) to the lead-day int the backend
/// birthdays.reminder_dates() understands.
class BPreReminder {
  final int leadDays;
  final String stringKey;
  const BPreReminder(this.leadDays, this.stringKey);
}

const List<BPreReminder> kPreReminderOptions = [
  BPreReminder(7, 'bRemind1Week'),
  BPreReminder(3, 'bRemind3Days'),
  BPreReminder(1, 'bRemind1Day'),
  BPreReminder(0, 'bRemindOnDay'),
];

/// Quick-pick relation chips for the Add/Edit sheet (free text is still
/// allowed). Returns [stringKey, englishValue] — we send the English value to
/// the backend as a stable `relation` while showing the localized label.
const List<List<String>> kRelationChips = [
  ['bRelMom', 'Mom'],
  ['bRelDad', 'Dad'],
  ['bRelSpouse', 'Spouse'],
  ['bRelChild', 'Child'],
  ['bRelSibling', 'Sibling'],
  ['bRelFriend', 'Friend'],
  ['bRelColleague', 'Colleague'],
];

const List<String> kWishStyles = ['short', 'warm', 'formal'];

String bStyleKey(String style) {
  switch (style) {
    case 'short':
      return 'bStyleShort';
    case 'formal':
      return 'bStyleFormal';
    default:
      return 'bStyleWarm';
  }
}

/// Icon per kind — mirrors HealthBirthdayCard so the look is consistent.
IconData bKindIcon(String kind) {
  switch (kind) {
    case 'anniversary':
      return Icons.favorite_outline_rounded;
    case 'death_anniversary':
      return Icons.local_florist_rounded;
    case 'memorable':
      return Icons.star_outline_rounded;
    default:
      return Icons.cake_rounded;
  }
}

// ---- one-tap send URI builders (mirror birthdays.send_actions) ----
// Each opens the native app with text prefilled; the USER presses send. Never
// a gateway, never auto-sent.

String _enc(String s) => Uri.encodeComponent(s);

String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

/// WhatsApp deep link for a wish text. With a phone it targets that chat; with
/// no phone it opens the WhatsApp share sheet. User presses send.
Uri bWhatsAppUri(String text, {String? phone}) {
  final d = _digits(phone ?? '');
  if (d.isNotEmpty) {
    return Uri.parse('https://wa.me/$d?text=${_enc(text)}');
  }
  return Uri.parse('https://wa.me/?text=${_enc(text)}');
}

Uri bSmsUri(String text, String phone) =>
    Uri.parse('sms:${phone.trim()}?body=${_enc(text)}');

Uri bCallUri(String phone) => Uri.parse('tel:${phone.trim()}');

// ---- client-side next-occurrence / age (offline fallback; mirrors backend) --

/// Parse an ISO yyyy-MM-dd into a DateTime (date only) or null.
DateTime? bParseDate(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final parts = iso.split('-');
  if (parts.length < 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

/// Days until the next annual occurrence (0 == today). Used only as an offline
/// fallback when the server didn't attach `days_until` to a cached row.
int? bDaysUntil(String? iso, {DateTime? today}) {
  final d = bParseDate(iso);
  if (d == null) return null;
  final now = today ?? DateTime.now();
  final t = DateTime(now.year, now.month, now.day);
  var day = d.day;
  // Feb 29 -> Feb 28 on non-leap years (match backend convention).
  DateTime occ(int year) {
    try {
      return DateTime(year, d.month, day);
    } catch (_) {
      return DateTime(year, 2, 28);
    }
  }

  var cand = occ(t.year);
  if (cand.isBefore(t)) cand = occ(t.year + 1);
  return cand.difference(t).inDays;
}
