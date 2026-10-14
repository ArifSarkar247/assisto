/// farmer_engine.dart — on-device Dart mirror of
/// `backend/core/logic/farmer_mode.py` (FARMER / VILLAGE MODE, SPEC v2.1 §20
/// #199, ADVANCED).
///
/// PURE and DETERMINISTIC — no network, no AI, no key, and no wall-clock inside
/// the math (callers pass `now`), so the on-device result matches the Python
/// source of truth and the farm screen works fully offline.
///
/// Three pieces:
///   • farm ledger — per-record lifecycle status + profit math (never invents a
///     price the farmer did not enter);
///   • seasonal crop calendar — a FIXED Bangladeshi cropping-season almanac
///     (Rabi / Kharif-1 / Kharif-2), NOT live weather or agronomy advice;
///   • livestock tracking — head counts + a vaccination-DUE check that is the
///     REMINDER SEAM (the engine says whether a shot is due; delivering the
///     reminder is the app's job, documented in up_farmtrust_integration.md).
///
/// This file holds machine tokens only (season codes, status codes, crop/animal
/// keys); every user-facing label is an AppLocalizations getter in the screen,
/// so there are ZERO Bangla literals here (language gate).
library;

// --------------------------------------------------------------------------- //
// status + vaccination tokens (mirror farmer_mode.py)
// --------------------------------------------------------------------------- //

const String kStatusPlanned = 'planned';
const String kStatusGrowing = 'growing';
const String kStatusHarvested = 'harvested';
const String kStatusSold = 'sold';

const String kVaccDue = 'due';
const String kVaccSoon = 'soon';
const String kVaccOk = 'ok';
const String kVaccUnknown = 'unknown';

const int kVaccIntervalDays = 180;
const int kVaccSoonDays = 14;

/// Season codes, in calendar order.
const List<String> kSeasonCodes = ['rabi', 'kharif1', 'kharif2'];

/// Every crop key the calendar can emit — stable tokens the UI localises.
const Map<String, Map<String, List<dynamic>>> kSeasons = {
  'rabi': {
    'months': [10, 11, 12, 1, 2, 3],
    'sow': [10, 11],
    'harvest': [2, 3, 4],
    'crops': [
      'boro_rice', 'wheat', 'potato', 'mustard', 'lentil',
      'onion', 'garlic', 'maize', 'tomato', 'cabbage',
    ],
  },
  'kharif1': {
    'months': [3, 4, 5, 6, 7],
    'sow': [3, 4],
    'harvest': [6, 7],
    'crops': [
      'aus_rice', 'jute', 'chilli', 'aubergine', 'cucumber',
      'bitter_gourd', 'okra',
    ],
  },
  'kharif2': {
    'months': [7, 8, 9, 10, 11, 12],
    'sow': [7, 8],
    'harvest': [11, 12],
    'crops': [
      'aman_rice', 'pumpkin', 'spinach', 'radish',
      'cauliflower', 'bean',
    ],
  },
};

const List<String> kAnimalKeys = [
  'cow', 'goat', 'sheep', 'buffalo', 'chicken', 'duck',
];

// --------------------------------------------------------------------------- //
// coercers
// --------------------------------------------------------------------------- //

DateTime? _toDate(dynamic v) {
  if (v == null || v == '') return null;
  if (v is DateTime) return DateTime(v.year, v.month, v.day);
  final s = v.toString();
  if (s.length < 10) return null;
  return DateTime.tryParse(s.substring(0, 10));
}

/// Blank / bad → 0. Keeps ints tidy (mirrors `_num`).
num _num(dynamic v) {
  if (v == null || v == '') return 0;
  final n = (v is num) ? v : num.tryParse(v.toString());
  if (n == null) return 0;
  final r = (n == n.roundToDouble()) ? n.toInt() : (n * 100).round() / 100;
  return r;
}

bool _dayLe(DateTime a, DateTime b) =>
    !DateTime(a.year, a.month, a.day).isAfter(DateTime(b.year, b.month, b.day));

// --------------------------------------------------------------------------- //
// 1) farm ledger
// --------------------------------------------------------------------------- //

