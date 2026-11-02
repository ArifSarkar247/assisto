// lifebar (board groups 17 + 18): shared pieces — Bangla digits helper,
// Unseen Bangladesh places fully Bangla in a Bangla UI, watcher/exam push
// routes, the exam multi-student list kept on the phone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/widgets/local_digits.dart';
import 'package:assisto/widgets/unseen_data.dart';
import 'package:assisto/widgets/unseen_l10n.dart';

final _bnLetter = RegExp(r'[ঀ-৿]');
final _latin = RegExp(r'[A-Za-z0-9]');

void main() {
  test('toLocalDigits: Bangla digits only in a Bangla UI', () {
    expect(toLocalDigits('৳1,250.50', true), '৳১,২৫০.৫০');
    expect(toLocalDigits('৳1,250.50', false), '৳1,250.50');
    expect(toLocalDigits('', true), '');
    expect(_latin.hasMatch(toLocalDigits('0123456789', true)), isFalse);
  });

  test('every curated Unseen place has Bangla name/route/tip (no English in bn)', () {
    final bn = lookupAppLocalizations(const Locale('bn'));
    final en = lookupAppLocalizations(const Locale('en'));
    expect(kUwTranslatedIds.length, kDestinations.length);
    for (final d in kDestinations) {
      final x = uwText(bn, d, true);
      for (final s in [x.name, x.best, x.how, x.near, x.tip]) {
        expect(_bnLetter.hasMatch(s), isTrue, reason: '${d.id}: "$s"');
        expect(RegExp(r'[A-Za-z]').hasMatch(s), isFalse, reason: '${d.id}: "$s"');
      }
      // English UI keeps the data text
      expect(uwText(en, d, false).name, d.name);
    }
  });

  test('Bangla search finds a place by its Bangla name', () {
    final bn = lookupAppLocalizations(const Locale('bn'));
    final sajek = kDestinations.firstWhere((d) => d.id == 'sajek');
    final q = uwText(bn, sajek, true).name;
    final r = searchDestinations(query: q, extraHay: (d) {
      final x = uwText(bn, d, true);
      return '${x.name} ${x.how} ${x.near}';
    });
    expect(r.map((d) => d.id), contains('sajek'));
  });

  test('watch-feed and exam pushes open their screens', () {
    expect(PushRouting.routeMap['watch_feed'], 'watch_feed');
    expect(PushRouting.routeMap['exam'], 'exam');
    final p = PushPayload.fromData({'kind': 'reminder', 'route': 'exam'});
    expect(PushRouting.targetFor(p)?.chatNavRoute, 'exam');
  });
}
