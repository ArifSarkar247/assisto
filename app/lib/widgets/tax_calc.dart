/// Client-side Bangladesh income-tax + zakat math, mirroring
/// `backend/core/logic/tax_zakat.py` byte-for-byte so a future AI/voice flow on
/// the server returns identical numbers.
///
/// Money is handled in integer POISHA internally (1 taka = 100 poisha) so there
/// is no float drift; outputs are taka doubles rounded to paisa. Pure functions,
/// no I/O, NO Bangla literals.
///
/// SOURCE DISCIPLINE: every slab band, rate, threshold, rebate cap and minimum
/// tax below is a PUBLISHED NBR figure — see `taxYears`. Nothing is invented.
/// Gold/silver per-gram PRICES are user inputs; nisab is derived, never guessed.

library;

/// Round a taka amount to paisa via integer-poisha half-up (matches backend).
double round2(double v) {
  final poisha = (v * 100).round();
  return poisha / 100.0;
}

// --- Zakat constants (classical fiqh weights; NOT prices) -------------------
const double nisabGoldGrams = 87.48;
const double nisabSilverGrams = 612.36;
const double zakatRate = 0.025; // 2.5%

// --- NBR income-tax reference data (source-noted) ---------------------------

/// One slab band above the tax-free threshold. `width == null` = remaining.
class TaxBand {
  final double? width;
  final double rate;
  const TaxBand(this.width, this.rate);
}

/// Slab bands ABOVE the tax-free threshold. Identical for AY 2024-25 and
/// AY 2025-26 per NBR Finance Act 2024 / Finance Ordinance 2025 (the proposed
/// reshaped 375k bands were NOT adopted).
const List<TaxBand> baseSlabs = [
  TaxBand(100000, 0.05), // next 1,00,000 @ 5%
  TaxBand(400000, 0.10), // next 4,00,000 @ 10%
  TaxBand(500000, 0.15), // next 5,00,000 @ 15%
  TaxBand(500000, 0.20), // next 5,00,000 @ 20%
  TaxBand(2000000, 0.25), // next 20,00,000 @ 25%
  TaxBand(null, 0.30), // balance @ 30%
];

/// Taxpayer category → tax-free threshold (taka). NBR published.
enum TaxCategory { general, femaleSenior, disabled, thirdGender, freedomFighter }

double thresholdFor(TaxCategory c) {
  switch (c) {
    case TaxCategory.general:
      return 350000;
    case TaxCategory.femaleSenior:
      return 400000;
    case TaxCategory.disabled:
    case TaxCategory.thirdGender:
      return 475000;
    case TaxCategory.freedomFighter:
      return 500000;
  }
}

/// A selectable tax year with its location minimum-tax figures and source note.
class TaxYear {
  final String id;
  final Map<String, double> minTax; // location key → taka
  const TaxYear(this.id, this.minTax);
}

const Map<String, TaxYear> taxYears = {
  '2024-2025': TaxYear('2024-2025', {
    'dhaka_ctg': 5000,
    'other_city': 4000,
    'elsewhere': 3000,
  }),
  '2025-2026': TaxYear('2025-2026', {
    'dhaka_ctg': 5000,
    'other_city': 4000,
    'elsewhere': 3000,
  }),
};
const String defaultTaxYear = '2025-2026';

// Investment rebate: 15% of the LOWEST of (actual eligible investment,
// 30% of taxable income, 1 crore). NBR published.
const double rebateRate = 0.15;
const double rebateIncomeFraction = 0.30;
const double rebateCap = 10000000;

double taxFreeThreshold(TaxCategory c, {bool extraDisabledDependent = false}) {
  var base = thresholdFor(c);
  if (extraDisabledDependent) base += 50000;
  return base;
}

class SlabBandResult {
  final double width;
  final double ratePct;
  final double tax;
  const SlabBandResult(this.width, this.ratePct, this.tax);
}

class SlabResult {
  final double grossTax;
  final double taxableAboveThreshold;
  final double threshold;
  final List<SlabBandResult> bands;
  const SlabResult(
      this.grossTax, this.taxableAboveThreshold, this.threshold, this.bands);
}

SlabResult slabTax(double taxableIncome,
    {String year = defaultTaxYear,
    TaxCategory category = TaxCategory.general,
    bool extraDisabledDependent = false}) {
  final threshold =
      taxFreeThreshold(category, extraDisabledDependent: extraDisabledDependent);
  if (taxableIncome <= 0) return SlabResult(0, 0, threshold, const []);
  final above = taxableIncome - threshold;
  if (above <= 0) return SlabResult(0, 0, threshold, const []);
  var remaining = above;
  var total = 0.0;
  final bands = <SlabBandResult>[];
  for (final b in baseSlabs) {
    if (remaining <= 0) break;
    final take =
        (b.width == null || remaining < b.width!) ? remaining : b.width!;
    final bandTax = take * b.rate;
    total += bandTax;
    bands.add(SlabBandResult(round2(take), b.rate * 100, round2(bandTax)));
    remaining -= take;
  }
  return SlabResult(round2(total), round2(above), threshold, bands);
}

