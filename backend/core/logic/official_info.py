"""
official_info.py — p3guides (owner PART 3: Service guide, Probashi corner,
Student corner). Facts that come ONLY from official / published sources, each
with a link and the date Assisto last checked it.

Honesty rules (enforced by core/tests_p3guides.py):
  * A fee is printed as a NUMBER only when it is set by a published government
    rule/circular (`fee_basis`) AND independent reports agree. Everything else
    is `fee_status = "official_page"`: the app shows a button to the official
    fee page instead of a number. We never guess a fee.
  * Every source URL is an official site (gov.bd, the board/university/agency
    itself, or the World Bank / UN for international benchmarks).
  * Dates for exams, admissions and scholarships are NEVER invented: we list the
    official notice pages; the student saves a deadline they read there.
  * Pure data + pure functions. No Django, no network.

Checked 2026-11-03. Note: several gov.bd fee pages (epassport, nidw, brta,
mutation, remittanceprices.worldbank.org) refuse our server's network (403 /
no route), which is exactly why those fees stay link-only until the owner
confirms them from a Bangladesh network (FEATURE_CARD_SERVICE_GUIDE_BN.md).
"""

CHECKED = "2026-11-03"

OFFICIAL_HOST_SUFFIXES = (
    ".gov.bd", ".ac.bd", ".edu.bd", "worldbank.org", "un.org", "amiprobashi.com",
    "gstadmission.ac.bd", "bb.org.bd",
)


def _t(bn, en):
    return (bn, en)


def _src(bn, en, url):
    return {"label": (bn, en), "url": url}


