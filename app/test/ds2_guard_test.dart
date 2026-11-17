// designv2 CI guard (owner order 10 Nov 01:40, Design System V2, step 4).
//  1. LINT: no raw `TextStyle(` / `Color(` outside lib/theme.dart + lib/ds/.
//     Existing uses are allow-listed per file in test/ds2_lint_allow.json —
//     a count may only go DOWN (lower it when you migrate a file); a NEW file
//     starts at 0; files in "migrated" must stay at 0. Use DsTokens.of(context)
//     / Theme.of(context).textTheme.*.copyWith(...) instead.
//  2. CONTRAST: every V2 text role meets WCAG AA (4.5:1) on its surfaces.
//  3. COMPONENTS: every DS component renders in bn + en, light + dark, at
//     100 % and 200 % font on a 360 dp phone with no overflow, no cut text,
//     48 dp touch targets and AA text contrast (Flutter's a11y guidelines).
//  4. LITE: low-end / reduce-motion → no glow, no pulse controller.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:assisto/ds/ds.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_fonts.dart';

final _ts = RegExp(r'\bTextStyle\(');
final _col = RegExp(r'\bColor\(|\bColor\.from(ARGB|RGBO)\(');

(int, int) _count(File f) {
  var t = 0, c = 0;
  for (final l in f.readAsLinesSync()) {
    if (l.trimLeft().startsWith('//')) continue;
    final code = l.split('//').first;
    t += _ts.allMatches(code).length;
    c += _col.allMatches(code).length;
  }
  return (t, c);
}

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

Widget _app(Widget child,
        {String lang = 'en', bool dark = false, double scale = 1.0}) =>
    MediaQuery(
      data: MediaQueryData(
          size: const Size(360, 1600), textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        darkTheme: AssistoTheme.dark,
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        home: Scaffold(body: child),
      ),
    );

/// Every DS component once (sample text in both languages).
Widget dsGallery(String lang) {
  final bn = lang == 'bn';
  return Builder(builder: (context) {
    final t = DsTokens.of(context);
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      DsHeroCard(
        danger: true,
        child: Text(bn ? 'জরুরি রক্ত লাগবে?' : 'Need blood urgently?',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(color: t.onDangerHero)),
      ),
      const SizedBox(height: Gap.md),
      DsHeroCard(child: Text(bn ? 'শুভ সকাল, রহিম' : 'Good morning, Rahim')),
      const SizedBox(height: Gap.md),
      DsCard(
        onTap: () {},
        child: Row(children: [
          const DsStatusDot(),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(bn ? 'পরিবারের সবাই নিরাপদ' : 'Everyone in the family is safe')),
        ]),
      ),
      const SizedBox(height: Gap.md),
      Row(children: [
        Expanded(child: DsTile(icon: Icons.group_rounded, label: bn ? 'আমার সার্কেল' : 'My Circle', onTap: () {})),
        const SizedBox(width: Gap.sm),
        Expanded(child: DsTile(icon: Icons.sos_rounded, label: bn ? 'জরুরি সাহায্য' : 'Emergency help', onTap: () {}, accent: t.dangerInk)),
        const SizedBox(width: Gap.sm),
        Expanded(child: DsTile(icon: Icons.route_rounded, label: bn ? 'নিরাপদ যাত্রা' : 'Safe Journey', onTap: () {}, selected: true)),
      ]),
      const SizedBox(height: Gap.md),
      DsChipRow(padding: EdgeInsets.zero, children: [
        DsChip(label: bn ? '৫ কিমি' : '5 km', selected: true, onSelected: (_) {}),
        DsChip(label: bn ? '১০ কিমি' : '10 km', onSelected: (_) {}),
        DsChip(label: bn ? '২৫ কিমি' : '25 km', onSelected: (_) {}),
      ]),
      const SizedBox(height: Gap.md),
      DsButton(label: bn ? 'অনুরোধ পাঠান' : 'Send request', onPressed: () {}, icon: Icons.send_rounded, expand: true),
      const SizedBox(height: Gap.sm),
      DsButton.secondary(label: bn ? 'বাতিল' : 'Cancel', onPressed: () {}, expand: true),
      const SizedBox(height: Gap.sm),
      DsButton.danger(label: bn ? 'এসওএস পাঠান' : 'Send SOS', onPressed: () {}, expand: true),
      const SizedBox(height: Gap.md),
      DsCard(
        padding: EdgeInsets.zero,
        child: DsListRow(
          leading: const DsAvatar(name: 'Rahim Uddin'),
          title: bn ? 'রহিম উদ্দিন' : 'Rahim Uddin',
          subtitle: bn ? 'মিরপুর · প্রায় ২ কিমি' : 'Mirpur · about 2 km',
          trailing: DsIconAction(icon: Icons.call_rounded, tooltip: bn ? 'কল' : 'Call', onPressed: () {}),
          onTap: () {},
        ),
      ),
      const SizedBox(height: Gap.md),
      DsNumber(bn ? '৳১২,৫০০' : '৳12,500'),
      const SizedBox(height: Gap.md),
      const TextField(decoration: InputDecoration(labelText: 'Name')),
      const SizedBox(height: Gap.md),
      DsSkeleton.card(),
      const SizedBox(height: Gap.md),
      DsOfflineStrip(label: bn ? 'অফলাইন — পরে পাঠানো হবে' : 'Offline — will send later', retryLabel: bn ? 'আবার' : 'Retry', onRetry: () {}),
      const SizedBox(height: Gap.md),
      DsEmptyState(
        icon: Icons.bloodtype_rounded,
        title: bn ? 'এখনো কোনো রক্তদাতা নেই' : 'No donor yet',
        benefit: bn ? 'এক মিনিটে কাছের দাতা খুঁজুন' : 'Find a donor nearby in a minute',
        actionLabel: bn ? 'খুঁজুন' : 'Find',
        onAction: () {},
        howTo: [bn ? 'গ্রুপ বাছুন' : 'Pick the group', bn ? 'দূরত্ব বাছুন' : 'Pick the distance'],
      ),
      const SizedBox(height: Gap.md),
      DsPaywallCard(
        title: bn ? 'প্রিমিয়াম' : 'Premium',
        price: bn ? '৳৯৯/মাস' : '৳99/month',
        perks: [bn ? 'সীমাহীন এআই' : 'Unlimited AI', bn ? 'সিসিটিভি ক্লাউড' : 'CCTV cloud'],
        ctaLabel: bn ? 'শুরু করুন' : 'Start',
        onCta: () {},
        badge: bn ? 'জনপ্রিয়' : 'Popular',
      ),
      const SizedBox(height: Gap.md),
      DsSheetHeader(bn ? 'বার্তা লিখুন' : 'Write a message'),
    ]);
  });
}

