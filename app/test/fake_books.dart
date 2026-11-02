// ledger (owner Part 1 f): server-shaped Books responses (backend/core/
// ledger_views.py) for the hand-worked grocery fixture in
// backend/core/tests_ledger.py — net profit ৳370, total assets ৳8,470,
// debits = credits. Account names come from the server already in the
// request language; the fixture keeps English names (gallery + tests).

Map<String, dynamic> _n(String code, String en, int amount, {String type = 'asset'}) =>
    {'code': code, 'name': en, 'type': type, 'group': '', 'amount': amount};

const _book = {
  'start_date': '2026-10-15', 'lock_date': null, 'last_sync_at': '2026-11-02T10:00:00+06:00',
  'opening_inventory': 665000, 'warning': null,
};

Map<String, dynamic>? fakeBooksGet(String path, {bool empty = false}) {
  if (!path.startsWith('/business/books/')) return null;
  if (path.contains('/business/books/profit-loss')) {
    return {
      'from': '2026-11-01', 'to': '2026-11-02',
      'sales': empty ? [] : [_n('4010', 'Sales — shop (POS)', 200000), _n('4020', 'Sales — khata credit', 15000)],
      'gross_sales': empty ? 0 : 215000,
      'discounts': [], 'discounts_total': empty ? 0 : 5000,
      'net_sales': empty ? 0 : 210000, 'cogs': [], 'cogs_total': empty ? 0 : 115000,
      'gross_profit': empty ? 0 : 95000, 'gross_margin_pct': empty ? null : 45.2,
      'operating_expenses': empty ? [] : [_n('6010', 'Rent', 50000), _n('6030', 'Utilities', 8000)],
      'operating_expenses_total': empty ? 0 : 58000,
      'other_income': [], 'other_income_total': 0,
      'net_profit': empty ? 0 : 37000, 'book': _book,
    };
  }
  if (path.contains('/business/books/balance-sheet')) {
    return {
      'as_of': '2026-11-02',
      'assets': empty ? [] : [_n('1010', 'Cash in hand', 7000), _n('1020', 'bKash', 55000),
        _n('1100', 'Accounts receivable (customers)', 35000), _n('1200', 'Inventory (stock)', 750000)],
      'total_assets': empty ? 0 : 847000,
      'liabilities': empty ? [] : [_n('2010', 'Accounts payable (suppliers)', 140000),
        _n('2900', 'Suspense — unclassified cash', 5000)],
      'total_liabilities': empty ? 0 : 145000,
      'equity': empty ? [] : [_n('3030', 'Opening balance equity', 665000)],
      'profit_to_date': empty ? 0 : 37000, 'total_equity': empty ? 0 : 702000,
      'total_liabilities_equity': empty ? 0 : 847000, 'balanced': true, 'book': _book,
    };
  }
  // trial balance
  return {
    'as_of': '2026-11-02',
    'rows': empty ? [] : [
      {..._n('1010', 'Cash in hand', 7000), 'debit': 7000, 'credit': 0},
      {..._n('2010', 'Accounts payable (suppliers)', 140000), 'debit': 0, 'credit': 140000},
    ],
    'total_debit': empty ? 0 : 1077000, 'total_credit': empty ? 0 : 1077000,
    'balanced': true, 'book': _book,
  };
}

