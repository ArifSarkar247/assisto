/// callmoney — the ONLY notifications Assisto's listener may look at.
///
/// This is the Dart mirror of the native gate
/// (android_overlay/.../notiflisten/NotifAllow.kt); test/callmoney_test.dart
/// fails if the two lists ever drift. The native side decides from the
/// posting package (and, for the default SMS app, the sender title) BEFORE it
/// reads any text; every other notification is ignored unread.
class NotifAllowList {
  NotifAllowList._();

  /// Wallet + bank apps: package -> wallet slug (exact match only).
  static const moneyApps = <String, String>{
    'com.bKash.customerapp': 'bkash',
    'com.konasl.nagad': 'nagad',
    'com.dbbl.mbs.apps.main': 'rocket',
    'com.dbbl.nexus.pay': 'bank',
    'com.ibbl.cellfin': 'bank',
    'com.thecitybank.citytouch': 'bank',
  };

  /// SMS sender ids (upper-case, no spaces / dots / dashes) -> wallet slug.
  static const moneySmsSenders = <String, String>{
    'BKASH': 'bkash', '16247': 'bkash',
    'NAGAD': 'nagad', '16167': 'nagad',
    'ROCKET': 'rocket', 'DBBL': 'rocket', '16216': 'rocket',
    'UPAY': 'upay',
    'BRACBANK': 'bank', 'CITYBANK': 'bank', 'EBL': 'bank', 'IBBL': 'bank',
    'MTB': 'bank', 'PRIMEBANK': 'bank', 'SCB': 'bank', 'UCB': 'bank',
    'SONALIBANK': 'bank', 'JANATABANK': 'bank', 'AGRANIBANK': 'bank',
    'PUBALIBANK': 'bank', 'BANKASIA': 'bank', 'DHAKABANK': 'bank',
    'ONEBANK': 'bank', 'NCCBANK': 'bank', 'SIBL': 'bank', 'FSIBL': 'bank',
    'AIBL': 'bank', 'TRUSTBANK': 'bank', 'JAMUNABANK': 'bank',
    'MERCANTILE': 'bank', 'SEBL': 'bank', 'ABBANK': 'bank',
  };

  /// WhatsApp / Messenger call notifications: package -> call source.
  static const voipCallApps = <String, String>{
    'com.whatsapp': 'whatsapp',
    'com.whatsapp.w4b': 'whatsapp',
    'com.facebook.orca': 'messenger',
    'com.facebook.mlite': 'messenger',
  };

  /// Phone (SIM) in-call UIs, on top of the phone's default dialer.
  static const dialerApps = <String>{
    'com.google.android.dialer', 'com.android.dialer', 'com.android.incallui',
    'com.samsung.android.incallui', 'com.samsung.android.dialer',
    'com.android.server.telecom', 'com.oplus.dialer', 'com.coloros.dialer',
    'com.oplus.incallui', 'com.transsion.dialer',
  };

  /// Wallet slugs in display order (monthly summary).
  static const wallets = ['bkash', 'nagad', 'rocket', 'upay', 'bank'];

  static String normSender(String? title) {
    final t = (title ?? '').trim();
    if (t.isEmpty || t.contains(' ')) return ''; // saved contact names have spaces
    return t.toUpperCase().replaceAll('-', '').replaceAll('_', '').replaceAll('.', '');
  }

  /// Wallet slug for an SMS sender, or null = its text must never be read.
  static String? smsSenderWallet(String? title) {
    final n = normSender(title);
    return n.isEmpty ? null : moneySmsSenders[n];
  }

  /// 'sim' / 'whatsapp' / 'messenger' or null (= not a call we track).
  static String? callSource(String pkg, {String? defaultDialer}) {
    final v = voipCallApps[pkg];
    if (v != null) return v;
    if (pkg == defaultDialer || dialerApps.contains(pkg)) return 'sim';
    return null;
  }

  /// 'app' (wallet/bank app) / 'sms' (the default SMS app) / null (ignore).
  static String? moneyPackageKind(String pkg, {String? defaultSms}) {
    if (moneyApps.containsKey(pkg)) return 'app';
    if (defaultSms != null && pkg == defaultSms) return 'sms';
    return null;
  }

  /// The full native decision, for tests: may this notification's TEXT be
  /// read for money? (SMS: only after the sender passed.)
  static String? moneyWalletFor(String pkg, {String? defaultSms, String? smsTitle}) {
    final kind = moneyPackageKind(pkg, defaultSms: defaultSms);
    if (kind == 'app') return moneyApps[pkg];
    if (kind == 'sms') return smsSenderWallet(smsTitle);
    return null;
  }
}