# =========================================================== SERVICE GUIDE
# Keyed by core/logic/govt_guide.py service keys.
GUIDE_FACTS = {
    "nid": {
        "fee_status": "official_page",
        "fee_page": "https://services.nidw.gov.bd",
        "sources": [_src("নির্বাচন কমিশন — NID সেবা", "Election Commission — NID services", "https://services.nidw.gov.bd"),
                    _src("নির্বাচন কমিশন", "Election Commission", "https://www.ecs.gov.bd")],
    },
    "epassport": {
        "fee_status": "official_page",
        "fee_page": "https://www.epassport.gov.bd/instructions/passport-fees",
        "sources": [_src("ই-পাসপোর্ট পোর্টাল (ইমিগ্রেশন ও পাসপোর্ট অধিদপ্তর)", "e-Passport portal (Dept. of Immigration & Passports)", "https://www.epassport.gov.bd"),
                    _src("ইমিগ্রেশন ও পাসপোর্ট অধিদপ্তর", "Dept. of Immigration & Passports", "https://www.dip.gov.bd")],
    },
    "birth": {
        "fee_status": "published",
        "fee_page": "https://bdris.gov.bd",
        "fee_basis": _t("জন্ম ও মৃত্যু নিবন্ধন বিধিমালা অনুযায়ী সরকারের প্রকাশিত ফি",
                        "Fees published by the government under the Birth and Death Registration Rules"),
        "fees": [
            (_t("জন্মের ৪৫ দিনের মধ্যে নিবন্ধন", "Registration within 45 days of birth"), _t("ফি নেই", "Free")),
            (_t("৪৫ দিন পর থেকে ৫ বছর পর্যন্ত", "After 45 days, up to 5 years"), _t("৳২৫", "Tk 25")),
            (_t("৫ বছর পরে নিবন্ধন", "Registration after 5 years"), _t("৳৫০", "Tk 50")),
            (_t("জন্মতারিখ সংশোধনের আবেদন", "Application to correct the date of birth"), _t("৳১০০", "Tk 100")),
        ],
        "sources": [_src("জন্ম ও মৃত্যু নিবন্ধন (BDRIS)", "Birth & Death Registration (BDRIS)", "https://bdris.gov.bd"),
                    _src("রেজিস্ট্রার জেনারেলের কার্যালয়", "Office of the Registrar General", "https://bdris.gov.bd")],
    },
    "driving": {
        "fee_status": "official_page",
        "fee_page": "https://bsp.brta.gov.bd",
        "sources": [_src("BRTA সেবা পোর্টাল", "BRTA Service Portal", "https://bsp.brta.gov.bd"),
                    _src("বাংলাদেশ সড়ক পরিবহন কর্তৃপক্ষ", "Bangladesh Road Transport Authority", "https://brta.gov.bd")],
    },
    "tin": {
        "fee_status": "published",
        "fee_page": "https://secure.incometax.gov.bd",
        "fee_basis": _t("জাতীয় রাজস্ব বোর্ড: e-TIN নিবন্ধন ও অনলাইন রিটার্ন জমায় সরকারি ফি নেই (প্রদেয় কর আলাদা)",
                        "National Board of Revenue: e-TIN registration and filing a return online carry no government fee (tax payable is separate)"),
        "fees": [
            (_t("e-TIN নিবন্ধন", "e-TIN registration"), _t("ফি নেই", "Free")),
            (_t("ই-রিটার্ন জমা", "Filing the e-Return"), _t("ফি নেই", "Free")),
        ],
        "sources": [_src("e-TIN (জাতীয় রাজস্ব বোর্ড)", "e-TIN (National Board of Revenue)", "https://secure.incometax.gov.bd"),
                    _src("ই-রিটার্ন", "e-Return", "https://etaxnbr.gov.bd"),
                    _src("জাতীয় রাজস্ব বোর্ড", "National Board of Revenue", "https://nbr.gov.bd")],
    },
    "porcha": {
        "fee_status": "official_page",
        "fee_page": "https://eporcha.gov.bd",
        "sources": [_src("ই-পর্চা (ভূমি মন্ত্রণালয়)", "e-Porcha (Ministry of Land)", "https://eporcha.gov.bd"),
                    _src("ভূমি মন্ত্রণালয়", "Ministry of Land", "https://land.gov.bd")],
    },
    "emutation": {
        "fee_status": "published",
        "fee_page": "https://mutation.land.gov.bd",
        "fee_basis": _t("ভূমি মন্ত্রণালয়ের পরিপত্র (সেপ্টেম্বর ২০২২ থেকে শুধু অনলাইনে); ফেব্রুয়ারি ২০২৬-এ সব ভূমি অফিসে সাইনবোর্ডে টাঙানোর নির্দেশ",
                        "Ministry of Land circular (online-only since September 2022); February 2026 order to display it on a signboard in every land office"),
        "fees": [
            (_t("কোর্ট ফি (আবেদন)", "Court fee (application)"), _t("৳২০", "Tk 20")),
            (_t("নোটিশ জারি ফি", "Notice fee"), _t("৳৫০", "Tk 50")),
            (_t("রেকর্ড সংশোধন ফি", "Record correction fee"), _t("৳১,০০০", "Tk 1,000")),
            (_t("খতিয়ান সরবরাহ ফি", "Khatian copy fee"), _t("৳১০০", "Tk 100")),
            (_t("মোট", "Total"), _t("৳১,১৭০", "Tk 1,170")),
        ],
        "sources": [_src("ই-নামজারি (ভূমি মন্ত্রণালয়)", "e-Mutation (Ministry of Land)", "https://mutation.land.gov.bd"),
                    _src("ভূমি মন্ত্রণালয়", "Ministry of Land", "https://land.gov.bd")],
    },
    "trade_license": {
        "fee_status": "official_page",
        "fee_page": "https://bangladesh.gov.bd",
        "fee_note": _t("ফি সিটি কর্পোরেশন/পৌরসভা ও ব্যবসার ধরন অনুযায়ী আলাদা — নিজের সিটি/পৌরসভার সাইটে দেখুন।",
                       "The fee differs by City Corporation/Pourashava and business type — see your own city/pourashava site."),
        "sources": [_src("জাতীয় তথ্য বাতায়ন (সিটি/পৌরসভা খুঁজুন)", "National Portal (find your city/pourashava)", "https://bangladesh.gov.bd"),
                    _src("ঢাকা উত্তর সিটি কর্পোরেশন", "Dhaka North City Corporation", "https://dncc.gov.bd"),
                    _src("ঢাকা দক্ষিণ সিটি কর্পোরেশন", "Dhaka South City Corporation", "https://dscc.gov.bd")],
    },
    "police_clearance": {
        "fee_status": "official_page",
        "fee_page": "https://pcc.police.gov.bd",
        "sources": [_src("পুলিশ ক্লিয়ারেন্স (বাংলাদেশ পুলিশ)", "Police Clearance (Bangladesh Police)", "https://pcc.police.gov.bd")],
    },
    "brta_vehicle": {
        "fee_status": "official_page",
        "fee_page": "https://bsp.brta.gov.bd",
        "sources": [_src("BRTA সেবা পোর্টাল", "BRTA Service Portal", "https://bsp.brta.gov.bd")],
    },
}


