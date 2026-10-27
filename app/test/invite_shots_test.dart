// invite-join: before/after screenshots without the full gallery (the same
// specs are also registered in screenshots_test.dart). Writes PNGs to
// $ASSISTO_SHOT_DIR only when it is set; otherwise just renders (smoke).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/language_picker_screen.dart';
import 'package:assisto/screens/login_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'app_fonts.dart';
import 'invite_shots.dart';

final _out = Platform.environment['ASSISTO_SHOT_DIR'];

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await loadAppFonts();
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final l = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.view(b.buffer)));
      await l.load();
    }
  });
  final specs = <String, Widget Function(String)>{
    'before_login': (l) => SignedOut(lang: l, child: const LoginScreen()),
    'before_language_picker': (l) => SignedOut(lang: l, child: const LanguagePickerScreen()),
    ...inviteShots,
  };
  for (final e in specs.entries) {
    for (final lang in ['bn', 'en']) {
      for (final b in [Brightness.light, Brightness.dark]) {
        testWidgets('shot ${e.key} $lang ${b.name}', (tester) async {
          await tester.binding.setSurfaceSize(const Size(360, 800));
          final key = GlobalKey();
          final app = AppState()
            ..locale = Locale(lang)
            ..loading = false;
          await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
            value: app,
            child: RepaintBoundary(
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
                theme: AssistoTheme.light,
                darkTheme: AssistoTheme.dark,
                themeMode: b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
                home: e.value(lang),
              ),
            ),
          ));
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
          expect(tester.takeException(), isNull);
          if (_out == null) return;
          final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final img = await tester.runAsync(() => rb.toImage(pixelRatio: 2)) as ui.Image;
          final bytes = await tester.runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
          Directory(_out!).createSync(recursive: true);
          File('$_out/${e.key}_${lang}_${b.name}.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          img.dispose();
        });
      }
    }
  }
}
