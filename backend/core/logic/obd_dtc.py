"""
obd_dtc.py — PURE static table of common OBD-II trouble codes with plain-
language Bangla and English meanings (v1-vehicle).

This is NOT a diagnosis. A code says which sensor/system the car's computer is
unhappy with; a mechanic should confirm. Every meaning therefore ends in a
"what to do" hint, and unknown codes get an honest generic description built
from the code's family (P0/P1/C/B/U + subsystem digit), never a guess.
"""
import re

# code -> (bn, en, severity)  severity: low | med | high
DTC = {
    "P0100": ("বাতাস প্রবাহ (MAF) সেন্সরে সমস্যা", "Mass air flow (MAF) sensor circuit problem", "med"),
    "P0101": ("বাতাস প্রবাহ (MAF) সেন্সরের মাপ ঠিক নেই", "MAF sensor reading out of range", "med"),
    "P0110": ("ইনটেক বাতাসের তাপমাত্রা সেন্সরে সমস্যা", "Intake air temperature sensor circuit", "low"),
    "P0115": ("ইঞ্জিন কুল্যান্ট তাপমাত্রা সেন্সরে সমস্যা", "Engine coolant temperature sensor circuit", "med"),
    "P0116": ("কুল্যান্ট তাপমাত্রা সেন্সরের মাপ ঠিক নেই", "Coolant temperature sensor range/performance", "med"),
    "P0120": ("থ্রটল পজিশন সেন্সরে সমস্যা", "Throttle position sensor circuit", "med"),
    "P0128": ("ইঞ্জিন ঠিকমতো গরম হচ্ছে না (থার্মোস্ট্যাট)", "Engine not reaching temperature (thermostat)", "low"),
    "P0130": ("অক্সিজেন সেন্সর (ব্যাংক ১, সেন্সর ১) সমস্যা", "O2 sensor circuit (bank 1, sensor 1)", "low"),
    "P0133": ("অক্সিজেন সেন্সর ধীরে সাড়া দিচ্ছে", "O2 sensor slow response (bank 1, sensor 1)", "low"),
    "P0135": ("অক্সিজেন সেন্সরের হিটারে সমস্যা", "O2 sensor heater circuit (bank 1, sensor 1)", "low"),
    "P0141": ("পেছনের অক্সিজেন সেন্সরের হিটারে সমস্যা", "O2 sensor heater circuit (bank 1, sensor 2)", "low"),
    "P0171": ("জ্বালানি-বাতাসের মিশ্রণ খুব পাতলা (ব্যাংক ১)", "System too lean (bank 1)", "med"),
    "P0172": ("জ্বালানি-বাতাসের মিশ্রণ খুব ঘন (ব্যাংক ১)", "System too rich (bank 1)", "med"),
    "P0174": ("জ্বালানি-বাতাসের মিশ্রণ খুব পাতলা (ব্যাংক ২)", "System too lean (bank 2)", "med"),
    "P0175": ("জ্বালানি-বাতাসের মিশ্রণ খুব ঘন (ব্যাংক ২)", "System too rich (bank 2)", "med"),
    "P0217": ("ইঞ্জিন অতিরিক্ত গরম হয়ে গেছে", "Engine over-temperature condition", "high"),
    "P0230": ("ফুয়েল পাম্পের বৈদ্যুতিক সংযোগে সমস্যা", "Fuel pump primary circuit", "high"),
    "P0261": ("সিলিন্ডার ১-এর ইনজেক্টরে সমস্যা", "Cylinder 1 injector circuit low", "med"),
    "P0300": ("এলোমেলোভাবে মিসফায়ার হচ্ছে (একাধিক সিলিন্ডার)", "Random / multiple cylinder misfire", "high"),
    "P0301": ("সিলিন্ডার ১-এ মিসফায়ার", "Cylinder 1 misfire", "high"),
    "P0302": ("সিলিন্ডার ২-এ মিসফায়ার", "Cylinder 2 misfire", "high"),
    "P0303": ("সিলিন্ডার ৩-এ মিসফায়ার", "Cylinder 3 misfire", "high"),
    "P0304": ("সিলিন্ডার ৪-এ মিসফায়ার", "Cylinder 4 misfire", "high"),
    "P0325": ("নক সেন্সরে সমস্যা", "Knock sensor circuit", "med"),
    "P0335": ("ক্র্যাঙ্কশ্যাফট পজিশন সেন্সরে সমস্যা", "Crankshaft position sensor circuit", "high"),
    "P0340": ("ক্যামশ্যাফট পজিশন সেন্সরে সমস্যা", "Camshaft position sensor circuit", "high"),
    "P0400": ("EGR (ধোঁয়া পুনঃসঞ্চালন) প্রবাহে সমস্যা", "Exhaust gas recirculation (EGR) flow", "low"),
    "P0401": ("EGR প্রবাহ কম", "EGR flow insufficient", "low"),
    "P0420": ("ক্যাটালিটিক কনভার্টার ঠিকমতো কাজ করছে না (ব্যাংক ১)", "Catalytic converter efficiency below threshold (bank 1)", "med"),
    "P0430": ("ক্যাটালিটিক কনভার্টার ঠিকমতো কাজ করছে না (ব্যাংক ২)", "Catalytic converter efficiency below threshold (bank 2)", "med"),
    "P0440": ("জ্বালানি বাষ্প (EVAP) ব্যবস্থায় সমস্যা", "Evaporative emission (EVAP) system", "low"),
    "P0442": ("EVAP ব্যবস্থায় ছোট লিক", "EVAP system small leak", "low"),
    "P0455": ("EVAP ব্যবস্থায় বড় লিক (ফুয়েল ক্যাপ দেখুন)", "EVAP system large leak (check fuel cap)", "low"),
    "P0456": ("EVAP ব্যবস্থায় খুব ছোট লিক", "EVAP system very small leak", "low"),
    "P0500": ("গাড়ির গতি সেন্সরে সমস্যা", "Vehicle speed sensor", "med"),
    "P0505": ("আইডল (স্থির) গতি নিয়ন্ত্রণে সমস্যা", "Idle air control system", "med"),
    "P0506": ("আইডল গতি প্রত্যাশার চেয়ে কম", "Idle speed lower than expected", "low"),
    "P0507": ("আইডল গতি প্রত্যাশার চেয়ে বেশি", "Idle speed higher than expected", "low"),
    "P0562": ("ব্যাটারি/চার্জিং ভোল্টেজ কম", "System voltage low (battery / charging)", "high"),
    "P0563": ("ব্যাটারি/চার্জিং ভোল্টেজ বেশি", "System voltage high", "med"),
    "P0600": ("ইঞ্জিন কম্পিউটারের যোগাযোগে সমস্যা", "Engine computer serial communication link", "high"),
    "P0700": ("ট্রান্সমিশন (গিয়ার) নিয়ন্ত্রণে সমস্যা", "Transmission control system malfunction", "high"),
    "P0715": ("ট্রান্সমিশন ইনপুট গতি সেন্সরে সমস্যা", "Transmission input speed sensor", "med"),
    "P0741": ("টর্ক কনভার্টার ক্লাচে সমস্যা", "Torque converter clutch performance", "med"),
}

