/// fcrest — Probashi "Where I live": the countries most Bangladeshis abroad
/// live in, with their IANA time zone (the server checks it with zoneinfo).
/// Locale data, so it lives under lib/l10n/ (the lang gate allows Bangla
/// script only here). [zone, English, Bangla]
library;

const kFcrZones = <List<String>>[
  ['Asia/Riyadh', 'Saudi Arabia', 'সৌদি আরব'],
  ['Asia/Dubai', 'UAE (Dubai)', 'আমিরাত (দুবাই)'],
  ['Asia/Qatar', 'Qatar', 'কাতার'],
  ['Asia/Kuwait', 'Kuwait', 'কুয়েত'],
  ['Asia/Muscat', 'Oman', 'ওমান'],
  ['Asia/Bahrain', 'Bahrain', 'বাহরাইন'],
  ['Asia/Kuala_Lumpur', 'Malaysia', 'মালয়েশিয়া'],
  ['Asia/Singapore', 'Singapore', 'সিঙ্গাপুর'],
  ['Asia/Kolkata', 'India', 'ভারত'],
  ['Asia/Tokyo', 'Japan', 'জাপান'],
  ['Asia/Seoul', 'South Korea', 'দক্ষিণ কোরিয়া'],
  ['Europe/London', 'United Kingdom', 'যুক্তরাজ্য'],
  ['Europe/Rome', 'Italy', 'ইতালি'],
  ['Europe/Paris', 'France', 'ফ্রান্স'],
  ['Europe/Berlin', 'Germany', 'জার্মানি'],
  ['America/New_York', 'USA (New York)', 'যুক্তরাষ্ট্র (নিউইয়র্ক)'],
  ['America/Los_Angeles', 'USA (California)', 'যুক্তরাষ্ট্র (ক্যালিফোর্নিয়া)'],
  ['America/Toronto', 'Canada (Toronto)', 'কানাডা (টরন্টো)'],
  ['Australia/Sydney', 'Australia (Sydney)', 'অস্ট্রেলিয়া (সিডনি)'],
];

/// The country name for [zone] in [lang]; the zone's city otherwise.
String fcrZoneName(String zone, String lang) {
  for (final z in kFcrZones) {
    if (z[0] == zone) return lang == 'bn' ? z[2] : z[1];
  }
  final i = zone.lastIndexOf('/');
  return (i >= 0 ? zone.substring(i + 1) : zone).replaceAll('_', ' ');
}
