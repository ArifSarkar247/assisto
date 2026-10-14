"""
govt_guide (ADVANCED) — Bangladesh government / public-service "how-to" guides.

This is the ADVANCED upgrade of feature 30 (was: a flat list of service names +
a few steps). It provides, for each real BD service, a full how-to card:

  * step-by-step process,
  * required-documents checklist,
  * fees,
  * where / which office,
  * official online link(s),
  * typical processing time,
  * common mistakes people make,
  * a source note + a "verify on the official portal" disclaimer.

HARD RULE ON FEES/FIGURES  ───────────────────────────────────────────────────
We do NOT invent fees or legally-binding figures. Every `fee` string is written
as guidance only and is paired with `fee_verify = True` plus a `source` (the
official portal). The UI MUST render the "verify on official portal" disclaimer
beside any fee/time. Where an exact amount is genuinely well-known and public
(e.g. an application form being free) we still mark it verify-on-portal because
gazette rates change. When unsure, the fee text itself says "verify on the
official portal". This mirrors best-in-class gov how-to apps (gov.uk, Singapore
LifeSG) which always link to the authoritative source.

Content is ORIGINAL bilingual summary text (bn + en), not copied from any site.
Steps are general guidance; the official portal is the authority.

The module is pure data + pure functions (no DB, no network, no AI) so it is
safe to localise server-side via core/views.py#govt_guide and equally safe for
the app to cache offline. Keep the category/service keys in lockstep with
app/lib/widgets/guide_data.dart.
"""

from ..i18n import localise, pick

# ---------------------------------------------------------------------------
# Categories a Bangladeshi user actually searches for.
# ---------------------------------------------------------------------------
CATEGORIES = [
    {"key": "identity", "name_bn": "পরিচয় ও নাগরিকত্ব", "name_en": "Identity & citizenship"},
    {"key": "travel", "name_bn": "ভ্রমণ ও পাসপোর্ট", "name_en": "Travel & passport"},
    {"key": "driving", "name_bn": "যানবাহন ও লাইসেন্স", "name_en": "Vehicles & licence"},
    {"key": "tax", "name_bn": "কর ও রাজস্ব", "name_en": "Tax & revenue"},
    {"key": "land", "name_bn": "জমি ও ভূমি", "name_en": "Land & property"},
    {"key": "business", "name_bn": "ব্যবসা ও ট্রেড", "name_en": "Business & trade"},
    {"key": "utility", "name_bn": "ইউটিলিটি সংযোগ", "name_en": "Utility connections"},
    {"key": "police", "name_bn": "পুলিশ ও ছাড়পত্র", "name_en": "Police & clearance"},
]

# A reusable disclaimer sentence (bilingual).
DISCLAIMER_BN = ("তথ্য সাধারণ দিকনির্দেশনা মাত্র — ফি, সময় ও নিয়ম বদলাতে পারে। "
                 "আবেদনের আগে সরকারি পোর্টালে যাচাই করুন।")
DISCLAIMER_EN = ("This is general guidance only — fees, timelines and rules can "
                 "change. Always verify on the official portal before applying.")


def _svc(key, cat, name_bn, name_en, portal, url,
         steps_bn, steps_en, docs_bn, docs_en,
         fee_bn, fee_en, office_bn, office_en,
         time_bn, time_en, mistakes_bn, mistakes_en):
    """Build one service record. `fee`/`time` always carry verify flags +
    the portal as the source. We never assert a fee as final."""
    return {
        "key": key,
        "category": cat,
        "name_bn": name_bn, "name_en": name_en,
        "portal": portal,          # short host shown as source
        "url": url,                # official link the app opens
        "steps_bn": steps_bn, "steps_en": steps_en,
        "docs_bn": docs_bn, "docs_en": docs_en,
        "fee_bn": fee_bn, "fee_en": fee_en,
        "fee_verify": True,        # UI must show "verify on portal" beside fee
        "office_bn": office_bn, "office_en": office_en,
        "time_bn": time_bn, "time_en": time_en,
        "time_verify": True,
        "mistakes_bn": mistakes_bn, "mistakes_en": mistakes_en,
        "source_bn": "সূত্র: " + portal, "source_en": "Source: " + portal,
        "disclaimer_bn": DISCLAIMER_BN, "disclaimer_en": DISCLAIMER_EN,
    }


