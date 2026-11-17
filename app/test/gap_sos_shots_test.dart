// gap-sos: AFTER screenshots (bn + en, light + dark) of the changed SOS
// states. BEFORE = main's gallery (sosat_ladder_offline, fcs alarm). Writes
// PNGs to $ASSISTO_SHOT_DIR only when it is set; otherwise just renders.
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
import 'package:assisto/family_sos/sos_alarm_screen.dart';
import 'package:assisto/family_sos/sos_retry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/emergency_sos_panel.dart';
import 'package:assisto/widgets/sos_ladder_card.dart';

import 'app_fonts.dart';
import 'fcsos_fakes.dart';

final _out = Platform.environment['ASSISTO_SHOT_DIR'];

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  @override
  Future<Map<String, dynamic>> getJson(String path) async => {};
}

class _NoEventApi extends FakeFcSosApi {
  _NoEventApi(String lang) : super(lang: lang);
  @override
  Future<Map<String, dynamic>> event(int deliveryId) async => throw Exception('offline');
}

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

  Widget page(Widget w) => Scaffold(
      appBar: AppBar(title: const Text('SOS')),
      body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: w));

  // name -> (widget, the key to show after the SOS hold — null = no hold)
  final specs = <String, (Widget Function(String), String?)>{
    'gapsos_panel_offline_trying': (
      (l) => page(EmergencySosPanel(
            contacts: [
              {'name': l == 'bn' ? 'আম্মা' : 'Mother', 'phone': '০১৭১১ ২০০০০২'}
            ],
            countdownSeconds: 0,
            onNoContact: () {},
            locate: () async => (23.7461, 90.3742),
            sendSos: (la, ln) async => throw Exception('offline'),
          )),
      'sos-still-trying'
    ),
    'gapsos_panel_sent_full': (
      (l) => page(EmergencySosPanel(
            contacts: [
              {'name': l == 'bn' ? 'আম্মা' : 'Mother', 'phone': '01711200002'}
            ],
            countdownSeconds: 0,
            onNoContact: () {},
            locate: () async => (23.7461, 90.3742),
            ladderLoad: () async => {'stage': 'seen', 'total': 1, 'seen': 1, 'recipients': []},
            sendSos: (la, ln) async => {'recipients': 2},
          )),
      'sos-open-full'
    ),
    'gapsos_ladder_nameless': (
      (l) => page(const SosLadderCard(contacts: [
            {'name': '', 'phone': '০১৭১১ ২০০০০২'}
          ], offline: true)),
      null
    ),
    'gapsos_alarm_no_net': (
      (l) => SosAlarmScreen(
          data: fcsPush(l), api: _NoEventApi(l), sound: FakeAlarmSound(), autoAlarm: false, country: 'BD'),
      null
    ),
  };
  for (final e in specs.entries) {
    for (final lang in ['bn', 'en']) {
      for (final b in [Brightness.light, Brightness.dark]) {
        testWidgets('shot ${e.key} $lang ${b.name}', (tester) async {
          SosRetry.stop();
          await tester.binding.setSurfaceSize(const Size(360, 800));
          final key = GlobalKey();
          final app = AppState()
            ..api = _Api()
            ..locale = Locale(lang)
            ..user = AppUser(
                id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
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
                home: e.value.$1(lang),
              ),
            ),
          ));
          await tester.pump();
          final show = e.value.$2;
          if (show != null) {
            final g = await tester.startGesture(
                tester.getCenter(find.byKey(const ValueKey('sosat-sos-hold'))));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: EmergencySosPanel.holdMs + 100));
            await g.up();
            for (var i = 0; i < 8; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            // the snackbar goes away; scroll to the changed row
            await tester.pump(const Duration(seconds: 5));
            await tester.pump(const Duration(seconds: 1));
            final row = find.byKey(ValueKey(show));
            expect(row, findsOneWidget);
            await tester.ensureVisible(row);
          }
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
          expect(tester.takeException(), isNull);
          if (_out != null) {
            final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
            final img = await tester.runAsync(() => rb.toImage(pixelRatio: 2)) as ui.Image;
            final bytes =
                await tester.runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
            Directory(_out!).createSync(recursive: true);
            File('$_out/${e.key}_${lang}_${b.name}.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            img.dispose();
          }
          SosRetry.stop();
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 1));
          await tester.binding.setSurfaceSize(null);
        });
      }
    }
  }
}
