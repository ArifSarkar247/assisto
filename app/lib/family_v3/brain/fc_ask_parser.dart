/// fcbrain — the family ASK BAR offline parser (on the phone, free, no AI).
///
/// Dart twin of backend/core/logic/fc_ask.py. ONE case table drives both
/// test suites (app/test/fixtures/fc_ask_cases.json), so the phone and the
/// server answer the same question the same way. Bangla, romanized Bangla
/// and English ("Is Ammu OK", "ammu thik ase?", "Where is my son",
/// "chele kothay", "sobai thik?" and the same in Bengali script).
/// Answers ONLY from family status — never "OK" unless the status is ok.
/// Returns null when it cannot answer: the caller then asks the server
/// (POST family/brain/ask), which uses the AI only for those.
///
/// The answer sentences are not ARB strings on purpose: the server must
/// produce the very same sentence for the same case, and the slot that
/// calls this has no BuildContext. Bangla words + sentences live in
/// lib/l10n/fc_brain_bn.dart (the lang gate allows Bangla only there).
library;

import '../../l10n/fc_brain_bn.dart';

export '../../l10n/fc_brain_bn.dart' show fcAtBn;

class FcAskMember {
  final int userId;
  final String name, label, relation, state, reason, placeLabel;
  final DateTime? lastSeen;
  final int? battery;
  final bool paused;
  const FcAskMember({
    required this.userId,
    required this.name,
    this.label = '',
    this.relation = '',
    this.state = 'stale',
    this.reason = '',
    this.placeLabel = '',
    this.lastSeen,
    this.battery,
    this.paused = false,
  });

  static FcAskMember? fromJson(Object? m) {
    if (m is! Map) return null;
    final id = (m['user_id'] as num?)?.toInt();
    if (id == null) return null;
    return FcAskMember(
      userId: id,
      name: (m['name'] ?? '').toString(),
      label: (m['label'] ?? '').toString(),
      relation: (m['relation'] ?? '').toString(),
      state: (m['state'] ?? 'stale').toString(),
      reason: (m['reason'] ?? '').toString(),
      placeLabel: (m['place_label'] ?? '').toString(),
      lastSeen: DateTime.tryParse((m['last_seen'] ?? '').toString()),
      battery: (m['battery'] as num?)?.toInt(),
      paused: m['paused'] == true,
    );
  }

  String get shown => label.isNotEmpty ? label : name;
}

class FcAskResult {
  final String text;
  final int? memberUserId;
  final String action; // none | open_member | call | location
  const FcAskResult(this.text, this.memberUserId, this.action);
}

const Map<String, List<String>> _kFcRelationLatin = {
  'mother': ['ammu', 'amma', 'ammi', 'ma', 'maa', 'mom', 'mum', 'mummy', 'mother'],
  'father': ['abbu', 'abba', 'baba', 'bapi', 'dad', 'daddy', 'father', 'papa'],
  'son': ['son', 'chele', 'chhele', 'cheley', 'bacha'],
  'daughter': ['daughter', 'meye', 'maye', 'mey'],
  'spouse': ['wife', 'husband', 'bou', 'bow', 'swami'],
  'brother': ['brother', 'bhai', 'bhaiya', 'vai'],
  'sister': ['sister', 'bon', 'apu', 'apa', 'didi'],
  'grandparent': ['dadu', 'nanu', 'dadi', 'nani', 'grandma', 'grandpa', 'granny'],
};
final Map<String, List<String>> kFcRelationWords = {
  for (final e in _kFcRelationLatin.entries) e.key: [...e.value, ...?kFcRelationBn[e.key]],
};
final _where = ['where', 'location', 'kothay', 'kothai', 'kotay', 'koi', 'kon jaygay', ...kFcWhereBn];
final _okq = ['ok', 'okay', 'fine', 'safe', 'alright', 'all right', 'doing', 'how is', 'hows', 'thik', 'theek', 'valo', 'bhalo', 'nirapod', 'kemon', ...kFcOkBn];
final _battery = ['battery', 'charge', 'charj', ...kFcBatteryBn];
final _when = ['last seen', 'when', 'kokhon', 'shesh khobor', ...kFcWhenBn];
final _all = ['everyone', 'everybody', 'all', 'family', 'sobai', 'shobai', 'sokole', ...kFcAllBn];
const _suffix = kFcSuffixBn;
const _romSuffix = ['er', 'r', 'ke', 'ra'];

String fcBn(Object v) => fcBnDigits(v);

