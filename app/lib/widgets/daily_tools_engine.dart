import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'finance_calc.dart';

/// daily_tools_engine.dart — p2tools (flag `daily_tools`): the PURE, OFFLINE
/// maths behind the Daily tools screen (unit / land / weight converter,
/// currency with a user-entered rate, age, EMI flat vs reducing, zakat,
/// VAT / discount / percent, tip + split bill, BMI, Gregorian <-> Bangla
/// (Bangabda) <-> Hijri dates, word counter, dice / lottery).
///
/// No network, no clock (callers pass "now"), no Bangla literals (lang gate):
/// every label comes from the ARB in the screen. Unit factors are the
/// standard Bangladesh values (sources in FEATURE_CARD_QUICK_TOOLS_BN.md):
///   1 decimal (shotangsho / shotok) = 435.6 sq ft = 1/100 acre
///   1 katha = 720 sq ft (= 1.65 decimal), 1 bigha = 20 katha = 14,400 sq ft
///   1 bhori = 1 tola = 11.664 g = 16 ana = 96 rati
///   1 seer = 80 tola = 933.12 g, 1 maund (mon) = 40 seer = 37.3248 kg
///   1 hath (cubit) = 18 inch

// ------------------------------------------------------------------ numbers

/// Parse a user-typed number: Bangla digits (U+09E6..U+09EF) and ASCII both
/// work, thousands commas and spaces are ignored. Null when not a number.
double? parseNum(String? raw) {
  if (raw == null) return null;
  final b = StringBuffer();
  for (final r in raw.runes) {
    if (r >= 0x09E6 && r <= 0x09EF) {
      b.writeCharCode(0x30 + (r - 0x09E6));
    } else if (r == 0x2C || r == 0x20 || r == 0x09F3) {
      // comma, space and the taka sign are decoration
    } else {
      b.writeCharCode(r);
    }
  }
  final s = b.toString().trim();
  if (s.isEmpty) return null;
  final v = double.tryParse(s);
  if (v == null || v.isNaN || v.isInfinite) return null;
  return v;
}

