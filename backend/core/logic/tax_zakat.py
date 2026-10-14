"""
tax_zakat.py — Bangladesh INCOME TAX estimator + ZAKAT calculator (feature #60,
SPEC v2.1 §21 ADVANCED). Pure Decimal math, no DB, no AI, no network.

DESIGN RULES (do not soften):
  * Every slab band, rate, tax-free threshold, rebate cap and minimum-tax figure
    is a PUBLISHED NBR figure, source-noted in `TAX_YEARS` below. Nothing here is
    invented. Where a figure could change, the UI is told to say
    "verify with NBR / consult a professional".
  * Gold / silver PRICE and the per-gram bullion rate are USER inputs — we never
    fetch or guess bullion prices or FX. Nisab is derived from the user-entered
    per-gram price times the fixed metal weights (87.48 g gold / 612.36 g silver).
  * Zakat is a flat 2.5% of net zakatable wealth, levied only at/above nisab.
  * Money is integer POISHA internally (1 taka = 100 poisha) so there is no float
    drift; results are returned as taka strings quantized to 2 dp.
  * This is an ESTIMATE and NOT tax advice — the caller/UI must always show the
    "not tax advice — consult a professional" disclaimer.

These functions mirror the client-side Dart in app/lib/widgets/tax_calc.dart
byte-for-byte so a future AI/voice flow returns identical numbers.
"""
from decimal import Decimal, ROUND_HALF_UP, InvalidOperation

_CENT = Decimal("0.01")

# Fixed nisab metal weights (grams). These are the classical fiqh values used
# across BD zakat guidance and are NOT prices — only the per-gram PRICE is a
# user input.
NISAB_GOLD_GRAMS = Decimal("87.48")
NISAB_SILVER_GRAMS = Decimal("612.36")

ZAKAT_RATE = Decimal("0.025")  # 2.5%

# ---------------------------------------------------------------------------
# NBR income-tax reference data. SOURCE-NOTED — these are published figures.
#
# Sources (accessed Oct 2026):
#   - Mahfel Huq & Co, "2024-2025 Bangladesh individual income tax rates"
#   - ACE Advisory, "Income Tax Rate in Bangladesh 2025"
#   - Rakib Hassan, "Tax Rate in Bangladesh 2025-26 Guide"
#   - NBR Finance Act / Finance Ordinance summaries (ACNABIN, 2024 & 2025)
#
# The AY 2025-26 (income year 2024-25) slab STRUCTURE is unchanged from
# AY 2024-25: the proposed new 375,000 threshold / reshaped bands were NOT
# adopted (the Finance Ordinance 2025 kept the 350,000 tax-free ceiling and
# spared the new top-rate change) — so both years share the same slab math,
# differing only in minimum-tax figures, which we note per year.
#
# `slabs` = list of (band_width_or_None, rate). None width = "all remaining".
# Thresholds are the tax-free band already baked in as the first (width, 0.0)
# slab, which is replaced per taxpayer category at compute time.
# ---------------------------------------------------------------------------

# Slab bands ABOVE the tax-free threshold (width in taka, rate as Decimal).
# None = remaining balance. Same for AY 2024-25 and AY 2025-26 per sources.
_BASE_SLABS = [
    (Decimal("100000"), Decimal("0.05")),   # next 1,00,000 @ 5%
    (Decimal("400000"), Decimal("0.10")),   # next 4,00,000 @ 10%
    (Decimal("500000"), Decimal("0.15")),   # next 5,00,000 @ 15%
    (Decimal("500000"), Decimal("0.20")),   # next 5,00,000 @ 20%
    (Decimal("2000000"), Decimal("0.25")),  # next 20,00,000 @ 25%
    (None, Decimal("0.30")),                # balance @ 30%
]

# Tax-free thresholds by category (taka). NBR published.
_THRESHOLDS = {
    "general": Decimal("350000"),
    "female_senior": Decimal("400000"),   # women & 65+
    "disabled": Decimal("475000"),
    "third_gender": Decimal("475000"),
    "freedom_fighter": Decimal("500000"),
}

