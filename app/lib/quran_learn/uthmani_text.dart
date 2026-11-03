// quranread: the Tanzil Quran Text (Uthmani, v1.1), Copyright (C) 2007-2026
// Tanzil Project, CC BY 3.0 - bundled VERBATIM (gzip only, notice kept) as
// assets/quran/quran-uthmani.txt.gz. Tanzil's text follows the Medina mushaf
// (King Fahd Complex), riwayah Hafs 'an 'Asim. We only READ it: a lesson item
// names sura:ayah (+ a word range) and we show those words as they are.
// Attribution ("Tanzil Project" + tanzil.net link) is on the lessons' source
// page (QuranLearnAboutScreen).
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'qaida_model.dart';

class UthmaniText {
  static const asset = 'assets/quran/quran-uthmani.txt.gz';
  static const totalAyas = 6236;

  final Map<int, List<String>> _ayat; // key sura*1000+ayah -> words
  final String notice;
  UthmaniText._(this._ayat, this.notice);

  static Future<UthmaniText>? _loading;

  /// Loads (once) the bundled file. Throws on a broken asset; callers show
  /// an error state with a retry, never invented text.
  static Future<UthmaniText> load() =>
      _loading ??= _load().catchError((Object e) {
        _loading = null;
        throw e;
      });

  static Future<UthmaniText> _load() async {
    final bd = await rootBundle.load(asset);
    final bytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    final raw = utf8.decode(gzip.decode(bytes));
    return compute(parse, raw);
  }

  /// Parse the decompressed Tanzil "sura|ayah|text" file.
  static UthmaniText parse(String raw) {
    final m = <int, List<String>>{};
    final notice = StringBuffer();
    for (final line in const LineSplitter().convert(raw)) {
      if (line.startsWith('#')) {
        notice.writeln(line.replaceFirst(RegExp(r'^#\s?'), ''));
        continue;
      }
      final p1 = line.indexOf('|');
      final p2 = p1 < 0 ? -1 : line.indexOf('|', p1 + 1);
      if (p2 < 0) continue;
      final s = int.tryParse(line.substring(0, p1));
      final a = int.tryParse(line.substring(p1 + 1, p2));
      if (s == null || a == null) continue;
      m[s * 1000 + a] = line.substring(p2 + 1).split(' ');
    }
    if (m.length != totalAyas) {
      throw FormatException('uthmani: expected $totalAyas ayas, got ${m.length}');
    }
    return UthmaniText._(m, notice.toString().trim());
  }

  /// The words of [r] joined by spaces, or null when the reference is out of
  /// range (never a guess).
  String? text(QlRef r) {
    final w = _ayat[r.sura * 1000 + r.ayah];
    if (w == null) return null;
    final f = r.from ?? 0;
    final t = r.to ?? w.length - 1;
    if (f < 0 || t >= w.length || f > t) return null;
    return w.sublist(f, t + 1).join(' ');
  }

  /// Tests / gallery: use an already-parsed copy of the real file.
  @visibleForTesting
  static void debugPreload(UthmaniText? d) =>
      _loading = d == null ? null : Future.value(d);
}
