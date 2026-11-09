import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// fcsos — the two people who get an SMS from MY SIM when an SOS cannot reach
/// the server (no internet). Kept ON THE PHONE (it must work offline). The
/// SMS app opens with both numbers and the text (location link included);
/// the user taps Send — Assisto never sends SMS itself (no SEND_SMS
/// permission, Play SMS policy). SMS cost is the user's normal SIM rate.
class SosSmsContact {
  const SosSmsContact(this.name, this.phone);
  final String name;
  final String phone;

  Map<String, String> toJson() => {'name': name, 'phone': phone};

  static SosSmsContact? fromJson(Object? j) {
    if (j is! Map) return null;
    final p = cleanPhone('${j['phone'] ?? ''}');
    if (p.isEmpty) return null;
    return SosSmsContact('${j['name'] ?? ''}'.trim(), p);
  }
}

/// Digits and a leading + only (what an sms: URI accepts everywhere).
String cleanPhone(String s) {
  final t = s.trim();
  final d = t.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length < 3 || d.length > 15) return '';
  return t.startsWith('+') ? '+$d' : d;
}

class SosSmsStore {
  static const key = 'fcsos_sms_contacts_v1';
  static const max = 2;

  static Future<List<SosSmsContact>> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(key);
      if (raw == null || raw.isEmpty) return const [];
      final l = jsonDecode(raw);
      if (l is! List) return const [];
      return [
        for (final x in l.map(SosSmsContact.fromJson))
          if (x != null) x
      ].take(max).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(List<SosSmsContact> c) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final seen = <String>{};
      final keep = [
        for (final x in c)
          if (seen.add(x.phone)) x
      ].take(max).map((e) => e.toJson()).toList();
      await sp.setString(key, jsonEncode(keep));
    } catch (_) {
      // best effort: the SOS screen still offers manual entry
    }
  }
}

/// `sms:` URI for several numbers with a pre-filled body. Android accepts
/// ';' between numbers on most SMS apps; Samsung's app also understands it.
Uri sosSmsUri(List<String> phones, String body) {
  final nums = phones.map(cleanPhone).where((p) => p.isNotEmpty).join(';');
  return Uri.parse('sms:$nums?body=${Uri.encodeComponent(body)}');
}

/// The SMS text: who, what, where (map link when known), Assisto-free text so
/// it reads well on any phone.
String sosSmsBody(String Function(String link) withLink, String noLink,
    (double, double)? pos) {
  if (pos == null) return noLink;
  return withLink('https://maps.google.com/?q=${pos.$1.toStringAsFixed(6)},'
      '${pos.$2.toStringAsFixed(6)}');
}
