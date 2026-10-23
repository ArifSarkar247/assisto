"""
world_content.py — curated, ORIGINAL bilingual guide content for the Unseen
World hubs (p4-world): Jobs, Expats, Students, Farmers, Government services,
Health helpers.

Rules this content follows:
  * Written by Assisto in our own words — no article, job post or guide is
    copied. Every item points to the OFFICIAL site for the authoritative
    version, and carries a `reviewed` date + "verify on the official site".
  * Fees and figures are shown only with their official source; where a
    figure changes often we say so and link the official fee page instead of
    printing a number.
  * Pure data + a localiser. No Django, no network.
"""
from . import govt_guide as GG

REVIEWED = "2026-10-23"

VERIFY = ("তথ্য বদলাতে পারে — সিদ্ধান্তের আগে সরকারি/অফিশিয়াল সাইটে যাচাই করুন।",
          "Details can change — verify on the official site before you act.")


def _t(bn, en):
    return (bn, en)


def _link(bn, en, url):
    return {"label": (bn, en), "url": url}


def _item(id_, title, body=None, steps=None, docs=None, fee=None, fee_source="",
          links=None, tips=None, kind="guide"):
    return {"id": id_, "title": title, "body": body, "steps": steps, "docs": docs,
            "fee": fee, "fee_source": fee_source, "links": links or [],
            "tips": tips, "kind": kind, "reviewed": REVIEWED}


# =================================================================== JOBS
# Link-out portals. `feed` documents whether a LAWFUL machine feed exists
# (RSS / official API) that job alerts may use. Only Careerjet does (its
# publisher API, key-gated); the rest are link-out only.
JOB_CATEGORIES = [
    ("govt", "সরকারি", "Government"),
    ("bank", "ব্যাংক", "Bank"),
    ("private", "বেসরকারি", "Private"),
    ("overseas", "বিদেশে চাকরি", "Overseas"),
    ("ngo", "এনজিও", "NGO"),
]

JOB_PORTALS = [
    {"id": "bpsc", "cat": "govt", "url": "https://bpsc.gov.bd", "name": _t("বাংলাদেশ সরকারি কর্ম কমিশন (BPSC)", "Bangladesh Public Service Commission (BPSC)"),
     "desc": _t("বিসিএস ও নন-ক্যাডার নিয়োগ বিজ্ঞপ্তি, পরীক্ষার সূচি ও ফল।", "BCS and non-cadre circulars, exam schedules and results."), "feed": False},
    {"id": "teletalk", "cat": "govt", "url": "https://alljobs.teletalk.com.bd", "name": _t("টেলিটক সব সরকারি চাকরি", "Teletalk All Jobs"),
     "desc": _t("সরকারি দপ্তরের অনলাইন আবেদন, ফি পরিশোধ ও প্রবেশপত্র এক জায়গায়।", "Online applications, fee payment and admit cards for government offices."), "feed": False},
    {"id": "govportal", "cat": "govt", "url": "https://bangladesh.gov.bd", "name": _t("জাতীয় তথ্য বাতায়ন", "Bangladesh National Portal"),
     "desc": _t("মন্ত্রণালয় ও দপ্তরের নোটিশ বোর্ডে নিয়োগ বিজ্ঞপ্তি খুঁজুন।", "Find recruitment notices on ministry and office notice boards."), "feed": False},
    {"id": "bb", "cat": "bank", "url": "https://erecruitment.bb.org.bd", "name": _t("বাংলাদেশ ব্যাংক ই-রিক্রুটমেন্ট", "Bangladesh Bank e-Recruitment"),
     "desc": _t("বাংলাদেশ ব্যাংক ও সরকারি ব্যাংকের সমন্বিত নিয়োগ পরীক্ষার আবেদন।", "Applications for Bangladesh Bank and combined state-bank recruitment."), "feed": False},
    {"id": "bdjobs", "cat": "private", "url": "https://www.bdjobs.com", "name": _t("বিডিজবস", "Bdjobs.com"),
     "desc": _t("দেশের বড় বেসরকারি চাকরির পোর্টাল; সিভি তৈরি ও আবেদন সেখানেই।", "The country's large private-sector job portal; build your CV and apply there."), "feed": False},
    {"id": "chakri", "cat": "private", "url": "https://chakri.com", "name": _t("চাকরি ডট কম", "Chakri.com"),
     "desc": _t("বেসরকারি চাকরির বিজ্ঞপ্তি ও অনলাইন আবেদন।", "Private-sector job listings and online applications."), "feed": False},
    {"id": "linkedin", "cat": "private", "url": "https://www.linkedin.com/jobs", "name": _t("লিংকডইন জবস", "LinkedIn Jobs"),
     "desc": _t("দেশি-বিদেশি কোম্পানির চাকরি; প্রোফাইল হালনাগাদ রাখুন।", "Jobs at local and international companies; keep your profile up to date."), "feed": False},
    {"id": "careerjet", "cat": "private", "url": "https://www.careerjet.com.bd", "name": _t("ক্যারিয়ারজেট বাংলাদেশ", "Careerjet Bangladesh"),
     "desc": _t("বহু সাইটের চাকরি এক সার্চে খোঁজার ইঞ্জিন।", "A search engine that finds jobs across many sites."), "feed": True},
    {"id": "boesl", "cat": "overseas", "url": "https://www.boesl.gov.bd", "name": _t("বোয়েসেল (সরকারি রিক্রুটিং এজেন্সি)", "BOESL (government recruiting agency)"),
     "desc": _t("সরকারি ব্যবস্থাপনায় বিদেশে চাকরি — কম খরচে, প্রতারণার ঝুঁকি কম।", "Overseas jobs through the government agency — low cost, less fraud risk."), "feed": False},
    {"id": "ngoforum", "cat": "ngo", "url": "https://www.ngoforum.org.bd", "name": _t("এনজিও ফোরাম", "NGO Forum"),
     "desc": _t("পানি-স্যানিটেশন ও উন্নয়ন খাতের এনজিও চাকরি ও নোটিশ।", "NGO jobs and notices in water, sanitation and development."), "feed": False},
]

