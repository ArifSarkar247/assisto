/// p3life — pure, deterministic helpers shared by Travel planner, Wedding &
/// events and Ride & food (owner PART 3, 3 Nov). No Flutter imports so the
/// unit tests run fast and the math is identical online and offline.
///
/// Money is INTEGER POISHA everywhere (৳1 = 100 poisha), like the existing
/// wedding/travel/split engines.
library;

/// Transport modes for a trip leg. Train opens our own Train tracker.
const List<String> kLegModes = ['train', 'bus', 'launch', 'air', 'car', 'other'];

/// Travel document kinds.
const List<String> kDocKinds = ['nid', 'passport', 'visa', 'ticket', 'insurance', 'other'];

/// Official sources only (owner rule: destination/booking info only from
/// official sources, cited). We OPEN these sites; we never copy their content
/// or show a price we cannot verify.
class OfficialSource {
  final String id;
  final String name; // proper name, same in bn/en
  final String url;
  const OfficialSource(this.id, this.name, this.url);
}

const OfficialSource kSrcRailway = OfficialSource(
    'railway', 'Bangladesh Railway e-ticket', 'https://eticket.railway.gov.bd/');
const OfficialSource kSrcBiwtc = OfficialSource(
    'biwtc', 'BIWTC (Bangladesh Inland Water Transport Corporation)', 'https://www.biwtc.gov.bd/');
const OfficialSource kSrcBiman = OfficialSource(
    'biman', 'Biman Bangladesh Airlines', 'https://www.biman-airlines.com/');
const OfficialSource kSrcBrtc = OfficialSource(
    'brtc', 'BRTC (Bangladesh Road Transport Corporation)', 'https://www.brtc.gov.bd/');
const OfficialSource kSrcTourismBoard = OfficialSource(
    'tourism_board', 'Bangladesh Tourism Board', 'https://tourismboard.gov.bd/');
const OfficialSource kSrcParjatan = OfficialSource(
    'parjatan', 'Bangladesh Parjatan Corporation', 'https://parjatan.gov.bd/');

/// Destination information sources (cited by name on screen).
const List<OfficialSource> kTourismSources = [kSrcTourismBoard, kSrcParjatan];

/// The official ticket/info site for a leg's mode, or null (car/other).
OfficialSource? officialForMode(String mode) {
  switch (mode) {
    case 'train':
      return kSrcRailway;
    case 'launch':
      return kSrcBiwtc;
    case 'air':
      return kSrcBiman;
    case 'bus':
      return kSrcBrtc;
    default:
      return null;
  }
}

String normMode(Object? m) {
  final s = '${m ?? ''}';
  return kLegModes.contains(s) ? s : 'other';
}

