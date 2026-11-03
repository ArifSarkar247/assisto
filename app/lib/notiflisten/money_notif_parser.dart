/// callmoney — ON-PHONE parser for allow-listed wallet / bank notifications
/// (bKash, Nagad, Rocket, Upay, bank apps and their SMS), Bangla + English.
///
/// Pure Dart, no I/O: the raw text never leaves the phone. The result only
/// becomes a khata entry after the user confirms it (or turned auto-save on),
/// and then only the parsed fields (amount, type, wallet, counterparty, TrxID,
/// date) are written — never the message itself.
///
/// Safety first: OTP / PIN / verification messages and promotions are
/// REJECTED (never a fake transaction); a message counts as a transaction only
/// with real proof (a TrxID / TxnID, a balance line or an account line).
/// Bangla words are written as \u escapes (language gate: no Bangla literals).
class MoneyNotif {
  final bool ok;
  final String wallet; // bkash | nagad | rocket | upay | bank
  final String? type; // income | expense
  final num? amount;
  final num? fee;
  final num? balance;
  final String? counterparty;
  final String? trxId;
  final DateTime? date;
  final String reason; // '' when ok; otp | promo | no_amount | no_type | no_proof | empty

  const MoneyNotif({
    required this.ok,
    required this.wallet,
    this.type,
    this.amount,
    this.fee,
    this.balance,
    this.counterparty,
    this.trxId,
    this.date,
    this.reason = '',
  });

  /// Stable key so the SMS and the wallet-app notification of ONE payment
  /// become one entry (TrxID first; else wallet + type + amount + minute).
  String get dedupeKey {
    if (trxId != null && trxId!.isNotEmpty) return '$wallet|$trxId';
    final d = date;
    final m = d == null ? '' : '${d.year}-${d.month}-${d.day}-${d.hour}-${d.minute}';
    return '$wallet|$type|$amount|$m';
  }
}

class MoneyNotifParser {
  MoneyNotifParser._();

  static final _bnZero = '\u09E6'.codeUnitAt(0);

  static String normalizeDigits(String s) {
    final b = StringBuffer();
    for (final c in s.codeUnits) {
      if (c >= _bnZero && c <= _bnZero + 9) {
        b.writeCharCode(0x30 + c - _bnZero);
      } else {
        b.writeCharCode(c);
      }
    }
    return b.toString();
  }

  static num? _num(String? s) {
    if (s == null) return null;
    final t = s.replaceAll(',', '').replaceAll(RegExp(r'\.$'), '');
    return num.tryParse(t);
  }

  // ---- rejection ------------------------------------------------------
  static final _otp = RegExp(
      r'\b(otp|one[- ]time|verification|verify|pin\b|password|passcode)|code\s*(is|:)'
      r'|\u0995\u09CB\u09A1|\u0997\u09CB\u09AA\u09A8 \u09A8\u09AE\u09CD\u09AC\u09B0|\u09AF\u09BE\u099A\u09BE\u0987',
      caseSensitive: false);
  static final _promo = RegExp(
      r'\b(offer|up\s*to|t&c|win|chance|discount|campaign|enjoy|get\s+\d+%|dial\s*\*)'
      r'|\d+\s*%|\u0985\u09AB\u09BE\u09B0|\u09AA\u09B0\u09CD\u09AF\u09A8\u09CD\u09A4|\u099C\u09BF\u09A4\u09C1\u09A8|\u099B\u09BE\u09A1\u09BC',
      caseSensitive: false);

  // ---- proof that this is a real transaction --------------------------
  static final _trx = RegExp(
      r'(?:trx\s*id|txn\s*id|trxid|txnid|transaction\s*id)\s*[:.#]?\s*([A-Za-z0-9]{6,})',
      caseSensitive: false);
  static final _balance = RegExp(
      r'(?:avl\.?\s*bal(?:ance)?|available\s*balance|balance|\bbal\b|\u09AC\u09CD\u09AF\u09BE\u09B2\u09C7\u09A8\u09CD\u09B8)\s*(?:is)?\s*[:.]?\s*(?:tk\.?|bdt|৳)?\s*([\d,]+(?:\.\d+)?)',
      caseSensitive: false);
  static final _fee = RegExp(
      r'(?:fee|charge|chrg|\u09AB\u09BF|\u099A\u09BE\u09B0\u09CD\u099C)\s*[:.]?\s*(?:tk\.?|bdt|৳)?\s*([\d,]+(?:\.\d+)?)',
      caseSensitive: false);
  static final _account = RegExp(r'\ba/?c\b|account|\u09B9\u09BF\u09B8\u09BE\u09AC|\u0985\u09CD\u09AF\u09BE\u0995\u09BE\u0989\u09A8\u09CD\u099F',
      caseSensitive: false);