class FarmerEngine {
  FarmerEngine._();

  /// Deterministic lifecycle status for one ledger row. `now` drives "has the
  /// date passed" — callers must pass it (no hidden clock in the math).
  static String recordStatus(Map<String, dynamic> row, {required DateTime now}) {
    final income = _num(row['income']);
    final planted = _toDate(row['planted']);
    final harvest = _toDate(row['harvest']);
    if (income > 0) return kStatusSold;
    if (harvest != null && _dayLe(harvest, now)) return kStatusHarvested;
    if (planted != null) return kStatusGrowing;
    return kStatusPlanned;
  }

  /// income − cost (pure arithmetic over what the farmer entered).
  static FarmProfit recordProfit(Map<String, dynamic> row) {
    final cost = _num(row['cost']);
    final income = _num(row['income']);
    final profit = income - cost;
    final tidyProfit = (profit == profit.roundToDouble()) ? profit.toInt() : profit;
    num? margin;
    if (income > 0) margin = (profit / income * 1000).round() / 10;
    return FarmProfit(
      cost: cost,
      income: income,
      profit: tidyProfit,
      marginPct: margin,
      profitable: income > 0 && profit > 0,
    );
  }

  /// Farm-wide totals + per-status counts over a list of ledger rows.
  static LedgerSummary ledgerSummary(List<Map<String, dynamic>> rows,
      {required DateTime now}) {
    num totalCost = 0, totalIncome = 0;
    final counts = {
      kStatusPlanned: 0,
      kStatusGrowing: 0,
      kStatusHarvested: 0,
      kStatusSold: 0,
    };
    for (final row in rows) {
      final p = recordProfit(row);
      totalCost += p.cost;
      totalIncome += p.income;
      counts[recordStatus(row, now: now)] =
          (counts[recordStatus(row, now: now)] ?? 0) + 1;
    }
    final net = totalIncome - totalCost;
    num tidy(num x) => (x == x.roundToDouble()) ? x.toInt() : (x * 100).round() / 100;
    return LedgerSummary(
      count: rows.length,
      totalCost: tidy(totalCost),
      totalIncome: tidy(totalIncome),
      netProfit: tidy(net),
      profitable: totalIncome > 0 && net > 0,
      statusCounts: counts,
    );
  }

  /// Honest guards for a crop row (empty = ok). Blanks allowed (a planned
  /// record may carry no numbers yet).
  static List<String> validateRecord(Map<String, dynamic> row) {
    final problems = <String>[];
    if ((row['name'] ?? '').toString().trim().isEmpty) {
      problems.add('name_required');
    }
    if (_num(row['cost']) < 0) problems.add('cost_negative');
    if (_num(row['income']) < 0) problems.add('income_negative');
    final planted = _toDate(row['planted']);
    final harvest = _toDate(row['harvest']);
    if (planted != null && harvest != null && harvest.isBefore(planted)) {
      problems.add('harvest_before_planting');
    }
    return problems;
  }

  // ------------------------------------------------------------------------- //
  // 2) seasonal crop calendar
  // ------------------------------------------------------------------------- //

  /// Primary season code for a month (1..12): prefer a season actively sowing,
  /// else the first that contains the month. Fixed almanac lookup.
  static String seasonForMonth(int month) {
    for (final c in kSeasonCodes) {
      if ((kSeasons[c]!['sow']!).contains(month)) return c;
    }
    for (final c in kSeasonCodes) {
      if ((kSeasons[c]!['months']!).contains(month)) return c;
    }
    return 'rabi';
  }

  static String seasonNow(DateTime now) => seasonForMonth(now.month);

  static List<String> cropsForSeason(String code) =>
      (kSeasons[code]?['crops'] as List?)?.cast<String>() ?? const [];

  /// Full-year almanac view with the current season flagged.
  static List<SeasonView> calendar(DateTime now) {
    final cur = seasonNow(now);
    return [
      for (final c in kSeasonCodes)
        SeasonView(
          season: c,
          sowMonths: (kSeasons[c]!['sow']!).cast<int>(),
          harvestMonths: (kSeasons[c]!['harvest']!).cast<int>(),
          crops: (kSeasons[c]!['crops']!).cast<String>(),
          current: c == cur,
        ),
    ];
  }

