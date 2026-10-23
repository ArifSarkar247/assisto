// P3 — parse "@Assisto …" typed in a My Circle chat into an action.
//
// Runs ON THE PHONE (no network). bn + Banglish + en. Nothing typed after
// "@Assisto" is ever sent to the other chat members: the composer intercepts
// it and opens the Assisto sheet with the parsed action pre-filled.
//
// Language gate: Bangla keywords are \u escapes (no literal Bangla in lib/).
import 'assisto_card.dart' show normBn, poishaOf;

enum AssistoAction { menu, summarize, remind, split, list, translate, ask }

class AssistoIntent {
  final AssistoAction action;
  final String rest; // the text after the mention (and after a list colon)
  final bool everyone; // reminder for everyone in the chat
  final int poisha; // split amount
  final List<String> items; // shopping list items
  final String target; // translate target 'bn' | 'en'
  const AssistoIntent(this.action,
      {this.rest = '',
      this.everyone = false,
      this.poisha = 0,
      this.items = const [],
      this.target = ''});
}

// "@assisto", "@Assisto", Bangla "@\u0985\u09cd\u09af\u09be\u09b8\u09bf\u09b8\u09cd\u099f\u09cb" / "@\u098f\u09b8\u09bf\u09b8\u09cd\u099f\u09cb" / "@\u0986\u09b8\u09bf\u09b8\u09cd\u099f\u09cb".
final RegExp _mention = RegExp(
    '^\\s*@\\s*(assisto|\u0985\u09cd\u09af\u09be\u09b8\u09bf\u09b8\u09cd\u099f\u09cb|\u098f\u09b8\u09bf\u09b8\u09cd\u099f\u09cb|\u0986\u09b8\u09bf\u09b8\u09cd\u099f\u09cb)(?![a-z0-9])[\\s,:]*',
    caseSensitive: false);

/// True when the draft starts with an @Assisto mention.
bool hasAssistoMention(String text) => _mention.hasMatch(normBn(text));

/// True while the user is typing the handle ("@", "@as", "@Assi").
bool isTypingMention(String text) {
  final t = text.trimLeft().toLowerCase();
  if (!t.startsWith('@') || t.contains(' ')) return false;
  final h = t.substring(1);
  return h.isNotEmpty && 'assisto'.startsWith(h);
}

bool _hasAny(String low, List<String> words) =>
    words.any((w) => low.contains(normBn(w)));

const _summ = [
  'summar', 'summery', 'unread', 'what did i miss', 'catch me up', 'recap',
  'ki holo', 'ki miss', 'sarsongkhep', 'songkhep', 'shongkhep',
  '\u09b8\u09be\u09b0\u09be\u0982\u09b6', // \u09b8\u09be\u09b0\u09be\u0982\u09b6
  '\u09b8\u0982\u0995\u09cd\u09b7\u09c7\u09aa', // \u09b8\u0982\u0995\u09cd\u09b7\u09c7\u09aa
  '\u0995\u09c0 \u09ae\u09bf\u09b8', // \u0995\u09c0 \u09ae\u09bf\u09b8
  '\u09a8\u09be \u09aa\u09dc\u09be', // \u09a8\u09be \u09aa\u09a1\u09bc\u09be
];
const _remind = [
  'remind', 'reminder', 'mone koriye', 'mone koraye', 'mone koriyo',
  '\u09ae\u09a8\u09c7 \u0995\u09b0\u09bf\u09df\u09c7', // \u09ae\u09a8\u09c7 \u0995\u09b0\u09bf\u09af\u09bc\u09c7
  '\u09ae\u09a8\u09c7 \u0995\u09b0\u09be\u09ac\u09c7', // \u09ae\u09a8\u09c7 \u0995\u09b0\u09be\u09ac\u09c7
  '\u09b0\u09bf\u09ae\u09be\u0987\u09a8\u09cd\u09a1', // \u09b0\u09bf\u09ae\u09be\u0987\u09a8\u09cd\u09a1
];
const _everyone = [
  'everyone', 'everybody', 'all of us', 'us all', 'for all', 'sobai',
  'shobai', 'sobaike', 'shobaike', 'sokolke',
  '\u09b8\u09ac\u09be\u0987', // \u09b8\u09ac\u09be\u0987
  '\u09b8\u0995\u09b2\u0995\u09c7', // \u09b8\u0995\u09b2\u0995\u09c7
];
const _split = [
  'split', 'bhag kor', 'bhaag', 'bill vag', 'bill bhag', 'vag kor',
  '\u09ad\u09be\u0997', // \u09ad\u09be\u0997
];
const _list = [
  'shopping', 'grocery', 'list', 'bazar', 'bajar', 'kinte hobe',
  '\u09ac\u09be\u099c\u09be\u09b0', // \u09ac\u09be\u099c\u09be\u09b0
  '\u09b2\u09bf\u09b8\u09cd\u099f', // \u09b2\u09bf\u09b8\u09cd\u099f
  '\u09a4\u09be\u09b2\u09bf\u0995\u09be', // \u09a4\u09be\u09b2\u09bf\u0995\u09be
];
const _translate = [
  'translate', 'translation', 'anubad', 'onubad', 'in english', 'in bangla',
  'in bengali', 'to english', 'to bangla',
  '\u0985\u09a8\u09c1\u09ac\u09be\u09a6', // \u0985\u09a8\u09c1\u09ac\u09be\u09a6
];
const _toBn = [
  'bangla', 'bengali', 'bn',
  '\u09ac\u09be\u0982\u09b2\u09be', // \u09ac\u09be\u0982\u09b2\u09be
];
const _toEn = [
  'english', 'ingreji', 'engreji',
  '\u0987\u0982\u09b0\u09c7\u099c\u09bf', // \u0987\u0982\u09b0\u09c7\u099c\u09bf
];

