// unseen-rename (owner 27 Oct): the Today / Jobs / Expats / Students /
// Farmers / Government-services hub (screens/world/) is "Daily info and
// services" / "আজকের তথ্য ও সেবা", behind flag `daily_info`. The flag key
// `unseen_world` now belongs to the NEW Unseen World travel feature (default
// OFF). Checks: the new name in bn + en; no "Unseen World" / "অদেখা" text left
// for this screen; an answer from an old server / old prefs cache (where
// `unseen_world` meant the hub) still drives the hub; the new travel flag
// stays hidden; saved home shortcuts and ChatNav routes are untouched.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/feature_flags.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';
import 'package:assisto/widgets/sidebar_sections.dart';

final ff = FeatureFlags.instance;

FeaturesFetch _serve(Map<String, dynamic> features,
        {List<String> preview = const []}) =>
    (String? _) async => (
          status: 200,
          body: {
            'v': 1,
            'flavour': 'apk',
            'features': features,
            'preview': preview
          },
          etag: '"e1"'
        );

bool _hubInDrawer() => SidebarSections.all
    .expand((s) => s.items)
    .any((i) => i.feature == 'daily_info');

SidebarItem _hubItem() {
  final hits = [
    for (final s in SidebarSections.all)
      for (final i in s.items)
        if (i.feature == 'daily_info') i,
  ];
  expect(hits, hasLength(1));
  return hits.single;
}

Map<String, dynamic> _arb(String lang) =>
    jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    ff.resetForTest();
  });
  tearDown(() => ff.resetForTest());

  test(
      'registry: hub is daily_info (on), unseen_world is the new feature (off)',
      () {
    expect(kFeatureDefaults['daily_info'], isTrue);
    expect(kFeatureDefaults['unseen_world'], isFalse);
    expect(kRouteFeature.values, isNot(contains('unseen_world')));
    expect(kFeaturesVersion, 2);
    expect(kLegacyFeatureKeys, {'unseen_world': 'daily_info'});
  });

  test('the drawer entry shows the new name in English and Bangla', () {
    final item = _hubItem();
    final en = lookupAppLocalizations(const Locale('en'));
    final bn = lookupAppLocalizations(const Locale('bn'));
    expect(item.label(en), 'Daily info and services');
    expect(item.label(bn), 'আজকের তথ্য ও সেবা');
    // searchable by the new name in both languages
    expect(
        SidebarSections.filter(en, 'daily info')
            .expand((s) => s.items)
            .where((i) => i.feature == 'daily_info'),
        isNotEmpty);
    expect(
        SidebarSections.filter(bn, 'আজকের তথ্য')
            .expand((s) => s.items)
            .where((i) => i.feature == 'daily_info'),
        isNotEmpty);
  });

  test('no "Unseen World" / "অদেখা" text left for this screen', () {
    final en = _arb('en'), bn = _arb('bn');
    // every l10n key the hub screens + its drawer entry use
    final sources = [
      for (final f in Directory('lib/screens/world').listSync())
        if (f is File && f.path.endsWith('.dart')) f.readAsStringSync(),
      File('lib/widgets/sidebar_sections.dart')
          .readAsStringSync()
          .split('feature: \'daily_info\'')
          .first
          .split('SidebarItem(')
          .last,
    ];
    final keys = <String>{
      for (final src in sources)
        for (final m in RegExp(r'\bt\.(\w+)').allMatches(src)) m.group(1)!,
    }..retainWhere(en.containsKey);
    expect(keys, contains('dailyInfoTitle'));
    expect(keys.length, greaterThan(10));
    for (final k in keys) {
      for (final v in ['${en[k]}', '${bn[k]}']) {
        expect(v.contains('Unseen World'), isFalse, reason: k);
        expect(v.contains('অদেখা'), isFalse, reason: k);
        expect(v.contains('আনসিন'), isFalse, reason: k);
      }
    }
    // the old title key is no longer used anywhere in the app
    final libUses = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.contains('/l10n/'))
        .where((f) => f.readAsStringSync().contains('uwTitle'));
    expect(libUses.map((f) => f.path), isEmpty);
  });

  test('old server / old cache answer: unseen_world drives the hub', () async {
    await ff.refresh(_serve({'unseen_world': true, 'money': true}),
        force: true);
    expect(ff.isOn('daily_info'), isTrue);
    expect(ff.isOn('unseen_world'), isFalse); // new feature keeps its default
    expect(_hubInDrawer(), isTrue);

    await ff.refresh(_serve({'unseen_world': false, 'money': true}),
        force: true);
    expect(ff.isOn('daily_info'), isFalse); // owner had hidden the hub
    expect(_hubInDrawer(), isFalse);
    expect(ff.isOn('unseen_world'), isFalse);
  });

  test('old answer preview moves to daily_info', () async {
    await ff.refresh(_serve({'unseen_world': true}, preview: ['unseen_world']),
        force: true);
    expect(ff.isPreview('daily_info'), isTrue);
    expect(ff.isPreview('unseen_world'), isFalse);
  });

  test('new answer: keys keep their real meaning', () async {
    await ff.refresh(_serve({'daily_info': true, 'unseen_world': false}),
        force: true);
    expect(ff.isOn('daily_info'), isTrue);
    expect(ff.isOn('unseen_world'), isFalse);
    await ff.refresh(_serve({'daily_info': false, 'unseen_world': true}),
        force: true);
    expect(ff.isOn('daily_info'), isFalse);
    expect(ff.isOn('unseen_world'), isTrue); // owner preview of the new one
  });

  test('an old cached answer in prefs (saved before the update) still works',
      () async {
    SharedPreferences.setMockInitialValues({
      FeatureFlags.prefsKey: jsonEncode({
        'v': 1,
        'features': {'unseen_world': true, 'money': true},
        'preview': [],
        '_etag': '"old"'
      }),
    });
    Settings.resetForTest();
    ff.resetForTest();
    await ff.load();
    expect(ff.isOn('daily_info'), isTrue);
    expect(ff.isOn('unseen_world'), isFalse);
  });

  test('saved home shortcuts and ChatNav routes are untouched', () {
    // The hub never had a ChatNav route or a home shortcut; the travel
    // guide's route `unseen` (flag unseen_bangladesh) keeps working.
    expect(kRouteFeature['unseen'], 'unseen_bangladesh');
    expect(ChatNav.routes.containsKey('unseen'), isTrue);
    final saved = [
      'reminders',
      'money',
      'notes',
      'ai_chat',
      'family',
      'documents'
    ];
    expect(HomeQuickButtons.sanitize(saved), saved);
  });
}
