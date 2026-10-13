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
    if (path.startsWith('crm/')) return _crmList(path);
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
          {'id': 1, 'title': _bn ? 'স্কুল ফি' : 'School fee', 'item_type': 'fee', 'due_date': '2026-10-15'},
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
        'plan': 'premium', 'name_bn': _bn ? 'প্রিমিয়াম' : 'Premium',
        'unlimited_ai': true, 'ads': false, 'credits': 0,
        'trial_active': true, 'trial_until': '2026-10-20T00:00:00',
      };

  @override
  Future<List<Map<String, dynamic>>> plansPublic() async => _maybe([
        {'id': 'free', 'name': _bn ? 'ফ্রি' : 'Free', 'price': 0, 'cur': 'BDT', 'period': 'mo',
         'desc': _bn ? 'শুরু করার জন্য' : 'To get started',
         'benefits': _bn ? ['নিরাপত্তা সবসময় ফ্রি', 'দিনে ৩টি AI ক্রেডিট'] : ['Safety always free', '3 AI credits/day'],
         'unlimited_ai': false, 'ads': true, 'family': false},
        {'id': 'premium', 'name': _bn ? 'প্রিমিয়াম' : 'Premium', 'price': 299, 'cur': 'BDT', 'period': 'mo',
         'desc': _bn ? 'পুরো সহকারী' : 'The full assistant',
         'benefits': _bn ? ['আনলিমিটেড AI', 'বিজ্ঞাপন নেই', 'পরিবারের জন্য'] : ['Unlimited AI', 'No ads', 'For your family'],
         'unlimited_ai': true, 'ads': false, 'family': true},
        {'id': 'annual', 'name': _bn ? 'বার্ষিক' : 'Annual', 'price': 2990, 'cur': 'BDT', 'period': 'yr',
         'desc': _bn ? '২ মাস ফ্রি' : '2 months free',
         'benefits': _bn ? ['প্রিমিয়ামের সব', '২ মাস সাশ্রয়'] : ['Everything in Premium', 'Save 2 months'],
         'unlimited_ai': true, 'ads': false, 'family': true},
        {'id': 'business', 'name': _bn ? 'বিজনেস' : 'Business', 'price': 999, 'cur': 'BDT', 'period': 'mo',
         'desc': _bn ? 'দোকান ও সেলস' : 'Shop & sales',
         'benefits': _bn ? ['বিজনেস মোড', 'সেলস CRM'] : ['Business mode', 'Sales CRM'],
         'unlimited_ai': true, 'ads': false, 'family': true},
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
    return super.createItem(path, body);
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    await _slow();
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
    if (path.startsWith('/circle/members') || path.startsWith('/circle/requests')) {
      if (mode == FakeMode.fail) _fail();
      return {'results': const []}; // friendly empty state
    }
    if (path.startsWith('/circle/') && path.contains('/messages')) {
      return {'results': const []};
    }
    if (path.startsWith('/circle/invite')) {
      return {'token': 'fake-token', 'qr': 'assisto://i/fake-token'};
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
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
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
    if (path.startsWith('/circle/')) {
      // keys / request / act / sharing / report / messages — accept gracefully.
      return {'ok': true, ...body};
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
    if (path.startsWith('/crm/')) return {'ok': true, ...body};
    return super.postJson(path, body);
  }

}
