// P3 — on-device scam warning for incoming My Circle messages.
//
// PRIVACY: runs ONLY on the phone over text it already decrypted. Nothing is
// sent to the server or to any AI. The result is a non-blocking banner under
// the message with a "Why?" explanation; the message itself is untouched.
//
// Rule-based, bn + Banglish + en. Every rule is a COMBINATION (e.g. "OTP"
// alone is fine; "OTP ta dao" is not; "do not share your OTP" is a bank's own
// warning and never flags) so family chats do not drown in false alarms.
//
// Language gate: Bangla literals in this file are \u escapes (generated).
import 'assisto_card.dart' show normBn;

/// Why a message looks like a scam. The UI localises each key.
enum ScamReason { otpRequest, mfsAgent, prize, lookalikeLink, urgentMoney }

class ScamVerdict {
  final List<ScamReason> reasons;
  final String domain; // the look-alike domain, when that rule fired
  const ScamVerdict(this.reasons, {this.domain = ''});
  bool get flagged => reasons.isNotEmpty;
  static const none = ScamVerdict([]);
}

String _norm(String s) {
  var t = normBn(s).toLowerCase();
  const bn = '\u09e6\u09e7\u09e8\u09e9\u09ea\u09eb\u09ec\u09ed\u09ee\u09ef';
  for (var i = 0; i < 10; i++) {
    t = t.replaceAll(bn[i], '$i');
  }
  // "o t p" / "p i n" spaced out to dodge filters
  t = t.replaceAllMapped(RegExp(r'\b([a-z]) ([a-z]) ([a-z])\b'), (m) {
    final w = '${m[1]}${m[2]}${m[3]}';
    return (w == 'otp' || w == 'pin' || w == 'cvv') ? w : m[0]!;
  });
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _any(String t, List<String> words) =>
    words.any((w) => t.contains(normBn(w)));

// ---- vocabulary --------------------------------------------------------
const _secret = [
  'otp', 'pin', 'cvv', 'password', 'verification code', 'secret code',
  '\u0993\u099f\u09bf\u09aa\u09bf', '\u09aa\u09bf\u09a8', '\u0995\u09cb\u09a1', '\u09aa\u09be\u09b8\u0993\u09af\u09bc\u09be\u09b0\u09cd\u09a1', '\u0997\u09cb\u09aa\u09a8 \u09a8\u09ae\u09cd\u09ac\u09b0',
];
// "do not share" — a bank/MFS warning, never a request
const _negation = [
  'do not share', "don't share", 'dont share', 'never share', 'not share',
  'share korben na', 'kauke diben na', 'kauke deben na', 'karo sathe share',
  '\u0995\u09be\u0989\u0995\u09c7 \u09a6\u09c7\u09ac\u09c7\u09a8 \u09a8\u09be', '\u0995\u09be\u0989\u0995\u09c7 \u09a6\u09bf\u09ac\u09c7\u09a8 \u09a8\u09be', '\u09b6\u09c7\u09af\u09bc\u09be\u09b0 \u0995\u09b0\u09ac\u09c7\u09a8 \u09a8\u09be', '\u0995\u09be\u0989\u0995\u09c7 \u09ac\u09b2\u09ac\u09c7\u09a8 \u09a8\u09be',
  '\u0995\u09be\u09b0\u09cb \u09b8\u09be\u09a5\u09c7 \u09b6\u09c7\u09af\u09bc\u09be\u09b0',
];
const _mfs = [
  'bkash', 'bikash', 'b kash', 'nagad', 'rocket', 'upay',
  '\u09ac\u09bf\u0995\u09be\u09b6', '\u09a8\u0997\u09a6', '\u09b0\u0995\u09c7\u099f', '\u0989\u09aa\u09be\u09af\u09bc',
];
const _mfsTrick = [
  'agent', 'customer care', 'customer service', 'head office', 'helpline',
  'account block', 'account bondho', 'account bandho', 'account will be',
  'by mistake', 'wrong number', 'bhul kore', 'vul kore', 'bhule',
  'ferot', 'return the money', 'send back', 'reverse', 'cash out kore',
  '\u098f\u099c\u09c7\u09a8\u09cd\u099f', '\u0995\u09be\u09b8\u09cd\u099f\u09ae\u09be\u09b0 \u0995\u09c7\u09af\u09bc\u09be\u09b0', '\u09b9\u09c7\u09a1 \u0985\u09ab\u09bf\u09b8', '\u0985\u09cd\u09af\u09be\u0995\u09be\u0989\u09a8\u09cd\u099f \u09ac\u09a8\u09cd\u09a7', '\u098f\u0995\u09be\u0989\u09a8\u09cd\u099f \u09ac\u09a8\u09cd\u09a7',
  '\u09ad\u09c1\u09b2 \u0995\u09b0\u09c7', '\u09ad\u09c1\u09b2\u09c7', '\u09ab\u09c7\u09b0\u09a4', '\u09b0\u09bf\u09ad\u09be\u09b0\u09cd\u09b8', '\u0995\u09cd\u09af\u09be\u09b6 \u0986\u0989\u099f \u0995\u09b0\u09c7',
];
const _prize = [
  'lottery', 'prize', 'you have won', "you've won", 'you won', 'winner',
  'lucky draw', 'jitechen', 'puroskar', 'bijoyi',
  '\u09b2\u099f\u09be\u09b0\u09bf', '\u09aa\u09c1\u09b0\u09b8\u09cd\u0995\u09be\u09b0', '\u099c\u09bf\u09a4\u09c7\u099b\u09c7\u09a8', '\u09ac\u09bf\u099c\u09af\u09bc\u09c0', '\u09b2\u09be\u0995\u09bf \u09a1\u09cd\u09b0',
];
const _prizeHook = [
  'fee', 'charge', 'claim', 'taka', ' tk', 'tk ', 'send', 'http', 'www.',
  'bkash', 'nagad', 'click', 'link', 'pathan', 'pathao',
  '\u09ab\u09bf', '\u099a\u09be\u09b0\u09cd\u099c', '\u099f\u09be\u0995\u09be', '\u09aa\u09be\u09a0\u09be\u09a8', '\u09b2\u09bf\u0982\u0995', '\u0995\u09cd\u09b2\u09bf\u0995', '\u09a6\u09be\u09ac\u09bf',
];
const _moneyAsk = [
  'send money', 'send me money', 'need money', 'need taka',
  'transfer', 'taka pathao', 'taka pathan', 'taka lagbe', 'tk lagbe',
  'bkash koro', 'bkash kor', 'nagad koro', 'flexi', 'recharge kore dao',
  '\u099f\u09be\u0995\u09be \u09aa\u09be\u09a0\u09be', '\u099f\u09be\u0995\u09be \u09b2\u09be\u0997\u09ac\u09c7', '\u099f\u09be\u0995\u09be \u09a6\u09b0\u0995\u09be\u09b0', '\u09ac\u09bf\u0995\u09be\u09b6 \u0995\u09b0\u09cb', '\u09ac\u09bf\u0995\u09be\u09b6 \u0995\u09b0',
  '\u09a8\u0997\u09a6 \u0995\u09b0\u09cb', '\u099f\u09be\u0995\u09be \u09a6\u09be\u0993',
];
const _urgent = [
  'urgent', 'emergency', 'asap', 'right now', 'immediately', 'hurry',
  'ekhoni', 'ekhuni', 'joldi', 'taratari', 'bipod', 'hospital', 'accident',
  '\u098f\u0996\u09a8\u0987', '\u099c\u09b2\u09a6\u09bf', '\u09a4\u09be\u09a1\u09bc\u09be\u09a4\u09be\u09a1\u09bc\u09bf', '\u099c\u09b0\u09c1\u09b0\u09bf', '\u09ac\u09bf\u09aa\u09a6', '\u09b9\u09be\u09b8\u09aa\u09be\u09a4\u09be\u09b2', '\u09a6\u09c1\u09b0\u09cd\u0998\u099f\u09a8\u09be',
];
const _newNumber = [
  'new number', 'notun number', 'my number changed', 'this is my new',
  '\u09a8\u09a4\u09c1\u09a8 \u09a8\u09ae\u09cd\u09ac\u09b0', '\u09a8\u09a4\u09c1\u09a8 \u09a8\u09be\u09ae\u09cd\u09ac\u09be\u09b0',
];

// "send me the otp", "otp ta dao", "\u0995\u09cb\u09a1\u099f\u09be \u09a6\u09bf\u09a8" …
final List<RegExp> _askSecret = [
  // directed at the reader: "send ME the otp", "share YOUR pin"
  RegExp(r"\b(send|share|tell|give|forward|read|type)\b(\s+\w+){0,2}?\s+(me|us|your|ur)\b(\s+\w+){0,2}\s*(otp|pin|code|cvv|password)\b"),
  RegExp(r"\b(otp|pin|code|cvv)\b.{0,30}\b(to this number|to my number|to me)\b"),
  RegExp(r'\b(otp|pin|code|kod|cvv|password)\b\s*(ta|ti|gula|number)?\s*(dao|daw|den|din|diyen|dien|bolo|bolen|bolun|pathao|pathan|send|share|dite hobe|lagbe)\b'),
  RegExp(normBn('(\u0993\u099f\u09bf\u09aa\u09bf|\u0995\u09cb\u09a1|\u09aa\u09bf\u09a8|otp|\u09aa\u09be\u09b8\u0993\u09af\u09bc\u09be\u09b0\u09cd\u09a1)\\s*(\u099f\u09be|\u099f\u09bf|\u09a8\u09ae\u09cd\u09ac\u09b0|\u09a8\u09ae\u09cd\u09ac\u09b0\u099f\u09be)?\\s*(\u09a6\u09be\u0993|\u09a6\u09bf\u09a8|\u09a6\u09c7\u09a8|\u09a6\u09bf\u09ac\u09c7\u09a8|\u09ac\u09b2\u09cb|\u09ac\u09b2\u09c1\u09a8|\u09ac\u09b2\u09c7\u09a8|\u09aa\u09be\u09a0\u09be\u0993|\u09aa\u09be\u09a0\u09be\u09a8|\u09b6\u09c7\u09af\u09bc\u09be\u09b0|\u09b2\u09be\u0997\u09ac\u09c7|\u09a6\u09bf\u09a4\u09c7 \u09b9\u09ac\u09c7)')),
  RegExp(r'\b(otp|code|pin)\b.{0,30}\b(to me|with me|amake|amay)\b'),
  RegExp(normBn('(\u0993\u099f\u09bf\u09aa\u09bf|\u0995\u09cb\u09a1|\u09aa\u09bf\u09a8).{0,20}(\u0986\u09ae\u09be\u0995\u09c7|\u0986\u09ae\u09be\u09af\u09bc)')),
];

// Official domains (and their sub-domains) for brands scammers copy.
const _official = {
  'bkash': ['bkash.com'],
  'nagad': ['nagad.com.bd'],
  'rocket': ['dutchbanglabank.com'],
  'dbbl': ['dutchbanglabank.com'],
  'sonali': ['sonalibank.com.bd'],
  'brac': ['bracbank.com', 'brac.net'],
  'islami': ['islamibankbd.com'],
  'facebook': ['facebook.com', 'fb.com', 'fb.me'],
  'whatsapp': ['whatsapp.com', 'wa.me'],
  'google': ['google.com'],
  'assisto': ['lifeassisto.com'],
  'daraz': ['daraz.com.bd'],
};
// common digit/letter swaps used in fake domains
String _deLeet(String d) => d
    .replaceAll('0', 'o')
    .replaceAll('1', 'l')
    .replaceAll('3', 'e')
    .replaceAll('5', 's')
    .replaceAll('vv', 'w')
    .replaceAll('rn', 'm');

final RegExp _urlRe = RegExp(
    r'((https?://)?([a-z0-9-]+\.)+[a-z]{2,}(/\S*)?)',
    caseSensitive: false);

String _host(String url) {
  var u = url.toLowerCase();
  u = u.replaceFirst(RegExp(r'^https?://'), '');
  final cut = u.indexOf(RegExp(r'[/?#:]'));
  if (cut >= 0) u = u.substring(0, cut);
  return u.replaceFirst(RegExp(r'^www\.'), '');
}

bool _isOfficial(String host, List<String> roots) =>
    roots.any((r) => host == r || host.endsWith('.$r'));

/// The look-alike host in [t] ('' when none): a host that imitates a known
/// brand without being its official domain, or a punycode host.
String lookalikeDomain(String t) {
  for (final m in _urlRe.allMatches(t)) {
    final host = _host(m.group(0)!);
    if (!host.contains('.')) continue;
    if (host.startsWith('xn--') || host.contains('.xn--')) return host;
    final plain = _deLeet(host.replaceAll('-', ''));
    for (final e in _official.entries) {
      if (!plain.contains(e.key)) continue;
      if (_isOfficial(host, e.value)) continue;
      return host;
    }
  }
  return '';
}

/// Check one incoming, already-decrypted message.
/// [newContact] = the chat is new (few/no earlier messages): an urgent money
/// request then warns even without "new number" in the text.
ScamVerdict checkScam(String text, {bool newContact = false}) {
  if (text.trim().length < 6) return ScamVerdict.none;
  final t = _norm(text);
  final reasons = <ScamReason>[];

  final negated = _any(t, _negation);
  if (!negated && _any(t, _secret) && _askSecret.any((r) => r.hasMatch(t))) {
    reasons.add(ScamReason.otpRequest);
  }
  if (_any(t, _mfs) && _any(t, _mfsTrick)) {
    reasons.add(ScamReason.mfsAgent);
  }
  if (_any(t, _prize) && _any(t, _prizeHook)) {
    reasons.add(ScamReason.prize);
  }
  final dom = lookalikeDomain(t);
  if (dom.isNotEmpty) reasons.add(ScamReason.lookalikeLink);
  if (_any(t, _moneyAsk) && _any(t, _urgent) &&
      (newContact || _any(t, _newNumber))) {
    reasons.add(ScamReason.urgentMoney);
  }
  return ScamVerdict(reasons, domain: dom);
}
