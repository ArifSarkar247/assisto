// budrem: gallery states for test/screenshots_test.dart (and therefore the
// a11y guideline sweep + dead-button sweep) — Budget and Remittance.
// The fixture family is Rahim's; the sender is his brother Karim.
import 'package:flutter/material.dart';

import 'package:assisto/screens/remittance/remit_entry_screen.dart';
import 'package:assisto/screens/remittance/remit_parser.dart';
import 'package:assisto/screens/remittance/remit_report_screen.dart';
import 'package:assisto/screens/remittance/remit_source.dart';
import 'package:assisto/screens/remittance/remittance_screen.dart';

import 'budrem_fakes.dart';

final _now = DateTime(2026, 10, 20);

String budremSaid(String lang) =>
    lang == 'bn' ? 'ভাই ২০ হাজার টাকা পাঠাইছে বিকাশে' : 'Bhai sent 20 thousand taka by bKash';

Widget _entry(FakeRemit f, {RemitDraft? draft, String? said, Map<String, dynamic>? entry}) => RemitEntryScreen(
    source: f,
    queue: RemitQueue(f),
    draft: draft,
    said: said,
    entry: entry,
    members: const [
      {'id': 7, 'name': 'Karim', 'relation': 'brother'},
      {'id': 8, 'name': 'Salma', 'relation': 'sister'},
    ]);

final Map<String, Widget Function(String)> budremShots = {
  'rmt_first_run': (_) => RemittanceScreen(source: FakeRemit('empty'), now: _now),
  'rmt_month': (_) => RemittanceScreen(source: FakeRemit('data'), guide: false, now: _now),
  'rmt_month_missing': (_) => RemittanceScreen(source: FakeRemit('missing'), guide: false, now: _now),
  'rmt_budget': (_) => RemittanceScreen(source: FakeRemit('data'), guide: false, now: _now, initialTab: 1),
  'rmt_budget_empty': (_) => RemittanceScreen(source: FakeRemit('empty'), guide: false, now: _now, initialTab: 1),
  'rmt_year': (_) => RemittanceScreen(source: FakeRemit('data'), guide: false, now: _now, initialTab: 2),
  'rmt_offline': (_) => RemittanceScreen(source: FakeRemit('offline'), guide: false, now: _now),
  'rmt_feature_off': (_) => RemittanceScreen(source: FakeRemit('off'), guide: false, now: _now),
  'rmt_load_error': (_) => RemittanceScreen(source: FakeRemit('fail'), guide: false, now: _now),
  'rmt_entry_new': (_) => _entry(FakeRemit('data')),
  'rmt_entry_quick': (lang) => _entry(FakeRemit('data'),
      draft: RemitParser.parse(budremSaid(lang), now: _now), said: budremSaid(lang)),
  'rmt_entry_edit': (_) => _entry(FakeRemit('data'), entry: FakeRemit('data').entries.first),
  'rmt_report': (lang) => RemitReportScreen(source: FakeRemit('data'), month: FakeRemit.month, initialLang: lang),
};
