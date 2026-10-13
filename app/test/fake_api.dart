import 'package:assisto/api.dart';
import 'package:assisto/models.dart';

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
          {'id': 1, 'name': _bn ? 'আম্মা' : 'Mother', 'relation': _bn ? 'মা' : 'Mother', 'phone': '01710000000'},
          {'id': 2, 'name': _bn ? 'আব্বা' : 'Father', 'relation': _bn ? 'বাবা' : 'Father', 'phone': '01720000000'},
        ]);
      case 'medicines':
        return _maybe([
          {'id': 1, 'name': 'Napa', 'dosage': _bn ? '১টা' : '1 tab', 'times': ['08:00', '20:00'], 'refill_date': '2026-10-30'},
          {'id': 2, 'name': 'Losectil', 'dosage': _bn ? '১টা' : '1 tab', 'times': ['08:00'], 'refill_date': null},
        ]);
      case 'school':
        return _maybe([
          {'id': 1, 'title': _bn ? 'স্কুল ফি' : 'School fee', 'item_type': 'fee', 'due_date': '2026-10-15'},
        ]);
      case 'reminders':
        return _maybe([
          {'id': 1, 'title': _bn ? 'বিদ্যুৎ বিল' : 'Electricity bill', 'due_at': '2026-10-14T10:00:00', 'done': false},
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
      default:
        return _maybe([]);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> medicinesToday() async => _maybe([
        {'medicine_id': 1, 'name': 'Napa', 'slot': '08:00', 'taken': true, 'dosage': _bn ? '১টা' : '1 tab', 'refill_date': '2026-10-30'},
        {'medicine_id': 1, 'name': 'Napa', 'slot': '20:00', 'taken': false, 'dosage': _bn ? '১টা' : '1 tab', 'refill_date': '2026-10-30'},
        {'medicine_id': 2, 'name': 'Losectil', 'slot': '08:00', 'taken': false, 'dosage': _bn ? '১টা' : '1 tab', 'refill_date': null},
      ]);

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
  Future<Map<String, dynamic>> scamCheck(String message) async => {
        'emoji': '⚠️',
        'label': _bn ? 'সন্দেহজনক' : 'Suspicious',
        'reasons': _bn
            ? ['অজানা লিংক আছে', 'তাড়াহুড়ো করতে বলছে']
            : ['Contains an unknown link', 'Creates urgency'],
        'advice': _bn ? 'লিংকে ক্লিক করবেন না।' : "Don't tap the link.",
      };

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
        'plan': 'premium', 'name_bn': _bn ? 'প্রিমিয়াম' : 'Premium',
        'unlimited_ai': true, 'ads': false, 'credits': 0,
        'trial_active': true, 'trial_until': '2026-10-20T00:00:00',
      };

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
}
