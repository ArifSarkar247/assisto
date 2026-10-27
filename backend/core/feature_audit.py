"""feature-flags: the FIRST Definition-of-Done audit (26 Oct 2026) of every
feature in core.feature_flags.REGISTRY — what code, tests and docs can prove
today, nothing more. It only SEEDS the 9 checkboxes + notes of a new
FeatureFlag row (Owner Admin → Features) and feeds
owner_actions/FEATURE_STATUS_BN.md. It never changes visibility: the
proposed Play column is a proposal for the owner / integrator.

Check codes, in DoD order (1 journey on two accounts · 2 every button real ·
3 bn/en + 200% font + dark + 48dp · 4 2 GB phone < 1 s · 5 server limits ·
6 privacy / permissions / Play declarations · 7 tests + reality flow ·
8 in-app guide · 9 owner 10-minute test in STATUS):
  P = pass (evidence in repo)   F = fails (known gap)   ? = not proven
Evidence used: .phaseB/REALITY_AUDIT.md (flows A/B + drawer sweep S001-S086),
app/test/dead_button_sweep_test.dart + a11y_guidelines_test.dart (screens in
the screenshot gallery; a11y runs light+dark at 1.3x, not 200%),
bin/lang_gate.py (global pass), owner_actions/PLAY_STORE_PACK.md §5-6 +
PLAY_FGS_DECLARATION_BN.md, owner_actions/SHOWPIECES_BN.md, STATUS_FOR_OWNER.md.
No feature has a measured 2 GB-phone run (check 4) or a per-feature "10-minute
test" in STATUS (check 9) yet, so strictly NO feature is DONE (9/9) today.
"""