  // ---- amount: a currency marker hugging a number, either order -------
  static final _amount = RegExp(
      r'(?:tk\.?|bdt|taka|৳)\s*([\d,]+(?:\.\d+)?)|([\d,]+(?:\.\d+)?)\s*(?:tk\b|bdt|taka|\u099F\u09BE\u0995\u09BE|৳)',
      caseSensitive: false);

  // ---- type cues (earliest cue wins; strong phrases first) -------------
  static const _creditStrong = [
    'payment received', 'received payment', 'money received', 'cash in',
    'remittance', 'salary', 'refund', 'cashback',
  ];
  static const _debitStrong = ['cash out', 'send money', 'bill pay', 'payment to', 'payment of'];
  static final _credit = RegExp(
      r'received|deposit(ed)?|credited|add\s*money|disbursed|reversal'
      r'|\u09AA\u09C7\u09DF\u09C7\u099B\u09C7\u09A8|\u09AA\u09C7\u09AF\u09BC\u09C7\u099B\u09C7\u09A8|\u0997\u09CD\u09B0\u09B9\u09A3|\u099C\u09AE\u09BE|\u0995\u09CD\u09AF\u09BE\u09B6 \u0987\u09A8|\u098F\u09B8\u09C7\u099B\u09C7|\u09B0\u09C7\u09AE\u09BF\u099F\u09CD\u09AF\u09BE\u09A8\u09CD\u09B8',
      caseSensitive: false);
  static final _debit = RegExp(
      r'payment|paid|\bsent\b|withdra(wn|wal|w)|debited|purchase|recharge|transferred\s*to|\bpos\b|\batm\b|merchant'
      r'|\u09AA\u09BE\u09A0\u09BF\u09DF\u09C7\u099B\u09C7\u09A8|\u09AA\u09BE\u09A0\u09BF\u09AF\u09BC\u09C7\u099B\u09C7\u09A8|\u09B8\u09C7\u09A8\u09CD\u09A1 \u09AE\u09BE\u09A8\u09BF|\u0995\u09CD\u09AF\u09BE\u09B6 \u0986\u0989\u099F|\u09AA\u09C7\u09AE\u09C7\u09A8\u09CD\u099F|\u0989\u09A4\u09CD\u09A4\u09CB\u09B2\u09A8|\u0996\u09B0\u099A|\u09B0\u09BF\u099A\u09BE\u09B0\u09CD\u099C|\u09A1\u09C7\u09AC\u09BF\u099F|\u09AA\u09B0\u09BF\u09B6\u09CB\u09A7|\u0995\u09C7\u099F\u09C7',
      caseSensitive: false);

  static String? detectType(String text) {
    final low = text.toLowerCase();
    var best = -1;
    String? kind;
    void hit(int at, String k) {
      if (at >= 0 && (best < 0 || at < best)) {
        best = at;
        kind = k;
      }
    }

    for (final p in _creditStrong) {
      hit(low.indexOf(p), 'income');
    }
    for (final p in _debitStrong) {
      hit(low.indexOf(p), 'expense');
    }
    if (kind != null) return kind;
    hit(_credit.firstMatch(text)?.start ?? -1, 'income');
    hit(_debit.firstMatch(text)?.start ?? -1, 'expense');
    return kind;
  }

  // ---- counterparty ----------------------------------------------------
  static final _phone = RegExp(r'(?<!\d)(01[3-9]\d{8})(?!\d)');
  static final _labelled = RegExp(
      r'\b(?:sender|receiver|recipient|agent|merchant|biller|from|to|at)\b\s*[:]?\s*(?:a/c\s*[:]?\s*)?([A-Za-z][A-Za-z0-9 .&\x27-]{1,30}?)(?=\s*(?:[().,;]|\s(?:on|tk|bdt|trx|txn|ref|bal|fee|charge|successful|is|has|was|\d)|$))',
      caseSensitive: false);
  static const _notNames = {
    'your', 'you', 'a', 'ac', 'account', 'the', 'bank', 'bkash', 'nagad', 'rocket',
    'agent', 'merchant', 'tk', 'bdt', 'customer',
  };