TAX_YEARS = {
    "2024-2025": {
        "label": "AY 2024-2025 (income year 2023-24)",
        "slabs": _BASE_SLABS,
        "thresholds": _THRESHOLDS,
        "min_tax": {  # by location, taka
            "dhaka_ctg": Decimal("5000"),
            "other_city": Decimal("4000"),
            "elsewhere": Decimal("3000"),
        },
        "source": "NBR Finance Act 2024; Mahfel Huq & Co / ACE Advisory summaries",
    },
    "2025-2026": {
        "label": "AY 2025-2026 (income year 2024-25)",
        "slabs": _BASE_SLABS,
        "thresholds": _THRESHOLDS,
        "min_tax": {
            "dhaka_ctg": Decimal("5000"),
            "other_city": Decimal("4000"),
            "elsewhere": Decimal("3000"),
        },
        "source": "NBR Finance Ordinance 2025; Rakib Hassan / ACE Advisory summaries",
    },
}
DEFAULT_TAX_YEAR = "2025-2026"

# Investment rebate: 15% of the LOWEST of
#   (actual eligible investment, 30% of taxable income, BDT 1 crore).
# NBR published (Finance Act 2024 / Ordinance 2025).
REBATE_RATE = Decimal("0.15")
REBATE_INCOME_FRACTION = Decimal("0.30")
REBATE_CAP = Decimal("10000000")  # BDT 1 crore


def _d(v, default="0"):
    try:
        return Decimal(str(v if v not in (None, "") else default))
    except (InvalidOperation, ValueError):
        return Decimal(default)


def _q(x):
    """Quantize to paisa via integer-poisha rounding (half-up) → taka string."""
    poisha = (x * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP)
    return str((poisha / 100).quantize(_CENT))


def tax_free_threshold(category="general", extra_disabled_dependent=False):
    """Tax-free threshold for a taxpayer category. Optional +50,000 for a parent
    of a physically-challenged / adopted child (one parent only — NBR)."""
    base = _THRESHOLDS.get(category, _THRESHOLDS["general"])
    if extra_disabled_dependent:
        base += Decimal("50000")
    return base


def slab_tax(taxable_income, year=DEFAULT_TAX_YEAR, category="general",
             extra_disabled_dependent=False):
    """Gross tax from the progressive slabs (before rebate / minimum tax).

    Returns the per-band breakdown too, so the UI can show HOW the tax was
    built — every band is a source-noted NBR figure, never invented.
    """
    y = TAX_YEARS.get(year, TAX_YEARS[DEFAULT_TAX_YEAR])
    income = _d(taxable_income)
    threshold = tax_free_threshold(category, extra_disabled_dependent)
    if income <= 0:
        return {"gross_tax": "0.00", "taxable_above_threshold": "0.00",
                "threshold": _q(threshold), "bands": []}
    above = income - threshold
    if above <= 0:
        return {"gross_tax": "0.00", "taxable_above_threshold": "0.00",
                "threshold": _q(threshold), "bands": []}
    remaining = above
    total = Decimal("0")
    bands = []
    for width, rate in y["slabs"]:
        if remaining <= 0:
            break
        take = remaining if (width is None or remaining < width) else width
        band_tax = (take * rate)
        total += band_tax
        bands.append({
            "width": _q(take),
            "rate_pct": str((rate * 100).quantize(_CENT)),
            "tax": _q(band_tax),
        })
        remaining -= take
    return {"gross_tax": _q(total),
            "taxable_above_threshold": _q(above),
            "threshold": _q(threshold),
            "bands": bands}


def investment_rebate(taxable_income, eligible_investment):
    """Investment tax rebate = 15% of the LOWEST of (actual eligible investment,
    30% of taxable income, 1 crore). NBR published figures."""
    income = _d(taxable_income)
    invest = _d(eligible_investment)
    cap_income = income * REBATE_INCOME_FRACTION
    allowable = min(invest, cap_income, REBATE_CAP)
    if allowable < 0:
        allowable = Decimal("0")
    rebate = allowable * REBATE_RATE
    return {"allowable_investment": _q(allowable),
            "rebate": _q(rebate),
            "rate_pct": str((REBATE_RATE * 100).quantize(_CENT))}