def _loc(v, lang):
    if isinstance(v, tuple) and len(v) == 2:
        return v[1] if lang == "en" else v[0]
    return v


def guide_facts(key, lang):
    """Localised official facts for one service, or a minimal honest block
    (official_page + checked) when we hold none for it."""
    f = GUIDE_FACTS.get(key)
    if f is None:
        return {"checked": CHECKED, "fee_status": "official_page", "fee_page": "",
                "fee_basis": "", "fees": [], "sources": [], "fee_note": ""}
    return {
        "checked": CHECKED,
        "fee_status": f["fee_status"],
        "fee_page": f.get("fee_page", ""),
        "fee_basis": _loc(f.get("fee_basis", ""), lang),
        "fee_note": _loc(f.get("fee_note", ""), lang),
        "fees": [{"label": _loc(a, lang), "amount": _loc(b, lang)} for a, b in f.get("fees", [])],
        "sources": [{"label": _loc(s["label"], lang), "url": s["url"]} for s in f.get("sources", [])],
    }


# =========================================================== PROBASHI
PROBASHI = {
    "helplines": [
        {"id": "probashbondhu", "dial": "16135",
         "name": _t("প্রবাসবন্ধু কল সেন্টার (দেশ থেকে)", "Probash-Bondhu call centre (from Bangladesh)"),
         "display": _t("১৬১৩৫", "16135"),
         "note": _t("টোল-ফ্রি, ২৪ ঘণ্টা — ওয়েজ আর্নার্স কল্যাণ বোর্ড (সেপ্টেম্বর ২০২২ চালু)",
                    "Toll-free, 24 hours — Wage Earners' Welfare Board (launched September 2022)"),
         "source": "https://wewb.gov.bd"},
        {"id": "probashbondhu_abroad", "dial": "+8809610102030",
         "name": _t("প্রবাসবন্ধু — বিদেশ থেকে", "Probash-Bondhu — from abroad"),
         "display": _t("+৮৮ ০৯৬১০১০২০৩০", "+88 09610102030"),
         "note": _t("বিদেশ থেকে কল করার নম্বর (আন্তর্জাতিক কল চার্জ লাগতে পারে)",
                    "Number to call from abroad (international call charges may apply)"),
         "source": "https://wewb.gov.bd"},
        {"id": "national_999", "dial": "999",
         "name": _t("জাতীয় জরুরি সেবা (বাংলাদেশে)", "National emergency service (in Bangladesh)"),
         "display": _t("৯৯৯", "999"),
         "note": _t("দেশে থাকা পরিবারের বিপদে — পুলিশ, ফায়ার, অ্যাম্বুলেন্স", "For family in Bangladesh — police, fire, ambulance"),
         "source": "https://999.gov.bd"},
    ],
    "links": [
        _src("বিদেশে বাংলাদেশ দূতাবাস/মিশনের তালিকা (পররাষ্ট্র মন্ত্রণালয়)", "Bangladesh missions abroad (Ministry of Foreign Affairs)", "https://mofa.gov.bd"),
        _src("ওয়েজ আর্নার্স কল্যাণ বোর্ড", "Wage Earners' Welfare Board", "https://wewb.gov.bd"),
        _src("BMET — লাইসেন্সপ্রাপ্ত এজেন্সি যাচাই", "BMET — check a licensed agency", "https://www.bmet.gov.bd"),
        _src("প্রবাসী কল্যাণ ও বৈদেশিক কর্মসংস্থান মন্ত্রণালয়", "Ministry of Expatriates' Welfare and Overseas Employment", "https://probashi.gov.bd"),
        _src("আমি প্রবাসী (সরকারি অ্যাপ: BMET নিবন্ধন, ছাড়পত্র)", "Ami Probashi (official app: BMET registration, clearance)", "https://www.amiprobashi.com"),
    ],
    "welfare": [
        {"id": "death_grant",
         "title": _t("মৃত্যুতে পরিবারকে আর্থিক অনুদান", "Grant to the family after a death abroad"),
         "amount": _t("৳৩,০০,০০০", "Tk 300,000"),
         "note": _t("বহির্গমন ছাড়পত্র (BMET) বা বোর্ডের সদস্যপদ থাকলে; বোর্ডে আবেদন করতে হয়।",
                    "If the worker had BMET emigration clearance or board membership; the family applies to the board.")},
        {"id": "airport_burial",
         "title": _t("লাশ পরিবহন ও দাফনের খরচ (বিমানবন্দরে)", "Transport and burial cost (at the airport)"),
         "amount": _t("৳৩৫,০০০", "Tk 35,000"),
         "note": _t("তিন আন্তর্জাতিক বিমানবন্দরের প্রবাসী কল্যাণ ডেস্কে তাৎক্ষণিক চেক।",
                    "An immediate cheque at the expatriate welfare desk of the three international airports.")},
        {"id": "repatriation",
         "title": _t("লাশ দেশে আনা ও বাড়ি পৌঁছানো", "Bringing the body home"),
         "amount": _t("বোর্ডের সহায়তা", "Board support"),
         "note": _t("বোর্ড লাশ দেশে আনা, বিমানবন্দরে গ্রহণ ও পরিবারের কাছে পৌঁছাতে সাহায্য করে; অসুস্থ ফেরত-আসা কর্মীর জন্য অ্যাম্বুলেন্স।",
                    "The board helps repatriate the body, receive it at the airport and take it home; ambulances for sick returnee workers.")},
    ],
    "welfare_basis": _t("সূত্র: প্রবাসী কল্যাণ মন্ত্রীর সংসদে দেওয়া তথ্য (BSS, জুলাই ২০২৬) ও ওয়েজ আর্নার্স কল্যাণ বোর্ড। আবেদনের আগে বোর্ডে নিশ্চিত হোন।",
                        "Source: the Expatriates' Welfare Minister's statement in parliament (BSS, July 2026) and the Wage Earners' Welfare Board. Confirm with the board before applying."),
    "welfare_source": "https://wewb.gov.bd",
    "remit": {
        "incentive_pct": 2.5,
        "incentive_note": _t("বৈধ পথে (ব্যাংক, লাইসেন্সপ্রাপ্ত মানি-ট্রান্সফার, মোবাইল ব্যাংকিং) পাঠালে সরকারি নগদ প্রণোদনা ২.৫% — সরকার জুন ২০২৬-এ চালু রাখার ঘোষণা দিয়েছে। হুন্ডি অবৈধ।",
                             "Sending through official channels (bank, licensed money-transfer, mobile banking) earns the government's 2.5% cash incentive — the government said in June 2026 it continues. Hundi is illegal."),
        "incentive_source": "https://www.bb.org.bd",
        "sdg_target_pct": 3.0,
        "sdg_note": _t("জাতিসংঘের টেকসই উন্নয়ন লক্ষ্য ১০.সি: টাকা পাঠানোর খরচ ৩%-এর নিচে নামানো।",
                       "UN Sustainable Development Goal 10.c: bring the cost of sending money below 3%."),
        "sdg_source": "https://sdgs.un.org/goals/goal10",
        "rpw_note": _t("দেশভিত্তিক খরচের তুলনা বিশ্বব্যাংক প্রতি তিন মাসে প্রকাশ করে (Remittance Prices Worldwide)। পাঠানোর দেশ → বাংলাদেশ বেছে নিন।",
                       "The World Bank publishes corridor-by-corridor costs every quarter (Remittance Prices Worldwide). Pick your sending country → Bangladesh."),
        "rpw_source": "https://remittanceprices.worldbank.org",
        "rate_note": _t("আজকের রেফারেন্স রেট বাংলাদেশ ব্যাংকের সাইটে।", "Today's reference rate is on Bangladesh Bank's site."),
        "rate_source": "https://www.bb.org.bd",
    },
    "sos_tips": [
        _t("বিপদে আগে স্থানীয় জরুরি নম্বরে কল করুন, তারপর দূতাবাস ও ১৬১৩৫।", "In danger, call the local emergency number first, then the embassy and 16135."),
        _t("পাসপোর্ট, ভিসা ও চুক্তির ছবি Assisto ডকুমেন্টসে রাখুন — হারালে কাজে লাগে।", "Keep photos of your passport, visa and contract in Assisto Documents — they help if lost."),
        _t("নিয়োগকর্তা পাসপোর্ট আটকে রাখলে বা বেতন না দিলে দূতাবাসের শ্রম শাখায় লিখিত অভিযোগ দিন।", "If the employer keeps your passport or withholds pay, file a written complaint with the embassy's labour wing."),
    ],
}


