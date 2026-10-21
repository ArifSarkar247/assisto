// a6 scope of the gen-l10n argument-order bug (see a1's arb_arg_order_test):
// the generated method takes placeholders in ARB *metadata* order, so these
// call sites were passing values swapped. Pin the signatures + the rendered
// text so a metadata reorder breaks this test instead of the UI.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/l10n/app_localizations.dart';

void main() {
  final t = lookupAppLocalizations(const Locale('en'));

  test('fallCountdownValue(seconds, minutes)', () {
    expect(t.fallCountdownValue(5, 2), '2 min 5 sec');
  });
  test('disFamilyInArea(area, kind, sev)', () {
    expect(t.disFamilyInArea('Sylhet', 'Flood', 'Severe'), 'Sylhet — Severe: Flood');
  });
  test('disShareHotlines(disaster, emergency)', () {
    final s = t.disShareHotlines('1090', '999');
    expect(s, contains('Emergency: 999'));
    expect(s, contains('Forecast: 1090'));
  });
  test('refCardCaption(days, friends)', () {
    expect(t.refCardCaption(30, 3), contains('invited 3 friends'));
    expect(t.refCardCaption(30, 3), contains('30 Premium days'));
  });
  test('storageUsedOf(quota, used)', () {
    expect(t.storageUsedOf('5 GB', '1 GB'), '1 GB of 5 GB');
  });
  test('adRewardedTodayCap(cap, done)', () {
    expect(t.adRewardedTodayCap('5', '2'), '2/5 today');
  });
  test('updateVersionLine(n = latest, v = current)', () {
    expect(t.updateVersionLine('1.0.150', '1.0.146'), '1.0.146 • 1.0.150');
  });
}
