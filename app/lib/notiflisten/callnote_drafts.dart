import '../widgets/reminders_nlp.dart';

/// callmoney — AFTER CALL NOTE drafts.
///
/// The user's words (spoken or typed AFTER the call — the call itself is
/// NEVER recorded) become up to three drafts: a reminder, a note or a khata
/// due entry. The shared AI router does it on the server; when AI is not
/// available these on-device rules do it instead. Either way a draft is only
/// a suggestion: [CallNoteSaver] writes it ONLY when the user taps Confirm.
/// Bangla cue words are \u escapes (language gate).
enum CallNoteKind { reminder, note, due }

class CallNoteDraft {
  CallNoteKind kind;
  String title;
  DateTime? dueAt; // reminder time (local)
  bool dateOnly;
  num? amount; // due
  String? person; // due
  bool theyOwe; // due: true = they will pay me (loan given); false = I owe
  DateTime? dueDate; // due: when it should be paid
  CallNoteDraft({
    required this.kind,
    required this.title,
    this.dueAt,
    this.dateOnly = false,
    this.amount,
    this.person,
    this.theyOwe = true,
    this.dueDate,
  });

  /// May the Confirm button save this draft right now?
  bool get complete => switch (kind) {
        CallNoteKind.reminder => title.trim().isNotEmpty,
        CallNoteKind.note => title.trim().isNotEmpty,
        CallNoteKind.due =>
          amount != null && amount! > 0 && (person ?? '').trim().isNotEmpty,
      };
}

class CallNoteUnderstand {
  CallNoteUnderstand._();

  static final _bnZero = '\u09E6'.codeUnitAt(0);
  static String _digits(String s) {
    final b = StringBuffer();
    for (final c in s.codeUnits) {
      b.writeCharCode(c >= _bnZero && c <= _bnZero + 9 ? 0x30 + c - _bnZero : c);
    }
    return b.toString();
  }

  // someone will pay ME (loan given / customer due)
  static final _theyOwe = RegExp(
      r'will pay|will give|will send|owes? me|pay me back|\bdebe\b|\bdibe\b|\bdiben\b|\bdeben\b|\bpabo\b|\bpaona\b|\bbaki\b'
      r'|\u09A6\u09C7\u09AC\u09C7|\u09A6\u09BF\u09AC\u09C7|\u09A6\u09C7\u09AC\u09C7\u09A8|\u09A6\u09BF\u09AC\u09C7\u09A8|\u09AA\u09BE\u09AC\u09CB|\u09AA\u09BE\u09AC|\u09AA\u09BE\u0993\u09A8\u09BE|\u09AC\u09BE\u0995\u09BF|\u09AB\u09C7\u09B0\u09A4 \u09A6\u09C7\u09AC\u09C7',
      caseSensitive: false);
  // I must pay
  static final _iOwe = RegExp(
      r"\bi owe\b|i will pay|i'll pay|i have to pay|i need to pay|\bdebo\b|\bdibo\b|dite hobe|shodh korbo"
      r'|\u09A6\u09C7\u09AC\u09CB|\u09A6\u09BF\u09AC\u09CB|\u09A6\u09BF\u09A4\u09C7 \u09B9\u09AC\u09C7|\u09B6\u09CB\u09A7 \u0995\u09B0\u09AC|\u09A7\u09BE\u09B0 \u09A8\u09BF\u09B2\u09BE\u09AE',
      caseSensitive: false);
  static final _money = RegExp(
      r'(\d[\d,]*(?:\.\d+)?)\s*(?:tk\b|taka|bdt|\u099F\u09BE\u0995\u09BE|৳)|(?:tk\.?|bdt|৳)\s*(\d[\d,]*(?:\.\d+)?)',
      caseSensitive: false);

