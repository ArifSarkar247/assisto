// sosat: AFTER screenshots for the owner (BEFORE = the same screens in
// main's gallery artifacts: emergency, safety, fall_detect). Writes PNGs to
// $ASSISTO_SHOT_DIR only when it is set; otherwise just renders (smoke).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/fall_detect_screen.dart';
import 'package:assisto/screens/sos_triggers_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/emergency_sos_panel.dart';
import 'package:assisto/widgets/sos_ladder_card.dart';

import 'app_fonts.dart';

final _out = Platform.environment['ASSISTO_SHOT_DIR'];

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  @override
  Future<Map<String, dynamic>> getJson(String path) async => {};
}

Map<String, dynamic> _ladder(String stage, bool bn) => {
      'stage': stage,
      'total': 2,
      'seen': stage == 'seen' ? 1 : 0,
      'recipients': [
        {'name': bn ? 'আম্মা' : 'Mother', 'status': 'sent', 'received': true, 'seen': stage == 'seen'},
        {'name': bn ? 'ভাইয়া' : 'Brother', 'status': 'no_device', 'received': false, 'seen': false},
      ],
    };

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await loadAppFonts();
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons = File(
        '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final l = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.view(b.buffer)));
      await l.load();
    }
  });
  Widget page(Widget w) => Scaffold(
      appBar: AppBar(title: const Text('SOS')),
      body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: w));
  final specs = <String, Widget Function(String)>{
    'sosat_sos_panel': (l) => page(EmergencySosPanel(
        contacts: const [], countdownSeconds: 5, onNoContact: () {})),
    'sosat_ladder_waiting': (l) => page(SosLadderCard(
        contacts: [
          {'name': l == 'bn' ? 'আম্মা' : 'Mother', 'phone': '01710000000'}
        ],
        load: () async => _ladder('waiting', l == 'bn'))),
    'sosat_ladder_999': (l) => page(SosLadderCard(
        contacts: [
          {'name': l == 'bn' ? 'আম্মা' : 'Mother', 'phone': '01710000000'}
        ],
        load: () async => _ladder('call_999', l == 'bn'))),
    'sosat_ladder_offline': (l) => page(SosLadderCard(contacts: [
          {'name': l == 'bn' ? 'আম্মা' : 'Mother', 'phone': '01710000000'}
        ], offline: true)),
    'sosat_triggers_off': (l) =>
        SosTriggersScreen(isRunning: () async => false, fallFlagOn: true),
    'sosat_triggers_on': (l) =>
        SosTriggersScreen(isRunning: () async => true, fallFlagOn: true),
    'sosat_fall': (l) => FallDetectScreen(
        isRunning: () async => true, pending: () async => {'pending': null}),
    'sosat_fall_check': (l) => const FallCheckScreen(clientId: 'f', seconds: 58),
  };
  for (final e in specs.entries) {
    for (final lang in ['bn', 'en']) {
      for (final b in [Brightness.light, Brightness.dark]) {
        testWidgets('shot ${e.key} $lang ${b.name}', (tester) async {
          await tester.binding.setSurfaceSize(const Size(360, 800));
          final key = GlobalKey();
          final app = AppState()
            ..api = _Api()
            ..locale = Locale(lang)
            ..user = AppUser(
                id: 1, name: 'A', phone: '01712345678', email: '',
                autonomyLevel: 2, language: lang)
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
                themeMode:
                    b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
                home: e.value(lang),
              ),
            ),
          ));
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
          expect(tester.takeException(), isNull);
          if (_out == null) return;
          final rb =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final img = await tester.runAsync(() => rb.toImage(pixelRatio: 2))
              as ui.Image;
          final bytes = await tester
              .runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
          Directory(_out!).createSync(recursive: true);
          File('$_out/${e.key}_${lang}_${b.name}.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          img.dispose();
          await tester.binding.setSurfaceSize(null);
        });
      }
    }
  }
}
