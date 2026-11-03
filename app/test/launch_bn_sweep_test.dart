// launchsweep (2 Nov) — LAUNCH BANGLA + BIG-FONT GUARD for every screen that
// shipped on 2 Nov (owner launches ALL features on 8 Nov).
//
// For each gallery spec (gallerySpecs() in screenshots_test.dart) whose name
// starts with one of [_launchPrefixes] this test pumps the screen exactly like
// the gallery and fails on:
//   digit     bn UI: a visible text with an ASCII digit 0-9 (owner rule: Bangla
//             digits everywhere in Bangla — money, counts, dates, times, km).
//   english   bn UI: a visible text that is EXACTLY an English app string (an
//             app_en.arb value with no Bangla twin shown) — i.e. a hard-coded
//             or untranslated label leaking into the Bangla screen.
//   overflow  bn AND en at text scale 2.0 (owner rule: 200 % font, 360 dp):
//             any RenderFlex/RenderBox overflow is a clipped label.
//
// New screens are covered automatically: add the gallery spec with one of
// the prefixes below (or add the prefix). A finding fails unless it matches
// the reviewed [_allow] list ("<screen>|<check>|<text in finding>").
//
// SITE SHOTS (sitelive, 3 Nov): every gallery shot lifeassisto.com shows
// (../backend/web/site_shot_sources.json, kept equal to
// web.site_v3.shot_names() by web.tests_site_v3) gets the bn `digit` check
// too — a Bangla site screenshot must never show English digits. Every
// failing screen name is written to $ASSISTO_SHOT_DIR/launch_bn_sweep_failures.json
// (the shots-* artifacts), and tools/website/site_shots.py refuses to put a
// shot from that failure list on the site.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart' show FakeMode;
import 'screenshots_test.dart' as gallery;

/// Gallery spec name prefixes of the 2 Nov launch features.
const _launchPrefixes = <String>[
  'emergency_hub', // emergency hub
  'blood_', // blood donor list / profile / request / share
  'missing_', // missing alert
  'train_', 'dest_alarm', // train tracker + chat + destination alarm
  'journey_', // journey modes
  'chip_', // tracker chip
  'kid_audio', // child emergency audio
  'acct_', // accounting + account modes (acct_mode_*)
  'inv_', // invoices
  'rt_', // CRM automation (retention1)
  'mkt_', // marketing engine (mktengine)
  'chx_', // channels + communities
  'cact_', // cctvactivity: CCTV activity brain (3 Nov)
  'callpip_', // call PiP / mini tile / call bar
  'bizops_', // biz brief card
  'chat', 'ps_assistant', // home AI chat action cards (expense / reminder / approval)
  'dtools_', // p2tools: Daily tools hub + every tool (3 Nov)
  // launchsweep2 (3 Nov): everything built on the 2–3 Nov night.
  'pc_', // CCTV phone camera (old phone as camera)
  'cx_', 'cxat_', // CCTV alerts inbox / actions / alert types
  'cev_', // CCTV evidence (SD clip / recording)
  'cesc_', // CCTV escalation (alarm call, police card)
  'cpl_', // CCTV pricing / add-on
  'cg_', // CCTV cost guard
  'lostsim_', // lost phone: intruder-photo notice on the Vault PIN (3 Nov)
  'carm_', // CCTV auto guard (arm / SOS)
  'ctm_', // CCTV team (guards, links, access log)
  'dp_', 'task_mgr', 'cost_est', // p2plan: daily planner, task manager, estimator (3 Nov)
  'sjl_', 'trip_', // Safe Journey Live Location + trip recorder
  'bbl2_', 'bbl_', // chat bubbles
  'psec_', // Personal Secretary
  'amk_', // Market
  'p3feed_', // Today feed: BB official rate, notices, not-connected list (3 Nov)
  'food_cal', // p2food: food photo -> calories
  'ielts_', // p2lang: IELTS practice (Language Partner)
  // 3 Nov bndigits6: screens the website bn sweep found with ASCII digits
  'ai_knowledge', 'nominee', 'crm_lead_detail', 'jobs', 'landlord', 'exam',
  'crr_', // p2career: CV export, Find jobs, role interview (3 Nov)
  'farm_', // p3farm: Farmer mode help / crop calendar / disease check
];

