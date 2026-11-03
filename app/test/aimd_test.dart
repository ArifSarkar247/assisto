// aifinal PART 1b: AI chat bubbles render safe markdown — bold, lists,
// links; never raw asterisks; links open only http/https after a confirm;
// no images or HTML.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/ai_markdown.dart';

Widget _app(Widget child, {String lang = 'en', double scale = 1, bool dark = false}) =>
    MaterialApp(
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
      builder: (ctx, w) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: w!),
      home: Scaffold(
          body: SingleChildScrollView(
              child: AiMarkdown(
                  text: child is Text ? child.data! : '',
                  color: Colors.black,
                  linkColor: Colors.blue))),
    );

String _all(List<AiBlock> b) =>
    b.map((x) => x.inlines.map((r) => r.text).join()).join('\n');

void main() {
  test('bold, italic, code and lists parse without raw asterisks', () {
    final b = parseAiMarkdown(
        '**ঢাকা** is *big*.\n\n* one\n- two\n1. first\n২. দ্বিতীয়\n# Title\n`x`');
    expect(_all(b).contains('*'), isFalse);
    expect(b.first.inlines.first.bold, isTrue);
    expect(b.first.inlines.first.text, 'ঢাকা');
    expect(b.where((x) => x.kind == 'ul').length, 2);
    expect(b.where((x) => x.kind == 'ol').map((x) => x.marker), ['1.', '২.']);
    expect(b.any((x) => x.kind == 'h'), isTrue);
    expect(b.last.inlines.single.code, isTrue);
  });

  test('unclosed bold markers never show asterisks', () {
    expect(_all(parseAiMarkdown('this is **broken')).contains('*'), isFalse);
  });

  test('links: only http/https become tappable', () {
    final b = parseAiMarkdown(
        '[ok](https://lifeassisto.com) [bad](javascript:alert(1)) [f](file:///x) see http://a.b/c.');
    final links = b.single.inlines.where((r) => r.url != null).toList();
    expect(links.map((r) => r.url),
        ['https://lifeassisto.com', 'http://a.b/c']);
    expect(aiSafeUrl('intent://x'), isFalse);
    expect(aiSafeUrl('tel:999'), isFalse);
  });

  test('images become alt text; HTML tags are stripped', () {
    final s = _all(parseAiMarkdown(
        '![a map](https://x.y/i.png) <img src=x onerror=1><b>hi</b><script>z</script>'));
    expect(s.contains('<'), isFalse);
    expect(s.contains('https://x.y/i.png'), isFalse);
    expect(s.contains('a map'), isTrue);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('link tap asks first ($lang); cancel opens nothing',
        (tester) async {
      await tester.pumpWidget(_app(const Text('Read **this** at [site](https://lifeassisto.com)'),
          lang: lang, scale: 2, dark: lang == 'bn'));
      expect(find.textContaining('**'), findsNothing);
      await tester.tap(find.textContaining('site', findRichText: true));
      await tester.pumpAndSettle();
      final t = AppLocalizations.of(tester.element(find.byType(AiMarkdown)));
      expect(find.text(t.aimdOpenLinkTitle), findsOneWidget);
      expect(find.text('https://lifeassisto.com'), findsOneWidget);
      await tester.tap(find.text(t.cancel));
      await tester.pumpAndSettle();
      expect(find.text(t.aimdOpenLinkTitle), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