JOB_SAFETY = _t("চাকরির জন্য কাউকে আগাম টাকা দেবেন না। সরকারি চাকরির আবেদন ফি শুধু অফিশিয়াল পোর্টালে দিন। বিদেশে চাকরির এজেন্সির লাইসেন্স BMET সাইটে যাচাই করুন।",
                "Never pay anyone upfront for a job. Pay government application fees only on the official portal. Check an overseas agency's licence on the BMET site.")

# Alert job types -> Careerjet search keywords (English; the API is English).
JOB_TYPES = [
    ("govt", "সরকারি চাকরি", "Government jobs", "government"),
    ("bank", "ব্যাংক", "Banking", "bank officer"),
    ("it", "আইটি / সফটওয়্যার", "IT / software", "software developer"),
    ("teaching", "শিক্ষকতা", "Teaching", "teacher"),
    ("health", "স্বাস্থ্য / নার্সিং", "Health / nursing", "nurse doctor"),
    ("sales", "সেলস / মার্কেটিং", "Sales / marketing", "sales executive"),
    ("accounts", "হিসাব / ফাইন্যান্স", "Accounts / finance", "accountant"),
    ("garments", "গার্মেন্টস / টেক্সটাইল", "Garments / textile", "garments merchandiser"),
    ("driver", "ড্রাইভার", "Driver", "driver"),
    ("ngo", "এনজিও / উন্নয়ন", "NGO / development", "NGO program officer"),
]
JOB_TYPE_IDS = tuple(j[0] for j in JOB_TYPES)


def jobs_public(lang):
    i = 0 if lang == "bn" else 1
    return {
        "categories": [{"id": c[0], "name": c[1 + i]} for c in JOB_CATEGORIES],
        "portals": [{"id": p["id"], "cat": p["cat"], "url": p["url"], "name": p["name"][i],
                     "desc": p["desc"][i], "feed": p["feed"]} for p in JOB_PORTALS],
        "types": [{"id": j[0], "name": j[1 + i]} for j in JOB_TYPES],
        "safety": JOB_SAFETY[i],
        "feeds_note": (
            "শুধু ক্যারিয়ারজেটের অফিশিয়াল পার্টনার API থেকে সতর্কতা আসে। বাকি সাইটগুলোর কোনো উন্মুক্ত ফিড নেই, তাই সেগুলো শুধু লিংক — আমরা কোনো সাইট স্ক্র্যাপ বা কপি করি না।",
            "Alerts come only from Careerjet's official partner API. The other sites have no open feed, so they are links only — we never scrape or copy any site.")[i],
        "reviewed": REVIEWED,
    }


# =================================================================== EXPATS
_EXPAT_COMMON_STEPS = (
    ["রিক্রুটিং এজেন্সির লাইসেন্স BMET সাইটে যাচাই করুন (বা সরকারি BOESL ব্যবহার করুন)",
     "লিখিত চাকরির চুক্তি ও ভিসা হাতে নিন — বেতন, কাজ, থাকা-খাওয়া চুক্তিতে মিলিয়ে নিন",
     "অনুমোদিত কেন্দ্রে মেডিকেল পরীক্ষা করান",
     "প্রাক-বহির্গমন প্রশিক্ষণ (PDO) নিন",
     "BMET থেকে বহির্গমন ছাড়পত্র (স্মার্ট কার্ড) নিন — এটি ছাড়া বৈধভাবে যাওয়া যায় না",
     "ওয়েজ আর্নার্স কল্যাণ বোর্ডে নিবন্ধন হয়েছে কিনা দেখে নিন",
     "পাসপোর্ট, ভিসা, চুক্তির কপি পরিবারের কাছে ও ফোনের ভল্টে রাখুন"],
    ["Check the recruiting agency's licence on the BMET site (or use the government agency BOESL)",
     "Get a written job contract and the visa — match salary, work, food and housing to the contract",
     "Do the medical test at an approved centre",
     "Attend pre-departure orientation (PDO)",
     "Get BMET emigration clearance (smart card) — you cannot leave legally without it",
     "Make sure you are registered with the Wage Earners' Welfare Board",
     "Keep copies of passport, visa and contract with family and in your phone vault"])