String fcNorm(String q) => q
    .toLowerCase()
    .replaceAll(RegExp('[?？!$kFcDandaBn,.;:"\'()\\-]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _stem(String tok) {
  for (final s in _suffix) {
    if (tok.endsWith(s) && tok.length > s.length + 1) {
      return tok.substring(0, tok.length - s.length);
    }
  }
  if (RegExp(r'^[a-z]+$').hasMatch(tok)) {
    for (final s in _romSuffix) {
      if (tok.endsWith(s) && tok.length > s.length + 2) {
        return tok.substring(0, tok.length - s.length);
      }
    }
  }
  return tok;
}

bool _has(String text, List<String> words) {
  final toks = text.split(' ').toSet();
  for (final w in words) {
    if (w.contains(' ')) {
      if (text.contains(w)) return true;
    } else if (toks.contains(w) || toks.any((t) => _stem(t) == w)) {
      return true;
    }
  }
  return false;
}

Set<String> _nameKeys(FcAskMember m) {
  final keys = <String>{};
  for (final v in [m.label, m.name]) {
    final n = fcNorm(v);
    if (n.isNotEmpty) {
      keys.add(n);
      keys.add(n.split(' ').first);
    }
  }
  return keys.where((k) => k.length >= 2).toSet();
}

List<FcAskMember> fcFindMembers(String text, List<FcAskMember> members) {
  final toks = text.split(' ');
  final stems = {...toks, ...toks.map(_stem)};
  final hits = <FcAskMember>[];
  for (final m in members) {
    for (final k in _nameKeys(m)) {
      if ((k.contains(' ') && text.contains(k)) || stems.contains(k)) {
        hits.add(m);
        break;
      }
    }
  }
  if (hits.isNotEmpty) return hits;
  for (final e in kFcRelationWords.entries) {
    final ws = e.value.toSet();
    if (stems.intersection(ws).isNotEmpty) {
      final h = members
          .where((m) => m.relation == e.key || _nameKeys(m).intersection(ws).isNotEmpty)
          .toList();
      if (h.isNotEmpty) return h;
    }
  }
  return const [];
}

String _relationWord(String text) {
  for (final t in text.split(' ')) {
    final s = _stem(t);
    for (final ws in kFcRelationWords.values) {
      if (ws.contains(t) || ws.contains(s)) return t;
    }
  }
  return '';
}

String _age(DateTime? seen, DateTime now, bool en) {
  if (seen == null) return '';
  final s0 = now.difference(seen).inSeconds;
  final s = s0 < 0 ? 0 : s0;
  if (s < 90) return en ? 'just now' : FcAskBn.justNow;
  if (s < 3600) return en ? '${s ~/ 60} min ago' : FcAskBn.minAgo(s ~/ 60);
  if (s < 86400) return en ? '${s ~/ 3600} h ago' : FcAskBn.hAgo(s ~/ 3600);
  return en ? '${s ~/ 86400} days ago' : FcAskBn.daysAgo(s ~/ 86400);
}

const _reasonEn = {
  'battery_off': 'the battery may have run out',
  'no_internet': 'no internet',
  'background_killed': 'the phone is stopping Assisto in the background',
  'never': 'Assisto has not reported yet',
  'clock': 'the phone clock is wrong',
  'battery_low': 'battery is low',
  'watch': 'no response for a long time',
  'carecall_missed': 'missed a Care Call',
  'journey_overdue': 'a journey is late',
};
String _reason(String r, bool en) => (en ? _reasonEn : kFcReasonBn)[r] ?? '';

FcAskResult _okAnswer(FcAskMember m, bool en, DateTime now) {
  final n = m.shown;
  final age = _age(m.lastSeen, now, en);
  final st = m.state;
  if (st == 'sos') {
    return FcAskResult(en ? '$n pressed SOS. Call now.' : FcAskBn.sos(n), m.userId, 'call');
  }
  if (st == 'paused' || m.paused) {
    return FcAskResult(en ? '$n has paused sharing for now.' : FcAskBn.paused(n), m.userId, 'call');
  }
  if (st == 'ok') {
    final w = m.placeLabel;
    final t = en
        ? 'Yes, $n is OK (last news $age${w.isNotEmpty ? ', at $w' : ''}).'
        : FcAskBn.ok(n, age, w);
    return FcAskResult(t, m.userId, 'open_member');
  }
  final r = _reason(m.reason, en);
  if (st == 'check') {
    return FcAskResult(en ? 'Check on $n: $r.' : FcAskBn.check(n, r), m.userId, 'call');
  }
  final t = en
      ? 'No fresh news from $n${age.isNotEmpty ? ' (last $age)' : ''}${r.isNotEmpty ? '; $r' : ''}. Call to be sure.'
      : FcAskBn.stale(n, age, r);
  return FcAskResult(t, m.userId, 'call');
}

FcAskResult _whereAnswer(FcAskMember m, bool en, DateTime now) {
  final n = m.shown;
  if (m.state == 'paused' || m.paused) {
    return FcAskResult(
        en
            ? '$n has paused sharing, so Assisto does not show a place.'
            : FcAskBn.wherePaused(n),
        m.userId,
        'call');
  }
  final place = m.placeLabel;
  final age = _age(m.lastSeen, now, en);
  final fresh = const {'ok', 'check', 'sos'}.contains(m.state);
  if (place.isNotEmpty && fresh) {
    return FcAskResult(en ? '$n is at $place (news $age).' : FcAskBn.whereNow(n, place, age), m.userId, 'location');
  }
  if (place.isNotEmpty) {
    return FcAskResult(
        en
            ? '$n was last at $place, $age. No fresh news since.'
            : FcAskBn.whereLast(n, place, age),
        m.userId,
        'call');
  }
  return FcAskResult(
      en
          ? 'Assisto does not know where $n is right now${age.isNotEmpty ? ' (last news $age)' : ''}.'
          : FcAskBn.whereUnknown(n, age),
      m.userId,
      'open_member');
}

FcAskResult _batteryAnswer(FcAskMember m, bool en, DateTime now) {
  final n = m.shown;
  final b = m.battery;
  if (m.paused || m.state == 'paused' || b == null) {
    return FcAskResult(en ? "Assisto does not know $n's battery right now." : FcAskBn.batteryUnknown(n), m.userId, 'open_member');
  }
  final age = _age(m.lastSeen, now, en);
  return FcAskResult(en ? "$n's phone was at $b% ($age)." : FcAskBn.battery(n, b, age), m.userId, 'open_member');
}

FcAskResult _whenAnswer(FcAskMember m, bool en, DateTime now) {
  final n = m.shown;
  final age = _age(m.lastSeen, now, en);
  if (age.isEmpty) {
    return FcAskResult(en ? 'No news from $n yet.' : FcAskBn.noNewsYet(n), m.userId, 'call');
  }
  return FcAskResult(en ? 'Last news from $n: $age.' : FcAskBn.lastNews(n, age), m.userId, 'open_member');
}

FcAskResult _allAnswer(List<FcAskMember> members, bool en, DateTime now) {
  if (members.isEmpty) {
    return FcAskResult(en ? 'No family members yet.' : FcAskBn.noFamily, null, 'none');
  }
  const order = {'sos': 0, 'check': 1, 'stale': 2, 'paused': 3, 'ok': 4};
  final bad = members.where((m) => m.state != 'ok').toList()
    ..sort((a, b) => (order[a.state] ?? 2).compareTo(order[b.state] ?? 2));
  if (bad.isEmpty) {
    return FcAskResult(en ? 'Yes, everyone is OK with fresh news.' : FcAskBn.allOk, null, 'none');
  }
  final a = _okAnswer(bad.first, en, now);
  if (bad.length == 1) return a;
  final more = bad.length - 1;
  return FcAskResult(a.text + (en ? ' (+$more more to check)' : FcAskBn.more(more)), a.memberUserId, a.action);
}

/// The parser. [lang] 'bn' | 'en'. Null = not understood (ask the server).
FcAskResult? fcAskAnswer(String q, List<FcAskMember> members,
    {String lang = 'bn', DateTime? now}) {
  final en = lang == 'en';
  final t = DateTime.now();
  final at = now ?? t;
  final text = fcNorm(q);
  if (text.isEmpty) return null;
  final hits = fcFindMembers(text, members);
  String? intent;
  if (_has(text, _battery)) {
    intent = 'battery';
  } else if (_has(text, _where)) {
    intent = 'where';
  } else if (_has(text, _when)) {
    intent = 'when';
  } else if (_has(text, _okq)) {
    intent = 'ok';
  }
  if (hits.isEmpty) {
    if (intent == 'ok' && _has(text, _all)) return _allAnswer(members, en, at);
    final word = _relationWord(text);
    if (word.isNotEmpty && intent != null) {
      return FcAskResult(
          en
              ? 'Nobody in your family list is "$word". Add them from My Circle.'
              : FcAskBn.notInList(word),
          null,
          'none');
    }
    return null;
  }
  if (intent == null) {
    if (text.split(' ').length > 3) return null;
    intent = 'ok';
  }
  if (hits.map((h) => h.userId).toSet().length > 1) {
    final names = hits.take(4).map((h) => h.shown).join(', ');
    return FcAskResult(en ? 'Who do you mean: $names?' : FcAskBn.who(names), null, 'none');
  }
  final m = hits.first;
  switch (intent) {
    case 'where':
      return _whereAnswer(m, en, at);
    case 'battery':
      return _batteryAnswer(m, en, at);
    case 'when':
      return _whenAnswer(m, en, at);
    default:
      return _okAnswer(m, en, at);
  }
}
