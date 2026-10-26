// a11y1 — ACCESSIBILITY GUIDELINES SWEEP.
//
// Many Assisto users are elderly people and farmers (Bangla UI). For every
// screen the screenshot gallery pumps (gallerySpecs() in screenshots_test.dart:
// its `specs` + every *_shots.dart map it wires in — same harness, same
// FakeApi/fakes, same 360x800 surface) this test runs Flutter's accessibility
// guidelines:
//   * tap     androidTapTargetGuideline   (every tappable >= 48x48 dp)
//   * label   labeledTapTargetGuideline   (every tappable has a label/tooltip)
//   * contrast textContrastGuideline      (WCAG AA: 4.5, large/bold text 3.0)
// in bn + en, light + dark, and then re-pumps each screen at textScaler 1.3
// (bn + en) where any RenderFlex/RenderBox overflow FlutterError is a failure.
// (iOSTapTargetGuideline is not run: 44x44 is strictly weaker than 48x48 and
// the app ships on Android only.)
//
// A finding fails the test unless it matches the reviewed [_allow] list.
// Report: a11y_report.{md,json} in $A11Y_REPORT_DIR (default build/a11y).
//
// CI / speed:
//   default run      every spec, ONE combo per spec, rotating through
//                    bn-light / en-dark / bn-dark / en-light (so each screen is
//                    checked once and every combo is exercised), + the 1.3
//                    overflow pass in bn (the longer script) for every spec.
//   A11Y_FULL=1      the full matrix: 4 guideline combos + 1.3 in bn AND en.
//   A11Y_ONLY=a,b    only these spec names.   A11Y_AUDIT=1  report, never fail.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';
import 'screenshots_test.dart' as gallery;

/// Reviewed allow-list: "<screen>|<guideline>|<text in the finding>" -> why.
/// <screen> may end in `*` (prefix) or be `*`; <guideline> is tap, label,
/// contrast or overflow (or `*`). Keep it tiny: only third-party widgets the
/// app cannot change, decorative cases, and fixtures that are not app code.
const Map<String, String> _allow = {
  // HOME IS FROZEN (owner rule): only labels / invisible hit areas may change
  // there. Reported to the owner instead of fixed.
  'home_*|tap|label: "Edit"': 'HOME FROZEN: quick-buttons "Edit" is a compact TextButton (40 dp); a 48 dp target moves the home layout 8 dp',
  'home_*|tap|label: "সাজান"': 'HOME FROZEN: same "Edit" button in Bangla',
  'quick_grid*|tap|label: "Edit"': 'HOME FROZEN: the home quick-buttons grid (same widget as home_*)',
  'quick_grid*|tap|label: "সাজান"': 'HOME FROZEN: same, Bangla',
  'home_*|tap|tags: [RenderViewport.twoPane]': 'false positive: the next home carousel card peeks in at the screen edge (13 dp visible); it is full size once swiped',
  // Ads are out of scope for this sweep (owner rule: no ads changes).
  'p2_hero_sponsor|tap|': 'ADS: sponsor card "Why am I seeing this?" icon is ads code (no ads changes)',
  'home_hero_ad_free|contrast|Install': 'ADS: fake native-ad template in h1_home_fakes.dart (not app UI)',
  // Secondary controls inside a voice bubble: the 48 dp play/pause button is
  // the primary control; a taller strip/pill would grow every voice bubble.
  '*|tap|label: "Voice message position': 'voice bubble seek strip (30 dp); play/pause is the 48 dp control',
  '*|tap|label: "ভয়েস মেসেজের অবস্থান': 'same, Bangla',
  '*|tap|label: "Playback speed': 'voice bubble 1x/1.5x/2x pill (24 dp) beside the duration; play/pause is the 48 dp control',
  '*|tap|label: "চালানোর গতি': 'same, Bangla',
  // Not controls / not really obscured.
  '*|tap|flags: [isTextField, isMultiline, isReadOnly': 'SelectableText answer body: long-press selects text; it is reading text, not a button',
  'payment_ladder|contrast|label: "Snooze"': 'false positive: the last card\'s "Snooze" sits under the "Add a due" FAB at the 800 dp fold; the list scrolls it clear',
  // Text drawn over a live video frame cannot have a guaranteed background.
  'cde_call_swapped|contrast|': 'call canvas: timer/path/labels over the (fake) remote video frame; real video changes every frame',
};

