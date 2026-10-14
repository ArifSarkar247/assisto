import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// quick_tools_engine.dart — on-device Dart mirror of
/// `backend/core/logic/quick_tools.py` (QUICK TOOLS toolbox, #17, §6, §21).
///
/// A DETERMINISTIC engine: identical inputs always give identical output, so the
/// offline result matches the Python source of truth. It is PURE — no network,
/// no AI, no key. Every result is an honest MOCK ("AI-generated — review"); a
/// real provider is key-gated server-side (`core.ai.generate`, Integrations
/// `anthropic`). `translate` NEVER fabricates a sentence translation — it renders
/// only known common phrases offline and otherwise honestly needs the key.
///
/// Nothing here sends/posts anything. Optional saved results live locally in
/// SharedPreferences (key `quick_tools_v1`); a cross-device copy is a documented
/// generic-collection seam (`quicktools/saved`) — see up_quickbrief_integration.md.

const List<String> kQuickActions = [
  'summarise',
  'fix_grammar',
  'translate',
  'change_tone',
  'make_shareable',
];
const List<String> kQuickTones = [
  'polite',
  'shorter',
  'warmer',
  'firmer',
  'formal'
];
const List<String> kQuickDirections = ['auto', 'bn2en', 'en2bn'];

const int kMaxSummary = 3;
const int kShareLimit = 500;
const String kQuickMarker = 'ai_review';

// Key-hint words that make a sentence more likely to be a "key" point (mirrors
// quick_tools.py::_KEY_HINTS). Neutral English seeds — zero Bangla.
const List<String> _keyHints = [
  'important', 'must', 'need', 'because', 'result', 'deadline',
  'please', 'note', 'remember', 'total', 'decision', 'summary'
];

// Deterministic tone skeletons (mirror _TONE_WRAP). Zero Bangla.
const Map<String, String> _toneWrap = {
  'polite': 'Could you please consider this: {text} Thank you.',
  'shorter': '{short}',
  'warmer': "Hope you're doing well! {text} Take care.",
  'firmer': 'To be clear: {text} Please confirm.',
  'formal':
      'Dear recipient, I would like to note the following: {text} Regards.',
};

// The common-phrase keys the mock can render offline (mirror of the keys of
// `quick_tools.py::_PHRASES`). Zero Bangla literals live in this .dart file: the
// actual bn renderings are supplied at call time by the screen from the ARB
// (keys `qtPhrase_<key>`), so the mirror still matches the Python source of
// truth while staying strictly Bangla-free. Everything NOT in this set honestly
// needs the key-gated AI route.
const List<String> kQuickPhraseKeys = [
  'hello',
  'thank you',
  'thanks',
  'good morning',
  'good night',
  'how are you',
  'yes',
  'no',
  'sorry',
  'welcome',
];