# ---------------------------------------------------------------------------
# The 11 core services. All figures are verify-on-portal guidance, never final.
# ---------------------------------------------------------------------------
SERVICES = [
    _svc(
        "nid", "identity", "জাতীয় পরিচয়পত্র (NID)", "National ID (NID)",
        "services.nidw.gov.bd", "https://services.nidw.gov.bd",
        ["পোর্টালে রেজিস্টার করে লগইন করুন", "ফর্ম-২ পূরণ করুন (নাম, ঠিকানা, তথ্য)",
         "প্রয়োজনীয় কাগজ স্ক্যান করে আপলোড করুন", "সংশোধন হলে ফি পরিশোধ করুন",
         "আবেদন জমা দিন ও স্ট্যাটাস ট্র্যাক করুন"],
        ["Register and log in on the portal", "Fill Form-2 (name, address, details)",
         "Scan and upload the required documents", "Pay the fee if it is a correction",
         "Submit and track your application status"],
        ["জন্ম নিবন্ধন সনদ", "নাগরিকত্ব/ঠিকানার প্রমাণ (ইউটিলিটি বিল)",
         "শিক্ষাগত সনদ (যদি থাকে)", "পাসপোর্ট সাইজ ছবি", "অভিভাবকের NID (নতুন ভোটারের জন্য)"],
        ["Birth registration certificate", "Proof of citizenship/address (utility bill)",
         "Educational certificate (if any)", "Passport-size photo", "Parent's NID (for new voters)"],
        "নতুন NID সাধারণত ফি ছাড়া; সংশোধন/রিইস্যুতে নির্ধারিত ফি প্রযোজ্য — পোর্টালে যাচাই করুন।",
        "A new NID is usually free; corrections/re-issue carry a set fee — verify on the portal.",
        "নির্বাচন কমিশন (উপজেলা/থানা নির্বাচন অফিস)", "Election Commission (upazila/thana election office)",
        "অনলাইন কপি কয়েক দিন; স্মার্ট কার্ড কয়েক সপ্তাহ — যাচাই করুন।",
        "Online copy in a few days; smart card in a few weeks — verify.",
        ["নাম/জন্মতারিখ কাগজের সাথে অমিল", "ঝাপসা/ভুল ফরম্যাটের ছবি আপলোড",
         "সংশোধনের সপক্ষে প্রমাণ না দেওয়া"],
        ["Name/date-of-birth not matching the documents", "Uploading a blurry/wrong-format photo",
         "Not attaching evidence for a correction"]),
    _svc(
        "epassport", "travel", "ই-পাসপোর্ট", "e-Passport",
        "epassport.gov.bd", "https://www.epassport.gov.bd",
        ["পোর্টালে অনলাইন আবেদন করুন", "পাতা ও মেয়াদ (৪৮/৬৪ পাতা, ৫/১০ বছর) বেছে নিন",
         "ফি পরিশোধ করুন (ব্যাংক/অনলাইন)", "বায়োমেট্রিক অ্যাপয়েন্টমেন্ট নিন ও অফিসে যান",
         "পুলিশ ভেরিফিকেশনের পর ডেলিভারি ট্র্যাক করুন"],
        ["Apply online on the portal", "Choose pages & validity (48/64 pages, 5/10 years)",
         "Pay the fee (bank/online)", "Book a biometric appointment and attend",
         "After police verification, track delivery"],
        ["অনলাইন আবেদনের সারাংশ (প্রিন্ট)", "জাতীয় পরিচয়পত্র (NID)",
         "জন্ম নিবন্ধন (১৮ বছরের নিচে)", "আগের পাসপোর্ট (রিনিউ হলে)", "ফি পরিশোধের রসিদ"],
        ["Printed online application summary", "National ID (NID)",
         "Birth registration (under 18)", "Old passport (if renewing)", "Fee payment receipt"],
        "পাতা, মেয়াদ ও ডেলিভারি (সাধারণ/জরুরি/অতি-জরুরি) ভেদে ফি আলাদা — পোর্টালে যাচাই করুন।",
        "The fee varies by pages, validity and delivery (regular/express/super-express) — verify on the portal.",
        "বিভাগীয় পাসপোর্ট অফিস / আঞ্চলিক অফিস", "Divisional / regional passport office",
        "ডেলিভারি ধরন অনুযায়ী কয়েক দিন থেকে কয়েক সপ্তাহ — যাচাই করুন।",
        "A few days to a few weeks depending on delivery type — verify.",
        ["NID-এর সাথে নামের বানান অমিল", "অ্যাপয়েন্টমেন্ট মিস করা",
         "স্থায়ী ঠিকানা ভুল দেওয়া (পুলিশ ভেরিফিকেশন আটকায়)"],
        ["Name spelling not matching the NID", "Missing the appointment",
         "Wrong permanent address (holds up police verification)"]),
    _svc(
        "birth", "identity", "জন্ম নিবন্ধন", "Birth registration",
        "bdris.gov.bd", "https://bdris.gov.bd",
        ["BDRIS পোর্টালে আবেদন ফর্ম পূরণ করুন", "জন্মস্থান/ঠিকানা অনুযায়ী অফিস বেছে নিন",
         "প্রমাণপত্র আপলোড করুন", "আবেদন নম্বর নিয়ে অফিসে যাচাই করান",
         "অনুমোদনের পর সনদ সংগ্রহ করুন"],
        ["Fill the application form on the BDRIS portal", "Pick the office by place/address of birth",
         "Upload the supporting documents", "Take the application number for office verification",
         "Collect the certificate after approval"],
        ["হাসপাতাল ছাড়পত্র / EPI টিকা কার্ড", "অভিভাবকের NID",
         "অভিভাবকের জন্ম নিবন্ধন", "ঠিকানার প্রমাণ (হোল্ডিং ট্যাক্স/বিল)"],
        ["Hospital discharge / EPI vaccination card", "Parent's NID",
         "Parent's birth registration", "Proof of address (holding tax/utility bill)"],
        "নবজাতকের নির্দিষ্ট সময়ের মধ্যে নিবন্ধন সাধারণত বিনামূল্যে; দেরিতে করলে ফি — পোর্টালে যাচাই করুন।",
        "Registering a newborn within the window is usually free; late registration has a fee — verify on the portal.",
        "ইউনিয়ন পরিষদ / পৌরসভা / সিটি কর্পোরেশন / ক্যান্টনমেন্ট বোর্ড",
        "Union Parishad / Pourashava / City Corporation / Cantonment Board",
        "যাচাই ও অনুমোদনে কয়েক দিন — অফিসভেদে ভিন্ন, যাচাই করুন।",
        "A few days for verification & approval — varies by office, verify.",
        ["বাবা-মায়ের তথ্যে বানান অমিল", "ভুল অফিস নির্বাচন (ঠিকানার সাথে মেলে না)",
         "দেরিতে নিবন্ধনে বাড়তি কাগজ লাগে — না আনা"],
        ["Spelling mismatch in parents' details", "Choosing the wrong office (doesn't match address)",
         "Late registration needs extra papers — not bringing them"]),
    _svc(
        "driving", "driving", "ড্রাইভিং লাইসেন্স", "Driving licence",
        "bsp.brta.gov.bd", "https://bsp.brta.gov.bd",
        ["BRTA সার্ভিস পোর্টালে (BSP) অ্যাকাউন্ট খুলুন", "লার্নার লাইসেন্সের আবেদন করুন",
         "ফি + মেডিকেল সার্টিফিকেট জমা দিন", "লিখিত ও ব্যবহারিক পরীক্ষা দিন",
         "পাসের পর স্মার্ট কার্ড লাইসেন্স সংগ্রহ করুন"],
        ["Create an account on the BRTA service portal (BSP)", "Apply for a learner's licence",
         "Submit the fee + a medical certificate", "Sit the written and practical tests",
         "Collect the smart-card licence after passing"],
        ["জাতীয় পরিচয়পত্র (NID)", "পাসপোর্ট সাইজ ছবি", "রক্তের গ্রুপসহ মেডিকেল সার্টিফিকেট",
         "শিক্ষাগত সনদ (ন্যূনতম যোগ্যতা)", "ইউটিলিটি বিল (ঠিকানা)"],
        ["National ID (NID)", "Passport-size photo", "Medical certificate with blood group",
         "Educational certificate (minimum qualification)", "Utility bill (address)"],
        "লার্নার, পরীক্ষা ও স্মার্ট কার্ড—প্রতিটির আলাদা নির্ধারিত ফি BSP-তে দেখানো হয় — যাচাই করুন।",
        "Learner, test and smart-card each have a set fee shown on BSP — verify.",
        "বিআরটিএ সার্কেল অফিস", "BRTA circle office",
        "লার্নার থেকে স্মার্ট কার্ড পেতে কয়েক সপ্তাহ — যাচাই করুন।",
        "A few weeks from learner to smart card — verify.",
        ["মেডিকেল সার্টিফিকেট আপডেট না থাকা", "পরীক্ষার তারিখ মিস করা",
         "লার্নারের মেয়াদ শেষ হয়ে যাওয়া"],
        ["Outdated medical certificate", "Missing the test date",
         "Letting the learner's licence expire"]),
    _svc(
        "tin", "tax", "TIN ও ই-রিটার্ন", "TIN & e-Return",
        "etaxnbr.gov.bd", "https://etaxnbr.gov.bd",
        ["eTIN পোর্টালে রেজিস্ট্রেশন করে TIN নিন", "ই-রিটার্ন অ্যাকাউন্টে লগইন করুন",
         "আয়, সম্পদ ও কর্তিত কর তথ্য দিন", "রিটার্ন যাচাই করে অনলাইনে জমা দিন",
         "প্রাপ্তি স্বীকার (acknowledgment) সংরক্ষণ করুন"],
        ["Register on the eTIN portal to get a TIN", "Log in to your e-Return account",
         "Enter income, assets and tax-deducted details", "Review and submit the return online",
         "Save the acknowledgement slip"],
        ["জাতীয় পরিচয়পত্র (NID)", "আয়ের প্রমাণ (বেতন/ব্যবসা)", "ব্যাংক স্টেটমেন্ট",
         "উৎসে কর কর্তনের সনদ (থাকলে)", "সম্পদ/বিনিয়োগের তথ্য"],
        ["National ID (NID)", "Proof of income (salary/business)", "Bank statement",
         "Tax-deduction-at-source certificate (if any)", "Asset/investment details"],
        "TIN নেওয়া বিনামূল্যে; কর দায় আয়ের ওপর নির্ভর করে — হিসাব ও হার পোর্টালে যাচাই করুন।",
        "Getting a TIN is free; tax liability depends on income — verify the slabs/rates on the portal.",
        "জাতীয় রাজস্ব বোর্ড (NBR) — অনলাইন / কর অঞ্চল অফিস", "National Board of Revenue (NBR) — online / tax-zone office",
        "অনলাইন রিটার্ন সাথে সাথে জমা হয়; প্রক্রিয়াকরণ পরে — যাচাই করুন।",
        "The online return submits instantly; processing follows — verify.",
        ["রিটার্ন জমার শেষ তারিখ মিস করা", "আয়/সম্পদ কম দেখানো",
         "ভুল কর অঞ্চল/সার্কেল নির্বাচন"],
        ["Missing the return filing deadline", "Under-reporting income/assets",
         "Selecting the wrong tax zone/circle"]),
    _svc(
        "porcha", "land", "জমির পর্চা / খতিয়ান", "Land record (porcha / khatian)",
        "eporcha.gov.bd", "https://eporcha.gov.bd",
        ["e-Porcha পোর্টালে বিভাগ/জেলা/উপজেলা বেছে নিন", "খতিয়ান ধরন (RS/BS/CS) ও নম্বর দিন",
         "মালিক/দাগ নম্বর দিয়ে সার্চ করুন", "আবেদন ফি পরিশোধ করুন",
         "অনলাইন কপি/ডাক-কপির জন্য আবেদন করুন"],
        ["Pick division/district/upazila on the e-Porcha portal", "Choose khatian type (RS/BS/CS) and number",
         "Search by owner / plot (dag) number", "Pay the application fee",
         "Request an online copy / certified postal copy"],
        ["জমির দাগ ও খতিয়ান নম্বর", "মালিকের নাম", "জাতীয় পরিচয়পত্র (NID)",
         "আগের দলিল/রেকর্ড (থাকলে)"],
        ["Plot (dag) and khatian number", "Owner's name", "National ID (NID)",
         "Previous deed/record (if any)"],
        "অনলাইন সার্চ/কপির জন্য নির্ধারিত ফি e-Porcha-তে দেখানো হয় — যাচাই করুন।",
        "A set fee for online search/copy is shown on e-Porcha — verify.",
        "ভূমি অফিস (এসিল্যান্ড) / অনলাইন", "Land office (AC Land) / online",
        "অনলাইন কপি দ্রুত; সার্টিফায়েড ডাক-কপি কয়েক দিন — যাচাই করুন।",
        "Online copy is quick; certified postal copy takes a few days — verify.",
        ["খতিয়ান ধরন (RS/BS/CS) ভুল নির্বাচন", "দাগ নম্বরে টাইপো",
         "জেলা/উপজেলা ভুল নির্বাচন"],
        ["Picking the wrong khatian type (RS/BS/CS)", "Typo in the plot (dag) number",
         "Selecting the wrong district/upazila"]),
    _svc(
        "trade_license", "business", "ট্রেড লাইসেন্স", "Trade licence",
        "City Corporation / Pourashava", "",
        ["সিটি কর্পোরেশন/পৌরসভার নির্ধারিত ফর্ম নিন", "ব্যবসার ধরন ও ঠিকানা উল্লেখ করুন",
         "প্রয়োজনীয় কাগজ ও ফি জমা দিন", "পরিদর্শন/যাচাই সম্পন্ন করুন",
         "লাইসেন্স সংগ্রহ করুন ও প্রতি বছর নবায়ন করুন"],
        ["Get the prescribed form from the City Corporation/Pourashava", "State the business type and address",
         "Submit the documents and fee", "Complete inspection/verification",
         "Collect the licence and renew it every year"],
        ["জাতীয় পরিচয়পত্র (NID)", "ভাড়ার চুক্তি / মালিকানা দলিল", "পাসপোর্ট সাইজ ছবি",
         "হোল্ডিং ট্যাক্স রসিদ", "TIN (কিছু ক্ষেত্রে)"],
        ["National ID (NID)", "Rental agreement / ownership deed", "Passport-size photo",
         "Holding-tax receipt", "TIN (in some cases)"],
        "ফি ব্যবসার ধরন ও এলাকার শ্রেণি অনুযায়ী ভিন্ন; সংশ্লিষ্ট পৌরসভা/সিটি অফিসে যাচাই করুন।",
        "The fee varies by business type and area category; verify with the relevant Pourashava/City office.",
        "সংশ্লিষ্ট সিটি কর্পোরেশন / পৌরসভা অফিস", "The relevant City Corporation / Pourashava office",
        "যাচাই/পরিদর্শনসহ কয়েক দিন — অফিসভেদে ভিন্ন, যাচাই করুন।",
        "A few days including verification/inspection — varies by office, verify.",
        ["ব্যবসার ঠিকানা ও ভাড়ার চুক্তির অমিল", "ভুল ব্যবসা-শ্রেণি নির্বাচন",
         "প্রতি বছর নবায়ন না করা"],
        ["Business address not matching the rental agreement", "Choosing the wrong business category",
         "Not renewing every year"]),
    _svc(
        "electricity", "utility", "নতুন বিদ্যুৎ সংযোগ", "New electricity connection",
        "DPDC / DESCO / BREB / NESCO", "",
        ["সংশ্লিষ্ট বিতরণ কোম্পানির পোর্টালে আবেদন করুন", "মিটার ধরন ও লোড নির্ধারণ করুন",
         "কাগজপত্র ও ছবি আপলোড করুন", "পরিদর্শন ও ডিমান্ড নোট ফি পরিশোধ করুন",
         "মিটার স্থাপন ও সংযোগ গ্রহণ করুন"],
        ["Apply on the relevant distribution company's portal", "Select meter type and load",
         "Upload documents and photos", "Pay the inspection + demand-note fee",
         "Get the meter installed and connection activated"],
        ["জাতীয় পরিচয়পত্র (NID)", "জমি/বাড়ির মালিকানা বা ভাড়ার প্রমাণ", "পাসপোর্ট সাইজ ছবি",
         "পাশের হোল্ডিং-এর সাম্প্রতিক বিল (রেফারেন্স)"],
        ["National ID (NID)", "Proof of land/house ownership or tenancy", "Passport-size photo",
         "A recent bill of a nearby holding (reference)"],
        "আবেদন, নিরাপত্তা জামানত ও ডিমান্ড নোট ফি লোড ও কোম্পানি অনুযায়ী ভিন্ন — পোর্টালে যাচাই করুন।",
        "Application, security deposit and demand-note fees vary by load and company — verify on the portal.",
        "DPDC / DESCO / BREB (পল্লী বিদ্যুৎ) / NESCO অফিস", "DPDC / DESCO / BREB (rural) / NESCO office",
        "পরিদর্শন ও মিটার স্থাপনে কয়েক দিন থেকে সপ্তাহ — যাচাই করুন।",
        "A few days to weeks for inspection and meter installation — verify.",
        ["ভুল বিতরণ কোম্পানি নির্বাচন (এলাকাভেদে ভিন্ন)", "লোড কম/বেশি নির্ধারণ",
         "মালিকানা/ভাড়ার প্রমাণ অস্পষ্ট"],
        ["Choosing the wrong distribution company (differs by area)", "Setting the load too low/high",
         "Unclear ownership/tenancy proof"]),
    _svc(
        "police_clearance", "police", "পুলিশ ক্লিয়ারেন্স সার্টিফিকেট", "Police Clearance Certificate",
        "pcc.police.gov.bd", "https://pcc.police.gov.bd",
        ["পুলিশ ক্লিয়ারেন্স পোর্টালে আবেদন করুন", "স্থায়ী ঠিকানা ও উদ্দেশ্য দিন",
         "ফি পরিশোধ করুন (চালান/অনলাইন)", "পুলিশ ভেরিফিকেশন সম্পন্ন হতে দিন",
         "অনুমোদনের পর সার্টিফিকেট সংগ্রহ/ডাউনলোড করুন"],
        ["Apply on the Police Clearance portal", "Enter permanent address and purpose",
         "Pay the fee (challan/online)", "Allow the police verification to complete",
         "Collect/download the certificate after approval"],
        ["বৈধ পাসপোর্ট", "জাতীয় পরিচয়পত্র (NID)", "স্থায়ী ঠিকানার প্রমাণ",
         "পাসপোর্ট সাইজ ছবি", "ফি পরিশোধের চালান"],
        ["Valid passport", "National ID (NID)", "Proof of permanent address",
         "Passport-size photo", "Fee payment challan"],
        "নির্ধারিত সরকারি ফি চালানে পরিশোধ করতে হয় — অঙ্ক পোর্টালে যাচাই করুন।",
        "A set government fee is paid by challan — verify the amount on the portal.",
        "সংশ্লিষ্ট থানা / জেলা পুলিশ / ডিএমপি", "Relevant thana / district police / DMP",
        "ভেরিফিকেশন ও অনুমোদনে কয়েক দিন থেকে সপ্তাহ — যাচাই করুন।",
        "A few days to weeks for verification and approval — verify.",
        ["স্থায়ী ঠিকানা ভুল/অসম্পূর্ণ", "পাসপোর্ট তথ্যের সাথে অমিল",
         "চালান নম্বর ভুল দেওয়া"],
        ["Wrong/incomplete permanent address", "Mismatch with passport details",
         "Entering the wrong challan number"]),
    _svc(
        "brta_vehicle", "driving", "যানবাহন রেজিস্ট্রেশন (BRTA)", "Vehicle registration (BRTA)",
        "bsp.brta.gov.bd", "https://bsp.brta.gov.bd",
        ["BSP পোর্টালে রেজিস্ট্রেশনের আবেদন করুন", "গাড়ির তথ্য ও মালিকানা দিন",
         "ফি ও কর পরিশোধ করুন", "পরিদর্শনের জন্য গাড়ি উপস্থাপন করুন",
         "ডিজিটাল রেজিস্ট্রেশন ও নম্বরপ্লেট সংগ্রহ করুন"],
        ["Apply for registration on the BSP portal", "Enter vehicle details and ownership",
         "Pay the fees and taxes", "Present the vehicle for inspection",
         "Collect the digital registration and number plate"],
        ["ক্রয়ের রসিদ / মালিকানার দলিল", "আমদানি/বিক্রয় কাগজ", "জাতীয় পরিচয়পত্র (NID)",
         "TIN", "বীমার কাগজ"],
        ["Purchase receipt / ownership deed", "Import/sale papers", "National ID (NID)",
         "TIN", "Insurance papers"],
        "রেজিস্ট্রেশন ফি, কর ও নম্বরপ্লেট চার্জ যানবাহনের ধরন অনুযায়ী ভিন্ন — BSP-তে যাচাই করুন।",
        "Registration fee, tax and plate charges vary by vehicle type — verify on BSP.",
        "বিআরটিএ সার্কেল অফিস", "BRTA circle office",
        "পরিদর্শন ও ডিজিটাল নম্বরপ্লেটে কয়েক সপ্তাহ — যাচাই করুন।",
        "A few weeks for inspection and the digital plate — verify.",
        ["মালিকানার কাগজ অসম্পূর্ণ", "কর/ফি বকেয়া রেখে দেওয়া",
         "পরিদর্শনে গাড়ি না আনা"],
        ["Incomplete ownership papers", "Leaving tax/fee dues unpaid",
         "Not bringing the vehicle for inspection"]),
    _svc(
        "water_gas", "utility", "নতুন পানি / গ্যাস সংযোগ", "New water / gas connection",
        "WASA / Titas", "",
        ["সংশ্লিষ্ট কর্তৃপক্ষের (WASA/তিতাস) অফিস/পোর্টালে আবেদন করুন",
         "সংযোগ ধরন ও ব্যবহারের শ্রেণি দিন", "কাগজপত্র ও ফি জমা দিন",
         "পরিদর্শন ও ডিমান্ড নোট পরিশোধ করুন", "সংযোগ ও মিটার স্থাপন গ্রহণ করুন"],
        ["Apply at the relevant authority (WASA/Titas) office/portal",
         "Select connection type and usage category", "Submit documents and the fee",
         "Pay the inspection + demand-note", "Get the connection and meter installed"],
        ["জাতীয় পরিচয়পত্র (NID)", "জমি/বাড়ির মালিকানা বা ভাড়ার প্রমাণ",
         "হোল্ডিং ট্যাক্স রসিদ", "পাশের হোল্ডিং-এর বিল (রেফারেন্স)"],
        ["National ID (NID)", "Proof of land/house ownership or tenancy",
         "Holding-tax receipt", "A nearby holding's bill (reference)"],
        "সংযোগ, জামানত ও ডিমান্ড নোট ফি ব্যবহারের শ্রেণি ও কর্তৃপক্ষ অনুযায়ী ভিন্ন — অফিসে যাচাই করুন।",
        "Connection, deposit and demand-note fees vary by usage category and authority — verify at the office.",
        "ঢাকা/চট্টগ্রাম WASA বা তিতাস গ্যাস অফিস", "Dhaka/Chattogram WASA or Titas Gas office",
        "পরিদর্শন ও স্থাপনে কয়েক সপ্তাহ — যাচাই করুন।",
        "A few weeks for inspection and installation — verify.",
        ["ভুল কর্তৃপক্ষ/জোন নির্বাচন", "ব্যবহারের শ্রেণি ভুল দেওয়া",
         "মালিকানা/ভাড়ার প্রমাণ অস্পষ্ট"],
        ["Choosing the wrong authority/zone", "Wrong usage category",
         "Unclear ownership/tenancy proof"]),
]


