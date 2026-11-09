// geminioff (owner 9 Nov 13:30): while the image AI (Gemini) is off, Photo
// Studio shows an honest "Coming soon" card — no prompt box, no dead
// button — and the free on-phone tools stay; the voice mic shows the
// server's honest "use your keyboard mic" message instead of recording.
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_engines.dart';
import 'package:assisto/photo_studio/ps_models.dart';
import 'package:assisto/photo_studio/ps_native.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:assisto/widgets/voice_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ps1_fakes.dart';

class SoonBackend extends FakePsBackend {
  SoonBackend({this.soon = true}) : super(entryDue: false, providerReady: false);
  final bool soon;

  @override
  Future<PsConfig> config() async {
    final base = await super.config();
    return PsConfig(
      plan: base.plan,
      free: base.free,
      features: base.features,
      providerReady: false,
      previewMaxPx: base.previewMaxPx,
      aiEditComingSoon: soon,
    );
  }
}

Widget _app(Widget child, {String lang = 'en'}) => MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

Future<void> _pump(WidgetTester tester, FakePsBackend b, {String lang = 'en'}) async {
  await tester.binding.setSurfaceSize(const Size(360, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final c = PhotoStudioController(PsDeps(
      backend: b,
      ads: FakeAds(b),
      native: const NoPhotoNative(),
      engine: FakeEngine(),
      guard: IdentityGuard(landmarks: FakeLandmarks()),
      sink: FakeSink(),
      renderer: FakeRenderer(),
      secure: FakeSecure(works: false),
      picker: FakePicker()));
  await tester.pumpWidget(_app(PhotoStudioScreen(controller: c), lang: lang));
  await c.init();
  await tester.pumpAndSettle();
}

void main() {
  test('server flag parsed (default off)', () {
    expect(PsConfig.fromJson(const {'ai_edit_coming_soon': true}).aiEditComingSoon, isTrue);
    expect(PsConfig.fromJson(const {}).aiEditComingSoon, isFalse);
  });

  testWidgets('Gemini off: honest Coming soon card, no prompt box or button', (tester) async {
    await _pump(tester, SoonBackend());
    expect(find.byKey(const Key('psAiEditSoon')), findsOneWidget);
    expect(find.textContaining('coming soon'), findsOneWidget);
    expect(find.byKey(const Key('psPrompt')), findsNothing);
    expect(find.byKey(const Key('psRunPrompt')), findsNothing);
  });

  testWidgets('Bangla card', (tester) async {
    await _pump(tester, SoonBackend(), lang: 'bn');
    expect(find.textContaining('শীঘ্রই আসছে'), findsOneWidget);
  });

  testWidgets('Gemini on: no Coming soon card', (tester) async {
    await _pump(tester, SoonBackend(soon: false));
    expect(find.byKey(const Key('psAiEditSoon')), findsNothing);
  });

  test('voice: server-off message held for the next tap, clearable', () {
    VoiceDictation.debugSetServerOff('Tap your keyboard mic');
    expect(VoiceDictation.serverOff, isTrue);
    expect(VoiceDictation.serverOffMessage, 'Tap your keyboard mic');
    VoiceDictation.debugSetServerOff(null);
    expect(VoiceDictation.serverOff, isFalse);
  });
}
