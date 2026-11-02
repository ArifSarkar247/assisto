// pssec: Personal Secretary — pick up a task from a pasted message.
//
// ON-DEVICE ONLY. The pasted text (a WhatsApp / SMS / Messenger message the
// user copied) is parsed here and never sent to the server; only the task the
// user CONFIRMS is saved. Dates/times reuse the offline reminder parser
// (`parseReminder`, Bangla + English + Banglish). The same function is the seam
// a future opt-in NotificationListenerService would feed (see
// owner_actions/FEATURE_CARD_PERSONAL_SECRETARY_BN.md section 6).
//
// NOTE: no Bangla characters appear literally in this file (language gate) —
// every Bangla keyword is written with \u escapes.
import '../widgets/reminders_nlp.dart' show parseReminder;

enum PsKind { meeting, followup, reminder }

class PsPickup {
  final String title;
  final DateTime? when;
  final bool dateOnly; // a day was found but no clock time
  final PsKind kind;
  final String counterpart; // sender name from a WhatsApp copy, if any
  final bool isPast; // the message talks about a date already gone
  const PsPickup({
    required this.title,
    required this.kind,
    this.when,
    this.dateOnly = true,
    this.counterpart = '',
    this.isPast = false,
  });
}

// WhatsApp "copy message" prefix: "[02/11/26, 10:15 am] Karim Bhai: text"
// (also without brackets: "02/11/2026, 10:15 - Karim: text" from exports).
final RegExp _waPrefix = RegExp(
    r'^\s*\[?\s*\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4},?\s+\d{1,2}[:.]\d{2}(?:\s*[aApP]\.?[mM]\.?)?\s*[\]\-]\s*([^:\n]{1,40}):\s*');

const _meetingWords = [
  'meeting', 'meet ', 'appointment', 'interview', 'call at',
  'মিটিং', // miting
  'বৈঠক', // boithok
  'সাক্ষাৎ', // sakkhat
  'দেখা করব', // dekha korbo
  'অ্যাপয়েন্টমেন্ট', // appointment
  'সভা', // sobha
];

const _followWords = [
  'send', 'reply', 'let me know', 'quote', 'quotation', 'invoice', 'confirm',
  'follow up', 'follow-up', 'get back',
  'জানাব', // janabo / janaben
  'জানাও', // janao
  'পাঠাবেন', // pathaben
  'পাঠিয়ে', // pathiye
  'দেবেন', // deben
  'কোটেশন', // quotation
  'উত্তর', // uttor
  'ফলো', // follow
];

String _fold(String s) =>
    s.toLowerCase().replaceAll('য়', 'য়'); // ya + nukta

PsKind psKindOf(String text) {
  final f = _fold(text);
  if (_meetingWords.any(f.contains)) return PsKind.meeting;
  if (_followWords.any(f.contains)) return PsKind.followup;
  return PsKind.reminder;
}

/// Parse one pasted message. Returns null for blank input. Never throws.
PsPickup? psExtract(String raw, {DateTime? now}) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  var who = '';
  final m = _waPrefix.firstMatch(text);
  if (m != null) {
    who = (m.group(1) ?? '').trim();
    text = text.substring(m.end).trim();
  }
  // One task per pick-up: the first non-empty line carries it.
  final first = text
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => text);
  final kind = psKindOf(first);
  DateTime? when;
  var dateOnly = true;
  var isPast = false;
  var title = first;
  try {
    final p = parseReminder(first, now: now);
    when = p.dateTime;
    dateOnly = p.dateOnly;
    isPast = p.isPast;
    final ct = p.cleanTitle.trim();
    // Keep the user's own words when stripping dates left too little.
    if (ct.length >= 4) title = ct;
  } catch (_) {
    // The parser is total in tests; a surprise never blocks a manual pick-up.
  }
  if (title.length > 80) title = '${title.substring(0, 79)}…';
  return PsPickup(
      title: title,
      kind: kind,
      when: when,
      dateOnly: when == null ? true : dateOnly,
      counterpart: who,
      isPast: isPast);
}
