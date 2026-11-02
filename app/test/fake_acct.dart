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

/// The CORE's VAT (ledger2: four separate lines — output / input / paid /
/// payable — plus the sales register (6.2) and purchase register (6.1)).
Map<String, dynamic> _coreVat(bool empty) => {
      ..._vat(empty),
      'sales_taxable': empty ? 0 : 100000,
      'exempt_sales': empty ? 0 : 23000,
      'register': empty
          ? <Map<String, dynamic>>[]
          : [
              {'number': 'INV-0007', 'date': '2026-11-01', 'buyer': 'Karim Traders',
                'buyer_bin': '000123456-0101', 'taxable': 100000, 'sd': 0, 'vat': 15000,
                'total': 115000, 'exempt': 0, 'source': 'invoice'},
            ],
      'purchase_register': empty
          ? <Map<String, dynamic>>[]
          : [
              {'date': '2026-11-01', 'supplier': 'Akij Foods', 'supplier_bin': '000999888-0101',
                'bill_no': 'CH-77', 'value': 40000, 'vat': 6000, 'total': 46000, 'on_credit': true},
            ],
      'vat_ready': true, 'vat_periods': <Map<String, dynamic>>[], 'book': acctFakeBook,
    };

// ---- ledger2 -------------------------------------------------------------
Map<String, dynamic> _name(String bn, String en) => {'bn': bn, 'en': en};

Map<String, dynamic> _cashbox(bool empty) => {
      'rows': empty
          ? <Map<String, dynamic>>[]
          : [
              {'id': 31, 'date': '2026-11-02', 'kind': 'in', 'amount': 5000, 'note': 'change from bank',
                'code': '', 'name': null},
              {'id': 30, 'date': '2026-11-01', 'kind': 'out', 'amount': 12000, 'note': 'tea for staff',
                'code': '', 'name': null},
              {'id': 29, 'date': '2026-10-30', 'kind': 'out', 'amount': 20000, 'note': 'took home',
                'code': '3020', 'name': _name('মালিকের উত্তোলন', "Owner's drawings")},
            ],
      'unclassified': empty ? 0 : 2,
      'unclassified_amount': empty ? 0 : 17000,
      'choices': {
        'in': [
          {'code': '4010', 'name': _name('বিক্রি — দোকান', 'Sales — shop (POS)')},
          {'code': '4100', 'name': _name('অন্যান্য আয়', 'Other income')},
          {'code': '3010', 'name': _name('মালিকের মূলধন', "Owner's capital")},
          {'code': '2300', 'name': _name('ঋণ', 'Loans payable')},
        ],
        'out': [
          {'code': '6010', 'name': _name('দোকান ভাড়া', 'Rent')},
          {'code': '6100', 'name': _name('আপ্যায়ন ও খাবার', 'Food & entertainment')},
          {'code': '6900', 'name': _name('অন্যান্য খরচ', 'Other expenses')},
          {'code': '1200', 'name': _name('মজুদ মাল', 'Inventory (stock)')},
          {'code': '3020', 'name': _name('মালিকের উত্তোলন', "Owner's drawings")},
        ],
      },
      'book': acctFakeBook,
    };

Map<String, dynamic> _vatRates(bool empty) => {
      'shop_vat_bp': empty ? 0 : 1500, 'shop_sd_bp': 0, 'vat_seller': !empty,
      'custom': empty ? 0 : 2,
      'products': empty
          ? <Map<String, dynamic>>[]
          : [
              {'product_id': 1, 'name': 'Rice (miniket)', 'category': 'Grocery', 'mode': 'exempt',
                'vat_bp': 0, 'note': 'First Schedule', 'since': '2026-11-01'},
              {'product_id': 2, 'name': 'Soybean oil 1L', 'category': 'Grocery', 'mode': 'reduced',
                'vat_bp': 500, 'note': 'Third Schedule', 'since': '2026-11-01'},
              {'product_id': 3, 'name': 'Biscuits', 'category': 'Snacks', 'mode': 'standard',
                'vat_bp': null, 'note': '', 'since': null},
            ],
    };

Map<String, dynamic> _yearClose(bool empty) => {
      'closes': empty
          ? <Map<String, dynamic>>[]
          : [
              {'end': '2025-12-31', 'number': 40, 'status': 'posted', 'total': 3700000,
                'memo': _name('বছর শেষে লাভ', 'Year-end close')},
            ],
      'suggestions': [
        {'end': '2026-06-30', 'kind': 'tax'},
        if (empty) {'end': '2025-12-31', 'kind': 'calendar'},
      ],
      'book': acctFakeBook,
    };

Map<String, dynamic> _costGaps(bool empty) => {
      'sales': empty ? 0 : 3, 'lines': empty ? 0 : 4, 'revenue': empty ? 0 : 64000,
      'products': empty
          ? <Map<String, dynamic>>[]
          : [
              {'product_id': 2, 'name': 'Soybean oil 1L', 'lines': 3, 'qty': 3, 'revenue': 54000,
                'current_cost': 15000, 'last_sold': '2026-11-01'},
              {'product_id': 3, 'name': 'Biscuits', 'lines': 1, 'qty': 1, 'revenue': 10000,
                'current_cost': 0, 'last_sold': '2026-11-02'},
            ],
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
    case '/business/acct/cashbox':
      return _cashbox(empty);
    case '/business/acct/vat-rates':
      return _vatRates(empty);
    case '/business/acct/year-close':
      return _yearClose(empty);
    case '/business/acct/cost-gaps':
      return _costGaps(empty);
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
  if (p.endsWith('/classify')) return {'_status': 200, 'code': body['code'], 'book': acctFakeBook};
  if (p == 'business/acct/vat-rates') {
    return {'_status': 200, 'product_id': body['product_id'], 'mode': body['mode'],
      'vat_bp': body['vat_bp'], 'since': '2026-11-02'};
  }
  if (p == 'business/acct/year-close') {
    return {'_status': 201, 'end': body['end'], 'number': 41, 'profit': 3700000,
      'lock_date': body['end'], 'book': acctFakeBook};
  }
  if (p == 'business/acct/year-reopen') {
    return {'_status': 200, 'end': body['end'], 'lock_date': null, 'book': acctFakeBook};
  }
  if (p == 'business/acct/cost-gaps/apply') {
    return {'_status': 200, 'product_id': body['product_id'], 'fixed': 3, 'skipped_locked': 0};
  }
  return {'_status': 200, 'ok': true};
}