/// The action the user asked for, or null when the text has no @Assisto
/// mention at the start (an ordinary message).
AssistoIntent? parseAssisto(String text) {
  text = normBn(text);
  final m = _mention.firstMatch(text);
  if (m == null) return null;
  final rest = text.substring(m.end).trim();
  if (rest.isEmpty) return const AssistoIntent(AssistoAction.menu);
  final low = rest.toLowerCase();

  if (_hasAny(low, _summ)) {
    return AssistoIntent(AssistoAction.summarize, rest: rest);
  }
  if (_hasAny(low, _remind)) {
    return AssistoIntent(AssistoAction.remind,
        rest: _stripWords(rest, [..._remind, ..._everyone, 'me', 'to', 'please']),
        everyone: _hasAny(low, _everyone));
  }
  if (_hasAny(low, _split)) {
    return AssistoIntent(AssistoAction.split,
        rest: rest, poisha: poishaOf(rest));
  }
  if (_hasAny(low, _translate)) {
    final bn = _hasAny(low, _toBn);
    final en = _hasAny(low, _toEn);
    final target = bn && !en ? 'bn' : (en && !bn ? 'en' : '');
    return AssistoIntent(AssistoAction.translate,
        rest: _afterColon(rest), target: target);
  }
  if (_hasAny(low, _list)) {
    return AssistoIntent(AssistoAction.list,
        rest: rest, items: splitItems(_afterColon(rest, dropIfNone: true)));
  }
  return AssistoIntent(AssistoAction.ask, rest: rest);
}

String _afterColon(String s, {bool dropIfNone = false}) {
  final i = s.indexOf(':');
  if (i >= 0) return s.substring(i + 1).trim();
  return dropIfNone ? '' : s;
}

String _stripWords(String s, List<String> words) {
  var out = ' $s ';
  for (final w in words) {
    out = out.replaceAll(RegExp('(?<![a-z])${RegExp.escape(w)}(?![a-z])', caseSensitive: false), ' ');
  }
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// "rice, oil and eggs" / one per line / Bangla "\u0986\u09b0" -> ['rice','oil','eggs'].
List<String> splitItems(String s) {
  if (s.trim().isEmpty) return const [];
  return s
      .split(RegExp(',|،|;|\\n| and | \u0986\u09b0 | ar | o |।'))
      .map((x) => x.trim())
      .where((x) => x.isNotEmpty)
      .take(50)
      .toList();
}