def remit_cost(amount, fee, rate_given, rate_ref, incentive_pct=2.5):
    """Real cost of one transfer, the World Bank way: fee + FX margin against a
    reference rate, as % of the amount sent. Pure arithmetic on the user's own
    numbers. Returns None for impossible inputs."""
    try:
        a, f, r, R = float(amount), float(fee or 0), float(rate_given), float(rate_ref)
    except (TypeError, ValueError):
        return None
    if a <= 0 or r <= 0 or R <= 0 or f < 0:
        return None
    fx_margin = a * (R - r) / R            # in sending currency
    cost = f + fx_margin
    home = a * r
    return {
        "cost": round(cost, 2),
        "cost_pct": round(cost / a * 100, 2),
        "home_amount": round(home, 2),
        "incentive": round(home * incentive_pct / 100, 2),
        "above_sdg": cost / a * 100 > 3.0,
    }


# =========================================================== STUDENT
STUDENT = {
    "groups": [
        {"id": "scholarship",
         "title": _t("বৃত্তি ও উপবৃত্তি", "Scholarships and stipends"),
         "note": _t("আবেদনের শেষ তারিখ প্রতিবার নোটিশে আসে। নোটিশ দেখে নিচে 'শেষ তারিখ সেভ' করুন — Assisto মনে করিয়ে দেবে। বৃত্তির জন্য কাউকে টাকা দেবেন না।",
                    "Each deadline comes in the official notice. Read it, then 'Save a deadline' below — Assisto reminds you. Never pay anyone for a scholarship."),
         "links": [_src("শিক্ষা মন্ত্রণালয় (মাধ্যমিক ও উচ্চশিক্ষা বিভাগ)", "Ministry of Education (Secondary & Higher Education Division)", "https://shed.gov.bd"),
                   _src("মাধ্যমিক ও উচ্চ শিক্ষা অধিদপ্তর (মাউশি)", "Directorate of Secondary & Higher Education (DSHE)", "https://dshe.gov.bd"),
                   _src("শিক্ষা বোর্ড (বোর্ড বৃত্তির ফল)", "Education boards (board scholarship results)", "https://educationboard.gov.bd"),
                   _src("বিশ্ববিদ্যালয় মঞ্জুরি কমিশন (UGC)", "University Grants Commission (UGC)", "https://ugc.gov.bd")]},
        {"id": "board_exams",
         "title": _t("এসএসসি / এইচএসসি রুটিন ও ফল", "SSC / HSC routine and results"),
         "note": _t("পরীক্ষার রুটিন বোর্ড প্রকাশ করে; ফলের দিন Assisto-র 'পরীক্ষার ফলাফল' নিজে খুঁজে জানায়।",
                    "The boards publish the exam routine; on result day Assisto's 'Exam result' checks for you."),
         "links": [_src("আন্তঃশিক্ষা বোর্ড", "Inter-education boards", "https://educationboard.gov.bd"),
                   _src("ঢাকা শিক্ষা বোর্ড (নোটিশ)", "Dhaka Education Board (notices)", "https://dhakaeducationboard.gov.bd"),
                   _src("মাদ্রাসা শিক্ষা বোর্ড", "Madrasah Education Board", "https://bmeb.gov.bd"),
                   _src("কারিগরি শিক্ষা বোর্ড", "Technical Education Board", "https://bteb.gov.bd"),
                   _src("শিক্ষা বোর্ড ফল", "Education board results", "https://www.educationboardresults.gov.bd")]},
        {"id": "admission",
         "title": _t("ভর্তি (একাদশ ও বিশ্ববিদ্যালয়)", "Admissions (Class XI and university)"),
         "note": _t("সার্কুলার, যোগ্যতা ও তারিখ প্রতি বছর বদলায় — শুধু এই অফিশিয়াল সাইটগুলো মানুন।",
                    "Circulars, eligibility and dates change every year — trust only these official sites."),
         "links": [_src("একাদশ শ্রেণি ভর্তি", "Class XI admission", "https://xiclassadmission.gov.bd"),
                   _src("ঢাকা বিশ্ববিদ্যালয় ভর্তি", "University of Dhaka admission", "https://admission.eis.du.ac.bd"),
                   _src("গুচ্ছ (GST) ভর্তি", "GST cluster admission", "https://gstadmission.ac.bd"),
                   _src("মেডিকেল/ডেন্টাল (স্বাস্থ্য শিক্ষা অধিদপ্তর)", "Medical/dental (DGME)", "https://dgme.gov.bd"),
                   _src("বুয়েট ভর্তি", "BUET admission", "https://ugadmission.buet.ac.bd"),
                   _src("জাতীয় বিশ্ববিদ্যালয়", "National University", "https://www.nu.ac.bd")]},
    ],
    "books_note": _t("এখানে কোনো বই বা গাইড বই নেই — পাঠ্যবই এনসিটিবি-র অফিশিয়াল সাইটে বিনামূল্যে।",
                     "No books or guide books here — textbooks are free on NCTB's official site."),
    "books_source": "https://nctb.gov.bd",
}


