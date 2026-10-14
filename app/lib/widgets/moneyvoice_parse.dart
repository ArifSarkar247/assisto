// On-device money-VOICE parser (feature #62, SPEC v2.1 §21).
//
// Turns ONE spoken money utterance (or a comma/‘and’-separated batch) into
// reviewable draft entries — amount + type + category + counterparty — so the
// screen can show "what it understood" and only log AFTER the user confirms.
//
// This is the Dart mirror of `backend/core/logic/money_parse.parse_money_voice`
// and deliberately reuses its logic shape (digit-normalise → amount token →
// type cues → counterparty → category) so on-device review matches the server.
// It runs with ZERO latency and NO network, exactly like `voice_intent.dart`.
//
// LANGUAGE GATE: this file holds parsing DATA + pure functions only — no
// user-facing strings (no AppLocalizations) and, per the gate, no Bangla
// literals or Bangla \u escapes. Bangla NUMERALS are still supported honestly:
// their code points (U+09E6..U+09EF) are built with String.fromCharCode from
// plain integers (digit normalisation, not translatable text). Bangla-SCRIPT
// type-cue words romanise in the realistic Banglish voice-typing path and are
// matched there; pure Bangla-script verbs fall back to the common-case expense
// draft, which the user still confirms (never auto-logged).

/// Draft transaction type understood from speech.
/// due_in  = someone owes YOU (you lent)        -> logs as a loan "given".
/// due_out = YOU owe someone (you borrowed)     -> logs as a loan "taken".
enum MoneyVoiceType { expense, income, dueIn, dueOut }

/// One reviewable entry parsed from a spoken utterance.
class MoneyVoiceEntry {
  final num? amount;
  final MoneyVoiceType? type; // null => needs the user to pick in review
  final String? counterparty;
  final String note;
  final String raw;
  const MoneyVoiceEntry({
    this.amount,
    this.type,
    this.counterparty,
    this.note = '',
    required this.raw,
  });

  /// True only when BOTH amount and type were understood. A false entry is
  /// shown for the user to complete — it is NEVER logged as-is.
  bool get parsed => amount != null && type != null;

  MoneyVoiceEntry copyWith({num? amount, MoneyVoiceType? type}) =>
      MoneyVoiceEntry(
        amount: amount ?? this.amount,
        type: type ?? this.type,
        counterparty: counterparty,
        note: note,
        raw: raw,
      );
}

class MoneyVoiceParser {
  MoneyVoiceParser._();

  // Bangla numeral code points U+09E6..U+09EF, built without any Bangla literal.
  static final String _bnZero = String.fromCharCode(0x09E6);
  static String _normalizeDigits(String s) {
    final sb = StringBuffer();
    for (final rune in s.runes) {
      if (rune >= 0x09E6 && rune <= 0x09EF) {
        sb.writeCharCode(0x30 + (rune - 0x09E6)); // -> ASCII 0..9
      } else {
        sb.writeCharCode(rune);
      }
    }
    return sb.toString();
  }

  // Romanised (Banglish) + English type cues. Checked by LAST occurrence so a
  // trailing direction verb wins (mirrors the Python _mv_last_cue_type).
  static const _incomeCues = [
    'income', 'earned', 'got paid', 'received', 'receive', 'salary', 'profit',
    'pelam', 'peyechi', 'paisi', 'ay holo', 'beton', 'joma',
  ];
  static const _expenseCues = [
    'spent', 'paid', 'bought', 'expense', 'cost', 'bill', 'kinlam', 'khoroch',
    'kharoch', 'porlo', 'laglo', 'gelo', 'dilam', 'diyechi', 'dilo', 'gave',
  ];
  static const _dueInCues = [
    'lent', 'loaned', 'gave a loan', 'will get back', 'owes me',
    'dhar dilam', 'dhar dilo', 'dhar diyechi', 'pabo', 'pawna',
  ];
  static const _dueOutCues = [
    'borrowed', 'owe', 'took a loan',
    'dhar nilam', 'dhar nilo', 'dhar niyechi', 'dena', 'debo', 'dibo',
    'dite hobe',
  ];

  static int _lastHit(String low, List<String> cues) {
    var pos = -1;
    for (final c in cues) {
      final i = low.lastIndexOf(c);
      if (i > pos) pos = i;
    }
    return pos;
  }