  // ------------------------------------------------------------------------- //
  // 3) livestock vaccination (reminder seam)
  // ------------------------------------------------------------------------- //

  /// Is a booster DUE / SOON / OK for one animal, from the last-vaccination date
  /// and the standard interval, measured against `now`. No date → unknown.
  static VaccStatus vaccinationStatus(dynamic lastVaccinated,
      {required DateTime now, int intervalDays = kVaccIntervalDays}) {
    final last = _toDate(lastVaccinated);
    if (last == null) {
      return const VaccStatus(status: kVaccUnknown, dueDate: null, daysUntil: null);
    }
    final due = last.add(Duration(days: intervalDays));
    final daysUntil = DateTime(due.year, due.month, due.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    String status;
    if (daysUntil <= 0) {
      status = kVaccDue;
    } else if (daysUntil <= kVaccSoonDays) {
      status = kVaccSoon;
    } else {
      status = kVaccOk;
    }
    return VaccStatus(
      status: status,
      dueDate:
          '${due.year.toString().padLeft(4, '0')}-${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')}',
      daysUntil: daysUntil,
    );
  }

  static LivestockSummary livestockSummary(List<Map<String, dynamic>> rows,
      {required DateTime now}) {
    int totalHead = 0, due = 0, soon = 0, unknown = 0;
    final byType = <String, int>{};
    for (final row in rows) {
      var count = _num(row['count']).toInt();
      if (count < 0) count = 0;
      totalHead += count;
      final atype = (row['animal'] ?? '').toString().trim().isEmpty
          ? 'other'
          : row['animal'].toString().trim();
      byType[atype] = (byType[atype] ?? 0) + count;
      final v = vaccinationStatus(row['last_vaccinated'], now: now);
      if (v.status == kVaccDue) {
        due++;
      } else if (v.status == kVaccSoon) {
        soon++;
      } else if (v.status == kVaccUnknown) {
        unknown++;
      }
    }
    return LivestockSummary(
      animals: rows.length,
      totalHead: totalHead,
      byType: byType,
      vaccDue: due,
      vaccSoon: soon,
      vaccUnknown: unknown,
    );
  }

  static List<String> validateLivestock(Map<String, dynamic> row) {
    final problems = <String>[];
    if ((row['animal'] ?? '').toString().trim().isEmpty) {
      problems.add('animal_required');
    }
    if (_num(row['count']) < 0) problems.add('count_negative');
    return problems;
  }
}

// --------------------------------------------------------------------------- //
// value types
// --------------------------------------------------------------------------- //

class FarmProfit {
  final num cost, income, profit;
  final num? marginPct;
  final bool profitable;
  const FarmProfit({
    required this.cost,
    required this.income,
    required this.profit,
    required this.marginPct,
    required this.profitable,
  });
}

class LedgerSummary {
  final int count;
  final num totalCost, totalIncome, netProfit;
  final bool profitable;
  final Map<String, int> statusCounts;
  const LedgerSummary({
    required this.count,
    required this.totalCost,
    required this.totalIncome,
    required this.netProfit,
    required this.profitable,
    required this.statusCounts,
  });
}

class SeasonView {
  final String season;
  final List<int> sowMonths, harvestMonths;
  final List<String> crops;
  final bool current;
  const SeasonView({
    required this.season,
    required this.sowMonths,
    required this.harvestMonths,
    required this.crops,
    required this.current,
  });
}

class VaccStatus {
  final String status;
  final String? dueDate;
  final int? daysUntil;
  const VaccStatus(
      {required this.status, required this.dueDate, required this.daysUntil});
}

class LivestockSummary {
  final int animals, totalHead, vaccDue, vaccSoon, vaccUnknown;
  final Map<String, int> byType;
  const LivestockSummary({
    required this.animals,
    required this.totalHead,
    required this.byType,
    required this.vaccDue,
    required this.vaccSoon,
    required this.vaccUnknown,
  });
}
