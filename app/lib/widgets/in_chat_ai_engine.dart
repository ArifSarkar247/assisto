/// in_chat_ai_engine.dart — on-device Dart mirror of
/// `backend/core/logic/in_chat_ai.py` (the IN-CHAT AI helper, #97, SPEC v2.1
/// §21, ADVANCED).
///
/// A DETERMINISTIC TEMPLATE engine: identical inputs always give identical
/// output, so the offline preview matches the Python source of truth. It is
/// PURE — no network, no AI, no key, no clock.
///
/// The "AI helps you in chat" promise is served by this MOCK and is clearly
/// labelled "AI-generated — review" (see [InChatAiResult.marker], rendered by
/// the UI). A real provider is key-gated and routed server-side via
/// `core.ai.generate`; see up_inchatai_integration.md. `translate` honestly
/// reports it NEEDS the key for a real render and never fabricates a
/// translation. Nothing here sends a message — inserting/copying is a manual
/// user action.
///
/// ZERO Bangla literals live in this file: tone skeletons are neutral English
/// seeds (the real-AI path replaces them); the only Bangla handling is a range
/// check on the Bengali Unicode block to GUESS translate direction.
library;

/// The three bounded actions. The UI localises these keys.
const List<String> kInChatAiActions = ['summarise', 'translate', 'tone'];

/// Tone presets for adjust-tone. Neutral English seed labels; UI localises.
const List<String> kInChatAiTones = [
  'polite',
  'shorter',
  'warmer',
  'firmer',
  'formal',
];

/// Translate direction hints. 'auto' guesses from the script.
const List<String> kInChatAiDirections = ['auto', 'bn2en', 'en2bn'];

/// Most recent messages a summary looks at, at most (mirrors MAX_THREAD).
const int kInChatAiMaxThread = 12;

/// The honest marker key every result carries (mirrors MARKER_KEY).
const String kInChatAiMarkerKey = 'ai_review';

/// One digest bullet: who said it ('you' | 'them') + a trimmed lead.
class InChatAiBullet {
  final String who;
  final String text;
  const InChatAiBullet(this.who, this.text);
}

/// A deterministic MOCK result. [aiRequired] is true only for translate (a real
/// render is key-gated and never fabricated). [mock] is always true here.
class InChatAiResult {
  final String action; // summarise | translate | tone
  final List<String> problems; // validate keys; non-empty ⇒ invalid inputs
  final bool aiRequired;
  final bool mock;
  final String marker; // == kInChatAiMarkerKey

  // summarise
  final int count;
  final List<InChatAiBullet> bullets;

  // translate
  final String direction; // bn2en | en2bn
  final String source;
  final String translated; // always '' in the mock — honest, never fabricated

  // tone
  final String tone;
  final String result; // rewritten text

  const InChatAiResult({
    required this.action,
    this.problems = const [],
    this.aiRequired = false,
    this.mock = true,
    this.marker = kInChatAiMarkerKey,
    this.count = 0,
    this.bullets = const [],
    this.direction = '',
    this.source = '',
    this.translated = '',
    this.tone = '',
    this.result = '',
  });
}