_COUNTRIES = [
    ("ksa", _t("সৌদি আরব", "Saudi Arabia"),
     _t("কাজের ভিসা নিয়োগকর্তার স্পনসরে হয়। পৌঁছানোর পর ইকামা (বসবাসের অনুমতি) করাতে হয়। গৃহকর্মীর নিয়োগ মুসানেদ প্ল্যাটফর্মে নিবন্ধিত হয়। স্পনসরের বাইরে অন্য কোথাও কাজ করা আইনত ঝুঁকিপূর্ণ।",
        "Work visas are sponsored by the employer. After arrival you need an iqama (residence permit). Domestic-worker hiring is registered on the Musaned platform. Working for anyone other than your sponsor is legally risky."),
     [_link("সৌদি ভিসা প্ল্যাটফর্ম", "Saudi visa platform", "https://visa.mofa.gov.sa"),
      _link("মুসানেদ (গৃহকর্মী)", "Musaned (domestic workers)", "https://musaned.com.sa"),
      _link("আবশের (ইকামা সেবা)", "Absher (iqama services)", "https://www.absher.sa")]),
    ("uae", _t("সংযুক্ত আরব আমিরাত", "United Arab Emirates"),
     _t("ওয়ার্ক পারমিট দেয় শ্রম মন্ত্রণালয় (MOHRE), রেসিডেন্স ভিসা ও এমিরেটস আইডি হয় ICP/GDRFA-তে। বেতন সাধারণত ওয়েজ প্রোটেকশন সিস্টেমে ব্যাংকে আসে। চুক্তি MOHRE সাইটে যাচাই করা যায়।",
        "Work permits come from the labour ministry (MOHRE); the residence visa and Emirates ID from ICP/GDRFA. Salary is normally paid into a bank through the Wage Protection System. Contracts can be checked on the MOHRE site."),
     [_link("MOHRE (শ্রম মন্ত্রণালয়)", "MOHRE (labour ministry)", "https://www.mohre.gov.ae"),
      _link("ICP (ভিসা ও আইডি)", "ICP (visa & ID)", "https://icp.gov.ae")]),
    ("qatar", _t("কাতার", "Qatar"),
     _t("ঢাকার কাতার ভিসা সেন্টারে (QVC) মেডিকেল, আঙুলের ছাপ ও চুক্তি সই হয়। পৌঁছানোর পর কাতার আইডি (QID) করাতে হয়। শ্রম মন্ত্রণালয়ে অভিযোগ জানানো যায়।",
        "Medical, fingerprints and contract signing happen at the Qatar Visa Center (QVC) in Dhaka. After arrival you get a Qatar ID (QID). Complaints can be filed with the labour ministry."),
     [_link("কাতার ভিসা সেন্টার", "Qatar Visa Center", "https://www.qvc.gov.qa"),
      _link("কাতার শ্রম মন্ত্রণালয়", "Qatar Ministry of Labour", "https://www.mol.gov.qa")]),
    ("oman", _t("ওমান", "Oman"),
     _t("নিয়োগকর্তা শ্রম মন্ত্রণালয় থেকে অনুমতি নিয়ে ভিসা করান; রয়্যাল ওমান পুলিশ ভিসা ও রেসিডেন্ট কার্ড দেয়।",
        "The employer gets labour-ministry approval and applies for the visa; Royal Oman Police issues visas and resident cards."),
     [_link("ওমান শ্রম মন্ত্রণালয়", "Oman Ministry of Labour", "https://www.mol.gov.om"),
      _link("রয়্যাল ওমান পুলিশ ই-ভিসা", "Royal Oman Police e-visa", "https://evisa.rop.gov.om")]),
    ("kuwait", _t("কুয়েত", "Kuwait"),
     _t("কাজের অনুমতি দেয় পাবলিক অথরিটি ফর ম্যানপাওয়ার; পৌঁছানোর পর সিভিল আইডি করাতে হয়।",
        "Work permits come from the Public Authority for Manpower; after arrival you need a Civil ID."),
     [_link("পাবলিক অথরিটি ফর ম্যানপাওয়ার", "Public Authority for Manpower", "https://www.manpower.gov.kw"),
      _link("সিভিল আইডি (PACI)", "Civil ID (PACI)", "https://www.paci.gov.kw")]),
    ("malaysia", _t("মালয়েশিয়া", "Malaysia"),
     _t("কর্মী নিয়োগ দুই সরকারের চুক্তি ও অনুমোদিত এজেন্সির মাধ্যমে হয় এবং বাজার কখনো খোলা, কখনো বন্ধ থাকে। যাওয়ার আগে BMET-এ বর্তমান অবস্থা জেনে নিন।",
        "Workers are hired under government-to-government arrangements through approved agencies, and the market opens and closes from time to time. Check the current status with BMET before you commit."),
     [_link("মালয়েশিয়া ইমিগ্রেশন", "Malaysia Immigration", "https://www.imi.gov.my")]),
    ("singapore", _t("সিঙ্গাপুর", "Singapore"),
     _t("ওয়ার্ক পারমিট বা এস পাস নিয়োগকর্তা মিনিস্ট্রি অব ম্যানপাওয়ার (MOM) থেকে করেন। MOM-এর সাইটে নিজের ওয়ার্ক পাস যাচাই করা যায়।",
        "The employer applies to the Ministry of Manpower (MOM) for a Work Permit or S Pass. You can check your own work pass on MOM's site."),
     [_link("মিনিস্ট্রি অব ম্যানপাওয়ার", "Ministry of Manpower", "https://www.mom.gov.sg")]),
    ("italy", _t("ইতালি", "Italy"),
     _t("কাজের ভিসা হয় ইতালির বার্ষিক কোটা (ডিক্রেতো ফ্লুসি) অনুযায়ী — নিয়োগকর্তা ইতালিতে 'নুল্লা ওস্তা' (অনুমতি) নেন, তারপর ঢাকার ইতালীয় দূতাবাসে ভিসার আবেদন। 'নিশ্চিত ইতালি ভিসা' বলে টাকা চাওয়া দালাল থেকে সাবধান।",
        "Work visas follow Italy's annual quota (Decreto Flussi): the employer gets a 'nulla osta' (clearance) in Italy, then you apply at the Italian Embassy in Dhaka. Beware of brokers selling a 'guaranteed Italy visa'."),
     [_link("ঢাকায় ইতালীয় দূতাবাস", "Embassy of Italy, Dhaka", "https://ambdhaka.esteri.it")]),
    ("uk", _t("যুক্তরাজ্য", "United Kingdom"),
     _t("স্কিলড ওয়ার্কার ভিসার জন্য লাইসেন্সপ্রাপ্ত স্পনসর ও সার্টিফিকেট অব স্পনসরশিপ লাগে, ইংরেজির শর্তও আছে। নিয়োগকর্তা লাইসেন্সপ্রাপ্ত কিনা gov.uk-এর তালিকায় দেখুন।",
        "A Skilled Worker visa needs a licensed sponsor and a Certificate of Sponsorship, plus an English requirement. Check that the employer is on gov.uk's register of licensed sponsors."),
     [_link("স্কিলড ওয়ার্কার ভিসা (gov.uk)", "Skilled Worker visa (gov.uk)", "https://www.gov.uk/skilled-worker-visa"),
      _link("লাইসেন্সপ্রাপ্ত স্পনসরের তালিকা", "Register of licensed sponsors", "https://www.gov.uk/government/publications/register-of-licensed-sponsors-workers")]),
]

