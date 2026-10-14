import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// social_engine.dart — on-device Dart mirror of `backend/core/logic/social.py`
/// (the SOCIAL-MEDIA POST & CAPTION composer, #135, SPEC v2.1 §21).
///
/// It is a DETERMINISTIC TEMPLATE GENERATOR: identical inputs always give an
/// identical draft, so the offline preview matches the Python source of truth
/// semantics-for-semantics. It is PURE — no network, no AI, no key. The honest
/// "AI drafts it" promise is served by this mock and is clearly labelled
/// ("AI-generated — review before posting"); a real provider is key-gated and
/// routed server-side via `core.ai.generate` (out of scope here).
///
/// Nothing here posts anything. Saved drafts + a small history live locally in
/// SharedPreferences (key `social_drafts_v1`).

/// The four supported platforms and their public character ceilings. Kept in
/// lockstep with `social.py::PLATFORMS`.
class SocialPlatform {
  final String id; // facebook | instagram | linkedin | whatsapp
  final int limit; // hard character cap the UI counts against
  final int soft; // comfortable target length used to size the draft
  final int hashtags; // suggested-hashtag cap
  final bool emoji; // whether emoji chips are offered
  const SocialPlatform(this.id, this.limit, this.soft, this.hashtags, this.emoji);
}

const Map<String, SocialPlatform> kPlatforms = {
  'facebook': SocialPlatform('facebook', 63206, 480, 3, true),
  'instagram': SocialPlatform('instagram', 2200, 300, 8, true),
  'linkedin': SocialPlatform('linkedin', 3000, 700, 5, false),
  'whatsapp': SocialPlatform('whatsapp', 700, 180, 2, true),
};

const List<String> kPlatformOrder = [
  'facebook',
  'instagram',
  'linkedin',
  'whatsapp'
];
const List<String> kTones = [
  'friendly',
  'professional',
  'funny',
  'inspirational',
  'promotional'
];
const List<String> kLengths = ['short', 'medium', 'long'];

const Map<String, double> _lengthScale = {
  'short': 0.45,
  'medium': 1.0,
  'long': 1.6
};

const Map<String, List<String>> _toneEmoji = {
  'friendly': ['😊', '👍', '🙌', '✨'],
  'professional': ['📊', '✅', '💼', '🔹'],
  'funny': ['😂', '😄', '🎉', '🙃'],
  'inspirational': ['🌟', '🚀', '💪', '🙏'],
  'promotional': ['🔥', '🎁', '⏰', '🛒'],
};

const Map<String, String> _toneOpener = {
  'friendly': 'Hey everyone! A quick word about {topic}.',
  'professional': 'Sharing an update on {topic}.',
  'funny': 'Okay, real talk about {topic} 😄',
  'inspirational': "Every big step starts somewhere — today it's {topic}.",
  'promotional': "Don't miss this: {topic} is here!",
};
const Map<String, String> _toneBody = {
  'friendly': 'Wanted to share this with you all and hear what you think.',
  'professional': 'Here are the key points and why they matter.',
  'funny': "No, seriously, you had to be there. Here's the short version.",
  'inspirational':
      "Small, steady effort turns into something you'll be proud of.",
  'promotional':
      'Limited time, genuinely worth a look — here are the details.',
};
const Map<String, String> _toneCta = {
  'friendly': 'Let me know your thoughts in the comments!',
  'professional': 'Happy to discuss — reach out anytime.',
  'funny': 'Tag someone who needs to see this.',
  'inspirational': 'Save this as your reminder for today.',
  'promotional': 'Tap the link / DM to grab yours.',
};

String _cleanTopic(String topic) {
  final t = topic.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  return t.isEmpty ? 'this' : t;
}

List<String> _slugWords(String topic, int limit) {
  final words = RegExp(r'[A-Za-z0-9]+').allMatches(topic).map((m) => m.group(0)!);
  final out = <String>[];
  final seen = <String>{};
  for (final w in words) {
    final tag = w[0].toUpperCase() + w.substring(1).toLowerCase();
    final low = tag.toLowerCase();
    if (!seen.contains(low)) {
      seen.add(low);
      out.add(tag);
    }
    if (out.length >= limit) break;
  }
  return out;
}

/// Problem keys (empty ⇒ valid). The UI localises these.
List<String> validateSocial(String platform, String topic,
    {String tone = 'friendly', String length = 'medium', String lang = 'en'}) {
  final out = <String>[];
  if (!kPlatforms.containsKey(platform)) out.add('bad_platform');
  if (topic.trim().isEmpty) out.add('topic_required');
  if (!kTones.contains(tone)) out.add('bad_tone');
  if (!kLengths.contains(length)) out.add('bad_length');
  if (!['bn', 'banglish', 'en'].contains(lang)) out.add('bad_lang');
  return out;
}

List<String> hashtagsFor(String topic, String platform) {
  final cap = (kPlatforms[platform] ?? kPlatforms['facebook']!).hashtags;
  final tags = _slugWords(topic, cap);
  const fillers = [
    'Bangladesh',
    'Community',
    'Tips',
    'Update',
    'Today',
    'Growth',
    'Deal',
    'Story'
  ];
  final lower = tags.map((t) => t.toLowerCase()).toSet();
  for (final f in fillers) {
    if (tags.length >= cap) break;
    if (!lower.contains(f.toLowerCase())) {
      tags.add(f);
      lower.add(f.toLowerCase());
    }
  }
  return tags.take(cap).map((t) => '#$t').toList();
}