_FAMILY = {
    "P0": ("ইঞ্জিন/ট্রান্সমিশনের সাধারণ কোড", "generic powertrain (engine/transmission) code"),
    "P1": ("নির্মাতা-নির্দিষ্ট ইঞ্জিন কোড", "manufacturer-specific powertrain code"),
    "P2": ("ইঞ্জিন/ট্রান্সমিশনের সাধারণ কোড", "generic powertrain code"),
    "P3": ("ইঞ্জিন/ট্রান্সমিশনের কোড", "powertrain code"),
    "C": ("চেসিস (ব্রেক/স্টিয়ারিং/সাসপেনশন) কোড", "chassis (brakes/steering/suspension) code"),
    "B": ("বডি (এয়ারব্যাগ/লাইট/দরজা) কোড", "body (airbag/lights/doors) code"),
    "U": ("গাড়ির ভেতরের নেটওয়ার্ক/যোগাযোগ কোড", "in-vehicle network / communication code"),
}
_SUBSYS = {
    "1": ("জ্বালানি ও বাতাস মাপা", "fuel and air metering"),
    "2": ("জ্বালানি ইনজেকশন", "fuel injection"),
    "3": ("ইগনিশন/মিসফায়ার", "ignition / misfire"),
    "4": ("ধোঁয়া নিয়ন্ত্রণ", "emission controls"),
    "5": ("গতি ও আইডল নিয়ন্ত্রণ", "speed and idle control"),
    "6": ("কম্পিউটার ও আউটপুট সার্কিট", "computer and output circuits"),
    "7": ("ট্রান্সমিশন", "transmission"),
    "8": ("ট্রান্সমিশন", "transmission"),
}

ADVICE = {
    "high": ("শিগগিরই মেকানিক দেখান; ইঞ্জিনের আলো জ্বলে-নিভে করলে গাড়ি চালানো বন্ধ রাখুন।",
             "See a mechanic soon; if the engine light is flashing, stop driving."),
    "med": ("সুবিধামতো সময়ে মেকানিক দিয়ে পরীক্ষা করান।",
            "Have a mechanic check it when convenient."),
    "low": ("জরুরি নয়, পরের সার্ভিসিংয়ে দেখিয়ে নিন।",
            "Not urgent — mention it at the next service."),
}

_CODE_RE = re.compile(r"^[PCBU][0-3][0-9A-F]{3}$")


def normalize(code):
    c = str(code or "").strip().upper().replace(" ", "")
    return c if _CODE_RE.match(c) else ""


def explain(code):
    """{code, known, bn, en, severity, advice_bn, advice_en} or None if the
    string is not a well-formed DTC."""
    c = normalize(code)
    if not c:
        return None
    if c in DTC:
        bn, en, sev = DTC[c]
        known = True
    else:
        fam = _FAMILY.get(c[:2]) or _FAMILY.get(c[0])
        sub = _SUBSYS.get(c[2]) if c[0] == "P" else None
        if sub:
            bn = "%s — %s অংশ" % (fam[0], sub[0])
            en = "%s — %s" % (fam[1], sub[1])
        else:
            bn, en = fam
        sev = "med"
        known = False
    a_bn, a_en = ADVICE[sev]
    return {"code": c, "known": known, "bn": bn, "en": en, "severity": sev,
            "advice_bn": a_bn, "advice_en": a_en}


def explain_all(codes):
    out, seen = [], set()
    for raw in codes or []:
        e = explain(raw)
        if e and e["code"] not in seen:
            seen.add(e["code"])
            out.append(e)
    return out
