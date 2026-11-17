// a11ysweep — ACCESSIBILITY GATE FOR THE TOP FLOWS.
//
// Elders, low-vision people and TalkBack users are core Assisto users. The
// whole-gallery sweep (a11y_guidelines_test.dart) checks every screen in ONE
// rotating bn/en x light/dark combo at text scale 1.3. For the flows people
// touch most this test is stricter:
//   * tap / label / contrast guidelines in the 3 OTHER combos (the sweep runs
//     the 4th), so every top screen is checked in bn + en, light + dark;
//   * "meaningful" — no tappable whose spoken name is a generic word
//     ("button", "icon", "বোতাম"), a lone symbol ("+", "×") or a leaked code
//     key ("fcs_call", "Icons.add");
//   * text scale 2.0 (Android's largest font size, which the app now honours)
//     in bn AND en: no RenderFlex/RenderBox overflow and no button, chip or tab
//     label cut off ("..." or clipped) on the full screen.
// Flows: Home, SOS sender + receiver alarm, Family Care + elder simple home,
// Care Call, My Circle chat + call, Safe Journey, reminders, khata,
// plans/credits, settings.
//
// A finding fails unless it matches the sweep's reviewed allow-list or the
// short [_allow2] list below.  A11Y_ONLY=a,b limits the screens.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'a11y_guidelines_test.dart' as sweep;
import 'screenshots_test.dart' as gallery;

/// Top flows -> gallery spec names (regex on the spec name).
final Map<String, RegExp> kTopFlows = {
  'home': RegExp(r'^(home_welcome|home_top|home_v2|home_v2_chat)$'),
  'sos': RegExp(r'^(fcs_.*|journey_sos|voice_sos_confirm|g2_sos_responding|cesc_alarm_call|fc3_board_sos)$'),
  'family_care': RegExp(r'^(family|elderly_home|famcare_family(_empty)?|fc3_board(_ok|_empty|_error)?|fc3_member|fce_.*)$'),
  'care_call': RegExp(r'^cc_.*$'),
  'circle': RegExp(r'^(circle|circle_chat|circle_call_history|incoming_call|c2_call_.*)$'),
  'journey': RegExp(r'^(journey_(start|live|settings|fake_call)|safe_arrival)$'),
  'reminders': RegExp(r'^(reminders|reminder_due|rem_check|remnotes_reminders(_empty)?)$'),
  'khata': RegExp(r'^(biz_khata(_error)?|ldg_.*)$'),
  'plans': RegExp(r'^(plans|credits_nopay|credits_paylive|credits_reason|spl_.*)$'),
  'settings': RegExp(r'^(settings|settings_voice|push_settings)$'),
};

/// Reviewed exceptions for the checks only this test runs. Same key format
/// as the sweep: "<screen>|<guideline>|<text in the finding>".
const Map<String, String> _allow2 = {
  // HOME IS FROZEN (owner rule): layout never changes. Its tiles/labels
  // already cap their own text scale (HV2.tileLabelMaxScale); a 2.0 finding
  // there is reported to the owner, not fixed here.
  'home_*|overflow2|': 'HOME FROZEN: reported to the owner (layout change needs an explicit order)',
  'home_*|clipped2|': 'HOME FROZEN: same',
};

final _env = Platform.environment;
final Set<String>? _only = () {
  final o = _env['A11Y_ONLY'];
  return (o == null || o.isEmpty) ? null : o.split(',').toSet();
}();

String? _allowed(String screen, String guideline, String detail) {
  final a = sweep.a11yAllowedBy(screen, guideline, detail);
  if (a != null) return a;
  for (final k in _allow2.keys) {
    final p = k.split('|');
    final scr = p[0];
    final scrOk = scr == '*' || scr == screen ||
        (scr.endsWith('*') && screen.startsWith(scr.substring(0, scr.length - 1)));
    if (!scrOk) continue;
    if (p[1] != '*' && p[1] != guideline) continue;
    if (detail.contains(p.sublist(2).join('|'))) return k;
  }
  return null;
}

/// Spoken names that tell a TalkBack user nothing.
final _generic = RegExp(
    r'^(button|icon|image|img|tap|click|press|menu button|icon button|'
    r'বোতাম|বাটন|আইকন|ছবি|চাপুন|ট্যাপ করুন)$',
    caseSensitive: false);
