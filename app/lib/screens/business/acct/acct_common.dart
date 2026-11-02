import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../acct_api.dart';
import '../../../api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../messaging/date_separators.dart' show fmtDate, localDigits;

/// acctui — shared bits of the accounting UI: money / date formatting,
/// labels for the plain-word entry kinds, the period maths (mirror of
/// core.logic.ledger_entry.period_range) and the OFFLINE QUEUE.

String acctLang(BuildContext context) => Localizations.localeOf(context).languageCode;

/// Poisha -> "৳1,25,000" (lakh grouping, Bangla digits in bn). Negative in
/// brackets, the accounting convention.
String acctMoneyFor(Object? poisha, String lang, {bool signed = false}) {
  final p = (poisha as num?)?.toInt() ?? 0;
  final taka = p.abs() / 100;
  final f = NumberFormat(
      taka == taka.truncateToDouble() ? '#,##,##0' : '#,##,##0.00', 'en');
  final s = localDigits('৳${f.format(taka)}', lang);
  if (p < 0) return signed ? '−$s' : '($s)';
  return signed && p > 0 ? '+$s' : s;
}

String acctMoney(BuildContext context, Object? poisha, {bool signed = false}) =>
    acctMoneyFor(poisha, acctLang(context), signed: signed);

/// "1,250.50" / Bangla-digit amounts / "1,250.5" -> poisha. Null when not a positive number.
int? parseTakaToPoisha(String raw) {
  final b = StringBuffer();
  for (final r in raw.runes) {
    if (r >= 0x09E6 && r <= 0x09EF) {
      b.writeCharCode(0x30 + r - 0x09E6);
    } else if ((r >= 0x30 && r <= 0x39) || r == 0x2E) {
      b.writeCharCode(r);
    }
  }
  final v = double.tryParse(b.toString());
  if (v == null || v <= 0 || v > 1e11) return null;
  return (v * 100).round();
}

/// Poisha -> plain "1250" / "1250.5" for a text field (latin digits; the
/// field accepts either script).
String poishaToField(int? poisha) {
  if (poisha == null || poisha == 0) return '';
  final t = poisha / 100;
  return t == t.truncateToDouble() ? '${t.toInt()}' : t.toStringAsFixed(2);
}

String acctIso(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

String acctDay(BuildContext context, Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  return d == null ? '' : fmtDate('d MMM yyyy', d.toLocal(), acctLang(context));
}

String acctDigits(BuildContext context, Object? s) =>
    localDigits('${s ?? ''}', acctLang(context));

/// 16 random hex chars — minted ONCE per entry and replayed until the server
/// answers, so an offline retry never books the same entry twice.
String newAcctClientId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
}

// ------------------------------------------------------------------ labels
const acctKinds = [
  'sale', 'purchase', 'expense', 'due', 'money_in', 'money_out', 'transfer'
];
const acctMoneyAccounts = ['cash', 'bank', 'bkash', 'nagad'];
const acctExpenseCodes = [
  '6010', '6020', '6030', '6040', '6050', '6060', '6070', '6080', '6090',
  '6100', '6110', '6900'
];
const acctInPurposes = ['customer', 'capital', 'loan', 'other'];
const acctOutPurposes = ['supplier', 'drawings', 'loan', 'vat'];

String acctKindLabel(AppLocalizations t, String k) => switch (k) {
      'sale' => t.acuKindSale,
      'purchase' => t.acuKindPurchase,
      'expense' => t.acuKindExpense,
      'due' => t.acuKindDue,
      'money_in' => t.acuKindIn,
      'money_out' => t.acuKindOut,
      _ => t.acuKindTransfer,
    };

String acctKindHint(AppLocalizations t, String k) => switch (k) {
      'sale' => t.acuKindSaleHint,
      'purchase' => t.acuKindPurchaseHint,
      'expense' => t.acuKindExpenseHint,
      'due' => t.acuKindDueHint,
      'money_in' => t.acuKindInHint,
      'money_out' => t.acuKindOutHint,
      _ => t.acuKindTransferHint,
    };

IconData acctKindIcon(String k) => switch (k) {
      'sale' => Icons.point_of_sale_rounded,
      'purchase' => Icons.inventory_2_rounded,
      'expense' => Icons.receipt_long_rounded,
      'due' => Icons.menu_book_rounded,
      'money_in' => Icons.south_west_rounded,
      'money_out' => Icons.north_east_rounded,
      _ => Icons.swap_horiz_rounded,
    };

String acctAccountLabel(AppLocalizations t, String a) => switch (a) {
      'cash' => t.acuAccCash,
      'bank' => t.acuAccBank,
      'bkash' => t.acuAccBkash,
      'nagad' => t.acuAccNagad,
      _ => t.acuAccDue,
    };

String acctExpenseLabel(AppLocalizations t, String code) => switch (code) {
      '6010' => t.acuExpRent,
      '6020' => t.acuExpSalary,
      '6030' => t.acuExpUtility,
      '6040' => t.acuExpTransport,
      '6050' => t.acuExpPhone,
      '6060' => t.acuExpAds,
      '6070' => t.acuExpRepair,
      '6080' => t.acuExpCharges,
      '6090' => t.acuExpPackaging,
      '6100' => t.acuExpFood,
      '6110' => t.acuExpFees,
      _ => t.acuExpOther,
    };