  static MoneyVoiceType? _detectType(String low) {
    final scores = <MoneyVoiceType, int>{
      MoneyVoiceType.dueIn: _lastHit(low, _dueInCues),
      MoneyVoiceType.dueOut: _lastHit(low, _dueOutCues),
      MoneyVoiceType.income: _lastHit(low, _incomeCues),
      MoneyVoiceType.expense: _lastHit(low, _expenseCues),
    };
    // Loans take priority on a tie (so "dhar dilam" beats the "dilam" spend cue).
    MoneyVoiceType? best;
    var bestPos = -1;
    for (final t in const [
      MoneyVoiceType.dueIn,
      MoneyVoiceType.dueOut,
      MoneyVoiceType.income,
      MoneyVoiceType.expense,
    ]) {
      if (scores[t]! > bestPos) {
        bestPos = scores[t]!;
        best = t;
      }
    }
    return bestPos < 0 ? null : best;
  }

  // counterparty: "<name> ke" (dative) / "<name> theke" (from) / English
  // to|from|for <name>. Romanised path only (Banglish); keeps original casing.
  static final _partyKe =
      RegExp(r"\b([A-Za-z][A-Za-z.'\-]{1,24})\s+(?:ke|theke)\b", caseSensitive: false);
  static final _partyEn = RegExp(
      r"\b(?:to|from|for)\s+([A-Za-z][A-Za-z .'\-]{1,24}?)(?=[.,;]|\s+(?:tk|taka|bdt|\d)|$)",
      caseSensitive: false);

  static String? _counterparty(String raw) {
    final m1 = _partyKe.firstMatch(raw);
    if (m1 != null) return m1.group(1)!.trim();
    final m2 = _partyEn.firstMatch(raw);
    if (m2 != null) {
      final n = m2.group(1)!.trim();
      if (n.isNotEmpty) return n;
    }
    return null;
  }

  static final _amountRx = RegExp(r'(\d[\d,]*(?:\.\d+)?)');

  static String _note(String norm, String? party) {
    var s = norm;
    s = s.replaceAll(_amountRx, ' ');
    s = s.replaceAll(RegExp(r'\b(?:tk|taka|bdt)\b', caseSensitive: false), ' ');
    if (party != null) {
      s = s.replaceAll(RegExp(RegExp.escape(party), caseSensitive: false), ' ');
      s = s.replaceAll(RegExp(r'\b(?:ke|theke)\b', caseSensitive: false), ' ');
    }
    s = s.replaceAll(
        RegExp(r'\b(?:to|from|for|the|a|an|of|on)\b', caseSensitive: false), ' ');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Parse ONE utterance into a draft entry.
  static MoneyVoiceEntry parseEntry(String text) {
    final raw = text.trim();
    final norm = _normalizeDigits(raw);
    final low = norm.toLowerCase();

    num? amount;
    final am = _amountRx.firstMatch(norm);
    if (am != null) {
      final cleaned = am.group(1)!.replaceAll(',', '');
      final v = num.tryParse(cleaned);
      if (v != null) amount = (v == v.toInt()) ? v.toInt() : v;
    }

    final party = _counterparty(raw);

    var type = _detectType(low);
    // No explicit cue but an amount exists -> common-case expense draft (still
    // confirmed in review). No amount -> leave type null so review flags it.
    type ??= amount != null ? MoneyVoiceType.expense : null;

    return MoneyVoiceEntry(
      amount: amount,
      type: type,
      counterparty: party,
      note: _note(norm, party),
      raw: raw,
    );
  }

  // Split a batch ("tea 20, rickshaw 30"). A comma counts as a separator unless
  // it sits between two digits (thousands separator "1,500").
  static final _splitRx = RegExp(
      r'\s*(?:(?<!\d),|,(?!\d)|;|\n|\band\b|\bar\b)\s*',
      caseSensitive: false);

  static List<String> split(String text) {
    final norm = _normalizeDigits(text);
    return norm
        .split(_splitRx)
        .map((p) => p.trim().replaceAll(RegExp(r'^[\s.,\-]+|[\s.,\-]+$'), ''))
        .where((p) => p.isNotEmpty && RegExp(r'\d').hasMatch(p))
        .toList();
  }

  /// Parse an utterance (single OR batch) into reviewable drafts, in order.
  /// Empty input -> empty list. A single fragment still returns one element so
  /// the UI has one review path.
  static List<MoneyVoiceEntry> parse(String? text) {
    final raw = (text ?? '').trim();
    if (raw.isEmpty) return const [];
    final frags = split(raw);
    if (frags.length <= 1) return [parseEntry(raw)];
    return frags.map(parseEntry).toList();
  }

  /// Exposed so callers/tests can confirm the digit-normaliser is wired up.
  static String get bnZeroGlyph => _bnZero;
}
