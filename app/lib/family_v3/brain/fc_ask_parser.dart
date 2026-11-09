/// fcbrain — the family ASK BAR offline parser (on the phone, free, no AI).
///
/// Dart twin of backend/core/logic/fc_ask.py. ONE case table drives both
/// test suites (app/test/fixtures/fc_ask_cases.json), so the phone and the
/// server answer the same question the same way. Bangla, romanized Bangla
/// and English: "Is Ammu OK" · "আম্মু ঠিক আছে?" · "ammu thik ase?" ·
/// "Where is my son" · "ছেলে কোথায়" · "chele kothay" · "sobai thik?".
/// Answers ONLY from family status — never "OK" unless the status is ok.
/// Returns null when it cannot answer: the caller then asks the server
/// (POST family/brain/ask), which uses the AI only for those.
///
/// The answer sentences live here (not in the ARB files) on purpose: the
/// server must produce the very same sentence for the same case, and the
/// slot that calls this has no BuildContext. Bangla digits throughout.
library;

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

const Map<String, List<String>> kFcRelationWords = {
  'mother': ['ammu', 'amma', 'ammi', 'ma', 'maa', 'mom', 'mum', 'mummy', 'mother', 'আম্মু', 'আম্মা', 'আম্মি', 'মা', 'মামণি'],
  'father': ['abbu', 'abba', 'baba', 'bapi', 'dad', 'daddy', 'father', 'papa', 'আব্বু', 'আব্বা', 'বাবা', 'বাপি'],
  'son': ['son', 'chele', 'chhele', 'cheley', 'bacha', 'ছেলে'],
  'daughter': ['daughter', 'meye', 'maye', 'mey', 'মেয়ে', 'মেয়ে'],
  'spouse': ['wife', 'husband', 'bou', 'bow', 'swami', 'বউ', 'বৌ', 'স্ত্রী', 'স্বামী'],
  'brother': ['brother', 'bhai', 'bhaiya', 'vai', 'ভাই', 'ভাইয়া'],
  'sister': ['sister', 'bon', 'apu', 'apa', 'didi', 'বোন', 'আপু', 'আপা', 'দিদি'],
  'grandparent': ['dadu', 'nanu', 'dadi', 'nani', 'grandma', 'grandpa', 'granny', 'দাদু', 'নানু', 'দাদি', 'নানি'],
};
const _where = ['where', 'location', 'kothay', 'kothai', 'kotay', 'koi', 'kon jaygay', 'কোথায়', 'কোথায়', 'কই', 'লোকেশন'];
const _okq = ['ok', 'okay', 'fine', 'safe', 'alright', 'all right', 'doing', 'how is', 'hows', 'thik', 'theek', 'valo', 'bhalo', 'nirapod', 'kemon', 'ঠিক', 'ভালো', 'ভাল', 'নিরাপদ', 'কেমন'];
const _battery = ['battery', 'charge', 'charj', 'ব্যাটারি', 'চার্জ'];
const _when = ['last seen', 'when', 'kokhon', 'shesh khobor', 'কখন', 'শেষ খবর'];
const _all = ['everyone', 'everybody', 'all', 'family', 'sobai', 'shobai', 'sokole', 'সবাই', 'সকলে', 'পরিবার'];
const _suffix = ['দের', 'এর', 'ের', 'র', 'কে', 'রা', 'টা', 'টি'];
const _romSuffix = ['er', 'r', 'ke', 'ra'];

String fcBn(Object v) {
  const d = '০১২৩৪৫৬৭৮৯';
  return v.toString().replaceAllMapped(RegExp(r'[0-9]'), (m) => d[int.parse(m[0]!)]);
}

String fcNorm(String q) => q
    .toLowerCase()
    .replaceAll(RegExp(r'''[?？!।,.;:"'()\-]+'''), ' ')
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
  if (s < 90) return en ? 'just now' : 'এইমাত্র';
  if (s < 3600) return en ? '${s ~/ 60} min ago' : '${fcBn(s ~/ 60)} মিনিট আগে';
  if (s < 86400) return en ? '${s ~/ 3600} h ago' : '${fcBn(s ~/ 3600)} ঘণ্টা আগে';
  return en ? '${s ~/ 86400} days ago' : '${fcBn(s ~/ 86400)} দিন আগে';
}

const _reasonBn = {
  'battery_off': 'চার্জ শেষ হয়ে ফোন বন্ধ হতে পারে',
  'no_internet': 'ইন্টারনেট নেই',
  'background_killed': 'ফোন ব্যাকগ্রাউন্ডে Assisto বন্ধ করে দিচ্ছে',
  'never': 'Assisto এখনো খবর পাঠায়নি',
  'clock': 'ফোনের ঘড়ি ভুল',
  'battery_low': 'চার্জ কম',
  'watch': 'অনেকক্ষণ কোনো সাড়া নেই',
  'carecall_missed': 'কেয়ার কল ধরেননি',
  'journey_overdue': 'যাত্রায় দেরি হচ্ছে',
};
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
const _atBn = {
  'বাড়ি': 'বাড়িতে',
  'স্কুল': 'স্কুলে',
  'অফিস': 'অফিসে',
  'কলেজ': 'কলেজে',
  'মাদ্রাসা': 'মাদ্রাসায়',
  'দোকান': 'দোকানে',
};

/// Natural Bangla locative: বাড়ি -> বাড়িতে, স্কুল -> স্কুলে, else "X-এ".
String fcAtBn(String place) => _atBn[place.trim()] ?? '${place.trim()}-এ';

String _reason(String r, bool en) => (en ? _reasonEn : _reasonBn)[r] ?? '';