def estimate_income_tax(taxable_income, year=DEFAULT_TAX_YEAR,
                        category="general", eligible_investment=0,
                        tds_paid=0, location="dhaka_ctg",
                        extra_disabled_dependent=False):
    """Full income-tax ESTIMATE: slabs → rebate → minimum tax → less TDS.

    NOT tax advice. Every rate/threshold/minimum is a source-noted NBR figure.
    The caller MUST surface the 'verify with NBR / consult a professional'
    disclaimer. Returns taka strings (integer-poisha rounded).
    """
    y = TAX_YEARS.get(year, TAX_YEARS[DEFAULT_TAX_YEAR])
    slab = slab_tax(taxable_income, year, category, extra_disabled_dependent)
    gross = _d(slab["gross_tax"])
    reb = investment_rebate(taxable_income, eligible_investment)
    rebate = _d(reb["rebate"])
    after_rebate = gross - rebate
    if after_rebate < 0:
        after_rebate = Decimal("0")
    # Minimum tax applies when the taxpayer has taxable income above the
    # threshold (i.e. is a return-filer with assessable income).
    min_tax = y["min_tax"].get(location, y["min_tax"]["elsewhere"])
    above = _d(slab["taxable_above_threshold"])
    if above > 0:
        net_tax = max(after_rebate, min_tax)
        min_applied = after_rebate < min_tax
    else:
        net_tax = Decimal("0")
        min_applied = False
    tds = _d(tds_paid)
    payable = net_tax - tds
    refund = Decimal("0")
    if payable < 0:
        refund = -payable
        payable = Decimal("0")
    return {
        "year": year,
        "year_label": y["label"],
        "category": category,
        "threshold": slab["threshold"],
        "taxable_above_threshold": slab["taxable_above_threshold"],
        "bands": slab["bands"],
        "gross_tax": _q(gross),
        "rebate": _q(rebate),
        "allowable_investment": reb["allowable_investment"],
        "tax_after_rebate": _q(after_rebate),
        "minimum_tax": _q(min_tax),
        "minimum_tax_applied": min_applied,
        "net_tax": _q(net_tax),
        "tds_paid": _q(tds),
        "payable": _q(payable),
        "refund": _q(refund),
        "source": y["source"],
        "estimate": True,
    }


def zakat_nisab(gold_price_per_gram=0, silver_price_per_gram=0):
    """Nisab thresholds from USER-entered per-gram metal prices (never guessed).

    Returns both gold-nisab and silver-nisab; the effective nisab for cash-rich
    zakat is conventionally the LOWER (silver) so more wealth is captured — but
    we return both and let the caller/UI choose explicitly.
    """
    g = _d(gold_price_per_gram) * NISAB_GOLD_GRAMS
    s = _d(silver_price_per_gram) * NISAB_SILVER_GRAMS
    both = [x for x in (g, s) if x > 0]
    lower = min(both) if both else Decimal("0")
    return {"gold_nisab": _q(g), "silver_nisab": _q(s),
            "gold_grams": str(NISAB_GOLD_GRAMS),
            "silver_grams": str(NISAB_SILVER_GRAMS),
            "lower_nisab": _q(lower)}


def zakat(cash=0, bank=0, gold_value=0, silver_value=0, investments=0,
          business_goods=0, money_lent=0, debts=0, nisab=0):
    """Zakat = 2.5% of net zakatable wealth, levied only at/above nisab.

    All asset VALUES and the nisab threshold are user inputs — bullion prices
    are never guessed. If nisab is 0/blank the UI should warn it is unset; here
    we treat 0 as "no floor" (zakat on any positive wealth) and flag it.
    """
    wealth = (_d(cash) + _d(bank) + _d(gold_value) + _d(silver_value)
              + _d(investments) + _d(business_goods) + _d(money_lent)
              - _d(debts))
    if wealth <= 0:
        return {"zakatable": "0.00", "zakat_due": "0.00", "above_nisab": False,
                "nisab": _q(_d(nisab)), "nisab_set": _d(nisab) > 0}
    nis = _d(nisab)
    above = wealth >= nis if nis > 0 else True
    due = (wealth * ZAKAT_RATE) if above else Decimal("0")
    return {"zakatable": _q(wealth), "zakat_due": _q(due), "above_nisab": above,
            "nisab": _q(nis), "nisab_set": nis > 0,
            "rate_pct": str((ZAKAT_RATE * 100).quantize(_CENT))}
