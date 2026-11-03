import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';

// aifinal (owner AI order 3 Nov 23:15, PART 1b): safe, tiny markdown for AI
// chat bubbles. Supports **bold**, *italic*, `code`, headings, bullet and
// numbered lists and [links](https://...). NO images (alt text only), NO HTML
// (tags are stripped), never raw asterisks. Links open only http/https and
// only after the user confirms the exact address.

/// One inline run produced by [parseAiInline].
class AiInline {
  final String text;
  final bool bold;
  final bool italic;
  final bool code;
  final String? url; // only http/https; null = plain text
  const AiInline(this.text,
      {this.bold = false, this.italic = false, this.code = false, this.url});
}

/// One block (line-level) produced by [parseAiMarkdown].
class AiBlock {
  /// 'p' paragraph, 'h' heading, 'ul' bullet item, 'ol' numbered item.
  final String kind;
  final String marker; // "1." for ol, "" otherwise
  final List<AiInline> inlines;
  const AiBlock(this.kind, this.inlines, {this.marker = ''});
}

/// Only absolute http/https links are ever opened.
bool aiSafeUrl(String raw) {
  final u = Uri.tryParse(raw.trim());
  if (u == null || !u.hasScheme || u.host.isEmpty) return false;
  return u.scheme == 'http' || u.scheme == 'https';
}

final _html = RegExp(r'<\/?[a-zA-Z][^>]*>');
final _image = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
final _ul = RegExp(r'^\s*[-*+•]\s+(.*)$');
final _ol = RegExp(r'^\s*([0-9০-৯]{1,3})[.)]\s+(.*)$');
final _h = RegExp(r'^\s*#{1,6}\s+(.*)$');
final _rule = RegExp(r'^\s*([-*_]\s*){3,}$');

/// Block-level parse. Never throws; unknown syntax becomes plain text.
List<AiBlock> parseAiMarkdown(String src) {
  final text = src
      .replaceAll('\r\n', '\n')
      .replaceAllMapped(_image, (m) => (m[1] ?? '').trim())
      .replaceAll(_html, '');
  final out = <AiBlock>[];
  final para = <String>[];
  void flush() {
    if (para.isEmpty) return;
    out.add(AiBlock('p', parseAiInline(para.join('\n'))));
    para.clear();
  }

  for (final line in text.split('\n')) {
    if (line.trim().isEmpty || _rule.hasMatch(line)) {
      flush();
      continue;
    }
    final h = _h.firstMatch(line);
    final ul = _ul.firstMatch(line);
    final ol = _ol.firstMatch(line);
    if (h != null) {
      flush();
      out.add(AiBlock('h', parseAiInline(h[1]!)));
    } else if (ul != null) {
      flush();
      out.add(AiBlock('ul', parseAiInline(ul[1]!)));
    } else if (ol != null) {
      flush();
      out.add(AiBlock('ol', parseAiInline(ol[2]!), marker: '${ol[1]}.'));
    } else {
      para.add(line.trim());
    }
  }
  flush();
  return out;
}

final _inline = RegExp(
    r'(\*\*|__)(.+?)\1' // 1,2 bold
    r'|`([^`]+)`' // 3 code
    r'|\[([^\]]+)\]\(([^)\s]+)\)' // 4,5 link
    r'|(?<![\w*])[*_](?![\s*_])(.+?)(?<![\s*_])[*_](?![\w*])' // 6 italic
    r'|(https?://[^\s<>()]+[^\s<>().,!?;:])'); // 7 bare url

/// Inline parse. Any leftover marker asterisks are removed.
List<AiInline> parseAiInline(String s) {
  final runs = <AiInline>[];
  var last = 0;
  String plain(String x) => x.replaceAll('**', '').replaceAll('__', '');
  for (final m in _inline.allMatches(s)) {
    if (m.start > last) runs.add(AiInline(plain(s.substring(last, m.start))));
    if (m[2] != null) {
      for (final r in parseAiInline(m[2]!)) {
        runs.add(AiInline(r.text,
            bold: true, italic: r.italic, code: r.code, url: r.url));
      }
    } else if (m[3] != null) {
      runs.add(AiInline(m[3]!, code: true));
    } else if (m[4] != null) {
      final url = m[5]!;
      runs.add(AiInline(plain(m[4]!), url: aiSafeUrl(url) ? url : null));
    } else if (m[6] != null) {
      runs.add(AiInline(plain(m[6]!), italic: true));
    } else if (m[7] != null) {
      runs.add(AiInline(m[7]!, url: aiSafeUrl(m[7]!) ? m[7] : null));
    }
    last = m.end;
  }
  if (last < s.length) runs.add(AiInline(plain(s.substring(last))));
  // A lone "* " left at a line start after the parse is a stray marker.
  return [
    for (final r in runs)
      if (r.text.isNotEmpty)
        r.url == null && !r.code
            ? AiInline(r.text.replaceAll(RegExp(r'(^|\n)\*\s'), r'$1'),
                bold: r.bold, italic: r.italic)
            : r
  ];
}

/// Ask before leaving the app. Returns true when the user tapped Open.
Future<bool> confirmOpenAiLink(BuildContext context, String url) async {
  final t = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(t.aimdOpenLinkTitle),
      content: SelectableText(url),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(c, true), child: Text(t.aimdOpenLink)),
      ],
    ),
  );
  return ok == true;
}

/// Renders [text] as safe markdown in the given [color].
class AiMarkdown extends StatefulWidget {
  final String text;
  final Color color;
  final Color linkColor;
  const AiMarkdown(
      {super.key,
      required this.text,
      required this.color,
      required this.linkColor});

  @override
  State<AiMarkdown> createState() => _AiMarkdownState();
}

class _AiMarkdownState extends State<AiMarkdown> {
  final _taps = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _taps) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _open(String url) async {
    if (!aiSafeUrl(url)) return;
    if (!await confirmOpenAiLink(context, url)) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  TextSpan _span(AiInline r, TextStyle base) {
    var st = base;
    if (r.bold) st = st.copyWith(fontWeight: FontWeight.w700);
    if (r.italic) st = st.copyWith(fontStyle: FontStyle.italic);
    if (r.code) st = st.copyWith(fontFamily: 'monospace');
    final url = r.url;
    if (url == null) return TextSpan(text: r.text, style: st);
    final tap = TapGestureRecognizer()..onTap = () => _open(url);
    _taps.add(tap);
    return TextSpan(
        text: r.text,
        style: st.copyWith(
            color: widget.linkColor, decoration: TextDecoration.underline),
        recognizer: tap);
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _taps) {
      r.dispose();
    }
    _taps.clear();
    final base = TextStyle(color: widget.color, height: 1.45);
    final blocks = parseAiMarkdown(widget.text);
    final kids = <Widget>[];
    for (final b in blocks) {
      final style = b.kind == 'h'
          ? base.copyWith(fontWeight: FontWeight.w700, fontSize: 16)
          : base;
      final body = Text.rich(
          TextSpan(children: [for (final r in b.inlines) _span(r, style)]));
      if (b.kind == 'ul' || b.kind == 'ol') {
        kids.add(Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 24,
                child: Text(b.kind == 'ul' ? '•' : b.marker, style: base)),
            Expanded(child: body),
          ]),
        ));
      } else {
        kids.add(Padding(
            padding: EdgeInsets.only(top: kids.isEmpty ? 0 : 6),
            child: body));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids);
  }
}
