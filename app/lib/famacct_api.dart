import 'api.dart';
import 'widgets/money_digits.dart'; // gap-familycare
import 'widgets/num_input.dart'; // savesweep

/// FAMILY ACCOUNTING API surface (#61, SPEC v2.1 §21) — shared family money.
///
/// Implemented as an EXTENSION on [ApiClient] (built only on the public
/// getJson / postJson helpers) so the family-accounting section ships WITHOUT
/// editing api.dart. The integrator SHOULD later fold these into ApiClient
/// proper; the paths + shapes below are authoritative.
///
/// Backed by core/views_m1_routes.py (Fam* views, famacct_engine maths). A
/// failure is an [ApiException] the section shows honestly (no local
/// fallback ledger). Members are 'self' (the account owner) or a family
/// member id. All money crosses the wire as INTEGER POISHA
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
  Future<Map<String, dynamic>> famAcctSummary({String? month, int? family}) =>
      getJson('/family/accounting/summary${_famQ(month: month, family: family)}');

  /// GET /family/accounting/expenses?month=YYYY-MM ->
  /// {expenses:[{id, payer, payer_name, total_poisha, category, mode, note,
  /// date, shares:[{member, name, share_poisha}], ai_captured}]}.
  /// Shared-only (privacy honoured server-side).
  Future<Map<String, dynamic>> famAcctExpenses({String? month, int? family}) =>
      getJson('/family/accounting/expenses${_famQ(month: month, family: family)}');

  /// POST /family/accounting/expenses {payer, total_poisha, category, note,
  /// date, mode: equal|shares|exact, members:[id] (equal) | parts:[{member,
  /// weight|amount}]} -> the created expense (with its computed split).
  /// `shared` defaults true; set false for a private personal item.
  Future<Map<String, dynamic>> famAcctAddExpense(Map<String, dynamic> body, {int? family}) =>
      postJson('/family/accounting/expenses', {...body, if (family != null) 'family': family});

  /// DELETE is modelled as POST .../delete {id} to avoid touching api.dart's
  /// verb set. -> {ok:true}.
  Future<Map<String, dynamic>> famAcctDeleteExpense(int id, {int? family}) =>
      postJson('/family/accounting/expenses/delete',
          {'id': id, if (family != null) 'family': family});

  /// GET /family/accounting/pool?month=YYYY-MM -> the pool block (see summary).
  Future<Map<String, dynamic>> famAcctPool({String? month}) =>
      getJson('/family/accounting/pool${month != null ? '?month=$month' : ''}');

  /// POST /family/accounting/pool {target_poisha} -> updated pool.
  Future<Map<String, dynamic>> famAcctSetPoolTarget(int targetPoisha) =>
      postJson('/family/accounting/pool', {'target_poisha': targetPoisha});

  /// POST /family/accounting/pool/contribute {member, amount_poisha} -> pool.
  Future<Map<String, dynamic>> famAcctContribute(
          Object member, int amountPoisha) =>
      postJson('/family/accounting/pool/contribute',
          {'member': member, 'amount_poisha': amountPoisha});

  /// POST /family/accounting/settle {from, to, amount_poisha} — records that a
  /// settle-up transfer was paid. The server refuses an amount above what
  /// `from` actually owes `to` (400 exceeds_outstanding, max_poisha).
  /// -> {ok:true, remaining:[{from,to,amount_poisha}]}.
  Future<Map<String, dynamic>> famAcctSettle(
          Object from, Object to, int amountPoisha, {int? family}) =>
      postJson('/family/accounting/settle', {
        'from': from, 'to': to, 'amount_poisha': amountPoisha,
        if (family != null) 'family': family,
      });

  // gap-familycare: named goals of a SHARED family ledger (Family Care v3).
  // A goal: {id, name, target_poisha, collected_poisha, remaining_poisha,
  // pct, state, closed, can_close, created_by_name, breakdown:[{member, name,
  // amount_poisha}]}. Money is only RECORDED — Assisto never holds or moves it.
  Future<Map<String, dynamic>> famGoalCreate(int family, String name, int targetPoisha) =>
      postJson('/family/accounting/goals',
          {'family': family, 'name': name, 'target_poisha': targetPoisha});

  Future<Map<String, dynamic>> famGoalContribute(int goalId, Object member, int amountPoisha) =>
      postJson('/family/accounting/goals/$goalId/contribute',
          {'member': member, 'amount_poisha': amountPoisha});

  /// close | reopen (who made it, or a family admin)
  Future<Map<String, dynamic>> famGoalAction(int goalId, String action) =>
      postJson('/family/accounting/goals/$goalId/$action');
}

/// ?month=…&family=… (either may be absent).
String _famQ({String? month, int? family}) {
  final q = [if (month != null) 'month=$month', if (family != null) 'family=$family'];
  return q.isEmpty ? '' : '?${q.join('&')}';
}

/// On-device mirror of famacct_engine.py's integer-poisha helpers, used for
/// the UI's taka<->poisha conversion so NO float ever enters the ledger
/// (parsing goes through [takaToPoisha] on the string).
class FamAcctLocal {
  /// Parse a taka-ish string ("12.50", "1,250") to INTEGER poisha. Mirrors
  /// to_poisha(): decimal-string path, half-up on the paisa, no binary float.
  static int takaToPoisha(String input) =>
      // savesweep (owner bug 10 Nov): the old body padded the fraction to 2
      // digits then took 3 for every WHOLE amount ("15000") -> RangeError inside
      // the Save tap -> Save did nothing. It also could not read Bangla
      // digits. Now the shared parser; 0 = no valid amount (caller shows why).
      takaToPoishaInput(input) ?? 0;

  /// Format integer poisha as a ৳ amount string (always 2 dp, lakh grouping).
  /// The ৳ sign is a currency glyph, not Bangla copy.
  static String fmtPoisha(int p) {
    final neg = p < 0;
    final abs = p.abs();
    final taka = abs ~/ 100;
    final paisa = abs % 100;
    final body = '${_group(taka)}.${paisa.toString().padLeft(2, '0')}';
    // gap-familycare: Bangla digits while the UI is Bangla (syncMoneyDigits)
    return moneyDigits('${neg ? '-' : ''}\u09F3$body'); // \u09F3 = BDT taka sign (currency glyph, not copy)
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