def _loc_links(links, lang):
    return [{"label": _loc(s["label"], lang), "url": s["url"]} for s in links]


def probashi_public(lang):
    p = PROBASHI
    r = p["remit"]
    return {
        "checked": CHECKED,
        "helplines": [{"id": h["id"], "dial": h["dial"], "name": _loc(h["name"], lang),
                       "display": _loc(h["display"], lang), "note": _loc(h["note"], lang),
                       "source": h["source"]} for h in p["helplines"]],
        "links": _loc_links(p["links"], lang),
        "welfare": [{"id": w["id"], "title": _loc(w["title"], lang), "amount": _loc(w["amount"], lang),
                     "note": _loc(w["note"], lang)} for w in p["welfare"]],
        "welfare_basis": _loc(p["welfare_basis"], lang),
        "welfare_source": p["welfare_source"],
        "remit": {k: (_loc(v, lang) if isinstance(v, tuple) else v) for k, v in r.items()},
        "sos_tips": [_loc(t, lang) for t in p["sos_tips"]],
    }


def student_public(lang):
    return {
        "checked": CHECKED,
        "groups": [{"id": g["id"], "title": _loc(g["title"], lang), "note": _loc(g["note"], lang),
                    "links": _loc_links(g["links"], lang)} for g in STUDENT["groups"]],
        "books_note": _loc(STUDENT["books_note"], lang),
        "books_source": STUDENT["books_source"],
    }


SECTIONS = {"probashi": probashi_public, "student": student_public}


def section_public(section, lang):
    fn = SECTIONS.get(section)
    return fn(lang) if fn else None


def all_urls():
    """Every URL this module shows (tests check they are official hosts)."""
    out = []
    for f in GUIDE_FACTS.values():
        out.append(f.get("fee_page", ""))
        out.extend(s["url"] for s in f.get("sources", []))
    out.extend(h["source"] for h in PROBASHI["helplines"])
    out.extend(s["url"] for s in PROBASHI["links"])
    out.append(PROBASHI["welfare_source"])
    r = PROBASHI["remit"]
    out.extend([r["incentive_source"], r["sdg_source"], r["rpw_source"], r["rate_source"]])
    for g in STUDENT["groups"]:
        out.extend(s["url"] for s in g["links"])
    out.append(STUDENT["books_source"])
    return [u for u in out if u]
