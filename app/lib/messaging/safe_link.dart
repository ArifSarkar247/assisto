/// circlea — "is this link risky?" ON THE PHONE (pure, no network).
///
/// The same rules as backend core/logic/safe_link.py, so an end-to-end
/// encrypted chat is checked without its URL ever leaving the phone.
///   bad  -> payment / login lookalike (bkash, nagad …), "user@host", not http(s)
///   warn -> punycode / non-ASCII host, raw IP host, URL shortener, plain
///           http, suspicious top-level domain
///   ok   -> none of the above
library;

enum LinkVerdict { ok, warn, bad }

class LinkCheck {
  final LinkVerdict verdict;
  final List<String> reasons;
  final String host;
  final String brand;
  const LinkCheck(this.verdict, this.reasons, this.host, [this.brand = '']);
}

const Set<String> kShorteners = {
  'bit.ly', 'bitly.com', 'tinyurl.com', 't.co', 'goo.gl', 'ow.ly', 'is.gd',
  'buff.ly', 'cutt.ly', 'rb.gy', 'shorturl.at', 'rebrand.ly', 'tiny.cc', 's.id',
  't.ly', 'lnkd.in', 'shorte.st', 'adf.ly', 'v.gd', 'bl.ink', 'short.io',
  'tr.im', 'qr.ae', 'surl.li', 'u.to', 'clck.ru', 'shrtco.de',
};

const Set<String> kSuspiciousTlds = {
  'zip', 'mov', 'xyz', 'top', 'click', 'country', 'gq', 'tk', 'ml', 'cf', 'ga',
  'work', 'loan', 'men', 'rest', 'cam', 'icu', 'buzz', 'monster', 'cyou', 'sbs',
  'cfd', 'quest', 'bond', 'lol', 'support', 'beauty',
};

const Map<String, List<String>> kBrands = {
  'bkash': ['bkash.com'],
  'nagad': ['nagad.com.bd'],
  'rocket': ['dutchbanglabank.com'],
  'upay': ['upaybd.com'],
  'dbbl': ['dutchbanglabank.com'],
  'sonalibank': ['sonalibank.com.bd'],
  'bracbank': ['bracbank.com'],
  'facebook': ['facebook.com', 'fb.com', 'fb.watch', 'fb.me', 'messenger.com'],
  'whatsapp': ['whatsapp.com', 'wa.me', 'whatsapp.net'],
  'google': ['google.com', 'google.com.bd', 'goo.gl', 'youtube.com', 'g.co'],
  'youtube': ['youtube.com', 'youtu.be'],
  'instagram': ['instagram.com'],
  'tiktok': ['tiktok.com'],
  'paypal': ['paypal.com'],
  'assisto': ['lifeassisto.com'],
  'daraz': ['daraz.com.bd'],
};
const Set<String> kAmbiguousBrands = {'rocket', 'upay', 'google', 'assisto', 'daraz'};
const List<String> kLoginWords = [
  'login', 'signin', 'verify', 'secure', 'account', 'update', 'bonus',
  'reward', 'gift', 'free', 'otp', 'pin', 'wallet', 'kyc',
];
const Set<String> _secondLevel = {'com', 'net', 'org', 'gov', 'edu', 'ac', 'co', 'mil', 'info'};
const Map<String, String> _leet = {
  '0': 'o', '1': 'l', '3': 'e', '4': 'a', '5': 's', '7': 't', '@': 'a', r'$': 's',
};

String _unleet(String s) => s.split('').map((c) => _leet[c] ?? c).join();

String registrableDomain(String host) {
  final parts = host.toLowerCase().split('.').where((p) => p.isNotEmpty).toList();
  if (parts.length >= 3 &&
      _secondLevel.contains(parts[parts.length - 2]) &&
      parts.last.length == 2) {
    return parts.sublist(parts.length - 3).join('.');
  }
  return parts.length <= 2 ? parts.join('.') : parts.sublist(parts.length - 2).join('.');
}

bool _isIp(String host) {
  final h = host.replaceAll('[', '').replaceAll(']', '');
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h)) return true;
  return h.contains(':'); // IPv6 literal
}

/// Levenshtein distance <= 1 (typo-squats: b1kash, bkassh, nagadd).
bool _near(String a, String b) {
  if (a == b) return true;
  if ((a.length - b.length).abs() > 1) return false;
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  String tail(String s, int from) => from >= s.length ? '' : s.substring(from);
  return tail(a, i + 1) == tail(b, i + 1) ||
      tail(a, i) == tail(b, i + 1) ||
      tail(a, i + 1) == tail(b, i);
}

LinkCheck checkLink(String url) {
  final reasons = <String>[];
  var brand = '';
  final raw = url.trim();
  Uri? u = Uri.tryParse(raw);
  if (u == null) return const LinkCheck(LinkVerdict.bad, ['bad_url'], '');
  if (!u.hasScheme) {
    u = Uri.tryParse('http://$raw');
    if (u == null) return const LinkCheck(LinkVerdict.bad, ['bad_url'], '');
  }
  final scheme = u.scheme.toLowerCase();
  if (u.userInfo.isNotEmpty) reasons.add('userinfo');
  final host = u.host.toLowerCase().replaceAll(RegExp(r'\.+$'), '');
  if (scheme != 'http' && scheme != 'https') {
    reasons.add('scheme');
  } else if (scheme == 'http') {
    reasons.add('not_https');
  }
  if (host.isEmpty) {
    return LinkCheck(LinkVerdict.bad, reasons.isEmpty ? ['bad_url'] : reasons, '');
  }
  if (_isIp(host)) reasons.add('ip_host');
  if (host.contains('xn--') || host.contains('%') || host.codeUnits.any((c) => c > 127)) {
    reasons.add('punycode');
  }
  final reg = registrableDomain(host);
  if (kShorteners.contains(host) || kShorteners.contains(reg)) reasons.add('shortener');
  final tld = host.contains('.') ? host.substring(host.lastIndexOf('.') + 1) : '';
  if (kSuspiciousTlds.contains(tld)) reasons.add('suspicious_tld');
  final flat = _unleet(host).replaceAll('-', '').replaceAll('.', '');
  final hostLogin = kLoginWords.any(flat.contains);
  for (final e in kBrands.entries) {
    if (flat.contains(e.key) &&
        !e.value.contains(reg) &&
        (!kAmbiguousBrands.contains(e.key) || hostLogin)) {
      brand = e.key;
      reasons.add('lookalike');
      break;
    }
  }
  if (brand.isEmpty) {
    outer:
    for (final label in host.split('.')) {
      final lab = label.replaceAll('-', '');
      for (final e in kBrands.entries) {
        if (e.key.length >= 5 &&
            !kAmbiguousBrands.contains(e.key) &&
            !e.value.contains(reg) &&
            (_near(lab, e.key) || _near(_unleet(lab), e.key))) {
          brand = e.key;
          reasons.add('lookalike');
          break outer;
        }
      }
    }
  }
  if (brand.isEmpty) {
    final path = _unleet(u.path.toLowerCase());
    for (final e in kBrands.entries) {
      if (path.contains(e.key) &&
          !e.value.contains(reg) &&
          kLoginWords.any(path.contains)) {
        brand = e.key;
        reasons.add('lookalike');
        break;
      }
    }
  }
  final LinkVerdict v;
  if (reasons.contains('lookalike') || reasons.contains('userinfo') || reasons.contains('scheme')) {
    v = LinkVerdict.bad;
  } else if (reasons.isNotEmpty) {
    v = LinkVerdict.warn;
  } else {
    v = LinkVerdict.ok;
  }
  return LinkCheck(v, reasons, host, brand);
}
