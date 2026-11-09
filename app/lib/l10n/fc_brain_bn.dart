/// fcbrain — Bangla locale data for the family ask-bar parser and the night
/// news clock (lib/family_v3/brain/). Locale data, so it lives under
/// lib/l10n/ (the lang gate allows Bangla script only here). The sentences
/// mirror backend/core/logic/fc_ask.py word for word (shared case table
/// app/test/fixtures/fc_ask_cases.json).
library;

const kFcDigitsBn = '০১২৩৪৫৬৭৮৯';

/// Bangla words per relation (the English / romanized ones live in the parser).
const kFcRelationBn = <String, List<String>>{
  'mother': ['আম্মু', 'আম্মা', 'আম্মি', 'মা', 'মামণি'],
  'father': ['আব্বু', 'আব্বা', 'বাবা', 'বাপি'],
  'son': ['ছেলে'],
  'daughter': ['মেয়ে', 'মেয়ে'],
  'spouse': ['বউ', 'বৌ', 'স্ত্রী', 'স্বামী'],
  'brother': ['ভাই', 'ভাইয়া'],
  'sister': ['বোন', 'আপু', 'আপা', 'দিদি'],
  'grandparent': ['দাদু', 'নানু', 'দাদি', 'নানি'],
};
const kFcWhereBn = ['কোথায়', 'কোথায়', 'কই', 'লোকেশন'];
const kFcOkBn = ['ঠিক', 'ভালো', 'ভাল', 'নিরাপদ', 'কেমন'];
const kFcBatteryBn = ['ব্যাটারি', 'চার্জ'];
const kFcWhenBn = ['কখন', 'শেষ খবর'];
const kFcAllBn = ['সবাই', 'সকলে', 'পরিবার'];
const kFcSuffixBn = ['দের', 'এর', 'ের', 'র', 'কে', 'রা', 'টা', 'টি'];

/// The Bangla (U+0980-U+09FF) character test the punctuation stripper keeps.
const kFcDandaBn = '।';

const kFcReasonBn = <String, String>{
  'battery_off': 'চার্জ শেষ হয়ে ফোন বন্ধ হতে পারে',
  'no_internet': 'ইন্টারনেট নেই',
  'background_killed': 'ফোন ব্যাকগ্রাউন্ডে Assisto বন্ধ করে দিচ্ছে',
  'never': 'Assisto এখনো খবর পাঠায়নি',
  'clock': 'ফোনের ঘড়ি ভুল',
  'battery_low': 'চার্জ কম',
  'watch': 'অনেকক্ষণ কোনো সাড়া নেই',
  'carecall_missed': 'কেয়ার কল ধরেননি',
  'journey_overdue': 'যাত্রায় দেরি হচ্ছে',
};
const _atBn = <String, String>{
  'বাড়ি': 'বাড়িতে',
  'স্কুল': 'স্কুলে',
  'অফিস': 'অফিসে',
  'কলেজ': 'কলেজে',
  'মাদ্রাসা': 'মাদ্রাসায়',
  'দোকান': 'দোকানে',
};

String fcBnDigits(Object v) =>
    v.toString().replaceAllMapped(RegExp(r'[0-9]'), (m) => kFcDigitsBn[int.parse(m[0]!)]);

/// Natural Bangla locative: বাড়ি -> বাড়িতে, স্কুল -> স্কুলে, else "X-এ".
String fcAtBn(String place) => _atBn[place.trim()] ?? '${place.trim()}-এ';

/// Part of day for a 24 h hour (রাত / ভোর / সকাল / দুপুর / বিকাল / সন্ধ্যা).
String fcDayPartBn(int h) => h < 4
    ? 'রাত'
    : h < 6
        ? 'ভোর'
        : h < 12
            ? 'সকাল'
            : h < 15
                ? 'দুপুর'
                : h < 18
                    ? 'বিকাল'
                    : h < 20
                        ? 'সন্ধ্যা'
                        : 'রাত';

/// Ask-bar answers in Bangla (same words as the server).
class FcAskBn {
  FcAskBn._();
  static const justNow = 'এইমাত্র';
  static String minAgo(int n) => '${fcBnDigits(n)} মিনিট আগে';
  static String hAgo(int n) => '${fcBnDigits(n)} ঘণ্টা আগে';
  static String daysAgo(int n) => '${fcBnDigits(n)} দিন আগে';
  static String sos(String n) => '$n SOS চেপেছেন। এখনই ফোন করুন।';
  static String paused(String n) => '$n এখন শেয়ারিং বিরতিতে রেখেছেন।';
  static String ok(String n, String age, String where) =>
      'হ্যাঁ, $n ঠিক আছেন (শেষ খবর $age${where.isNotEmpty ? ', ${fcAtBn(where)}' : ''})।';
  static String check(String n, String r) => '$n-কে একবার দেখুন: $r।';
  static String stale(String n, String age, String r) =>
      '$n-এর কাছ থেকে নতুন খবর নেই${age.isNotEmpty ? ' (শেষ খবর $age)' : ''}${r.isNotEmpty ? '; $r' : ''}। নিশ্চিত হতে ফোন করুন।';
  static String wherePaused(String n) => '$n শেয়ারিং বিরতিতে রেখেছেন, তাই জায়গা দেখানো হচ্ছে না।';
  static String whereNow(String n, String place, String age) => '$n এখন ${fcAtBn(place)} (খবর $age)।';
  static String whereLast(String n, String place, String age) =>
      '$n শেষবার ${fcAtBn(place)} ছিলেন, $age। এরপর নতুন খবর নেই।';
  static String whereUnknown(String n, String age) =>
      '$n এখন কোথায় Assisto জানে না${age.isNotEmpty ? ' (শেষ খবর $age)' : ''}।';
  static String batteryUnknown(String n) => '$n-এর চার্জ এখন জানা নেই।';
  static String battery(String n, int b, String age) => '$n-এর ফোনে চার্জ ছিল ${fcBnDigits(b)}% ($age)।';
  static String noNewsYet(String n) => '$n-এর কাছ থেকে এখনো কোনো খবর আসেনি।';
  static String lastNews(String n, String age) => '$n-এর শেষ খবর: $age।';
  static const noFamily = 'পরিবারে এখনো কেউ নেই।';
  static const allOk = 'হ্যাঁ, সবাই ঠিক আছেন — সবার তাজা খবর আছে।';
  static String more(int k) => ' (আরও ${fcBnDigits(k)} জন)';
  static String notInList(String w) => 'আপনার পরিবারের তালিকায় "$w" নেই। My Circle থেকে যোগ করুন।';
  static String who(String names) => 'কার কথা বলছেন: $names?';
}
