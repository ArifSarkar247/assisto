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
      '\\botp\\b|one[- ]time|verification|verify|passcode|password|\\bpin\\b|\\bcode\\b|\u0993\u099F\u09BF\u09AA\u09BF|\u0995\u09CB\u09A1|\u09AA\u09BF\u09A8|\u09AA\u09BE\u09B8\u0993\u09AF\u09BC\u09BE\u09B0\u09CD\u09A1|\u09AF\u09BE\u099A\u09BE\u0987',
      caseSensitive: false);
  static final _codeDigits = RegExp('(?<![\\d\u09E6-\u09EF])[\\d\u09E6-\u09EF]{4,8}(?![\\d\u09E6-\u09EF])');
  static final _money = RegExp(
      '\u09F3|\\btk\\b|\\btaka\\b|\\bbdt\\b|\u099F\u09BE\u0995\u09BE|bkash|bikash|nagad|rocket|upay|send ?money|cash ?out|cash ?in|payment|\\bpay\\b|\\bpaid\\b|transfer|loan|\\bdue\\b|account ?(no|number)|a/c|trx|txn|balance|\u09AC\u09BF\u0995\u09BE\u09B6|\u09A8\u0997\u09A6|\u09B0\u0995\u09C7\u099F|\u09AA\u09C7\u09AE\u09C7\u09A8\u09CD\u099F|\u09A7\u09BE\u09B0|\u09B2\u09CB\u09A8|\u09AC\u09CD\u09AF\u09BE\u09B2\u09C7\u09A8\u09CD\u09B8|\u09AA\u09BE\u09A0\u09BE\u0993 \u099F\u09BE\u0995\u09BE|\u099F\u09BE\u0995\u09BE \u09AA\u09BE\u09A0\u09BE',
      caseSensitive: false);
  static final _sos = RegExp(
      '\\bsos\\b|emergency|help me|save me|accident|hospital|ambulance|police|kidnap|\u099C\u09B0\u09C1\u09B0\u09BF|\u09AC\u09BE\u0981\u099A\u09BE\u0993|\u09AC\u09BE\u099A\u09BE\u0993|\u09B8\u09BE\u09B9\u09BE\u09AF\u09CD\u09AF \u0995\u09B0|\u09A6\u09C1\u09B0\u09CD\u0998\u099F\u09A8\u09BE|\u09B9\u09BE\u09B8\u09AA\u09BE\u09A4\u09BE\u09B2|\u0985\u09CD\u09AF\u09BE\u09AE\u09CD\u09AC\u09C1\u09B2\u09C7\u09A8\u09CD\u09B8|\u09AA\u09C1\u09B2\u09BF\u09B6|\u09AC\u09BF\u09AA\u09A6',
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
