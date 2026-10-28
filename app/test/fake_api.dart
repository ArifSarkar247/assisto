import 'fake_famcare.dart'; // famcare
import 'fake_kidswatch.dart'; // kidswatch
import 'package:assisto/api.dart';
import 'package:assisto/business_selling_api.dart';
import 'package:assisto/models.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';

import 'fake_c1_contacts.dart';
import 'fake_c3_msg.dart';
import 'mr1_shots.dart' show fakeMr1Get;
import 'md1_shots.dart' show fakeMd1Get;
import 'fake_m3_circle.dart';
import 'fake_discover.dart';
import 'fake_vehicle.dart';
import 'fake_khata.dart'; // ledger100
import 'p1_bizagent_fakes.dart'; // p1-bizagent
import 'fake_crm100.dart'; // crm100
import 'at100_fakes.dart'; // at100

enum FakeMode { data, empty, fail, slow }

/// Returns realistic sample data so every screen renders populated (or empty,
/// or in an error state) in the screenshot harness — no network.
class FakeApi extends ApiClient {
  final FakeMode mode;
  final String lang;
  FakeApi({this.mode = FakeMode.data, this.lang = 'bn'}) {
    token = 'preview-token';
  }

  bool get _bn => lang == 'bn';

  /// The plan slug [plan] reports. The gallery sets 'business' for the Shop Box
  /// shots (Business-only UI) and resets it to 'premium' for everything else.
  static String planSlug = 'premium';

  /// pay1 + NO SHOWPIECES: whether a payment channel is LIVE in
  /// /payments/config (the gallery sets it for the `*_paylive` shots).
  static bool payLive = false;

  /// credout: also list a LIVE Google Play channel (Play-build tests) with
  /// the real Play ids: assisto_premium / assisto_business on base plans
  /// monthly | annual, and the credits_p20.. one-time packs.
  static bool playLive = false;

  /// pay-e2e: skus /payments/config leaves out (e.g. 'business_yearly').
  static Set<String> payOmit = {};

  /// dl1: whether /account/delete/status reports a PENDING deletion (the
  /// gallery sets it for the `dl1_*pending*` / grace shots).
  static bool delPending = false;

  Map<String, dynamic> _payProduct(String sku, int price,
          {String kind = 'sub', int credits = 0}) =>
      {
        'sku': sku, 'kind': kind, 'plan': sku.split('_').first,
        'period': sku.endsWith('yearly') ? 'yearly' : 'monthly',
        'months': sku.endsWith('yearly') ? 12 : 1, 'credits': credits,
        'price_bdt': price, 'title': kind == 'sub' ? 'Premium' : '$credits',
        'play_product_id': '', 'play_base_plan': '',
      };

  static const _packs = [
    {'id': 'p20', 'taka': 20, 'credits': 20, 'valid_months': 12},
    {'id': 'p50', 'taka': 50, 'credits': 55, 'valid_months': 12},
    {'id': 'p100', 'taka': 100, 'credits': 115, 'valid_months': 12},
  ];

  @override
  Future<List<Map<String, dynamic>>> creditsPacks() async {
    await _slow();
    if (mode == FakeMode.fail) _fail();
    // mirrors the server: purchasable=false -> the client gets no packs
    return payLive && mode != FakeMode.empty
        ? [for (final p in _packs) Map<String, dynamic>.from(p)]
        : const [];
  }

  /// truth: GET /nearby — REAL-shaped rows (the server's live Places/OSM
  /// layer) with the licence line; empty mode = nothing nearby; fail = down.
  @override
  Future<Map<String, dynamic>> nearby(double lat, double lon, String type) async {
    await _slow();
    if (mode == FakeMode.fail) _fail();
    final rows = mode == FakeMode.empty
        ? const <Map<String, dynamic>>[]
        : [
            {'name': 'Dhaka Medical College Hospital', 'address': 'Secretariat Road',
             'distance_m': 850, 'open_now': null, 'rating': null, 'phone': null,
             'lat': lat + 0.006, 'lon': lon + 0.002, 'maps': 'https://maps'},
            {'name': 'Square Hospital', 'address': 'Panthapath',
             'distance_m': 2100, 'open_now': null, 'rating': null, 'phone': '10616',
             'lat': lat + 0.015, 'lon': lon - 0.012, 'maps': 'https://maps'},
          ];
    return {'type': type, 'source': 'osm', 'places': rows,
            'attribution': '\u00a9 OpenStreetMap contributors (ODbL)'};
  }

  Map<String, dynamic>? _pay1Get(String path) {
    if (path.startsWith('/payments/config')) {
      final prods = [
        for (final sku in ['premium_monthly', 'premium_yearly',
            'business_monthly', 'business_yearly'])
          if (!payOmit.contains(sku))
            _payProduct(sku, sku == 'business_yearly'
                ? 5808
                : sku.startsWith('premium') ? 199 : 499),
        for (final p in _packs)
          _payProduct('pack_${p['id']}', p['taka'] as int,
              kind: 'pack', credits: p['credits'] as int),
      ];
      Map<String, dynamic> playOf(Map<String, dynamic> p) {
        final sku = '${p['sku']}';
        if (sku.startsWith('pack_')) {
          return {...p, 'play_product_id': 'credits_${sku.substring(5)}'};
        }
        return {
          ...p,
          'play_product_id': 'assisto_${sku.split('_').first}',
          'play_base_plan': sku.endsWith('yearly') ? 'annual' : 'monthly',
        };
      }
      return {
        'channels': [
          if (playLive)
            {'id': 'play', 'enabled': true, 'ready': true, 'label': 'Google Play'},
          {'id': 'gateway', 'enabled': payLive, 'ready': payLive,
            'label': 'bKash / Nagad / Card — EPS'},
        ],
        'products': {
          'gateway': prods,
          if (playLive) 'play': [for (final p in prods) playOf(p)],
        },
        'play_account_id': playLive ? 'u7-abc' : '',
      };
    }
    if (path == '/payments/state') return {'plan': planSlug};
    if (path == '/me/usage-summary') {
      return {
        'plan': planSlug, 'balance': 312, 'included_pool': 120,
        'ad_wallet_credits': 0, 'month_total': 48,
        'month_usage': [
          {'action': 'ai_msg_cheap', 'credits': 30}, // the server's real code
          {'action': 'photo_enhance', 'credits': 18},
        ],
        'storage': {'used': 1200000000, 'quota_bytes': 5368709120},
      };
    }
    if (path.startsWith('/credits/history')) {
      // billapp: the real paged ledger shape (newest first)
      return {
        'ledger': [
          {'id': 3, 'delta': -1, 'reason': 'consume', 'note': 'ai_msg_cheap', 'bucket': 'plan',
            'at': '2026-10-27T09:10:00+00:00', 'balance_after': 17},
          {'id': 2, 'delta': 18, 'reason': 'grant', 'note': '', 'bucket': 'plan',
            'at': '2026-10-27T08:00:00+00:00', 'balance_after': 18},
          {'id': 1, 'delta': 20, 'reason': 'topup', 'note': '', 'bucket': 'pack',
            'at': '2026-10-20T08:00:00+00:00', 'balance_after': 20},
        ],
        'next_offset': null, 'total': 3, 'expiry_buckets': const [],
      };
    }
    if (path == '/credits/refunds') {
      // billapp: one eligible purchase (server suggestion), one past the
      // window, and a decided request with the owner's note
      final now = DateTime.now().toUtc();
      return {
        'window_hours': 48,
        'policy': {'window_hours': 48, 'url': '/refund-policy',
          'text': _bn
              ? 'কেনা বা নবায়নের 48 ঘণ্টার মধ্যে অ্যাপ থেকে রিফান্ড চাওয়া যায়। শুধু অব্যবহৃত অংশ ফেরত হয়।'
              : 'You can ask for a refund in the app within 48 hours of a purchase or renewal. Only the unused part is refunded.'},
        'purchases': [
          {'id': 12, 'channel': 'play', 'order_ref': '00012', 'sku': 'premium_monthly', 'kind': 'sub',
            'plan': 'premium', 'price': '199.00', 'currency': 'BDT', 'test': true,
            'purchased_at': now.subtract(const Duration(hours: 3)).toIso8601String(),
            'window_ends_at': now.add(const Duration(hours: 45)).toIso8601String(),
            'eligible': true, 'reason': '', 'suggested': '179.10', 'request': null,
            'usage': {'credits_planned': 90, 'credits_used': 9, 'days_total': 30.0, 'days_used': 0.1}},
          {'id': 9, 'channel': 'play', 'order_ref': '00009', 'sku': 'pack_p50', 'kind': 'pack',
            'plan': '', 'price': '50.00', 'currency': 'BDT', 'test': false,
            'purchased_at': now.subtract(const Duration(days: 5)).toIso8601String(),
            'eligible': false, 'reason': 'already_requested', 'suggested': null},
        ],
        'requests': [
          {'id': 3, 'status': 'rejected', 'order': 9,
            'requested_at': now.subtract(const Duration(days: 4)).toIso8601String(),
            'note': _bn ? 'প্যাকের বেশিরভাগ ক্রেডিট ব্যবহার হয়েছে' : 'Most of the pack was used',
            'approved_amount': '0.00'},
        ],
      };
    }
    if (path == '/credits/state') {
      // billapp: 18 usable now, 72 locked (opens in 2 days), a pack
      final now = DateTime.now().toUtc();
      return {
        'balance': 38, 'now_usable': 38, 'locked': 72,
        'unlocks_at': now.add(const Duration(hours: 47)).toIso8601String(),
        'negative': false, 'blocked': false, 'purchase_blocked': false, 'debt': 0,
        'buckets': {'plan': 18, 'pack': 20},
        'bucket_detail': [
          {'bucket': 'plan', 'remaining': 18, 'locked': 72,
            'expires_at': now.add(const Duration(days: 30)).toIso8601String(),
            'unlocks_at': now.add(const Duration(hours: 47)).toIso8601String()},
          {'bucket': 'pack', 'remaining': 20, 'locked': 0, 'expires_at': null, 'unlocks_at': null},
        ],
        'plan_expires_at': now.add(const Duration(days: 30)).toIso8601String(),
        'unlock_pct': 20, 'unlock_hours': 48, 'refund_window_hours': 48,
        'action_costs': {'ai_msg_cheap': 1, 'ai_msg_medium': 3, 'scan_ocr': 2,
          'photo_generate': 9, 'retention_in_app': 0},
        'withdrawable': false,
        'server_time': now.toIso8601String(),
      };
    }
    return null;
  }
  Never _fail() => throw ApiException(
      _bn ? 'সংযোগ করা গেল না' : 'Could not connect', 503);
  List<Map<String, dynamic>> _maybe(List<Map<String, dynamic>> data) {
    if (mode == FakeMode.fail) _fail();
    return mode == FakeMode.empty ? [] : data;
  }