/// Reviewed exceptions. Keep it tiny and say why.
const Map<String, String> _allow = {
  // Paper size / device model trade names are written the same in Bangla.
  'inv_*|digit|A4': 'paper size trade name (A4), same on Bangla printers and in shops',
  'chip_pair|digit|GT06': 'tracker model name printed on the box (Concox GT06)',
  'chip_pair|digit|ST-90': 'tracker model name printed on the box (Sinotrack ST-901/906)',
  'chip_pair|digit|TK103': 'tracker model name printed on the box (Coban TK103)',
  // Place / product / customer names are the user's (or OpenStreetMap's) data.
  'dest_alarm|digit|Bus': 'bus stop names from OpenStreetMap (no Bangla name tag), data not UI',
  'dest_alarm|digit|Road': 'same: OpenStreetMap stop name',
  'bizops_card|digit|Tel 1L': "the shop's own product name (user data)",
  'acct_vat_rates*|digit|Soybean oil 1L': "the shop's own product name (user data)",
  'rt_*|english|"Karim"': 'fake customer name (user data)',
  'rt_inbox|digit|A gentle note': "a customer's chat message text (user data)",
  // Site shots: standard / brand names written the same in Bangla.
  '*|digit|SHA-256': 'hash standard name (SHA-256), never translated',
  'p3feed_*|digit|CC BY 4.0': 'MET Norway licence name (CC BY 4.0) — attribution text required as published',
  // Report account names arrive from the server in the request language
  // (backend ledger._m); the gallery fake is English-only.
  // bndigits6: names the user typed / the job board supplies (data, not UI).
  'jobs|digit|Shop365': "a company's own name from the job board (data)",
  'exam|digit|SSC 2026': "the watcher label the user typed (data)",
  'exam|digit|HSC 2026': "the watcher label the user typed (data)",
  'acct_reports_*|english|"Rent"': 'fake data: server sends the Bangla account name',
  'acct_reports_*|english|"Stock"': 'fake data: server sends the Bangla account name',
  // launchsweep2 (3 Nov) — reviewed; each is user data or English-only
  // gallery fake data for text the server already sends in Bangla.
  '*|digit|PDF (A': 'paper size trade name (A4 / A5)',
  '*|english|"PDF (A': 'paper size trade name (A4 / A5), same in Bangla',
  'cx_privacy_kit|english|"English"': 'the language choice বাংলা / English, each in its own script',
  'amk_*|digit|Good quality, 2nd floor': "the seller's own note (user data)",
  'amk_deals|digit|LED bulb 12W': "the buyer's own product name (user data)",
  'amk_offers|digit|more than the lowest price': 'fake data: core/market.py rank_bids sends bn reasons',
  'amk_offers|digit|Delivery in': 'fake data: core/market.py rank_bids sends bn reasons',
  'amk_offers|digit|Rating 4.6/5': 'fake data: core/market.py rank_bids sends bn reasons',
  'amk_offers|digit|km away': 'fake data: core/market.py rank_bids sends bn reasons',
  'cx_placement|english|it cannot tell what is in front': 'fake data: core/cctvx_views.py sends the bn honest line',
  'cx_cash_guard_extras|digit|Cash drawer:': 'fake data: core/logic/cctv_extras.py sends bn lines',
  'cx_cash_guard_extras|digit|Camera/internet silent': 'fake data: core/logic/cctv_extras.py sends bn lines',
  'cx_cash_guard_extras|digit|The shop opened at': 'fake data: core/logic/cctv_extras.py sends bn lines',
  'cev_recording*|english|"SD card OK"': 'fake data: core/cctv_evidence.py sends the bn SD label',
  'carm_sos_live|english|"Home"': 'the place name the owner typed (user data)',
  'bbl2_circle_row|english|"Karim"': 'a contact name (user data)',
  'bbl2_circle_row|english|"Family"': 'a group name the user chose (user data)',
};