String _clean(String? text) =>
    (text ?? '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

/// True if any char is in the Bengali Unicode block (U+0980–U+09FF). Used ONLY
/// to guess translate direction — never to emit Bangla.
bool _hasBangla(String text) {
  for (final ch in text.runes) {
    if (ch >= 0x0980 && ch <= 0x09FF) return true;
  }
  return false;
}

List<String> _sentences(String text) => text
    .split(RegExp(r'[.!?।\n]+')) // । = Bangla danda ।
    .map((p) => p.trim())
    .where((p) => p.isNotEmpty)
    .toList();

String _firstWords(String text, int n) =>
    _clean(text).split(' ').take(n).where((w) => w.isNotEmpty).join(' ');

/// Return problem keys (empty ⇒ valid). The UI localises these.
List<String> validateInChatAi(
  String action, {
  List<Map<String, dynamic>>? messages,
  String text = '',
  String tone = 'polite',
  String direction = 'auto',
}) {
  final problems = <String>[];
  if (!kInChatAiActions.contains(action)) {
    return ['bad_action'];
  }
  if (action == 'summarise') {
    if (messages == null || messages.isEmpty) problems.add('empty_thread');
  } else {
    if (_clean(text).isEmpty) problems.add('empty_text');
  }
  if (action == 'tone' && !kInChatAiTones.contains(tone)) {
    problems.add('bad_tone');
  }
  if (action == 'translate' && !kInChatAiDirections.contains(direction)) {
    problems.add('bad_direction');
  }
  return problems;
}

/// MOCK: a short bullet digest of recent messages (newest last).
InChatAiResult summariseThread(List<Map<String, dynamic>> messages) {
  final msgs = messages
      .where((m) => _clean('${m['text'] ?? ''}').isNotEmpty)
      .toList();
  final capped =
      msgs.length <= kInChatAiMaxThread ? msgs : msgs.sublist(msgs.length - kInChatAiMaxThread);
  final total = capped.length;
  final recent = capped.length <= 3 ? capped : capped.sublist(capped.length - 3);
  final bullets = [
    for (final m in recent)
      InChatAiBullet(
        m['mine'] == true ? 'you' : 'them',
        _firstWords('${m['text'] ?? ''}', 14),
      ),
  ];
  return InChatAiResult(
    action: 'summarise',
    count: total,
    bullets: bullets,
    aiRequired: false,
    problems: validateInChatAi('summarise', messages: messages),
  );
}

/// MOCK: a translate PLAN (direction + source), NOT a fabricated translation.
/// A real render is key-gated; [InChatAiResult.aiRequired] is true.
InChatAiResult translateMessage(String text, {String direction = 'auto'}) {
  final src = _clean(text);
  var dir = direction;
  if (dir == 'auto') dir = _hasBangla(src) ? 'bn2en' : 'en2bn';
  return InChatAiResult(
    action: 'translate',
    direction: dir,
    source: src,
    translated: '', // honest: never fabricated
    aiRequired: true,
    problems: validateInChatAi('translate', text: src, direction: dir),
  );
}

// Deterministic tone skeletons (neutral English seeds; real-AI path replaces).
const Map<String, String> _kToneWrap = {
  'polite': 'Could you please consider this: {text}. Thank you.',
  'shorter': '{short}',
  'warmer': 'Hope you\'re doing well! {text} \u{1F642}',
  'firmer': 'To be clear: {text}. Please confirm.',
  'formal': 'Dear recipient, I would like to note the following: {text}. Regards.',
};

/// MOCK: rewrite one message in a chosen tone, deterministically.
InChatAiResult adjustTone(String text, {String tone = 'polite'}) {
  final src = _clean(text);
  final sents = _sentences(src);
  final shortLead = sents.isNotEmpty ? sents.first : _firstWords(src, 10);
  final wrap = _kToneWrap[tone] ?? _kToneWrap['polite']!;
  final result = wrap.replaceAll('{text}', src).replaceAll('{short}', shortLead);
  return InChatAiResult(
    action: 'tone',
    tone: tone,
    source: src,
    result: result,
    aiRequired: false,
    problems: validateInChatAi('tone', text: src, tone: tone),
  );
}

/// Single entry mirroring the request shape the real-AI route takes.
InChatAiResult runInChatAi(
  String action, {
  List<Map<String, dynamic>>? messages,
  String text = '',
  String tone = 'polite',
  String direction = 'auto',
}) {
  final problems = validateInChatAi(action,
      messages: messages, text: text, tone: tone, direction: direction);
  if (problems.isNotEmpty) {
    return InChatAiResult(
      action: action,
      problems: problems,
      aiRequired: action == 'translate',
    );
  }
  if (action == 'summarise') return summariseThread(messages!);
  if (action == 'translate') return translateMessage(text, direction: direction);
  return adjustTone(text, tone: tone);
}
