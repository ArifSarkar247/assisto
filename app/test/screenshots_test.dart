import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/state.dart';
import 'package:assisto/models.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/login_screen.dart';
import 'package:assisto/screens/language_picker_screen.dart';
import 'package:assisto/screens/home_screen.dart';
import 'package:assisto/screens/app_drawer.dart';
import 'package:assisto/screens/settings_screen.dart';
import 'package:assisto/screens/in_progress_screen.dart';

/// Block ALL real network in the render harness — any screen that polls on
/// open (e.g. /alerts) must fail fast, not stall the isolate.
class _NoNet extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? c) => _DeadClient();
}

class _DeadClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw const SocketException('network disabled in screenshot tests');
}

const _outDir = '/home/ubuntu/assisto/screenshots';

Future<void> _loadFont(String family, String path) async {
  final loader = FontLoader(family);
  loader.addFont(
      File(path).readAsBytes().then((b) => ByteData.view(b.buffer)));
  await loader.load();
}

AppState _stubState({required String lang}) {
  final s = AppState();
  s.user = AppUser(
      id: 1,
      name: lang == 'bn' ? 'আরিফ' : 'Arif',
      phone: '01712345678',
      email: '',
      autonomyLevel: 2,
      language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

void main() {
  setUpAll(() async {
    HttpOverrides.global = _NoNet();
    await _loadFont('NotoSansBengali', 'assets/fonts/NotoSansBengali.ttf');
    // Material icons + a Latin fallback so renders look real (not Ahem boxes).
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons =
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(icons).existsSync()) await _loadFont('MaterialIcons', icons);
    Directory(_outDir).createSync(recursive: true);
  });

  final screens = <String, Widget Function(String)>{
    'login': (_) => const LoginScreen(),
    'language_picker': (_) => const LanguagePickerScreen(),
    'home_welcome': (_) => const HomeScreen(),
    'drawer': (_) => Scaffold(body: Row(children: [AppDrawer(onNewChat: () {})])),
    'settings': (_) => const SettingsScreen(),
    'in_progress': (_) => const InProgressScreen(),
  };

  for (final lang in ['bn', 'en']) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final mode = brightness == Brightness.light ? 'light' : 'dark';
      screens.forEach((name, builder) {
        testWidgets('shot $name $lang $mode', (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 844));
          final key = GlobalKey();
          final app = _stubState(lang: lang);
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<AppState>.value(value: app),
                ChangeNotifierProvider<Updater>(create: (_) => Updater()),
              ],
              child: RepaintBoundary(
                key: key,
                child: MediaQuery(
                  data: const MediaQueryData(size: Size(390, 844)),
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
                    themeMode:
                        brightness == Brightness.light ? ThemeMode.light : ThemeMode.dark,
                    home: Builder(builder: (ctx) => builder(lang)),
                  ),
                ),
              ),
            ),
          );
          // Load real asset images (the logo) and capture — all in real async.
          await tester.runAsync(() async {
            for (final el in find.byType(Image).evaluate()) {
              final img = el.widget as Image;
              await precacheImage(img.image, el).timeout(
                  const Duration(seconds: 5),
                  onTimeout: () {});
            }
            await Future.delayed(const Duration(milliseconds: 200));
          });
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await tester.runAsync(
              () => boundary.toImage(pixelRatio: 2.0)) as ui.Image;
          final bytes = await tester.runAsync(
              () => image.toByteData(format: ui.ImageByteFormat.png));
          File('$_outDir/${name}_${lang}_$mode.png')
              .writeAsBytesSync((bytes!).buffer.asUint8List());
          image.dispose();
        });
      });
    }
  }
}