_EXPAT_OFFICIAL = [
    _link("BMET (জনশক্তি, কর্মসংস্থান ও প্রশিক্ষণ ব্যুরো)", "BMET (Bureau of Manpower, Employment and Training)", "https://www.bmet.gov.bd"),
    _link("প্রবাসী কল্যাণ ও বৈদেশিক কর্মসংস্থান মন্ত্রণালয়", "Ministry of Expatriates' Welfare and Overseas Employment", "https://probashi.gov.bd"),
    _link("ওয়েজ আর্নার্স কল্যাণ বোর্ড", "Wage Earners' Welfare Board", "https://wewb.gov.bd"),
    _link("বোয়েসেল (সরকারি রিক্রুটিং এজেন্সি)", "BOESL (government recruiting agency)", "https://www.boesl.gov.bd"),
    _link("প্রবাসী কল্যাণ ব্যাংক", "Probashi Kallyan Bank", "https://www.pkb.gov.bd"),
    _link("আমি প্রবাসী (অফিশিয়াল অ্যাপ/সাইট)", "Ami Probashi (official app/site)", "https://www.amiprobashi.com"),
    _link("বিদেশে বাংলাদেশ দূতাবাস/মিশন", "Bangladesh missions abroad", "https://mofa.gov.bd"),
]

EXPAT = {
    "id": "expat",
    "intro": _t("বিদেশে কাজ, ভিসা ও দেশে টাকা পাঠানোর সঠিক ও নিরাপদ পথ — সব লিংক অফিশিয়াল।",
                "The right, safe way to work abroad, get a visa and send money home — every link is official."),
    "sections": [
        {"id": "steps", "title": _t("বিদেশ যাওয়ার ধাপ", "Steps before you go"), "items": [
            _item("steps", _t("সবার জন্য জরুরি ধাপ", "Must-do steps for everyone"),
                  body=_t("যেকোনো দেশে যাওয়ার আগে এই ধাপগুলো মানলে প্রতারণা ও বিপদের ঝুঁকি অনেক কমে।",
                          "Following these steps before any country cuts the risk of fraud and trouble a lot."),
                  steps=_EXPAT_COMMON_STEPS,
                  links=[_link("লাইসেন্সপ্রাপ্ত এজেন্সির তালিকা (BMET)", "Licensed agencies (BMET)", "https://www.bmet.gov.bd")])]},
        {"id": "visa", "title": _t("দেশভিত্তিক ভিসার মূল কথা", "Visa basics by country"), "items": [
            _item(c[0], c[1], body=c[2], links=c[3]) for c in _COUNTRIES]},
        {"id": "remit", "title": _t("টাকা পাঠানো (রেমিট্যান্স)", "Sending money home"), "items": [
            _item("remit_official", _t("শুধু বৈধ পথে পাঠান", "Use official channels only"),
                  body=_t("ব্যাংক, বৈধ মানি-ট্রান্সফার কোম্পানি বা মোবাইল ব্যাংকিংয়ের (বিকাশ, নগদ ইত্যাদি) রেমিট্যান্স সেবায় পাঠান। বৈধ পথে পাঠালে সরকারি প্রণোদনা পাওয়া যায় (হার সময়ে সময়ে বদলায় — বাংলাদেশ ব্যাংকে দেখুন)। হুন্ডি অবৈধ — টাকা হারানো ও আইনি ঝুঁকি আছে। Assisto কখনো আপনার টাকা রাখে বা পাঠায় না।",
                          "Send through a bank, a licensed money-transfer company or a mobile-banking remittance service (bKash, Nagad, etc.). Official channels earn the government incentive (the rate changes — see Bangladesh Bank). Hundi is illegal and you can lose the money. Assisto never holds or sends your money."),
                  steps=(["প্রেরণের আগে মোট খরচ (ফি + হার) মিলিয়ে দেখুন — দেশে কত টাকা পৌঁছাবে সেটাই আসল",
                          "প্রাপকের নাম ও নম্বর দুবার মিলিয়ে নিন",
                          "রসিদ/রেফারেন্স নম্বর রেখে দিন",
                          "প্রবাসী কর্নারে প্রতিটি পাঠানো টাকা লিখে রাখুন"],
                         ["Before sending, compare the total cost (fee + rate) — what reaches home is what counts",
                          "Double-check the receiver's name and number",
                          "Keep the receipt / reference number",
                          "Log every transfer in Probashi corner"]),
                  links=[_link("বাংলাদেশ ব্যাংক", "Bangladesh Bank", "https://www.bb.org.bd"),
                         _link("বিকাশ রেমিট্যান্স", "bKash remittance", "https://www.bkash.com"),
                         _link("নগদ", "Nagad", "https://nagad.com.bd")])]},
        {"id": "rules", "title": _t("জরুরি নিয়ম ও সহায়তা", "Key rules and help"), "items": [
            _item("rules_core", _t("মনে রাখার মতো কথা", "Things to remember"),
                  tips=(["নিজের পাসপোর্ট নিজের কাছে রাখার চেষ্টা করুন — অনেক দেশে নিয়োগকর্তার পাসপোর্ট আটকে রাখা বেআইনি",
                         "চুক্তির বাইরে কাজ বা বেতন কম হলে দূতাবাসের শ্রম শাখায় জানান",
                         "ভিসার মেয়াদ শেষ হওয়ার আগে নবায়ন করুন — অবৈধ অবস্থান জেল/জরিমানার কারণ",
                         "বিপদে ওয়েজ আর্নার্স কল্যাণ বোর্ড আর্থিক সহায়তা ও লাশ দেশে আনার সহায়তা দেয়"],
                        ["Try to keep your passport yourself — in many countries an employer holding it is illegal",
                         "If work or pay does not match the contract, tell the embassy's labour wing",
                         "Renew your visa before it expires — overstaying can mean jail or fines",
                         "In an emergency the Wage Earners' Welfare Board gives financial help and repatriation support"]),
                  links=_EXPAT_OFFICIAL)]},
    ],
    "screens": ["probashi"],
    "ai": True,
}