List<String> emojiFor(String tone, String platform) {
  if (!(kPlatforms[platform] ?? kPlatforms['facebook']!).emoji) return const [];
  return List<String>.from(_toneEmoji[tone] ?? _toneEmoji['friendly']!);
}

/// Character count against the platform's hard limit.
class CharCount {
  final int used;
  final int limit;
  final int remaining;
  final bool over;
  const CharCount(this.used, this.limit, this.remaining, this.over);
}

CharCount charCount(String text, String platform) {
  final limit = (kPlatforms[platform] ?? kPlatforms['facebook']!).limit;
  final used = text.length;
  return CharCount(used, limit, limit - used, used > limit);
}

String captionFor(String topic, String tone) {
  topic = _cleanTopic(topic);
  const lead = {
    'friendly': 'A little about',
    'professional': 'On the topic of',
    'funny': 'Buckle up:',
    'inspirational': "Today's focus:",
    'promotional': 'Now live:'
  };
  final cap = '${lead[tone] ?? 'On'} $topic.';
  return cap.length <= 120 ? cap : '${cap.substring(0, 117).trimRight()}...';
}

/// The deterministic MOCK draft. Mirrors `social.py::draft`.
class SocialDraft {
  final String platform;
  final String tone;
  final String length;
  final String lang;
  final String caption;
  final String body;
  final List<String> hashtags;
  final List<String> emoji;
  const SocialDraft({
    required this.platform,
    required this.tone,
    required this.length,
    required this.lang,
    required this.caption,
    required this.body,
    required this.hashtags,
    required this.emoji,
  });

  /// Honest flags — this draft is always a mock, never a real-AI result.
  bool get aiRequired => false;
  bool get mock => true;
}

SocialDraft buildDraft(String platform, String topic,
    {String tone = 'friendly', String length = 'medium', String lang = 'en'}) {
  final p = kPlatforms[platform] ?? kPlatforms['facebook']!;
  topic = _cleanTopic(topic);
  final opener =
      (_toneOpener[tone] ?? _toneOpener['friendly']!).replaceAll('{topic}', topic);
  final bodyMid = _toneBody[tone] ?? _toneBody['friendly']!;
  final cta = _toneCta[tone] ?? _toneCta['friendly']!;

  final target = (p.soft * (_lengthScale[length] ?? 1.0)).toInt();
  final parts = <String>[opener, bodyMid];
  if (length == 'long') parts.add(bodyMid);
  if (length != 'short') parts.add(cta);
  var text = parts.join(' ');

  while (text.length < target && text.length < p.limit) {
    text = '$text $bodyMid';
    if (text.length >= target) break;
  }
  if (text.length > p.limit) text = text.substring(0, p.limit).trimRight();

  return SocialDraft(
    platform: platform,
    tone: tone,
    length: length,
    lang: lang,
    caption: captionFor(topic, tone),
    body: text,
    hashtags: hashtagsFor(topic, platform),
    emoji: emojiFor(tone, platform),
  );
}

/// Join body + hashtags into the single string the user copies / shares,
/// clamped to the platform limit. Mirrors `social.py::compose_for_share`.
String composeForShare(String body, List<String> hashtags, String platform) {
  final tail = hashtags.join(' ');
  var text = body.trimRight();
  if (tail.isNotEmpty) text = '$text\n\n$tail'.trim();
  final limit = (kPlatforms[platform] ?? kPlatforms['facebook']!).limit;
  if (text.length > limit) text = text.substring(0, limit).trimRight();
  return text;
}

/// A saved draft row (local history). Stores the edited body + caption +
/// hashtags so the user can reopen, re-copy or re-share — never posts.
class SavedDraft {
  String id;
  String platform;
  String topic;
  String tone;
  String caption;
  String body;
  List<String> hashtags;
  String savedAt; // ISO
  SavedDraft({
    required this.id,
    required this.platform,
    required this.topic,
    required this.tone,
    required this.caption,
    required this.body,
    required this.hashtags,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'platform': platform,
        'topic': topic,
        'tone': tone,
        'caption': caption,
        'body': body,
        'hashtags': hashtags,
        'savedAt': savedAt,
      };

  factory SavedDraft.fromJson(Map<String, dynamic> j) => SavedDraft(
        id: (j['id'] ?? '').toString(),
        platform: (j['platform'] ?? 'facebook').toString(),
        topic: (j['topic'] ?? '').toString(),
        tone: (j['tone'] ?? 'friendly').toString(),
        caption: (j['caption'] ?? '').toString(),
        body: (j['body'] ?? '').toString(),
        hashtags:
            (j['hashtags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        savedAt: (j['savedAt'] ?? '').toString(),
      );
}

/// Local persistence for saved drafts / history (newest first, capped at 50).
class SocialStore {
  static const _key = 'social_drafts_v1';

  static Future<List<SavedDraft>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => SavedDraft.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> save(List<SavedDraft> drafts) async {
    final p = await SharedPreferences.getInstance();
    final capped = drafts.take(50).toList();
    await p.setString(_key, jsonEncode(capped.map((d) => d.toJson()).toList()));
  }
}
