// p2food: fake /food/table + food/log + food/goal for the gallery and tests.
// Values are copied from backend/core/logic/food_table_data.py (the cited
// generated table) — not invented.

Map<String, dynamic> _dish(String id, String group, String bn, String en,
        {required bool bnLang,
        String src = '',
        String code = '',
        Map<String, num?>? per100,
        List<List<Object>> portions = const [],
        String note = ''}) =>
    {
      'id': id,
      'group': group,
      'name': bnLang ? bn : en,
      'name_bn': bn,
      'name_en': en,
      'syn': id,
      'has_value': per100 != null,
      'per100': per100 ??
          {'kcal': null, 'protein': null, 'fat': null, 'carb': null, 'fibre': null},
      'src': src,
      'code': code,
      'source': per100 == null
          ? ''
          : '${src == 'fct' ? (bnLang ? 'FCT বাংলাদেশ ২০১৩' : 'FCT Bangladesh 2013') : 'USDA FNDDS'} · $code',
      'note': note,
      'portions': [
        for (final p in portions)
          {'id': p[0], 'label': bnLang ? p[1] : p[2], 'g': p[3], 'approx': p[4]},
      ],
    };

Map<String, dynamic> fakeFoodTable({required bool bn, bool photoReady = false}) => {
      'photo_ready': photoReady,
      'disclaimer': bn
          ? 'এটি আনুমানিক হিসাব, চিকিৎসা-পরামর্শ নয়। ডায়েট বদলানোর আগে ডাক্তার বা পুষ্টিবিদের সাথে কথা বলুন।'
          : 'This is an estimate, not medical advice. Talk to a doctor or dietitian before changing your diet.',
      'hints': [
        {
          'text': bn
              ? 'প্লেটের অর্ধেক সবজি, এক-চতুর্থাংশ মাছ/মাংস/ডাল, এক-চতুর্থাংশ ভাত-রুটি।'
              : 'Fill half the plate with vegetables, a quarter with fish/meat/dal, a quarter with rice or ruti.',
          'src': 'American Diabetes Association — Diabetes Plate Method'
        },
      ],
      'sources': {
        'fct': {
          'short': bn ? 'FCT বাংলাদেশ ২০১৩' : 'FCT Bangladesh 2013',
          'cite': 'Shaheen N, Rahim ATMA, Mohiduzzaman M, et al. Food Composition Table for Bangladesh. INFS, University of Dhaka, 2013 (with FAO). ISBN 978-984-33-7522-3.',
        },
        'usda': {
          'short': 'USDA FNDDS',
          'cite': 'U.S. Department of Agriculture, Agricultural Research Service. FoodData Central — FNDDS (survey foods, release 2024-10-31). Public domain.',
        },
      },
      'goal': {'min': 800, 'max': 5000, 'default': 2000},
      'dishes': [
        _dish('bhat', 'rice', 'ভাত (সাদা)', 'Rice (white, boiled)',
            bnLang: bn, src: 'fct', code: '01_0041',
            per100: {'kcal': 111, 'protein': 2.1, 'fat': 0.11, 'carb': 24.81, 'fibre': 0.99},
            portions: [
              ['plate', '১ প্লেট (≈২ কাপ)', '1 plate (≈2 cups)', 316, true],
              ['cup', '১ কাপ', '1 cup', 158, false],
            ]),
        _dish('biriyani', 'rice', 'বিরিয়ানি / কাচ্চি (মাংস)', 'Biryani / kacchi (meat)',
            bnLang: bn, src: 'usda', code: '2706490',
            per100: {'kcal': 145, 'protein': 8.5, 'fat': 6.79, 'carb': 12.19, 'fibre': 1.0},
            portions: [
              ['plate', '১ প্লেট (≈২ কাপ)', '1 plate (≈2 cups)', 392, true],
            ],
            note: bn
                ? 'দেশি রান্নার মান নেই — বিদেশি রেসিপির মান। তেল বেশি হলে ক্যালরি বেশি।'
                : 'No Bangladeshi value — this is a foreign recipe. More oil means more calories.'),
        _dish('dal_mosur', 'dal', 'মসুর ডাল (সেদ্ধ, তেল ছাড়া)', 'Red lentil (boiled, no oil)',
            bnLang: bn, src: 'fct', code: '02_0015',
            per100: {'kcal': 155, 'protein': 13.59, 'fat': 0.39, 'carb': 21.16, 'fibre': 6.49},
            portions: [
              ['bati', '১ বাটি (১ কাপ)', '1 bowl (1 cup)', 180, false],
            ]),
        _dish('dudh_cha', 'drink', 'দুধ চা (চিনিসহ)', 'Milk tea (with sugar)',
            bnLang: bn, src: 'fct', code: '14_0007',
            per100: {'kcal': 41, 'protein': 0.73, 'fat': 0.78, 'carb': 7.59, 'fibre': 0.21},
            portions: [
              ['cup', '১ কাপ (≈১২৫ মিলি)', '1 cup (≈125 ml)', 125, true],
            ]),
        _dish('fuchka', 'snack', 'ফুচকা', 'Fuchka',
            bnLang: bn,
            portions: [
              ['plate', '১ প্লেট', '1 plate', 0, true],
            ],
            note: bn
                ? 'সূত্রসহ মান পাওয়া যায়নি — আমরা সংখ্যা বানাই না। চাইলে নিজে ক্যালরি লিখুন।'
                : 'No cited value found — we never make up a number. You can type the calories yourself.'),
      ],
    };

/// Log rows: today (bhat plate + milk tea + an uncited fuchka) and 3 earlier
/// days, so the week chart shows bars.
List<Map<String, dynamic>> fakeFoodLog(DateTime now) {
  String d(int ago) {
    final x = now.subtract(Duration(days: ago));
    return '${x.year.toString().padLeft(4, '0')}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> r(int id, int ago, String dish, String bn, String en, num? g,
          int? kcal, {String src = 'fct', String code = ''}) =>
      {
        'id': id, 'date': d(ago), 'dish': dish, 'name_bn': bn, 'name_en': en,
        'grams': g, 'kcal': kcal, 'protein': kcal == null ? null : 6.6,
        'fat': kcal == null ? null : 0.3, 'carb': kcal == null ? null : 78.4,
        'src': kcal == null ? '' : src, 'code': code,
        'source': kcal == null ? '' : 'FCT Bangladesh 2013 · $code',
        'self': false,
      };
  return [
    r(1, 3, 'bhat', 'ভাত (সাদা)', 'Rice (white, boiled)', 632, 702, code: '01_0041'),
    r(2, 2, 'bhat', 'ভাত (সাদা)', 'Rice (white, boiled)', 474, 526, code: '01_0041'),
    r(3, 1, 'bhat', 'ভাত (সাদা)', 'Rice (white, boiled)', 790, 877, code: '01_0041'),
    r(4, 0, 'bhat', 'ভাত (সাদা)', 'Rice (white, boiled)', 316, 351, code: '01_0041'),
    r(5, 0, 'dudh_cha', 'দুধ চা (চিনিসহ)', 'Milk tea (with sugar)', 125, 51, code: '14_0007'),
    r(6, 0, 'fuchka', 'ফুচকা', 'Fuchka', null, null),
  ];
}

/// GET hook: null when [path] is not ours.
Map<String, dynamic>? fakeFoodGet(String path, {required bool bn}) =>
    path.split('?').first == '/food/table' ? fakeFoodTable(bn: bn) : null;
