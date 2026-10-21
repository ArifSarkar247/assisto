// Assisto Voice — on-device, rule-based intent parser (Part 3).
//
// Understands Bangla, Banglish (romanised Bangla) and English commands and
// turns ONE spoken utterance into a structured [VaIntent]. Pure Dart: no
// Flutter, no plugins, no network — fully unit-testable and instant.
//
// Anything it cannot map with confidence returns [VaAction.unknown] and the
// caller sends the transcript to the server agent (`api.agent`), which has the
// richer bilingual brain (questions, loans, medicine, memory, …).
//
// LANGUAGE GATE: Bangla keywords in this file are written as \u escapes (the
// gate forbids Bangla characters in Dart outside lib/l10n). They are INPUT
// vocabulary (what the user may say), never user-facing output.

/// What the assistant should do.
enum VaAction {
  call,
  sms,
  whatsapp,
  youtube,
  alarm,
  timer,
  torchOn,
  torchOff,
  openApp,
  openScreen,
  navigate,
  mapSearch,
  reminder,
  expense,
  sos,
  unknown,
}

/// A clock time understood from speech ("8tay", "6:30 pm", "sokal 7 ta").
class VaClock {
  final int hour; // as spoken, 0..23 (may be 1..12 when ampm unknown)
  final int minute;
  final bool ampmKnown; // am/pm or a day-part word fixed the half of the day
  final bool tomorrow;

  /// The matched text ("8 tay", "6:30 pm") so callers can cut it out.
  final String span;
  const VaClock(this.hour, this.minute,
      {this.ampmKnown = false, this.tomorrow = false, this.span = ''});

  /// The concrete next fire time after [now]. When am/pm is unknown we pick
  /// the soonest of h:mm and (h+12):mm that is still ahead (Google-style); a
  /// "tomorrow" hint without am/pm means the morning.
  DateTime resolve(DateTime now) {
    var h = hour;
    final today = DateTime(now.year, now.month, now.day);
    if (tomorrow) {
      final d = today.add(const Duration(days: 1));
      return DateTime(d.year, d.month, d.day, h, minute);
    }
    if (ampmKnown || h > 12 || h == 0) {
      var c = DateTime(now.year, now.month, now.day, h, minute);
      if (!c.isAfter(now)) c = c.add(const Duration(days: 1));
      return c;
    }
    final am = h == 12 ? 0 : h;
    final cands = [
      DateTime(now.year, now.month, now.day, am, minute),
      DateTime(now.year, now.month, now.day, am + 12, minute),
      DateTime(now.year, now.month, now.day, am, minute)
          .add(const Duration(days: 1)),
    ];
    for (final c in cands) {
      if (c.isAfter(now)) return c;
    }
    return cands.last;
  }

  @override
  String toString() =>
      'VaClock($hour:$minute ampm=$ampmKnown tomorrow=$tomorrow)';
}

/// One understood command.
class VaIntent {
  final VaAction action;

  /// Contact name / app name / place / search query, as spoken (cleaned).
  final String? target;

  /// SMS / WhatsApp body, reminder title, expense note.
  final String? message;
  final VaClock? clock; // alarm / reminder time
  final int? seconds; // timer length
  final num? amount; // expense
  final String? category; // expense category key (see VaText.categories)
  final String? route; // in-app screen (openScreen)
  final String raw;

  const VaIntent(
    this.action,
    this.raw, {
    this.target,
    this.message,
    this.clock,
    this.seconds,
    this.amount,
    this.category,
    this.route,
  });

  /// Outgoing actions ALWAYS need an explicit confirmation before they run.
  bool get outgoing =>
      action == VaAction.call ||
      action == VaAction.sms ||
      action == VaAction.whatsapp ||
      action == VaAction.sos;

  @override
  String toString() => 'VaIntent($action, target: $target, message: $message, '
      'clock: $clock, seconds: $seconds, amount: $amount, '
      'category: $category, route: $route)';
}

/// Text helpers shared by the parser, the contact matcher and the app matcher.
class VaText {
  VaText._();

  static final _bnDigit0 = 0x09E6;

