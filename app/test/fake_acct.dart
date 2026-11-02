// acctui: server-shaped responses for the accounting UI endpoints
// (backend/core/ledger_entry_views.py, prefix business/acct/). Numbers follow
// the same grocery fixture as fake_books.dart and are internally consistent
// (cash flow ties: opening + net change = closing; VAT output − input − paid
// = still due). Names arrive from the server in the request language; the
// fixture keeps English names.

const acctFakeBook = {
  'start_date': '2026-10-15', 'lock_date': '2026-10-31', 'last_sync_at': '2026-11-02T10:00:00+06:00',
  'opening_inventory': 665000, 'warning': null,
};

List<Map<String, dynamic>> _entries() => [
      {'id': 4, 'client_id': 'c4', 'kind': 'expense', 'amount': 50000, 'account': 'bkash',
        'category': '6010', 'date': '2026-11-02', 'note': 'November rent', 'by_name': 'Rahman'},
      {'id': 3, 'client_id': 'c3', 'kind': 'money_in', 'purpose': 'customer', 'amount': 10000,
        'account': 'nagad', 'party_name': 'Karim', 'party_id': 7, 'date': '2026-11-02', 'by_name': 'Rahman'},
      {'id': 2, 'client_id': 'c2', 'kind': 'sale', 'amount': 115000, 'vat': 15000, 'account': 'cash',
        'date': '2026-11-01', 'by_name': 'Rahman'},
      {'id': 1, 'client_id': 'c1', 'kind': 'due', 'amount': 30000, 'party_name': 'Rahim',
        'date': '2026-11-01', 'by_name': 'Rahman', 'void': {'at': '2026-11-01T12:00:00+06:00', 'reason': 'typo'}},
    ];

Map<String, dynamic> _opening(bool empty) => {
      'values': empty
          ? <String, dynamic>{}
          : {'cash': 500000, 'bank': 2000000, 'bkash': 150000, 'nagad': 0, 'receivable': 0, 'payable': 0},
      'set': !empty,
      'start_date': '2026-10-15',
      'lock_date': empty ? null : '2026-10-31',
      'locked': false,
      'stock_estimate': 665000,
      'stock_warning': null,
      'khata': {'receivable': 35000, 'payable': 140000},
      'shop': 'Rahman Store',
    };

Map<String, dynamic> _cashFlow(bool empty) => empty
    ? {
        'from': '2026-11-01', 'to': '2026-11-02', 'opening_cash': 0, 'opening_balances': 0,
        'operating': {'customers': 0, 'suppliers': 0, 'expenses': 0, 'vat': 0, 'other_income': 0,
          'other': 0, 'total': 0},
        'investing': {'total': 0}, 'financing': {'capital': 0, 'drawings': 0, 'loans': 0, 'total': 0},
        'net_change': 0, 'closing_cash': 0, 'balanced': true, 'book': acctFakeBook, 'shop': 'Rahman Store',
      }
    : {
        'from': '2026-11-01', 'to': '2026-11-02', 'opening_cash': 2650000, 'opening_balances': 0,
        'operating': {'customers': 225000, 'suppliers': -60000, 'expenses': -58000, 'vat': 0,
          'other_income': 0, 'other': 5000, 'total': 112000},
        'investing': {'total': 0},
        'financing': {'capital': 0, 'drawings': -20000, 'loans': 0, 'total': -20000},
        'net_change': 92000, 'closing_cash': 2742000, 'balanced': true, 'book': acctFakeBook,
        'shop': 'Rahman Store',
      };

Map<String, dynamic> _vat(bool empty) => {
      'from': '2026-11-01', 'to': '2026-11-02',
      'output_vat': empty ? 0 : 15000, 'input_vat': empty ? 0 : 6000,
      'net_payable': empty ? 0 : 9000, 'paid': empty ? 0 : 5000, 'still_due': empty ? 0 : 4000,
      'taxable_sales': empty ? 0 : 100000, 'taxable_purchases': empty ? 0 : 40000,
      'sale_invoices': empty ? 0 : 1, 'purchase_bills': empty ? 0 : 1,
      'book': acctFakeBook, 'shop': 'Rahman Store',
    };