  /// On-device fallback (no AI): rules only, never invents a name or time.
  static List<CallNoteDraft> onDevice(String text, {DateTime? now}) {
    final raw = text.trim();
    if (raw.isEmpty) return [];
    final norm = _digits(raw);
    final out = <CallNoteDraft>[];
    final m = _money.firstMatch(norm);
    final amount = m == null ? null : num.tryParse((m.group(1) ?? m.group(2))!.replaceAll(',', ''));
    final iOwe = _iOwe.hasMatch(norm);
    final theyOwe = _theyOwe.hasMatch(norm);
    final r = parseReminder(raw, now: now);
    if (amount != null && amount > 0 && (iOwe || theyOwe)) {
      out.add(CallNoteDraft(
        kind: CallNoteKind.due,
        title: raw,
        amount: amount,
        theyOwe: !iOwe,
        dueDate: r.dateTime,
      ));
    }
    if (r.hasSchedule && r.dateTime != null && !r.isPast) {
      out.add(CallNoteDraft(
        kind: CallNoteKind.reminder,
        title: r.cleanTitle.trim().isEmpty ? raw : r.cleanTitle.trim(),
        dueAt: r.dateTime,
        dateOnly: r.dateOnly,
      ));
    }
    if (out.isEmpty) out.add(CallNoteDraft(kind: CallNoteKind.note, title: raw));
    return out;
  }

  /// Server (AI) items -> drafts. Unknown kinds are dropped.
  static List<CallNoteDraft> fromServer(List<dynamic> items, {required String fallbackTitle}) {
    final out = <CallNoteDraft>[];
    for (final e in items) {
      if (e is! Map) continue;
      final kind = switch (e['kind']) {
        'reminder' => CallNoteKind.reminder,
        'note' => CallNoteKind.note,
        'due' => CallNoteKind.due,
        _ => null,
      };
      if (kind == null) continue;
      final title = '${e['title'] ?? ''}'.trim();
      out.add(CallNoteDraft(
        kind: kind,
        title: title.isEmpty ? fallbackTitle : title,
        dueAt: DateTime.tryParse('${e['due_at'] ?? ''}'),
        dateOnly: e['date_only'] == true,
        amount: e['amount'] is num ? e['amount'] as num : num.tryParse('${e['amount'] ?? ''}'),
        person: e['person'] is String ? e['person'] as String : null,
        theyOwe: e['direction'] != 'i_owe',
        dueDate: DateTime.tryParse('${e['due_date'] ?? ''}'),
      ));
      if (out.length >= 3) break;
    }
    return out;
  }
}

/// Builds the repo payloads. Called ONLY from a Confirm tap.
class CallNoteSaver {
  CallNoteSaver._();

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Map<String, dynamic> reminderPayload(CallNoteDraft d) => {
        'title': d.title.trim(),
        'notes': '',
        'due_at': d.dueAt?.toUtc().toIso8601String(),
        'recurrence': 'none',
        'recurrence_rule': <String, dynamic>{},
        'date_only': d.dueAt == null ? true : d.dateOnly,
        'done': false,
        'source': 'callnote',
      };

  static Map<String, dynamic> notePayload(CallNoteDraft d) => {
        'color': '',
        'attachments': <Map<String, dynamic>>[],
        'title': '',
        'body': d.title.trim(),
        'checklist': <Map<String, dynamic>>[],
        'tags': <String>[],
        'priority': 'none',
        'pinned': false,
        'due_at': null,
        'source': 'callnote',
      };

  /// due -> a personal-khata loan row: "given" = they owe me, "taken" = I owe.
  static Map<String, dynamic> duePayload(CallNoteDraft d, DateTime today) => {
        'kind': d.theyOwe ? 'given' : 'taken',
        'person': (d.person ?? '').trim(),
        'amount': '${d.amount}',
        'date': _day(today),
        if (d.dueDate != null) 'due_date': _day(d.dueDate!),
        'settled': false,
        'paid': '0',
        'repayments': <Map<String, dynamic>>[],
        'note': d.title.trim().length > 200 ? d.title.trim().substring(0, 200) : d.title.trim(),
        'source': 'callnote',
      };
}