String _clean(String? text) =>
    (text ?? '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

/// True if any character is in the Bengali Unicode block (U+0980–U+09FF).
/// Codepoint comparison (no Bangla literal in this file).
bool _hasBangla(String text) {
  for (final c in text.runes) {
    if (c >= 0x0980 && c <= 0x09FF) return true;
  }
  return false;
}

/// Split into sentence fragments KEEPING the terminator (mirror _sentences).
List<String> _sentences(String text) {
  final out = <String>[];
  final buf = StringBuffer();
  for (final ch in text.split('')) {
    buf.write(ch);
    if ('.!?।\n'.contains(ch)) {
      final s = buf.toString().trim();
      if (s.isNotEmpty) out.add(s);
      buf.clear();
    }
  }
  final tail = buf.toString().trim();
  if (tail.isNotEmpty) out.add(tail);
  return out;
}

/// Problem keys (empty ⇒ valid). The UI localises these.
List<String> validateQuick(String action, String text,
    {String tone = 'polite', String direction = 'auto'}) {
  final out = <String>[];
  if (!kQuickActions.contains(action)) {
    out.add('bad_action');
    return out;
  }
  if (_clean(text).isEmpty) out.add('empty_text');
  if (action == 'change_tone' && !kQuickTones.contains(tone)) out.add('bad_tone');
  if (action == 'translate' && !kQuickDirections.contains(direction)) {
    out.add('bad_direction');
  }
  return out;
}

/// The result of one quick-tool transform. `aiRequired` is true only for an
/// unknown translate input (honest: a real translation needs the key).
class QuickResult {
  final String action;
  final String source;
  final String result;
  final bool aiRequired;
  final bool phraseHit; // translate only
  final String direction; // translate only
  final List<String> changes; // fix_grammar only
  const QuickResult({
    required this.action,
    required this.source,
    required this.result,
    this.aiRequired = false,
    this.phraseHit = false,
    this.direction = '',
    this.changes = const [],
  });
  bool get mock => true;
  String get marker => kQuickMarker;
}

int _score(String sentence, int index) {
  final lower = sentence.toLowerCase();
  final n = lower.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  var s = 0;
  if (index == 0) {
    s += 5;
  } else if (index == 1) {
    s += 2;
  }
  for (final h in _keyHints) {
    if (lower.contains(h)) s += 2;
  }
  if (n >= 6 && n <= 30) {
    s += 2;
  } else if (n < 4) {
    s -= 1;
  }
  return s;
}

QuickResult summariseQuick(String text) {
  text = _clean(text);
  final sents = _sentences(text);
  List<String> kept;
  if (sents.length <= 1) {
    kept = sents;
  } else {
    final scored = <List<dynamic>>[];
    for (var i = 0; i < sents.length; i++) {
      scored.add([_score(sents[i], i), i, sents[i]]);
    }
    scored.sort((a, b) {
      final byScore = (b[0] as int).compareTo(a[0] as int);
      return byScore != 0 ? byScore : (a[1] as int).compareTo(b[1] as int);
    });
    final top = scored.take(kMaxSummary).toList()
      ..sort((a, b) => (a[1] as int).compareTo(b[1] as int));
    kept = top.map((e) => e[2] as String).toList();
  }
  return QuickResult(
      action: 'summarise', source: text, result: kept.join(' '));
}

QuickResult fixGrammarQuick(String text) {
  final original = _clean(text);
  var s = original;
  final changes = <String>[];

  var s2 = s.replaceAllMapped(RegExp(r'\s+([.,!?;:।])'), (m) => m.group(1)!);
  if (s2 != s) changes.add('space_before_punct');
  s = s2;

  s2 = s.replaceAllMapped(RegExp(r'([.!?।])\1{1,}'), (m) => m.group(1)!);
  if (s2 != s) changes.add('repeat_punct');
  s = s2;

  s2 = s.replaceAllMapped(
      RegExp(r'([.,!?;:।])(?=[^\s\d])'), (m) => '${m.group(1)} ');
  s2 = _clean(s2);
  if (s2 != s) changes.add('space_after_punct');
  s = s2;

  s2 = s.replaceAllMapped(RegExp(r"(?<![\w'])i(?![\w'])"), (_) => 'I');
  if (s2 != s) changes.add('capital_i');
  s = s2;

  String cap(String sent) {
    for (var i = 0; i < sent.length; i++) {
      final ch = sent[i];
      if (RegExp('[A-Za-z]').hasMatch(ch)) {
        if (RegExp('[a-z]').hasMatch(ch)) {
          return sent.substring(0, i) + ch.toUpperCase() + sent.substring(i + 1);
        }
        return sent;
      }
    }
    return sent;
  }

  final sents = _sentences(s);
  final capped = sents.isNotEmpty ? sents.map(cap).join(' ') : s;
  if (capped != s) changes.add('capital_sentence');
  s = capped;

  return QuickResult(
      action: 'fix_grammar',
      source: original,
      result: s.trim(),
      changes: changes);
}

/// `phraseTable` maps a known English phrase key → its bn rendering, supplied by
/// the screen from the ARB (keeps this file Bangla-free). When omitted, en→bn
/// phrase hits are unavailable offline and honestly need the key; bn→en hits use
/// the reverse of whatever table is passed. Mirrors `quick_tools.py::translate`.
QuickResult translateQuick(String text,
    {String direction = 'auto', Map<String, String> phraseTable = const {}}) {
  text = _clean(text);
  if (direction == 'auto') direction = _hasBangla(text) ? 'bn2en' : 'en2bn';
  String? hit;
  if (direction == 'en2bn') {
    final key = text.toLowerCase();
    if (kQuickPhraseKeys.contains(key)) hit = phraseTable[key];
  } else {
    // reverse lookup bn -> en (first matching en key)
    for (final e in phraseTable.entries) {
      if (kQuickPhraseKeys.contains(e.key) && e.value == text) {
        hit = e.key;
        break;
      }
    }
  }
  return QuickResult(
    action: 'translate',
    source: text,
    result: hit ?? '',
    direction: direction,
    phraseHit: hit != null,
    aiRequired: hit == null,
  );
}

QuickResult changeToneQuick(String text, {String tone = 'polite'}) {
  text = _clean(text);
  final sents = _sentences(text);
  final shortLead = sents.isNotEmpty
      ? sents.first
      : text.split(RegExp(r'\s+')).take(12).join(' ');
  final wrap = _toneWrap[tone] ?? _toneWrap['polite']!;
  final result =
      _clean(wrap.replaceAll('{text}', text).replaceAll('{short}', shortLead));
  return QuickResult(action: 'change_tone', source: text, result: result);
}

QuickResult makeShareableQuick(String text) {
  text = _clean(text);
  var body = text;
  if (body.length > kShareLimit) {
    var cut = body.substring(0, kShareLimit);
    final sp = cut.lastIndexOf(' ');
    if (sp > kShareLimit ~/ 2) cut = cut.substring(0, sp);
    body = '${cut.trimRight()}…';
  }
  return QuickResult(action: 'make_shareable', source: text, result: body);
}

/// Single dispatch mirroring `quick_tools.py::run`.
QuickResult runQuick(String action, String text,
    {String tone = 'polite',
    String direction = 'auto',
    Map<String, String> phraseTable = const {}}) {
  switch (action) {
    case 'summarise':
      return summariseQuick(text);
    case 'fix_grammar':
      return fixGrammarQuick(text);
    case 'translate':
      return translateQuick(text,
          direction: direction, phraseTable: phraseTable);
    case 'change_tone':
      return changeToneQuick(text, tone: tone);
    default:
      return makeShareableQuick(text);
  }
}

/// A saved quick-tool result (optional local history, newest first, capped 30).
class SavedQuick {
  final String id;
  final String action;
  final String source;
  final String result;
  final String savedAt; // ISO
  const SavedQuick({
    required this.id,
    required this.action,
    required this.source,
    required this.result,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'action': action,
        'source': source,
        'result': result,
        'savedAt': savedAt,
      };

  factory SavedQuick.fromJson(Map<String, dynamic> j) => SavedQuick(
        id: (j['id'] ?? '').toString(),
        action: (j['action'] ?? 'summarise').toString(),
        source: (j['source'] ?? '').toString(),
        result: (j['result'] ?? '').toString(),
        savedAt: (j['savedAt'] ?? '').toString(),
      );
}

/// Local persistence for optional saved results.
class QuickStore {
  static const _key = 'quick_tools_v1';

  static Future<List<SavedQuick>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => SavedQuick.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> save(List<SavedQuick> items) async {
    final p = await SharedPreferences.getInstance();
    final capped = items.take(30).toList();
    await p.setString(_key, jsonEncode(capped.map((d) => d.toJson()).toList()));
  }
}
