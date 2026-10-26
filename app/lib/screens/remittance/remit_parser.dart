import '../../voice/voice_intents.dart' show VaText;

/// budget-remittance: the QUICK ENTRY parser — one Bangla (or Banglish /
/// English) sentence, typed or spoken (speech becomes text on the phone),
/// into a draft entry: amount, currency, channel, who sent it, date, rate.
///
/// Rule-based and fully offline: no AI, no network, no cost. The result is
/// ALWAYS shown in the entry form for the user to check before saving — it
/// never saves by itself. Only legal channels are recognised (bank, bKash,
/// Nagad, Rocket, Western Union, MoneyGram). No SMS is ever read.
///
/// Bangla words are written as \u escapes: the language gate keeps Bangla
/// script out of Dart files (user-facing text lives in the ARB files).
class RemitDraft {
  final double? amount;
  final String? currency; // ISO code, null = not said
  final String? channel; // one of RemitParser.channels, null = not said
  final String? relation; // brother | father | ... (null = not said)
  final int? memberId; // a My Circle member named in the sentence
  final String? memberName;
  final double? rate;
  final DateTime? date;
  const RemitDraft({
    this.amount,
    this.currency,
    this.channel,
    this.relation,
    this.memberId,
    this.memberName,
    this.rate,
    this.date,
  });

  bool get isEmpty =>
      amount == null && currency == null && channel == null && relation == null && memberId == null && rate == null;
}

class RemitParser {
  RemitParser._();

  static const channels = ['bank', 'bkash', 'nagad', 'rocket', 'western_union', 'moneygram', 'other'];

  static const relations = [
    'brother',
    'father',
    'mother',
    'husband',
    'wife',
    'son',
    'daughter',
    'sister',
    'uncle',
    'aunt',
  ];

  // channel -> words (substring match on the normalised text)
  static const Map<String, List<String>> _channelWords = {
    'western_union': [
      '\u0993\u09af\u09bc\u09c7\u09b8\u09cd\u099f\u09be\u09b0\u09cd\u09a8',
      '\u0993\u09af\u09bc\u09c7\u09b8\u09cd\u099f\u09be\u09b0\u09cd\u09a8',
      'western union',
      'western',
      'wu ',
    ],
    'moneygram': [
      '\u09ae\u09be\u09a8\u09bf\u0997\u09cd\u09b0\u09be\u09ae',
      '\u09ae\u09be\u09a8\u09bf \u0997\u09cd\u09b0\u09be\u09ae',
      'moneygram',
      'money gram',
    ],
    'bkash': ['\u09ac\u09bf\u0995\u09be\u09b6', 'bkash', 'bikash', 'b kash'],
    'nagad': ['\u09a8\u0997\u09a6', 'nagad', 'nogod'],
    'rocket': ['\u09b0\u0995\u09c7\u099f', 'rocket'],
    'bank': [
      '\u09ac\u09cd\u09af\u09be\u0982\u0995',
      '\u09ac\u09cd\u09af\u09be\u0999\u09cd\u0995',
      '\u09ac\u09c7\u0982\u0995',
      'bank',
      '\u098f\u0995\u09be\u0989\u09a8\u09cd\u099f\u09c7',
      'account',
    ],
  };