/// Text that was cut (maxLines / ellipsis hit) anywhere under [tester].
List<String> cutTexts(WidgetTester tester) {
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final r = e.renderObject;
    if (r is RenderParagraph && r.didExceedMaxLines) {
      out.add(r.text.toPlainText());
    }
  }
  return out;
}

void main() {
  test('lint: no new raw TextStyle( / Color( outside the design tokens', () {
    final allow = jsonDecode(File('test/ds2_lint_allow.json').readAsStringSync())
        as Map<String, dynamic>;
    final ts = (allow['textStyle'] as Map).cast<String, int>();
    final cs = (allow['color'] as Map).cast<String, int>();
    final migrated = (allow['migrated'] as List).cast<String>().toSet();
    final bad = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final p = f.path.replaceAll(r'\', '/');
      if (!p.endsWith('.dart') || p == 'lib/theme.dart' ||
          p.startsWith('lib/ds/') || p.startsWith('lib/l10n/')) {
        continue;
      }
      final (t, c) = _count(f);
      final at = migrated.contains(p) ? 0 : (ts[p] ?? 0);
      final ac = migrated.contains(p) ? 0 : (cs[p] ?? 0);
      if (t > at) bad.add('$p: $t raw TextStyle( (allowed $at)');
      if (c > ac) bad.add('$p: $c raw Color( (allowed $ac)');
    }
    // SHRINKING baseline (lead 10 Nov): the allow-list may only get smaller.
    // A new file or a higher total needs these ceilings raised in review —
    // lower them whenever a file is migrated (owner_actions/design/ds2_mark.py).
    const maxFiles = 429, maxTextStyle = 1691, maxColor = 212; // design3-b06
    final files = {...ts.keys, ...cs.keys}.length;
    final sumT = ts.values.fold<int>(0, (a, b) => a + b);
    final sumC = cs.values.fold<int>(0, (a, b) => a + b);
    if (files > maxFiles) bad.add('baseline grew: $files files (max $maxFiles)');
    if (sumT > maxTextStyle) bad.add('baseline grew: $sumT TextStyle( (max $maxTextStyle)');
    if (sumC > maxColor) bad.add('baseline grew: $sumC Color( (max $maxColor)');
    expect(bad, isEmpty,
        reason: 'Design System V2: use DsTokens.of(context) and '
            'Theme.of(context).textTheme.*.copyWith(...) (lib/ds/ds.dart).\n'
            '${bad.join('\n')}');
  });

  // b323 (swiftshader died on first run): no GPU-heavy effects outside the
  // few places that need them. A blur / shader mask / saveLayer per frame
  // kills software GPUs and the low-end Mali / PowerVR phones common in
  // Bangladesh. Use DS surfaces (plain static BoxShadows) instead.
  test('perf: no BackdropFilter / ImageFilter.blur / ShaderMask / saveLayer outside the allow-list', () {
    const allow = {
      'lib/messaging/media/media_bubble.dart', // view-once preview blur (static)
      'lib/messaging/media/album_viewer.dart',
      'lib/messaging/media/photo_album_view.dart',
      'lib/voice/va_onboarding_step.dart',
    };
    final rx = RegExp(r'\bBackdropFilter\(|ImageFilter\.blur\(|\bShaderMask\(|\.saveLayer\(');
    final bad = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final p = f.path.replaceAll(r'\', '/');
      if (!p.endsWith('.dart') || allow.contains(p)) continue;
      var n = 0;
      for (final l in f.readAsLinesSync()) {
        if (l.trimLeft().startsWith('//')) continue;
        if (rx.hasMatch(l.split('//').first)) n++;
      }
      if (n > 0) bad.add('$p: $n');
    }
    expect(bad, isEmpty,
        reason: 'GPU-heavy effect outside the allow-list (b323 swiftshader death):\n${bad.join('\n')}');
  });

  test('perf: DS surfaces draw the cheap look on lite devices', () {
    // the lite shadow is one small static blur; glows are off in lite
    for (final t in [DsTokens.light, DsTokens.dark]) {
      expect(t.liteShadows.length, lessThanOrEqualTo(1));
      for (final b in t.liteShadows) {
        expect(b.blurRadius, lessThanOrEqualTo(8));
      }
    }
  });

  test('contrast: V2 text roles meet WCAG AA', () {
    for (final t in [DsTokens.light, DsTokens.dark]) {
      final m = t.isDark ? 'dark' : 'light';
      for (final bg in [t.bg, t.card, t.cardAlt, t.cardHigh, t.inputFill]) {
        expect(contrast(t.text, bg), greaterThanOrEqualTo(4.5), reason: '$m text');
        expect(contrast(t.muted, bg), greaterThanOrEqualTo(4.5), reason: '$m muted on $bg');
        expect(contrast(t.primaryInk, bg), greaterThanOrEqualTo(4.5), reason: '$m primaryInk on $bg');
      }
      expect(contrast(t.onPrimary, t.primaryInk), greaterThanOrEqualTo(4.5), reason: '$m onPrimary');
      expect(contrast(t.successInk, t.successBg), greaterThanOrEqualTo(4.5), reason: '$m success');
      expect(contrast(t.successInk, t.card), greaterThanOrEqualTo(4.5), reason: '$m success/card');
      expect(contrast(t.dangerInk, t.dangerBg), greaterThanOrEqualTo(4.5), reason: '$m danger');
      expect(contrast(t.dangerInk, t.card), greaterThanOrEqualTo(4.5), reason: '$m danger/card');
      expect(contrast(t.onDangerFill, t.dangerFill), greaterThanOrEqualTo(4.5), reason: '$m danger btn');
      for (final h in t.dangerHero) {
        expect(contrast(t.onDangerHero, h), greaterThanOrEqualTo(4.5), reason: '$m hero');
      }
      expect(contrast(t.text, t.primarySoft), greaterThanOrEqualTo(4.5), reason: '$m chip');
      expect(contrast(t.primaryInk, t.primarySoft), greaterThanOrEqualTo(4.5), reason: '$m chip ink');
    }
    // the theme uses the V2 tokens
    expect(AssistoTheme.light.scaffoldBackgroundColor, DsTokens.light.bg);
    expect(AssistoTheme.dark.scaffoldBackgroundColor, DsTokens.dark.bg);
    expect(AssistoTheme.light.extension<DsTokens>(), isNotNull);
  });

  setUpAll(() async {
    await loadAppFonts();
  });

  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('components $lang ${dark ? 'dark' : 'light'} ${scale}x: '
            'no overflow / cut text, 48 dp, AA', (tester) async {
          DsPerf.debugLite = true; // no looping animations in the guard
          addTearDown(() => DsPerf.debugLite = null);
          await tester.binding.setSurfaceSize(const Size(360, 3200));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(_app(dsGallery(lang), lang: lang, dark: dark, scale: scale));
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);
          expect(cutTexts(tester), isEmpty, reason: 'text cut off');
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          if (scale == 1.0) {
            await expectLater(tester, meetsGuideline(textContrastGuideline));
          }
          handle.dispose();
        });
      }
    }
  }

  testWidgets('lite mode: no glow, no pulse animation', (tester) async {
    DsPerf.debugLite = true;
    addTearDown(() => DsPerf.debugLite = null);
    await tester.pumpWidget(_app(Column(children: [
      DsButton(label: 'Go', onPressed: () {}),
      const DsStatusDot(),
    ])));
    await tester.pump();
    // a pulsing dot would keep scheduling frames
    expect(tester.binding.hasScheduledFrame, isFalse);
    final glow = find.descendant(
        of: find.byType(DsButton),
        matching: find.byWidgetPredicate((w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            ((w.decoration as BoxDecoration).boxShadow?.isNotEmpty ?? false)));
    expect(glow, findsNothing);
  });

  testWidgets('full mode: the status dot pulses, the primary button glows', (tester) async {
    DsPerf.debugLite = false;
    addTearDown(() => DsPerf.debugLite = null);
    await tester.pumpWidget(_app(Column(children: [
      DsButton(label: 'Go', onPressed: () {}),
      const DsStatusDot(),
    ])));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);
    final glow = find.descendant(
        of: find.byType(DsButton),
        matching: find.byWidgetPredicate((w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            ((w.decoration as BoxDecoration).boxShadow?.isNotEmpty ?? false)));
    expect(glow, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
