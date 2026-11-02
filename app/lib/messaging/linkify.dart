/// circlea — find links in chat text (pure, no Flutter).
///
/// Benchmark: WhatsApp / Telegram — every http(s) link, `www.` link and a
/// bare `facebook.com/reel/…` style link is tappable; trailing punctuation
/// (`.` `,` `!` `?` `)` `।` quotes) is not part of the link; Bangla text
/// glued to a link ends it; emails and phone numbers are left alone.
library;

class TextPiece {
  final String text;

  /// The URL to open (with a scheme) when this piece is a link, else null.
  final String? url;
  const TextPiece(this.text, [this.url]);
  bool get isLink => url != null;
  @override
  String toString() => isLink ? '[$text→$url]' : text;
}

// Characters allowed inside a URL (ASCII only — Bangla ends the link).
const _urlChars = r"[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]";
// Top-level domains accepted for a BARE domain (no scheme, no www.) — short
// allow-lists so "photo.jpg", "v2.0" or "Mr.Rahim" never become links.
// Long TLDs may stand alone ("daraz.com.bd"); two-letter ones need a path
// ("youtu.be/abc", "fb.me/x", "wa.me/880…").
const _bareLong =
    'com|net|org|bd|info|edu|gov|xyz|link|site|online|shop|watch|app|dev';
const _bareShort = 'io|me|be|ly|co|tv|gl|in|uk|us|gg';
const _label = '[A-Za-z0-9](?:[A-Za-z0-9\\-]{0,62}[A-Za-z0-9])?';
const _host = '$_label(?:\\.$_label)*';
// what may follow a bare domain without a path: space, punctuation, Bangla
const _after = '(?=\$|[\\s,.!?;:)\\]}"\'।]|[^\\x00-\\x7F])';

final RegExp _linkRe = RegExp(
  // 1) scheme links  2) www. links  3) bare long-TLD domain  4) bare
  // short-TLD domain WITH a path
  '(?:https?://$_urlChars+)'
  '|(?:www\\.[A-Za-z0-9\\-]+(?:\\.[A-Za-z0-9\\-]+)+$_urlChars*)'
  '|(?:$_host\\.(?:$_bareLong)(?:\\.bd)?(?:[/?#]$_urlChars*|$_after))'
  '|(?:$_host\\.(?:$_bareShort)/$_urlChars*)',
  caseSensitive: false,
);

const _trailing = '.,;:!?\'"।…';

/// Trim punctuation that belongs to the sentence, keeping balanced brackets
/// (Wikipedia-style "…/Dhaka_(city)" keeps its ")").
String _trimTail(String s) {
  var out = s;
  while (out.isNotEmpty) {
    final last = out[out.length - 1];
    if (_trailing.contains(last)) {
      out = out.substring(0, out.length - 1);
      continue;
    }
    if (last == ')' || last == ']' || last == '}') {
      final open = last == ')' ? '(' : (last == ']' ? '[' : '{');
      final opens = open.allMatches(out).length;
      final closes = last.allMatches(out).length;
      if (closes > opens) {
        out = out.substring(0, out.length - 1);
        continue;
      }
    }
    break;
  }
  return out;
}

bool _wordCharBefore(String text, int i) {
  if (i <= 0) return false;
  final c = text.codeUnitAt(i - 1);
  // letters, digits, '@' (email), '.', '_' , '-' glued before = not a link start
  return (c >= 48 && c <= 57) ||
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      c == 64 ||
      c == 95 ||
      c == 45 ||
      c == 46;
}

/// Split [text] into plain + link pieces. Pure; safe on any input.
List<TextPiece> linkify(String text) {
  if (text.isEmpty) return const [];
  final out = <TextPiece>[];
  var pos = 0;
  for (final m in _linkRe.allMatches(text)) {
    if (m.start < pos) continue;
    var raw = m.group(0)!;
    final hasScheme = raw.toLowerCase().startsWith('http');
    if (!hasScheme && _wordCharBefore(text, m.start)) continue;
    // "name@site.com" — the bare domain of an email is never a link
    if (!hasScheme && m.end < text.length && text[m.end] == '@') continue;
    raw = _trimTail(raw);
    if (raw.isEmpty) continue;
    if (hasScheme && raw.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '').isEmpty) {
      continue;
    }
    // an email address: "x@y.com" matched from the domain part is skipped
    // above; a bare domain that is the tail of "user@host" is too.
    if (!hasScheme && raw.contains('@')) continue;
    if (m.start > pos) out.add(TextPiece(text.substring(pos, m.start)));
    final url = hasScheme ? raw : 'https://$raw';
    out.add(TextPiece(raw, url));
    pos = m.start + raw.length;
  }
  if (pos < text.length) out.add(TextPiece(text.substring(pos)));
  return out;
}

/// The first link in [text] (with a scheme), or null.
String? firstLink(String text) {
  for (final p in linkify(text)) {
    if (p.isLink) return p.url;
  }
  return null;
}

/// Every link in [text].
List<String> allLinks(String text) =>
    [for (final p in linkify(text)) if (p.isLink) p.url!];