# ---------------------------------------------------------------------------
# Pure helpers (localisation, search, "what do I need").
# ---------------------------------------------------------------------------
_LOCALISED_FIELDS = (
    "name", "steps", "docs", "fee", "office", "time",
    "mistakes", "source", "disclaimer",
)


def localized(lang):
    """Full ADVANCED payload localised to `lang` ('bn'|'en'). Keeps the stable
    keys (key, category, portal, url, fee_verify, time_verify) and flattens the
    _bn/_en pairs to single localised fields. Backwards-compatible: `services`
    still carry `name` + `steps`; `religious` is dropped (religion moved out of
    this module in the ADVANCED upgrade)."""
    return {
        "version": "2.1",
        "categories": [localise(lang, c, "name") for c in CATEGORIES],
        "services": [localise(lang, s, *_LOCALISED_FIELDS) for s in SERVICES],
        "disclaimer": pick(lang, DISCLAIMER_BN, DISCLAIMER_EN),
    }


def _haystack(svc, lang):
    """Lower-cased searchable text for one service in `lang`."""
    parts = [svc.get("name_" + lang, ""), svc.get("name_en", ""),
             svc.get("portal", ""), svc.get("category", "")]
    for f in ("steps", "docs", "mistakes"):
        parts.extend(svc.get(f + "_" + lang, []))
    return " ".join(parts).lower()