DateTime? parseIsoDate(Object? s) {
  final t = '${s ?? ''}'.trim();
  if (t.length < 10) return null;
  final d = DateTime.tryParse(t.substring(0, 10));
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Legs sorted by date then time; undated legs last.
List<Map<String, dynamic>> sortLegs(List<Map<String, dynamic>> legs) {
  String k(Map<String, dynamic> r) {
    final d = '${r['date'] ?? ''}';
    return '${d.isEmpty ? '9999-99-99' : d} ${r['time'] ?? '99:99'}';
  }

  final out = [...legs];
  out.sort((a, b) => k(a).compareTo(k(b)));
  return out;
}

/// Document status vs. the trip:
///   nodate      — no expiry written (we cannot judge; honest)
///   expired     — already expired today
///   before_trip — expires before the trip ends (red)
///   passport_6m — a passport valid < 6 months after the trip ends (amber;
///                 many countries require 6 months — check the embassy)
///   ok
String docStatus(Map<String, dynamic> doc,
    {DateTime? tripEnd, required DateTime today}) {
  final exp = parseIsoDate(doc['expiry']);
  if (exp == null) return 'nodate';
  final t = DateTime(today.year, today.month, today.day);
  if (exp.isBefore(t)) return 'expired';
  if (tripEnd != null && exp.isBefore(tripEnd)) return 'before_trip';
  if (doc['kind'] == 'passport') {
    final ref = tripEnd ?? t;
    final six = DateTime(ref.year, ref.month + 6, ref.day);
    if (exp.isBefore(six)) return 'passport_6m';
  }
  return 'ok';
}

/// Bangla keyboard digits (U+09E6..U+09EF) -> ASCII digits.
String asciiDigits(String raw) {
  var s = raw;
  for (var i = 0; i < 10; i++) {
    s = s.replaceAll(String.fromCharCode(0x09E6 + i), '$i');
  }
  return s;
}

/// "1,500.50" / Bangla digits / "৳ 200" -> poisha; null when not a number.
int? parsePoisha(String raw) {
  var s = asciiDigits(raw.trim());
  s = s.replaceAll(RegExp(r'[৳,\s]'), '').replaceAll('Tk', '').replaceAll('tk', '');
  if (s.isEmpty) return null;
  final v = double.tryParse(s);
  if (v == null || v < 0 || v > 1e11) return null;
  return (v * 100).round();
}

int poishaOf(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse('${v ?? ''}') ?? 0;
}

/// ৳ with South-Asian grouping (1,50,000); whole taka unless there are paisa.
String fmtTaka(int poisha) {
  final neg = poisha < 0;
  final p = poisha.abs();
  final whole = p ~/ 100, frac = p % 100;
  final s = whole.toString();
  String g;
  if (s.length <= 3) {
    g = s;
  } else {
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    g = '${parts.join(',')},$last3';
  }
  final f = frac == 0 ? '' : '.${frac.toString().padLeft(2, '0')}';
  return '${neg ? '-' : ''}৳$g$f';
}

/// Vendors: total quoted, paid, and still due (never negative per vendor).
({int quoted, int paid, int due}) vendorTotals(List<Map<String, dynamic>> rows) {
  var q = 0, p = 0, d = 0;
  for (final r in rows) {
    final qq = poishaOf(r['quote']), pp = poishaOf(r['paid']);
    q += qq;
    p += pp;
    if (qq > pp) d += qq - pp;
  }
  return (quoted: q, paid: p, due: d);
}

/// Gifts: count, cash total, and how many still need a thank-you.
({int count, int cash, int toThank}) giftTotals(List<Map<String, dynamic>> rows) {
  var c = 0, t = 0;
  for (final r in rows) {
    c += poishaOf(r['amount']);
    if (r['thanked'] != true) t++;
  }
  return (count: rows.length, cash: c, toThank: t);
}

/// Food log for one month ('YYYY-MM'): total spent, order count, budget left
/// (null when no budget is set), and per-provider totals (largest first).
({int spent, int orders, int? left, List<MapEntry<String, int>> byProvider})
    foodMonth(List<Map<String, dynamic>> orders, String month, int? budget) {
  var spent = 0, n = 0;
  final by = <String, int>{};
  for (final o in orders) {
    if (!'${o['date'] ?? ''}'.startsWith(month)) continue;
    final a = poishaOf(o['amount']);
    spent += a;
    n++;
    final p = '${o['provider'] ?? ''}'.trim();
    final key = p.isEmpty ? 'other' : p;
    by[key] = (by[key] ?? 0) + a;
  }
  final list = by.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return (
    spent: spent,
    orders: n,
    left: budget == null || budget <= 0 ? null : budget - spent,
    byProvider: list,
  );
}

String monthKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

/// The scope tag the shared Expense-split screen uses for one trip's own
/// people/expenses (so trip costs never mix with other split groups).
String tripSplitScope(int tripId) => 'trip:$tripId';

/// Rows that belong to a split scope (null scope = the general, unscoped
/// group — exactly the rows saved before scopes existed).
bool inSplitScope(Map<String, dynamic> row, String? scope) {
  final s = row['scope'];
  if (scope == null || scope.isEmpty) return s == null || '$s'.isEmpty;
  return '$s' == scope;
}