final _codeKey = RegExp(r'^([a-z]+_[a-z0-9_]+|Icons\.\w+|IconData\(.*\))$');
final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Every tappable has a name that MEANS something (labeledTapTargetGuideline
/// only checks that some label exists).
class MeaningfulLabelGuideline extends AccessibilityGuideline {
  const MeaningfulLabelGuideline();

  @override
  String get description => 'Tappable widgets should have a meaningful spoken name';

  @override
  Evaluation evaluate(WidgetTester tester) {
    var r = const Evaluation.pass();
    for (final v in tester.binding.renderViews) {
      r += _visit(v.owner!.semanticsOwner!.rootSemanticsNode!);
    }
    return r;
  }

  Evaluation _visit(SemanticsNode node) {
    var r = const Evaluation.pass();
    node.visitChildren((c) {
      r += _visit(c);
      return true;
    });
    if (node.isMergedIntoParent || node.isInvisible || node.flagsCollection.isHidden ||
        node.flagsCollection.isTextField) {
      return r;
    }
    final d = node.getSemanticsData();
    if (!d.hasAction(SemanticsAction.tap) && !d.hasAction(SemanticsAction.longPress)) return r;
    final name = (d.label.isNotEmpty ? d.label : d.tooltip).trim();
    if (name.isEmpty) return r; // labeledTapTargetGuideline reports it
    final first = name.split('\n').first.trim();
    if (_generic.hasMatch(first) || _codeKey.hasMatch(first) ||
        !_letterOrDigit.hasMatch(name)) {
      r += Evaluation.fail('$node: tappable is spoken as "$name" — say what it does '
          '(e.g. "Call Ammu", "Add reminder").');
    }
    return r;
  }
}

const _meaningful = MeaningfulLabelGuideline();

/// Button / chip / tab labels cut short at the current text scale.
List<String> _clippedControlLabels(WidgetTester tester) {
  final out = <String>{};
  final controls = find.byWidgetPredicate((w) =>
      w is ButtonStyleButton || w is RawChip || w is Tab || w is SegmentedButton ||
      w is NavigationDestination || w is ListTile || w is SwitchListTile ||
      w is CheckboxListTile || w is RadioListTile);
  // an app-bar title ellipsizes by design (fixed toolbar height, every
  // platform does it) and the full name is on the screen below it
  final inBar = find
      .descendant(of: find.byType(AppBar), matching: find.byType(RichText))
      .evaluate()
      .toSet();
  for (final e in find.descendant(of: controls, matching: find.byType(RichText)).evaluate()) {
    if (inBar.contains(e)) continue;
    final ro = e.renderObject;
    if (ro is RenderParagraph && ro.attached && ro.hasSize && ro.didExceedMaxLines) {
      out.add('cut: "${ro.text.toPlainText().replaceAll('\n', ' ')}"');
    }
  }
  return out.toList();
}

void main() {
  setUpAll(gallery.gallerySetUpAll);

  final specs = gallery.gallerySpecs();
  const combos = [
    ('bn', Brightness.light),
    ('en', Brightness.dark),
    ('bn', Brightness.dark),
    ('en', Brightness.light),
  ];
  final guides = <(String, AccessibilityGuideline)>[
    ('tap', androidTapTargetGuideline),
    ('label', labeledTapTargetGuideline),
    ('contrast', sweep.a11yDeviceResTextContrast),
    ('meaningful', _meaningful),
  ];
  var i = 0; // the sweep's rotation (same order, same counter)
  specs.forEach((name, spec) {
    final sweepCombo = combos[i++ % combos.length];
    final flow = kTopFlows.entries.where((e) => e.value.hasMatch(name)).map((e) => e.key).firstOrNull;
    if (flow == null) return;
    final only = _only;
    if (only != null && !only.contains(name)) return;

    for (final (lang, b) in combos) {
      final combo = '$lang-${b.name}';
      final sweepRan = sweepCombo == (lang, b);
      testWidgets('a11y+ $flow $name $combo', (tester) async {
        final handle = tester.ensureSemantics();
        final orig = FlutterError.onError;
        final errs = <String>[];
        FlutterError.onError = (d) {
          final s = d.exceptionAsString();
          if (s.contains('overflowed by')) {
            errs.add(s.split('\n').first);
          } else {
            orig?.call(d);
          }
        };
        try {
          await sweep.a11yPump(tester, name, spec, lang, b, 1.0);
          await tester.pump();
          final open = <String>[];
          for (final (g, guide) in guides) {
            // the sweep already ran tap/label/contrast in this combo
            if (sweepRan && g != 'meaningful') continue;
            Evaluation r;
            try {
              r = await guide.evaluate(tester);
            } catch (e) {
              continue; // same as the sweep: unmeasurable text is not a finding
            }
            if (r.passed) continue;
            for (final d in sweep.a11ySplit(r.reason)) {
              if (_allowed(name, g, d) == null) open.add('$g: $d');
            }
          }
          if (!sweepRan) {
            for (final e in errs.toSet()) {
              if (_allowed(name, 'overflow', e) == null) open.add('overflow: $e');
            }
          }
          await sweep.a11yDrain(tester, spec);
          expect(open, isEmpty,
              reason: 'a11y findings on "$name" ($flow) $combo. Fix it (meaningful '
                  'bn/en tooltip or Semantics label, 48dp hit area, theme token) '
                  'or justify it in the allow-list.');
        } finally {
          FlutterError.onError = orig;
          handle.dispose();
        }
      });
    }

    for (final lang in ['bn', 'en']) {
      final combo = '$lang-x2.0';
      testWidgets('a11y+ $flow $name $combo', (tester) async {
        final orig = FlutterError.onError;
        final errs = <String>[];
        FlutterError.onError = (d) {
          final s = d.exceptionAsString();
          if (s.contains('overflowed by')) {
            errs.add(s.split('\n').first);
          } else {
            orig?.call(d);
          }
        };
        try {
          await sweep.a11yPump(tester, name, spec, lang, Brightness.light, 2.0);
          await tester.pump();
          final open = <String>[
            for (final e in errs.toSet())
              if (_allowed(name, 'overflow2', e) == null) 'overflow: $e',
            for (final c in _clippedControlLabels(tester))
              if (_allowed(name, 'clipped2', c) == null) 'clipped: $c',
          ];
          await sweep.a11yDrain(tester, spec);
          expect(open, isEmpty,
              reason: 'Text scale 2.0 ($lang) breaks "$name" ($flow). Let the '
                  'text wrap (Flexible/Expanded, no fixed heights), scroll the '
                  'body, or stack the row when the text is large.');
        } finally {
          FlutterError.onError = orig;
        }
      });
    }
  });
}
