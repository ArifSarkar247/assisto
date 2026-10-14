import 'api.dart';

/// FAMILY ACCOUNTING API surface (#61, SPEC v2.1 §21) — shared family money.
///
/// Implemented as an EXTENSION on [ApiClient] (built only on the public
/// getJson / postJson helpers) so the family-accounting section ships WITHOUT
/// editing api.dart. The integrator SHOULD later fold these into ApiClient
/// proper; the paths + shapes below are authoritative.
///
/// EMITTED ENDPOINT NEEDS (see .phaseB/up_famacct_integration.md). None of
/// these exist on the server yet, so every call is wrapped so the section can
/// degrade to the on-device compute path ([FamAcctLocal]) and show honest
/// states rather than crash. All money crosses the wire as INTEGER POISHA
/// (1 taka = 100 poisha) — never a float. The family MEMBER rows are READ from
/// the existing `family` / Connected-Circle contacts; this surface defines no
/// new contact store.
extension FamAcctApi on ApiClient {
  /// GET /family/accounting/summary?month=YYYY-MM ->
  /// {month, total_poisha, by_category:{slug:poisha}, members:[{member, name,
  /// paid_poisha, share_poisha, net_poisha}], settlements:[{from,to,
  /// amount_poisha, message{bn,en}}], pool:{target,collected,remaining,pct,
  /// state,label{bn,en},breakdown:[{member,amount}]}}.
  /// Privacy: the server returns only items the caller participates in
  /// (shared==true); private spending is never included.
  Future<Map<String, dynamic>> famAcctSummary({String? month}) =>
      getJson('/family/accounting/summary${month != null ? '?month=$month' : ''}');

  /// GET /family/accounting/expenses?month=YYYY-MM ->
  /// {expenses:[{id, payer, payer_name, total_poisha, category, mode, note,
  /// date, shares:[{member, name, share_poisha}], ai_captured}]}.
  /// Shared-only (privacy honoured server-side).
  Future<Map<String, dynamic>> famAcctExpenses({String? month}) =>
      getJson('/family/accounting/expenses${month != null ? '?month=$month' : ''}');

  /// POST /family/accounting/expenses {payer, total_poisha, category, note,
  /// date, mode: equal|shares|exact, members:[id] (equal) | parts:[{member,
  /// weight|amount}]} -> the created expense (with its computed split).
  /// `shared` defaults true; set false for a private personal item.
  Future<Map<String, dynamic>> famAcctAddExpense(Map<String, dynamic> body) =>
      postJson('/family/accounting/expenses', body);

  /// DELETE is modelled as POST .../delete {id} to avoid touching api.dart's
  /// verb set. -> {ok:true}.
  Future<Map<String, dynamic>> famAcctDeleteExpense(int id) =>
      postJson('/family/accounting/expenses/delete', {'id': id});

  /// GET /family/accounting/pool?month=YYYY-MM -> the pool block (see summary).
  Future<Map<String, dynamic>> famAcctPool({String? month}) =>
      getJson('/family/accounting/pool${month != null ? '?month=$month' : ''}');

  /// POST /family/accounting/pool {target_poisha} -> updated pool.
  Future<Map<String, dynamic>> famAcctSetPoolTarget(int targetPoisha) =>
      postJson('/family/accounting/pool', {'target_poisha': targetPoisha});

  /// POST /family/accounting/pool/contribute {member, amount_poisha} -> pool.
  Future<Map<String, dynamic>> famAcctContribute(int member, int amountPoisha) =>
      postJson('/family/accounting/pool/contribute',
          {'member': member, 'amount_poisha': amountPoisha});

  /// POST /family/accounting/settle {from, to, amount_poisha} — records that a
  /// settle-up transfer was paid (removes it from outstanding). -> {ok:true}.
  Future<Map<String, dynamic>> famAcctSettle(
          int from, int to, int amountPoisha) =>
      postJson('/family/accounting/settle',
          {'from': from, 'to': to, 'amount_poisha': amountPoisha});
}

/// On-device mirror of famacct_engine.py's integer-poisha math. Used as the
/// compute path while the endpoints above are not yet live, and as the single
/// source of truth for the UI's taka<->poisha conversion so NO float ever
/// enters the ledger (parsing goes through [takaToPoisha] on the string).
class FamAcctLocal {
  /// Parse a taka-ish string ("12.50", "1,250") to INTEGER poisha. Mirrors
  /// to_poisha(): decimal-string path, half-up on the paisa, no binary float.
  static int takaToPoisha(String input) {
    var s = input.trim().replaceAll(',', '');
    if (s.isEmpty) return 0;
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    String whole, frac;
    final dot = s.indexOf('.');
    if (dot >= 0) {
      whole = s.substring(0, dot);
      frac = s.substring(dot + 1);
    } else {
      whole = s;
      frac = '';
    }
    if (whole.isEmpty) whole = '0';
    frac = (frac + '00');
    frac = frac.substring(0, 3); // 3 digits -> round the 3rd
    final taka = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (taka == null || milli == null) return 0;
    var poisha = taka * 100 + milli ~/ 10;
    if (milli % 10 >= 5) poisha += 1;
    return neg ? -poisha : poisha;
  }

  /// Format integer poisha as a ৳ amount string (always 2 dp, lakh grouping).
  /// The ৳ sign is a currency glyph, not Bangla copy.
  static String fmtPoisha(int p) {
    final neg = p < 0;
    final abs = p.abs();
    final taka = abs ~/ 100;
    final paisa = abs % 100;
    final body = '${_group(taka)}.${paisa.toString().padLeft(2, '0')}';
    return '${neg ? '-' : ''}\u09F3$body'; // \u09F3 = BDT taka sign (currency glyph, not copy)
  }

  static String _group(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$tail';
  }

  /// Equal split with remainder handed one-each to the first members, so the
  /// returned shares sum EXACTLY to [totalPoisha]. Mirrors split_equal().
  static List<int> splitEqual(int totalPoisha, int n) {
    if (n <= 0) return const [];
    final sign = totalPoisha < 0 ? -1 : 1;
    final abs = totalPoisha.abs();
    final base = abs ~/ n;
    final rem = abs % n;
    return [for (var i = 0; i < n; i++) sign * (base + (i < rem ? 1 : 0))];
  }
}