def search(query, lang="bn", category=None):
    """Return localised services matching `query` (substring, case-insensitive)
    and/or `category`. Empty query + no category returns everything (localised).
    """
    q = (query or "").strip().lower()
    out = []
    for s in SERVICES:
        if category and s["category"] != category:
            continue
        if q and q not in _haystack(s, lang):
            continue
        out.append(localise(lang, s, *_LOCALISED_FIELDS))
    return out


def what_do_i_need(service_key, lang="bn"):
    """The "what do I need for X" flow: the documents checklist + fee + office
    + link for one service. Returns None if the key is unknown."""
    s = next((x for x in SERVICES if x["key"] == service_key), None)
    if s is None:
        return None
    loc = localise(lang, s, *_LOCALISED_FIELDS)
    return {
        "key": s["key"],
        "name": loc["name"],
        "docs": loc["docs"],
        "fee": loc["fee"], "fee_verify": True,
        "office": loc["office"],
        "time": loc["time"], "time_verify": True,
        "url": s["url"], "portal": s["portal"],
        "source": loc["source"],
        "disclaimer": loc["disclaimer"],
    }


def has_no_invented_fees():
    """Honesty invariant used by tests: every service carries fee_verify=True,
    a non-empty fee string, and a portal source. We never state a fee as final.
    """
    for s in SERVICES:
        if not s.get("fee_verify"):
            return False
        if not s.get("fee_bn") or not s.get("fee_en"):
            return False
        if not s.get("portal"):
            return False
    return True
