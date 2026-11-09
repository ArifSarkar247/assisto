"""citydata (owner 9 Nov 11:25): fares for City Service.

Every fare we show carries a label:
  * "official" — computed from a published government rate or chart
    (DTCA/DMTCL metro chart and rate, BRTA city-bus per-km rate, BRTA CNG
    auto-rickshaw meter rate), with the date we last checked it and a link;
  * "estimate" — no official rate exists (rickshaw, leguna, ride share);
    always a range, never one exact number.
We never call any ride-share API (owner order). Owner Admin can edit every
rate (CityDataset.overrides["rates"]) — the edit carries its own checked date.

Pure Python (no Django): also imported by the GitHub Actions data build for
the top-50 measurement.
"""
import math

CHECKED = "2026-11-09"

RATES = {
    "metro": {
        "label": "official",
        # DTCA fare policy (gazette Sept 2022), run by DMTCL: Tk 5 per km,
        # minimum Tk 20; Uttara North - Motijheel Tk 100 (the maximum).
        "per_km": 5.0, "min": 20, "max": 100, "round_to": 10,
        "card_discount_pct": 10,    # MRT / Rapid Pass smart card
        "checked": CHECKED,
        "source": "DTCA metro fare chart (Tk 5/km, min Tk 20, max Tk 100)",
        "source_url": "https://dmtcl.gov.bd/",
        "news_url": "https://www.thedailystar.net/news/bangladesh/news/no-decision-yet-3002476",
    },
    "bus": {
        "label": "official",
        # BRTA Dhaka/Chattogram metropolitan city bus rate. Gazette notification
        # of 22 Sep 2026 (Road Transport and Highways Division, issued through
        # BRTA; reported by bdnews24 23 Sep 2026 and Prothom Alo 22 Sep 2026):
        # diesel bus Tk 2.53 -> 2.70 per km, minibus 2.43 -> 2.60, minimum
        # Tk 10 (minibus Tk 8); gas-run buses stay at Tk 2.53 (24 Apr 2026
        # rate). The gazette PDF itself could not be opened on brta.gov.bd
        # (certificate error, 9 Nov) -> we cite the news reports of it.
        # We show the range gas..diesel.
        "per_km_low": 2.53, "per_km_high": 2.70, "min": 10,
        "minibus_per_km": 2.60, "minibus_min": 8,
        "effective": "2026-09-22",
        "checked": CHECKED,
        "source": "Government gazette 22 Sep 2026 (BRTA city bus rate: Tk 2.70/km diesel, "
                  "Tk 2.53/km gas, minimum Tk 10) as reported by bdnews24 and Prothom Alo",
        "source_url": "https://bdnews24.com/bangladesh/vi8979wckd",
        "news_url": "https://en.prothomalo.com/bangladesh/k3n86iluhg",
        "sources": ["https://bdnews24.com/bangladesh/vi8979wckd",
                    "https://en.prothomalo.com/bangladesh/k3n86iluhg",
                    "https://today.thefinancialexpress.com.bd/print/bus-fares-up-by-11-paisa-per-kilometre-1776966071"],
    },
    "cng": {
        "label": "official",
        # BRTA auto-rickshaw meter rate (Dhaka, since 1 Nov 2015): first 2 km
        # Tk 40, then Tk 12 per km, waiting Tk 2 per minute.
        "first_km": 2.0, "first_tk": 40, "per_km": 12, "wait_per_min": 2,
        "checked": CHECKED,
        "source": "BRTA CNG auto-rickshaw meter rate (Dhaka)",
        "source_url": "https://brta.gov.bd/",
        "news_url": "https://www.tbsnews.net/bangladesh/cng-drivers-face-tk50000-fine-6-months-imprisonment-charging-fare-higher-meter-1066706",
    },
    "rickshaw": {
        "label": "estimate", "min_low": 30, "min_high": 40,
        "per_km_low": 25, "per_km_high": 40,
        "checked": CHECKED, "source": "Assisto estimate (no official rickshaw rate)",
        "source_url": "",
    },
    "leguna": {
        "label": "estimate", "min_low": 10, "min_high": 15,
        "per_km_low": 2.5, "per_km_high": 4.0,
        "checked": CHECKED, "source": "Assisto estimate (no official leguna chart)",
        "source_url": "",
    },
    "water": {
        "label": "estimate", "min_low": 20, "min_high": 30,
        "per_km_low": 2.0, "per_km_high": 4.0,
        "checked": CHECKED, "source": "Assisto estimate (BIWTC waterbus / launch fares vary)",
        "source_url": "",
    },
    "ride_bike": {
        "label": "estimate", "base_low": 30, "base_high": 50,
        "per_km_low": 14, "per_km_high": 22, "per_min": 1.0,
        "checked": CHECKED,
        "source": "Assisto estimate of app bike fares (no ride-share API is called)",
        "source_url": "",
    },
    "ride_car": {
        "label": "estimate", "base_low": 80, "base_high": 120,
        "per_km_low": 30, "per_km_high": 45, "per_min": 3.0,
        "checked": CHECKED,
        "source": "Assisto estimate of app car fares (no ride-share API is called)",
        "source_url": "",
    },
}