/// South-Asian (lakh / crore) grouping: 12345678.5 -> "1,23,45,678.5".
/// [dp] = max decimals; trailing zeros are dropped. ASCII digits — the screen
/// converts to Bangla digits for a Bangla UI.
String fmtNum(double v, {int dp = 2}) {
  if (v.isNaN || v.isInfinite) return '-';
  final neg = v < 0;
  var s = v.abs().toStringAsFixed(dp);
  var intPart = s;
  var frac = '';
  final dot = s.indexOf('.');
  if (dot >= 0) {
    intPart = s.substring(0, dot);
    frac = s.substring(dot + 1).replaceAll(RegExp(r'0+$'), '');
  }
  String grouped;
  if (intPart.length <= 3) {
    grouped = intPart;
  } else {
    final last3 = intPart.substring(intPart.length - 3);
    var rest = intPart.substring(0, intPart.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    grouped = '${parts.join(',')},$last3';
  }
  s = frac.isEmpty ? grouped : '$grouped.$frac';
  return neg && s != '0' ? '-$s' : s;
}

/// A precision-friendly format for converted units: small values keep more
/// significant decimals (0.000123 stays readable), big ones 2-4 dp.
String fmtUnit(double v) {
  final a = v.abs();
  if (a == 0) return '0';
  if (a >= 1000) return fmtNum(v, dp: 2);
  if (a >= 1) return fmtNum(v, dp: 4);
  if (a >= 0.001) return fmtNum(v, dp: 6);
  return fmtNum(v, dp: 9);
}

// ------------------------------------------------------------------ units

class UnitDef {
  final String id;

  /// How many BASE units one of this unit is (area: sq ft, weight: gram,
  /// length: metre, volume: litre). Temperature is handled separately.
  final double toBase;
  const UnitDef(this.id, this.toBase);
}

/// Category id -> units (display order). Labels: ARB `dtU_<id>`.
const Map<String, List<UnitDef>> kUnitCats = {
  'land': [
    UnitDef('sqft', 1),
    UnitDef('sqm', 10.763910416709722),
    UnitDef('decimal', 435.6),
    UnitDef('katha', 720),
    UnitDef('bigha', 14400),
    UnitDef('acre', 43560),
    UnitDef('hectare', 107639.10416709722),
  ],
  'weight': [
    UnitDef('gram', 1),
    UnitDef('kg', 1000),
    UnitDef('rati', 0.1215),
    UnitDef('ana', 0.729),
    UnitDef('bhori', 11.664),
    UnitDef('seer', 933.12),
    UnitDef('maund', 37324.8),
    UnitDef('pound', 453.59237),
    UnitDef('ounce', 28.349523125),
    UnitDef('tonne', 1000000),
  ],
  'length': [
    UnitDef('cm', 0.01),
    UnitDef('inch', 0.0254),
    UnitDef('foot', 0.3048),
    UnitDef('hath', 0.4572),
    UnitDef('yard', 0.9144),
    UnitDef('metre', 1),
    UnitDef('km', 1000),
    UnitDef('mile', 1609.344),
  ],
  'volume': [
    UnitDef('ml', 0.001),
    UnitDef('litre', 1),
    UnitDef('gallon', 3.785411784),
    UnitDef('cuft', 28.316846592),
  ],
  'temp': [
    UnitDef('c', 1),
    UnitDef('f', 1),
    UnitDef('k', 1),
  ],
};

/// [v] in unit [from] -> unit [to] of category [cat]. Null on an unknown unit.
double? convertUnit(String cat, String from, String to, double v) {
  if (cat == 'temp') {
    double c;
    switch (from) {
      case 'c':
        c = v;
      case 'f':
        c = (v - 32) * 5 / 9;
      case 'k':
        c = v - 273.15;
      default:
        return null;
    }
    switch (to) {
      case 'c':
        return c;
      case 'f':
        return c * 9 / 5 + 32;
      case 'k':
        return c + 273.15;
      default:
        return null;
    }
  }
  final units = kUnitCats[cat];
  if (units == null) return null;
  UnitDef? a, b;
  for (final u in units) {
    if (u.id == from) a = u;
    if (u.id == to) b = u;
  }
  if (a == null || b == null) return null;
  return v * a.toBase / b.toBase;
}

/// Every unit of [cat] for [v] in [from] (the "show all" table).
Map<String, double> convertAll(String cat, String from, double v) => {
      for (final u in kUnitCats[cat] ?? const <UnitDef>[])
        u.id: convertUnit(cat, from, u.id, v) ?? double.nan,
    };

// ------------------------------------------------------------------ currency

/// Remittance + travel currencies people in Bangladesh actually use.
const List<String> kFxCodes = [
  'USD', 'SAR', 'AED', 'MYR', 'QAR', 'KWD', 'OMR', 'SGD', 'GBP', 'EUR', 'INR',
];

/// [amount] of foreign money at [bdtPerUnit] -> taka, or the reverse.
double fxConvert(double amount, double bdtPerUnit, {bool toBdt = true}) {
  if (bdtPerUnit <= 0) return 0;
  return toBdt ? round2(amount * bdtPerUnit) : round2(amount / bdtPerUnit);
}

// ------------------------------------------------------------------ age

class AgeResult {
  final int years, months, days, totalDays, totalWeeks, totalMonths;

  /// Days until the next birthday (0 = today is the birthday).
  final int nextBirthdayIn;
  const AgeResult(this.years, this.months, this.days, this.totalDays,
      this.totalWeeks, this.totalMonths, this.nextBirthdayIn);
}

int _daysIn(int y, int m) => DateTime.utc(y, m + 1, 0).day;

/// Exact age of someone born on [birth] on the calendar day [on]. Null when
/// [birth] is after [on]. A 29 Feb birthday counts 28 Feb in non-leap years.
AgeResult? ageOn(DateTime birth, DateTime on) {
  final b = DateTime.utc(birth.year, birth.month, birth.day);
  final o = DateTime.utc(on.year, on.month, on.day);
  if (b.isAfter(o)) return null;
  var y = o.year - b.year;
  var m = o.month - b.month;
  var d = o.day - b.day;
  if (d < 0) {
    m -= 1;
    final pm = o.month == 1 ? 12 : o.month - 1;
    final py = o.month == 1 ? o.year - 1 : o.year;
    d += _daysIn(py, pm);
  }
  if (m < 0) {
    y -= 1;
    m += 12;
  }
  final total = o.difference(b).inDays;
  DateTime bdayIn(int year) {
    final day = math.min(b.day, _daysIn(year, b.month));
    return DateTime.utc(year, b.month, day);
  }

  var next = bdayIn(o.year);
  if (next.isBefore(o)) next = bdayIn(o.year + 1);
  return AgeResult(y, m, d, total, total ~/ 7, y * 12 + m,
      next.difference(o).inDays);
}

// ------------------------------------------------------------------ EMI

class EmiCompare {
  final EmiResult reducing;
  final EmiResult flat;

  /// Extra total cost of the flat quote over the same nominal rate.
  double get flatExtra => round2(flat.total - reducing.total);

  /// The reducing-balance rate that costs the same as this flat rate
  /// (what the flat quote "really" is), by bisection; 0 when not solvable.
  final double flatEffectiveRate;
  const EmiCompare(this.reducing, this.flat, this.flatEffectiveRate);
}

EmiCompare emiCompare(double principal, double annualRatePct, int months) {
  final red = emiSchedule(principal, annualRatePct, months, 'reducing');
  final flat = emiSchedule(principal, annualRatePct, months, 'flat');
  var eff = 0.0;
  if (principal > 0 && months > 0 && annualRatePct > 0) {
    var lo = 0.0, hi = 200.0;
    for (var i = 0; i < 60; i++) {
      final mid = (lo + hi) / 2;
      final r = mid / 1200.0;
      final f = math.pow(1 + r, months).toDouble();
      final e = principal * r * f / (f - 1);
      if (e < flat.emi) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    eff = round2((lo + hi) / 2);
  }
  return EmiCompare(red, flat, eff);
}

// ------------------------------------------------------------------ zakat

/// Nisab weights (classical: gold 20 mithqal = 7.5 tola, silver 200 dirham
/// = 52.5 tola), in bhori (1 bhori = 1 tola = 11.664 g).
const double kNisabGoldBhori = 7.5;
const double kNisabSilverBhori = 52.5;

class ZakatCalc {
  final double nisabValue; // taka; 0 = price missing
  final double wealth;
  final double due;
  final bool aboveNisab;
  final bool priceMissing;
  const ZakatCalc(this.nisabValue, this.wealth, this.due, this.aboveNisab,
      this.priceMissing);
}

/// [basis] 'silver' (the lower, more cautious nisab most Bangladeshi scholars
/// and Islamic Foundation announcements use) or 'gold'. Prices are taka per
/// bhori, entered by the user (or filled from Assisto's BAJUS card).
ZakatCalc zakatCalc({
  required String basis,
  double goldPricePerBhori = 0,
  double silverPricePerBhori = 0,
  double cash = 0,
  double goldBhori = 0,
  double silverBhori = 0,
  double businessAndLent = 0,
  double debts = 0,
}) {
  final price = basis == 'gold' ? goldPricePerBhori : silverPricePerBhori;
  final nisab =
      price > 0 ? price * (basis == 'gold' ? kNisabGoldBhori : kNisabSilverBhori) : 0.0;
  final r = zakatFull(
    cash: cash,
    goldValue: goldBhori * goldPricePerBhori,
    silverValue: silverBhori * silverPricePerBhori,
    businessGoods: businessAndLent,
    debts: debts,
    nisab: nisab,
  );
  final missing = price <= 0;
  // Never claim zakat is due without a nisab to compare against.
  return ZakatCalc(round2(nisab), r.zakatable, missing ? 0 : r.due,
      missing ? false : r.aboveNisab, missing);
}

// ------------------------------------------------------------------ percent / VAT

class VatResult {
  final double base, vat, total;
  const VatResult(this.base, this.vat, this.total);
}

/// Add VAT on top of [amount] (exclusive price).
VatResult vatAdd(double amount, double ratePct) {
  final vat = round2(amount * ratePct / 100);
  return VatResult(round2(amount), vat, round2(amount + vat));
}

/// Take VAT out of a VAT-inclusive [total].
VatResult vatExtract(double total, double ratePct) {
  final base = round2(total / (1 + ratePct / 100));
  return VatResult(base, round2(total - base), round2(total));
}

/// Price after [pct] discount: (saving, final).
(double, double) discount(double price, double pct) {
  final save = round2(price * pct / 100);
  return (save, round2(price - save));
}

/// [part] is what % of [whole]. Null when whole is 0.
double? percentOf(double part, double whole) =>
    whole == 0 ? null : part * 100 / whole;

/// % change from [from] to [to]. Null when from is 0.
double? percentChange(double from, double to) =>
    from == 0 ? null : (to - from) * 100 / from.abs();

// ------------------------------------------------------------------ split bill

class SplitResult {
  final double tip, total, perPerson;

  /// Per person rounded UP to whole taka (what people actually hand over)
  /// and the extra that rounding collects.
  final int perPersonRounded;
  final double roundingExtra;
  const SplitResult(this.tip, this.total, this.perPerson, this.perPersonRounded,
      this.roundingExtra);
}

SplitResult? splitBill(double bill, int people, {double tipPct = 0}) {
  if (people <= 0 || bill < 0) return null;
  final tip = round2(bill * tipPct / 100);
  final total = round2(bill + tip);
  final per = round2(total / people);
  final up = (total / people - 1e-9).ceil();
  return SplitResult(tip, total, per, up, round2(up * people - total));
}

// ------------------------------------------------------------------ BMI

class BmiResult {
  final double bmi;

  /// 'under' | 'normal' | 'over' | 'obese' — WHO Asia-Pacific cut-offs
  /// (18.5 / 23 / 25), the ones Bangladeshi doctors use for South Asians.
  final String band;
  final double healthyMinKg, healthyMaxKg;
  const BmiResult(this.bmi, this.band, this.healthyMinKg, this.healthyMaxKg);
}

BmiResult? bmiCalc(double weightKg, double heightCm) {
  if (weightKg <= 0 || heightCm <= 0) return null;
  final h = heightCm / 100;
  final bmi = weightKg / (h * h);
  final band = bmi < 18.5
      ? 'under'
      : bmi < 23
          ? 'normal'
          : bmi < 25
              ? 'over'
              : 'obese';
  return BmiResult(double.parse(bmi.toStringAsFixed(1)), band,
      double.parse((18.5 * h * h).toStringAsFixed(1)),
      double.parse((22.9 * h * h).toStringAsFixed(1)));
}

/// feet + inches -> cm.
double feetInchToCm(double feet, double inch) => (feet * 12 + inch) * 2.54;

// ------------------------------------------------------------------ dates

int _g2jd(int y, int m, int d) {
  final a = (14 - m) ~/ 12;
  final y2 = y + 4800 - a;
  final m2 = m + 12 * a - 3;
  return d +
      (153 * m2 + 2) ~/ 5 +
      365 * y2 +
      y2 ~/ 4 -
      y2 ~/ 100 +
      y2 ~/ 400 -
      32045;
}

DateTime _jd2g(int jd) {
  final a = jd + 32044;
  final b = (4 * a + 3) ~/ 146097;
  final c = a - 146097 * b ~/ 4;
  final d = (4 * c + 3) ~/ 1461;
  final e = c - 1461 * d ~/ 4;
  final m = (5 * e + 2) ~/ 153;
  return DateTime.utc(100 * b + d - 4800 + m ~/ 10, m + 3 - 12 * (m ~/ 10),
      e - (153 * m + 2) ~/ 5 + 1);
}

/// A Hijri date from the TABULAR (arithmetic, "Kuwaiti") calendar. It is an
/// APPROXIMATION: the real date in Bangladesh follows the moon-sighting
/// committee and can differ by 1-2 days — the screen always says so.
class HijriDate {
  final int year, month, day;
  const HijriDate(this.year, this.month, this.day);

  static HijriDate of(DateTime g) {
    var l = _g2jd(g.year, g.month, g.day) - 1948440 + 10632;
    final n = (l - 1) ~/ 10631;
    l = l - 10631 * n + 354;
    final j = ((10985 - l) ~/ 5316) * ((50 * l) ~/ 17719) +
        (l ~/ 5670) * ((43 * l) ~/ 15238);
    l = l -
        ((30 - j) ~/ 15) * ((17719 * j) ~/ 50) -
        (j ~/ 16) * ((15238 * j) ~/ 43) +
        29;
    final m = (24 * l) ~/ 709;
    final d = l - (709 * m) ~/ 24;
    final y = 30 * n + j - 30;
    return HijriDate(y, m, d);
  }

  DateTime toGregorian() => _jd2g((11 * year + 3) ~/ 30 +
      354 * year +
      30 * month -
      (month - 1) ~/ 2 +
      day +
      1948440 -
      385);

  /// Month lengths of the tabular calendar (odd 30, even 29, Dhul-Hijjah 30
  /// in leap years) — used to validate typed dates.
  static int monthLength(int year, int month) {
    if (month % 2 == 1) return 30;
    if (month == 12 && (14 + 11 * year) % 30 < 11) return 30;
    return 29;
  }
}

/// Bangla (Bangabda, Bangla Academy revised) date -> Gregorian. Mirrors the
/// rules of services/bangla_calendar.dart (1 Boishakh = 14 April; months 1-6
/// 31 days, 7-10 and 12 30, Falgun 29 / 30 in a Gregorian leap year).
/// Null when the day does not exist.
DateTime? bangabdaToGregorian(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1) return null;
  final startYear = year + 593;
  bool leap(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
  final lengths = <int>[
    31, 31, 31, 31, 31, 31, 30, 30, 30, 30,
    leap(startYear + 1) ? 30 : 29, 30,
  ];
  if (day > lengths[month - 1]) return null;
  var offset = day - 1;
  for (var i = 0; i < month - 1; i++) {
    offset += lengths[i];
  }
  return DateTime.utc(startYear, 4, 14).add(Duration(days: offset));
}

/// Day of week 1 = Monday ... 7 = Sunday (DateTime.weekday).
int weekdayOf(DateTime d) => DateTime.utc(d.year, d.month, d.day).weekday;

// ------------------------------------------------------------------ words

class WordStats {
  final int words, banglaWords, englishWords, chars, charsNoSpace, sentences,
      paragraphs;

  /// Reading time in seconds at ~200 words per minute.
  final int readSeconds;
  const WordStats(this.words, this.banglaWords, this.englishWords, this.chars,
      this.charsNoSpace, this.sentences, this.paragraphs, this.readSeconds);
}

bool _isBn(int r) => r >= 0x0980 && r <= 0x09FF;

/// Word counter that understands Bangla: words split on whitespace and
/// punctuation (incl. the dari U+0964), a word with any Bangla letter counts
/// as Bangla. Characters are Unicode code points (a Bangla conjunct is 2-3).
WordStats wordStats(String text) {
  final t = text.trim();
  if (t.isEmpty) return const WordStats(0, 0, 0, 0, 0, 0, 0, 0);
  final tokens = t
      .split(RegExp(r'[\s,;:!?.।॥"()\[\]{}]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  var bn = 0, en = 0;
  for (final w in tokens) {
    if (w.runes.any(_isBn)) {
      bn++;
    } else if (RegExp('[A-Za-z]').hasMatch(w)) {
      en++;
    }
  }
  final sentences = t
      .split(RegExp(r'[.!?।॥]+'))
      .where((s) => s.trim().isNotEmpty)
      .length;
  final paragraphs =
      t.split(RegExp(r'\n\s*\n')).where((p) => p.trim().isNotEmpty).length;
  return WordStats(tokens.length, bn, en, t.runes.length, _countNonSpace(t),
      sentences, paragraphs, (tokens.length * 60 / 200).ceil());
}

int _countNonSpace(String s) {
  var n = 0;
  for (final r in s.runes) {
    if (r != 0x20 && r != 0x0A && r != 0x09 && r != 0x0D && r != 0xA0) n++;
  }
  return n;
}

// ------------------------------------------------------------------ fun

/// Dice / coin / lottery with an injectable [rng] (tests pass a seeded one).
List<int> rollDice(int count, math.Random rng) =>
    [for (var i = 0; i < count.clamp(1, 6); i++) rng.nextInt(6) + 1];

bool flipCoin(math.Random rng) => rng.nextBool();

/// [count] DISTINCT numbers from [lo]..[hi] (sorted). Null when impossible.
List<int>? pickNumbers(int lo, int hi, int count, math.Random rng) {
  if (hi < lo || count < 1 || count > hi - lo + 1 || hi - lo > 1000000) {
    return null;
  }
  final out = <int>{};
  while (out.length < count) {
    out.add(lo + rng.nextInt(hi - lo + 1));
  }
  return out.toList()..sort();
}

// ------------------------------------------------------------------ store

/// Local-only prefs: favourites, recents, the last currency rates (with the
/// date the user entered them) and the last gold/silver prices. Nothing
/// leaves the phone.
class DailyToolsStore {
  static const key = 'daily_tools_v1';

  static Future<Map<String, dynamic>> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(key);
      if (raw == null || raw.isEmpty) return {};
      final j = jsonDecode(raw);
      return j is Map<String, dynamic> ? j : {};
    } catch (_) {
      return {}; // corrupt or blocked prefs: start clean, never crash
    }
  }

  static Future<void> save(Map<String, dynamic> data) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode(data));
    } catch (_) {} // best-effort convenience copy
  }

  static Future<void> patch(Map<String, dynamic> changes) async {
    final d = await load();
    d.addAll(changes);
    await save(d);
  }

  static List<String> strings(Map<String, dynamic> d, String k) =>
      [for (final v in (d[k] as List?) ?? const []) v.toString()];

  /// Move [id] to the front of recents (max 6).
  static List<String> pushRecent(List<String> recents, String id) =>
      ([id, ...recents.where((r) => r != id)]).take(6).toList();
}
