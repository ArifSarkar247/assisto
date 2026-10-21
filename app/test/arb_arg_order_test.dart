// Regression guard for a systemic bug found in Premium QA (a1): gen-l10n
// builds each method's parameter list in the ARB *metadata* placeholder
// order, not the order the placeholders appear in the text. 48 strings had
// those two orders differ, and almost every call site passed arguments in
// text order -> values silently swapped on screen (Ramadan "30/0", daily brief
// "50 of 4 done (2%)", wellness "8 of 3 glasses", ...).
//
// 1) Pins the signature order of keys whose call sites were fixed, so a later
//    metadata reorder breaks this test instead of the UI.
// 2) Fails when a NEW key with a mismatched order appears (fix the metadata
//    order in the ARB proposal, or update the known list + check call sites).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/l10n/app_localizations.dart';

const _knownMismatched = {
  'fallCountdownValue', 'jobsSalaryRange', 'plMsgReceivable', 'plMsgPayable',
  'dictShareTemplate', 'ramadanFastingCount', 'disFamilyInArea',
  'disShareHotlines', 'refCardCaption', 'updateVersionLine', 'paVisSummary',
  'paAuditSummary', 'splitPaidBySplit', 'samityRecordPayoutBody',
  'rentStatusCounts', 'rentBillPaid', 'studentCourseMath',
  'studentCreditsSummary', 'studentFormulaBody', 'weddingEstVsAct',
  'probashiRateOnDate', 'staffDaysPresent', 'wellGlassesOf', 'wellHoursOf',
  'wellTrendAverages', 'spendObsTopCategory', 'spendObsMomUp',
  'spendObsMomDown', 'spendObsMoverUp', 'spendObsMoverDown',
  'spendObsOverBudget', 'tvItinerarySummary', 'tvBudgetLine', 'dbCompletion',
  'paCeTplAcknowledge', 'paCeTplDecline', 'paCeTplSchedule',
  'paCeTplFollowup', 'paMinActionCount', 'shootChecklistProgress',
  'paBizEstVsAct', 'moodEnergyValue', 'moodTrendSummary', 'camSentPartial',
  'storageUsedOf', 'adRewardedTodayCap', 'pnlRevCost', 'pnlBreakEvenBody',
};

void main() {
  test('signature order of fixed call sites is pinned', () {
    final t = lookupAppLocalizations(const Locale('en'));
    expect(t.ramadanFastingCount(30, 4), '4/30'); // (total, kept)
    expect(t.dbCompletion(2, 50, 4), contains('2 of 4'));
    expect(t.dbCompletion(2, 50, 4), contains('50%')); // (done, pct, total)
    expect(t.wellGlassesOf(8, 3).indexOf('3') < t.wellGlassesOf(8, 3).indexOf('8'), isTrue); // (goal, value)
    expect(t.moodEnergyValue(5, 3).indexOf('3') < t.moodEnergyValue(5, 3).indexOf('5'), isTrue); // (max, value)
    expect(t.paMinActionCount('D', 'O').indexOf('O') < t.paMinActionCount('D', 'O').indexOf('D'), isTrue);
    expect(t.paCeTplDecline('C', 'SENDER', 'SUBJ'), allOf(startsWith('Dear C'), contains('SUBJ'), endsWith('SENDER')));
  });

  test('no NEW ARB key has placeholder metadata out of text order', () {
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    final bad = <String>[];
    en.forEach((k, v) {
      if (k.startsWith('@') || v is! String) return;
      final meta = (en['@$k'] as Map?)?['placeholders'] as Map?;
      if (meta == null || meta.length < 2) return;
      final declared = meta.keys.cast<String>().toList();
      final appear = <String>[];
      for (final m in RegExp(r'\{(\w+)').allMatches(v)) {
        final p = m.group(1)!;
        if (declared.contains(p) && !appear.contains(p)) appear.add(p);
      }
      if (appear.join(',') != declared.join(',') && !_knownMismatched.contains(k)) {
        bad.add('$k declared=$declared text=$appear');
      }
    });
    expect(bad, isEmpty, reason: 'call sites pass args in TEXT order; keep metadata in the same order');
  });
}