  // relation -> word STARTS (a token starting with it: bhai-ya, bhai-ye)
  static const Map<String, List<String>> _relationWords = {
    'brother': [
      '\u09ad\u09be\u0987',
      '\u09ad\u09be\u0987\u09af\u09bc\u09be',
      '\u09a6\u09be\u09a6\u09be',
      'bhai',
      'vai',
      'bhaiya',
      'brother',
    ],
    'father': [
      '\u0986\u09ac\u09cd\u09ac\u09be',
      '\u0986\u09ac\u09cd\u09ac\u09c1',
      '\u09ac\u09be\u09ac\u09be',
      '\u0986\u09ac\u09cd\u09ac\u09be\u099c\u09be\u09a8',
      'abba',
      'abbu',
      'baba',
      'father',
      'dad',
    ],
    'mother': [
      '\u0986\u09ae\u09cd\u09ae\u09be',
      '\u0986\u09ae\u09cd\u09ae\u09c1',
      '\u09ae\u09be ',
      '\u09ae\u09be\u09af\u09bc',
      'amma',
      'ammu',
      'mother',
      'mom',
    ],
    'husband': ['\u09b8\u09cd\u09ac\u09be\u09ae\u09c0', '\u099c\u09be\u09ae\u09be\u0987', 'shami', 'swami', 'husband'],
    'wife': ['\u09b8\u09cd\u09a4\u09cd\u09b0\u09c0', '\u09ac\u0989', '\u09ac\u09cc', 'wife', 'bou'],
    'son': ['\u099b\u09c7\u09b2\u09c7', '\u09aa\u09cb\u09b2\u09be', 'chele', 'son '],
    'daughter': ['\u09ae\u09c7\u09af\u09bc\u09c7', '\u09ae\u09be\u0987\u09af\u09bc\u09be', 'meye', 'daughter'],
    'sister': [
      '\u09ac\u09cb\u09a8',
      '\u0986\u09aa\u09c1',
      '\u0986\u09aa\u09be',
      '\u09ac\u09c1\u09ac\u09c1',
      'bon ',
      'apu',
      'sister',
    ],
    'uncle': [
      '\u09ae\u09be\u09ae\u09be',
      '\u099a\u09be\u099a\u09be',
      '\u0995\u09be\u0995\u09be',
      '\u0996\u09be\u09b2\u09c1',
      '\u09ab\u09c1\u09aa\u09be',
      'mama',
      'chacha',
      'uncle',
    ],
    'aunt': [
      '\u0996\u09be\u09b2\u09be',
      '\u09ab\u09c1\u09aa\u09c1',
      '\u09ae\u09be\u09ae\u09bf',
      '\u099a\u09be\u099a\u09bf',
      'khala',
      'fupu',
      'aunt',
    ],
  };

  // currency -> words
  static const Map<String, List<String>> _currencyWords = {
    'BDT': ['\u099f\u09be\u0995\u09be', '\u099f\u09be\u0995\u09be\u09b0', 'taka', 'tk', '\u09f3', 'bdt'],
    'SAR': [
      '\u09b0\u09bf\u09af\u09bc\u09be\u09b2',
      '\u09b0\u09bf\u09af\u09bc\u09be\u09b2',
      '\u09b0\u09bf\u09af\u09bc\u09c7\u09b2',
      '\u09b0\u09bf\u09af\u09bc\u09c7\u09b2',
      'riyal',
      'rial',
      'sar',
    ],
    'AED': ['\u09a6\u09bf\u09b0\u09b9\u09be\u09ae', 'dirham', 'aed'],
    'QAR': ['\u0995\u09be\u09a4\u09be\u09b0\u09bf', 'qar'],
    'KWD': ['\u09a6\u09bf\u09a8\u09be\u09b0', 'dinar', 'kwd'],
    'OMR': ['\u0993\u09ae\u09be\u09a8\u09bf', 'omr'],
    'MYR': ['\u09b0\u09bf\u0999\u09cd\u0997\u09bf\u09a4', '\u09b0\u09bf\u0982\u0997\u09bf\u09a4', 'ringgit', 'myr'],
    'SGD': ['\u09b8\u09bf\u0999\u09cd\u0997\u09be\u09aa\u09c1\u09b0\u09bf \u09a1\u09b2\u09be\u09b0', 'sgd'],
    'USD': ['\u09a1\u09b2\u09be\u09b0', 'dollar', 'usd', r'$'],
    'GBP': ['\u09aa\u09be\u0989\u09a8\u09cd\u09a1', 'pound', 'gbp', '£'],
    'EUR': ['\u0987\u0989\u09b0\u09cb', 'euro', 'eur', '€'],
    'JPY': ['\u0987\u09af\u09bc\u09c7\u09a8', 'yen', 'jpy'],
    'KRW': ['won', 'krw'],
  };

  // multipliers
  static const Map<String, double> _mult = {
    '\u09b9\u09be\u099c\u09be\u09b0': 1000,
    '\u09b9\u09be\u099c\u09be\u09b0\u09c7\u09b0': 1000,
    'hajar': 1000,
    'hazar': 1000,
    'thousand': 1000,
    'k': 1000,
    '\u09b2\u09be\u0996': 100000,
    '\u09b2\u0995\u09cd\u09b7': 100000,
    '\u09b2\u09be\u0996\u09c7\u09b0': 100000,
    'lakh': 100000,
    'lac': 100000,
    'lakhs': 100000,
    '\u0995\u09cb\u099f\u09bf': 10000000,
    'crore': 10000000,
    '\u09b6': 100,
    '\u09b6\u09cb': 100,
    '\u09b6\u09a4': 100,
    'hundred': 100,
  };

