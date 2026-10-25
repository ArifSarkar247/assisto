// call-reply review shots — NOT part of the CI suite (no _test suffix).
// Run on demand:
//   flutter test test/call_reply_shots.dart
// Writes the incoming call screen (with Reply) and the quick-reply sheet,
// bn/en (sheet in light + dark), to owner_actions/call_reply/.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:assisto/calls/call_reply.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_fonts.dart';

final _out = Platform.environment['ASSISTO_SHOT_DIR'] ??
    '${Directory.current.path}/../owner_actions/call_reply';

PushPayload _p(String lang) => PushPayload({
      'kind': 'call',
      'call_id': '7',
      'chat_id': '3',
      'caller_name': lang == 'bn' ? 'আয়েশা রহমান' : 'Ayesha Rahman',
      'video': 'false',
      'lang': lang,
    });

/// A stand-in for the chat underneath the sheet (header + composer).
class _ChatBehind extends StatelessWidget {
  const _ChatBehind({required this.name});
  final String name;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(name)),
        body: const SizedBox.expand(),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: TextField(
                decoration: InputDecoration(
                    hintText: AppLocalizations.of(context).callReplyWriteOwn)),
          ),
        ),
      );
}

void main() {
  setUpAll(() async {
    await loadAppFonts();
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons =
        '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(icons).existsSync()) {
      final l = FontLoader('MaterialIcons')
        ..addFont(
            File(icons).readAsBytes().then((b) => ByteData.view(b.buffer)));
      await l.load();
    }
    Directory(_out).createSync(recursive: true);
  });

  const calls = MethodChannel('com.assisto/calls');
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(calls, (c) async => true));

  Future<void> shoot(WidgetTester t, String file, Widget home, bool dark,
      String lang, {Future<void> Function(WidgetTester)? then}) async {
    debugDisableShadows = false;
    await t.binding.setSurfaceSize(const Size(360, 780));
    final key = GlobalKey();
    await t.pumpWidget(RepaintBoundary(
      key: key,
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
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        home: home,
      ),
    ));
    await t.pump(const Duration(milliseconds: 400));
    if (then != null) await then(t);
    final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await t.runAsync(() => b.toImage(pixelRatio: 2)) as ui.Image;
    final bytes = await t
        .runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
    File('$_out/$file.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    img.dispose();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 65));
    debugDisableShadows = true;
    await t.binding.setSurfaceSize(null);
  }

  for (final lang in ['bn', 'en']) {
    testWidgets('incoming $lang', (t) async {
      await shoot(t, 'incoming_$lang',
          IncomingCallScreen(payload: _p(lang), onReply: (_) {}), true, lang);
    });
    for (final dark in [false, true]) {
      final mode = dark ? 'dark' : 'light';
      testWidgets('sheet $lang $mode', (t) async {
        final name = _p(lang).callerName;
        await shoot(
            t,
            'sheet_${lang}_$mode',
            Builder(
                builder: (ctx) => _ChatBehind(name: name)),
            dark,
            lang, then: (t) async {
          final ctx = t.element(find.byType(_ChatBehind));
          final input = TextEditingController();
          // ignore: unawaited_futures
          runCallQuickReply(ctx,
              name: name, input: input, send: () async {}, focus: () {});
          await t.pumpAndSettle();
        });
      });
    }
  }
}