FcAskResult _okAnswer(FcAskMember m, bool en, DateTime now) {
  final n = m.shown;
  final age = _age(m.lastSeen, now, en);
  final st = m.state;
  if (st == 'sos') {
    return FcAskResult(en ? '$n pressed SOS. Call now.' : '$n SOS চেপেছেন। এখনই ফোন করুন।', m.userId, 'call');
  }
  if (st == 'paused' || m.paused) {
    return FcAskResult(en ? '$n has paused sharing for now.' : '$n এখন শেয়ারিং বিরতিতে রেখেছেন।', m.userId, 'call');
  }
  if (st == 'ok') {
    final w = m.placeLabel;
    final t = en
        ? 'Yes, $n is OK (last news $age${w.isNotEmpty ? ', at $w' : ''}).'
        : 'হ্যাঁ, $n ঠিক আছেন (শেষ খবর $age${w.isNotEmpty ? ', ${fcAtBn(w)}' : ''})।';
    return FcAskResult(t, m.userId, 'open_member');
  }
  final r = _reason(m.reason, en);
  if (st == 'check') {
    return FcAskResult(en ? 'Check on $n: $r.' : '$n-কে একবার দেখুন: $r।', m.userId, 'call');
  }
  final t = en
      ? 'No fresh news from $n${age.isNotEmpty ? ' (last $age)' : ''}${r.isNotEmpty ? '; $r' : ''}. Call to be sure.'
      : '$n-এর কাছ থেকে নতুন খবর নেই${age.isNotEmpty ? ' (শেষ খবর $age)' : ''}${r.isNotEmpty ? '; $r' : ''}। নিশ্চিত হতে ফোন করুন।';
  return FcAskResult(t, m.userId, 'call');
}

FcAskResult _whereAnswer(FcAskMember m, bool en, DateTime now) {
  final n = m.shown;
  if (m.state == 'paused' || m.paused) {
    return FcAskResult(
        en
            ? '$n has paused sharing, so Assisto does not show a place.'
            : '$n শেয়ারিং বিরতিতে রেখেছেন, তাই জায়গা দেখানো হচ্ছে না।',
        m.userId,
        'call');
  }
  final place = m.placeLabel;
  final age = _age(m.lastSeen, now, en);
  final fresh = const {'ok', 'check', 'sos'}.contains(m.state);
  if (place.isNotEmpty && fresh) {
    return FcAskResult(en ? '$n is at $place (news $age).' : '$n এখন ${fcAtBn(place)} (খবর $age)।', m.userId, 'location');
  }
  if (place.isNotEmpty) {
    return FcAskResult(
        en
            ? '$n was last at $place, $age. No fresh news since.'
            : '$n শেষবার ${fcAtBn(place)} ছিলেন, $age। এরপর নতুন খবর নেই।',
        m.userId,
        'call');
  }
  return FcAskResult(
      en
          ? 'Assisto does not know where $n is right now${age.isNotEmpty ? ' (last news $age)' : ''}.'
          : '$n এখন কোথায় Assisto জানে না${age.isNotEmpty ? ' (শেষ খবর $age)' : ''}।',
      m.userId,
      'open_member');
}

FcAskResult _batteryAnswer(FcAskMember m, bool en, DateTime now) {
  final n = m.shown;
  final b = m.battery;
  if (m.paused || m.state == 'paused' || b == null) {
    return FcAskResult(en ? "Assisto does not know $n's battery right now." : '$n-এর চার্জ এখন জানা নেই।', m.userId, 'open_member');
  }
  final age = _age(m.lastSeen, now, en);
  return FcAskResult(en ? "$n's phone was at $b% ($age)." : '$n-এর ফোনে চার্জ ছিল ${fcBn(b)}% ($age)।', m.userId, 'open_member');
}

FcAskResult _whenAnswer(FcAskMember m, bool en, DateTime now) {
  final n = m.shown;
  final age = _age(m.lastSeen, now, en);
  if (age.isEmpty) {
    return FcAskResult(en ? 'No news from $n yet.' : '$n-এর কাছ থেকে এখনো কোনো খবর আসেনি।', m.userId, 'call');
  }
  return FcAskResult(en ? 'Last news from $n: $age.' : '$n-এর শেষ খবর: $age।', m.userId, 'open_member');
}

FcAskResult _allAnswer(List<FcAskMember> members, bool en, DateTime now) {
  if (members.isEmpty) {
    return FcAskResult(en ? 'No family members yet.' : 'পরিবারে এখনো কেউ নেই।', null, 'none');
  }
  const order = {'sos': 0, 'check': 1, 'stale': 2, 'paused': 3, 'ok': 4};
  final bad = members.where((m) => m.state != 'ok').toList()
    ..sort((a, b) => (order[a.state] ?? 2).compareTo(order[b.state] ?? 2));
  if (bad.isEmpty) {
    return FcAskResult(en ? 'Yes, everyone is OK with fresh news.' : 'হ্যাঁ, সবাই ঠিক আছেন — সবার তাজা খবর আছে।', null, 'none');
  }
  final a = _okAnswer(bad.first, en, now);
  if (bad.length == 1) return a;
  final more = bad.length - 1;
  return FcAskResult(a.text + (en ? ' (+$more more to check)' : ' (আরও ${fcBn(more)} জন)'), a.memberUserId, a.action);
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
              : 'আপনার পরিবারের তালিকায় "$word" নেই। My Circle থেকে যোগ করুন।',
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
    return FcAskResult(en ? 'Who do you mean: $names?' : 'কার কথা বলছেন: $names?', null, 'none');
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