  // number words (the common ones people say about remittance)
  static const Map<String, double> _numWords = {
    '\u098f\u0995': 1,
    '\u09a6\u09c1\u0987': 2,
    '\u09a6\u09c1': 2,
    '\u09a4\u09bf\u09a8': 3,
    '\u099a\u09be\u09b0': 4,
    '\u09aa\u09be\u0981\u099a': 5,
    '\u099b\u09af\u09bc': 6,
    '\u09b8\u09be\u09a4': 7,
    '\u0986\u099f': 8,
    '\u09a8\u09af\u09bc': 9,
    '\u09a6\u09b6': 10,
    '\u09ac\u09be\u09b0\u09cb': 12,
    '\u09aa\u09a8\u09c7\u09b0': 15,
    '\u09aa\u09a8\u09c7\u09b0\u09cb': 15,
    '\u09ac\u09bf\u09b6': 20,
    '\u0995\u09c1\u09a1\u09bc\u09bf': 20,
    '\u09aa\u0981\u099a\u09bf\u09b6': 25,
    '\u09a4\u09cd\u09b0\u09bf\u09b6': 30,
    '\u09a4\u09bf\u09b0\u09bf\u09b6': 30,
    '\u09aa\u0981\u09af\u09bc\u09a4\u09cd\u09b0\u09bf\u09b6': 35,
    '\u099a\u09b2\u09cd\u09b2\u09bf\u09b6': 40,
    '\u09aa\u099e\u09cd\u099a\u09be\u09b6': 50,
    '\u09b7\u09be\u099f': 60,
    '\u09b8\u09a4\u09cd\u09a4\u09b0': 70,
    '\u0986\u09b6\u09bf': 80,
    '\u09a8\u09ac\u09cd\u09ac\u0987': 90,
    '\u09a6\u09c7\u09a1\u09bc': 1.5,
    '\u0986\u09a1\u09bc\u09be\u0987': 2.5,
    'one': 1,
    'two': 2,
    'three': 3,
    'five': 5,
    'ten': 10,
    'fifteen': 15,
    'twenty': 20,
    'thirty': 30,
    'forty': 40,
    'fifty': 50,
  };

  static const _rateWords = [
    '\u09b0\u09c7\u099f',
    '\u09b0\u09c7\u099f\u09c7',
    'rate',
    'dore',
    '\u09a6\u09b0\u09c7',
    '\u09a6\u09b0',
  ];
  static const _yesterday = ['\u0997\u09a4\u0995\u09be\u09b2', 'gotokal', 'yesterday'];
  static const _today = ['\u0986\u099c', '\u0986\u099c\u0995\u09c7', 'ajke', 'aaj', 'today'];

  static String _n(String s) => VaText.norm(s);

  static List<String> _ns(List<String> l) => [for (final w in l) _n(w)];

  /// A keyword hit: "a b" (several words) anywhere; "w " (trailing space)
  /// = a whole token; Latin = a whole token; Bangla = a token STARTING with
  /// it (Bangla adds case endings: bikash-e, bhai-ya); symbols anywhere.
  static bool _hasWord(String text, List<String> toks, List<String> words) {
    for (final raw in words) {
      final w = _n(raw);
      if (w.isEmpty) continue;
      if (raw.endsWith(' ')) {
        if (toks.contains(w)) return true;
      } else if (w.contains(' ')) {
        if (' $text '.contains(' $w')) return true;
      } else if (RegExp(r'^[a-z]+$').hasMatch(w)) {
        if (toks.contains(w)) return true;
      } else if (RegExp(r'^[\u0980-\u09FF]+$').hasMatch(w)) {
        if (toks.any((t) => t.startsWith(w))) return true;
      } else if (text.contains(w)) {
        return true;
      }
    }
    return false;
  }

  static double? _tokNum(String tok) {
    final d = double.tryParse(tok.replaceAll(',', ''));
    if (d != null) return d;
    final n = _n(tok);
    for (final e in _numWords.entries) {
      if (_n(e.key) == n) return e.value;
    }
    return null;
  }

