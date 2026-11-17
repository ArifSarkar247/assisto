/// ai-reply-notif — Dart mirror of the native rules in
/// android_overlay/.../notiflisten/AiReplyAllow.kt (a test compares the
/// package lists so they never drift). The native side decides on the phone;
/// this copy drives the per-app list and the tests.
class AiReplyRules {
  AiReplyRules._();

  /// Chat apps the user can switch on: package -> slug (exact match only).
  static const Map<String, String> chatApps = {
    'com.whatsapp': 'whatsapp',
    'com.whatsapp.w4b': 'whatsapp_business',
    'com.facebook.orca': 'messenger',
    'com.facebook.mlite': 'messenger',
    'org.telegram.messenger': 'telegram',
    'org.telegram.messenger.web': 'telegram',
    'com.imo.android.imoim': 'imo',
    'com.imo.android.imous': 'imo',
    'com.viber.voip': 'viber',
    'org.thoughtcrime.securesms': 'signal',
  };

  /// Assisto's own My Circle chat.
  static const String myCircle = 'mycircle';

  /// The per-app list, in the order shown (My Circle first).
  static const List<String> slugs = [
    myCircle,
    'whatsapp',
    'whatsapp_business',
    'messenger',
    'telegram',
    'imo',
    'viber',
    'signal',
  ];

  /// Brand names are the same in Bangla and English (My Circle is localized
  /// by the screen).
  static const Map<String, String> brand = {
    'whatsapp': 'WhatsApp',
    'whatsapp_business': 'WhatsApp Business',
    'messenger': 'Messenger',
    'telegram': 'Telegram',
    'imo': 'imo',
    'viber': 'Viber',
    'signal': 'Signal',
  };

  static const Set<String> blockedPackages = {
    'com.bKash.customerapp', 'com.bkash.businessapp', 'com.konasl.nagad',
    'com.dbbl.mbs.apps.main', 'com.dbbl.nexus.pay', 'com.ibbl.cellfin',
    'com.thecitybank.citytouch', 'com.upay.android', 'com.bracbank.astha',
    'com.ebl.skybanking', 'com.mtb.smart', 'com.primebank.mybank',
    'com.google.android.apps.messaging', 'com.android.mms', 'com.android.messaging',
    'com.samsung.android.messaging', 'com.oplus.mms', 'com.coloros.mms',
    'com.android.systemui', 'android', 'com.android.phone',
    'com.google.android.gms', 'com.android.settings',
  };

  static const _blockedWords = ['bank', 'bkash', 'nagad', 'rocket', 'upay', 'wallet', 'pay', 'otp', 'mms', 'sms'];

  static bool isBlockedPackage(String pkg) {
    if (blockedPackages.contains(pkg)) return true;
    if (chatApps.containsKey(pkg)) return false;
    final p = pkg.toLowerCase();
    return _blockedWords.any(p.contains);
  }

  static const myCircleChannels = {'chat_msg_v2', 'messages'};

  /// Slug for an allowed chat notification, or null (= never read).
  static String? chatSlug(String pkg, String ownPkg, String? channelId) {
    if (pkg == ownPkg) return myCircleChannels.contains(channelId) ? myCircle : null;
    if (isBlockedPackage(pkg)) return null;
    return chatApps[pkg];
  }

  // Same patterns as AiReplyAllow.kt (OTP, money, SOS) — no suggestions at all.
  static final _otp = RegExp(
      r'\botp\b|one[- ]time|verification|verify|passcode|password|\bpin\b|\bcode\b|ওটিপি|কোড|পিন|পাসওয়ার্ড|যাচাই',
      caseSensitive: false);
  static final _codeDigits = RegExp(r'(?<![\d০-৯])[\d০-৯]{4,8}(?![\d০-৯])');
  static final _money = RegExp(
      r'৳|\btk\b|\btaka\b|\bbdt\b|টাকা|bkash|bikash|nagad|rocket|upay|send ?money|cash ?out|cash ?in|payment|\bpay\b|\bpaid\b|transfer|loan|\bdue\b|account ?(no|number)|a/c|trx|txn|balance|বিকাশ|নগদ|রকেট|পেমেন্ট|ধার|লোন|ব্যালেন্স|পাঠাও টাকা|টাকা পাঠা',
      caseSensitive: false);
  static final _sos = RegExp(
      r'\bsos\b|emergency|help me|save me|accident|hospital|ambulance|police|kidnap|জরুরি|বাঁচাও|বাচাও|সাহায্য কর|দুর্ঘটনা|হাসপাতাল|অ্যাম্বুলেন্স|পুলিশ|বিপদ',
      caseSensitive: false);

  /// 'otp' | 'money' | 'sos' | 'empty' when blocked, else null.
  static String? blockedText(String? sender, String? text) {
    final t = (text ?? '').trim();
    if (t.isEmpty) return 'empty';
    final all = '${sender ?? ''}\n$t';
    if (_sos.hasMatch(all)) return 'sos';
    if (_otp.hasMatch(all)) return 'otp';
    if (_codeDigits.hasMatch(t) && t.length < 200) return 'otp';
    if (_money.hasMatch(all)) return 'money';
    return null;
  }
}
