// acctui: server-shaped responses for the accounting UI endpoints
// (backend/core/ledger_entry_views.py, prefix business/acct/). Numbers follow
// the same grocery fixture as fake_books.dart and are internally consistent
// (cash flow reconciles: opening + net change = closing; VAT output − input −
// paid = still due). Also the core's opening / cash-flow / vat shapes
// (backend/core/ledger/README.md) the accounting UI reads. Names arrive from the server in the request language; the
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

Map<String, dynamic> _hints(bool empty) => {
      'khata': {'receivable': 35000, 'payable': 140000},
      'start_date': '2026-10-15',
      'lock_date': empty ? null : '2026-10-31',
      'stock_estimate': 665000,
      'shop': 'Rahman Store',
    };

/// The CORE's opening (business/books/opening).
Map<String, dynamic> _coreOpening(bool empty) => {
      'opening': empty
          ? null
          : {'date': '2026-10-15', 'cash': 500000, 'bkash': 150000, 'nagad': 0, 'bank': 2000000,
              'inventory': null, 'receivables': <Map<String, dynamic>>[], 'payables': <Map<String, dynamic>>[],
              'loans': 0},
      'book': acctFakeBook,
    };

/// The CORE's cash flow (indirect): 370 profit ... ties 26,500 -> 27,420.
Map<String, dynamic> _cashFlow(bool empty) => empty
    ? {
        'from': '2026-11-01', 'to': '2026-11-02', 'net_profit': 0, 'adjustments': <Map<String, dynamic>>[],
        'operating': 0, 'investing': <Map<String, dynamic>>[], 'investing_total': 0,
        'financing': <Map<String, dynamic>>[], 'financing_total': 0, 'net_change': 0,
        'opening_cash': 0, 'closing_cash': 0, 'reconciles': true, 'book': acctFakeBook,
      }
    : {
        'from': '2026-11-01', 'to': '2026-11-02', 'net_profit': 37000,
        'adjustments': [
          {'key': 'receivables', 'name': "Customers' dues", 'amount': -20000},
          {'key': 'inventory', 'name': 'Stock', 'amount': 85000},
          {'key': 'payables', 'name': "Suppliers' dues", 'amount': 10000},
        ],
        'operating': 112000, 'investing': <Map<String, dynamic>>[], 'investing_total': 0,
        'financing': [
          {'code': '3020', 'name': "Owner's drawings", 'type': 'equity', 'group': 'equity', 'amount': -20000},
        ],
        'financing_total': -20000, 'net_change': 92000,
        'opening_cash': 2650000, 'closing_cash': 2742000, 'reconciles': true, 'book': acctFakeBook,
      };

/// The CORE's VAT (register from invoices).
Map<String, dynamic> _coreVat(bool empty) => {
      'output_vat': empty ? 0 : 15000, 'output_sd': 0, 'input_vat': 0,
      'net_payable': empty ? 0 : 15000, 'sales_taxable': empty ? 0 : 210000,
      'register': empty
          ? <Map<String, dynamic>>[]
          : [
              {'number': 'INV-0007', 'date': '2026-11-01', 'buyer': 'Karim Traders',
                'buyer_bin': '000123456-0101', 'taxable': 100000, 'sd': 0, 'vat': 15000,
                'total': 115000, 'source': 'invoice'},
            ],
      'vat_ready': true, 'vat_periods': <Map<String, dynamic>>[], 'book': acctFakeBook,
    };

Map<String, dynamic> _vat(bool empty) => {
      'from': '2026-11-01', 'to': '2026-11-02',
      'output_vat': empty ? 0 : 15000, 'output_sd': 0, 'input_vat': empty ? 0 : 6000,
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
                'memo': {'bn': 'উল্টো এন্ট্রি #14', 'en': 'Reversal of #14'}, 'total': 30000,
                'who': 'Rahman', 'reversal_of': 14, 'reversed_by': null,
                'lines': [
                  {'code': '4020', 'debit': 30000, 'credit': 0, 'name': {'bn': 'বিক্রি — খাতায় বাকি', 'en': 'Sales — khata credit'}, 'party': ''},
                  {'code': '1100', 'debit': 0, 'credit': 30000, 'name': {'bn': 'পাওনা (গ্রাহকের বাকি)', 'en': 'Accounts receivable'}, 'party': 'Rahim'},
                ]},
              {'id': 14, 'number': 14, 'date': '2026-11-01', 'created_at': '2026-11-01T11:00:00+06:00',
                'status': 'reversed', 'source': 'acct', 'late': false,
                'memo': {'bn': 'বাকিতে বিক্রি — রহিম', 'en': 'Sold on credit — Rahim'}, 'total': 30000,
                'who': 'Rahman', 'reversal_of': null, 'reversed_by': 15,
                'lines': [
                  {'code': '1100', 'debit': 30000, 'credit': 0, 'name': {'bn': 'পাওনা (গ্রাহকের বাকি)', 'en': 'Accounts receivable'}, 'party': 'Rahim'},
                  {'code': '4020', 'debit': 0, 'credit': 30000, 'name': {'bn': 'বিক্রি — খাতায় বাকি', 'en': 'Sales — khata credit'}, 'party': ''},
                ]},
              {'id': 9, 'number': 9, 'date': '2026-10-20', 'created_at': '2026-10-20T18:00:00+06:00',
                'status': 'posted', 'source': 'sale', 'late': true,
                'memo': {'bn': 'দোকানে বিক্রি #12', 'en': 'Shop sale #12'}, 'total': 100000,
                'who': 'Rahman', 'reversal_of': null, 'reversed_by': null,
                'lines': [
                  {'code': '1010', 'debit': 100000, 'credit': 0, 'name': {'bn': 'হাতে নগদ', 'en': 'Cash in hand'}, 'party': ''},
                  {'code': '4010', 'debit': 0, 'credit': 100000, 'name': {'bn': 'বিক্রি — দোকান', 'en': 'Sales — shop (POS)'}, 'party': ''},
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
  final bare = path.split('?').first;
  switch (bare) {
    case '/business/books/opening':
      return _coreOpening(empty);
    case '/business/books/cash-flow':
      return _cashFlow(empty);
    case '/business/books/vat':
      return _coreVat(empty);
  }
  if (!path.startsWith('/business/acct/')) return null;
  switch (bare) {
    case '/business/acct/entries':
      return {'entries': empty ? <Map<String, dynamic>>[] : _entries(), 'has_more': false,
        'book': acctFakeBook, 'shop': 'Rahman Store'};
    case '/business/acct/hints':
      return _hints(empty);
    case '/business/acct/vat':
      return _vat(empty);
    case '/business/acct/audit':
      return _audit(empty);
  }
  return const {};
}

/// Every POST answers like the server's success (with `_status`).
Map<String, dynamic>? fakeAcctPost(String path, Map<String, dynamic> body) {
  final p = path.startsWith('/') ? path.substring(1) : path;
  if (p == 'business/books/opening') {
    return {'_status': 200, 'opening': body, 'book': acctFakeBook};
  }
  if (!p.startsWith('business/acct/')) return null;
  if (p == 'business/acct/entries') {
    return {'_status': 201, 'created': true, 'entry': {...body, 'id': 99}, 'book': acctFakeBook};
  }
  if (p.endsWith('/void')) return {'_status': 200, 'entry': {'void': {'at': 'now'}}};
  if (p == 'business/acct/lock') {
    return {'_status': 200, 'book': {...acctFakeBook, 'lock_date': body['lock_date']}};
  }
  return {'_status': 200, 'ok': true};
}