# Complaint line for overcharging / meter refusal (one tap in the app).
# A BRTA hotline could NOT be confirmed on an official BRTA page (9 Nov:
# brta.gov.bd certificate error; numbers seen only on old news / third-party
# pages) -> "number" stays empty and the app offers 333, which is the
# government's National Information and Service Helpline (333.gov.bd: "a
# single voice access point for all Government Information & Grievance
# Redressal", 24/7). It is labelled as that, never as a BRTA number. The
# owner can enter a confirmed BRTA number in Owner Admin -> City data.
BRTA_COMPLAINT = {"number": "", "fallback": "333", "verified": False,
                  "kind": "national_helpline",
                  "label_en": "333 national helpline", "label_bn": "৩৩৩ জাতীয় হেল্পলাইন",
                  "fallback_en": "333 national helpline", "fallback_bn": "৩৩৩ জাতীয় হেল্পলাইন",
                  "note_en": "333 is the government's national information and complaint helpline "
                             "(not a BRTA number).",
                  "note_bn": "৩৩৩ সরকারের জাতীয় তথ্য ও অভিযোগ হেল্পলাইন (বিআরটিএ-র নিজস্ব নম্বর নয়)।",
                  "checked": CHECKED, "source_url": "https://333.gov.bd/",
                  "brta_number_status": "not confirmed on an official BRTA page (9 Nov 2026)"}

# Published station-pair amounts we could confirm (DTCA chart as reported).
# Keys are sorted station codes; these win over the per-km computation.
METRO_CHART = {
    ("AGA", "UTN"): 60,
    ("MOT", "UTN"): 100,
    ("FAR", "UTN"): 70,
    ("AGA", "FAR"): 20,
    ("FAR", "MOT"): 40,
}


def rates(overrides=None):
    """Default rates with Owner Admin edits merged on top."""
    out = {k: dict(v) for k, v in RATES.items()}
    for k, v in (overrides or {}).items():
        if k in out and isinstance(v, dict):
            out[k].update(v)
    return out


def _r(x):
    return int(round(x))


def _meta(r):
    return {"label": r["label"], "checked": r.get("checked", CHECKED),
            "source": r.get("source", ""), "source_url": r.get("source_url", "")}


def metro(km, a_code="", b_code="", R=None):
    r = (R or RATES)["metro"]
    key = tuple(sorted((a_code, b_code)))
    basis = "chart"
    if key in METRO_CHART:
        tk = METRO_CHART[key]
    else:
        basis = "rate"
        step = r.get("round_to", 10) or 1
        tk = int(round(km * r["per_km"] / step) * step)
        tk = max(r["min"], min(r["max"], tk))
    disc = r.get("card_discount_pct", 0)
    return dict(_meta(r), low=tk, high=tk, basis=basis,
                card=int(tk - tk * disc / 100.0) if disc else tk)


def bus(km, R=None):
    r = (R or RATES)["bus"]
    lo = max(r["min"], _r(km * r["per_km_low"]))
    hi = max(r["min"], _r(km * r["per_km_high"]))
    return dict(_meta(r), low=lo, high=max(lo, hi), basis="rate")


def cng_meter(km, wait_min=0.0, R=None):
    r = (R or RATES)["cng"]
    tk = r["first_tk"] + max(0.0, km - r["first_km"]) * r["per_km"]
    return _r(tk + max(0.0, wait_min) * r["wait_per_min"])


def cng(km, minutes=0.0, R=None):
    """Meter fare: low = meter with no waiting, high = meter with the expected
    stop-and-go waiting (≈ a third of the ride in Dhaka traffic)."""
    r = (R or RATES)["cng"]
    lo = cng_meter(km, 0, R)
    hi = cng_meter(km, minutes / 3.0, R)
    return dict(_meta(r), low=lo, high=max(lo, hi), basis="meter",
                meter=lo, overcharge_note=True)


def _range(r, km, minutes=0.0):
    if "base_low" in r:
        lo = r["base_low"] + km * r["per_km_low"] + minutes * r.get("per_min", 0) * 0.5
        hi = r["base_high"] + km * r["per_km_high"] + minutes * r.get("per_min", 0)
    else:
        lo = max(r["min_low"], km * r["per_km_low"])
        hi = max(r["min_high"], km * r["per_km_high"])
    lo, hi = int(math.floor(lo / 5.0) * 5), int(math.ceil(hi / 5.0) * 5)
    return dict(_meta(r), low=lo, high=max(lo, hi), basis="estimate")


def rickshaw(km, R=None):
    return _range((R or RATES)["rickshaw"], km)


def leguna(km, R=None):
    return _range((R or RATES)["leguna"], km)


def ride(kind, km, minutes, R=None):
    return _range((R or RATES)["ride_" + kind], km, minutes)


def leg_fare(mode, km, minutes=0.0, a_code="", b_code="", R=None):
    if mode == "metro":
        return metro(km, a_code, b_code, R)
    if mode == "bus":
        return bus(km, R)
    if mode == "leguna":
        return leguna(km, R)
    if mode == "cng":
        return cng(km, minutes, R)
    if mode == "rickshaw":
        return rickshaw(km, R)
    if mode == "water":
        return _range((R or RATES)["water"], km)
    if mode in ("ride_bike", "ride_car"):
        return ride(mode[5:], km, minutes, R)
    return None


def sources(R=None):
    R = R or RATES
    return [{"mode": k, "label": v["label"], "checked": v.get("checked", CHECKED),
             "source": v.get("source", ""), "source_url": v.get("source_url", ""),
             "news_url": v.get("news_url", "")} for k, v in R.items()]
