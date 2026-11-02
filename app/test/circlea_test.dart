// circlea — My Circle A1: links in chat (linkify edge cases, safe-link
// check + interstitial, E2E preview never readable outside the encryption),
// Family / Others lists + pickers, and the Guardians screen (2 parents x 2
// children). bn + en, 200 % text, dark theme, TalkBack tap targets.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/ring_decrypt.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/link_open.dart';
import 'package:assisto/messaging/link_preview_client.dart';
import 'package:assisto/messaging/linkify.dart';
import 'package:assisto/messaging/safe_link.dart';
import 'package:assisto/screens/circle_guardians_screen.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/circle_bubble.dart';
import 'package:assisto/widgets/circle_people_filter.dart';

Widget _app(Widget child,
    {String lang = 'en', double scale = 1.0, bool dark = false, bool scroll = true}) {
  return MaterialApp(
    locale: Locale(lang),
    theme: dark ? AssistoTheme.dark : AssistoTheme.light,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (ctx, c) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: scroll ? Scaffold(body: SingleChildScrollView(child: child)) : child,
  );
}

List<String> _links(String s) => [for (final p in linkify(s)) if (p.isLink) p.text];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    linkLauncherOverride = null;
    shortenerResolverOverride = null;
    guardiansLoaderOverride = null;
    guardianRemoveOverride = null;
  });

  // ------------------------------------------------------------ linkify
  group('linkify', () {
    test('scheme links, trailing punctuation stays text', () {
      expect(_links('see https://example.com/a.'), ['https://example.com/a']);
      expect(_links('wow https://x.com!'), ['https://x.com']);
      expect(_links('"https://x.com/q?a=1&b=2", ok'), ['https://x.com/q?a=1&b=2']);
      expect(_links("it's 'https://x.com'"), ['https://x.com']);
      final p = linkify('see https://example.com/a.');
      expect(p.map((x) => x.text).join(), 'see https://example.com/a.');
      expect(p.last.text, '.');
    });

    test('balanced brackets kept, unbalanced dropped', () {
      expect(_links('(https://en.wikipedia.org/wiki/Dhaka_(city))'),
          ['https://en.wikipedia.org/wiki/Dhaka_(city)']);
      expect(_links('(see https://x.com/a)'), ['https://x.com/a']);
    });

    test('Bangla text glued to a link ends it', () {
      expect(_links('লিংক:https://x.com/aভাই দেখো'), ['https://x.com/a']);
      expect(_links('দেখো https://youtu.be/abc।'), ['https://youtu.be/abc']);
      expect(_links('দোকান daraz.com.bd।'), ['daraz.com.bd']);
    });

    test('reels / youtube / facebook / tiktok / www / bare domains', () {
      expect(_links('https://www.facebook.com/reel/123 and https://www.tiktok.com/@a/video/9'),
          ['https://www.facebook.com/reel/123', 'https://www.tiktok.com/@a/video/9']);
      expect(_links('song youtu.be/dQw4w9WgXcQ now'), ['youtu.be/dQw4w9WgXcQ']);
      expect(firstLink('song youtu.be/dQw4w9WgXcQ now'), 'https://youtu.be/dQw4w9WgXcQ');
      expect(_links('go to www.google.com, ok'), ['www.google.com']);
      expect(_links('fb.com/page and bit.ly/abc'), ['fb.com/page', 'bit.ly/abc']);
      expect(firstLink('Visit daraz.com.bd'), 'https://daraz.com.bd');
    });

    test('emails, phone numbers, decimals, file names are left alone', () {
      expect(_links('mail rina@example.com now'), isEmpty);
      expect(_links('call 01711-000000 or +8801711000000'), isEmpty);
      expect(_links('০১৭১১-০০০০০০'), isEmpty);
      expect(_links('v2.0 is 3.5 times better, see photo.jpg'), isEmpty);
      expect(_links('Mr.Rahim said hello.World'), isEmpty);
      expect(_links('http:// nothing'), isEmpty);
      expect(_links('wa.me without path? fb.me'), isEmpty);
      expect(linkify(''), isEmpty);
      expect(firstLink('no links here'), isNull);
    });

    test('text round-trips exactly', () {
      const s = 'A https://a.com/x, B (www.b.com) C rina@c.com D daraz.com.bd।';
      expect(linkify(s).map((p) => p.text).join(), s);
    });
  });

  // ------------------------------------------------------------ safe link
  group('safe link (on the phone)', () {
    LinkVerdict v(String u) => checkLink(u).verdict;
    test('official links are ok', () {
      for (final u in [
        'https://www.bkash.com/', 'https://www.facebook.com/reel/123', 'https://youtu.be/abc',
        'https://www.youtube.com/watch?v=1', 'https://www.tiktok.com/@a/video/1',
        'https://nagad.com.bd/', 'https://rocketchat.com', 'https://lh3.googleusercontent.com/x',
      ]) {
        expect(v(u), LinkVerdict.ok, reason: u);
      }
    });
    test('payment / login lookalikes are bad', () {
      for (final u in [
        'https://bkash-bonus.xyz/login', 'http://b1kash.com', 'https://bkassh.com',
        'https://nagad.com.bd.verify-now.top/', 'https://foo.com/bkash/login',
        'https://xn--bkash-9za.com', 'https://user@evil.com', 'https://faceb00k-login.com',
      ]) {
        expect(v(u), LinkVerdict.bad, reason: u);
      }
      expect(checkLink('https://bkash-bonus.xyz/login').brand, 'bkash');
    });
    test('warnings', () {
      expect(checkLink('https://bit.ly/abc').reasons, contains('shortener'));
      expect(checkLink('http://example.com').reasons, contains('not_https'));
      expect(checkLink('https://8.8.8.8/x').reasons, contains('ip_host'));
      expect(checkLink('https://example.zip/').reasons, contains('suspicious_tld'));
      expect(v('https://bit.ly/abc'), LinkVerdict.warn);
    });
  });

  // ------------------------------------------------------- E2E preview
  group('E2E link preview', () {
    test('parse og tags, never a local image', () {
      const html = '<html><head><meta property="og:title" content="Tea &amp; rain">'
          '<meta content="Facebook" property="og:site_name">'
          '<meta property="og:image" content="/i.png"><title>x</title></head></html>';
      final d = parsePreviewHtml('https://www.facebook.com/reel/1', html)!;
      expect(d.title, 'Tea & rain');
      expect(d.site, 'Facebook');
      expect(previewImageUrl('https://www.facebook.com/reel/1', html),
          'https://www.facebook.com/i.png');
      expect(previewImageUrl('https://x.com/',
          '<meta property="og:image" content="http://192.168.1.1/a.png">'), isNull);
      expect(isLocalHost('10.0.0.1'), isTrue);
      expect(isLocalHost('169.254.169.254'), isTrue);
      expect(isLocalHost('router.local'), isTrue);
      expect(isLocalHost('example.com'), isFalse);
      expect(parsePreviewHtml('https://x.com', '<html></html>'), isNull);
    });

    test('the preview travels ONLY inside the encryption', () {
      final e2e = SoftwareE2E();
      final a = e2e.generateIdentity(), b = e2e.generateIdentity();
      final d = LinkPreviewData(
          url: 'https://www.facebook.com/reel/42',
          title: 'Secret family reel',
          site: 'Facebook',
          image: Uint8List.fromList(List.filled(64, 7)));
      final env = e2e
          .encrypt(self: a, recipientPublicKey: b.publicKey, plaintext: d.encode())
          .toEnvelopeFields();
      // exactly the opaque keys the relay accepts — no url / title / image
      expect(env.keys.toSet(), {'scheme', 'ciphertext', 'nonce', 'sender_key_id'});
      final wire = jsonEncode({'content_type': 'text', 'link_preview': env});
      for (final leak in ['facebook', 'reel', 'Secret', 'http']) {
        expect(wire.contains(leak), isFalse, reason: leak);
      }
      // the receiver opens it with the normal key ring
      final pt = RingDecrypt.openEnvelope(env, ring: [b], peerKeys: [a.publicKey]);
      final got = LinkPreviewData.tryDecode(pt)!;
      expect(got.title, 'Secret family reel');
      expect(got.image, d.image);
      // junk / non-web URLs are dropped
      expect(LinkPreviewData.tryDecode('{"v":1,"url":"javascript:x","title":"t"}'), isNull);
      expect(LinkPreviewData.tryDecode('not json'), isNull);
    });
  });

  // ------------------------------------------------- open + interstitial
  group('open safely', () {
    Future<List<Uri>> pumpOpen(WidgetTester tester, String url,
        {String lang = 'en'}) async {
      final opened = <Uri>[];
      linkLauncherOverride = (u) async {
        opened.add(u);
        return true;
      };
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => TextButton(
              onPressed: () => openLinkSafely(ctx, url), child: const Text('go'))),
          lang: lang));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return opened;
    }

    testWidgets('an ok link opens at once', (tester) async {
      final opened = await pumpOpen(tester, 'https://www.youtube.com/watch?v=1');
      expect(opened.single.host, 'www.youtube.com');
      expect(find.byKey(const Key('cla-warn-title')), findsNothing);
    });

    testWidgets('a lookalike warns; Go back never opens', (tester) async {
      final opened = await pumpOpen(tester, 'http://bkash-bonus.xyz/login');
      expect(find.byKey(const Key('cla-warn-title')), findsOneWidget);
      expect(find.text('This link may be a trap'), findsOneWidget);
      expect(find.textContaining('bkash-bonus.xyz'), findsWidgets);
      await tester.tap(find.byKey(const Key('cla-go-back')));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
    });

    testWidgets('Open anyway opens (bn)', (tester) async {
      final opened = await pumpOpen(tester, 'http://example.com/', lang: 'bn');
      expect(find.text('খোলার আগে লিংকটা দেখে নিন'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cla-open-anyway')));
      await tester.pumpAndSettle();
      expect(opened.length, 1);
    });

    testWidgets('a short link shows its REAL destination', (tester) async {
      shortenerResolverOverride = (u) async => 'https://bkash-login.top/x';
      final opened = await pumpOpen(tester, 'https://bit.ly/zz');
      expect(find.text('This link may be a trap'), findsOneWidget);
      expect(find.byKey(const Key('cla-warn-destination')), findsOneWidget);
      expect(find.textContaining('bkash-login.top'), findsWidgets);
      expect(opened, isEmpty);
    });

    testWidgets('links in a bubble are tappable; preview card shows', (tester) async {
      final opened = <Uri>[];
      linkLauncherOverride = (u) async {
        opened.add(u);
        return true;
      };
      await tester.pumpWidget(_app(CircleBubble(
        msg: CircleMessage(
            id: '1', text: 'look https://www.youtube.com/watch?v=1 ok', mine: false,
            at: DateTime(2026, 11, 2)),
        linkPreview: const LinkPreviewData(
            url: 'https://www.youtube.com/watch?v=1', title: 'A song', site: 'YouTube'),
      )));
      expect(find.byKey(const Key('cla-linkified')), findsOneWidget);
      expect(find.text('A song'), findsOneWidget);
      await tester.tapOnText(find.textRange.ofSubstring('youtube.com'));
      await tester.pumpAndSettle();
      expect(opened.single.host, 'www.youtube.com');
    });

    testWidgets('warning sheet: 200 % text, dark, tap targets', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final lang in ['bn', 'en']) {
        await tester.pumpWidget(_app(
            const LinkWarningSheet(
                url: 'http://bkash-bonus.xyz/login',
                destination: 'bkash-bonus.xyz',
                reasons: ['lookalike', 'not_https', 'suspicious_tld'],
                brand: 'bkash',
                bad: true),
            lang: lang,
            scale: 2.0,
            dark: true));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      }
      handle.dispose();
    });
  });

  // ------------------------------------------------- Family / Others
  group('Family / Others', () {
    final rows = <Map<String, dynamic>>[
      {'id': 1, 'name': 'Karim', 'relation': 'colleague', 'circle_group': 'others'},
      {'id': 2, 'name': 'Ammu', 'relation': 'mother', 'circle_group': 'family'},
      {'id': 3, 'name': 'Shila', 'relation': 'friend', 'circle_group': 'others', 'phone': '01911000004'},
      {'id': 4, 'name': 'Nani', 'relation': 'relative'}, // older server: no field
      {'id': 5, 'name': 'Boss', 'relation': 'mother', 'circle_group': 'others'}, // user's mark wins
      {'id': 6, 'name': 'Driver', 'relation': 'custom', 'circle_group': 'others'},
    ];

    test('group, filter, search, sections (Family first)', () {
      expect(circleGroupOf(rows[3]), 'family');
      expect(circleGroupOf(rows[4]), 'others');
      expect(filterPeople(rows, PeopleFilter.family, '').map((r) => r['name']),
          ['Ammu', 'Nani']);
      expect(filterPeople(rows, PeopleFilter.others, '').length, 4);
      expect(filterPeople(rows, PeopleFilter.all, 'shi').single['name'], 'Shila');
      // Bangla digits find the number
      expect(filterPeople(rows, PeopleFilter.all, '০১৯১১').single['name'], 'Shila');
      final s = sectionPeople(rows);
      expect(s.map((e) => e.$1), ['family', 'others']);
      expect(sectionPeople(<Map>[]), isEmpty);
    });

    Widget list({PeopleFilter? start, List<Map<String, dynamic>>? r}) => CirclePeopleList(
          rows: r ?? rows,
          listKey: 'test',
          initialFilter: start,
          rowBuilder: (_, m) => ListTile(key: ValueKey('p-${m['id']}'), title: Text('${m['name']}')),
        );

    testWidgets('chips + search + sections, remembered per list', (tester) async {
      await tester.pumpWidget(_app(list()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cfa-section-family')), findsOneWidget);
      expect(find.byKey(const Key('cfa-section-others')), findsOneWidget);
      // Family first
      final famY = tester.getTopLeft(find.byKey(const ValueKey('p-2'))).dy;
      final othY = tester.getTopLeft(find.byKey(const ValueKey('p-1'))).dy;
      expect(famY < othY, isTrue);
      await tester.tap(find.byKey(const Key('cfa-test-chip-family')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('p-1')), findsNothing);
      expect(find.byKey(const ValueKey('p-2')), findsOneWidget);
      expect(await PeopleFilterStore.load('test'), PeopleFilter.family);
      expect(await PeopleFilterStore.load('other-list'), PeopleFilter.all);
      await tester.tap(find.byKey(const Key('cfa-test-chip-all')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cfa-test-search')), 'kar');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('p-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('p-2')), findsNothing);
    });

    testWidgets('empty Family: benefit + how-to + one tap back (bn)', (tester) async {
      await tester.pumpWidget(_app(
          list(start: PeopleFilter.family, r: [rows[0], rows[2]]),
          lang: 'bn'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cfa-empty')), findsOneWidget);
      expect(find.text('পরিবার'), findsWidgets);
      await tester.tap(find.byKey(const Key('cfa-show-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('p-1')), findsOneWidget);
    });

    testWidgets('200 % text + dark: no overflow, 48 dp chips', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final lang in ['bn', 'en']) {
        await tester.pumpWidget(_app(list(start: PeopleFilter.all), lang: lang, scale: 2.0, dark: true));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      }
      handle.dispose();
    });
  });

  // ------------------------------------------------- Guardians screen
  group('Guardians (2 parents x 2 children)', () {
    Map<String, dynamic> mine(bool withDad) => {
          'guardians': [
            if (withDad)
              {'id': 11, 'name': 'Dad', 'removable': true, 'sources': [
                {'kind': 'kids_watch', 'removable': false, 'set_up_by': 'Dad'},
                {'kind': 'school_mode', 'removable': true, 'set_up_by': 'Mom'},
              ]},
            {'id': 10, 'name': 'Mom', 'removable': true, 'sources': [
              {'kind': 'school_mode', 'removable': true, 'set_up_by': 'Mom'},
            ]},
          ]
        };
    final kids = {
      'children': [
        {'key': 'u3', 'name': 'Rina', 'sources': [{'kind': 'school_mode'}],
          'co_guardians': [{'id': 11, 'name': 'Dad'}]},
        {'key': 'u4', 'name': 'Babu', 'sources': [{'kind': 'journey'}], 'co_guardians': []},
      ]
    };

    testWidgets('every watcher by name; co-guardians; remove (en)', (tester) async {
      guardiansLoaderOverride = (p) async => p.endsWith('mine') ? mine(true) : kids;
      final removed = <int>[];
      guardianRemoveOverride = (uid) async {
        removed.add(uid);
        return {'ok': true, ...mine(false), 'removed': [{'kind': 'school_mode'}],
          'kept': [{'kind': 'kids_watch', 'set_up_by': 'Dad'}]};
      };
      await tester.pumpWidget(_app(const CircleGuardiansScreen(), scroll: false));
      await tester.pumpAndSettle();
      expect(find.text('Dad'), findsWidgets);
      expect(find.text('Mom'), findsOneWidget);
      expect(find.textContaining('only they can change who sees it'), findsOneWidget);
      expect(find.text('Also looking after: Dad'), findsOneWidget);
      expect(find.text('Only you look after this child.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cga-remove-11')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cga-remove-confirm')));
      await tester.pumpAndSettle();
      expect(removed, [11]);
      expect(find.byKey(const ValueKey('cga-guardian-11')), findsNothing);
      expect(find.textContaining('The watch stays'), findsOneWidget);
    });

    testWidgets('empty: honest line + a real next step (bn, 200 %, dark)', (tester) async {
      guardiansLoaderOverride = (p) async =>
          p.endsWith('mine') ? {'guardians': []} : {'children': []};
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
          _app(const CircleGuardiansScreen(), lang: 'bn', scale: 2.0, dark: true, scroll: false));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('cga-mine-empty')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('cga-kids-start')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const Key('cga-kids-start')), findsOneWidget);
    });
  });
}