String acctPurposeLabel(AppLocalizations t, String kind, String p) =>
    kind == 'money_in'
        ? switch (p) {
            'customer' => t.acuInCustomer,
            'capital' => t.acuInCapital,
            'loan' => t.acuInLoan,
            _ => t.acuInOther,
          }
        : switch (p) {
            'supplier' => t.acuOutSupplier,
            'drawings' => t.acuOutDrawings,
            'loan' => t.acuOutLoan,
            _ => t.acuOutVat,
          };

/// Which khata book an entry needs a person from (null = none needed).
String? acctPartyBook(String kind, {String? purpose, String? pay}) {
  if (kind == 'due') return 'customer';
  if (kind == 'purchase') return pay == 'due' ? 'supplier' : null;
  if (kind == 'money_in') return purpose == 'customer' ? 'customer' : null;
  if (kind == 'money_out') return purpose == 'supplier' ? 'supplier' : null;
  return null;
}

// ------------------------------------------------------------------ period
enum AcctPeriodKind { month, quarter, year }

/// A reporting period: month / quarter / year, `offset` 0 = current,
/// -1 = previous ... End is capped at today (mirror of period_range).
class AcctPeriod {
  final AcctPeriodKind kind;
  final int offset;
  const AcctPeriod(this.kind, [this.offset = 0]);

  (DateTime, DateTime) range([DateTime? now]) {
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    late DateTime s, e;
    switch (kind) {
      case AcctPeriodKind.year:
        s = DateTime(today.year + offset, 1, 1);
        e = DateTime(today.year + offset, 12, 31);
      case AcctPeriodKind.quarter:
        final q0 = (today.month - 1) ~/ 3 + offset;
        final y = today.year + (q0 / 4).floor();
        final q = q0 % 4;
        s = DateTime(y, q * 3 + 1, 1);
        e = DateTime(y, q * 3 + 4, 0);
      case AcctPeriodKind.month:
        s = DateTime(today.year, today.month + offset, 1);
        e = DateTime(s.year, s.month + 1, 0);
    }
    return (s, e.isAfter(today) ? today : e);
  }

  bool get isCurrent => offset >= 0;

  String label(String lang, [DateTime? now]) {
    final (s, e) = range(now);
    switch (kind) {
      case AcctPeriodKind.year:
        return localDigits('${s.year}', lang);
      case AcctPeriodKind.quarter:
        return '${fmtDate('MMM', s, lang)} – ${fmtDate('MMM yyyy', e, lang)}';
      case AcctPeriodKind.month:
        return fmtDate('MMMM yyyy', s, lang);
    }
  }

  AcctPeriod shift(int by) => AcctPeriod(kind, offset + by);
}

// ------------------------------------------------------------------ queue
/// OFFLINE QUEUE: an entry saved without internet waits on the phone (with
/// its client_id) and is sent when the accounts screen opens / resumes or the
/// user taps "send now". The server is idempotent on client_id, so a replay
/// after a lost answer never books twice. A server REFUSAL (4xx) is kept as
/// `failed` with the server's words, for the user to fix or discard — never
/// silently dropped.
class AcctQueue {
  static const _key = 'acct_queue_v1';

  static Future<List<Map<String, dynamic>>> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<Map<String, dynamic>> rows) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(rows));
    } catch (_) {
      // best-effort: a phone without storage still saves online entries
    }
  }

  static Future<void> add(int? businessId, Map<String, dynamic> entry) async {
    final rows = await load();
    rows.removeWhere((r) => (r['entry'] as Map?)?['client_id'] == entry['client_id']);
    rows.add({'business': businessId, 'entry': entry, 'at': DateTime.now().toIso8601String()});
    await _save(rows);
  }

  static Future<void> remove(String clientId) async {
    final rows = await load();
    rows.removeWhere((r) => (r['entry'] as Map?)?['client_id'] == clientId);
    await _save(rows);
  }

  /// Sends what waits. Returns how many were saved on the server. Stops at
  /// the first network failure (still offline).
  static Future<int> flush(ApiClient api) async {
    final rows = await load();
    if (rows.isEmpty) return 0;
    var sent = 0;
    final keep = <Map<String, dynamic>>[];
    var offline = false;
    for (final r in rows) {
      if (offline || r['failed'] != null) {
        keep.add(r);
        continue;
      }
      try {
        final res = await api.acctCreateEntry(
            r['business'] as int?, (r['entry'] as Map).cast<String, dynamic>());
        final st = res['_status'] as int? ?? 0;
        if (st == 200 || st == 201) {
          sent++;
        } else if (st >= 400 && st < 500) {
          keep.add({...r, 'failed': res['detail'] ?? '$st'});
        } else {
          keep.add(r);
          offline = true;
        }
      } catch (_) {
        keep.add(r);
        offline = true;
      }
    }
    await _save(keep);
    return sent;
  }
}