# =================================================================== STUDENTS
STUDENTS = {
    "id": "students",
    "intro": _t("ফল, ভর্তি আর বিসিএস প্রস্তুতি — অফিশিয়াল লিংক ও অনুশীলন এক জায়গায়।",
                "Results, admissions and BCS prep — official links and practice in one place."),
    "sections": [
        {"id": "results", "title": _t("এসএসসি / এইচএসসি ফল", "SSC / HSC results"), "items": [
            _item("results_web", _t("অনলাইনে ফল দেখুন", "Check results online"),
                  body=_t("শিক্ষা বোর্ডের অফিশিয়াল সাইটে পরীক্ষা, বছর, বোর্ড, রোল ও রেজিস্ট্রেশন দিয়ে ফল দেখা যায়। ফলের দিন সাইট ধীর হতে পারে — একটু পর আবার চেষ্টা করুন।",
                          "Results are on the education board's official site using exam, year, board, roll and registration. On result day the site can be slow — try again a little later."),
                  steps=(["এসএমএসে: SSC <স্পেস> বোর্ডের প্রথম ৩ অক্ষর <স্পেস> রোল <স্পেস> বছর লিখে ১৬২২২ নম্বরে পাঠান (যেমন SSC DHA 123456 2026)",
                          "এইচএসসির জন্য SSC-এর জায়গায় HSC লিখুন",
                          "মাদ্রাসা ও কারিগরি বোর্ডের জন্য নিজ বোর্ডের সাইট দেখুন"],
                         ["By SMS: type SSC <space> first 3 letters of the board <space> roll <space> year and send to 16222 (e.g. SSC DHA 123456 2026)",
                          "For HSC write HSC instead of SSC",
                          "For Madrasah and Technical boards, use your own board's site"]),
                  links=[_link("শিক্ষা বোর্ড ফল", "Education board results", "http://www.educationboardresults.gov.bd"),
                         _link("ওয়েব ভিত্তিক ফল (প্রতিষ্ঠানসহ)", "Web-based results (with institution)", "https://www.eboardresults.com"),
                         _link("মাদ্রাসা বোর্ড", "Madrasah board", "https://bmeb.gov.bd"),
                         _link("কারিগরি শিক্ষা বোর্ড", "Technical education board", "https://www.bteb.gov.bd")])]},
        {"id": "admission", "title": _t("ভর্তি তথ্য", "Admission info"), "items": [
            _item("adm_links", _t("অফিশিয়াল ভর্তি সাইট", "Official admission sites"),
                  body=_t("ভর্তির সার্কুলার, যোগ্যতা ও তারিখ প্রতি বছর বদলায় — শুধু অফিশিয়াল সাইটের তথ্য মানুন।",
                          "Circulars, eligibility and dates change every year — follow only the official site."),
                  links=[_link("একাদশ শ্রেণি ভর্তি", "Class XI admission", "http://xiclassadmission.gov.bd"),
                         _link("ঢাকা বিশ্ববিদ্যালয় ভর্তি", "University of Dhaka admission", "https://admission.eis.du.ac.bd"),
                         _link("গুচ্ছ (GST) ভর্তি", "GST cluster admission", "https://gstadmission.ac.bd"),
                         _link("মেডিকেল/ডেন্টাল (স্বাস্থ্য শিক্ষা অধিদপ্তর)", "Medical/dental (DGME)", "https://dgme.gov.bd"),
                         _link("বুয়েট ভর্তি", "BUET admission", "https://ugadmission.buet.ac.bd"),
                         _link("জাতীয় বিশ্ববিদ্যালয়", "National University", "https://www.nu.ac.bd"),
                         _link("বিশ্ববিদ্যালয় মঞ্জুরি কমিশন (স্বীকৃত বিশ্ববিদ্যালয়)", "UGC (recognised universities)", "http://www.ugc.gov.bd")])]},
        {"id": "bcs", "title": _t("বিসিএস প্রস্তুতি", "BCS preparation"), "items": [
            _item("bcs_info", _t("বিসিএস: কোথা থেকে শুরু", "BCS: where to start"),
                  body=_t("সার্কুলার, সিলেবাস ও ফল বিপিএসসি-র সাইটে আসে। নিচের অনুশীলনে আমাদের নিজেদের লেখা প্রশ্ন দিয়ে সাধারণ জ্ঞান, বাংলা, ইংরেজি ও গণিত চর্চা করুন।",
                          "Circulars, syllabus and results are on BPSC's site. Practise general knowledge, Bangla, English and maths below with questions written by Assisto."),
                  links=[_link("বিপিএসসি", "BPSC", "https://bpsc.gov.bd")], kind="mcq")]},
    ],
    "screens": ["exam_result", "student_corner"],
    "ai": True,
}

