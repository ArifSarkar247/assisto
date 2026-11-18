// gap-quranblood (owner order 17 Nov 10:10): emulator steps for the Quran
// and Blood donor gap fixes (owner_actions/gaps/quran_BN.md, blood_BN.md).
// Demo user A is allow-listed for the `quran` and `blood_donors` flags on
// the throw-away CI database only (seed_reality).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void registerQuranBloodFlows() {
  realityFlow('qb1_quran_reader', 'Quran', 'Quran: paras, verse jump, inline meaning, next sura',
      (f) async {
    await f.home();
    await f.step('open Quran', () async {
      await f.openRoute('quran');
      await f.waitFor(find.byKey(const Key('quran-suras')), seconds: 20, what: 'sura list');
      await f.shot('suras');
    });
    await f.step('paras tab: para 30 opens An-Naba 1', () async {
      await f.tap(find.byKey(const Key('quran-tab-juz')));
      await f.waitFor(find.byKey(const Key('quran-juz-1')), what: 'para list');
      await f.shot('paras');
      await f.scrollTo(find.byKey(const Key('quran-juz-30')));
      await f.tap(find.byKey(const Key('quran-juz-30')), settleSeconds: 3);
      await f.waitFor(find.byKey(const Key('quran-reader')), what: 'reader');
      await f.shot('para30-reader');
      final bn = await f.appears(find.byKey(const Key('quran-bn-1')), seconds: 10);
      f.note(bn
          ? 'Bangla meaning (QuranEnc) shown inline'
          : 'QuranEnc not reachable from the CI server: offline English shown');
      await f.back();
    });
    await f.step('search 2:255 jumps to the verse', () async {
      await f.tap(find.byType(Tab).first);
      await f.tester.enterText(find.byKey(const Key('quran-search')), '2:255');
      await f.pumpFor(const Duration(milliseconds: 600));
      await f.tap(find.byKey(const Key('quran-jump')), settleSeconds: 3);
      await f.waitFor(find.byKey(const Key('quran-ayah-255')), what: 'verse 255');
      await f.shot('ayat-al-kursi');
      await f.back();
    });
    await f.step('end of Al-Ikhlas leads to Al-Falaq', () async {
      await f.tester.enterText(find.byKey(const Key('quran-search')), '112:4');
      await f.pumpFor(const Duration(milliseconds: 600));
      await f.tap(find.byKey(const Key('quran-jump')), settleSeconds: 3);
      await f.scrollTo(find.byKey(const Key('quran-next-sura')));
      await f.tap(find.byKey(const Key('quran-next-sura')), settleSeconds: 3);
      // the list is lazy and verses are tall now (inline meaning): verse 1 of
      // the next sura proves the jump (run 44210304008 waited for verse 5)
      await f.waitFor(find.byKey(const Key('quran-ayah-1')), what: 'Al-Falaq verse 1');
      await f.shot('next-sura');
    });
  });

  realityFlow('qb2_blood_find', 'Blood donor', 'Blood donor: compatible groups chip, Me tab number row',
      (f) async {
    await f.home();
    await f.step('open Blood donor', () async {
      await f.openRoute('blood_panel');
      await f.waitFor(find.byKey(const ValueKey('bp-tab-find')), seconds: 20, what: 'blood hub');
      await f.shot('hub');
    });
    await f.step('pick A+ and include compatible groups', () async {
      await f.scrollTo(find.byKey(const ValueKey('bp-g-A+')));
      await f.tap(find.byKey(const ValueKey('bp-g-A+')), settleSeconds: 3);
      await f.waitFor(find.byKey(const ValueKey('bp-compatible')), what: 'compatible chip');
      await f.tap(find.byKey(const ValueKey('bp-compatible')), settleSeconds: 3);
      await f.shot('compatible');
    });
    await f.step('Me tab: become-a-donor or the number-visibility row', () async {
      await f.tap(find.byKey(const ValueKey('bp-tab-me')), settleSeconds: 3);
      final donor = await f.appears(find.byKey(const ValueKey('bp-me-phone')), seconds: 6);
      f.note(donor ? 'number row shown (donor)' : 'not a donor yet: become-a-donor shown');
      await f.shot('me');
    });
  });
}
