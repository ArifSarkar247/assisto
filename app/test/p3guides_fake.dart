// p3guides: fake server answers for GET /official-info/<section> and the
// ADVANCED /guides e-namjari card (same shape as backend
// core/logic/official_info.py + govt_guide.localized). Bangla text uses
// Bangla digits, exactly like the server.
Map<String, dynamic>? fakeP3gGet(String path, bool bn) {
  if (path.startsWith('/official-info/probashi')) return p3gFakeProbashi(bn);
  if (path.startsWith('/official-info/student')) return p3gFakeStudent(bn);
  return null;
}

Map<String, dynamic> p3gFakeProbashi(bool bn) => {
      'checked': '2026-11-03',
      'helplines': [
        {'id': 'probashbondhu', 'dial': '16135',
         'name': bn ? 'প্রবাসবন্ধু কল সেন্টার (দেশ থেকে)' : 'Probash-Bondhu call centre (from Bangladesh)',
         'display': bn ? '১৬১৩৫' : '16135',
         'note': bn ? 'টোল-ফ্রি, ২৪ ঘণ্টা — ওয়েজ আর্নার্স কল্যাণ বোর্ড' : "Toll-free, 24 hours — Wage Earners' Welfare Board",
         'source': 'https://wewb.gov.bd'},
        {'id': 'probashbondhu_abroad', 'dial': '+8809610102030',
         'name': bn ? 'প্রবাসবন্ধু — বিদেশ থেকে' : 'Probash-Bondhu — from abroad',
         'display': bn ? '+৮৮ ০৯৬১০১০২০৩০' : '+88 09610102030',
         'note': bn ? 'বিদেশ থেকে কল করার নম্বর' : 'Number to call from abroad',
         'source': 'https://wewb.gov.bd'},
      ],
      'links': [
        {'label': bn ? 'বিদেশে বাংলাদেশ দূতাবাস/মিশনের তালিকা' : 'Bangladesh missions abroad', 'url': 'https://mofa.gov.bd'},
        {'label': bn ? 'ওয়েজ আর্নার্স কল্যাণ বোর্ড' : "Wage Earners' Welfare Board", 'url': 'https://wewb.gov.bd'},
      ],
      'welfare': [
        {'id': 'death_grant',
         'title': bn ? 'মৃত্যুতে পরিবারকে আর্থিক অনুদান' : 'Grant to the family after a death abroad',
         'amount': bn ? '৳৩,০০,০০০' : 'Tk 300,000',
         'note': bn ? 'বহির্গমন ছাড়পত্র বা বোর্ডের সদস্যপদ থাকলে।' : 'If the worker had emigration clearance or board membership.'},
      ],
      'welfare_basis': bn ? 'সূত্র: প্রবাসী কল্যাণ মন্ত্রীর সংসদে দেওয়া তথ্য ও কল্যাণ বোর্ড।' : "Source: the minister's statement in parliament and the board.",
      'welfare_source': 'https://wewb.gov.bd',
      'remit': {
        'incentive_pct': 2.5,
        'incentive_note': bn ? 'বৈধ পথে পাঠালে সরকারি প্রণোদনা ২.৫%। হুন্ডি অবৈধ।' : "Official channels earn the government's 2.5% incentive. Hundi is illegal.",
        'incentive_source': 'https://www.bb.org.bd',
        'sdg_target_pct': 3.0,
        'sdg_note': bn ? 'জাতিসংঘের লক্ষ্য: খরচ ৩%-এর নিচে।' : 'UN target: cost below 3%.',
        'sdg_source': 'https://sdgs.un.org/goals/goal10',
        'rpw_note': bn ? 'বিশ্বব্যাংক প্রতি তিন মাসে খরচ প্রকাশ করে।' : 'The World Bank publishes costs every quarter.',
        'rpw_source': 'https://remittanceprices.worldbank.org',
        'rate_note': bn ? 'আজকের রেট বাংলাদেশ ব্যাংকে।' : "Today's rate is on Bangladesh Bank's site.",
        'rate_source': 'https://www.bb.org.bd',
      },
      'sos_tips': [
        bn ? 'বিপদে আগে স্থানীয় জরুরি নম্বরে কল করুন।' : 'In danger, call the local emergency number first.',
      ],
    };