  /// Lowercase, Bangla digits -> ASCII, nukta forms unified, punctuation
  /// removed, whitespace collapsed.
  static String norm(String s) {
    final b = StringBuffer();
    for (final r in s.toLowerCase().runes) {
      if (r >= _bnDigit0 && r <= _bnDigit0 + 9) {
        b.writeCharCode(0x30 + r - _bnDigit0);
      } else if (r == 0x09DF) {
        // precomposed YYA -> YA + NUKTA
        b.writeCharCode(0x09AF);
        b.writeCharCode(0x09BC);
      } else if (r == 0x09DC) {
        b.writeCharCode(0x09A1);
        b.writeCharCode(0x09BC);
      } else if (r == 0x09DD) {
        b.writeCharCode(0x09A2);
        b.writeCharCode(0x09BC);
      } else if (r == 0x200C || r == 0x200D) {
        // zero-width (non-)joiners: drop
      } else if (r == 0x0964 || r == 0x0965) {
        b.write(' '); // dari / double dari
      } else {
        b.writeCharCode(r);
      }
    }
    return b
        .toString()
        .replaceAll(RegExp(r'''[,!?;"“”‘’]'''), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool isBangla(String w) =>
      w.runes.any((r) => r >= 0x0980 && r <= 0x09FF);

  /// True when [kw] occurs in [text] at a word START. Latin keywords must also
  /// END on a word boundary ("call" never matches "recall" or "calling"? —
  /// "calling" is allowed via an explicit keyword). Bangla keywords may carry
  /// attached suffixes ("kol" + "e").
  static bool has(String text, String kw) => indexOfKw(text, kw) >= 0;

  static int indexOfKw(String text, String kw) {
    if (kw.isEmpty) return -1;
    final latin = !isBangla(kw);
    var from = 0;
    while (true) {
      final i = text.indexOf(kw, from);
      if (i < 0) return -1;
      final startOk = i == 0 || text[i - 1] == ' ';
      final end = i + kw.length;
      final short = !latin && kw.runes.length <= 2;
      final endOk = (!latin && !short) ||
          end == text.length ||
          (latin
              ? !RegExp(r"[a-z0-9']").hasMatch(text[end])
              : text[end] == ' ');
      if (startOk && endOk) return i;
      from = i + 1;
    }
  }

  static bool any(String text, List<String> kws) =>
      kws.any((k) => has(text, k));

  static String? firstHit(String text, List<String> kws) {
    String? best;
    for (final k in kws) {
      if (has(text, k) && (best == null || k.length > best.length)) best = k;
    }
    return best;
  }

  /// Remove every keyword in [kws] (longest first). A Bangla keyword removes
  /// the whole word it starts (so attached suffixes go too).
  static String strip(String text, List<String> kws) {
    var out = ' $text ';
    final sorted = [...kws]..sort((a, b) => b.length.compareTo(a.length));
    for (final k in sorted) {
      if (k.isEmpty) continue;
      while (true) {
        final i = indexOfKw(out.trim(), k);
        if (i < 0) break;
        final t = out.trim();
        var end = i + k.length;
        if (isBangla(k)) {
          while (end < t.length && t[end] != ' ') {
            end++;
          }
        }
        out = ' ${t.substring(0, i)} ${t.substring(end)} ';
      }
    }
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Drop filler words only at the start and the end ("me at ... dio").
  static String trimFillers(String text, Set<String> words) {
    final w = text.split(' ').where((x) => x.isNotEmpty).toList();
    while (w.isNotEmpty && words.contains(w.first)) {
      w.removeAt(0);
    }
    while (w.isNotEmpty && words.contains(w.last)) {
      w.removeLast();
    }
    return w.join(' ');
  }

  /// Drop standalone filler words.
  static String dropWords(String text, Set<String> words) => text
      .split(' ')
      .where((w) => w.isNotEmpty && !words.contains(w))
      .join(' ')
      .trim();

  // ---- consonant skeleton (cross-script fuzzy name matching) -------------
  //
  // "rakib" and the Bangla spelling of Rakib both reduce to "rkb", so a contact
  // saved in English matches a name spoken in Bangla and vice versa.
  static const Map<int, String> _bnCons = {
    0x0995: 'k', 0x0996: 'k', 0x0997: 'g', 0x0998: 'g', 0x0999: 'n',
    0x099A: 'c', 0x099B: 'c', 0x099C: 'j', 0x099D: 'j', 0x099E: 'n',
    0x099F: 't', 0x09A0: 't', 0x09A1: 'd', 0x09A2: 'd', 0x09A3: 'n',
    0x09A4: 't', 0x09A5: 't', 0x09A6: 'd', 0x09A7: 'd', 0x09A8: 'n',
    0x09AA: 'p', 0x09AB: 'f', 0x09AC: 'b', 0x09AD: 'b', 0x09AE: 'm',
    0x09AF: 'j', 0x09B0: 'r', 0x09B2: 'l', 0x09B6: 's', 0x09B7: 's',
    0x09B8: 's', 0x09B9: 'h', 0x0982: 'n', 0x09CE: 't', 0x098B: 'r',
  };

  static String skeleton(String s) {
    final n = norm(s);
    final out = StringBuffer();
    String last = '';
    void emit(String c) {
      if (c.isEmpty || c == last) return;
      out.write(c);
      last = c;
    }

    if (isBangla(n)) {
      final rs = n.runes.toList();
      for (var i = 0; i < rs.length; i++) {
        final r = rs[i];
        // YA + NUKTA (y-sound) is a vowel glide, not a consonant.
        if (r == 0x09AF && i + 1 < rs.length && rs[i + 1] == 0x09BC) {
          i++;
          continue;
        }
        // DDA/DDHA + NUKTA (rr) sound like r.
        if ((r == 0x09A1 || r == 0x09A2) &&
            i + 1 < rs.length &&
            rs[i + 1] == 0x09BC) {
          emit('r');
          i++;
          continue;
        }
        // YA-phala after hasanta is a conjunct marker, not a sound.
        if (r == 0x09AF && i > 0 && rs[i - 1] == 0x09CD) continue;
        final c = _bnCons[r];
        if (c != null) emit(c);
      }
      return out.toString();
    }
    var t = n.replaceAll(RegExp(r'[^a-z]'), '');
    const di = {
      'kh': 'k', 'gh': 'g', 'ch': 'c', 'jh': 'j', 'th': 't', 'dh': 'd',
      'ph': 'f', 'bh': 'b', 'sh': 's',
    };
    di.forEach((k, v) => t = t.replaceAll(k, v));
    for (final ch in t.split('')) {
      switch (ch) {
        case 'a':
        case 'e':
        case 'i':
        case 'o':
        case 'u':
        case 'y':
        case 'w':
          last = ''; // a vowel separates double consonants ("mm" vs "m_m")
          continue;
        case 'q':
          emit('k');
        case 'c':
          emit('c');
        case 'z':
          emit('j');
        case 'v':
          emit('b');
        case 'x':
          emit('k');
          emit('s');
        default:
          emit(ch);
      }
    }
    return out.toString();
  }

  // ---- numbers -----------------------------------------------------------
  static num? amount(String normText) {
    final m = RegExp(r'(\d[\d,]*(?:\.\d+)?)\s*(k\b|hajar|hazar|haja|thousand|'
            '\u09b9\u09be\u099c\u09be\u09b0|lakh|lac|\u09b2\u09be\u0996)?')
        .firstMatch(normText);
    if (m == null) return null;
    var v = num.tryParse(m.group(1)!.replaceAll(',', ''));
    if (v == null) return null;
    final mult = m.group(2);
    if (mult != null) {
      if (mult.startsWith('l') || mult.startsWith('\u09b2')) {
        v = v * 100000;
      } else {
        v = v * 1000;
      }
    }
    return v == v.toInt() ? v.toInt() : v;
  }

  /// Bangladeshi number -> international digits for wa.me ("01712…" ->
  /// "8801712…"). Returns digits only.
  static String waNumber(String phone) {
    var d = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (d.startsWith('00')) d = d.substring(2);
    if (d.startsWith('0') && d.length == 11) d = '88$d';
    if (d.length == 10 && d.startsWith('1')) d = '880$d';
    return d;
  }

  // ---- expense categories (key -> spoken words) ---------------------------
  static const Map<String, List<String>> categories = {
    'groceries': [
      'bazar', 'bajar', 'grocery', 'groceries', 'market', 'vegetables',
      'sobji', 'baajar', '\u09ac\u09be\u099c\u09be\u09b0', '\u09b8\u09ac\u099c\u09bf', '\u09ae\u09be\u099b', '\u09ae\u09be\u0982\u09b8',
    ],
    'food': [
      'food', 'lunch', 'dinner', 'breakfast', 'snacks', 'khabar', 'khawa',
      'nasta', 'cha', 'tea', 'coffee', 'restaurant',
      '\u0996\u09be\u09ac\u09be\u09b0', '\u0996\u09be\u0993\u09af\u09bc\u09be', '\u09a8\u09be\u09b8\u09cd\u09a4\u09be', '\u099a\u09be', '\u09a6\u09c1\u09aa\u09c1\u09b0\u09c7\u09b0 \u0996\u09be\u09ac\u09be\u09b0',
    ],
    'transport': [
      'rickshaw', 'riksha', 'bus', 'cng', 'uber', 'pathao', 'taxi', 'fare',
      'transport', 'train', 'vara', 'bhara',
      '\u09b0\u09bf\u0995\u09b6\u09be', '\u09ac\u09be\u09b8', '\u09b8\u09bf\u098f\u09a8\u099c\u09bf', '\u09ad\u09be\u09a1\u09bc\u09be', '\u09af\u09be\u09a4\u09be\u09af\u09bc\u09be\u09a4', '\u0997\u09be\u09a1\u09bc\u09bf',
    ],
    'bills': [
      'bill', 'electricity', 'current bill', 'gas', 'water', 'internet', 'wifi',
      '\u09ac\u09bf\u09b2', '\u09ac\u09bf\u09a6\u09cd\u09af\u09c1\u09ce', '\u0997\u09cd\u09af\u09be\u09b8', '\u09aa\u09be\u09a8\u09bf', '\u0987\u09a8\u09cd\u099f\u09be\u09b0\u09a8\u09c7\u099f', '\u0995\u09be\u09b0\u09c7\u09a8\u09cd\u099f',
    ],
    'recharge': [
      'recharge', 'flexiload', 'mobile recharge', 'talktime',
      '\u09b0\u09bf\u099a\u09be\u09b0\u09cd\u099c', '\u09ab\u09cd\u09b2\u09c7\u0995\u09cd\u09b8\u09bf\u09b2\u09cb\u09a1',
    ],
    'health': [
      'medicine', 'oshudh', 'osudh', 'doctor', 'hospital', 'pharmacy',
      '\u0993\u09b7\u09c1\u09a7', '\u09a1\u09be\u0995\u09cd\u09a4\u09be\u09b0', '\u09b9\u09be\u09b8\u09aa\u09be\u09a4\u09be\u09b2',
    ],
    'shopping': [
      'shopping', 'clothes', 'shirt', 'dress', 'kapor', 'jama', 'shoes',
      '\u0995\u09be\u09aa\u09a1\u09bc', '\u099c\u09be\u09ae\u09be', '\u099c\u09c1\u09a4\u09be', '\u09b6\u09aa\u09bf\u0982',
    ],
    'education': [
      'school', 'tuition', 'books', 'boi', 'fees', 'college',
      '\u09b8\u09cd\u0995\u09c1\u09b2', '\u099f\u09bf\u0989\u09b6\u09a8', '\u09ac\u0987', '\u09ac\u09c7\u09a4\u09a8',
    ],
  };

  static String? categoryOf(String normText) {
    for (final e in categories.entries) {
      for (final w in e.value) {
        if (has(normText, norm(w))) return e.key;
      }
    }
    return null;
  }
}

/// Well-known apps: spoken names -> Android package (first is canonical label).
class VaApps {
  VaApps._();
  static const Map<String, List<String>> aliases = {
    'com.whatsapp': ['whatsapp', 'whats app', '\u09b9\u09cb\u09af\u09bc\u09be\u099f\u09b8\u0985\u09cd\u09af\u09be\u09aa', '\u09b9\u09cb\u09af\u09bc\u09be\u099f\u09b8\u09cd\u09af\u09be\u09aa'],
    'com.facebook.katana': ['facebook', 'fb', '\u09ab\u09c7\u09b8\u09ac\u09c1\u0995'],
    'com.facebook.orca': ['messenger', '\u09ae\u09c7\u09b8\u09c7\u099e\u09cd\u099c\u09be\u09b0'],
    'com.google.android.youtube': ['youtube', 'you tube', '\u0987\u0989\u099f\u09bf\u0989\u09ac'],
    'com.imo.android.imoim': ['imo', '\u0987\u09ae\u09cb'],
    'com.bKash.customerapp': ['bkash', 'b kash', '\u09ac\u09bf\u0995\u09be\u09b6'],
    'com.konasl.nagad': ['nagad', '\u09a8\u0997\u09a6'],
    'com.zhiliaoapp.musically': ['tiktok', 'tik tok', '\u099f\u09bf\u0995\u099f\u0995'],
    'org.telegram.messenger': ['telegram', '\u099f\u09c7\u09b2\u09bf\u0997\u09cd\u09b0\u09be\u09ae'],
    'com.instagram.android': ['instagram', 'insta', '\u0987\u09a8\u09b8\u09cd\u099f\u09be\u0997\u09cd\u09b0\u09be\u09ae'],
    'com.google.android.gm': ['gmail', 'email', 'mail', '\u099c\u09bf\u09ae\u09c7\u0987\u09b2'],
    'com.android.chrome': ['chrome', 'browser', '\u0995\u09cd\u09b0\u09cb\u09ae', '\u09ac\u09cd\u09b0\u09be\u0989\u099c\u09be\u09b0'],
    'com.google.android.apps.maps': ['google maps', 'maps', '\u09ae\u09cd\u09af\u09be\u09aa\u09b8'],
    'com.android.vending': ['play store', 'playstore', '\u09aa\u09cd\u09b2\u09c7 \u09b8\u09cd\u099f\u09cb\u09b0'],
    'com.pathao.user': ['pathao', '\u09aa\u09be\u09a0\u09be\u0993 \u0985\u09cd\u09af\u09be\u09aa'],
    'com.global.foodpanda.android': ['foodpanda', 'food panda', '\u09ab\u09c1\u09a1\u09aa\u09be\u09a8\u09cd\u09a1\u09be'],
    'com.android.settings': ['settings', 'setting', '\u09b8\u09c7\u099f\u09bf\u0982\u09b8'],
    'camera': ['camera', '\u0995\u09cd\u09af\u09be\u09ae\u09c7\u09b0\u09be'],
    'gallery': ['gallery', 'photos', '\u0997\u09cd\u09af\u09be\u09b2\u09be\u09b0\u09bf', '\u099b\u09ac\u09bf'],
    'calculator': ['calculator', '\u0995\u09cd\u09af\u09be\u09b2\u0995\u09c1\u09b2\u09c7\u099f\u09b0'],
    'clock': ['clock', '\u0998\u09a1\u09bc\u09bf'],
    'contacts': ['contacts', 'phonebook', '\u0995\u09a8\u09cd\u099f\u09be\u0995\u09cd\u099f\u09b8'],
  };

  /// Canonical spoken key for [name] (e.g. "whatsapp"), or null.
  static String? packageFor(String name) {
    final n = VaText.norm(name);
    for (final e in aliases.entries) {
      for (final a in e.value) {
        if (n == VaText.norm(a)) return e.key;
      }
    }
    return null;
  }

  /// Rank installed apps [{label, package}] against a spoken [name]. Returns
  /// the best package or null when nothing matches well.
  static String? best(String name, List<Map<String, String>> apps) {
    final n = VaText.norm(name);
    if (n.isEmpty) return null;
    final pkg = packageFor(n);
    if (pkg != null && pkg.contains('.')) {
      if (apps.any((a) => a['package'] == pkg)) return pkg;
    }
    // generic labels (camera/gallery/...) and everything else: label match.
    final words = <String>[n, ...?(pkg == null ? null : aliases[pkg])]
        .map(VaText.norm)
        .toList();
    String? hit;
    var score = 0;
    for (final a in apps) {
      final label = VaText.norm(a['label'] ?? '');
      if (label.isEmpty) continue;
      var s = 0;
      for (final w in words) {
        if (label == w) {
          s = 100;
        } else if (label.startsWith(w) && s < 80) {
          s = 80;
        } else if (VaText.has(label, w) && s < 60) {
          s = 60;
        } else {
          final ks = VaText.skeleton(w), ls = VaText.skeleton(label);
          if (ks.length >= 2 && ks == ls && s < 50) s = 50;
        }
      }
      if (s > score) {
        score = s;
        hit = a['package'];
      }
    }
    return score >= 50 ? hit : null;
  }
}

/// Relationship words -> every common way it is saved in a phonebook.
class VaContacts {
  VaContacts._();
  static const List<List<String>> relations = [
    ['ammu', 'amma', 'ammi', 'ma', 'maa', 'mom', 'mum', 'mummy', 'mother',
      '\u0986\u09ae\u09cd\u09ae\u09c1', '\u0986\u09ae\u09cd\u09ae\u09be', '\u09ae\u09be', '\u0986\u09ae\u09cd\u09ae\u09bf'],
    ['abbu', 'abba', 'baba', 'bapi', 'dad', 'daddy', 'father', 'papa',
      '\u0986\u09ac\u09cd\u09ac\u09c1', '\u0986\u09ac\u09cd\u09ac\u09be', '\u09ac\u09be\u09ac\u09be'],
    ['bhaiya', 'bhai', 'vaiya', 'vai', 'brother', 'bro', '\u09ad\u09be\u0987\u09af\u09bc\u09be', '\u09ad\u09be\u0987'],
    ['apu', 'apa', 'sister', 'sis', 'didi', '\u0986\u09aa\u09c1', '\u0986\u09aa\u09be', '\u09a6\u09bf\u09a6\u09bf'],
    ['nanu', 'nani', '\u09a8\u09be\u09a8\u09c1', '\u09a8\u09be\u09a8\u09bf'],
    ['dadu', 'dadi', '\u09a6\u09be\u09a6\u09c1', '\u09a6\u09be\u09a6\u09bf'],
    ['wife', 'bou', 'biwi', '\u09ac\u0989', '\u09ac\u09cc', '\u09b8\u09cd\u09a4\u09cd\u09b0\u09c0'],
    ['husband', 'jamai', '\u09b8\u09cd\u09ac\u09be\u09ae\u09c0', '\u099c\u09be\u09ae\u09be\u0987'],
  ];

  static List<String> expand(String spoken) {
    final n = VaText.norm(spoken);
    for (final group in relations) {
      if (group.any((w) => VaText.norm(w) == n)) {
        return group.map(VaText.norm).toList();
      }
    }
    return [n];
  }

  /// Score phonebook entries [{name, phone}] for a spoken name, best first.
  /// Only entries scoring >= 50 are returned.
  static List<Map<String, String>> rank(
      String spoken, List<Map<String, String>> contacts) {
    final keys = expand(spoken);
    final scored = <(int, Map<String, String>)>[];
    for (final c in contacts) {
      final name = VaText.norm(c['name'] ?? '');
      if (name.isEmpty) continue;
      var s = 0;
      for (final k in keys) {
        if (name == k) {
          s = s < 100 ? 100 : s;
        } else if (name.split(' ').contains(k)) {
          s = s < 85 ? 85 : s;
        } else if (name.startsWith(k) && k.length >= 3) {
          s = s < 70 ? 70 : s;
        } else {
          final ks = VaText.skeleton(k);
          if (ks.length >= 2) {
            final parts = name.split(' ').map(VaText.skeleton).toList();
            if (VaText.skeleton(name) == ks) {
              s = s < 65 ? 65 : s;
            } else if (parts.contains(ks)) {
              s = s < 55 ? 55 : s;
            }
          }
        }
      }
      if (s >= 50) scored.add((s, c));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return scored.map((e) => e.$2).toList();
  }
}

/// Yes / no for spoken confirmations.
class VaYesNo {
  VaYesNo._();
  static const _no = [
    'no', 'nope', 'cancel', 'stop', "don't", 'dont', 'wait', 'not now',
    'na', 'naa', 'nah', 'thak', 'bad dao', 'dorkar nai', 'lagbe na',
    '\u09a8\u09be', '\u09a5\u09be\u0995', '\u09ac\u09be\u09a6 \u09a6\u09be\u0993', '\u09a6\u09b0\u0995\u09be\u09b0 \u09a8\u09c7\u0987', '\u09ac\u09be\u09a4\u09bf\u09b2', '\u09b2\u09be\u0997\u09ac\u09c7 \u09a8\u09be',
  ];
  static const _yes = [
    'yes', 'yeah', 'yep', 'yup', 'sure', 'ok', 'okay', 'do it', 'confirm',
    'go ahead', 'call', 'send',
    'ha', 'haa', 'hae', 'hya', 'hmm', 'ji', 'jee', 'thik ache', 'koro', 'dao',
    '\u09b9\u09cd\u09af\u09be\u0981', '\u09b9\u09cd\u09af\u09be', '\u09b9\u09be\u0981', '\u099c\u09bf', '\u099c\u09cd\u09ac\u09bf', '\u09a0\u09bf\u0995 \u0986\u099b\u09c7', '\u0995\u09b0\u09cb', '\u09a6\u09be\u0993', '\u09b9\u09c1\u09ae',
  ];

  /// true = yes, false = no, null = unclear.
  static bool? classify(String text) {
    final n = VaText.norm(text);
    if (n.isEmpty) return null;
    if (_no.any((w) => VaText.has(n, VaText.norm(w)))) return false;
    if (_yes.any((w) => VaText.has(n, VaText.norm(w)))) return true;
    return null;
  }
}

/// The parser.
class VoiceIntentParser {
  VoiceIntentParser._();

  static List<String> _n(List<String> l) => l.map(VaText.norm).toList();

  static final _open = _n([
    'open', 'launch', 'start', 'go to', 'show', 'show me', 'take me to',
    'kholo', 'khulo', 'khol', 'open koro', 'dekhao', 'chalu koro',
    '\u0996\u09cb\u09b2\u09cb', '\u0996\u09c1\u09b2\u09cb', '\u0996\u09cb\u09b2', '\u0993\u09aa\u09c7\u09a8', '\u09a6\u09c7\u0996\u09be\u0993', '\u099a\u09be\u09b2\u09c1 \u0995\u09b0\u09cb',
  ]);

  // Always SOS.
  static final _sos = _n([
    'sos', 'save me', 'i am in danger', "i'm in danger", 'call for help',
    'bachao', 'bachaw', 'amake bachao', 'bipode achi', 'ami bipode',
    '\u09ac\u09be\u0981\u099a\u09be\u0993', '\u09ac\u09be\u099a\u09be\u0993', '\u098f\u09b8\u0993\u098f\u09b8', '\u0986\u09ae\u09bf \u09ac\u09bf\u09aa\u09a6\u09c7', '\u09ac\u09bf\u09aa\u09a6\u09c7 \u0986\u099b\u09bf',
  ]);
  // SOS only when that is (nearly) all that was said: "help!", "emergency".
  static final _sosShort = _n([
    'help', 'help me', 'emergency', 'help koro', 'bipod',
    '\u09ac\u09bf\u09aa\u09a6', '\u099c\u09b0\u09c1\u09b0\u09bf', '\u0987\u09ae\u09be\u09b0\u09cd\u099c\u09c7\u09a8\u09cd\u09b8\u09bf', '\u09b8\u09be\u09b9\u09be\u09af\u09cd\u09af', '\u09b8\u09be\u09b9\u09be\u09af\u09cd\u09af \u0995\u09b0\u09cb',
  ]);

  static final _remind = _n([
    'remind me', 'remind', 'reminder', 'set a reminder',
    'mone koriye', 'mone koriyo', 'mone korio', 'mone koraio', 'mone korabe',
    'mone koraben',
    '\u09ae\u09a8\u09c7 \u0995\u09b0\u09bf\u09af\u09bc\u09c7', '\u09ae\u09a8\u09c7 \u0995\u09b0\u09be\u0993', '\u09ae\u09a8\u09c7 \u0995\u09b0\u09bf\u0993', '\u09ae\u09a8\u09c7 \u0995\u09b0\u09be\u09ac\u09c7', '\u09b0\u09bf\u09ae\u09be\u0987\u09a8\u09cd\u09a1\u09be\u09b0',
  ]);

  static final _timer = _n(['timer', 'countdown', '\u099f\u09be\u0987\u09ae\u09be\u09b0']);

  static final _alarm = _n([
    'alarm', 'wake me up', 'wake me', 'alarm dao', 'jagiye dio',
    'jagiye diyo', 'jagiye dao', 'ghum theke tulo', 'ghum theke tuliyo',
    '\u0985\u09cd\u09af\u09be\u09b2\u09be\u09b0\u09cd\u09ae', '\u098f\u09b2\u09be\u09b0\u09cd\u09ae', '\u099c\u09be\u0997\u09bf\u09af\u09bc\u09c7 \u09a6\u09bf\u0993', '\u099c\u09be\u0997\u09bf\u09af\u09bc\u09c7 \u09a6\u09be\u0993', '\u0998\u09c1\u09ae \u09a5\u09c7\u0995\u09c7 \u09a4\u09c1\u09b2\u09cb',
    '\u0998\u09c1\u09ae \u09a5\u09c7\u0995\u09c7 \u09a4\u09c1\u09b2\u09c7 \u09a6\u09bf\u0993',
  ]);

  static final _torch = _n([
    'torch', 'flashlight', 'flash light', 'flash', 'torch light', 'torchlight',
    '\u099f\u09b0\u09cd\u099a', '\u099f\u09b0\u09cd\u099a\u09b2\u09be\u0987\u099f', '\u09ab\u09cd\u09b2\u09cd\u09af\u09be\u09b6\u09b2\u09be\u0987\u099f', '\u09ab\u09cd\u09b2\u09be\u09b6\u09b2\u09be\u0987\u099f', '\u09ab\u09cd\u09b2\u09cd\u09af\u09be\u09b6',
  ]);
  static final _off = _n([
    'off', 'turn off', 'switch off', 'disable', 'stop',
    'bondho', 'bondo', 'bondho koro', 'nibhao', 'nevao', 'nebhao',
    '\u09ac\u09a8\u09cd\u09a7', '\u09a8\u09bf\u09ad\u09be\u0993', '\u09a8\u09c7\u09ad\u09be\u0993', '\u0985\u09ab',
  ]);

  static final _expenseWords = _n([
    'spent', 'spend', 'expense', 'paid', 'bought', 'cost',
    'khoroch', 'khorch', 'khorcha', 'kinlam', 'kinechi', 'khoroch holo',
    '\u0996\u09b0\u099a', '\u0996\u09b0\u099a\u09be', '\u0995\u09bf\u09a8\u09b2\u09be\u09ae', '\u0995\u09bf\u09a8\u09c7\u099b\u09bf',
  ]);
  static final _currency = _n(['taka', 'tk', 'bdt', '\u099f\u09be\u0995\u09be', '\u09f3']);
  static final _notExpense = _n([
    'send', 'pathao', 'dhar', 'lent', 'borrow', 'borrowed', 'income',
    'salary', 'got', 'received', 'pelam', 'paisi', 'beton', 'dilam',
    '\u09aa\u09be\u09a0\u09be\u0993', '\u09a7\u09be\u09b0', '\u09aa\u09c7\u09b2\u09be\u09ae', '\u09ac\u09c7\u09a4\u09a8', '\u0986\u09af\u09bc', '\u09a6\u09bf\u09b2\u09be\u09ae',
  ]);

  static final _whatsapp = _n([
    'whatsapp', 'whats app', '\u09b9\u09cb\u09af\u09bc\u09be\u099f\u09b8\u0985\u09cd\u09af\u09be\u09aa', '\u09b9\u09cb\u09af\u09bc\u09be\u099f\u09b8\u09cd\u09af\u09be\u09aa', '\u09b9\u09cb\u09af\u09bc\u09be\u099f\u09b8\u0986\u09aa',
  ]);
  static final _sms = _n([
    'sms', 'text', 'message', 'send a message', 'send message', 'send sms',
    'send a text', 'msg',
    'likho', 'lekho', 'likhe dao', 'message dao', 'message koro', 'sms koro',
    'sms dao', 'janiye dao', 'bole dao',
    '\u09b2\u09bf\u0996\u09cb', '\u09b2\u09c7\u0996\u09cb', '\u09b2\u09bf\u0996\u09c7 \u09a6\u09be\u0993', '\u09ae\u09c7\u09b8\u09c7\u099c', '\u098f\u09b8\u098f\u09ae\u098f\u09b8', '\u09ae\u09cd\u09af\u09be\u09b8\u09c7\u099c', '\u099c\u09be\u09a8\u09bf\u09af\u09bc\u09c7 \u09a6\u09be\u0993',
    '\u09ac\u09b2\u09c7 \u09a6\u09be\u0993',
  ]);
  static final _noteWords = _n([
    'note', 'notes', 'diary', 'list', '\u09a8\u09cb\u099f', '\u09a1\u09be\u09af\u09bc\u09c7\u09b0\u09bf', '\u09a4\u09be\u09b2\u09bf\u0995\u09be',
  ]);
  static final _call = _n([
    'call', 'phone', 'dial', 'ring', 'make a call', 'calling',
    'call dao', 'call koro', 'phone dao', 'phone koro', 'kol dao', 'fon dao',
    '\u0995\u09b2', '\u09ab\u09cb\u09a8', '\u09a1\u09be\u09af\u09bc\u09be\u09b2', '\u0995\u09b2 \u09a6\u09be\u0993', '\u0995\u09b2 \u0995\u09b0\u09cb', '\u09ab\u09cb\u09a8 \u09a6\u09be\u0993', '\u09ab\u09cb\u09a8 \u0995\u09b0\u09cb',
  ]);

  static final _music = _n([
    'youtube', 'you tube', '\u0987\u0989\u099f\u09bf\u0989\u09ac',
  ]);
  static final _musicWords = _n([
    'song', 'songs', 'music', 'gaan', 'gan', '\u0997\u09be\u09a8', 'video',
  ]);
  static final _playVerbs = _n([
    'play', 'chalao', 'bajao', 'shunao', 'sunao',
    '\u099a\u09be\u09b2\u09be\u0993', '\u09ac\u09be\u099c\u09be\u0993', '\u09b6\u09cb\u09a8\u09be\u0993', '\u09b6\u09c1\u09a8\u09be\u0993', '\u099b\u09be\u09a1\u09bc\u09cb',
  ]);

  static final _navigate = _n([
    'navigate to', 'navigate', 'directions to', 'directions', 'direction',
    'take me to', 'route to', 'how do i go to', 'how to go to', 'how to get to',
    'jabo kivabe', 'jabo kibhabe', 'kivabe jabo', 'kibhabe jabo',
    'rasta dekhao', 'niye cholo', 'navigate koro', 'e jabo', 'te jabo',
    '\u0995\u09c0\u09ad\u09be\u09ac\u09c7 \u09af\u09be\u09ac', '\u0995\u09bf\u09ad\u09be\u09ac\u09c7 \u09af\u09be\u09ac', '\u0995\u09c0\u09ad\u09be\u09ac\u09c7 \u09af\u09be\u09ac\u09cb', '\u0995\u09bf\u09ad\u09be\u09ac\u09c7 \u09af\u09be\u09ac\u09cb', '\u09b0\u09be\u09b8\u09cd\u09a4\u09be \u09a6\u09c7\u0996\u09be\u0993',
    '\u09a8\u09bf\u09af\u09bc\u09c7 \u099a\u09b2\u09cb', '\u09af\u09be\u0993\u09af\u09bc\u09be\u09b0 \u09aa\u09a5', '\u09a8\u09c7\u09ad\u09bf\u0997\u09c7\u099f', '\u09af\u09be\u09ac \u0995\u09bf\u09ad\u09be\u09ac\u09c7', '\u09af\u09be\u09ac\u09cb \u0995\u09bf\u09ad\u09be\u09ac\u09c7',
  ]);
  static final _nearby = _n([
    'near me', 'nearby', 'nearest', 'close by', 'around me',
    'kache', 'kachakachi', 'ashepashe', 'kase',
    '\u0995\u09be\u099b\u09c7', '\u0995\u09be\u099b\u09be\u0995\u09be\u099b\u09bf', '\u0986\u09b6\u09c7\u09aa\u09be\u09b6\u09c7', '\u09a8\u09bf\u0995\u099f\u09a4\u09ae',
  ]);
  static final _mapWord = _n([
    'on map', 'on the map', 'in maps', 'on maps', 'map e', 'map',
    '\u09ae\u09cd\u09af\u09be\u09aa\u09c7', '\u09ae\u09cd\u09af\u09be\u09aa',
  ]);

  // Words that carry no meaning for target/message extraction.
  static final _fillers = {
    ...[
      'please', 'pls', 'plz', 'now', 'a', 'an', 'the', 'to', 'for', 'my', 'me',
      'can', 'you', 'could', 'would', 'hey', 'assisto', 'ok', 'okay', 'set',
      'ekta', 'akta', 'ektu', 'ke', 'k', 're', 'ta', 'ti', 'e', 'te',
      'er', 'r', 'amar', 'amake', 'koro', 'dao', 'den', 'diyo', 'dio', 'je',
      '\u098f\u0995\u099f\u09c1', '\u098f\u0995\u099f\u09be', '\u09aa\u09cd\u09b2\u09bf\u099c', '\u098f\u0996\u09a8', '\u0986\u09ae\u09be\u09b0', '\u0986\u09ae\u09be\u0995\u09c7', '\u0995\u09b0\u09cb', '\u09a6\u09be\u0993', '\u09a6\u09bf\u09a8',
      '\u09af\u09c7', '\u09a4\u09cb', '\u098f',
    ].map(VaText.norm)
  };

  static final _honorific = _n([
    'bhai', 'vai', 'bhaiya', 'apa', 'apu', 'sir', 'madam', 'uncle', 'aunty',
    'khala', 'mama', 'chacha', 'fufu',
    '\u09ad\u09be\u0987', '\u09ad\u09be\u0987\u09af\u09bc\u09be', '\u0986\u09aa\u09be', '\u0986\u09aa\u09c1', '\u09b8\u09cd\u09af\u09be\u09b0', '\u09ae\u09cd\u09af\u09be\u09a1\u09be\u09ae', '\u0986\u0999\u09cd\u0995\u09c7\u09b2', '\u0996\u09be\u09b2\u09be', '\u09ae\u09be\u09ae\u09be',
    '\u099a\u09be\u099a\u09be', '\u09ab\u09c1\u09ab\u09c1',
  ]);

  static final _tomorrow = _n([
    'tomorrow', 'kal', 'kalke', 'agamikal', '\u0995\u09be\u09b2', '\u0995\u09be\u09b2\u0995\u09c7', '\u0986\u0997\u09be\u09ae\u09c0\u0995\u09be\u09b2',
  ]);
  static final _am = _n([
    'am', 'a.m.', 'a m', 'morning', 'sokal', 'sokale', 'bhor', 'bhore',
    '\u09b8\u0995\u09be\u09b2', '\u09b8\u0995\u09be\u09b2\u09c7', '\u09ad\u09cb\u09b0', '\u09ad\u09cb\u09b0\u09c7',
  ]);
  static final _pm = _n([
    'pm', 'p.m.', 'p m', 'afternoon', 'evening', 'tonight', 'night', 'noon',
    'dupur', 'dupure', 'bikal', 'bikel', 'bikele', 'sondha', 'sondhya',
    'sondhay', 'rat', 'raat', 'rate', 'raate',
    '\u09a6\u09c1\u09aa\u09c1\u09b0', '\u09a6\u09c1\u09aa\u09c1\u09b0\u09c7', '\u09ac\u09bf\u0995\u09be\u09b2', '\u09ac\u09bf\u0995\u09c7\u09b2', '\u09ac\u09bf\u0995\u09c7\u09b2\u09c7', '\u09b8\u09a8\u09cd\u09a7\u09cd\u09af\u09be', '\u09b8\u09a8\u09cd\u09a7\u09cd\u09af\u09be\u09af\u09bc', '\u09b0\u09be\u09a4',
    '\u09b0\u09be\u09a4\u09c7',
  ]);
  static final _night = _n(['night', 'rat', 'raat', 'rate', 'raate', '\u09b0\u09be\u09a4', '\u09b0\u09be\u09a4\u09c7']);

  /// Parse an utterance. [detectRoute] (optional) maps an English
  /// "open X" phrase to an in-app ChatNav route.
  static VaIntent parse(String raw, {String? Function(String)? detectRoute}) {
    final text = VaText.norm(raw);
    if (text.isEmpty) return VaIntent(VaAction.unknown, raw);
    final hasOpen = VaText.any(text, _open);

    // 1. SOS beats everything (unless it is "open the emergency screen").
    if (!hasOpen &&
        (VaText.any(text, _sos) ||
            (VaText.any(text, _sosShort) &&
                text.split(' ').length <= 3 &&
                !VaText.any(text, _call)))) {
      return VaIntent(VaAction.sos, raw);
    }

    // 2. Reminder (before call: "remind me at 5 to call mum").
    if (VaText.any(text, _remind)) {
      final clock = extractClock(text);
      var title = VaText.strip(text, [..._remind, ..._timeWords]);
      if (clock != null && clock.span.isNotEmpty) {
        title = title.replaceFirst(clock.span, ' ');
      }
      title = VaText.trimFillers(title, {
        ..._fillers,
        ...['at', 'on', 'that', 'about', 'dite', 'diyo', 'dio', 'to', 'of',
          'koriye', 'ke'].map(VaText.norm),
        VaText.norm('\u09a6\u09bf\u0993'), VaText.norm('\u09a6\u09bf\u09ac\u09c7'), VaText.norm('\u099f\u09be\u09af\u09bc'),
        VaText.norm('\u099f\u09be\u09b0'), VaText.norm('\u099f\u09be'), VaText.norm('\u0995\u09c7'),
      });
      if (hasOpen && clock == null && title.isEmpty) {
        return VaIntent(VaAction.openScreen, raw, route: 'reminders');
      }
      return VaIntent(VaAction.reminder, raw,
          clock: clock, message: title.isEmpty ? null : title);
    }

    // 3. Timer.
    if (VaText.any(text, _timer)) {
      return VaIntent(VaAction.timer, raw, seconds: extractSeconds(text));
    }

    // 4. Alarm.
    if (VaText.any(text, _alarm)) {
      return VaIntent(VaAction.alarm, raw, clock: extractClock(text));
    }

    // 5. Torch.
    if (VaText.any(text, _torch)) {
      return VaIntent(
          VaText.any(text, _off) ? VaAction.torchOff : VaAction.torchOn, raw);
    }

    // 6. Expense: an amount AND (an expense word OR "taka").
    final amt = VaText.amount(text);
    if (amt != null &&
        (VaText.any(text, _expenseWords) || VaText.any(text, _currency)) &&
        !VaText.any(text, _notExpense)) {
      return _expense(raw, text, amt);
    }

    // 7. WhatsApp.
    if (VaText.any(text, _whatsapp)) {
      final rest = VaText.strip(text, [..._whatsapp, ..._sms, ..._open]);
      final tm = _targetAndMessage(rest, english: !VaText.isBangla(text));
      if (hasOpen && tm.$1 == null && tm.$2 == null) {
        return VaIntent(VaAction.openApp, raw, target: 'whatsapp');
      }
      return VaIntent(VaAction.whatsapp, raw, target: tm.$1, message: tm.$2);
    }

    // 8. SMS / text.
    if (VaText.any(text, _sms) && !hasOpen && !VaText.any(text, _noteWords)) {
      final rest = VaText.strip(text, _sms);
      final tm = _targetAndMessage(rest, english: !VaText.isBangla(text));
      if (tm.$1 != null || tm.$2 != null) {
        return VaIntent(VaAction.sms, raw, target: tm.$1, message: tm.$2);
      }
    }

    // 8b. Navigation (before call: a place name may start like a call word).
    if (VaText.any(text, _navigate)) {
      var place = VaText.strip(text, _navigate);
      place = VaText.dropWords(place, {
        ..._fillers,
        ...['how', 'do', 'i', 'go', 'get', 'route', 'way'].map(VaText.norm),
      });
      if (place.isNotEmpty) {
        return VaIntent(VaAction.navigate, raw, target: _stripLocative(place));
      }
    }
    // 9. Call.
    if (VaText.any(text, _call) && !(hasOpen && _isOnly(text, _call, _open))) {
      var who = VaText.strip(text, _call);
      who = _cleanName(who);
      return VaIntent(VaAction.call, raw, target: who.isEmpty ? null : who);
    }

    // 10. YouTube / music.
    final yt = VaText.any(text, _music);
    final musicish = VaText.any(text, _musicWords) ||
        (VaText.any(text, _playVerbs) && !VaText.any(text, _torch));
    if (yt || musicish) {
      var q = VaText.strip(text, [..._music, ..._playVerbs, ..._open]);
      q = VaText.dropWords(q, {
        ..._fillers,
        ...['on', 'in', 'some', 'something', 'theke', 'a'].map(VaText.norm),
        VaText.norm('\u09a5\u09c7\u0995\u09c7'),
        VaText.norm('\u0995\u09bf\u099b\u09c1'),
      });
      if (yt && hasOpen && q.isEmpty) {
        return VaIntent(VaAction.openApp, raw, target: 'youtube');
      }
      if (yt || musicish) {
        return VaIntent(VaAction.youtube, raw, target: q.isEmpty ? null : q);
      }
    }

    // 11. Nearby / map search.
    final nearby = VaText.any(text, _nearby);
    if (nearby || VaText.any(text, _mapWord)) {
      var q = VaText.strip(text, [..._nearby, ..._mapWord, ..._open]);
      q = VaText.dropWords(q, {
        ..._fillers,
        ...['where', 'is', 'find', 'search', 'show', 'khujo', 'khoj', 'ache',
          'koi', 'kothay'].map(VaText.norm),
        VaText.norm('\u0996\u09cb\u0981\u099c\u09cb'), VaText.norm('\u0996\u09c1\u0981\u099c\u09c7'), VaText.norm('\u0986\u099b\u09c7'),
        VaText.norm('\u0995\u09cb\u09a5\u09be\u09af\u09bc'),
      });
      if (q.isNotEmpty) {
        return VaIntent(VaAction.mapSearch, raw,
            target: nearby ? '$q near me' : q);
      }
    }

    // 13. Open an in-app screen or a phone app.
    final route = detectRoute?.call(raw) ?? detectRoute?.call(text);
    if (route != null) {
      return VaIntent(VaAction.openScreen, raw, route: route);
    }
    if (hasOpen) {
      var name = VaText.strip(text, _open);
      name = VaText.dropWords(name, {
        ..._fillers,
        ...['app', 'the app', 'application'].map(VaText.norm),
        VaText.norm('\u0985\u09cd\u09af\u09be\u09aa'),
      });
      if (name.isNotEmpty) {
        return VaIntent(VaAction.openApp, raw, target: name);
      }
    }

    return VaIntent(VaAction.unknown, raw);
  }

  // ---- helpers -------------------------------------------------------------

  static VaIntent _expense(String raw, String text, num amt) {
    final cat = VaText.categoryOf(text);
    var note = VaText.strip(text, [..._expenseWords, ..._currency]);
    note = note.replaceAll(RegExp(r'\d[\d,]*(?:\.\d+)?\s*(k\b)?'), ' ');
    note = VaText.strip(note, _n(['hajar', 'hazar', 'thousand', '\u09b9\u09be\u099c\u09be\u09b0']));
    note = VaText.dropWords(note, {
      ..._fillers,
      ...['on', 'in', 'for', 'of', 'holo', 'korlam', 'korechi', 'i', 'today',
        'aj', 'ajke'].map(VaText.norm),
      VaText.norm('\u09b9\u09b2\u09cb'), VaText.norm('\u0995\u09b0\u09b2\u09be\u09ae'), VaText.norm('\u0995\u09b0\u09c7\u099b\u09bf'),
      VaText.norm('\u0986\u099c'), VaText.norm('\u0986\u099c\u0995\u09c7'), VaText.norm('\u09ac\u09be\u09ac\u09a6'),
    });
    return VaIntent(VaAction.expense, raw,
        amount: amt, category: cat, message: note.isEmpty ? null : note);
  }

  /// True when text is only call-words + open-words ("open phone").
  static bool _isOnly(String text, List<String> a, List<String> b) =>
      VaText.dropWords(VaText.strip(text, [...a, ...b]), _fillers).isEmpty;

  static String _stripKe(String w) {
    final ke = VaText.norm('\u0995\u09c7'); // Bangla "ke"
    final re = VaText.norm('\u09b0\u09c7'); // Bangla "re"
    if (VaText.isBangla(w)) {
      for (final s in [ke, re]) {
        if (w.endsWith(s) && w.runes.length > s.runes.length + 1) {
          return w.substring(0, w.length - s.length);
        }
      }
      return w;
    }
    if (w.length > 4 && (w.endsWith('ke') || w.endsWith('re'))) {
      return w.substring(0, w.length - 2);
    }
    return w;
  }

  static String _cleanName(String s) {
    final words = s
        .split(' ')
        .where((w) => w.isNotEmpty && !_fillers.contains(w))
        .map(_stripKe)
        .where((w) => w.isNotEmpty && !_fillers.contains(w))
        .toList();
    return words.join(' ').trim();
  }

  static String _stripLocative(String place) {
    // Bangla locative "-e"/"-te" on the last word is fine for a maps search;
    // Banglish "dhanmondi te" already lost "te" as a filler.
    return place.trim();
  }

  /// Find the person ("X ke" / "to X" / first word) and the message body.
  static (String?, String?) _targetAndMessage(String rest,
      {required bool english}) {
    final words = rest.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return (null, null);
    final ke = VaText.norm('\u0995\u09c7');
    // a) "<name> ke ..." / "<name>ke ..." / Bangla "<name>-ke ..."
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      final standalone = (w == 'ke' || w == ke) && i > 0;
      final attached = !standalone &&
          ((VaText.isBangla(w) &&
                  w.endsWith(ke) &&
                  w.runes.length > ke.runes.length + 1) ||
              (!VaText.isBangla(w) && w.length > 4 && w.endsWith('ke')));
      if (standalone || attached) {
        final end = standalone ? i - 1 : i;
        var start = end;
        final first = _stripKe(words[end]);
        if (end > 0 && _honorific.contains(first)) start = end - 1;
        final nameWords = [
          for (var j = start; j <= end; j++) _stripKe(words[j]),
        ];
        final msgWords = [
          ...words.sublist(0, start),
          ...words.sublist(i + 1),
        ];
        return (_nz(nameWords.join(' ')), _nz(_cleanMsg(msgWords.join(' '))));
      }
    }
    // b) English "... to <name> saying/that <msg>"
    final toIdx = words.indexOf('to');
    if (english && toIdx >= 0 && toIdx + 1 < words.length) {
      var end = toIdx + 1;
      if (end + 1 < words.length && _honorific.contains(words[end + 1])) {
        end++;
      }
      final name = words.sublist(toIdx + 1, end + 1).join(' ');
      final msg = [...words.sublist(0, toIdx), ...words.sublist(end + 1)];
      return (_nz(name), _nz(_cleanMsg(msg.join(' '))));
    }
    // c) English "text rakib i am coming": first word is the name.
    if (english) {
      var end = 0;
      if (words.length > 1 && _honorific.contains(words[1])) end = 1;
      final name = words.sublist(0, end + 1).join(' ');
      return (_nz(name), _nz(_cleanMsg(words.sublist(end + 1).join(' '))));
    }
    return (null, _nz(_cleanMsg(rest)));
  }

  static String _cleanMsg(String s) {
    var out = s.trim();
    final leads = _n([
      'saying', 'that', 'je', '\u09af\u09c7', 'bolo', '\u09ac\u09b2\u09cb', 'dao', 'koro', 'send',
      'pathao', '\u09a6\u09be\u0993', '\u0995\u09b0\u09cb', '\u09aa\u09be\u09a0\u09be\u0993', 'a', 'the', 'e', 'te', 'ekta', 'to',
    ]);
    var changed = true;
    while (changed) {
      changed = false;
      for (final lead in leads) {
        if (out == lead) return '';
        if (out.startsWith('$lead ')) {
          out = out.substring(lead.length).trim();
          changed = true;
        }
      }
    }
    for (final tail in _n(['koro', 'dao', 'pathao', 'please', '\u0995\u09b0\u09cb', '\u09a6\u09be\u0993', '\u09aa\u09be\u09a0\u09be\u0993'])) {
      if (out.endsWith(' $tail')) {
        out = out.substring(0, out.length - tail.length).trim();
      }
    }
    return out;
  }

  static String? _nz(String s) => s.trim().isEmpty ? null : s.trim();

  // ---- time --------------------------------------------------------------

  static final _timeWords = _n([
    ..._tomorrowRaw, 'today', 'aj', 'ajke', '\u0986\u099c', '\u0986\u099c\u0995\u09c7',
    'morning', 'evening', 'night', 'afternoon', 'tonight', 'noon',
    'sokal', 'sokale', 'bhor', 'dupur', 'dupure', 'bikal', 'bikel', 'bikele',
    'sondha', 'sondhya', 'rat', 'raat', 'rate',
    '\u09b8\u0995\u09be\u09b2', '\u09b8\u0995\u09be\u09b2\u09c7', '\u09ad\u09cb\u09b0', '\u09a6\u09c1\u09aa\u09c1\u09b0', '\u09a6\u09c1\u09aa\u09c1\u09b0\u09c7', '\u09ac\u09bf\u0995\u09be\u09b2', '\u09ac\u09bf\u0995\u09c7\u09b2', '\u09ac\u09bf\u0995\u09c7\u09b2\u09c7',
    '\u09b8\u09a8\u09cd\u09a7\u09cd\u09af\u09be', '\u09b8\u09a8\u09cd\u09a7\u09cd\u09af\u09be\u09af\u09bc', '\u09b0\u09be\u09a4', '\u09b0\u09be\u09a4\u09c7',
  ]);
  static const _tomorrowRaw = [
    'tomorrow', 'kal', 'kalke', 'agamikal', '\u0995\u09be\u09b2', '\u0995\u09be\u09b2\u0995\u09c7', '\u0986\u0997\u09be\u09ae\u09c0\u0995\u09be\u09b2',
  ];

  static final RegExp _clockRx = RegExp(
      r'(?:(sare|sharhe|sowa|pone|' +
          VaText.norm('\u09b8\u09be\u09a1\u09bc\u09c7') +
          '|' +
          VaText.norm('\u09b8\u09cb\u09af\u09bc\u09be') +
          '|' +
          VaText.norm('\u09aa\u09cc\u09a8\u09c7') +
          r')\s*)?(?<!\d)(\d{1,2})(?!\d)(?:\s*[:.]\s*(\d{2}))?\s*'
              r'(a\.?\s?m\.?|p\.?\s?m\.?|o\s?clock|baje|tay|tar|tai|ta\b|' +
          VaText.norm('\u099f\u09be\u09af\u09bc') +
          '|' +
          VaText.norm('\u099f\u09be\u09b0') +
          '|' +
          VaText.norm('\u099f\u09be') +
          '|' +
          VaText.norm('\u09ac\u09be\u099c\u09c7') +
          r')?(?:\s*(\d{1,2})\s*(?:min|minute|minit|' +
          VaText.norm('\u09ae\u09bf\u09a8\u09bf\u099f') +
          r'))?');

  /// Extract a clock time from normalised text, or null.
  static VaClock? extractClock(String text) {
    final t = VaText.norm(text);
    VaClock? best;
    for (final m in _clockRx.allMatches(t)) {
      final pre = m.group(1);
      final hStr = m.group(2);
      final mStr = m.group(3);
      final suf = m.group(4);
      final mins2 = m.group(5);
      if (hStr == null) continue;
      // A bare number counts as a time only with a suffix, a minute part, or
      // a preceding "at/for/@" — otherwise "500 taka" would be a time.
      final idx = m.start + m.group(0)!.indexOf(hStr, pre?.length ?? 0);
      final before = t.substring(0, idx).trimRight();
      final atWord = before.endsWith(' at') ||
          before == 'at' ||
          before.endsWith(' for') ||
          before == 'for' ||
          before.endsWith('@');
      final hasDaypart = VaText.any(t, _am) || VaText.any(t, _pm);
      if (suf == null && mStr == null && pre == null && !atWord) {
        // "sokal 7" / "rat 10" — a day part right before the number.
        final dp = [..._am, ..._pm].any((w) => before.endsWith(w));
        if (!(dp && hasDaypart)) continue;
      }
      // Skip money / durations: "500 taka", "10 minute".
      final after = t.substring(idx + hStr.length).trimLeft();
      if (suf == null &&
          mStr == null &&
          RegExp(r'^(taka|tk|min|minute|sec|second|hour|ghonta|' +
                  VaText.norm('\u099f\u09be\u0995\u09be') +
                  '|' +
                  VaText.norm('\u09ae\u09bf\u09a8\u09bf\u099f') +
                  '|' +
                  VaText.norm('\u0998\u09a3\u09cd\u099f\u09be') +
                  ')')
              .hasMatch(after)) {
        continue;
      }
      var h = int.parse(hStr);
      var mi = mStr != null ? int.parse(mStr) : 0;
      if (mins2 != null) mi = int.parse(mins2);
      if (h > 23 || mi > 59) continue;
      var known = false;
      final s = (suf ?? '').replaceAll(RegExp(r'[\s.]'), '');
      if (s.startsWith('pm') || s == 'pm') {
        if (h < 12) h += 12;
        known = true;
      } else if (s.startsWith('am')) {
        if (h == 12) h = 0;
        known = true;
      }
      if (pre != null) {
        final p = pre;
        if (p == 'sare' || p == 'sharhe' || p == VaText.norm('\u09b8\u09be\u09a1\u09bc\u09c7')) {
          mi = 30;
        } else if (p == 'sowa' || p == VaText.norm('\u09b8\u09cb\u09af\u09bc\u09be')) {
          mi = 15;
        } else {
          // pone = quarter to
          h = h - 1 < 0 ? 23 : h - 1;
          mi = 45;
        }
      }
      if (!known && h <= 12) {
        if (VaText.any(t, _pm)) {
          final night = VaText.any(t, _night);
          if (night && (h <= 4 || h == 12)) {
            // "rat 2 ta" = 2 AM; "rat 12 ta" = midnight
            h = h == 12 ? 0 : h;
          } else if (h < 12) {
            h += 12;
          }
          known = true;
        } else if (VaText.any(t, _am)) {
          if (h == 12) h = 0;
          known = true;
        }
      }
      best = VaClock(h, mi,
          ampmKnown: known || h > 12 || h == 0,
          tomorrow: VaText.any(t, _tomorrow),
          span: m.group(0)!.trim());
      break;
    }
    return best;
  }

  /// Total seconds in "5 minute", "1 ghonta 30 min", "adha ghonta", or null.
  static int? extractSeconds(String text) {
    final t = VaText.norm(text);
    var total = 0;
    var found = false;
    final rx = RegExp(r'(\d{1,4})\s*(seconds?|secs?|s\b|' +
        VaText.norm('\u09b8\u09c7\u0995\u09c7\u09a8\u09cd\u09a1') +
        r'|minutes?|mins?|minit|m\b|' +
        VaText.norm('\u09ae\u09bf\u09a8\u09bf\u099f') +
        r'|hours?|hrs?|h\b|ghonta|ghanta|' +
        VaText.norm('\u0998\u09a3\u09cd\u099f\u09be') +
        '|' +
        VaText.norm('\u0998\u09a8\u09cd\u099f\u09be') +
        ')');
    for (final m in rx.allMatches(t)) {
      final n = int.parse(m.group(1)!);
      final u = m.group(2)!;
      found = true;
      if (u.startsWith('s') || u.startsWith(VaText.norm('\u09b8\u09c7'))) {
        total += n;
      } else if (u.startsWith('h') ||
          u.startsWith('gh') ||
          u.startsWith(VaText.norm('\u0998'))) {
        total += n * 3600;
      } else {
        total += n * 60;
      }
    }
    if (!found &&
        VaText.any(t, _n(['half an hour', 'adha ghonta', '\u0986\u09a7\u09be \u0998\u09a3\u09cd\u099f\u09be', '\u0986\u09a7 \u0998\u09a3\u09cd\u099f\u09be']))) {
      return 1800;
    }
    return found && total > 0 ? total : null;
  }
}
