/// remhbar — the Bangla calendar (বঙ্গাব্দ) as used in Bangladesh: the
/// Bangla Academy's revised calendar (in force from 1426 / 2019).
///
///  * Pohela Boishakh (1 Boishakh) is ALWAYS 14 April.
///  * Boishakh … Ashwin (the first six months) have 31 days; Kartik,
///    Agrahayan, Poush, Magh and Chaitra 30; Falgun 29, or 30 when that
///    Gregorian year is a leap year.
///  * Checks: 21 February = 8 Falgun, 26 March = 12 Chaitra,
///    16 December = 1 Poush (the national days line up every year).
///
/// Pure (no Flutter, no clock): callers pass the date. West Bengal's
/// (Surya Siddhanta) calendar differs by a day or so — we never claim it.
class BanglaDate {
  const BanglaDate(this.year, this.month, this.day);

  /// Bangla year (e.g. 1433).
  final int year;

  /// 1 = Boishakh … 12 = Chaitra.
  final int month;
  final int day;

  static const monthsBn = <String>[
    'বৈশাখ', // Boishakh
    'জ্যৈষ্ঠ', // Joishtho
    'আষাঢ়', // Asharh
    'শ্রাবণ', // Shrabon
    'ভাদ্র', // Bhadro
    'আশ্বিন', // Ashwin
    'কার্তিক', // Kartik
    'অগ্রহায়ণ', // Agrahayan
    'পৌষ', // Poush
    'মাঘ', // Magh
    'ফাল্গুন', // Falgun
    'চৈত্র', // Chaitra
  ];

  static const monthsEn = <String>[
    'Boishakh', 'Joishtho', 'Asharh', 'Shrabon', 'Bhadro', 'Ashwin',
    'Kartik', 'Agrahayan', 'Poush', 'Magh', 'Falgun', 'Chaitra',
  ];

  static bool _leap(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;

  /// The Bangla date of the calendar day of [d] (its local date; the time
  /// of day is ignored).
  static BanglaDate of(DateTime d) {
    final day = DateTime.utc(d.year, d.month, d.day);
    var startYear = d.year;
    if (day.isBefore(DateTime.utc(d.year, 4, 14))) startYear -= 1;
    final start = DateTime.utc(startYear, 4, 14);
    var left = day.difference(start).inDays; // 0-based day of the year
    final lengths = <int>[
      31, 31, 31, 31, 31, 31, 30, 30, 30, 30,
      _leap(startYear + 1) ? 30 : 29, 30,
    ];
    var m = 0;
    while (m < 11 && left >= lengths[m]) {
      left -= lengths[m];
      m++;
    }
    return BanglaDate(startYear - 593, m + 1, left + 1);
  }

  static String _bnDigits(String s) {
    final b = StringBuffer();
    for (final r in s.runes) {
      b.writeCharCode(r >= 0x30 && r <= 0x39 ? 0x09E6 + (r - 0x30) : r);
    }
    return b.toString();
  }

  /// "১৭ কার্তিক ১৪৩৩" (bn) / "17 Kartik 1433" (en). [withYear] false drops
  /// the year.
  String format({required bool bn, bool withYear = true}) {
    final name = (bn ? monthsBn : monthsEn)[month - 1];
    final s = withYear ? '$day $name $year' : '$day $name';
    if (!bn) return s;
    return '${_bnDigits('$day')} $name${withYear ? ' ${_bnDigits('$year')}' : ''}';
  }
}

/// Bangla digits (০-৯) in [s] -> ASCII 0-9 (search: "500" finds "৫০০").
String asciiDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r >= 0x09E6 && r <= 0x09EF ? 0x30 + (r - 0x09E6) : r);
  }
  return b.toString();
}
