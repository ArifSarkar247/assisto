/// train-app (Train Tracker V2, layer 4): read the 16318 SMS REPLY the user
/// pasted or shared into Assisto. Assisto never reads SMS (no READ_SMS) —
/// the user chooses to give us this one text. The server parses it again
/// (authoritative); this on-phone parse shows a preview at once and works
/// offline (the report is queued and sent when the internet returns).
///
/// Tolerant by design: Bangla or English, any order, Bangla digits, 12 h or
/// 24 h times, "Late 0:15" / "Late 15 min" / the Bangla "15 minutes late".
class TrainSmsReply {
  final String no;
  final String? stationId, stationBn, stationEn;

  /// reached | left | at (the reply only names the place)
  final String kind;
  final DateTime? at;
  final int? lateMin;
  const TrainSmsReply(
      {required this.no,
      this.stationId,
      this.stationBn,
      this.stationEn,
      this.kind = 'at',
      this.at,
      this.lateMin});

  bool get useful => stationId != null;

  String stationName(bool bn) {
    final b = stationBn ?? '', e = stationEn ?? '';
    return bn && b.isNotEmpty ? b : (e.isNotEmpty ? e : b);
  }
}

/// A station the parser can recognise (from the offline timetable or the
/// train's line): id + names.
class TrainSmsStation {
  final String id, bn, en;
  const TrainSmsStation(this.id, this.bn, this.en);
}

/// Bangla digits -> ASCII, and the 3 precomposed Bangla nukta letters
/// (U+09DC/09DD/09DF) -> letter + nukta, so typed and pasted text match.
String trainAsciiDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x09E6 && r <= 0x09EF) {
      b.writeCharCode(0x30 + r - 0x09E6);
    } else if (r == 0x09DC || r == 0x09DD || r == 0x09DF) {
      b.writeCharCode(r == 0x09DC ? 0x09A1 : (r == 0x09DD ? 0x09A2 : 0x09AF));
      b.writeCharCode(0x09BC);
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

String _norm(String s) =>
    trainAsciiDigits(s).toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true), ' ').trim();

final _timeRe = RegExp(r'(?<!\d)(\d{1,2})[:.](\d{2})(?!\d)\s*(am|pm|a\.m\.|p\.m\.)?', caseSensitive: false);