Map<String, dynamic> _audit(bool empty) => {
      'entries': empty
          ? <Map<String, dynamic>>[]
          : [
              {'id': 15, 'number': 15, 'date': '2026-11-01', 'created_at': '2026-11-01T12:00:00+06:00',
                'status': 'reversal', 'source': 'acct', 'late': false,
                'memo': {'bn': 'Reversal of #14', 'en': 'Reversal of #14'}, 'total': 30000,
                'who': 'Rahman', 'reversal_of': 14, 'reversed_by': null,
                'lines': [
                  {'code': '4020', 'debit': 30000, 'credit': 0, 'name': {'bn': 'Sales — khata credit', 'en': 'Sales — khata credit'}, 'party': ''},
                  {'code': '1100', 'debit': 0, 'credit': 30000, 'name': {'bn': 'Accounts receivable', 'en': 'Accounts receivable'}, 'party': 'Rahim'},
                ]},
              {'id': 14, 'number': 14, 'date': '2026-11-01', 'created_at': '2026-11-01T11:00:00+06:00',
                'status': 'reversed', 'source': 'acct', 'late': false,
                'memo': {'bn': 'Sold on credit — Rahim', 'en': 'Sold on credit — Rahim'}, 'total': 30000,
                'who': 'Rahman', 'reversal_of': null, 'reversed_by': 15,
                'lines': [
                  {'code': '1100', 'debit': 30000, 'credit': 0, 'name': {'bn': 'Accounts receivable', 'en': 'Accounts receivable'}, 'party': 'Rahim'},
                  {'code': '4020', 'debit': 0, 'credit': 30000, 'name': {'bn': 'Sales — khata credit', 'en': 'Sales — khata credit'}, 'party': ''},
                ]},
              {'id': 9, 'number': 9, 'date': '2026-10-20', 'created_at': '2026-10-20T18:00:00+06:00',
                'status': 'posted', 'source': 'sale', 'late': true,
                'memo': {'bn': 'Shop sale #12', 'en': 'Shop sale #12'}, 'total': 100000,
                'who': 'Rahman', 'reversal_of': null, 'reversed_by': null,
                'lines': [
                  {'code': '1010', 'debit': 100000, 'credit': 0, 'name': {'bn': 'Cash in hand', 'en': 'Cash in hand'}, 'party': ''},
                  {'code': '4010', 'debit': 0, 'credit': 100000, 'name': {'bn': 'Sales — shop (POS)', 'en': 'Sales — shop (POS)'}, 'party': ''},
                ]},
            ],
      'events': empty
          ? <Map<String, dynamic>>[]
          : [
              {'action': 'acct.lock', 'at': '2026-11-01T09:00:00+06:00', 'who': 'Rahman',
                'detail': {'from': null, 'to': '2026-10-31', 'reason': ''}},
              {'action': 'acct.void', 'at': '2026-11-01T12:00:00+06:00', 'who': 'Rahman',
                'detail': {'client_id': 'c1', 'reason': 'typo'}},
              {'action': 'acct.export', 'at': '2026-11-02T08:00:00+06:00', 'who': 'Rahman',
                'detail': {'what': 'xlsx'}},
            ],
      'page': 1, 'has_more': false, 'book': acctFakeBook,
    };

Map<String, dynamic>? fakeAcctGet(String path, {bool empty = false}) {
  if (!path.startsWith('/business/acct/')) return null;
  final bare = path.split('?').first;
  switch (bare) {
    case '/business/acct/entries':
      return {'entries': empty ? <Map<String, dynamic>>[] : _entries(), 'has_more': false,
        'book': acctFakeBook, 'shop': 'Rahman Store'};
    case '/business/acct/opening':
      return _opening(empty);
    case '/business/acct/cash-flow':
      return _cashFlow(empty);
    case '/business/acct/vat':
      return _vat(empty);
    case '/business/acct/audit':
      return _audit(empty);
  }
  return const {};
}

/// Every POST answers like the server's success (with `_status`).
Map<String, dynamic>? fakeAcctPost(String path, Map<String, dynamic> body) {
  if (!path.startsWith('business/acct/') && !path.startsWith('/business/acct/')) return null;
  final p = path.startsWith('/') ? path.substring(1) : path;
  if (p == 'business/acct/entries') {
    return {'_status': 201, 'created': true, 'entry': {...body, 'id': 99}, 'book': acctFakeBook};
  }
  if (p.endsWith('/void')) return {'_status': 200, 'entry': {'void': {'at': 'now'}}};
  if (p == 'business/acct/opening') return {'_status': 200, ..._opening(false)};
  if (p == 'business/acct/lock') {
    return {'_status': 200, 'book': {...acctFakeBook, 'lock_date': body['lock_date']}};
  }
  return {'_status': 200, 'ok': true};
}
