// p3faith: the REAL bundled Quran files, read synchronously for tests and
// the screenshot gallery (no invented text; fake-async friendly).
import 'dart:convert';
import 'dart:io';

import 'package:assisto/quran/quran_store.dart';

QuranData? _cached;

QuranData realQuranData() => _cached ??= QuranStore.fromRaw(
      File('assets/quran/quran_meta.json').readAsStringSync(),
      utf8.decode(gzip.decode(
          File('assets/quran/quran-simple.txt.gz').readAsBytesSync())),
      utf8.decode(gzip.decode(
          File('assets/quran/en.pickthall.txt.gz').readAsBytesSync())),
      uthmaniRaw: utf8.decode(gzip.decode(
          File('assets/quran/quran-uthmani.txt.gz').readAsBytesSync())),
    );

/// Make QuranStore.load() return the real data immediately.
void preloadRealQuran() => QuranStore.debugPreload(realQuranData());
