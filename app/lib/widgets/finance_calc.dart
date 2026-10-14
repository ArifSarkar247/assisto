/// Client-side finance math, mirroring `backend/core/finance.py`.
///
/// Dart `double` is used for the arithmetic but EVERY money output is rounded to
/// paisa (2 dp) at the boundary with [round2], and we absorb rounding residue
/// into the final period / the remainder bucket so parts always re-sum to the
/// whole — no visible float drift. Pure functions, no I/O, no Bangla.

double round2(double v) => (v * 100).roundToDouble() / 100;

/// One amortization row.
class AmortRow {
  final int month;
  final double payment;
  final double principal;
  final double interest;
  final double balance;
  const AmortRow(
      this.month, this.payment, this.principal, this.interest, this.balance);
}

class EmiResult {
  final double emi;
  final double total;
  final double interest;
  final int months;
  final String mode; // 'reducing' | 'flat'
  final List<AmortRow> schedule;
  const EmiResult(this.emi, this.total, this.interest, this.months, this.mode,
      this.schedule);
}

EmiResult emiSchedule(
    double principal, double annualRatePct, int months, String mode) {
  if (months <= 0 || principal <= 0) {
    return EmiResult(0, 0, 0, months < 0 ? 0 : months, mode, const []);
  }
  final r = annualRatePct / 1200.0;
  double m;
  double? perPrincipal, perInterest;
  if (mode == 'flat') {
    final totalInterest = principal * (annualRatePct / 100.0) * (months / 12.0);
    m = round2((principal + totalInterest) / months);
    perPrincipal = principal / months;
    perInterest = totalInterest / months;
  } else {
    if (r == 0) {
      m = round2(principal / months);
    } else {
      final f = _pow(1 + r, months);
      m = round2(principal * r * f / (f - 1));
    }
  }
  final schedule = <AmortRow>[];
  var bal = principal;
  var totalPay = 0.0;
  for (var i = 1; i <= months; i++) {
    double interestI, principalI, payI;
    if (mode == 'flat') {
      interestI = round2(perInterest!);
      principalI = round2(perPrincipal!);
    } else {
      interestI = round2(bal * r);
      principalI = m - interestI;
    }
    if (i == months) {
      principalI = bal; // absorb rounding into the last period
      payI = round2(principalI + interestI);
    } else {
      payI = m;
    }
    bal = bal - principalI;
    totalPay += payI;
    schedule.add(AmortRow(i, round2(payI), round2(principalI), round2(interestI),
        round2(bal > 0 ? bal : 0)));
  }
  final total = round2(totalPay);
  return EmiResult(m, total, round2(total - principal), months, mode, schedule);
}

/// Integer-exponent power (avoids dart:math import; keeps this file dependency
/// free and matches the backend's `(1+r)**n`).
double _pow(double base, int exp) {
  var result = 1.0;
  for (var i = 0; i < exp; i++) {
    result *= base;
  }
  return result;
}

class RateCompareResult {
  final EmiResult a;
  final EmiResult b;
  final String cheaper; // 'a' | 'b' | 'equal'
  final double savings;
  const RateCompareResult(this.a, this.b, this.cheaper, this.savings);
}

RateCompareResult rateCompare(
    double principal, int months, double rateA, double rateB, String mode) {
  final a = emiSchedule(principal, rateA, months, mode);
  final b = emiSchedule(principal, rateB, months, mode);
  final diff = b.total - a.total;
  return RateCompareResult(a, b,
      diff > 0 ? 'a' : (diff < 0 ? 'b' : 'equal'), round2(diff.abs()));
}

class DpsResult {
  final double maturity;
  final double invested;
  final double profit;
  const DpsResult(this.maturity, this.invested, this.profit);
}

DpsResult dpsProjection(double monthly, double annualRatePct, int months) {
  final mr = annualRatePct / 1200.0;
  var bal = 0.0;
  for (var i = 0; i < (months < 0 ? 0 : months); i++) {
    bal = (bal + monthly) * (1 + mr);
  }
  final invested = monthly * months;
  final maturity = round2(bal);
  return DpsResult(maturity, round2(invested), round2(maturity - invested));
}

class GoalResult {
  final double monthly;
  final bool reachedWithoutSaving;
  const GoalResult(this.monthly, this.reachedWithoutSaving);
}

GoalResult goalSavings(
    double target, double current, double annualRatePct, int months) {
  if (months <= 0) return const GoalResult(0, false);
  final mr = annualRatePct / 1200.0;
  final fvCur = current * _pow(1 + mr, months);
  final need = target - fvCur;
  if (need <= 0) return const GoalResult(0, true);
  double pay;
  if (mr == 0) {
    pay = need / months;
  } else {
    final factor = (_pow(1 + mr, months) - 1) / mr;
    pay = need / factor;
  }
  return GoalResult(round2(pay), false);
}

class BudgetResult {
  final double needs;
  final double wants;
  final double savings;
  const BudgetResult(this.needs, this.wants, this.savings);
}

BudgetResult budget503020(double income) {
  final needs = round2(income * 0.50);
  final wants = round2(income * 0.30);
  final savings = round2(income - needs - wants); // remainder → no drift
  return BudgetResult(needs, wants, savings);
}

class AffordResult {
  final double freeCash;
  final double emi;
  final double leftover;
  final double burdenPct;
  final bool affordable;
  const AffordResult(
      this.freeCash, this.emi, this.leftover, this.burdenPct, this.affordable);
}

AffordResult affordability(double income, double expenses, double price,
    double downPayment, int months, double annualRatePct, String mode) {
  final free = income - expenses;
  final financed = price - downPayment;
  double emi;
  if (financed <= 0) {
    emi = 0;
  } else if (months <= 1) {
    emi = financed;
  } else {
    emi = emiSchedule(financed, annualRatePct, months, mode).emi;
  }
  final leftover = free - emi;
  final burden = free > 0 ? (emi / free * 100) : 999.0;
  return AffordResult(round2(free), round2(emi), round2(leftover),
      round2(burden), leftover >= 0 && free > 0);
}

class BreakEvenResult {
  final int? units;
  final double revenue;
  final double margin;
  final bool impossible;
  const BreakEvenResult(
      this.units, this.revenue, this.margin, this.impossible);
}

BreakEvenResult breakEven(double fixedCost, double unitPrice, double unitCost) {
  final margin = unitPrice - unitCost;
  if (margin <= 0) return BreakEvenResult(null, 0, round2(margin), true);
  final units = (fixedCost / margin).ceil();
  return BreakEvenResult(units, round2(unitPrice * units), round2(margin), false);
}

class RoiResult {
  final double roiPct;
  final double profit;
  final double? annualisedPct;
  const RoiResult(this.roiPct, this.profit, this.annualisedPct);
}

RoiResult simpleRoi(double invested, double returned, int months) {
  if (invested <= 0) return const RoiResult(0, 0, null);
  final profit = returned - invested;
  final roi = profit / invested * 100;
  final ann = months > 0 ? round2(roi * 12 / months) : null;
  return RoiResult(round2(roi), round2(profit), ann);
}

double convertAmount(double amount, double rate) => round2(amount * rate);

class ZakatResult {
  final double zakatable;
  final double due;
  final bool aboveNisab;
  const ZakatResult(this.zakatable, this.due, this.aboveNisab);
}

ZakatResult zakatFull({
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
  if (wealth <= 0) return const ZakatResult(0, 0, false);
  final above = nisab > 0 ? wealth >= nisab : true;
  final due = above ? round2(wealth * 0.025) : 0.0;
  return ZakatResult(round2(wealth), due, above);
}