Map<String, dynamic> p3gFakeStudent(bool bn) => {
      'checked': '2026-11-03',
      'groups': [
        {'id': 'scholarship', 'title': bn ? 'বৃত্তি ও উপবৃত্তি' : 'Scholarships and stipends',
         'note': bn ? 'শেষ তারিখ নোটিশে আসে।' : 'Each deadline comes in the official notice.',
         'links': [{'label': bn ? 'মাধ্যমিক ও উচ্চ শিক্ষা অধিদপ্তর (মাউশি)' : 'Directorate of Secondary & Higher Education (DSHE)', 'url': 'https://dshe.gov.bd'}]},
        {'id': 'admission', 'title': bn ? 'ভর্তি (একাদশ ও বিশ্ববিদ্যালয়)' : 'Admissions (Class XI and university)',
         'note': bn ? 'শুধু অফিশিয়াল সাইট মানুন।' : 'Trust only official sites.',
         'links': [{'label': bn ? 'গুচ্ছ (GST) ভর্তি' : 'GST cluster admission', 'url': 'https://gstadmission.ac.bd'}]},
      ],
      'books_note': bn ? 'এখানে কোনো বই নেই — পাঠ্যবই এনসিটিবি-র সাইটে বিনামূল্যে।' : "No books here — textbooks are free on NCTB's site.",
      'books_source': 'https://nctb.gov.bd',
    };

/// The ADVANCED e-namjari service as /guides sends it.
Map<String, dynamic> p3gFakeEmutation(bool bn) => {
      'key': 'emutation',
      'category': 'land',
      'name': bn ? 'জমির ই-নামজারি (ই-মিউটেশন)' : 'Land e-mutation (e-namjari)',
      'portal': 'mutation.land.gov.bd',
      'url': 'https://mutation.land.gov.bd',
      'steps': bn
          ? ['ই-নামজারি সাইটে আবেদন শুরু করুন', 'কোর্ট ফি ও নোটিশ ফি অনলাইনে দিন']
          : ['Start the application on the e-mutation site', 'Pay the court fee and notice fee online'],
      'docs': bn
          ? ['দলিলের কপি', 'আগের খতিয়ান / পর্চা', 'জাতীয় পরিচয়পত্র (NID)']
          : ['Copy of the deed', 'Previous khatian / porcha', 'National ID (NID)'],
      'fee': bn ? 'মোট ফি ১,১৭০ টাকা' : 'Total fee Tk 1,170',
      'fee_verify': true,
      'office': bn ? 'সহকারী কমিশনার (ভূমি) অফিস' : 'Assistant Commissioner (Land) office',
      'time': '',
      'time_verify': true,
      'mistakes': <String>[],
      'source': bn ? 'সূত্র: mutation.land.gov.bd' : 'Source: mutation.land.gov.bd',
      'disclaimer': '',
      'official': {
        'checked': '2026-11-03',
        'fee_status': 'published',
        'fee_page': 'https://mutation.land.gov.bd',
        'fee_basis': bn ? 'ভূমি মন্ত্রণালয়ের পরিপত্র' : 'Ministry of Land circular',
        'fee_note': '',
        'fees': [
          {'label': bn ? 'কোর্ট ফি (আবেদন)' : 'Court fee (application)', 'amount': bn ? '৳২০' : 'Tk 20'},
          {'label': bn ? 'নোটিশ জারি ফি' : 'Notice fee', 'amount': bn ? '৳৫০' : 'Tk 50'},
          {'label': bn ? 'রেকর্ড সংশোধন ফি' : 'Record correction fee', 'amount': bn ? '৳১,০০০' : 'Tk 1,000'},
          {'label': bn ? 'খতিয়ান সরবরাহ ফি' : 'Khatian copy fee', 'amount': bn ? '৳১০০' : 'Tk 100'},
          {'label': bn ? 'মোট' : 'Total', 'amount': bn ? '৳১,১৭০' : 'Tk 1,170'},
        ],
        'sources': [
          {'label': bn ? 'ই-নামজারি (ভূমি মন্ত্রণালয়)' : 'e-Mutation (Ministry of Land)', 'url': 'https://mutation.land.gov.bd'},
        ],
      },
    };
