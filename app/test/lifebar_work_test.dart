// lifebar (board group 18 "work"): pure-logic checks for the fixes —
// mock interview "Next" always moves + Bangla answers get real keyword
// coverage; quick tools tone follows the INPUT's language; blog writer's
// Bangla picker gives a Bangla draft; strict Bangla digits; safe ids.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/blog_writer_screen.dart';
import 'package:assisto/screens/mock_interview_screen.dart';
import 'package:assisto/widgets/local_digits.dart';
import 'package:assisto/widgets/quick_tools_engine.dart';

void main() {
  final bn = lookupAppLocalizations(const Locale('bn'));
  final en = lookupAppLocalizations(const Locale('en'));

  group('mock interview', () {
    test('Next moves even when no feedback was asked for', () {
      final first = miNextAfter('job', const [], null);
      expect(first, 'job_tellme');
      final second = miNextAfter('job', const [], first);
      expect(second, isNot(first));
      // every question seen -> still moves (wraps to the one after current)
      final all = ['job_tellme', 'job_strength', 'job_weakness', 'job_why', 'job_fiveyears'];
      expect(miNextAfter('job', all, 'job_fiveyears'), 'job_tellme');
      expect(miNextAfter('job', all, 'job_tellme'), 'job_strength');
    });

    test('a Bangla answer gets real coverage from the bn keyword bank', () {
      final kw = miParseKwBank(bn.lbWMiKwBank);
      expect(kw['experience'], isNotEmpty);
      const answer = 'আমার তিন বছরের অভিজ্ঞতা আছে। আমার দক্ষতা হলো হিসাব রাখা, '
          'আর আমার লক্ষ্য এই পদে ভালো কাজ করা।';
      final withBank = miCoverage('job_tellme', answer, kw);
      final noBank = miCoverage('job_tellme', answer, const {});
      expect(noBank.coverage, 0);
      expect(withBank.coverage, greaterThanOrEqualTo(0.6));
      // missing chips are shown in the UI language
      for (final k in withBank.missing) {
        expect(miKwLabel(kw, k), isNot(k));
      }
    });

    test('English bank value is a no-op; English answers still work', () {
      expect(miParseKwBank(en.lbWMiKwBank), isEmpty);
      final r = miCoverage('job_tellme',
          'I have experience and skill for this role and a clear goal.', const {});
      expect(r.coverage, greaterThan(0.5));
    });

    test('ids from the server may be int, num or String', () {
      expect(miSafeId(5), 5);
      expect(miSafeId(5.0), 5);
      expect(miSafeId('7'), 7);
      expect(miSafeId('x'), isNull);
      expect(miSafeId(null), isNull);
    });
  });

  group('quick tools tone', () {
    test('Bangla input gets the Bangla wrapper, English keeps English', () {
      const bnText = 'কালকে মিটিং হবে';
      expect(quickHasBangla(bnText), isTrue);
      expect(quickHasBangla('meeting tomorrow'), isFalse);
      final r = changeToneQuick(bnText,
          tone: 'polite', templates: {'polite': bn.lbWQtTonePoliteBn});
      expect(r.result, contains(bnText));
      expect(r.result, isNot(contains('Could you please')));
      final e = changeToneQuick('meeting tomorrow', tone: 'polite');
      expect(e.result, startsWith('Could you please'));
    });

    test('a template without the @@ marker falls back safely', () {
      final r = changeToneQuick('hello', tone: 'firmer', templates: {'firmer': 'broken'});
      expect(r.result, contains('hello'));
    });
  });

  group('blog writer language', () {
    test('Bangla pick -> Bangla draft with the topic', () {
      final d = assembleBlog('blog', 'ঈদের বাজার', lang: 'bn', bnPack: bn.lbWBwBnPack);
      expect(d.text, contains('ঈদের বাজার'));
      expect(d.text, isNot(contains('Background')));
      expect(d.sections.length, 3);
    });

    test('script + caption + empty topic in Bangla', () {
      final s = assembleBlog('script', '', length: 'short', lang: 'bn', bnPack: bn.lbWBwBnPack);
      expect(s.text, isNot(contains('this topic')));
      expect(s.sections.length,
          assembleBlog('script', 'x', length: 'short').sections.length);
      final c = assembleBlog('caption', 'x', lang: 'bn', bnPack: bn.lbWBwBnPack);
      expect(c.sections.length, 2);
    });

    test('a malformed pack falls back to English', () {
      final d = assembleBlog('blog', 'tea', lang: 'bn', bnPack: '-');
      expect(d.text, contains('Background'));
    });
  });

  test('strict digits', () {
    expect(toLocalDigits('৳1,250.50', true), '৳১,২৫০.৫০');
    expect(toLocalDigits('12', false), '12');
  });
}