  static double? _tokMult(String tok) {
    final n = _n(tok);
    for (final e in _mult.entries) {
      if (_n(e.key) == n) return e.value;
    }
    // glued forms ("20k") are split before this.
    return null;
  }

  /// Split glued forms ("20k", Bangla digits + hajar / taka) into number +
  /// word tokens.
  static List<String> _tokens(String norm) {
    final spaced = norm
        .replaceAllMapped(RegExp(r'(\d)([^\d\s.,])'), (m) => '${m[1]} ${m[2]}')
        .replaceAllMapped(RegExp(r'([^\d\s.,])(\d)'), (m) => '${m[1]} ${m[2]}');
    return spaced.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  }

  /// [members]: My Circle members ({id, name, relation}) so "Karim sent…"
  /// or a relation word that matches exactly one member picks that member.
  static RemitDraft parse(String text, {List<Map<String, dynamic>> members = const [], DateTime? now}) {
    final norm = _n(text.replaceAllMapped(RegExp(r'([0-9\u09E6-\u09EF]),(?=[0-9\u09E6-\u09EF])'), (m) => m[1]!));
    if (norm.isEmpty) return const RemitDraft();
    final toks = _tokens(norm);

    // ---- rate: "rate 32.5" / "32.5 rate" / "dore 32"
    double? rate;
    final rateIdx = <int>{};
    for (var i = 0; i < toks.length; i++) {
      if (!_ns(_rateWords).contains(toks[i])) continue;
      for (final j in [i + 1, i - 1]) {
        if (j < 0 || j >= toks.length) continue;
        final v = double.tryParse(toks[j].replaceAll(',', ''));
        if (v != null && v > 0 && v < 1000) {
          rate = v;
          rateIdx.add(j);
          break;
        }
      }
      if (rate != null) break;
    }

    // ---- amount: the first number (digits or words), times multipliers
    double? amount;
    for (var i = 0; i < toks.length && amount == null; i++) {
      if (rateIdx.contains(i)) continue;
      final base = _tokNum(toks[i]);
      if (base == null || base <= 0) continue;
      var v = base;
      for (var j = i + 1; j < toks.length; j++) {
        final m = _tokMult(toks[j]);
        if (m == null) break;
        v = v * m; // "bish hajar", "der lakh", "20 k"
      }
      amount = v;
    }

    // ---- currency
    String? currency;
    for (final e in _currencyWords.entries) {
      if (_hasWord(norm, toks, e.value)) {
        currency = e.key;
        if (e.key != 'BDT') break; // a foreign currency word wins over "taka"
      }
    }

    // ---- channel (the most specific first: Western Union before bank)
    String? channel;
    for (final e in _channelWords.entries) {
      if (_hasWord(norm, toks, e.value)) {
        channel = e.key;
        break;
      }
    }

    // ---- who: a My Circle member's name, else a relation word
    int? memberId;
    String? memberName;
    for (final m in members) {
      final name = '${m['name'] ?? ''}'.trim();
      if (name.length < 2) continue;
      if (norm.contains(_n(name))) {
        memberId = int.tryParse('${m['id']}');
        memberName = name;
        break;
      }
    }
    String? relation;
    for (final e in _relationWords.entries) {
      final starts = _ns(e.value);
      final hit = toks.any(
        (t) => starts.any((w) {
          final ww = w.trim();
          if (ww.isEmpty) return false;
          // short Bangla words (e.g. mother) must be the whole token
          return w.endsWith(' ') ? t == ww : t.startsWith(ww);
        }),
      );
      if (hit) {
        relation = e.key;
        break;
      }
    }
    if (memberId == null && relation != null) {
      final same = members.where((m) => '${m['relation'] ?? ''}' == relation).toList();
      if (same.length == 1) {
        memberId = int.tryParse('${same.first['id']}');
        memberName = '${same.first['name'] ?? ''}';
      }
    }

    // ---- date
    final today = now ?? DateTime.now();
    DateTime? date;
    if (_hasWord(norm, toks, _yesterday)) {
      date = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 1));
    } else if (toks.any((t) => _ns(_today).contains(t))) {
      date = DateTime(today.year, today.month, today.day);
    }

    return RemitDraft(
      amount: amount,
      currency: currency,
      channel: channel,
      relation: relation,
      memberId: memberId,
      memberName: memberName,
      rate: rate,
      date: date,
    );
  }
}