final _env = Platform.environment;
final _full = _env['A11Y_FULL'] == '1';
final _audit = _env['A11Y_AUDIT'] == '1';
final Set<String>? _guides = () {
  final o = _env['A11Y_GUIDES'];
  return (o == null || o.isEmpty) ? null : o.split(',').toSet();
}();
final Set<String>? _only = () {
  final o = _env['A11Y_ONLY'];
  return (o == null || o.isEmpty) ? null : o.split(',').toSet();
}();

class _Finding {
  final String screen, combo, guideline, detail;
  _Finding(this.screen, this.combo, this.guideline, this.detail);
  String? allowedBy() {
    for (final k in _allow.keys) {
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

  Map<String, Object?> toJson() => {
        'screen': screen,
        'combo': combo,
        'guideline': guideline,
        'detail': detail,
        'allowed': allowedBy(),
      };
}

final List<_Finding> _findings = [];
final Set<String> _screensRun = {};

/// One guideline result -> one finding per failing semantics node, with the
/// volatile node ids stripped so findings compare across runs.
List<String> _split(String? reason) {
  if (reason == null || reason.isEmpty) return const [];
  final out = <String>[];
  for (var chunk in reason.split(RegExp(r'(?=SemanticsNode#)'))) {
    chunk = chunk
        .replaceAll(RegExp(r'\nSee also: \S+'), '')
        .replaceAll(RegExp(r'SemanticsNode#\d+'), 'Node')
        .replaceAll('\n', ' ')
        .trim();
    if (chunk.isNotEmpty) out.add(chunk);
  }
  return out;
}

/// textContrastGuideline, measured at DEVICE resolution.
///
/// Flutter's [textContrastGuideline] rasterises the screen at 1 logical px per
/// pixel and compares the most frequent light and dark colours around a text.
/// At that resolution a 12-14 dp regular glyph stroke is ~1 px wide, so the
/// "dark" colour it finds is an anti-aliased edge, not the text colour: dark
/// grey #1F2937 body text on white read as 1.6:1 (verified against the gallery
/// PNGs). This variant keeps Flutter's node selection, skip rules, WCAG targets
/// (4.5, or 3.0 for >= 18 dp / bold >= 14 dp) and tolerance, but rasterises at
/// the device pixel ratio (3x) and measures the text's core colour: the
/// background is the most frequent colour, the text is the colour (with at
/// least 1% of the pixels) that contrasts most with it.
class _DeviceResTextContrast extends AccessibilityGuideline {
  const _DeviceResTextContrast();

  @override
  String get description => 'Text contrast should follow WCAG guidelines (device resolution)';

  @override
  Future<Evaluation> evaluate(WidgetTester tester) async {
    var result = const Evaluation.pass();
    for (final view in tester.binding.renderViews) {
      final layer = view.debugLayer! as OffsetLayer;
      final dpr = view.flutterView.devicePixelRatio;
      late int w, h;
      final bytes = await tester.binding.runAsync<ByteData?>(() async {
        final img = await layer.toImage(view.paintBounds);
        w = img.width;
        h = img.height;
        final d = await img.toByteData();
        img.dispose();
        return d;
      });
      final root = view.owner!.semanticsOwner!.rootSemanticsNode!;
      result += _node(root, tester, bytes!, w, h, dpr, view);
    }
    return result;
  }

  Evaluation _node(SemanticsNode node, WidgetTester tester, ByteData px, int w,
      int h, double dpr, RenderView view) {
    var result = const Evaluation.pass();
    if (node.isInvisible || node.isMergedIntoParent ||
        node.flagsCollection.isHidden ||
        node.flagsCollection.isEnabled == ui.Tristate.isFalse) {
      return result;
    }
    node.visitChildren((c) {
      result += _node(c, tester, px, w, h, dpr, view);
      return true;
    });
    final data = node.getSemanticsData();
    if (data.flagsCollection.scopesRoute ||
        (data.label.trim().isEmpty && data.value.trim().isEmpty)) {
      return result;
    }
    final text = data.label.isEmpty ? data.value : data.label;
    var nodeRect = node.rect; // physical once the root transform is applied
    for (SemanticsNode? c = node; c != null; c = c.parent) {
      final t = c.transform;
      if (t != null) nodeRect = MatrixUtils.transformRect(t, nodeRect);
    }
    for (final el in find.text(text).hitTestable().evaluate()) {
      final ro = el.renderObject;
      if (ro is! RenderBox) continue;
      final logical = MatrixUtils.transformRect(ro.getTransformTo(null), ro.paintBounds);
      final phys = Rect.fromLTRB(logical.left * dpr, logical.top * dpr,
          logical.right * dpr, logical.bottom * dpr);
      final inter = nodeRect.intersect(phys);
      if (inter.width <= 0 || inter.height <= 0) continue;
      final screen = Offset.zero & view.flutterView.physicalSize;
      if (!screen.overlaps(phys)) continue;
      final widget = el.widget;
      final TextStyle style;
      if (widget is Text) {
        final ws = widget.style;
        style = ws == null || ws.inherit
            ? DefaultTextStyle.of(el).style.merge(ws)
            : ws;
      } else if (widget is EditableText) {
        style = widget.style;
      } else {
        continue;
      }
      final size = style.fontSize ?? 12.0;
      final bold = style.fontWeight == FontWeight.bold;
      final target = (bold && size >= 14) || size >= 18 ? 3.0 : 4.5;
      final r = _measure(px, phys.inflate(2 * dpr).intersect(screen), w, h);
      if (r == null) continue;
      final (ratio, bg, fg) = r;
      if (ratio - target >= -0.01) continue;
      result += Evaluation.fail('$node:\n'
          'Expected contrast ratio of at least $target but found '
          '${ratio.toStringAsFixed(2)} for a font size of $size. '
          'text ${_hex(fg)} on ${_hex(bg)}');
    }
    return result;
  }

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static (double, Color, Color)? _measure(ByteData px, Rect r, int w, int h) {
    final counts = <int, int>{};
    final x0 = r.left.floor().clamp(0, w), x1 = r.right.ceil().clamp(0, w);
    final y0 = r.top.floor().clamp(0, h), y1 = r.bottom.ceil().clamp(0, h);
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final v = px.getUint32((y * w + x) * 4);
        counts[v] = (counts[v] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return null;
    final total = counts.values.fold(0, (a, b) => a + b);
    Color col(int rgba) => Color((rgba << 24 | rgba >> 8) & 0xFFFFFFFF);
    final bgKey = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final bg = col(bgKey);
    final bgL = bg.computeLuminance();
    final minCount = (total * 0.01).ceil().clamp(4, 1 << 30);
    var best = 1.0;
    var fg = bg;
    counts.forEach((k, n) {
      if (n < minCount || k == bgKey) return;
      final c = col(k);
      final l = c.computeLuminance();
      final ratio = (bgL > l ? bgL + 0.05 : l + 0.05) / (bgL > l ? l + 0.05 : bgL + 0.05);
      if (ratio > best) {
        best = ratio;
        fg = c;
      }
    });
    // No pixels clearly apart from the background: the glyphs are not painted
    // here (covered, clipped or still fading in) -- nothing to measure.
    if (best < 1.1) return null;
    return (best, bg, fg);
  }
}

const _guidelines = <(String, AccessibilityGuideline)>[
  ('tap', androidTapTargetGuideline),
  ('label', labeledTapTargetGuideline),
  ('contrast', _DeviceResTextContrast()),
];

Future<void> _pump(WidgetTester tester, String name, gallery.GallerySpec spec,
    String lang, Brightness b, double scale) async {
  // A real phone: 360x800 dp at 3x, so the guidelines' screen-edge and
  // device-pixel maths match the surface the gallery lays out on.
  final tall = name.endsWith('_bottom');
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = Size(1080, tall ? 5400 : 2400);
  addTearDown(tester.view.reset);
  await gallery.galleryPump(tester, name, lang, b, spec.build(lang), spec.mode,
      key: GlobalKey(), textScale: scale);
}

Future<void> _drain(WidgetTester tester, gallery.GallerySpec spec) async {
  if (spec.mode == FakeMode.slow) {
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pump();
  }
}

void _writeReport() {
  if (_findings.isEmpty && _screensRun.isEmpty) return;
  final dir = _env['A11Y_REPORT_DIR'] ?? 'build/a11y';
  Directory(dir).createSync(recursive: true);
  File('$dir/a11y_report.json').writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert({
    'screens': _screensRun.length,
    'findings': [for (final f in _findings) f.toJson()],
  }));
  final counts = <String, int>{};
  final perScreen = <String, int>{};
  for (final f in _findings) {
    if (f.allowedBy() != null) continue;
    counts[f.guideline] = (counts[f.guideline] ?? 0) + 1;
    perScreen[f.screen] = (perScreen[f.screen] ?? 0) + 1;
  }
  final top = perScreen.entries.toList()..sort((a, b) => b.value - a.value);
  final md = StringBuffer()
    ..writeln('# a11y guidelines report')
    ..writeln()
    ..writeln('Runs: ${_screensRun.length} · open findings: '
        '${counts.values.fold(0, (a, b) => a + b)} '
        '(${counts.entries.map((e) => '${e.key} ${e.value}').join(', ')}) · '
        'allow-listed: ${_findings.where((f) => f.allowedBy() != null).length}')
    ..writeln()
    ..writeln('Top screens: ${top.take(15).map((e) => '${e.key} ${e.value}').join(', ')}')
    ..writeln()
    ..writeln('| screen | combo | guideline | finding |')
    ..writeln('|---|---|---|---|');
  for (final f in _findings) {
    md.writeln('| ${f.screen} | ${f.combo} | ${f.guideline}'
        '${f.allowedBy() != null ? ' (allowed)' : ''} | '
        '${f.detail.replaceAll('|', '/')} |');
  }
  File('$dir/a11y_report.md').writeAsStringSync(md.toString());
}

void main() {
  setUpAll(gallery.gallerySetUpAll);
  tearDownAll(_writeReport);

  final specs = gallery.gallerySpecs();
  final only = _only;
  const combos = [
    ('bn', Brightness.light),
    ('en', Brightness.dark),
    ('bn', Brightness.dark),
    ('en', Brightness.light),
  ];
  var i = 0;
  specs.forEach((name, spec) {
    if (only != null && !only.contains(name)) return;
    final mine = _full || only != null
        ? combos
        : [combos[i++ % combos.length]];
    for (final (lang, b) in mine) {
      final combo = '$lang-${b.name}';
      testWidgets('a11y $name $combo', (tester) async {
        final handle = tester.ensureSemantics();
        final errs = <String>[];
        final orig = FlutterError.onError;
        FlutterError.onError = (d) {
          final s = d.exceptionAsString();
          if (s.contains('overflowed by')) {
            errs.add(s.split('\n').first);
          } else {
            orig?.call(d);
          }
        };
        try {
          await _pump(tester, name, spec, lang, b, 1.0);
          await tester.pump();
          final here = <_Finding>[
            for (final e in errs.toSet()) _Finding(name, combo, 'overflow', e),
          ];
          for (final (g, guide) in _guidelines) {
            if (!(_guides?.contains(g) ?? true)) continue;
            Evaluation r;
            try {
              r = await guide.evaluate(tester);
            } catch (e) {
              // textContrastGuideline cannot measure some text (e.g. a
              // RichText the finder matches); record, never crash the sweep.
              here.add(_Finding(name, combo, g, 'EVAL-ERROR ${'$e'.split('\n').first}'));
              continue;
            }
            if (!r.passed) {
              for (final d in _split(r.reason)) {
                here.add(_Finding(name, combo, g, d));
              }
            }
          }
          _findings.addAll(here);
          _screensRun.add('$name $combo');
          await _drain(tester, spec);
          final open = here.where((f) => f.allowedBy() == null).toList();
          if (!_audit) {
            expect(open.map((f) => '${f.guideline}: ${f.detail}').toList(), isEmpty,
                reason: 'a11y findings on "$name" $combo. Fix (tooltip/semantics '
                    'label, 48dp hit area, theme token) or justify in _allow.');
          }
        } finally {
          FlutterError.onError = orig;
          handle.dispose();
        }
      });
    }
    final scales = !(_guides?.contains('overflow') ?? true)
        ? const <String>[]
        : _full || only != null ? ['bn', 'en'] : ['bn'];
    for (final lang in scales) {
      final combo = '$lang-x1.3';
      testWidgets('a11y $name $combo', (tester) async {
        final errs = <String>[];
        final orig = FlutterError.onError;
        FlutterError.onError = (d) {
          final s = d.exceptionAsString();
          if (s.contains('overflowed by')) {
            errs.add(s.split('\n').first);
          } else {
            orig?.call(d);
          }
        };
        try {
          await _pump(tester, name, spec, lang, Brightness.light, 1.3);
          await tester.pump();
          await _drain(tester, spec);
          final here = [
            for (final e in errs.toSet()) _Finding(name, combo, 'overflow', e),
          ];
          _findings.addAll(here);
          _screensRun.add('$name $combo');
          final open = here.where((f) => f.allowedBy() == null).toList();
          if (!_audit) {
            expect(open.map((f) => f.detail).toList(), isEmpty,
                reason: 'Overflow on "$name" at text scale 1.3 ($lang). '
                    'Let the text wrap/ellipsize (Flexible/Expanded, maxLines).');
          }
        } finally {
          FlutterError.onError = orig;
        }
      });
    }
  });
}