# =================================================================== FARMERS
FARMERS = {
    "id": "farmers",
    "intro": _t("ফসলের ছবি তুলে রোগ চিনুন, সঠিক পরামর্শ কোথায় পাবেন জানুন।",
                "Photograph a crop to recognise a problem, and know where to get the right advice."),
    "photo": "crop",
    "sections": [
        {"id": "help", "title": _t("সরাসরি পরামর্শ", "Talk to an expert"), "items": [
            _item("call", _t("কৃষি কল সেন্টার ১৬১২৩", "Krishi Call Centre 16123"),
                  body=_t("কৃষি তথ্য সার্ভিসের কল সেন্টারে যেকোনো মোবাইল থেকে ১৬১২৩ নম্বরে ফোন করে ফসল, মাছ ও গবাদিপশুর সমস্যার পরামর্শ পাওয়া যায় (প্রতি মিনিট প্রায় ২৫ পয়সা + ভ্যাট)। নিকটের উপজেলা কৃষি অফিসার মাঠে এসে দেখতেও পারেন।",
                          "Call 16123 from any mobile to reach the Agriculture Information Service call centre for advice on crops, fish and livestock (about 25 paisa a minute + VAT). Your Upazila Agriculture Officer can also visit the field."),
                  links=[_link("কৃষি তথ্য সার্ভিস", "Agriculture Information Service", "http://www.ais.gov.bd"),
                         _link("কৃষি সম্প্রসারণ অধিদপ্তর", "Department of Agricultural Extension", "http://www.dae.gov.bd"),
                         _link("প্রাণিসম্পদ অধিদপ্তর", "Department of Livestock Services", "http://www.dls.gov.bd"),
                         _link("মৎস্য অধিদপ্তর", "Department of Fisheries", "http://www.fisheries.gov.bd")], kind="call")]},
        {"id": "safe", "title": _t("নিরাপদ বালাইনাশক ব্যবহার", "Safe pesticide use"), "items": [
            _item("label", _t("লেবেলই আসল নিয়ম", "The label is the rule"),
                  tips=(["শুধু প্যাকেটের লেবেলে লেখা মাত্রা ও নিয়ম মানুন — বেশি দিলে ফসল, মাটি ও শরীরের ক্ষতি",
                         "লাইসেন্সধারী ডিলারের কাছ থেকে কিনুন, মেয়াদ দেখে নিন",
                         "স্প্রের সময় মাস্ক, গ্লাভস ও ফুলহাতা জামা পরুন; বাতাসের উল্টো দিকে স্প্রে করবেন না",
                         "লেবেলে লেখা 'ফসল তোলার আগে অপেক্ষার দিন' মেনে চলুন",
                         "খালি বোতল পুকুর-নদীতে ফেলবেন না, শিশুদের নাগালের বাইরে রাখুন"],
                        ["Use only the rate and method printed on the label — more harms the crop, soil and your body",
                         "Buy from a licensed dealer and check the expiry date",
                         "Wear a mask, gloves and long sleeves when spraying; never spray into the wind",
                         "Respect the 'days before harvest' written on the label",
                         "Never throw empty bottles in ponds or rivers; keep them away from children"]))]},
        {"id": "info", "title": _t("আবহাওয়া ও গবেষণা তথ্য", "Weather and research info"), "items": [
            _item("research", _t("নির্ভরযোগ্য সূত্র", "Reliable sources"),
                  links=[_link("কৃষি আবহাওয়া তথ্য (BAMIS)", "Agro-weather (BAMIS)", "https://www.bamis.gov.bd"),
                         _link("বাংলাদেশ আবহাওয়া অধিদপ্তর", "Bangladesh Meteorological Department", "https://live.bmd.gov.bd"),
                         _link("ধান গবেষণা ইনস্টিটিউট (BRRI)", "Rice Research Institute (BRRI)", "https://brri.gov.bd"),
                         _link("কৃষি গবেষণা ইনস্টিটিউট (BARI)", "Agricultural Research Institute (BARI)", "https://bari.gov.bd")])]},
    ],
    "screens": ["farmer_mode"],
    "ai": True,
}