/// Returns null when the text has no train number or names no known
/// station and no time — nothing we could place on the line.
TrainSmsReply? parseTrain16318(String raw,
    {List<TrainSmsStation> stations = const [], String? expectNo, DateTime? now}) {
  final text = trainAsciiDigits(raw).replaceAll(' ', ' ');
  if (text.trim().isEmpty) return null;
  final clock = now ?? DateTime.now();
  final lower = text.toLowerCase();

  // ---- late: "Late 0:15" | "late by 15 min" | "15 min late" | Bangla "15 minutes late"
  // (Bangla words are written as \u escapes: no Bangla glyphs in Dart source)
  int? late;
  final l1 = RegExp(r'late\D{0,12}(\d{1,2}):(\d{2})').firstMatch(lower);
  final l2 = RegExp(r'late\D{0,12}(\d{1,3})\s*(min|mins|minutes|m\b|\u09ae\u09bf)').firstMatch(lower);
  final l3 = RegExp(r'(\d{1,3})\s*(min|mins|minutes|\u09ae\u09bf\u09a8\u09bf\u099f)\.?\s*(late|\u09a6\u09c7\u09b0\u09bf|\u09ac\u09bf\u09b2\u09ae\u09cd\u09ac)').firstMatch(lower);
  final l4 = RegExp(r'(\u09a6\u09c7\u09b0\u09bf|\u09ac\u09bf\u09b2\u09ae\u09cd\u09ac)\D{0,6}(\d{1,3})').firstMatch(lower);
  if (l1 != null) {
    late = int.parse(l1.group(1)!) * 60 + int.parse(l1.group(2)!);
  } else if (l2 != null) {
    late = int.parse(l2.group(1)!);
  } else if (l3 != null) {
    late = int.parse(l3.group(1)!);
  } else if (l4 != null) {
    late = int.parse(l4.group(2)!);
  }
  if (RegExp(r'on\s*time|\u09b8\u09ae\u09af\u09bc\u09ae\u09a4\u09cb|\u09b8\u09ae\u09af\u09bc\u09ae\u09a4').hasMatch(lower)) late ??= 0;

  // ---- times (the first one that is not the late figure)
  DateTime? at;
  for (final m in _timeRe.allMatches(lower)) {
    if (l1 != null && m.start >= l1.start && m.end <= l1.end) continue;
    var h = int.parse(m.group(1)!);
    final mi = int.parse(m.group(2)!);
    if (h > 23 || mi > 59) continue;
    final ap = (m.group(3) ?? '').replaceAll('.', '');
    if (ap == 'pm' && h < 12) h += 12;
    if (ap == 'am' && h == 12) h = 0;
    var d = DateTime(clock.year, clock.month, clock.day, h, mi);
    // a reply is about the recent past: 2 h+ "in the future" = yesterday
    if (d.difference(clock).inMinutes > 120) d = d.subtract(const Duration(days: 1));
    at = d;
    break;
  }

  // ---- train number: "TR 701", "Train No. 701", "(701)", else a lone 3-4 digit number
  String? no;
  final n1 = RegExp(r'(?:\btr\b|train\s*(?:no\.?|number)?|\u099f\u09cd\u09b0\u09c7\u09a8\s*(?:\u09a8\u0982|\u09a8\u09ae\u09cd\u09ac\u09b0)?)\s*[:#.\-]?\s*(\d{2,4})\b')
      .firstMatch(lower);
  if (n1 != null) no = n1.group(1);
  if (no == null) {
    final n2 = RegExp(r'\((\d{2,4})\)').firstMatch(lower);
    no = n2?.group(1);
  }
  if (no == null) {
    for (final m in RegExp(r'(?<![\d:.])(\d{3,4})(?![\d:.])').allMatches(lower)) {
      no = m.group(1);
      break;
    }
  }
  no ??= expectNo;
  if (no == null) return null;
  no = '${int.tryParse(no) ?? no}';

  // ---- what happened
  var kind = 'at';
  if (RegExp(r'arriv|reach|\barr\b|\u09aa\u09cc\u0981\u099b|\u09aa\u09cc\u099b|\u098f\u09b8\u09c7\u099b\u09c7').hasMatch(lower)) kind = 'reached';
  if (RegExp(r'depart|\bleft\b|\bdep\b|left from|passed|\u099b\u09c7\u09a1\u09bc\u09c7|\u099b\u09c7\u09a1\u09bc\u09c7\u099b\u09c7|\u099b\u09be\u09a1\u09bc|\u09a4\u09cd\u09af\u09be\u0997|\u0985\u09a4\u09bf\u0995\u09cd\u09b0\u09ae').hasMatch(lower)) {
    kind = 'left';
  }

  // ---- station: the longest known name found in the text
  final nt = ' ${_norm(text)} ';
  TrainSmsStation? best;
  var bestLen = 0;
  for (final s in stations) {
    for (final name in [s.en, s.bn]) {
      final n = _norm(name);
      if (n.length < 3) continue;
      // match the whole name, or its first word when it is distinctive
      // ("Cumilla" in "CUMILLA RLY STN")
      if (nt.contains(' $n ') && n.length > bestLen) {
        best = s;
        bestLen = n.length;
      }
    }
  }
  if (best == null) {
    for (final s in stations) {
      final first = _norm(s.en).split(' ').first;
      if (first.length >= 5 && nt.contains(' $first ') && first.length > bestLen) {
        best = s;
        bestLen = first.length;
      }
    }
  }
  final r = TrainSmsReply(
      no: no,
      stationId: best?.id,
      stationBn: best?.bn,
      stationEn: best?.en,
      kind: kind,
      at: at,
      lateMin: late);
  if (!r.useful && at == null) return null;
  return r;
}