final _env = Platform.environment;
final Set<String>? _only = () {
  final o = _env['LAUNCH_ONLY'];
  return (o == null || o.isEmpty) ? null : o.split(',').toSet();
}();

bool _allowed(String screen, String check, String detail) {
  for (final k in _allow.keys) {
    final p = k.split('|');
    final s = p[0];
    final ok = s == '*' || s == screen ||
        (s.endsWith('*') && screen.startsWith(s.substring(0, s.length - 1)));
    if (!ok) continue;
    if (p[1] != '*' && p[1] != check) continue;
    if (detail.contains(p.sublist(2).join('|'))) return true;
  }
  return false;
}

/// English strings of the app (app_en.arb values) that are worth flagging:
/// at least one 3+ letter word, no placeholders, not a brand-only string.
final Set<String> _enStrings = () {
  final out = <String>{};
  try {
    final m = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map;
    m.forEach((k, v) {
      if ('$k'.startsWith('@') || v is! String) return;
      final s = v.trim();
      if (s.contains('{') || !RegExp(r'[A-Za-z]{3,}').hasMatch(s)) return;
      if (_brandOnly(s)) return;
      out.add(s);
    });
  } catch (_) {}
  return out;
}();

const _brands = {
  'assisto', 'bkash', 'nagad', 'rocket', 'upay', 'whatsapp', 'facebook',
  'messenger', 'google', 'play', 'imo', 'telegram', 'viber', 'youtube', 'sms',
  'otp', 'qr', 'pdf', 'csv', 'excel', 'gps', 'sos', 'ai', 'pip', 'id',
  'lifeassisto.com', 'wi-fi', 'wifi', 'android', 'vat', 'bin', 'tin', 'ok',
};

bool _brandOnly(String s) => s
    .toLowerCase()
    .split(RegExp(r'[\s/·,.:()\-]+'))
    .where((w) => w.isNotEmpty)
    .every(_brands.contains);

/// Visible strings on screen (every paragraph that painted).
List<String> _texts(WidgetTester tester) {
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final ro = e.renderObject;
    if (ro is! RenderParagraph || !ro.attached || !ro.hasSize) continue;
    if (ro.size.isEmpty) continue;
    final s = ro.text.toPlainText(includeSemanticsLabels: false).trim();
    if (s.isNotEmpty) out.add(s);
  }
  return out;
}

final _ascii = RegExp(r'[0-9]');
// URLs / app links / invite codes are not reading text.
final _urlish = RegExp(r'(https?://|lifeassisto\.com|\.com/|www\.)');

/// Gallery names of the screenshots on lifeassisto.com (site_shots.py writes
/// the file; the Django site test keeps it equal to site_v3.shot_names()).
List<String> _siteShots() {
  try {
    final m = jsonDecode(File('../backend/web/site_shot_sources.json')
        .readAsStringSync()) as Map;
    return [for (final n in m['names'] as List) '$n'];
  } catch (_) {
    return const [];
  }
}

/// Screens with an open finding -> launch_bn_sweep_failures.json.
final Map<String, List<String>> _failures = {};

void _record(String name, Iterable<String> open) {
  if (open.isEmpty) return;
  _failures.putIfAbsent(name, () => []).addAll(open);
}

void _writeFailures() {
  final dir = _env['ASSISTO_SHOT_DIR'];
  if (dir == null || dir.isEmpty) return;
  try {
    Directory(dir).createSync(recursive: true);
    File('$dir/launch_bn_sweep_failures.json').writeAsStringSync(
        const JsonEncoder.withIndent(' ').convert({'failures': _failures}));
  } catch (_) {}
}

/// bn texts with an ASCII digit (and, unless [digitsOnly], exact English app
/// strings) that are not in [_allow].
Set<String> _bnFindings(WidgetTester tester, String name,
    {bool digitsOnly = false}) {
  final open = <String>{};
  for (final s in _texts(tester)) {
    final one = s.replaceAll('\n', ' ');
    if (_ascii.hasMatch(one) && !_urlish.hasMatch(one)) {
      final d = 'digit: "$one"';
      if (!_allowed(name, 'digit', d)) open.add(d);
    }
    if (!digitsOnly && _enStrings.contains(s)) {
      final d = 'english: "$one"';
      if (!_allowed(name, 'english', d)) open.add(d);
    }
  }
  return open;
}