# =================================================================== GOV
_GOV_KEYS = ("epassport", "nid", "birth", "driving", "porcha")


def _gov_from_guide(svc):
    tips = (svc["mistakes_bn"], svc["mistakes_en"])
    return _item(svc["key"], (svc["name_bn"], svc["name_en"]),
                 body=((svc["office_bn"] + " · " + svc["time_bn"]), (svc["office_en"] + " · " + svc["time_en"])),
                 steps=(svc["steps_bn"], svc["steps_en"]),
                 docs=(svc["docs_bn"], svc["docs_en"]),
                 fee=(svc["fee_bn"], svc["fee_en"]), fee_source=svc["url"],
                 links=[_link(svc["portal"], svc["portal"], svc["url"])] if svc.get("url") else [],
                 tips=tips, kind="service")


_EMUTATION = _item(
    "emutation", _t("জমির ই-নামজারি (ই-মিউটেশন)", "Land e-mutation (e-namjari)"),
    body=_t("জমি কেনা বা উত্তরাধিকারে পাওয়ার পর নিজের নামে খতিয়ান খোলাকে নামজারি বলে। এখন এটি অনলাইনে আবেদন করা যায়; শুনানির তারিখে সহকারী কমিশনার (ভূমি) অফিসে কাগজ নিয়ে যেতে হয়।",
            "Mutation (namjari) opens the land record in your name after you buy or inherit land. You can apply online; on the hearing date you bring the papers to the Assistant Commissioner (Land) office."),
    steps=(["ভূমি মন্ত্রণালয়ের ই-নামজারি সাইটে মোবাইল নম্বর দিয়ে আবেদন শুরু করুন",
            "জমির তথ্য (মৌজা, খতিয়ান, দাগ) ও মালিকানার কাগজ আপলোড করুন",
            "অনলাইনে আবেদন ফি দিন",
            "এসএমএসে শুনানির তারিখ আসবে — মূল কাগজ নিয়ে এসি ল্যান্ড অফিসে যান",
            "অনুমোদনের পর ডিসিআর ফি দিয়ে নতুন খতিয়ান নিন"],
           ["Start the application on the Ministry of Land e-mutation site with your mobile number",
            "Enter the land details (mouza, khatian, dag) and upload ownership papers",
            "Pay the application fee online",
            "You get the hearing date by SMS — bring the original papers to the AC Land office",
            "After approval pay the DCR fee and get the new khatian"]),
    docs=(["দলিলের কপি (বা উত্তরাধিকার সনদ)", "আগের খতিয়ান / পর্চা", "জাতীয় পরিচয়পত্র", "ভূমি উন্নয়ন কর পরিশোধের রসিদ", "ছবি"],
          ["Copy of the deed (or succession certificate)", "Previous khatian / porcha", "National ID", "Land development tax receipt", "Photo"]),
    fee=_t("ভূমি মন্ত্রণালয়ের প্রকাশিত মোট ফি ১,১৭০ টাকা (কোর্ট ফি ২০ + নোটিশ জারি ৫০ + রেকর্ড সংশোধন ১,০০০ + খতিয়ান সরবরাহ ১০০)। পরিবর্তন হতে পারে — সাইটে যাচাই করুন।",
           "Ministry of Land published total fee: Tk 1,170 (court fee 20 + notice 50 + record correction 1,000 + khatian copy 100). It can change — verify on the site."),
    fee_source="https://mutation.land.gov.bd",
    links=[_link("ই-নামজারি", "e-Mutation", "https://mutation.land.gov.bd"),
           _link("ভূমি মন্ত্রণালয়", "Ministry of Land", "https://land.gov.bd")],
    tips=(["দালালকে টাকা দেবেন না — সব ফি অনলাইনে দেওয়া যায়", "শুনানির দিন মূল কাগজ ছাড়া গেলে আবেদন আটকে যায়"],
          ["Do not pay brokers — every fee can be paid online", "Going to the hearing without the original papers stalls the case"]),
    kind="service")


def _gov_items():
    by_key = {s["key"]: s for s in GG.SERVICES}
    items = [_gov_from_guide(by_key[k]) for k in _GOV_KEYS if k in by_key]
    items.append(_EMUTATION)
    return items


GOV = {
    "id": "gov",
    "intro": _t("পাসপোর্ট, এনআইডি, জন্ম নিবন্ধন, জমি ও ড্রাইভিং লাইসেন্স — ধাপ, কাগজ, ফি ও অফিশিয়াল লিংক।",
                "Passport, NID, birth registration, land and driving licence — steps, documents, fees and official links."),
    "sections": [{"id": "services", "title": _t("সেবাগুলো", "Services"), "items": None}],
    "screens": ["service_guide"],
    "ai": True,
    "form_help": True,
}

