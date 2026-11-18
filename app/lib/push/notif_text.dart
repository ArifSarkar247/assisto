/// notif-nine: shade text helpers (pure; any isolate).
///
/// Bangla shade text uses Bangla digits (০-৯): a count formatted from an int
/// placeholder came out as "3টি চ্যাট" before.
String notifDigits(String lang, String s) {
  if (lang != 'bn') return s;
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r >= 0x30 && r <= 0x39 ? 0x09E6 + (r - 0x30) : r);
  }
  return b.toString();
}