void main() {
  setUpAll(gallery.gallerySetUpAll);
  tearDownAll(_writeFailures);
  final specs = gallery.gallerySpecs();
  final names = specs.keys
      .where((n) => _launchPrefixes.any(n.startsWith))
      .where((n) => _only == null || _only!.contains(n))
      .toList();
  final site = _siteShots();

  test('site shot sources are listed (the site digit guard is not silently empty)', () {
    expect(site, isNotEmpty,
        reason: '../backend/web/site_shot_sources.json missing or empty — run '
            'python tools/website/site_shots.py --sources');
  });

  for (final name in site) {
    final spec = specs[name];
    testWidgets('site bn shot $name has Bangla digits', (tester) async {
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await gallery.galleryPump(tester, name, 'bn', Brightness.light,
          spec!.build('bn'), spec.mode, key: GlobalKey());
      await tester.pump();
      final open = _bnFindings(tester, name, digitsOnly: true);
      _record(name, open);
      if (spec.mode == FakeMode.slow) {
        await tester.pump(const Duration(milliseconds: 1400));
      }
      await tester.pump(const Duration(seconds: 2));
      expect(open.toList(), isEmpty,
          reason: 'lifeassisto.com shows the bn gallery shot "$name" and it '
              'has English digits. Fix the screen (localDigits / moneyDigits '
              '…) — the site must not show it.');
    },
        // a site shot whose gallery spec lives on a branch not merged yet
        skip: spec == null || (_only != null && !_only!.contains(name)));
  }

  test('launch prefixes match gallery specs (guard is not silently empty)', () {
    for (final p in _launchPrefixes) {
      expect(specs.keys.any((n) => n.startsWith(p)), isTrue,
          reason: 'no gallery spec starts with "$p" — the launch sweep would '
              'skip that feature. Add its gallery states or fix the prefix.');
    }
  });

  for (final name in names) {
    final spec = specs[name]!;
    testWidgets('launch bn text $name', (tester) async {
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await gallery.galleryPump(tester, name, 'bn', Brightness.light,
          spec.build('bn'), spec.mode, key: GlobalKey());
      await tester.pump();
      final open = _bnFindings(tester, name);
      _record(name, open);
      if (spec.mode == FakeMode.slow) {
        await tester.pump(const Duration(milliseconds: 1400));
      }
      await tester.pump(const Duration(seconds: 2));
      expect(open.toList(), isEmpty,
          reason: 'Bangla screen "$name" shows ASCII digits or English app '
              'strings. Use the Bangla-digit helper (localDigits / acctDigits '
              '/ moneyDigits …) and the bn ARB string, or justify in _allow.');
    });
    for (final lang in const ['bn', 'en']) {
      testWidgets('launch 2x font $name $lang', (tester) async {
        final errs = <String>{};
        final orig = FlutterError.onError;
        FlutterError.onError = (d) {
          final s = d.exceptionAsString();
          if (s.contains('overflowed by')) {
            final at = RegExp(r'lib/[A-Za-z0-9_/]+\.dart:\d+')
                .firstMatch(d.toString())?.group(0);
            errs.add('${s.split('\n').first}${at == null ? '' : ' at $at'}');
          } else {
            orig?.call(d);
          }
        };
        try {
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);
          await gallery.galleryPump(tester, name, lang, Brightness.light,
              spec.build(lang), spec.mode,
              key: GlobalKey(), textScale: 2.0);
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          final open = [
            for (final e in errs)
              if (!_allowed(name, 'overflow', e)) e,
          ];
          expect(open, isEmpty,
              reason: 'Overflow on "$name" ($lang) at 200 % font, 360 dp. '
                  'Let the text wrap (Expanded/Flexible, Wrap, maxLines).');
        } finally {
          FlutterError.onError = orig;
        }
      });
    }
  }
}