  static String? counterparty(String raw, String norm) {
    for (final m in _labelled.allMatches(raw)) {
      final n = m.group(1)!.trim().replaceAll(RegExp(r'[.\-]+$'), '');
      if (n.length < 2 || _notNames.contains(n.toLowerCase())) continue;
      if (RegExp(r'^(a/?c|acc)', caseSensitive: false).hasMatch(n)) continue;
      return n;
    }
    final p = _phone.firstMatch(norm);
    return p?.group(1);
  }

  // ---- date ------------------------------------------------------------
  static final _date = RegExp(
      r'(\d{4})-(\d{2})-(\d{2})|(\d{1,2})[-/](\d{1,2}|[A-Za-z]{3})[-/](\d{2,4})(?:\D{1,3}(\d{1,2}):(\d{2})(?::\d{2})?\s*([ap]m)?)?',
      caseSensitive: false);
  static const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

  static DateTime? parseDate(String norm) {
    final m = _date.firstMatch(norm);
    if (m == null) return null;
    try {
      if (m.group(1) != null) {
        return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
      }
      final d = int.parse(m.group(4)!);
      final mo = m.group(5)!;
      final mm = int.tryParse(mo) ?? (_months.indexOf(mo.toLowerCase().substring(0, 3)) + 1);
      var y = int.parse(m.group(6)!);
      if (y < 100) y += 2000;
      if (mm < 1 || mm > 12 || d < 1 || d > 31) return null;
      var h = m.group(7) == null ? 0 : int.parse(m.group(7)!);
      final ap = m.group(9)?.toLowerCase();
      if (ap == 'pm' && h < 12) h += 12;
      if (ap == 'am' && h == 12) h = 0;
      final mi = m.group(8) == null ? 0 : int.parse(m.group(8)!);
      return DateTime(y, mm, d, h, mi);
    } catch (_) {
      return null; // a date-looking token that is not a date: use the post time
    }
  }

  /// Parse one allow-listed notification. [wallet] comes from the native
  /// allow-list (package or SMS sender), never guessed from the text.
  static MoneyNotif parse(String text, {required String wallet, DateTime? postedAt}) {
    final raw = text.trim();
    if (raw.isEmpty) return MoneyNotif(ok: false, wallet: wallet, reason: 'empty');
    final norm = normalizeDigits(raw);
    if (_otp.hasMatch(norm)) return MoneyNotif(ok: false, wallet: wallet, reason: 'otp');
    final trx = _trx.firstMatch(norm);
    final bal = _balance.firstMatch(norm);
    final hasProof = trx != null || bal != null || _account.hasMatch(norm);
    if (_promo.hasMatch(norm) && trx == null) {
      return MoneyNotif(ok: false, wallet: wallet, reason: 'promo');
    }
    if (!hasProof) return MoneyNotif(ok: false, wallet: wallet, reason: 'no_proof');

    final feeM = _fee.firstMatch(norm);
    final skip = <(int, int)>[
      if (feeM != null) (feeM.start, feeM.end),
      if (bal != null) (bal.start, bal.end),
    ];
    num? amount;
    for (final m in _amount.allMatches(norm)) {
      final g = m.group(1) != null ? 1 : 2;
      final s = m.start, e = m.end;
      if (skip.any((r) => s < r.$2 && r.$1 < e)) continue;
      final v = _num(m.group(g));
      if (v != null && v > 0) {
        amount = v;
        break;
      }
    }
    if (amount == null) return MoneyNotif(ok: false, wallet: wallet, reason: 'no_amount');
    final type = detectType(norm);
    if (type == null) {
      return MoneyNotif(ok: false, wallet: wallet, amount: amount, reason: 'no_type');
    }
    return MoneyNotif(
      ok: true,
      wallet: wallet,
      type: type,
      amount: amount,
      fee: _num(feeM?.group(1)),
      balance: _num(bal?.group(1)),
      counterparty: counterparty(raw, norm),
      trxId: trx?.group(1)?.toUpperCase(),
      date: parseDate(norm) ?? postedAt,
    );
  }
}