# key: (codes, proposed Play visibility for 8 Nov, reason EN, reason BN)
_A = {
    # ---- My Circle
    "my_circle": ("?P??PPP?F", "show", "Two-account message flows A (15/17/19); offline + slow-net journey not proven.",
                  "দুই অ্যাকাউন্টে মেসেজ ফ্লো A (১৫/১৭/১৯); ইন্টারনেট-নেই ও ধীর-ইন্টারনেট যাত্রা প্রমাণ হয়নি।"),
    "calls": ("?P??PPF?F", "show", "Reality B until a two-phone voice+video test passes (TURN, app closed).",
              "দুই ফোনে ভয়েস+ভিডিও পরীক্ষা পাস না হওয়া পর্যন্ত রিয়ালিটি B (TURN, অ্যাপ বন্ধ অবস্থায়)।"),
    # ---- Reminders & Memory
    "reminders": ("?P???PP?F", "show", "Flow 08 A (server read-back); OS alarm with app closed needs the phone.",
                  "ফ্লো ০৮ A (সার্ভার থেকে মিলিয়ে দেখা); অ্যাপ বন্ধে অ্যালার্ম ফোনে দেখতে হবে।"),
    "birthdays": ("?F???P??F", "hide", "Sweep B?: key-gated / mock path (AI wishes).",
                  "সুইপ B?: চাবি-নির্ভর / নকল অংশ (AI শুভেচ্ছা)।"),
    "meetings": ("?F???P??F", "hide", "Sweep B?: key-gated / mock path; corporate meetings are a separate upcoming feature.",
                 "সুইপ B?: চাবি-নির্ভর / নকল অংশ; কর্পোরেট মিটিং আলাদা আসন্ন ফিচার।"),
    "notes": ("?P???PP?F", "show", "Flows 09/10 A.", "ফ্লো ০৯/১০ A।"),
    "memory": ("?P???P??F", "show", "Sweep A? (opened clean, routes resolve).", "সুইপ A? (ঠিকমতো খোলে, রুট মেলে)।"),
    "saved_items": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    # ---- Account & Finance
    "money": ("?P???PP?F", "show", "Flow 11 A; report export fixed.", "ফ্লো ১১ A; রিপোর্ট এক্সপোর্ট ঠিক করা হয়েছে।"),
    "budget": ("?P???PP?F", "show", "Flow 12 A.", "ফ্লো ১২ A।"),
    "budget_remittance": ("?PP?PF?PF", "hide", "Budget and Remittance (receiver side): two-account server tests (privacy, encryption at rest, export, delete-all, year maths, reminder logic, flag off) + app widget tests (parser, form, plan, goal, share-on-tap, offline queue, 200% bn/en light/dark) pass; reality flow 30_budget_remittance written but not yet run in CI; 2 GB speed not measured; Play Data safety 'Other financial info' not yet entered by the owner; 10-minute test is in BUDGET_REMITTANCE_BN.md (not yet in STATUS).",
                          "বাজেট ও রেমিট্যান্স (যাঁরা টাকা পান): দুই-অ্যাকাউন্টের সার্ভার-টেস্ট (গোপনীয়তা, ডাটাবেসে এনক্রিপশন, এক্সপোর্ট, সব মুছুন, বছরের হিসাব, রিমাইন্ডার) ও অ্যাপ টেস্ট (বাংলা বাক্য বোঝা, ফর্ম, পরিকল্পনা, সঞ্চয়, শুধু চাপলে শেয়ার, অফলাইন সারি, ২০০% বাংলা/ইংরেজি আলো/অন্ধকার) পাস; রিয়ালিটি ফ্লো ৩০ লেখা হয়েছে কিন্তু CI-তে এখনো চলেনি; ২ GB গতি মাপা হয়নি; Play Data safety-তে 'Other financial info' মালিক এখনো বসাননি; ১০ মিনিটের পরীক্ষা BUDGET_REMITTANCE_BN.md-তে (STATUS-এ এখনো নয়)।"),
    "tax_zakat": ("?P???P??F", "show", "Sweep A?; on-device calculators.", "সুইপ A?; ফোনেই হিসাব।"),
    "money_wrapped": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "money_voice": ("?P???P??F", "show", "Sweep A?; speech needs a real phone.", "সুইপ A?; কথা চেনা আসল ফোনে দেখতে হবে।"),
    "subscriptions": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "finance_tools": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "payment_ladder": ("?F???P??F", "hide", "Sweep B?: key-gated payments path.", "সুইপ B?: পেমেন্ট চাবি-নির্ভর।"),
    "mess_accounting": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "expense_split": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "samity": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "house_rent": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "prepaid_meter": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "domestic_staff": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "savings_challenge": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "spending_advice": ("?F???P?FF", "hide", "Sweep B?: AI mock without the key.", "সুইপ B?: চাবি ছাড়া AI নকল ফল।"),
    "price_radar": ("?F???P?FF", "hide", "Sweep B?: no live market-price source.", "সুইপ B?: বাজার দামের আসল উৎস নেই।"),
    # ---- Family & Safety
    "family": ("?P???PP?F", "show", "Flow 13 A; family accounting routes built.", "ফ্লো ১৩ A; পরিবারের হিসাবের রুট তৈরি।"),
    "nominee": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "safe_journey": ("?P????F?F", "show", "Sweep A? (fixed 404s); check the FGS-location declaration also covers Safe Journey, else hide.",
                     "সুইপ A? (৪০৪ ঠিক); FGS-লোকেশন ঘোষণায় নিরাপদ যাত্রাও আছে কিনা দেখুন, না থাকলে লুকান।"),
    "emergency": ("?P???PP?F", "show", "Flow 14 A (SOS countdown + cancel); FGS mic + location declared.",
                  "ফ্লো ১৪ A (SOS কাউন্টডাউন + বাতিল); FGS মাইক ও লোকেশন ঘোষিত।"),
    "scam_check": ("?P???P??F", "show", "Sweep A? (report route fixed).", "সুইপ A? (রিপোর্ট রুট ঠিক)।"),
    "fall_detect": ("FF???????", "hide", "Hidden today (no native fall sensor).", "আজও লুকানো (ফোনের পতন-সেন্সর যুক্ত নয়)।"),
    "anti_theft": ("?P????F?F", "hide", "Device-admin is reviewed under Play's Device & Network Abuse policy (pack D.1 open); not in the dead-button gallery (My lost phone / Phone safety / Security / Sell).",
                   "ডিভাইস-অ্যাডমিন Play-র Device & Network Abuse নীতিতে যাচাই হয় (প্যাক D.1 বাকি); কয়েকটি স্ক্রিন মরা-বাটন টেস্টে নেই।"),
    "cctv_watchman": ("?P??P?F?F", "hide", "Reality B: needs a real camera / Shop Box device; big-week item A — finish to 9/9 first.",
                      "রিয়ালিটি B: আসল ক্যামেরা / শপ বক্স লাগে; বড় সপ্তাহের A — আগে ৯/৯ শেষ।"),
    "home_watchman": ("?PPFP??PP", "hide", "cctv1 phase 1: no real phone + camera journey, 2 GB speed not measured, no reality-audit flow, Data safety Photos line pending.",
                      "cctv1 ফেজ ১: আসল ফোন+ক্যামেরা যাত্রা বাকি, ২ GB গতি মাপা হয়নি, রিয়ালিটি-অডিট ফ্লো নেই, Data safety-তে Photos লাইন বাকি।"),
    "disaster_alerts": ("?P???P?FF", "hide", "No official BMD/FFWC feed yet: honest empty state only.",
                        "সরকারি BMD/FFWC ফিড এখনো নেই: শুধু খালি অবস্থা।"),
    "blood_donor": ("?P????F?F", "hide", "Public donor contacts = user content: needs moderation + Play UGC answers.",
                    "রক্তদাতার যোগাযোগ = ব্যবহারকারীর কনটেন্ট: মডারেশন ও Play UGC উত্তর লাগবে।"),
    "kid_school": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    # ---- Contacts
    "contacts": ("?P???P??F", "show", "Sweep A?; phonebook match is C until the two-phone test (READ_CONTACTS disclosure built).",
                 "সুইপ A?; ফোনবুক মেলানো দুই-ফোন পরীক্ষা পর্যন্ত C (READ_CONTACTS ব্যাখ্যা তৈরি)।"),
    # ---- Daily Life
    "voice_assistant": ("?P???PP?F", "show", "Flow 22 A (typed fallback); speech needs the phone; FGS mic declared.",
                        "ফ্লো ২২ A (লিখে উত্তর); কথা চেনা ফোনে; FGS মাইক ঘোষিত।"),
    "documents": ("?P??PPP?F", "show", "Flow 21 A; storage quota editable in Owner Admin.",
                  "ফ্লো ২১ A; স্টোরেজ সীমা Owner Admin-এ বদলানো যায়।"),
    "service_guide": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "nearby": ("?F???P?FF", "hide", "Sweep B?: curated mock dataset until a Maps key.", "সুইপ B?: Maps চাবি না থাকা পর্যন্ত বাছাই করা নকল তালিকা।"),
    "unseen_world": ("?????????", "hide", "Not in the reality sweep or the dead-button gallery; web answers need keys.",
                     "রিয়ালিটি সুইপ বা মরা-বাটন টেস্টে নেই; ওয়েব-উত্তরে চাবি লাগে।"),
    "unseen_bangladesh": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "dictionary": ("?F???P?FF", "hide", "Sweep B?: dictionary dataset not wired.", "সুইপ B?: অভিধানের ডেটা যুক্ত নয়।"),
    "ramadan": ("?P???P??F", "show", "Sweep B? key-gated parts hidden (f6); prayer times work.",
                "সুইপ B? চাবি-নির্ভর অংশ লুকানো (f6); নামাজের সময় কাজ করে।"),
    "watch_feed": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "exam_result": ("?P???P??F", "show", "Sweep A?; watcher fixed (f6).", "সুইপ A?; ওয়াচার ঠিক (f6)।"),
    "photo_studio": ("?P??PP??F", "show", "Profit Guard + credits/ads; not in the dead-button gallery.",
                     "Profit Guard + ক্রেডিট/বিজ্ঞাপন; মরা-বাটন টেস্টে নেই।"),
    "ride_food": ("?P???P??F", "show", "Sweep A? (opens partner apps).", "সুইপ A? (পার্টনার অ্যাপ খোলে)।"),
    "vehicles": ("?P???P??F", "show", "Sweep B?: document reminders work; live tracking is its own flag.",
                 "সুইপ B?: কাগজের রিমাইন্ডার কাজ করে; লাইভ ট্র্যাকিং আলাদা ফ্ল্যাগ।"),
    "vehicle_tracking": ("?P????F?F", "hide", "No real map yet; big-plan B: Play risk (location) — hide before 8 Nov.",
                         "আসল ম্যাপ নেই; বড় পরিকল্পনা B: Play ঝুঁকি (লোকেশন) — ৮ নভেম্বরের আগে লুকান।"),
    "student_corner": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "wedding_events": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "qurbani": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "probashi": ("?P???P??F", "show", "Sweep A? (reminder due_at fixed).", "সুইপ A? (রিমাইন্ডারের সময় ঠিক)।"),
    "farmer_mode": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "wellness": ("?F???P?FF", "hide", "Sweep B?: key-gated / mock path.", "সুইপ B?: চাবি-নির্ভর / নকল অংশ।"),
    "fitness": ("?F???P?FF", "hide", "Sweep B?: key-gated / mock path.", "সুইপ B?: চাবি-নির্ভর / নকল অংশ।"),
    "smartwatch": ("?P????F?F", "hide", "Health Connect needs its own Play declaration (personal account rejected health features).",
                   "Health Connect-এর আলাদা Play ঘোষণা লাগে (ব্যক্তিগত অ্যাকাউন্টে স্বাস্থ্য-ফিচার বাতিল হয়েছিল)।"),
    "daily_challenges": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "contract_analyzer": ("?F???P?FF", "hide", "Sweep B?: AI mock without the key.", "সুইপ B?: চাবি ছাড়া AI নকল ফল।"),
    "language_partner": ("?F???P?FF", "hide", "Sweep B?: AI mock without the key.", "সুইপ B?: চাবি ছাড়া AI নকল ফল।"),
    "daily_brief": ("?F???P?FF", "hide", "Sweep B?: AI mock without the key.", "সুইপ B?: চাবি ছাড়া AI নকল ফল।"),
    "doc_scanner": ("?F???P?FF", "hide", "Sweep B?: OCR key-gated mock.", "সুইপ B?: OCR চাবি-নির্ভর নকল।"),
    "transcription": ("?F???P?FF", "hide", "Sweep B?: speech key-gated mock.", "সুইপ B?: কথা-থেকে-লেখা চাবি-নির্ভর নকল।"),
    "travel_planner": ("?F???P?FF", "hide", "Sweep B?: AI mock without the key.", "সুইপ B?: চাবি ছাড়া AI নকল ফল।"),
    "voice_mood": ("?P????F?F", "hide", "Mood / mental-wellbeing reads as health in Play review.",
                   "মন / মানসিক সুস্থতা Play পর্যালোচনায় স্বাস্থ্য হিসেবে ধরা হতে পারে।"),
    "proactive_ai": ("?F???P?FF", "hide", "Sweep B?: AI mock without the key.", "সুইপ B?: চাবি ছাড়া AI নকল ফল।"),
    "area_community": ("FF???????", "hide", "Hidden today (posts not shared; f6).", "আজও লুকানো (পোস্ট কেউ দেখেন না; f6)।"),
    # ---- Work
    "agent_studio": ("FF???????", "hide", "Hidden today (automations never run; f6).", "আজও লুকানো (অটোমেশন চলে না; f6)।"),
    "task_manager": ("?P???P??F", "show", "Sweep A?.", "সুইপ A?।"),
    "cost_estimator": ("?F???P?FF", "hide", "Sweep B?: AI mock without the key.", "সুইপ B?: চাবি ছাড়া AI নকল ফল।"),
    "mock_interview": ("?F???P?FF", "hide", "Sweep B?: AI mock without the key.", "সুইপ B?: চাবি ছাড়া AI নকল ফল।"),
    "quick_tools": ("?F???P?FF", "hide", "Sweep B?: rule-based results, AI key-gated.", "সুইপ B?: নিয়মে তৈরি ফল, AI চাবি-নির্ভর।"),
    "blog_writer": ("?F???P?FF", "hide", "Sweep B?: templates, AI key-gated.", "সুইপ B?: টেমপ্লেট, AI চাবি-নির্ভর।"),
    "jobs": ("?F???P?FF", "hide", "No official jobs feed (f6); only the user's own tracker.", "চাকরির সরকারি ফিড নেই (f6); শুধু নিজের তালিকা।"),
    "cv_builder": ("?P???P??F", "show", "Sweep B? (AI polish key-gated); manual CV works.", "সুইপ B? (AI ঘষামাজা চাবি-নির্ভর); হাতে সিভি বানানো কাজ করে।"),
    "ai_inbox": ("?F???P?FF", "hide", "No mailbox connected: honest empty state only.", "কোনো মেইলবক্স যুক্ত নয়: শুধু খালি অবস্থা।"),
    "pa_secretary": ("?F???P?FF", "hide", "Sweep B?: key-gated / mock parts.", "সুইপ B?: চাবি-নির্ভর / নকল অংশ।"),
    # ---- Business
    "business": ("?P???PP?F", "show", "Flows 17/18 A (POS sale + void, khata).", "ফ্লো ১৭/১৮ A (বিক্রি + বাতিল, খাতা)।"),
    "crm": ("?P???PPPF", "show", "Flow 19 A; first-run guide; email + real WhatsApp send missing (big-week E).",
            "ফ্লো ১৯ A; প্রথমবারের গাইড; ইমেইল ও আসল WhatsApp পাঠানো নেই (বড় সপ্তাহ E)।"),
    "business_agent": ("?P??P?F?F", "hide", "Page / Instagram / WhatsApp setup needs Meta app review; not in a reality flow.",
                       "Page / Instagram / WhatsApp সেটআপে Meta অ্যাপ রিভিউ লাগে; রিয়ালিটি ফ্লো নেই।"),
    "booking_bot": ("?PP?PFFP?", "hide", "Booking bot phase 1: two-account server test + app widget tests pass; no real two-phone run, 2 GB speed not measured, no reality-audit flow yet, Play Data safety line for booking phone numbers pending, 10-minute test is in BOOKING_BOT_BN.md (not yet in STATUS).",
                    "বুকিং বট ফেজ ১: দুই-অ্যাকাউন্টের সার্ভার-টেস্ট ও অ্যাপ টেস্ট পাস; দুই ফোনে আসল পরীক্ষা বাকি, ২ GB গতি মাপা হয়নি, রিয়ালিটি-অডিট ফ্লো নেই, Play Data safety-তে বুকিংয়ের ফোন নম্বর লাইন বাকি, ১০ মিনিটের পরীক্ষা BOOKING_BOT_BN.md-তে (STATUS-এ এখনো নয়)।"),
    "offers": ("?P????F?F", "hide", "~45% (big-week G); not in the reality sweep.", "~৪৫% (বড় সপ্তাহ G); রিয়ালিটি সুইপে নেই।"),
    "referral": ("?P??PP??F", "show", "Referral rate / min redeem editable (pricing tests).", "রেফারেল হার / সর্বনিম্ন রিডিম বদলানো যায় (প্রাইসিং টেস্ট)।"),
    "plans_v2": ("?PP?P??P?", "hide", "plans-v2: server gates + tests for every gate, Owner Admin limits, upgrade sheet with Play prices; real two-phone run, reality-audit flow and the owner's 10-minute check (PLANS_V2_BN.md) pending.",
                 "প্ল্যান v2: সার্ভারে প্রতিটি গেট ও টেস্ট, Owner Admin-এ সীমা, Play দামের আপগ্রেড শিট; আসল দুই ফোনে পরীক্ষা, রিয়ালিটি-অডিট ফ্লো ও মালিকের ১০ মিনিটের পরীক্ষা (PLANS_V2_BN.md) বাকি।"),
    # ---- Upcoming (nothing built yet)
    "corporate_meetings": ("FFFFFFFFF", "hide", "~10%: not built (needs its own SFU server).", "~১০%: তৈরি হয়নি (আলাদা SFU সার্ভার লাগবে)।"),
    "remote_support": ("FFFFFFFFF", "hide", "~2%: design only.", "~২%: শুধু নকশা।"),
    "marketing": ("FFFFFFFFF", "hide", "~10%: not built.", "~১০%: তৈরি হয়নি।"),
    "retention": ("FFFFFFFFF", "hide", "~35% server parts; no user entry yet.", "~৩৫% সার্ভার অংশ; ব্যবহারকারীর এন্ট্রি নেই।"),
    "retention_auto": ("?PP?P??PP", "hide", "retention1: backend two-account flow + widget tests pass; no real two-phone run yet, 2 GB speed not measured, no reality-audit flow, Play Data safety answer (business messages) pending; WhatsApp/SMS live sends need the owner's keys.",
                       "retention1: সার্ভারে দুই-অ্যাকাউন্ট ফ্লো ও অ্যাপ টেস্ট পাস; আসল দুই ফোনে পরীক্ষা বাকি, ২ GB গতি মাপা হয়নি, রিয়ালিটি-অডিট ফ্লো নেই, Play Data safety উত্তর বাকি; WhatsApp/SMS আসল পাঠাতে মালিকের চাবি লাগবে।"),
    "booking": ("FFFFFFFFF", "hide", "~15%: not built.", "~১৫%: তৈরি হয়নি।"),
    # ---- App shell
    "home_v2": ("?PP???P??", "show", "New home (owner design v6): widget tests + bn/en/light/dark/200% screenshot gallery; old home stays as the OFF fallback for one week; real-phone 2 GB timing and the owner's 10-minute check pending.",
                "নতুন হোম (মালিকের ডিজাইন v6): উইজেট টেস্ট + বাংলা/ইংরেজি/লাইট/ডার্ক/২০০% স্ক্রিনশট; এক সপ্তাহ পুরনো হোম বন্ধ-সুইচের বিকল্প; আসল ২ GB ফোনে সময় ও মালিকের ১০ মিনিটের পরীক্ষা বাকি।"),
}

AUDIT = {
    k: {"codes": c, "play": p, "reason_en": en, "reason_bn": bn,
        "note_en": "Audit 26 Oct: %s Proposed Play 8 Nov: %s." % (en, p),
        "note_bn": "অডিট ২৬ Oct: %s ৮ নভেম্বর Play-প্রস্তাব: %s।" % (
            bn, "দেখান" if p == "show" else "Play-তে লুকান")}
    for k, (c, p, en, bn) in _A.items()
}


def checks_bools(key):
    a = AUDIT.get(key)
    if not a:
        return [False] * 9
    return [ch == "P" for ch in a["codes"]]