  Future<void> _slow() async {
    if (mode == FakeMode.slow) {
      await Future.delayed(const Duration(milliseconds: 1200)); // stay loading during capture
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async {
    await _slow();
    if (path.startsWith('crm/')) return _crmList(path);
    // a2-cctv QA batch 3: seeded rows so arg-order fixes are visible on screen
    if (path == 'spending/notes') {
      final b = _bn;
      return _maybe([
        {'id': 1, 'category': b ? 'খাবার' : 'Food', 'amount': 9000, 'budget': 8000, 'previous': 6000},
        {'id': 2, 'category': b ? 'যাতায়াত' : 'Transport', 'amount': 2500, 'budget': 4000, 'previous': 3000},
        {'id': 3, 'category': b ? 'বিল' : 'Bills', 'amount': 1500, 'previous': 1500},
      ]);
    }
    if (path == 'rent_units' || path == 'rent_payments') {
      final now = DateTime.now();
      final m = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      // 3 paid, 2 partial, 1 due: distinct counts make a swap visible
      if (path == 'rent_units') {
        return _maybe([
          for (var i = 1; i <= 6; i++)
            {'id': i, 'label': '${_bn ? 'ফ্ল্যাট' : 'Flat'} ${i}A', 'tenant_name': _bn ? 'ভাড়াটিয়া $i' : 'Tenant $i', 'rent_poisha': 1500000, 'active': true},
        ]);
      }
      return _maybe([
        for (var i = 1; i <= 3; i++) {'id': i, 'unit_id': i, 'month': m, 'paid_poisha': 1500000},
        {'id': 4, 'unit_id': 4, 'month': m, 'paid_poisha': 500000},
        {'id': 5, 'unit_id': 5, 'month': m, 'paid_poisha': 1000000},
      ]);
    }
    // remmeter: prepaid meters (company, meter no, estimate, token log)
    if (path == 'meter/meters' || path == 'meter/recharges') {
      final today = DateTime.now();
      String d(int ago) => today
          .subtract(Duration(days: ago))
          .toIso8601String()
          .split('T')
          .first;
      if (path == 'meter/meters') {
        return _maybe([
          {'id': 1, 'name': _bn ? 'বাসার মিটার' : 'Home meter', 'kind': 'electricity',
           'utility': 'desco', 'meter_no': '04123456789', 'balance': '180',
           'balance_date': d(0), 'daily_use': '60', 'alert_days': 3, 'alerts': true},
          {'id': 2, 'name': _bn ? 'দোকান' : 'Shop', 'kind': 'electricity',
           'utility': 'breb', 'meter_no': '98765432', 'alert_days': 3, 'alerts': true},
          {'id': 3, 'name': _bn ? 'রান্নাঘরের গ্যাস' : 'Kitchen gas', 'kind': 'gas',
           'utility': 'titas', 'alerts': false},
        ]);
      }
      return _maybe([
        {'id': 11, 'meter': 2, 'amount': '1000', 'date': d(40), 'channel': 'bkash'},
        {'id': 12, 'meter': 2, 'amount': '1000', 'date': d(10), 'channel': 'nagad',
         'token': '12345678901234567890'},
        {'id': 13, 'meter': 3, 'amount': '1500', 'date': d(5)},
      ]);
    }
    switch (path) {
      case 'subscriptions':
        return _maybe([
          {'id': 1, 'name': 'Netflix', 'amount': '500', 'cycle': 'monthly', 'next_due': '2026-10-20'},
          {'id': 2, 'name': _bn ? 'ইন্টারনেট' : 'Internet', 'amount': '1200', 'cycle': 'monthly', 'next_due': '2026-10-25'},
          {'id': 3, 'name': _bn ? 'জিম' : 'Gym', 'amount': '9000', 'cycle': 'yearly', 'next_due': '2027-01-01'},
        ]);
      case 'accounts':
        return _maybe([
          {'id': 1, 'name': _bn ? 'ক্যাশ' : 'Cash', 'acc_type': 'cash', 'balance': '12500'},
          {'id': 2, 'name': 'bKash', 'acc_type': 'mobile', 'balance': '8300'},
        ]);
      case 'transactions':
        return _maybe([
          {'id': 1, 'kind': 'expense', 'amount': '500', 'category': _bn ? 'খাবার' : 'Food', 'date': '2026-10-12', 'source': 'ai'},
          {'id': 2, 'kind': 'income', 'amount': '25000', 'category': _bn ? 'বেতন' : 'Salary', 'date': '2026-10-01', 'source': 'manual'},
          {'id': 3, 'kind': 'expense', 'amount': '1200', 'category': _bn ? 'যাতায়াত' : 'Transport', 'date': '2026-10-10', 'source': 'manual'},
        ]);
      case 'budgets':
        return _maybe([
          {'id': 1, 'category': _bn ? 'খাবার' : 'Food', 'limit': '8000', 'spent': '6400'},
          {'id': 2, 'category': _bn ? 'যাতায়াত' : 'Transport', 'limit': '3000', 'spent': '3100'},
        ]);
      case 'loans':
        return _maybe([
          {'id': 1, 'kind': 'given', 'person': _bn ? 'রহিম' : 'Rahim', 'amount': '2000'},
          {'id': 2, 'kind': 'taken', 'person': _bn ? 'করিম' : 'Karim', 'amount': '5000'},
        ]);
      case 'goals':
        return _maybe([
          {'id': 1, 'name': _bn ? 'হজ্জ সঞ্চয়' : 'Hajj savings', 'target': '300000', 'saved': '120000'},
        ]);
      case 'family':
        return _maybe([
          // famcare: Mother was picked from My Circle (gets the SOS); Father
          // was typed by hand (honest "not in My Circle" chip).
          {'id': 1, 'name': _bn ? 'আম্মা' : 'Mother', 'relation': 'mother', 'phone': '01710000000', 'circle_member': 1, 'in_circle': true},
          {'id': 2, 'name': _bn ? 'আব্বা' : 'Father', 'relation': 'father', 'phone': '01720000000', 'circle_member': null, 'in_circle': false},
        ]);
      case 'medicines':
        return _maybe([
          {'id': 1, 'name': 'Napa', 'dosage': _bn ? '১টা' : '1 tab', 'times': ['08:00', '20:00'], 'refill_date': '2026-10-30', 'food_relation': 'after', 'as_needed': false, 'dose_qty': '1', 'stock_count': '6', 'days_left': 3, 'refill_status': 'soon', 'predicted_refill': '2026-10-16', 'adherence_30d': 92},
          {'id': 2, 'name': 'Losectil', 'dosage': _bn ? '১টা' : '1 tab', 'times': ['08:00'], 'refill_date': null, 'food_relation': 'before', 'as_needed': false, 'dose_qty': '1', 'stock_count': '40', 'days_left': 40, 'refill_status': 'ok', 'predicted_refill': '2026-11-22', 'adherence_30d': 78},
          {'id': 3, 'name': 'Sleeping aid', 'dosage': _bn ? 'প্রয়োজনে' : 'as needed', 'times': [], 'as_needed': true, 'prn_per_day': 0, 'dose_qty': '1', 'stock_count': null, 'days_left': null, 'refill_status': 'ok', 'predicted_refill': null, 'adherence_30d': 100},
        ]);
      case 'doctors':
        return _maybe([
          {'id': 1, 'name': _bn ? 'ডা. রহমান' : 'Dr Rahman', 'specialty': _bn ? 'মেডিসিন' : 'Medicine', 'hospital': _bn ? 'স্কয়ার হাসপাতাল' : 'Square Hospital', 'phone': '01710000000'},
        ]);
      case 'prescriptions':
        return _maybe([
          {'id': 1, 'doctor': 1, 'doctor_display': _bn ? 'ডা. রহমান' : 'Dr Rahman', 'member': 1, 'date': '2026-10-05', 'diagnosis': _bn ? 'উচ্চ রক্তচাপ' : 'Hypertension', 'meds': [{'name': 'Amlodipine 5mg'}, {'name': 'Napa'}]},
          {'id': 2, 'doctor': 1, 'doctor_display': _bn ? 'ডা. রহমান' : 'Dr Rahman', 'member': null, 'date': '2026-09-20', 'diagnosis': _bn ? 'গ্যাস্ট্রিক' : 'Gastric', 'meds': [{'name': 'Losectil'}]},
        ]);
      case 'school':
        return _maybe([
          // famcare: the server's real shape (kind / date / amount / done)
          {'id': 1, 'title': _bn ? 'স্কুল ফি' : 'School fee', 'child_name': _bn ? 'রাফি' : 'Rafi', 'kind': 'fee', 'date': '2026-11-10', 'amount': '2500.00', 'done': false},
          {'id': 2, 'title': _bn ? 'অর্ধবার্ষিক পরীক্ষা' : 'Half-yearly exam', 'child_name': _bn ? 'রাফি' : 'Rafi', 'kind': 'exam', 'date': '2026-11-20', 'amount': null, 'done': false},
        ]);
      case 'reminders':
        return _maybe([
          {'id': 1, 'title': _bn ? 'বিদ্যুৎ বিল' : 'Electricity bill', 'due_at': '2026-11-05T10:00:00', 'done': false,
           'recurrence': 'monthly', 'date_only': false,
           'recurrence_rule': {'freq': 'monthly', 'interval': 1, 'day_of_month': 5, 'tod': '10:00'},
           'link': {'type': 'subscription', 'id': 2, 'label': _bn ? 'ইন্টারনেট' : 'Internet'}},
          {'id': 2, 'title': _bn ? 'ওষুধ খাও' : 'Take medicine', 'due_at': '2026-10-13T08:00:00', 'done': false,
           'recurrence': 'daily', 'date_only': false,
           'recurrence_rule': {'freq': 'daily', 'interval': 1, 'tod': '08:00'}, 'link': {}},
          {'id': 3, 'title': _bn ? 'জন্মদিন' : 'Birthday', 'due_at': '2026-12-01T00:00:00', 'done': false,
           'recurrence': 'yearly', 'date_only': true,
           'recurrence_rule': {'freq': 'yearly', 'interval': 1}, 'link': {}},
        ]);
      case 'notes':
        return _maybe([
          {'id': 1, 'title': _bn ? 'বাজারের লিস্ট' : 'Market list', 'body': _bn ? 'চাল, ডাল, তেল' : 'Rice, lentils, oil', 'pinned': true},
        ]);
      case 'todos':
        return _maybe([
          {'id': 1, 'title': _bn ? 'পাসপোর্ট রিনিউ' : 'Renew passport', 'done': false, 'due_at': null},
        ]);
      case 'watchers':
        return _maybe([
          {'id': 1, 'kind': 'usd_bdt', 'label': _bn ? 'USD/BDT রেট' : 'USD/BDT rate', 'last_value': '122.80'},
          {'id': 2, 'kind': 'rss', 'label': _bn ? 'সরকারি job circular' : 'Govt job circular', 'last_value': ''},
        ]);
      case 'jobs':
        return _maybe([
          {'id': 1, 'title': 'Flutter Developer', 'company': 'TechBD', 'match_score': 82, 'match_reason': _bn ? 'ভালো মিল: flutter, dart, api' : 'Good match: flutter, dart, api', 'status': 'matched'},
          {'id': 2, 'title': 'Backend Engineer', 'company': 'Shop365', 'match_score': 48, 'match_reason': _bn ? 'আংশিক মিল: python' : 'Partial match: python', 'status': 'matched'},
        ]);
      case 'nominees':
        return _maybe([
          {'id': 1, 'name': _bn ? 'ছেলে' : 'Son', 'contact': '01711111111', 'scope': 'emergency', 'activated': false},
        ]);
      case 'contacts':
        return _maybe([
          {'id': 1, 'name': _bn ? 'করিম সাহেব' : 'Mr Karim', 'phone': '01712345678', 'org': 'ABC Ltd', 'note': _bn ? 'আগামী সপ্তাহে কল' : 'Call next week'},
        ]);
      case 'products':
        return _maybe([
          {'id': 1, 'name': _bn ? 'পাঞ্জাবি' : 'Panjabi', 'price': '1200', 'stock': 8},
          {'id': 2, 'name': _bn ? 'শাড়ি' : 'Saree', 'price': '2500', 'stock': 0},
        ]);
      case 'orders':
        return _maybe([
          {'id': 101, 'total': '1200', 'status': 'new', 'customer_phone': '0171...'},
        ]);
      case 'appointments':
        return _maybe([
          {'title': _bn ? 'ডাক্তারের অ্যাপয়েন্টমেন্ট' : 'Doctor appointment',
           'start': '2099-01-01T10:00:00', 'duration_min': 30,
           'place': _bn ? 'ল্যাবএইড' : 'Labaid', 'note': ''},
        ]);
      // Payment / auto-pay LADDER (SPEC §21). Money is INTEGER POISHA. Each row
      // carries its debt fields + a nested escalating `ladder` (steps keyed by
      // offset_days from the due date; negative = before due, for payable
      // heads-ups). No auto_charge/auto_pay actions — the engine never charges.
      case 'ladder-receivable':
        return _maybe([
          {
            'id': 1, 'kind': 'receivable',
            'party': _bn ? 'রহিম স্টোর' : 'Rahim Store',
            'amount_poisha': 600000, 'paid_poisha': 200000,  // ৳6000, ৳2000 paid
            'due_date': '2026-10-10', 'recurring_days': 0, 'paused': false,
            'ladder': {
              'stop_on_payment': true, 'has_payment_key': false,
              'steps': [
                {'offset_days': 0, 'action': 'remind_gentle', 'channel': 'in_app'},
                {'offset_days': 3, 'action': 'remind_firm', 'channel': 'whatsapp_share'},
                {'offset_days': 7, 'action': 'final_notice', 'channel': 'sms'},
                {'offset_days': 14, 'action': 'escalate_owner', 'channel': 'in_app'},
              ],
            },
          },
          {
            'id': 2, 'kind': 'receivable',
            'party': _bn ? 'করিম ভাই' : 'Karim Bhai',
            'amount_poisha': 150000, 'paid_poisha': 0,  // ৳1500
            'due_date': '2026-10-25', 'recurring_days': 0, 'paused': false,
            'ladder': {
              'stop_on_payment': true, 'has_payment_key': false,
              'steps': [
                {'offset_days': 0, 'action': 'remind_gentle', 'channel': 'in_app'},
                {'offset_days': 5, 'action': 'remind_firm', 'channel': 'whatsapp_share'},
              ],
            },
          },
        ]);
      case 'ladder-payable':
        return _maybe([
          {
            'id': 3, 'kind': 'payable',
            'party': _bn ? 'বিদ্যুৎ বিল' : 'Electricity bill',
            'amount_poisha': 128000, 'paid_poisha': 0,  // ৳1280
            'due_date': '2026-10-20', 'recurring_days': 30, 'paused': false,
            'ladder': {
              'stop_on_payment': true, 'has_payment_key': false,
              'steps': [
                {'offset_days': -3, 'action': 'remind_gentle', 'channel': 'in_app'},
                {'offset_days': 0, 'action': 'pay_manual', 'channel': 'in_app'},
                {'offset_days': 3, 'action': 'remind_firm', 'channel': 'sms'},
              ],
            },
          },
          {
            'id': 4, 'kind': 'payable',
            'party': _bn ? 'বাইক EMI' : 'Bike EMI',
            'amount_poisha': 850000, 'paid_poisha': 0,  // ৳8500
            'due_date': '2026-11-05', 'recurring_days': 30, 'paused': true,
            'ladder': {
              'stop_on_payment': true, 'has_payment_key': true,
              'steps': [
                {'offset_days': -2, 'action': 'remind_gentle', 'channel': 'in_app'},
                {'offset_days': 0, 'action': 'pay_key', 'channel': 'in_app'},
              ],
            },
          },
        ]);
      default:
        return _maybe([]);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> medicinesToday() async => _maybe([
        {'medicine_id': 1, 'name': 'Napa', 'slot': '08:00', 'taken': true, 'skipped': false, 'prn': false, 'dosage': _bn ? '১টা' : '1 tab', 'food_relation': 'after', 'member_name': _bn ? 'আম্মা' : 'Mother', 'days_left': 3, 'refill_date': '2026-10-30'},
        {'medicine_id': 1, 'name': 'Napa', 'slot': '20:00', 'taken': false, 'skipped': false, 'prn': false, 'dosage': _bn ? '১টা' : '1 tab', 'food_relation': 'after', 'member_name': _bn ? 'আম্মা' : 'Mother', 'days_left': 3, 'refill_date': '2026-10-30'},
        {'medicine_id': 2, 'name': 'Losectil', 'slot': '08:00', 'taken': false, 'skipped': false, 'prn': false, 'dosage': _bn ? '১টা' : '1 tab', 'food_relation': 'before', 'member_name': null, 'days_left': 40, 'refill_date': null},
        // PRN: one already-logged event today + the open 'log another' row (P4).
        {'medicine_id': 3, 'name': 'Sleeping aid', 'slot': 'prn-14:30:00', 'taken': true, 'skipped': false, 'prn': true, 'prn_at': '14:30:00', 'prn_count_today': 1, 'dosage': _bn ? '১টা' : '1 tab', 'food_relation': 'any', 'member_name': null, 'days_left': null, 'refill_date': null},
        {'medicine_id': 3, 'name': 'Sleeping aid', 'slot': 'prn', 'taken': false, 'skipped': false, 'prn': true, 'prn_at': '', 'prn_count_today': 1, 'dosage': _bn ? '১টা' : '1 tab', 'food_relation': 'any', 'member_name': null, 'days_left': null, 'refill_date': null},
      ]);

  @override
  Future<Map<String, dynamic>> medicineHistory({String? member}) async {
    if (mode == FakeMode.fail) _fail();
    if (mode == FakeMode.empty) {
      return {'overall': 100, 'taken': 0, 'scheduled': 0, 'medicines': []};
    }
    List<Map<String, dynamic>> weeks(List<int> p) => [
          for (int i = 0; i < p.length; i++)
            {'start': '2026-09-${15 + i * 7}', 'end': '2026-09-${21 + i * 7}', 'pct': p[i]}
        ];
    return {
      'overall': 88,
      'taken': 106,
      'scheduled': 120,
      'medicines': [
        {'id': 1, 'name': 'Napa', 'member': 1, 'prn': false, 'adherence_30d': 92, 'taken': 55, 'scheduled': 60, 'streak': 4, 'weeks': weeks([80, 90, 100, 95])},
        {'id': 2, 'name': 'Losectil', 'member': null, 'prn': false, 'adherence_30d': 78, 'taken': 23, 'scheduled': 30, 'streak': 0, 'weeks': weeks([70, 60, 90, 85])},
        {'id': 3, 'name': 'Sleeping aid', 'member': 1, 'prn': true, 'adherence_30d': 100, 'taken': 0, 'scheduled': 0, 'streak': 0, 'weeks': weeks([0, 0, 0, 0])},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> caregiverDashboard() async {
    if (mode == FakeMode.fail) _fail();
    if (mode == FakeMode.empty) return {'people': [], 'push_ready': false};
    return {
      'push_ready': false,
      'people': [
        {
          'member': null, 'name': _bn ? 'আমি' : 'Me', 'relation': 'self',
          'doses_today': 1, 'taken_today': 0, 'pending_today': 1, 'next_due': '08:00',
          'adherence_30d': 78, 'low_stock': [], 'has_meds': true,
        },
        {
          'member': 1, 'name': _bn ? 'আম্মা' : 'Mother', 'relation': _bn ? 'মা' : 'mother',
          'doses_today': 2, 'taken_today': 1, 'pending_today': 1, 'next_due': '20:00',
          'adherence_30d': 92, 'has_meds': true,
          'low_stock': [{'name': 'Napa', 'days_left': 3, 'status': 'soon'}],
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> medicineEscalation(int id, {String? slot}) async => {
        'slot': slot ?? '20:00',
        'push_ready': false,
        'events': [
          {'kind': 'reminder', 'at': '20:00', 'suppressed': false},
          {'kind': 'reremind', 'at': '20:15', 'suppressed': false},
          {'kind': 'reremind', 'at': '20:30', 'suppressed': false},
          {'kind': 'caregiver_alert', 'at': '20:30', 'suppressed': false},
        ],
      };

  @override
  Future<Map<String, dynamic>> getEmergency() async {
    if (mode == FakeMode.fail) _fail();
    if (mode == FakeMode.empty) {
      return {'blood_group': '', 'allergies': '', 'medicines': '', 'conditions': '', 'contacts': []};
    }
    return {
      'blood_group': 'B+',
      'allergies': _bn ? 'পেনিসিলিন' : 'Penicillin',
      'medicines': 'Losectil',
      'conditions': _bn ? 'উচ্চ রক্তচাপ' : 'Hypertension',
      'contacts': [
        {'name': _bn ? 'ছেলে' : 'Son', 'phone': '01711111111', 'relation': _bn ? 'ছেলে' : 'Son'},
        {'name': _bn ? 'ডাক্তার' : 'Doctor', 'phone': '01999999999', 'relation': _bn ? 'ডাক্তার' : 'Doctor'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> moneySummary() async {
    if (mode == FakeMode.fail) _fail();
    if (mode == FakeMode.empty) {
      return {'total_balance': '0', 'month_expense': '0', 'month_income': '0', 'expense_by_category': {}, 'budgets': []};
    }
    return {
      'total_balance': '20800',
      'month_expense': '7600',
      'month_income': '25000',
      'expense_by_category': {
        (_bn ? 'খাবার' : 'Food'): '6400',
        (_bn ? 'যাতায়াত' : 'Transport'): '1200',
      },
      'budgets': [
        {'category': _bn ? 'খাবার' : 'Food', 'limit': '8000', 'spent': '6400'},
      ],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> listDocuments() async => _maybe([
        {'id': 1, 'title': _bn ? 'পাসপোর্ট' : 'Passport', 'doc_type': 'passport', 'expiry_date': '2026-11-05', 'file_url': '/api/v1/documents/1/file', 'note': ''},
        {'id': 2, 'title': 'NID', 'doc_type': 'nid', 'expiry_date': null, 'file_url': null, 'note': ''},
        {'id': 3, 'title': _bn ? 'ড্রাইভিং লাইসেন্স' : 'Driving licence', 'doc_type': 'licence', 'expiry_date': '2027-03-01', 'file_url': null, 'note': ''},
      ]);

  @override
  Future<List<Map<String, dynamic>>> sources() async {
    if (mode == FakeMode.fail) _fail();
    return [
      {'source': 'photo', 'enabled': true},
      {'source': 'share', 'enabled': true},
      {'source': 'voice', 'enabled': false},
      {'source': 'notification', 'enabled': false},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> alertsList() async => _maybe([
        {'text': _bn ? 'পাসপোর্টের মেয়াদ ২৪ দিনে শেষ' : 'Passport expires in 24 days', 'severity': 'high'},
        {'text': _bn ? 'যাতায়াত বাজেট শেষ' : 'Transport budget exceeded', 'severity': 'high'},
      ]);

  @override
  Future<Map<String, dynamic>> briefing() async => {
        'lines': _bn
            ? ['আজ ২টি রিমাইন্ডার', 'Napa ৮টায় ও ৮টায়', 'যাতায়াত বাজেট শেষ']
            : ['2 reminders today', 'Napa at 8am & 8pm', 'Transport budget exceeded'],
        'ai_text': null,
      };

  @override
  Future<Map<String, dynamic>> wrapped() async => {
        'title': _bn ? 'আপনার অক্টোবর' : 'Your October',
        'badges': _bn
            ? ['৳25,000 আয়', 'সবচেয়ে বেশি খরচ: খাবার', '১২ দিন টানা ওষুধ নিয়েছেন']
            : ['Earned ৳25,000', 'Top spend: Food', '12-day medicine streak'],
        'card_url': 'https://assisto.asalify.com/w/sample',
      };

  @override
  Future<Map<String, dynamic>> scamCheck(String message) async {
    final patterns = [
      {
        'key': 'suspicious_link', 'level': 'high',
        'name': _bn ? 'সন্দেহজনক লিংক' : 'Suspicious link',
        'why': _bn ? 'অজানা শর্ট-লিংক আছে।' : 'Contains an unknown short link.',
        'do': _bn ? 'লিংকে ক্লিক করবেন না।' : "Don't tap the link.",
      },
      {
        'key': 'urgency', 'level': 'medium',
        'name': _bn ? 'তাড়াহুড়ো' : 'Urgency pressure',
        'why': _bn ? 'দ্রুত কাজ করতে চাপ দিচ্ছে।' : 'Pressures you to act fast.',
        'do': _bn ? 'থামুন, যাচাই করুন।' : 'Pause and verify.',
      },
    ];
    return {
      'score': 68, 'verdict': 'scam', 'level': 'high', 'emoji': '⚠️',
      'label': _bn ? 'প্রতারণা হতে পারে' : 'Likely a scam',
      'patterns': patterns,
      'reasons': [for (final p in patterns) p['name']],
      'advice': _bn
          ? 'PIN/OTP দেবেন না, টাকা পাঠাবেন না, লিংকে ক্লিক করবেন না।'
          : "Don't share PIN/OTP, don't send money, don't tap links.",
      'summary': _bn ? '২টি সতর্কতা-সংকেত মিলেছে।' : '2 warning signals matched.',
    };
  }

  @override
  Future<Map<String, dynamic>> invite() async => {
        'code': 'ASSIST-7F2K',
        'invited': 3,
        'share_text': _bn
            ? 'Assisto দিয়ে আপনার জীবন সহজ করুন!'
            : 'Make life easier with Assisto!',
      };

  @override
  Future<List<AuditEntry>> audit() async {
    if (mode == FakeMode.fail) _fail();
    if (mode == FakeMode.empty) return [];
    return [
      AuditEntry(action: _bn ? 'খরচ যোগ: ৳500 খাবার' : 'Expense added: ৳500 Food', createdAt: DateTime(2026, 10, 12, 13, 20), detail: const {}),
      AuditEntry(action: _bn ? 'রিমাইন্ডার সেট' : 'Reminder set', createdAt: DateTime(2026, 10, 12, 9, 5), detail: const {}),
    ];
  }

  @override
  Future<List<int>> getBytes(String path) async => [];

  @override
  Future<Map<String, dynamic>> plan() async => {
        'plan': planSlug, 'name': _bn ? 'প্রিমিয়াম' : 'Premium', 'name_bn': _bn ? 'প্রিমিয়াম' : 'Premium',
        'unlimited_ai': false, 'ads': false, 'credits': 90,
        'trial_active': true, 'trial_until': '2026-10-20T00:00:00',
      };

  @override
  Future<List<Map<String, dynamic>>> plansPublic() async => _maybe([
        // Mirrors the real /plans payload (pricing.plan_public defaults):
        // credits = monthly pool, family = member count, benefits from config.
        {'id': 'free', 'name': _bn ? 'ফ্রি' : 'Free', 'price': 0, 'cur': 'BDT', 'period': 'mo',
         'desc': _bn ? 'শুরু করার জন্য — নিরাপত্তা সবসময় ফ্রি।' : 'To get started — safety is always free.',
         'benefits': _bn ? ['AI: ক্রেডিট প্যাক কিনে বা বিজ্ঞাপন দেখে', 'রিমাইন্ডার, ভল্ট, হিসাব', 'জরুরি SOS ও স্ক্যাম সতর্কতা (ফ্রি)', 'ওষুধ রিমাইন্ডার (ফ্রি)'] : ['AI with credit packs or rewarded ads', 'Reminders, documents, money', 'Emergency SOS & scam alerts (free)', 'Medicine reminders (free)'],
         'unlimited_ai': false, 'ads': true, 'family': 0, 'credits': 0},
        {'id': 'premium', 'name': _bn ? 'প্রিমিয়াম' : 'Premium', 'price': 199, 'cur': 'BDT', 'period': 'mo',
         'desc': _bn ? 'প্রতি মাসে AI ক্রেডিট, বিজ্ঞাপন নেই — পরিবারের যত্ন একসাথে।' : 'Monthly AI credits, no ads — care for your family together.',
         'benefits': _bn ? ['প্রতি মাসে ৯০ AI ক্রেডিট (স্ক্যান ও সহকারী)', 'বিজ্ঞাপন নেই', '৫ জন পর্যন্ত কানেক্টেড সার্কেল ও কেয়ারগিভার ড্যাশবোর্ড'] : ['90 AI credits / month (scans & assistant)', 'No ads', 'Up to 5-member Circle & caregiver dashboard'],
         'unlimited_ai': false, 'ads': false, 'family': 5, 'credits': 90},
        {'id': 'business', 'name': _bn ? 'বিজনেস' : 'Business', 'price': 499, 'cur': 'BDT', 'period': 'mo',
         'desc': _bn ? 'ছোট ব্যবসা ও বিক্রয় দলের জন্য।' : 'For small businesses and sales teams.',
         'benefits': _bn ? ['প্রতি মাসে ২৪০ AI ক্রেডিট (স্ক্যান ও সহকারী)', 'বিজনেস মোড: ক্যাটালগ ও অর্ডার', 'AI CRM (Axon Dynamics)'] : ['240 AI credits / month (scans & assistant)', 'Business mode: catalog & orders', 'AI CRM (Axon Dynamics)'],
         'unlimited_ai': false, 'ads': false, 'family': 0, 'credits': 240},
        {'id': 'annual', 'name': _bn ? 'বার্ষিক (প্রিমিয়াম)' : 'Annual (Premium)', 'price': 1910, 'cur': 'BDT', 'period': 'yr',
         'desc': _bn ? 'প্রিমিয়াম — বছরে, ২০% সাশ্রয়।' : 'Premium — yearly, save 20%.',
         'benefits': _bn ? ['প্রতি মাসে ৯০ AI ক্রেডিট (স্ক্যান ও সহকারী)', 'বিজ্ঞাপন নেই'] : ['90 AI credits / month (scans & assistant)', 'No ads'],
         'unlimited_ai': false, 'ads': false, 'family': 5, 'credits': 90},
      ]);

  @override
  Future<Map<String, dynamic>> parseReminder(String text) async => {
        'title': text, 'datetime': '2026-10-14T10:00:00',
        'date_only': false, 'recurrence_rule': {}, 'confidence': 0.6,
      };

  @override
  Future<List<Map<String, dynamic>>> searchMemoryApi(String q) async => _maybe([
        {'id': 1, 'title': _bn ? 'আম্মুর ওষুধ' : "Mom's medicine",
         'detail': _bn ? 'সকাল ৮টায় Napa' : 'Napa at 8am',
         'category': _bn ? 'স্বাস্থ্য' : 'Health', 'source': 'ai'},
      ]);

  @override
  Future<List<Map<String, dynamic>>> listMemory() async => _maybe([
        {'id': 1, 'title': _bn ? 'আম্মুর ওষুধ' : "Mom's medicine",
         'detail': _bn ? 'সকাল ৮টায় Napa' : 'Napa at 8am',
         'category': _bn ? 'স্বাস্থ্য' : 'Health', 'source': 'ai', 'needs_review': false},
        {'id': 2, 'title': _bn ? 'গাড়ির নম্বর' : 'Car number',
         'detail': 'DHAKA METRO GA 12-3456',
         'category': _bn ? 'ব্যক্তিগত' : 'Personal', 'source': 'manual', 'needs_review': false},
      ]);

  @override
  Future<Map<String, dynamic>> finance(String tool, Map<String, dynamic> args) async {
    if (tool == 'net_worth') {
      return {'assets': '320000', 'receivable': '20000', 'liabilities': '50000', 'net_worth': '290000'};
    }
    if (tool == 'zakat') return {'zakatable': '400000', 'zakat_due': '10000.00', 'above_nisab': true};
    if (tool == 'emi') return {'emi': '8884.88', 'total': '106618.56', 'interest': '6618.56', 'months': 12};
    return {'future_value': '132000.00', 'invested': '120000.00', 'years': 1, 'estimate': true};
  }

  @override
  Future<Map<String, dynamic>> watchFeed() async => {
        'hits': mode == FakeMode.empty ? [] : [
          {'id': 1, 'label': _bn ? 'USD/BDT রেট' : 'USD/BDT rate', 'kind': 'usd_bdt',
           'summary': _bn ? 'USD/BDT 122.50 → 122.80 (↑)' : 'USD/BDT 122.50 → 122.80 (↑)',
           'severity': 'info', 'at': '2026-10-13T09:00:00'},
          {'id': 2, 'label': _bn ? 'সরকারি job circular' : 'Govt job circular', 'kind': 'rss',
           'summary': _bn ? 'নতুন আপডেট — নিয়োগ বিজ্ঞপ্তি প্রকাশ' : 'New update — circular published',
           'severity': 'high', 'at': '2026-10-13T08:30:00'},
        ],
      };

  @override
  Future<Map<String, dynamic>> guides() async => {
        'services': [
          {'name': _bn ? 'NID (জাতীয় পরিচয়পত্র)' : 'National ID', 'portal': 'services.nidw.gov.bd',
           'steps': _bn
               ? ['অনলাইনে রেজিস্টার/লগইন', 'ফর্ম পূরণ + ছবি', 'ফি পরিশোধ', 'স্ট্যাটাস ট্র্যাক']
               : ['Register/log in online', 'Fill the form + photo', 'Pay the fee', 'Track status']},
          {'name': _bn ? 'ই-পাসপোর্ট' : 'e-Passport', 'portal': 'epassport.gov.bd',
           'steps': _bn
               ? ['অনলাইন আবেদন', 'ফি পরিশোধ', 'বায়োমেট্রিক', 'ডেলিভারি ট্র্যাক']
               : ['Apply online', 'Pay the fee', 'Biometrics', 'Track delivery']},
        ],
        'religious': [
          {'tip': _bn ? 'নামাজের সময় রিমাইন্ডার সেট করি।' : 'Set prayer-time reminders.'},
          {'tip': _bn ? 'যাকাত হিসাব করতে Finance → যাকাত।' : 'Use Finance → Zakat.'},
        ],
      };

  @override
  Future<Map<String, dynamic>> inboxStatus() async => {
        'connected': false,
        'legend': _bn
            ? {'red': 'জরুরি', 'yellow': 'শীঘ্রই', 'green': 'তথ্য'}
            : {'red': 'Urgent', 'yellow': 'Soon', 'green': 'Info'},
      };

  @override
  Future<Map<String, dynamic>> moneyTrends() async {
    if (mode == FakeMode.fail) _fail();
    if (mode == FakeMode.empty) return {'months': [], 'categories': []};
    return {
      'months': [
        {'month': '2026-08', 'income': '25000', 'expense': '7000', 'net': '18000', 'delta': '0'},
        {'month': '2026-09', 'income': '25000', 'expense': '9000', 'net': '16000', 'delta': '-2000'},
        {'month': '2026-10', 'income': '25000', 'expense': '7600', 'net': '17400', 'delta': '1400'},
      ],
      'categories': [
        {'category': _bn ? 'খাবার' : 'Food', 'current': '6400', 'previous': '4000', 'delta': '2400', 'up': true},
        {'category': _bn ? 'যাতায়াত' : 'Transport', 'current': '1200', 'previous': '1500', 'delta': '-300', 'up': false},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> moneyNetWorth() async {
    if (mode == FakeMode.fail) _fail();
    if (mode == FakeMode.empty) {
      return {'net_worth': '0', 'assets': '0', 'receivable': '0', 'liabilities': '0', 'series': []};
    }
    return {
      'net_worth': '23000', 'assets': '20800', 'receivable': '2000', 'liabilities': '5000',
      'series': [
        {'month': '2026-08', 'net_worth': '18000', 'delta': '0'},
        {'month': '2026-09', 'net_worth': '20500', 'delta': '2500'},
        {'month': '2026-10', 'net_worth': '23000', 'delta': '2500'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> moneyBudgetDetail(String category) async {
    if (mode == FakeMode.fail) _fail();
    return {
      'category': category, 'rollover': true, 'carry_forward': '1600',
      'months': [
        {'month': '2026-08', 'base_limit': '8000', 'carried_in': '0', 'effective_limit': '8000', 'spent': '6400', 'remaining': '1600', 'state': 'ok', 'pct': 80},
        {'month': '2026-09', 'base_limit': '8000', 'carried_in': '1600', 'effective_limit': '9600', 'spent': '9000', 'remaining': '600', 'state': 'near', 'pct': 94},
        {'month': '2026-10', 'base_limit': '8000', 'carried_in': '600', 'effective_limit': '8600', 'spent': '7600', 'remaining': '1000', 'state': 'ok', 'pct': 88},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> moneyReport() async {
    if (mode == FakeMode.fail) _fail();
    return {
      'month': '2026-10', 'income': '25000', 'expense': '7600', 'net': '17400', 'savings_rate': 70,
      'by_category': [
        {'category': _bn ? 'খাবার' : 'Food', 'amount': '6400'},
        {'category': _bn ? 'যাতায়াত' : 'Transport', 'amount': '1200'},
      ],
      'budgets': [
        {'category': _bn ? 'খাবার' : 'Food', 'limit': '8000', 'spent': '6400', 'state': 'ok', 'pct': 80},
      ],
      'biggest_expense': {'category': _bn ? 'খাবার' : 'Food', 'amount': '6400', 'date': '2026-10-05'},
    };
  }

  @override
  Future<Map<String, dynamic>> moneyParse(String text) async {
    if (mode == FakeMode.fail) _fail();
    return {
      'transactions': [
        {'parsed': true, 'type': 'debit', 'amount': '500', 'channel': 'bkash', 'counterparty': 'Foodpanda', 'category_guess': _bn ? 'খাবার' : 'food', 'ref': '9F2A1B', 'date': '2026-10-12', 'duplicate': false, 'raw': 'Payment Tk 500 to Foodpanda. Bal Tk 1250 TrxID 9F2A1B'},
        {'parsed': true, 'type': 'credit', 'amount': '25000', 'channel': 'bank', 'counterparty': 'ACME LTD', 'category_guess': _bn ? 'বেতন' : 'salary', 'ref': 'SAL10', 'date': '2026-10-01', 'duplicate': true, 'raw': 'A/C credited BDT 25000 Salary'},
        {'parsed': false, 'raw': 'Your OTP is 123456'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> moneyLearnCategory(String c, String cat) async => {};

  // ======================== Sales CRM demo data ========================
  // Makes every in-app CRM screen render populated in the screenshot gallery.

  List<Map<String, dynamic>> _crmLeads() => [
        {
          'id': 1, 'org': 1, 'name': _bn ? 'করিম গার্মেন্টস' : 'Karim Garments',
          'company': _bn ? 'করিম গার্মেন্টস লিঃ' : 'Karim Garments Ltd',
          'industry': 'rmg', 'industry_display': _bn ? 'গার্মেন্টস' : 'RMG',
          'company_size': 600, 'source': 'whatsapp', 'source_display': 'WhatsApp',
          'phone': '01712345678', 'whatsapp': '01712345678', 'email': 'buy@karim.com',
          'designation': _bn ? 'ব্যবস্থাপক' : 'Manager', 'score': 95, 'priority': 'high',
          'status': 'contacted', 'status_display': _bn ? 'যোগাযোগ হয়েছে' : 'Contacted',
          'score_reason': 'industry_fit=25 + company_size=25 + buying_signals=50 = 95',
          'required_modules': ['vat', 'hrm', 'inventory'],
          'budget_range': '৳5-10L', 'timeline': _bn ? '৩ মাস' : '3 months',
          'decision_maker': _bn ? 'এমডি' : 'MD', 'notes': _bn ? 'ভ্যাট কমপ্লায়েন্ট ইআরপি লাগবে' : 'Needs VAT-compliant ERP',
          'next_follow_up': '2026-10-14',
        },
        {
          'id': 2, 'org': 1, 'name': _bn ? 'ফার্মা কেয়ার' : 'Pharma Care',
          'company': 'Pharma Care', 'industry': 'pharma', 'industry_display': _bn ? 'ফার্মা' : 'Pharma',
          'company_size': 220, 'source': 'linkedin', 'source_display': 'LinkedIn',
          'phone': '01812345678', 'whatsapp': '', 'email': 'info@pharmacare.com',
          'designation': 'CTO', 'score': 72, 'priority': 'normal',
          'status': 'demo', 'status_display': _bn ? 'ডেমো' : 'Demo',
          'score_reason': 'industry_fit=22 + company_size=20 + buying_signals=30 = 72',
          'required_modules': ['accounts', 'inventory'], 'budget_range': '', 'timeline': '',
          'decision_maker': '', 'notes': '', 'next_follow_up': null,
        },
        {
          'id': 3, 'org': 1, 'name': _bn ? 'শপ ৩৬৫' : 'Shop 365',
          'company': 'Shop 365', 'industry': 'retail', 'industry_display': _bn ? 'রিটেইল' : 'Retail',
          'company_size': 40, 'source': 'manual', 'source_display': _bn ? 'ম্যানুয়াল' : 'Manual',
          'phone': '01912345678', 'whatsapp': '', 'email': '', 'designation': '',
          'score': 34, 'priority': 'normal', 'status': 'new', 'status_display': _bn ? 'নতুন' : 'New',
          'score_reason': 'industry_fit=18 + company_size=8 + buying_signals=10 = 36',
          'required_modules': ['sales'], 'budget_range': '', 'timeline': '',
          'decision_maker': '', 'notes': '', 'next_follow_up': '2026-10-13',
        },
      ];

  List<Map<String, dynamic>> _crmStages() => [
        {'id': 1, 'pipeline': 1, 'name': _bn ? 'নতুন' : 'New', 'order': 0, 'probability': 10, 'is_won': false, 'is_lost': false, 'stuck_after_days': 7},
        {'id': 2, 'pipeline': 1, 'name': _bn ? 'যোগাযোগ' : 'Qualified', 'order': 1, 'probability': 25, 'is_won': false, 'is_lost': false, 'stuck_after_days': 10},
        {'id': 3, 'pipeline': 1, 'name': _bn ? 'ডেমো' : 'Demo', 'order': 2, 'probability': 45, 'is_won': false, 'is_lost': false, 'stuck_after_days': 14},
        {'id': 4, 'pipeline': 1, 'name': _bn ? 'প্রপোজাল' : 'Proposal', 'order': 3, 'probability': 65, 'is_won': false, 'is_lost': false, 'stuck_after_days': 14},
        {'id': 5, 'pipeline': 1, 'name': _bn ? 'জিতেছি' : 'Won', 'order': 4, 'probability': 100, 'is_won': true, 'is_lost': false, 'stuck_after_days': 0},
        {'id': 6, 'pipeline': 1, 'name': _bn ? 'হারিয়েছি' : 'Lost', 'order': 5, 'probability': 0, 'is_won': false, 'is_lost': true, 'stuck_after_days': 0},
      ];

  List<Map<String, dynamic>> _crmDeals() => [
        {'id': 1, 'org': 1, 'title': 'Axon ERP — Karim Garments', 'stage': 2, 'stage_name': _bn ? 'যোগাযোগ' : 'Qualified', 'value': 1200000, 'probability': 25, 'expected_close': '2026-11-10', 'state': 'open', 'stage_entered_at': '2026-09-20T09:00:00', 'next_step': _bn ? 'ডেমো কল' : 'Demo call'},
        {'id': 2, 'org': 1, 'title': 'Axon ERP — Pharma Care', 'stage': 3, 'stage_name': _bn ? 'ডেমো' : 'Demo', 'value': 650000, 'probability': 45, 'expected_close': '2026-11-20', 'state': 'open', 'stage_entered_at': '2026-10-10T09:00:00', 'next_step': ''},
        {'id': 3, 'org': 1, 'title': 'Axon ERP — Shop 365', 'stage': 4, 'stage_name': _bn ? 'প্রপোজাল' : 'Proposal', 'value': 300000, 'probability': 65, 'expected_close': '2026-10-30', 'state': 'open', 'stage_entered_at': '2026-10-12T09:00:00', 'next_step': _bn ? 'প্রপোজাল পাঠাও' : 'Send proposal'},
      ];

  List<Map<String, dynamic>> _crmList(String path) {
    if (mode == FakeMode.fail) _fail();
    if (mode == FakeMode.empty) {
      // Keep pipeline stages so the kanban still shows columns even when empty.
      if (path.startsWith('crm/pipelines')) {
        return [{'id': 1, 'org': 1, 'name': 'Axon Sales', 'is_default': true, 'stages': _crmStages()}];
      }
      return [];
    }
    if (path.startsWith('crm/orgs')) {
      return [{'id': 1, 'name': _bn ? 'অ্যাক্সন সেলস' : 'Axon Sales', 'owner': 1}];
    }
    if (path.startsWith('crm/leads')) return _crmLeads();
    if (path.startsWith('crm/pipelines')) {
      return [{'id': 1, 'org': 1, 'name': 'Axon Sales', 'is_default': true, 'stages': _crmStages()}];
    }
    if (path.startsWith('crm/deals')) return _crmDeals();
    if (path.startsWith('crm/members')) {
      return [
        {'id': 1, 'org': 1, 'user': 1, 'user_name': _bn ? 'আরিফ' : 'Arif', 'role': 'owner'},
        {'id': 2, 'org': 1, 'user': 2, 'user_name': _bn ? 'নাদিয়া' : 'Nadia', 'role': 'sales'},
      ];
    }
    if (path.startsWith('crm/routing-rules')) {
      return [{'id': 1, 'org': 1, 'match_industry': 'rmg', 'match_source': '', 'assign_to': 2, 'active': true}];
    }
    if (path.startsWith('crm/products')) {
      return [
        {'id': 1, 'org': 1, 'sku': 'ERP-CORE', 'name': 'Axon ERP Core', 'unit_price': '250000', 'billing': 'one_time', 'price_reviewed': true, 'active': true},
        {'id': 2, 'org': 1, 'sku': 'ERP-HR', 'name': 'HR & Payroll', 'unit_price': '80000', 'billing': 'one_time', 'price_reviewed': false, 'active': true},
      ];
    }
    if (path.startsWith('crm/proposals')) {
      return [
        {'id': 1, 'lead': 1, 'version': 1, 'title': 'Axon ERP Proposal — Karim Garments', 'body': _bn ? 'আপনার প্রতিষ্ঠানের জন্য প্রস্তাবিত সমাধান...' : 'Proposed solution for your organisation...', 'status': 'draft', 'subtotal': 400000, 'discount_amount': 20000, 'discount_pct': 5, 'tax_pct': 0, 'tax_amount': 0, 'total': 380000, 'prices_reviewed': true},
      ];
    }
    if (path.startsWith('crm/activities')) {
      return [
        {'id': 1, 'org': 1, 'kind': 'call', 'kind_display': _bn ? 'কল' : 'Call', 'subject': _bn ? 'প্রথম কল' : 'Intro call', 'body': '', 'actor_name': _bn ? 'আরিফ' : 'Arif', 'created_at': '2026-10-12T10:00:00'},
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> createItem(String path, Map<String, dynamic> body) async {
    if (path.startsWith('crm/')) return {'id': 99, ...body};
    // vault / scam / safety module endpoints (used via the ScamSafetyApi
    // extension: scamReportFamily, safetyCheckinStart, safetyCheckinArrived,
    // createDocumentWithDetails).
    if (path.startsWith('scam/report') ||
        path.startsWith('safety/checkin') ||
        path.startsWith('documents')) {
      if (mode == FakeMode.fail) _fail();
      return {'ok': true, 'id': 99, ...body};
    }
    if (path == 'appointments') {
      if (mode == FakeMode.fail) _fail();
      return {'ok': true, ...body};
    }
    // build-61: Safe Journey createItem-based paths (no leading slash):
    // journey/<id>/arrived|respond, journey/duress-pin, journey/routines,
    // journey/wellness, journey/wellness/ping, journey/places, journey/where-are-you.
    if (path.startsWith('journey/')) {
      return {'ok': true, 'id': 1, ...body};
    }
    return super.createItem(path, body);
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    await _slow();
    final c100 = fakeCrm100Get(path, empty: mode == FakeMode.empty); // crm100
    if (c100 != null) {
      if (mode == FakeMode.fail) _fail();
      return c100;
    }
    if (path == '/account/delete/status') {
      return delPending
          ? {'state': 'pending', 'effective_at': '2026-10-29T10:00:00Z',
              'otp_required': false}
          : {'state': null};
    }
    // b6-antitheft: Lost/Stolen engine stubs (empty mode => OFF screen)
    if (path == '/security/engine/state') {
      final on = mode != FakeMode.empty;
      return {
        'enabled': on,
        'has_pin': true,
        'snatch_lock': true,
        'intruder_photo': false, // opt-in: off until the owner turns it on
        'failed_unlock_threshold': 3,
        'alert_member_ids': on ? [1] : <int>[],
        'alert_members': on ? [{'id': 1, 'name': _bn ? 'বাবা' : 'Dad'}] : [],
        'candidates': [
          {'id': 1, 'name': _bn ? 'বাবা' : 'Dad'},
          {'id': 2, 'name': _bn ? 'বড় ভাই' : 'Brother'},
        ],
        'capabilities': {'sdk': 33, 'brand': 'realme', 'canCamera': false,
                         'canReadSimNumber': false},
        'last_ingest_at': DateTime.now().toUtc().toIso8601String(),
        'interval_min': 15,
        'frozen': false,
        'lost_mode': false,
        'recent': const [],
      };
    }
    if (path.startsWith('/security/engine/timeline')) {
      final now = DateTime.now().toUtc();
      String iso(Duration d) => now.subtract(d).toIso8601String();
      return {
        'viewer': 'owner',
        'enabled': true,
        'lost_mode': false,
        'went_dark_at': null,
        'last_location': {'lat': 23.78, 'lng': 90.41, 'at': iso(const Duration(minutes: 5))},
        'events': mode == FakeMode.empty ? [] : [
          {'id': 1, 'kind': 'sim_change', 'at': iso(const Duration(minutes: 20)),
           'late': false, 'data': {'state': 'inserted', 'carrier': 'Robi'}, 'has_photo': false},
          {'id': 2, 'kind': 'offline', 'at': iso(const Duration(hours: 2)),
           'late': true, 'data': {'reason': 'airplane'}, 'has_photo': false},
          {'id': 3, 'kind': 'low_battery', 'at': iso(const Duration(hours: 3)),
           'late': false, 'battery': 9, 'has_photo': false},
          {'id': 4, 'kind': 'failed_unlock', 'at': iso(const Duration(hours: 5)),
           'late': false, 'data': {'count': 3}, 'has_photo': false},
        ],
      };
    }
    // at100: remote switches + the trusted contact's watched phones
    if (path.startsWith('/security/engine/commands')) {
      if (mode == FakeMode.fail) _fail();
      return at100FakeCommands(bn: _bn, empty: mode == FakeMode.empty,
          trusted: path.contains('phone_id='));
    }
    if (path == '/security/engine/watching') {
      if (mode == FakeMode.fail) _fail();
      return {'watching': mode == FakeMode.empty ? [] : at100FakeWatching(_bn)};
    }
    final pay1 = _pay1Get(path); // pay1 (plans / credits / checkout)
    if (pay1 != null) {
      if (mode == FakeMode.fail) _fail();
      return pay1;
    }
    // v1-vehicle: vehicle tracking stubs (test/fake_vehicle.dart)
    final veh = fakeVehicleGet(path, _bn, mode.name, planSlug);
    if (veh != null) return veh;
    // d1-discover: Discover cards + owner Discover manager stubs
    final disc = fakeDiscoverGet(path, _bn, mode.name);
    if (disc != null) return disc;
    final c1 = fakeC1Get(path); // c1-contacts
    if (c1 != null) return c1;
    final mr1 = fakeMr1Get(path, _bn); // mr1 message requests (gallery)
    if (mr1 != null) return mr1;
    final md1 = fakeMd1Get(path, _bn); // md1 E2E media (gallery)
    if (md1 != null) return md1;
    final c3 = C3Fake.get(path, _bn); // c3-msg (gallery only)
    if (c3 != null) return c3;
    // ===== Home / Notification centre stubs =====
    if (path == '/home/badges') return {'my_circle_unread': 3, 'notif_unseen': 5};
    if (path.startsWith('/home/suggestions')) {
      if (mode == FakeMode.fail) _fail();
      final b = _bn;
      return {'lang': b ? 'bn' : 'en', 'prompts': [
        {'key':'medicine_due','text': b?'আম্মুর ওষুধের সময় হয়েছে — রেকর্ড করুন':'Record Mom\'s medicine (due now)','route':'family'},
        {'key':'pay_bill','text': b?'বিদ্যুৎ বিল ৳৮৫০ আজ শেষ তারিখ':'Electricity bill ৳850 due today','route':'money'},
        {'key':'birthday','text': b?'রহিমের জন্মদিন আগামীকাল — শুভেচ্ছা পাঠান':'Rahim\'s birthday tomorrow — send a wish','route':'birthdays'},
        {'key':'morning','text': b?'সকালের সারসংক্ষেপ দেখুন':'See your morning briefing','route':'watch_feed'},
      ]};
    }
    if (path.startsWith('/notif/reminders')) {
      if (mode == FakeMode.fail) _fail();
      final b=_bn;
      Map<String,dynamic> it(id,ttl_bn,ttl_en,sec,route)=>{'id':id,'source_module':route,'title':{'bn':ttl_bn,'en':ttl_en},'when':'2026-10-14T18:00:00','section':sec,'route':route,'actions':['done','snooze','open']};
      return {'now':'2026-10-14T09:00:00','badge':1,'snooze_options':['15m','1h','tomorrow','custom'],'counts':{'today':2,'upcoming':1,'missed':1},'sections':{
        'missed':[it('reminder:1','গতকালের ওষুধ মিস','Missed yesterday\'s medicine','missed','family')],
        'today':[it('reminder:2','দুপুরের ওষুধ','Noon medicine','today','family'),it('sub:3','নেটফ্লিক্স নবায়ন ৳৫০০','Netflix renews ৳500','today','subscriptions')],
        'upcoming':[it('meeting:4','ক্লায়েন্ট মিটিং','Client meeting','upcoming','meetings')]}};
    }
    if (path.startsWith('/notif/feed')) {
      if (mode == FakeMode.fail) _fail();
      final b=_bn;
      Map<String,dynamic> ev(id,type,title,bd_bn,bd_en,seen,route)=>{'id':id,'type':type,'title':{'bn':title,'en':title},'body':{'bn':bd_bn,'en':bd_en},'at':'2026-10-14T08:30:00','seen':seen,'route':route};
      return {'unseen':3,'badge':2,'bell_badge':0,'types':['circle_request','family_alert','business','security'],'items':[
        ev('notif:1','circle_request',b?'নতুন সার্কেল রিকোয়েস্ট':'New circle request','করিম যুক্ত হতে চান','Karim wants to connect',false,'circle'),
        ev('notif:2','family_alert',b?'পরিবার সতর্কতা':'Family alert','আম্মু ওষুধ মিস করেছেন','Mom missed a dose',false,'family'),
        ev('notif:3','business',b?'নতুন অর্ডার':'New order','৩টি নতুন অর্ডার','3 new orders',true,'business'),
        ev('notif:4','security',b?'নতুন ডিভাইস লগইন':'New device login','নতুন ফোন থেকে লগইন','Login from a new phone',true,'settings')]};
    }
    // ===== P14-P16 gap stubs =====
    if (path == '/analytics/dashboard') {
      if (mode == FakeMode.fail) _fail();
      if (mode == FakeMode.empty) {
        return {
          'retention': {
            'd1': {'eligible': 0, 'returned': 0, 'pct': 0.0},
            'd7': {'eligible': 0, 'returned': 0, 'pct': 0.0},
            'd30': {'eligible': 0, 'returned': 0, 'pct': 0.0},
            'new_users': 0,
          },
          'invites': {'sent': 0, 'accepted': 0, 'accept_rate_pct': 0.0},
          'paid_funnel': {
            'viewed': 0, 'started': 0, 'completed': 0,
            'view_to_start_pct': 0.0, 'start_to_paid_pct': 0.0, 'view_to_paid_pct': 0.0,
          },
          'top_features': <Map<String, dynamic>>[],
          'total_events': 0,
        };
      }
      return {
        'retention': {
          'd1': {'eligible': 120, 'returned': 78, 'pct': 65.0},
          'd7': {'eligible': 120, 'returned': 48, 'pct': 40.0},
          'd30': {'eligible': 90, 'returned': 27, 'pct': 30.0},
          'new_users': 34,
        },
        'invites': {'sent': 210, 'accepted': 132, 'accept_rate_pct': 62.9},
        'paid_funnel': {
          'viewed': 500, 'started': 180, 'completed': 54,
          'view_to_start_pct': 36.0, 'start_to_paid_pct': 30.0, 'view_to_paid_pct': 10.8,
        },
        'top_features': [
          {'feature': 'reminders', 'users': 142},
          {'feature': 'money', 'users': 118},
          {'feature': 'family', 'users': 73},
        ],
        'total_events': 8432,
      };
    }
    if (path.startsWith('/name/about')) {
      if (mode == FakeMode.fail) _fail();
      if (mode == FakeMode.empty) return {};
      return {
        'name': 'Assisto',
        'meaning': _bn
            ? "'Assisto' অর্থ সহায়তা করা — অ্যাপের উদ্দেশ্যকেই তুলে ধরে।"
            : "'Assisto' means to assist — reflecting the app's purpose.",
        'classes': [
          {'class': 9, 'note': _bn ? 'সফটওয়্যার, মোবাইল অ্যাপ' : 'Software, mobile apps'},
          {'class': 42, 'note': _bn ? 'SaaS, সফটওয়্যার ডেভেলপমেন্ট' : 'SaaS, software development'},
        ],
        'checklist': [
          _bn ? 'BD DPDT ট্রেডমার্ক ডাটাবেসে নামটি সার্চ করুন।' : 'Search the name in the BD DPDT database.',
          _bn ? 'একজন ট্রেডমার্ক আইনজীবীর সাথে পরামর্শ করুন।' : 'Consult a trademark attorney before filing.',
        ],
        'status': _bn ? 'গবেষণা চলমান — ছাড়পত্র দাবি করা হয়নি।' : 'Research pending — no clearance claimed.',
        'disclaimer': _bn
            ? 'এটি একটি গবেষণা চেকলিস্ট মাত্র — আইনি ছাড়পত্র নয়।'
            : 'This is a research checklist only — not legal clearance.',
      };
    }
    // ===== Module 5 (P13+) stubs =====
    if (path.startsWith('/health/tips')) {
      if (mode == FakeMode.fail) _fail();
      return {
        'topics': [
          {'id': 'dengue_mosquito', 'name': _bn ? 'ডেঙ্গু ও মশা' : 'Dengue & mosquitoes'},
          {'id': 'nutrition', 'name': _bn ? 'পুষ্টি' : 'Nutrition'},
        ],
        'tips': mode == FakeMode.empty ? [] : [
          {'id': 't1', 'topic': 'nutrition',
           'title': _bn ? 'লবণ কম খান' : 'Cut down on salt',
           'body': _bn ? 'দিনে ৫ গ্রামের কম লবণ রক্তচাপ নিয়ন্ত্রণে রাখে।' : 'Under 5g of salt a day helps control blood pressure.',
           'source': 'WHO', 'source_name': _bn ? 'বিশ্ব স্বাস্থ্য সংস্থা (WHO)' : 'World Health Organization (WHO)'},
        ],
        'disclaimer': _bn ? 'এটি রোগ নির্ণয় নয়—সমস্যা থাকলে ডাক্তার দেখান।' : 'This is not a diagnosis — see a doctor if needed.',
        'sources': [_bn ? 'DGHS' : 'DGHS', 'WHO'],
      };
    }
    if (path.startsWith('/medicine-db/search')) {
      if (mode == FakeMode.fail) _fail();
      return {
        'results': mode == FakeMode.empty ? [] : [
          {'brand': 'Napa', 'generic': 'Paracetamol',
           'uses': _bn ? 'জ্বর, ব্যথা' : 'Fever, pain',
           'how_to_take': _bn ? 'প্রয়োজনে ১টি ট্যাবলেট' : '1 tablet as needed',
           'alternatives': [{'brand': 'Ace', 'generic': 'Paracetamol'}]},
        ],
        'meta': {'source': 'sample', 'is_sample': true, 'count': 1,
                 'sample_notice': _bn ? 'নমুনা তথ্য—DGDA ডাটা যুক্ত হলে পূর্ণ হবে।' : 'Sample data — full when DGDA data is added.',
                 'switch_warning': _bn ? 'ডাক্তারের পরামর্শ ছাড়া ওষুধ বদলাবেন না।' : "Don't switch medicines without a doctor's advice."},
      };
    }
    if (path.startsWith('/medicine-db/lookup')) {
      return {'available': true, 'record': {
        'brand': 'Napa', 'generic': 'Paracetamol',
        'uses': _bn ? 'জ্বর, ব্যথা' : 'Fever, pain',
        'alternatives': [{'brand': 'Ace', 'generic': 'Paracetamol'}]},
        'meta': {'source': 'sample', 'is_sample': true}};
    }
    if (path.startsWith('/birthdays')) {
      if (mode == FakeMode.fail) _fail();
      final all = mode == FakeMode.empty ? [] : [
        {'id': 1, 'name': _bn ? 'মা' : 'Mom', 'date': '1970-05-01', 'kind': 'birthday',
         'lead_days': 1, 'days_until': 5, 'turning_age': 56},
      ];
      return {'upcoming': all, 'all': all,
              'kinds': [
                {'id': 'birthday', 'name': _bn ? 'জন্মদিন' : 'Birthday'},
                {'id': 'anniversary', 'name': _bn ? 'বার্ষিকী' : 'Anniversary'},
              ]};
    }
    if (path.startsWith('/dictionary/lookup')) {
      if (mode == FakeMode.fail) _fail();
      final q = Uri.parse('http://x$path').queryParameters['q'] ?? '';
      if (q.isEmpty || mode == FakeMode.empty) {
        return {'found': false, 'query': q, 'results': const [],
                'is_sample': true, 'source': 'sample', 'needs_data': q.isNotEmpty};
      }
      return {'found': true, 'query': q, 'direction': 'en2bn',
              'results': [{'bn': 'পানি', 'en': 'water', 'pos': 'noun', 'example': 'Drink water.'}],
              'is_sample': true, 'source': 'sample', 'needs_data': false};
    }
    if (path.startsWith('/ramadan/times')) {
      if (mode == FakeMode.fail) _fail();
      return {'date': '2026-03-15', 'method': 'karachi',
              'sehri_end': '04:42', 'fajr': '04:42', 'dhuhr': '12:05',
              'asr': '15:30', 'iftar': '18:12', 'maghrib': '18:12', 'isha': '19:30'};
    }
    if (path.startsWith('/legal/')) {
      return {'key': path.split('/').last,
              'title': _bn ? 'গোপনীয়তা নীতি' : 'Privacy policy',
              'draft': true,
              'stamp': _bn ? 'খসড়া — মালিকের পর্যালোচনা প্রয়োজন' : 'DRAFT — TO REVIEW BY OWNER',
              'last_updated': '2026-10-13',
              'web_url': 'https://lifeassisto.com/privacy${_bn ? '' : '?lang=en'}',
              'body': _bn ? 'এটি একটি খসড়া নীতিমালা।' : 'This is a draft policy.'};
    }
    if (path == '/legal' || path.startsWith('/legal?')) {
      if (mode == FakeMode.fail) _fail();
      return {'pages': mode == FakeMode.empty ? [] : [
        {'key': 'privacy', 'title': _bn ? 'গোপনীয়তা নীতি' : 'Privacy policy',
         'stamp': _bn ? 'খসড়া — মালিকের পর্যালোচনা প্রয়োজন' : 'DRAFT — TO REVIEW BY OWNER'},
        {'key': 'terms', 'title': _bn ? 'ব্যবহারের শর্ত' : 'Terms of use',
         'stamp': _bn ? 'খসড়া — মালিকের পর্যালোচনা প্রয়োজন' : 'DRAFT — TO REVIEW BY OWNER'},
      ]};
    }
    if (path == '/unseen' || path.startsWith('/unseen?')) {
      if (mode == FakeMode.fail) _fail();
      return {'source': 'unseenbangladesh.com',
              'attribution': _bn ? 'তথ্যসূত্র: unseenbangladesh.com ও উন্মুক্ত তথ্য।' : 'Sources: unseenbangladesh.com and open data.',
              'destinations': mode == FakeMode.empty ? [] : [
                {'name': _bn ? 'নিঝুম দ্বীপ' : 'Nijhum Dwip', 'region': _bn ? 'নোয়াখালী' : 'Noakhali',
                 'best_season': _bn ? 'শীতকাল' : 'Winter', 'tip': _bn ? 'নৌকায় যান।' : 'Go by boat.',
                 'source': 'unseenbangladesh.com'},
              ],
              'tips': mode == FakeMode.empty ? [] : [
                _bn ? 'আগে থেকে থাকার ব্যবস্থা করুন।' : 'Book your stay ahead of time.',
              ]};
    }
    final m3 = fakeM3Get(path, bn: _bn); // m3-circle (gallery only)
    if (m3 != null) return m3;
    if (path.startsWith('/circle/requests')) {
      if (mode == FakeMode.fail) _fail();
      return {'results': const []}; // friendly empty state
    }
    if (path.startsWith('/circle/members')) {
      if (mode == FakeMode.fail) _fail();
      final members = mode == FakeMode.empty
          ? const []
          : [
              {'id': 1, 'name': _bn ? 'Ammu' : 'Mom', 'phone': '01710000000', 'status': 'accepted', 'relation': 'mother'},
            ];
      // circle_screen reads results ?? members; journey_start reads members ?? accepted.
      return {'results': members, 'members': members, 'accepted': members};
    }
    if (path.startsWith('/circle/calls')) {
      if (mode == FakeMode.fail) _fail();
      return {
        'calls': mode == FakeMode.empty ? const [] : [
          // x1-calls: 6 missed calls in a row from one person -> ONE row
          // "T Shanto BD (6)" (grouped WhatsApp-style), then a normal call.
          for (var i = 0; i < 6; i++)
            {'id': 20 - i, 'kind': 'voice', 'state': 'missed', 'end_reason': 'no_answer', 'outgoing': false, 'peer_id': 20, 'member_id': 5, 'name': 'T Shanto BD', 'outcome': _bn ? 'ভয়েস · মিসড কল' : 'Voice · Missed call', 'started_at': '2026-10-22T07:3${5 - i}:00Z'},
          {'id': 1, 'kind': 'voice', 'state': 'ended', 'duration_sec': 65, 'duration': '01:05', 'mine': true, 'outgoing': true, 'peer_id': 3, 'name': _bn ? 'Ammu' : 'Mom', 'peer': _bn ? 'Ammu' : 'Mom', 'started_at': '2026-10-10T09:00:00Z'},
        ],
      };
    }
    if (path.startsWith('/circle/privacy')) {
      if (mode == FakeMode.fail) _fail();
      return {
        'visibility': {
          'last_seen': 'family', 'active_status': 'family', 'profile_photo': 'everyone',
          'about': 'everyone', 'status': 'everyone',
        },
        'read_receipts': true, 'typing': true, 'call_policy': 'everyone',
        'dnd_enabled': false, 'dnd_start': '22:00', 'dnd_end': '07:00',
        'dnd_family_exception': true,
      };
    }
    if (path.startsWith('/circle/') && path.contains('/messages')) {
      return {'results': const []};
    }
    // ===== M2: Groups / Status / Extras GET stubs =====
    if (path.startsWith('/circle/groups/') && path.contains('/members')) {
      if (mode == FakeMode.fail) _fail();
      final members = mode == FakeMode.empty ? const [] : [
        {'id': 0, 'name': _bn ? 'আমি' : 'Me', 'role': 'admin', 'is_self': true,
         'my_member_id': 0, 'my_role': 'admin', 'public_key': '', 'key_id': 'k0'},
        {'id': 1, 'name': _bn ? 'Ammu' : 'Mom', 'role': 'member', 'is_self': false,
         'my_member_id': 0, 'my_role': 'admin', 'public_key': 'AA==', 'key_id': 'k1'},
      ];
      return {'members': members, 'my_role': 'admin', 'my_member_id': 0};
    }
    if (path.startsWith('/circle/groups/') && path.endsWith('/invite')) {
      return {'token': 'fake-group-token', 'link': 'assisto://g/fake-group-token'};
    }
    if (RegExp(r'^/circle/groups/\d+$').hasMatch(path)) {
      return {'id': int.tryParse(path.split('/').last) ?? 1,
              'name': _bn ? 'পরিবার' : 'Family', 'description': '',
              'announcements_only': false, 'size_limit': 256,
              'my_role': 'admin', 'member_count': 2};
    }
    if (path == '/circle/groups' || path.startsWith('/circle/groups?')) {
      if (mode == FakeMode.fail) _fail();
      return {'groups': mode == FakeMode.empty ? const [] : [
        {'id': 1, 'name': _bn ? 'পরিবার' : 'Family', 'member_count': 4,
         'pinned_count': 1, 'announcements_only': false, 'my_role': 'admin'},
      ]};
    }
    if (path == '/circle/status/mine') {
      return {'statuses': mode == FakeMode.empty ? const [] : [
        {'id': 10, 'kind': 'text', 'created_at': '2026-10-14T08:00:00Z',
         'expires_at': '2026-10-15T08:00:00Z', 'viewer_count': 2,
         'views': [{'viewer': _bn ? 'Ammu' : 'Mom', 'at': '2026-10-14T09:00:00Z', 'anonymous': false}]},
      ], 'viewer_count': 2};
    }
    if (path.startsWith('/circle/status/author/')) {
      return {'statuses': mode == FakeMode.empty ? const [] : [
        {'id': 11, 'kind': 'text', 'created_at': '2026-10-14T07:00:00Z',
         'expires_at': '2026-10-15T07:00:00Z'},
      ]};
    }
    if (path == '/circle/status' || path.startsWith('/circle/status?')) {
      if (mode == FakeMode.fail) _fail();
      return {
        'mine': mode == FakeMode.empty ? null : {'count': 1},
        'entries': mode == FakeMode.empty ? const [] : [
          {'author_id': 1, 'author': {'id': 1, 'name': _bn ? 'Ammu' : 'Mom'},
           'count': 2, 'has_unseen': true, 'latest_at': '2026-10-14T08:00:00Z'},
        ],
      };
    }
    if (path.endsWith('/settings') && path.startsWith('/circle/')) {
      return {'disappearing_sec': 0};
    }
    if (path.endsWith('/scheduled') && path.startsWith('/circle/')) {
      return {'results': mode == FakeMode.empty ? const [] : [
        {'id': 1, 'send_at': '2026-10-20T09:00:00Z', 'status': 'pending'},
      ]};
    }
    if (path == '/circle/backup') {
      return {'backup': mode == FakeMode.empty ? null : {
        'v': 1, 'created_at': '2026-10-13T10:00:00Z', 'message_count': 42,
        'recovery_hint': _bn ? 'নীল নোটবুক' : 'blue notebook', 'size_bytes': 10240}};
    }
    if (path == '/circle/devices') {
      return {'devices': [
        {'id': 1, 'device_id': 'this', 'platform': 'android',
         'role': 'primary', 'name': _bn ? 'এই ফোন' : 'This phone',
         'linked_at': '2026-10-01T10:00:00Z', 'revoked': false},
      ]};
    }
    if (path.startsWith('/circle/invite')) {
      return {'token': 'fake-token', 'qr': 'assisto://i/fake-token'};
    }
    // ===== build-61: referral + Safe Journey GET stubs =====
    if (path.startsWith('/referral/balance')) {
      if (mode == FakeMode.fail) _fail();
      return {'points': 120, 'redeemable_days': 4, 'points_per_day': 25, 'min_redeem': 25, 'can_redeem': true, 'invite_link': 'https://assisto.app/i/abc'};
    }
    if (path.startsWith('/referral/history')) {
      if (mode == FakeMode.fail) _fail();
      return {'history': mode == FakeMode.empty ? const [] : [
        {'kind': 'grant', 'points': 50, 'reason': 'referral_accept', 'label': _bn ? 'Referral' : 'Referral', 'created_at': '2026-10-01T10:00:00Z'},
      ]};
    }
    if (path.startsWith('/journey/active')) {
      if (mode == FakeMode.fail) _fail();
      return const {}; // no active journey
    }
    if (path.contains('/web-link')) {
      return {'url': 'https://assisto.app/j/tok', 'token': 'tok'};
    }
    if (path.startsWith('/journey/nearest-help')) {
      return {
        'police': [{'name': _bn ? 'Thana' : 'Police station', 'distance_m': 300}],
        'hospital': [{'name': _bn ? 'Hospital' : 'Hospital', 'distance_m': 800}],
      };
    }
    if (path.startsWith('/journey/places')) {
      return {'places': mode == FakeMode.empty ? const [] : [
        {'label': 'Home', 'name': _bn ? 'Home' : 'Home', 'lat': 23.8, 'lng': 90.4},
      ]};
    }
    if (path.startsWith('/journey/wellness')) {
      return {'enabled': false, 'parent_opt_in': false, 'period_hours': 12};
    }
    if (path.startsWith('/journey/routines')) {
      return {'routines': const []};
    }
    if (path.contains('/timeline') && path.startsWith('/journey/')) {
      return {'events': const [], 'locations': const []};
    }
    if (path.startsWith('/scam/library')) {
      if (mode == FakeMode.fail) _fail();
      final patterns = mode == FakeMode.empty ? [] : [
        {'key': 'otp_phish', 'level': 'high',
         'name': _bn ? 'OTP/পিন হাতানো' : 'OTP / PIN phishing',
         'why': _bn ? 'OTP/PIN চায় — ব্যাংক কখনো চায় না।' : 'Asks for OTP/PIN — banks never do.',
         'do': _bn ? 'কাউকে OTP/PIN দেবেন না।' : 'Never share OTP/PIN with anyone.'},
        {'key': 'mfs_verify_phish', 'level': 'high',
         'name': _bn ? 'bKash/Nagad যাচাই প্রতারণা' : 'bKash/Nagad verify scam',
         'why': _bn ? 'অ্যাকাউন্ট যাচাইয়ের নামে তথ্য চায়।' : 'Asks to "verify" your MFS account.',
         'do': _bn ? 'নিজের অ্যাপে যাচাই করুন।' : 'Verify only inside your own app.'},
        {'key': 'lottery', 'level': 'medium',
         'name': _bn ? 'লটারি/পুরস্কার' : 'Lottery / prize',
         'why': _bn ? 'না-খেলা লটারিতে জেতা দেখায়।' : 'Claims you won a lottery you never entered.',
         'do': _bn ? 'উপেক্ষা করুন।' : 'Ignore and delete.'},
      ];
      return {'patterns': patterns};
    }
    if (path.startsWith('/guides')) {
      return guides();
    }
    if (path.startsWith('/crm/today')) {
      if (mode == FakeMode.fail) _fail();
      final leads = mode == FakeMode.empty ? <Map<String, dynamic>>[] : _crmLeads().where((l) => (l['score'] as int) >= 90).toList();
      return {
        'ok': true,
        'high_score_leads': leads,
        'lead_followups': mode == FakeMode.empty ? [] : [
          {'id': 3, 'name': _bn ? 'শপ ৩৬৫' : 'Shop 365', 'company': 'Shop 365', 'next_follow_up': '2026-10-13', 'priority': 'normal'},
        ],
        'overdue_next_steps': mode == FakeMode.empty ? [] : [
          {'deal_id': 1, 'title': 'Axon ERP — Karim Garments', 'next_step': _bn ? 'ডেমো কল' : 'Demo call', 'due': '2026-10-11'},
        ],
        'missing_next_step': mode == FakeMode.empty ? [] : [
          {'deal_id': 2, 'title': 'Axon ERP — Pharma Care'},
        ],
        'due_tasks': [],
        'stuck_deals': mode == FakeMode.empty ? [] : [
          {'deal_id': 1, 'title': 'Axon ERP — Karim Garments', 'stage': _bn ? 'যোগাযোগ' : 'Qualified', 'days': 23, 'threshold': 10},
        ],
      };
    }
    if (path.startsWith('/crm/dashboard')) {
      if (mode == FakeMode.fail) _fail();
      final thin = mode == FakeMode.empty;
      return {
        'ok': true,
        'pipeline_value': thin ? 0 : 2150000,
        'won_value': thin ? 0 : 1850000,
        'status_counts': {'new': 1, 'contacted': 1, 'demo': 1, 'proposal': 0, 'won': 2, 'lost': 1},
        'high_priority_leads': thin ? [] : _crmLeads().where((l) => l['priority'] == 'high').toList(),
        'forecast': thin
            ? {'has_data': false, 'message_bn': 'পর্যাপ্ত ডাটা নেই — পূর্বাভাসের জন্য অন্তত একটি চলমান ডিল দরকার।', 'message_en': 'Not enough data — a forecast needs at least one open deal.', 'weighted': 0, 'method': 'Σ(value × probability / 100) over open deals'}
            : {'has_data': true, 'weighted': 622500, 'best_case': 2150000, 'commit': 300000, 'open_count': 3, 'commit_count': 1, 'method': 'Σ(value × probability / 100) over open deals'},
        'win_loss': thin ? {'has_data': false} : {'has_data': true, 'won': 2, 'lost': 1, 'win_rate': 66.7},
        'by_industry': thin ? {'has_data': false, 'rows': []} : {'has_data': true, 'rows': [
          {'industry': 'rmg', 'count': 1, 'value': 1200000},
          {'industry': 'pharma', 'count': 1, 'value': 650000},
          {'industry': 'retail', 'count': 1, 'value': 300000},
        ]},
        'by_salesperson': thin ? {'has_data': false, 'rows': []} : {'has_data': true, 'rows': [
          {'member_id': 1, 'name': _bn ? 'আরিফ' : 'Arif', 'role': 'owner', 'open': 2, 'won': 2, 'lost': 0, 'won_value': 1850000},
          {'member_id': 2, 'name': _bn ? 'নাদিয়া' : 'Nadia', 'role': 'sales', 'open': 1, 'won': 0, 'lost': 1, 'won_value': 0},
        ]},
      };
    }
    if (path.contains('/timeline')) {
      return {
        'ok': true,
        'insight': _bn ? '২ ইনবাউন্ড / ১ আউটবাউন্ড বার্তা; সর্বশেষ টোন: pos।' : '2 inbound / 1 outbound messages; last tone: pos.',
        'messages': mode == FakeMode.empty ? [] : [
          {'id': 1, 'direction': 'in', 'text': _bn ? 'ভ্যাট কমপ্লায়েন্ট ইআরপি লাগবে' : 'Need VAT-compliant ERP', 'sentiment': 'pos', 'at': '2026-10-10T09:00:00'},
          {'id': 2, 'direction': 'out', 'text': _bn ? 'ডেমো সেট করছি।' : 'Setting up a demo.', 'sentiment': 'neu', 'at': '2026-10-10T10:00:00'},
        ],
        'activities': mode == FakeMode.empty ? [] : [
          {'id': 1, 'kind': 'call', 'kind_display': _bn ? 'কল' : 'Call', 'subject': _bn ? 'প্রথম কল' : 'Intro call', 'body': '', 'created_at': '2026-10-12T10:00:00'},
        ],
      };
    }
    if (path.contains('/followup')) {
      return {
        'ok': true,
        'suggested_contact_date': '2026-10-14',
        'draft': _bn ? 'করিম গার্মেন্টস, Axon ERP নিয়ে আলোচনা করতে চাই।' : 'Karim Garments, we would love to discuss Axon ERP.',
        'draft_source': 'template',
      };
    }
    if (path.startsWith('/circle/') || path.startsWith('/journey/') || path.startsWith('/referral/')) {
      return const {}; // unmatched build-61 GET -> empty, never throw in gallery
    }
    // ===== a2-cctv QA batch 3: CRM lead detail + Money Wrapped =====
    if (RegExp(r'^/crm/leads/\d+/?$').hasMatch(path)) {
      if (mode == FakeMode.fail) _fail();
      return _crmLeads().first;
    }
    if (RegExp(r'^/crm/leads/\d+/timeline/?$').hasMatch(path)) {
      final b = _bn;
      return {
        'insight': b ? 'গ্রাহক দাম নিয়ে প্রশ্ন করেছেন — একটি ডেমো প্রস্তাব করুন।' : 'The customer asked about price — offer a demo.',
        'messages': [
          {'direction': 'in', 'sentiment': 'positive', 'text': b ? 'ভ্যাট রিপোর্ট সহ ইআরপি দরকার, দাম কত?' : 'We need ERP with VAT reports, what is the price?'},
          {'direction': 'out', 'sentiment': 'neutral', 'text': b ? 'আগামী সপ্তাহে একটি ডেমো দেখাতে পারি।' : 'We can show you a demo next week.'},
        ],
        'activities': [
          {'kind': 'call', 'kind_display': b ? 'কল' : 'Call', 'subject': b ? 'প্রথম কল' : 'Intro call', 'body': b ? 'বাজেট ৳৫-১০ লাখ' : 'Budget ৳5-10L', 'created_at': '2026-10-12T10:00:00'},
        ],
      };
    }
    if (path.startsWith('/money/wrapped')) {
      if (mode == FakeMode.fail) _fail();
      if (mode == FakeMode.empty) return {'enough_data': false, 'min_txns': 5, 'txn_count': 2, 'month': '2026-09'};
      return {
        'enough_data': true, 'month': '2026-09', 'txn_count': 64, 'category_count': 7,
        'total_spent': 18450, 'total_earned': 35000, 'total_saved': 16550, 'savings_rate': 47,
        'top_category': _bn ? 'খাবার' : 'Food', 'top_category_amount': 6400,
        'biggest_expense': {'category': _bn ? 'বাজার' : 'Groceries', 'amount': 3200, 'date': '2026-09-14'},
        'spend_trend': {'has_previous': true, 'up': false, 'pct': 12, 'delta': -2500},
        'no_spend_days': 6, 'days_in_scope': 30,
        'busiest_day': {'date': '2026-09-14', 'amount': 4100},
        'personality': 'steady_balancer',
      };
    }
    // ===== a2-cctv: Shop Box (CCTV Part 4) GET stubs =====
    final shop = _shopGet(path);
    if (shop != null) return shop;
    // p1-bizagent: Business AI Agent stubs
    final p1 = fakeBizAgentGet(path, _bn, mode);
    if (p1 != null) {
      if (mode == FakeMode.fail) _fail();
      return p1;
    }
    // ===== Business v2 (khata / selling / AI) GET stubs =====
    final biz = _businessGet(path);
    if (biz != null) return biz;
    // famcare: Family Care (circle pick, tasks, shopping, docs, limits)
    final fc = fakeFamCareGet(path, bn: _bn, empty: mode == FakeMode.empty);
    if (fc != null) {
      if (mode == FakeMode.fail) _fail();
      return fc;
    }
    // kidswatch: Kids watch + School Mode
    final kw = fakeKidsWatchGet(path, bn: _bn, empty: mode == FakeMode.empty);
    if (kw != null) {
      if (mode == FakeMode.fail) _fail();
      return kw;
    }
    return super.getJson(path);
  }

  // ---------------------------------------------------------- Business v2
  //
  // Money is integer POISHA. Display/status strings arrive as {bn,en} pairs the
  // screens render via `pair(context, ...)`. Owner responses carry cost/min/
  // profit; STAFF-redacted variants omit those keys entirely (the client treats
  // a missing cost/min as "redacted"). `role` is present where screens branch.

  bool get _staff => false; // gallery runs as owner; staff redaction shown via variant below

  Map<String, dynamic> _pair(String bn, String en) => {'bn': bn, 'en': en};

  List<Map<String, dynamic>> _bizProducts() => [
        {
          'id': 1, 'name': _bn ? 'পাঞ্জাবি' : 'Panjabi', 'category': _bn ? 'পোশাক' : 'Clothing',
          'sku': 'PANJ-01', 'barcode': '8900000000017', 'photo': '',
          'price': 120000, 'sell_price': 120000, 'cost_price': 80000, 'min_price': 100000,
          'stock': 8, 'profit': 40000, 'margin': 33, 'role': 'owner',
          'variants': [
            // owner sees cost/min; keys present
            {'id': 11, 'size': 'M', 'colour': _bn ? 'নীল' : 'Blue', 'stock': 5,
             'sell_price': 120000, 'cost_price': 80000, 'min_price': 100000},
            {'id': 12, 'size': 'L', 'colour': _bn ? 'সাদা' : 'White', 'stock': 3,
             'sell_price': 125000, 'cost_price': 82000, 'min_price': 105000},
          ],
        },
        {
          // STAFF-redacted row: cost_price / min_price / profit / margin ABSENT.
          'id': 2, 'name': _bn ? 'শাড়ি' : 'Saree', 'category': _bn ? 'পোশাক' : 'Clothing',
          'sku': 'SAR-02', 'barcode': '8900000000024', 'photo': '',
          'price': 250000, 'sell_price': 250000, 'stock': 0, 'role': 'staff',
          'variants': [
            {'id': 21, 'size': '', 'colour': _bn ? 'লাল' : 'Red', 'stock': 0, 'sell_price': 250000},
          ],
        },
      ];

  List<Map<String, dynamic>> _bizParties(String book) => [
        {
          'id': 1, 'name': _bn ? 'করিম স্টোর' : 'Karim Store', 'phone': '01712345678',
          'area': _bn ? 'মিরপুর' : 'Mirpur', 'vip': true, 'book': book,
          'balance_poisha': 150000, 'balance_display': _pair('৳1,500', '৳1,500'),
          'balance_status': _pair('বাকি', 'Due'),
        },
        {
          'id': 2, 'name': _bn ? 'রহিম ট্রেডার্স' : 'Rahim Traders', 'phone': '01812345678',
          'area': _bn ? 'ধানমন্ডি' : 'Dhanmondi', 'vip': false, 'book': book,
          'balance_poisha': 0, 'balance_display': _pair('৳0', '৳0'),
          'balance_status': _pair('পরিশোধিত', 'Settled'),
        },
      ];

  Map<String, dynamic> _bizNetPosition() => {
        'receivable_poisha': 150000, 'receivable_display': _pair('৳1,500', '৳1,500'),
        'payable_poisha': 90000, 'payable_display': _pair('৳900', '৳900'),
        'customer_advances_display': _pair('৳0', '৳0'),
        'supplier_advances_display': _pair('৳0', '৳0'),
        'net_poisha': 60000, 'net_display': _pair('৳600', '৳600'),
        'ahead': true,
      };

  Map<String, dynamic> _bizCashbox(String day) => {
        'day': day, 'reconciled': false,
        'opening_poisha': 500000, 'opening_display': _pair('৳5,000', '৳5,000'),
        'total_in_poisha': 320000, 'total_in_display': _pair('৳3,200', '৳3,200'),
        'total_out_poisha': 120000, 'total_out_display': _pair('৳1,200', '৳1,200'),
        'expected_poisha': 700000, 'expected_display': _pair('৳7,000', '৳7,000'),
        'counted_poisha': 700000, 'counted_display': _pair('৳7,000', '৳7,000'),
        'variance_poisha': 0, 'variance_display': _pair('৳0', '৳0'),
        'variance_status': _pair('মিলে গেছে', 'Balanced'),
        'entries': mode == FakeMode.empty ? const [] : [
          {'id': 1, 'kind': 'in', 'amount_display': _pair('৳3,200', '৳3,200'),
           'note': _bn ? 'নগদ বিক্রি' : 'Cash sales', 'at_display': _pair('সকাল ১০টা', '10:00 AM')},
          {'id': 2, 'kind': 'out', 'amount_display': _pair('৳1,200', '৳1,200'),
           'note': _bn ? 'সরবরাহকারীকে' : 'To supplier', 'at_display': _pair('দুপুর ২টা', '2:00 PM')},
        ],
      };

  List<Map<String, dynamic>> _bizOrders() => [
        {
          'id': 101, 'status': 'new', 'customer_name': _bn ? 'নাদিয়া' : 'Nadia',
          'customer_phone': '01712345678', 'total': '2400.00', 'items': 2,
          'cod_amount': 240000, 'courier': 'pathao', 'courier_live': false, 'tracking': '',
          'line': _bn ? 'অর্ডার #101: অর্ডার নেওয়া হয়েছে' : 'Order #101: order received',
        },
        {
          'id': 102, 'status': 'shipped', 'customer_name': _bn ? 'সুমন' : 'Sumon',
          'customer_phone': '01812345678', 'total': '1250.00', 'items': 1,
          'cod_amount': '1250.00', 'courier': 'steadfast', 'courier_live': false,
          'tracking': 'SF-998877',
          'line': _bn ? 'অর্ডার #102: কুরিয়ারে পাঠানো হয়েছে' : 'Order #102: shipped via courier',
        },
      ];

  List<Map<String, dynamic>> _bizThreads() => [
        {
          'id': 1, 'customer_name': _bn ? 'নাদিয়া' : 'Nadia', 'channel': 'whatsapp',
          'needs_human': true, 'is_ai': true,
          'last_text': _bn ? 'দাম কি একটু কমানো যাবে?' : 'Can you lower the price a bit?',
        },
        {
          'id': 2, 'customer_name': _bn ? 'সুমন' : 'Sumon', 'channel': 'messenger',
          'needs_human': false, 'is_ai': true,
          'last_text': _bn ? 'ধন্যবাদ!' : 'Thanks!',
        },
      ];

  Map<String, dynamic>? _businessGet(String path) {
    if (!path.startsWith('/business/') && !path.startsWith('business/')) return null;
    if (mode == FakeMode.fail) _fail();
    final p = path.startsWith('/') ? path.substring(1) : path; // drop leading slash
    final bare = p.split('?').first; // strip query

    // profiles
    if (bare == 'business/profiles') {
      // the real server answers {businesses, selected_id} (ProfilesView);
      // 'profiles' kept for older callers.
      final rows = mode == FakeMode.empty ? const <Map<String, dynamic>>[] : [
        {'id': 1, 'name': _bn ? 'আমার দোকান' : 'My Shop', 'type': 'small_shop',
         'role': 'owner', 'has_staff': true, 'pay_method': 'bkash', 'pay_number': '01712345678',
         'is_premium': true, 'currency': 'BDT', 'selected': true},
      ];
      return {'businesses': rows, 'profiles': rows, 'selected_id': 1, 'role': 'owner'};
    }
    // products
    if (bare == 'business/products/' || bare == 'business/products') {
      return {'products': mode == FakeMode.empty ? const [] : _bizProducts(), 'role': 'owner'};
    }
    if (RegExp(r'^business/products/\d+/?$').hasMatch(bare)) {
      return {..._bizProducts().first, 'role': 'owner'};
    }
    // cart (client-held) — GET is just an empty seed; screen seeds locally.
    if (bare == 'business/cart/' || bare == 'business/cart') {
      return {'lines': const [], 'subtotal': 0, 'discount': 0, 'total': 0};
    }
    // customers
    if (bare == 'business/customers/' || bare == 'business/customers') {
      return {'customers': mode == FakeMode.empty ? const [] : [
        {'id': 1, 'name': _bn ? 'নাদিয়া' : 'Nadia', 'phone': '01712345678',
         'area': _bn ? 'মিরপুর' : 'Mirpur', 'address': '', 'vip': true,
         'dues_display': _pair('৳500', '৳500')},
      ], 'role': 'owner'};
    }
    if (RegExp(r'business/customers/.+/history/?$').hasMatch(bare)) {
      return {
        'customer': {'name': _bn ? 'নাদিয়া' : 'Nadia', 'phone': '01712345678'},
        'dues_display': _pair('৳500', '৳500'),
        'purchases': mode == FakeMode.empty ? const [] : [
          {'id': 1, 'total_display': _pair('৳1,200', '৳1,200'), 'at_display': _pair('১২ অক্টো', '12 Oct')},
        ],
      };
    }
    // ledger100: khata in the server's real shape (fake_khata.dart)
    final khG = fakeKhataGet(bare, p.contains('?') ? p.split('?').last : '',
        bn: _bn, empty: mode == FakeMode.empty);
    if (khG != null) return khG;
    // khata (legacy shapes, unreachable now — kept for reference)
    if (bare == 'business/khata/parties') {
      final book = Uri.parse('http://x/$path').queryParameters['book'] ?? 'customer';
      return {'parties': mode == FakeMode.empty ? const [] : _bizParties(book), 'role': 'owner'};
    }
    if (bare == 'business/khata/net-position') {
      return _bizNetPosition();
    }
    if (RegExp(r'business/khata/parties/\d+/statement$').hasMatch(bare)) {
      return {
        'opening_display': _pair('৳0', '৳0'), 'closing_display': _pair('৳1,500', '৳1,500'),
        'total_gave_display': _pair('৳2,000', '৳2,000'),
        'total_got_display': _pair('৳500', '৳500'),
        'rows': mode == FakeMode.empty ? const [] : [
          {'date': '2026-10-01', 'particulars': _bn ? 'বিক্রি' : 'Sale',
           'debit_display': _pair('৳2,000', '৳2,000'), 'credit_display': _pair('', ''),
           'balance_display': _pair('৳2,000', '৳2,000')},
          {'date': '2026-10-10', 'particulars': _bn ? 'পরিশোধ' : 'Payment',
           'debit_display': _pair('', ''), 'credit_display': _pair('৳500', '৳500'),
           'balance_display': _pair('৳1,500', '৳1,500')},
        ],
      };
    }
    if (bare == 'business/khata/tagada/schedule') {
      return {'reminders': mode == FakeMode.empty ? const [] : [
        {'id': 1, 'name': _bn ? 'করিম স্টোর' : 'Karim Store', 'tone': 'polite',
         'amount_display': _pair('৳1,500', '৳1,500'), 'sms': false, 'whatsapp': true},
      ]};
    }
    // cashbox
    if (RegExp(r'business/cashbox/[^/]+/entries$').hasMatch(bare)) {
      final day = bare.split('/')[2];
      return {'entries': _bizCashbox(day)['entries']};
    }
    if (RegExp(r'^business/cashbox/[^/?]+$').hasMatch(bare)) {
      final day = bare.split('/')[2];
      return _bizCashbox(day);
    }
    // reports
    if (bare == 'business/reports/' || bare == 'business/reports') {
      return {
        'period': 'daily', 'role': 'owner',
        'total_sales': 365000, 'sales': 365000, 'profit': 120000, 'net_profit': 95000,
        'expenses': 25000,
        'by_payment': [
          {'method': 'cash', 'amount': 200000}, {'method': 'bkash', 'amount': 165000},
        ],
        'by_payment_method': [
          {'method': 'cash', 'amount': 200000}, {'method': 'bkash', 'amount': 165000},
        ],
        'top_products': [
          {'name': _bn ? 'পাঞ্জাবি' : 'Panjabi', 'qty': 3, 'amount': 360000},
        ],
        'top_customers': [
          {'name': _bn ? 'নাদিয়া' : 'Nadia', 'amount': 240000},
        ],
      };
    }
    // AI
    if (bare == 'business/ai/threads') {
      return {'threads': mode == FakeMode.empty ? const [] : _bizThreads(), 'role': 'owner'};
    }
    if (RegExp(r'^business/ai/threads/\d+$').hasMatch(bare)) {
      return {
        'id': int.tryParse(bare.split('/').last) ?? 1,
        'owner_takeover': false,
        'messages': mode == FakeMode.empty ? const [] : [
          {'id': 1, 'direction': 'in', 'is_ai': false,
           'text': _bn ? 'দাম কত?' : 'What is the price?', 'at_display': _pair('সকাল ৯টা', '9:00 AM')},
          {'id': 2, 'direction': 'out', 'is_ai': true, 'confidence': 0.82,
           'text': _bn ? 'পাঞ্জাবি ৳1,200।' : 'Panjabi is ৳1,200.', 'at_display': _pair('সকাল ৯টা', '9:01 AM')},
        ],
      };
    }
    if (bare == 'business/ai/channels') {
      // db1: same shape as backend business_views (per-channel dicts).
      return {'whatsapp_cloud': {'connected': false, 'needs_key': true, 'number': null},
              'messenger': {'connected': false, 'needs_key': true, 'page': null}};
    }
    if (bare == 'business/ai/insights') {
      return {'insights': mode == FakeMode.empty ? const [] : [
        {'kind': 'sales_down', 'text': _bn ? 'পাঞ্জাবি বিক্রি ১৫% কমেছে।' : 'Panjabi sales down 15%.'},
      ]};
    }
    // bargain
    if (bare == 'business/bargain/rules') {
      return {'rules': mode == FakeMode.empty ? const [] : [
        {'id': 1, 'product_id': 1, 'product_name': _bn ? 'পাঞ্জাবি' : 'Panjabi',
         'list_price': 120000, 'min_price': 100000, 'discount_steps': [5, 10],
         'free_delivery_over': 200000, 'bundle_min_qty': 3, 'tone': _bn ? 'ভদ্র' : 'Polite'},
      ], 'role': 'owner'};
    }
    if (RegExp(r'^business/bargain/rules/\d+$').hasMatch(bare)) {
      return {'id': 1, 'product_id': 1, 'product_name': _bn ? 'পাঞ্জাবি' : 'Panjabi',
              'list_price': 120000, 'min_price': 100000, 'discount_steps': [5, 10],
              'free_delivery_over': 200000, 'bundle_min_qty': 3, 'tone': _bn ? 'ভদ্র' : 'Polite'};
    }
    // orders
    if (bare == 'business/orders') {
      return {'orders': mode == FakeMode.empty ? const [] : _bizOrders(), 'role': 'owner'};
    }
    if (RegExp(r'^business/orders/\d+$').hasMatch(bare)) {
      // the detail view carries the item LIST (the list view only a count)
      return {..._bizOrders().first, 'items': [
        {'name': _bn ? 'পাঞ্জাবি' : 'Panjabi', 'qty': 1, 'price': '1200.00'},
        {'name': _bn ? 'শাড়ি' : 'Saree', 'qty': 1, 'price': '1200.00'},
      ], 'tracking': '', 'courier': '', 'courier_live': false};
    }
    // payments
    if (bare == 'business/payments/qr') {
      return {'provider': 'bkash', 'merchant_number': '01712345678',
              'merchant_name': _bn ? 'আমার দোকান' : 'My Shop', 'url': ''};
    }
    if (bare == 'business/payments/link') {
      return {'needs_key': true, 'url': '', 'provider': 'partner'};
    }
    // policies
    if (bare == 'business/policies') {
      return {'policies': const []};
    }
    return const {}; // unmatched business GET -> empty, never throw in gallery
  }

  // a2-cctv: Shop Box sample data (signals-only; no video anywhere).
  Map<String, dynamic>? _shopGet(String path) {
    if (!path.startsWith('/shop/')) return null;
    if (mode == FakeMode.fail) _fail();
    final b = _bn;
    final now = DateTime.now();
    final ago = now.subtract(const Duration(hours: 3)).toUtc().toIso8601String();
    if (path == '/shop/sites') {
      return {'sites': mode == FakeMode.empty ? [] : [
        {'id': 1, 'name': b ? 'মিরপুর শাখা' : 'Mirpur branch', 'snapshot_retention_days': 7,
         'cameras': 3, 'hours': {'open': '09:00', 'close': '22:00'}, 'pos_link': true,
         'last_seen': now.toUtc().toIso8601String(), 'online': true, 'created': '2026-10-01T10:00:00Z'},
        {'id': 2, 'name': b ? 'গুদাম' : 'Warehouse', 'snapshot_retention_days': 3,
         'cameras': 1, 'hours': {}, 'pos_link': false, 'last_seen': ago, 'online': false,
         'created': '2026-10-05T10:00:00Z'},
      ]};
    }
    if (RegExp(r'^/shop/sites/\d+/cameras$').hasMatch(path)) {
      return {'included': 4, 'used': 3, 'used_total': 4, 'extra_camera_credits': 20, 'cameras': [
        {'id': 1, 'name': b ? 'ক্যাশ কাউন্টার' : 'Cash counter', 'kind': 'shopbox', 'enabled': true,
         'online': true, 'last_seen': now.toUtc().toIso8601String(), 'live_capable': true,
         'restricted_zone': true, 'hours': null, 'zone_config': {}},
        {'id': 2, 'name': b ? 'পেছনের দরজা' : 'Back door', 'kind': 'edge_webhook', 'enabled': true,
         'online': false, 'last_seen': ago, 'live_capable': false, 'restricted_zone': true,
         'hours': {'open': '08:00', 'close': '23:00'}, 'zone_config': {}},
        {'id': 3, 'name': b ? 'স্টোর রুম' : 'Store room', 'kind': 'edge_webhook', 'enabled': false,
         'online': false, 'last_seen': null, 'live_capable': false, 'restricted_zone': false,
         'hours': null, 'zone_config': {}},
      ]};
    }
    if (RegExp(r'^/shop/sites/\d+/eod$').hasMatch(path)) {
      return {'today_cash_sales': 1854000, 'today_cash_sale_count': 37, 'tolerance': 5000,
        'checks': mode == FakeMode.empty ? [] : [
          {'id': 2, 'day': '2026-10-20', 'counted': 1520000, 'expected': 1545000, 'opening_float': 200000,
           'cash_sales': 1345000, 'tolerance': 5000, 'difference': -25000, 'status': 'short', 'note': '', 'event_id': 9},
          {'id': 1, 'day': '2026-10-19', 'counted': 1210000, 'expected': 1212000, 'opening_float': 200000,
           'cash_sales': 1012000, 'tolerance': 5000, 'difference': -2000, 'status': 'ok', 'note': '', 'event_id': null},
        ]};
    }
    if (RegExp(r'^/shop/cameras/\d+$').hasMatch(path)) {
      return {'id': 1, 'name': b ? 'ক্যাশ কাউন্টার' : 'Cash counter', 'camera_token': 'demo-cam-token-xyz',
        'enabled': true, 'online': true, 'restricted_zone': true, 'hours': null};
    }
    if (path.startsWith('/shop/events')) {
      return {'site': 1, 'events': [
        {'id': 9, 'type': 'eod_mismatch', 'confidence': 0.62, 'possible': false, 'pos_matched': false,
         'status': 'open', 'signals': {'reason': ['eod_mismatch', 'short_by_25000']}, 'snapshot_url': null,
         'camera': null, 'created': ago},
      ]};
    }
    if (path.startsWith('/shop/summary')) {
      return {'site': 1, 'days': 7, 'total_events': 4, 'by_type': {'after_hours': 1, 'void_spike': 1,
        'eod_mismatch': 1, 'motion': 1}, 'open': 2, 'false_alarms': 1, 'after_hours': 1,
        'exceptions': {'voids': 5, 'refunds': 0, 'discounts': 11, 'drawer_opens': 0},
        'pos_by_kind': {'sale': 212, 'void': 5, 'discount': 11}, 'camera_only': false};
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    final p = (path.startsWith('/') ? path.substring(1) : path).split('?').first;
    final kh = fakeKhataPost(p, body, bn: _bn); // ledger100
    if (kh != null) return kh;
    return super.postJsonRaw(path, body);
  }

  @override
  Future<Map<String, dynamic>> deleteJson(String path) async {
    if (path.contains('/business/khata/tagada/schedule/')) {
      return {'ok': true}; // ledger100
    }
    return super.deleteJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    if (path == '/account/delete/preview') {
      return {'counts': {'memories': 42, 'reminders': 12, 'documents': 5, 'txns': 230, 'accounts': 3, 'auth_token': 1, 'notif_events': 88},
              'export_downloaded': false, 'grace_days': 7};
    }
    final p1P = fakeBizAgentPost(path, body, _bn); // p1-bizagent
    if (p1P != null) return p1P;
    final khP = fakeKhataPost(
        (path.startsWith('/') ? path.substring(1) : path).split('?').first, body,
        bn: _bn); // ledger100
    if (khP != null) {
      if (mode == FakeMode.fail) _fail();
      return khP;
    }
    final vehP = fakeVehiclePost(path, body, _bn); // v1-vehicle
    if (vehP != null) return vehP;
    final c1P = fakeC1Post(path, body); // c1-contacts
    if (c1P != null) return c1P;
    if (path == '/shop/live/start') {
      // the honest offline state the server answers (409 device_offline)
      throw ApiException(
          _bn
              ? 'শপ বক্স ডিভাইসটি এখন অফলাইন — ফোন/পিসি চালু ও ইন্টারনেটে আছে কিনা দেখুন।'
              : 'The Shop Box device is offline right now — check that the phone/PC is on and connected.',
          409);
    }
    // ===== Module 5 (P13+) stubs =====
    if (path.startsWith('/health/tips/emergency')) {
      return {'emergency': false, 'matched': const [],
              'action': _bn ? 'জরুরি লক্ষণ নেই—সমস্যা থাকলে ডাক্তার দেখান।' : 'No red flags — see a doctor if it persists.'};
    }
    if (path == '/birthdays') {
      return {'id': 99, ...body};
    }
    if (path.endsWith('/delete') && path.startsWith('/birthdays/')) {
      return {'ok': true};
    }
    if (path.startsWith('/birthdays/drafts')) {
      return {'drafts': [
        {'style': 'warm', 'text': _bn ? 'শুভ জন্মদিন!' : 'Happy birthday!'},
        {'style': 'short', 'text': _bn ? 'শুভেচ্ছা রইল।' : 'Best wishes.'},
      ], 'card': {'title': _bn ? 'শুভ জন্মদিন' : 'Happy birthday',
                  'body': _bn ? 'সুস্থ ও সুখী থাকুন।' : 'Stay healthy and happy.'}};
    }
    if (path.startsWith('/ramadan/eid-card')) {
      return {'text': _bn ? 'ঈদ মোবারক! — আপনার শুভাকাঙ্ক্ষী' : 'Eid Mubarak! — from a well-wisher'};
    }
    if (path.startsWith('/exam/watcher')) {
      return {'id': 1, ...body};
    }
    if (path.startsWith('/auth/reset/request')) {
      return {'message': _bn ? 'অ্যাকাউন্ট থাকলে একটি রিসেট লিংক পাঠানো হয়েছে।' : 'If an account exists, a reset link has been sent.'};
    }
    if (path.startsWith('/auth/reset/confirm')) {
      return {'ok': true, 'message': _bn ? 'পাসওয়ার্ড পরিবর্তন হয়েছে।' : 'Password changed.'};
    }
    if (path.startsWith('/analytics/ingest')) {
      return {'accepted': (body['events'] as List?)?.length ?? 0};
    }
    if (path.startsWith('/photo/plan')) {
      final kind = body['kind'];
      final ownPhoto = body['own_photo'] == true;
      if (kind == 'document') {
        return {'allowed': false, 'reason': 'document_blocked', 'path': 'device', 'ops': const [],
                'message': _bn ? 'আইডি/দলিলের ছবি বদলানো হয় না।' : 'ID / document photos are never altered.'};
      }
      if (!ownPhoto) {
        return {'allowed': false, 'reason': 'not_own', 'path': 'device', 'ops': const [],
                'message': _bn ? 'শুধু নিজের ছবি এনহ্যান্স করা যাবে।' : 'You may only enhance your own photos.'};
      }
      return {'allowed': true, 'reason': 'ok', 'path': 'device',
              'ops': (body['ops'] as List?) ?? const [],
              'message': _bn ? 'এনহ্যান্স করা যাবে।' : 'Ready to enhance.'};
    }
    // build-61: place-call gate. Fake can't branch on free-caller video;
    // always returns the allowed-voice shape.
    if (path.startsWith('/circle/') && (path.endsWith('/call') || path.endsWith('/call/answer'))) {
      return {'allowed': true, 'call_id': 1, 'kind': body['kind'] ?? 'voice'};
    }
    if (path.startsWith('/circle/privacy')) {
      return {'ok': true, ...body};
    }
    if (path.startsWith('/circle/')) {
      // keys / request / act / sharing / report / messages / call events — accept gracefully.
      return {'ok': true, ...body};
    }
    // build-61: Safe Journey POST stubs (postJson-based paths).
    if (path.startsWith('/journey/start')) {
      return {'id': 1, 'web_link': 'https://assisto.app/j/tok'};
    }
    if (path.startsWith('/journey/')) {
      // /journey/<id>/location, /journey/<id>/stop, /journey/sos,
      // /journey/where-are-you, etc. — accept gracefully.
      return {'ok': true, 'status': 'active', ...body};
    }
    if (path.startsWith('/crm/extract')) {
      return {'ok': true, 'ai_available': false, 'phone': '01712345678', 'phones': [], 'whatsapp': '01712345678', 'email': 'buy@karim.com', 'company': 'Karim Garments Ltd', 'name': 'Karim'};
    }
    if (path.contains('/proposal/')) {
      return {'ok': false, 'needs_key': true, 'message': _bn ? 'চালু হবে যখন AI key যোগ হবে' : 'Available when an AI key is added'};
    }
    if (path.contains('/onboard/')) {
      return {'ok': false, 'message': _bn ? 'Axon ERP কানেক্ট হলে হ্যান্ড-অফ চালু হবে।' : 'Hand-off available when Axon ERP is connected.'};
    }
    final c100P = fakeCrm100Post(path, body); // crm100
    if (c100P != null) return c100P;
    if (path.startsWith('/crm/')) return {'ok': true, ...body};
    // ===== Business v2 POST stubs =====
    final biz = _businessPost(path, body);
    if (biz != null) return biz;
    return super.postJson(path, body);
  }

  // Stateless cart: take the client cart under `cart`, return the updated cart
  // under `cart`. A sentinel below-min unit price (1 poisha / "0.01") triggers a
  // 422 `below_min`; a discount preview sets `discount_clamped: true`.
  Map<String, dynamic>? _businessPost(String path, Map<String, dynamic> body) {
    if (!path.startsWith('/business/') && !path.startsWith('business/')) return null;
    if (mode == FakeMode.fail) _fail();
    final p = (path.startsWith('/') ? path.substring(1) : path).split('?').first;

    Map<String, dynamic> cartIn() {
      final c = body['cart'];
      return c is Map ? c.cast<String, dynamic>() : <String, dynamic>{};
    }
    Map<String, dynamic> wrapCart(Map<String, dynamic> cart,
            [Map<String, dynamic>? line]) =>
        {'cart': cart, if (line != null) 'line': line};

    bool isBelowMinSentinel() {
      final up = body['unit_price']?.toString();
      return up == '0.01' || up == '1' || up == '0'; // sentinel below-min input
    }

    // ---- cart/add/ ----
    if (p == 'business/cart/add/') {
      if (isBelowMinSentinel()) {
        throw BelowMinException(
            _bn ? 'ন্যূনতম মূল্যের নিচে বিক্রি করা যাবে না' : 'Cannot sell below the minimum price',
            'below_min');
      }
      final cart = cartIn();
      final lines = ((cart['lines'] ?? const []) as List).cast<Map<String, dynamic>>().toList();
      final line = {
        'id': lines.length + 1, 'product': body['product'], 'variant': body['variant'],
        'product_name': _bn ? 'পাঞ্জাবি' : 'Panjabi', 'size': 'M', 'colour': _bn ? 'নীল' : 'Blue',
        'qty': body['qty'] ?? 1, 'unit_price': 120000, 'min_price': 100000,
      };
      lines.add(line);
      final subtotal = lines.fold<int>(0, (a, l) =>
          a + ((l['unit_price'] ?? 0) as int) * ((l['qty'] ?? 1) as num).toInt());
      return wrapCart({'lines': lines, 'subtotal': subtotal, 'discount': 0, 'total': subtotal}, line);
    }
    // ---- cart/line/{id}/price/ ----
    if (RegExp(r'^business/cart/line/\d+/price/$').hasMatch(p)) {
      if (isBelowMinSentinel()) {
        throw BelowMinException(
            _bn ? 'ন্যূনতম মূল্যের নিচে বিক্রি করা যাবে না' : 'Cannot sell below the minimum price',
            'below_min');
      }
      final cart = cartIn();
      return wrapCart(cart);
    }
    // ---- cart/line/{id}/qty/ , /remove/ ----
    if (RegExp(r'^business/cart/line/\d+/(qty|remove)/$').hasMatch(p)) {
      final id = int.tryParse(p.split('/')[3]) ?? 0;
      final cart = cartIn();
      var lines = ((cart['lines'] ?? const []) as List).cast<Map<String, dynamic>>().toList();
      if (p.endsWith('/remove/')) {
        lines = lines.where((l) => l['id'] != id).toList();
      } else {
        for (final l in lines) {
          if (l['id'] == id) l['qty'] = body['qty'] ?? l['qty'];
        }
      }
      final subtotal = lines.fold<int>(0, (a, l) =>
          a + ((l['unit_price'] ?? 0) as int) * ((l['qty'] ?? 1) as num).toInt());
      return wrapCart({'lines': lines, 'subtotal': subtotal, 'discount': 0, 'total': subtotal});
    }
    // ---- cart/discount/preview/ (clamped, NOT a 422) ----
    if (p == 'business/cart/discount/preview/') {
      final cart = cartIn();
      final subtotal = poishaOf(cart['subtotal'] ?? cart['total']);
      const discount = 5000; // clamped to the min floor
      return {
        'cart': {...cart, 'discount': discount, 'total': (subtotal - discount).clamp(0, 1 << 62)},
        'discount_clamped': true,
      };
    }
    // ---- sales/checkout/ ----
    if (p == 'business/sales/checkout/') {
      final cart = cartIn();
      final total = poishaOf(cart['total'] ?? cart['subtotal']);
      final paid = int.tryParse(((body['paid'] ?? '0').toString().replaceAll('.', ''))) ?? total;
      return {
        'id': 5001, 'role': 'owner', 'payment_method': body['payment_method'],
        'lines': ((cart['lines'] ?? const []) as List),
        'subtotal': poishaOf(cart['subtotal'] ?? cart['total']),
        'discount': poishaOf(cart['discount']),
        'total': total,
        'change': (paid - total).clamp(0, 1 << 62),
        'due': (total - paid).clamp(0, 1 << 62),
        'discount_clamped': false,
      };
    }
    // ---- profiles select / create ----
    if (p == 'business/profiles' || p == 'business/profiles/select') {
      return {'id': 1, 'role': 'owner', ...body};
    }
    // ---- products create / update / variants ----
    if (p == 'business/products/' || RegExp(r'^business/products/\d+/$').hasMatch(p)) {
      return {'id': 1, 'role': 'owner', ...body};
    }
    if (RegExp(r'^business/products/\d+/variants/$').hasMatch(p)) {
      return {'id': 31, ...body};
    }
    if (p == 'business/products/import/') {
      return {
        'products': [
          {'name': _bn ? 'নতুন পণ্য' : 'New product', 'sell_price': 50000, 'stock': 10},
        ],
        'bad_rows': const [], 'conflicts': const [],
      };
    }
    // ---- customers save / dedupe ----
    if (p == 'business/customers/') return {'id': 1, 'role': 'owner', ...body};
    if (p == 'business/customers/dedupe/') return {'merged': 0};
    // ---- khata entries / payments / tagada ----
    if (RegExp(r'^business/khata/parties(/\d+/(entries|payment))?$').hasMatch(p)) {
      return {
        'id': 99, 'role': 'owner',
        'balance_display': _pair('৳1,500', '৳1,500'),
        'balance_status': _pair('বাকি', 'Due'),
        'entry_added_message': _pair(
            _bn ? 'করিম স্টোর, আপনার খাতায় ৳1,500 বাকি যোগ হলো।' : 'Karim Store, ৳1,500 was added to your due.',
            'Karim Store, ৳1,500 was added to your due.'),
        ...body,
      };
    }
    if (p.startsWith('business/khata/tagada/')) {
      return {'ok': true, 'count': 1, 'sms': false, 'whatsapp': true, ...body};
    }
    // ---- cashbox opening / reconcile ----
    if (RegExp(r'^business/cashbox/[^/]+/(opening|reconcile)$').hasMatch(p)) {
      final day = p.split('/')[2];
      final cb = _bizCashbox(day);
      if (p.endsWith('/reconcile')) cb['reconciled'] = true;
      return cb;
    }
    // ---- orders advance / parcel ----
    if (RegExp(r'^business/orders/\d+/advance$').hasMatch(p)) {
      return {..._bizOrders().first, 'status': body['status'] ?? 'confirmed'};
    }
    if (RegExp(r'^business/orders/\d+/parcel$').hasMatch(p)) {
      return {
        'courier_live': false, 'tracking': 'SF-998877',
        'line': _bn ? 'অর্ডার #101: কুরিয়ারে পাঠানো হয়েছে' : 'Order #101: shipped via courier',
      };
    }
    // ---- AI reply / send / takeover / bargain / disclose / voice / paper / payment-match / morning ----
    if (p == 'business/ai/reply' || RegExp(r'^business/ai/threads/\d+/send$').hasMatch(p)) {
      return {
        'text': _bn ? 'পাঞ্জাবি ৳1,200। ফ্রি ডেলিভারি সহ।' : 'Panjabi is ৳1,200 with free delivery.',
        'confidence': 0.82, 'needs_human': false, 'handoff_reason': '',
        'is_ai': true,
        'disclosure': _pair(_bn ? 'আমি দোকানের এআই সহকারী।' : "I'm the shop's AI assistant.",
            "I'm the shop's AI assistant."),
      };
    }
    if (RegExp(r'^business/ai/threads/\d+/takeover$').hasMatch(p)) {
      return {'owner_takeover': true};
    }
    if (p == 'business/ai/bargain') {
      return {
        'text': _bn ? 'সর্বোচ্চ ছাড় দিয়ে ৳1,100।' : 'Best I can do is ৳1,100.',
        'price': 110000, 'confidence': 0.7, 'needs_human': false,
      };
    }
    if (p == 'business/ai/disclose') {
      return {'disclosure': _pair(
          _bn ? 'আমি দোকানের এআই সহকারী।' : "I'm the shop's AI assistant.",
          "I'm the shop's AI assistant.")};
    }
    if (p == 'business/ai/voice-entry' || p == 'business/ai/paper-khata') {
      return {'draft': true, 'count': 2, 'entries': const []};
    }
    if (p == 'business/ai/match-payment') {
      return {'matched': true, 'name': _bn ? 'নাদিয়া' : 'Nadia', 'amount_display': _pair('৳500', '৳500')};
    }
    if (p == 'business/ai/morning-summary') {
      return {'text': _bn ? 'সুপ্রভাত! ৩ মেসেজ, ২ অর্ডার।' : 'Good morning! 3 messages, 2 orders.'};
    }
    // ---- bargain rules upsert ----
    if (p.startsWith('business/bargain/rules')) {
      return {'id': 1, 'role': 'owner', ...body};
    }
    // ---- payments qr/link, outbound, webhook, policies ----
    if (p == 'business/payments/qr') return {'provider': 'bkash', 'merchant_number': '01712345678', ...body};
    if (p == 'business/payments/link') return {'needs_key': true, 'url': ''};
    if (p == 'business/policies') return {'ok': true, ...body};
    return {'ok': true, ...body}; // unmatched business POST -> accept gracefully
  }

  @override
  Future<void> deleteItem(String path, int id) async {
    if (path.startsWith('business/') || path.startsWith('/business/')) {
      if (mode == FakeMode.fail) _fail();
      return; // business deletes succeed silently in the gallery
    }
    return super.deleteItem(path, id);
  }

  @override
  Future<Map<String, dynamic>> homeDefaults() async =>
      {'quick_buttons': HomeQuickButtons.defaults, 'count': 6};

  // ---- chat history (Assisto AI chats page + home persistence previews) ----
  // A small mutable store so rename / pin / delete flows are testable; every
  // call is recorded in [chatCalls].
  List<Map<String, dynamic>>? _chatStore;
  final List<String> chatCalls = [];

  List<Map<String, dynamic>> get _chats => _chatStore ??= [
      {'id': 11, 'title': _bn ? 'কাল সকালে মাকে ফোন' : 'Call mom tomorrow morning', 'pinned': true, 'source': 'home', 'snippet': '', 'updated': '2026-10-20T09:00:00Z'},
      {'id': 12, 'title': _bn ? 'এই মাসের খরচের হিসাব' : "This month's spending", 'pinned': false, 'source': 'home', 'snippet': '', 'updated': '2026-10-19T18:00:00Z'},
      {'id': 13, 'title': _bn ? 'দোকানের অফারের পোস্ট লেখা' : 'Write a shop offer post', 'pinned': false, 'source': 'ai', 'snippet': '', 'updated': '2026-10-18T12:00:00Z'},
      {'id': 14, 'title': _bn ? 'বিদ্যুৎ বিল কবে দিতে হবে' : 'When is the electricity bill due', 'pinned': false, 'source': 'home', 'snippet': '', 'updated': '2026-10-17T08:00:00Z'},
      {'id': 15, 'title': _bn ? 'চাকরির আবেদনপত্র' : 'Job application letter', 'pinned': false, 'source': 'ai', 'snippet': '', 'updated': '2026-10-15T08:00:00Z'},
    ];

  @override
  Future<List<Map<String, dynamic>>> chatSessions({String? query}) async {
    await _slow();
    chatCalls.add('list:${query ?? ''}');
    final q = (query ?? '').trim().toLowerCase();
    return _maybe([
      for (final r in _chats)
        if (q.isEmpty || '${r['title']}'.toLowerCase().contains(q)) Map.of(r),
    ]);
  }

  @override
  Future<Map<String, dynamic>> chatUpdateSession(String id,
      {String? title, bool? pinned, bool? archived}) async {
    if (mode == FakeMode.fail) _fail();
    chatCalls.add('update:$id:${title ?? ''}:${pinned ?? ''}');
    final r = _chats.firstWhere((r) => '${r['id']}' == id, orElse: () => {});
    if (title != null) r['title'] = title;
    if (pinned != null) r['pinned'] = pinned;
    return Map.of(r);
  }

  @override
  Future<void> chatDeleteSession(String id) async {
    if (mode == FakeMode.fail) _fail();
    chatCalls.add('delete:$id');
    _chats.removeWhere((r) => '${r['id']}' == id);
  }

  // aivoice: mirrors LIVE today (no AI key): the AI chat shows its honest
  // "no AI key yet — this still works free" banner.
  @override
  Future<Map<String, dynamic>> chatStatus() async {
    if (mode == FakeMode.fail) _fail();
    return {
      'ai_available': false,
      'reason': 'no_key',
      'free': ['own_data', 'app_help', 'phone_commands', 'voice_input'],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> chatMessages(String sessionId) async {
    await _slow();
    return _maybe([
      {'id': 1, 'role': 'user', 'text': _bn ? 'কাল সকাল ৯টায় মাকে ফোন করতে মনে করিয়ে দিও' : 'Remind me to call mom tomorrow at 9am', 'meta': {}},
      {'id': 2, 'role': 'assistant', 'text': _bn ? 'রিমাইন্ডার সেট করেছি।' : 'Reminder set.', 'meta': {
        'cards': [
          {'type': 'reminder', 'title': _bn ? 'মাকে ফোন' : 'Call mom', 'subtitle': '2026-10-21 09:00', 'model': 'reminder', 'id': 7, 'undo': true}
        ]
      }},
    ]);
  }
}