class RebateResult {
  final double allowableInvestment;
  final double rebate;
  const RebateResult(this.allowableInvestment, this.rebate);
}

RebateResult investmentRebate(double taxableIncome, double eligibleInvestment) {
  final capIncome = taxableIncome * rebateIncomeFraction;
  var allowable = eligibleInvestment;
  if (capIncome < allowable) allowable = capIncome;
  if (rebateCap < allowable) allowable = rebateCap;
  if (allowable < 0) allowable = 0;
  return RebateResult(round2(allowable), round2(allowable * rebateRate));
}

class TaxEstimate {
  final String year;
  final TaxCategory category;
  final double threshold;
  final double taxableAboveThreshold;
  final List<SlabBandResult> bands;
  final double grossTax;
  final double rebate;
  final double allowableInvestment;
  final double taxAfterRebate;
  final double minimumTax;
  final bool minimumTaxApplied;
  final double netTax;
  final double tdsPaid;
  final double payable;
  final double refund;
  const TaxEstimate({
    required this.year,
    required this.category,
    required this.threshold,
    required this.taxableAboveThreshold,
    required this.bands,
    required this.grossTax,
    required this.rebate,
    required this.allowableInvestment,
    required this.taxAfterRebate,
    required this.minimumTax,
    required this.minimumTaxApplied,
    required this.netTax,
    required this.tdsPaid,
    required this.payable,
    required this.refund,
  });
}

TaxEstimate estimateIncomeTax(
  double taxableIncome, {
  String year = defaultTaxYear,
  TaxCategory category = TaxCategory.general,
  double eligibleInvestment = 0,
  double tdsPaid = 0,
  String location = 'dhaka_ctg',
  bool extraDisabledDependent = false,
}) {
  final y = taxYears[year] ?? taxYears[defaultTaxYear]!;
  final slab = slabTax(taxableIncome,
      year: year,
      category: category,
      extraDisabledDependent: extraDisabledDependent);
  final reb = investmentRebate(taxableIncome, eligibleInvestment);
  var afterRebate = slab.grossTax - reb.rebate;
  if (afterRebate < 0) afterRebate = 0;
  final minTax = y.minTax[location] ?? y.minTax['elsewhere']!;
  double netTax;
  bool minApplied;
  if (slab.taxableAboveThreshold > 0) {
    minApplied = afterRebate < minTax;
    netTax = minApplied ? minTax : afterRebate;
  } else {
    netTax = 0;
    minApplied = false;
  }
  var payable = netTax - tdsPaid;
  var refund = 0.0;
  if (payable < 0) {
    refund = -payable;
    payable = 0;
  }
  return TaxEstimate(
    year: year,
    category: category,
    threshold: slab.threshold,
    taxableAboveThreshold: slab.taxableAboveThreshold,
    bands: slab.bands,
    grossTax: slab.grossTax,
    rebate: reb.rebate,
    allowableInvestment: reb.allowableInvestment,
    taxAfterRebate: round2(afterRebate),
    minimumTax: minTax,
    minimumTaxApplied: minApplied,
    netTax: round2(netTax),
    tdsPaid: round2(tdsPaid),
    payable: round2(payable),
    refund: round2(refund),
  );
}

class NisabResult {
  final double goldNisab;
  final double silverNisab;
  final double lowerNisab;
  const NisabResult(this.goldNisab, this.silverNisab, this.lowerNisab);
}

NisabResult zakatNisab(
    {double goldPricePerGram = 0, double silverPricePerGram = 0}) {
  final g = goldPricePerGram * nisabGoldGrams;
  final s = silverPricePerGram * nisabSilverGrams;
  final candidates = [g, s].where((x) => x > 0).toList();
  final lower = candidates.isEmpty
      ? 0.0
      : candidates.reduce((a, b) => a < b ? a : b);
  return NisabResult(round2(g), round2(s), round2(lower));
}

class ZakatResult {
  final double zakatable;
  final double due;
  final bool aboveNisab;
  final double nisab;
  final bool nisabSet;
  const ZakatResult(
      this.zakatable, this.due, this.aboveNisab, this.nisab, this.nisabSet);
}

ZakatResult zakat({
  double cash = 0,
  double bank = 0,
  double goldValue = 0,
  double silverValue = 0,
  double investments = 0,
  double businessGoods = 0,
  double moneyLent = 0,
  double debts = 0,
  double nisab = 0,
}) {
  final wealth = cash +
      bank +
      goldValue +
      silverValue +
      investments +
      businessGoods +
      moneyLent -
      debts;
  if (wealth <= 0) {
    return ZakatResult(0, 0, false, round2(nisab), nisab > 0);
  }
  final above = nisab > 0 ? wealth >= nisab : true;
  final due = above ? round2(wealth * zakatRate) : 0.0;
  return ZakatResult(round2(wealth), due, above, round2(nisab), nisab > 0);
}