# =================================================================== HEALTH
HEALTH = {
    "id": "health",
    "intro": _t("প্রেসক্রিপশন পড়া ও স্বাস্থ্য সহায়তার নম্বর। সব সময় ডাক্তার বা ফার্মাসিস্টের পরামর্শ নিন।",
                "Read a prescription and find health helplines. Always consult a doctor or pharmacist."),
    "photo": "rx",
    "sections": [
        {"id": "helplines", "title": _t("সহায়তার নম্বর", "Helplines"), "items": [
            _item("hl_16263", _t("স্বাস্থ্য বাতায়ন ১৬২৬৩", "Shasthya Batayon 16263"),
                  body=_t("সরকারি স্বাস্থ্য কল সেন্টার — ডাক্তারের পরামর্শ ও হাসপাতালের তথ্য, ২৪ ঘণ্টা।",
                          "Government health call centre — doctor advice and hospital information, 24 hours."),
                  links=[_link("স্বাস্থ্য অধিদপ্তর", "Directorate General of Health Services", "https://dghs.gov.bd")], kind="call"),
            _item("hl_999", _t("জাতীয় জরুরি সেবা ৯৯৯", "National emergency 999"),
                  body=_t("অ্যাম্বুলেন্স, পুলিশ ও ফায়ার সার্ভিস — বিনা খরচে।", "Ambulance, police and fire service — free of charge."), kind="call")]},
        {"id": "medicine", "title": _t("ওষুধের তথ্য", "Medicine information"), "items": [
            _item("dgda", _t("ওষুধের অফিশিয়াল তথ্য ও দাম", "Official medicine information and price"),
                  body=_t("ওষুধের নিবন্ধন ও সরকার-নির্ধারিত দামের অফিশিয়াল উৎস ঔষধ প্রশাসন অধিদপ্তর (DGDA)। ভিন্ন কোম্পানির একই ওষুধে বদলানোর আগে ডাক্তার/ফার্মাসিস্টকে জিজ্ঞেস করুন।",
                          "The official source for medicine registration and government-set prices is the Directorate General of Drug Administration (DGDA). Ask a doctor or pharmacist before switching to another company's version."),
                  links=[_link("ঔষধ প্রশাসন অধিদপ্তর", "DGDA", "https://dgda.gov.bd")])]},
    ],
    "screens": ["medicine_db"],
    "ai": False,
}

HUBS = {"expat": EXPAT, "students": STUDENTS, "farmers": FARMERS, "gov": GOV, "health": HEALTH}

# Short, hub-specific instructions for the paid AI helper (ai.generate).
AI_TASK = {
    "expat": ("You help a Bangladeshi worker going or living abroad. Explain clearly and practically. "
              "Only official channels for jobs, visas and money; warn about brokers and hundi; never promise a visa. "
              "End by saying to verify on the official site (BMET, the embassy or the destination's government)."),
    "students": ("You help a Bangladeshi student with study, exam and admission questions. Explain step by step. "
                 "For dates, circulars and results tell them to check the official board/university site."),
    "farmers": ("You help a Bangladeshi farmer. Give practical, general crop/livestock advice. Never give a pesticide "
                "dose or mix ratio — say to follow the label. Always end with: ask your Upazila Agriculture Officer "
                "or call 16123 (Krishi Call Centre)."),
    "gov": ("You help fill Bangladeshi government service forms (passport, NID, birth registration, land mutation, "
            "driving licence). Explain what each field means and draft the text the user can copy. Never submit "
            "anything, never ask for passwords, OTPs or full ID numbers, and say the official portal is the authority."),
}
AI_TASK_NOTE = {
    "expat": VERIFY,
    "students": VERIFY,
    "farmers": ("নিশ্চিত হতে উপজেলা কৃষি অফিসারের সাথে কথা বলুন বা ১৬১২৩ নম্বরে ফোন করুন।",
                "To be sure, talk to your Upazila Agriculture Officer or call 16123."),
    "gov": ("Assisto কোনো ফর্ম জমা দেয় না — লেখাটি কপি করে নিজে অফিশিয়াল পোর্টালে বসান ও মিলিয়ে নিন।",
            "Assisto never submits a form — copy the text into the official portal yourself and check it."),
}


def _loc(v, i):
    if isinstance(v, tuple):
        return v[i]
    return v


def _loc_item(it, i):
    out = {"id": it["id"], "kind": it["kind"], "reviewed": it["reviewed"],
           "title": _loc(it["title"], i)}
    for k in ("body", "steps", "docs", "fee", "tips"):
        if it.get(k):
            out[k] = _loc(it[k], i)
    if it.get("fee_source"):
        out["fee_source"] = it["fee_source"]
    out["links"] = [{"label": _loc(l["label"], i), "url": l["url"]} for l in it.get("links") or []]
    return out


def hub_public(hub_id, lang):
    hub = HUBS.get(hub_id)
    if not hub:
        return None
    i = 0 if lang == "bn" else 1
    secs = []
    for s in hub["sections"]:
        items = s["items"] if s["items"] is not None else _gov_items()
        secs.append({"id": s["id"], "title": s["title"][i],
                     "items": [_loc_item(it, i) for it in items]})
    return {"id": hub_id, "intro": hub["intro"][i], "sections": secs,
            "screens": hub.get("screens", []), "photo": hub.get("photo", ""),
            "ai": bool(hub.get("ai")), "form_help": bool(hub.get("form_help")),
            "verify": VERIFY[i], "reviewed": REVIEWED}


def all_links():
    """Every official URL in the content (for the link-shape test)."""
    out = [p["url"] for p in JOB_PORTALS]
    for hid in HUBS:
        for s in hub_public(hid, "en")["sections"]:
            for it in s["items"]:
                out += [l["url"] for l in it["links"]]
                if it.get("fee_source"):
                    out.append(it["fee_source"])
    return out
