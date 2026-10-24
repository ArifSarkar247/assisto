// play-perm / play-fsi / play-fgs: Google Play policy fixes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/calls/fullscreen_call_prompt.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/media/photo_picker_setup.dart';
import 'package:assisto/screens/camera/camera_permission_gate.dart';

Widget _app(Locale locale, void Function(BuildContext) onTap) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
                key: const Key('go'),
                onPressed: () => onTap(ctx),
                child: const Text('go')),
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FullScreenCallPrompt.debugCanOverride = null;
  });

  testWidgets('full-screen call prompt shows ONCE when Android denies it',
      (tester) async {
    FullScreenCallPrompt.debugCanOverride = false;
    await tester.pumpWidget(
        _app(const Locale('bn'), (c) => FullScreenCallPrompt.maybeShow(c)));
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fsi-prompt')), findsOneWidget);
    expect(find.text('আসা কল পুরো স্ক্রিনে দেখাবে?'), findsOneWidget);
    expect(find.byKey(const Key('fsi-allow')), findsOneWidget);
    await tester.tap(find.byKey(const Key('fsi-later')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fsi-prompt')), findsNothing);
    // second time: never again
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fsi-prompt')), findsNothing);
  });

  testWidgets('no prompt when full-screen calls are allowed (or Android < 14)',
      (tester) async {
    FullScreenCallPrompt.debugCanOverride = true;
    await tester.pumpWidget(
        _app(const Locale('en'), (c) => FullScreenCallPrompt.maybeShow(c)));
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fsi-prompt')), findsNothing);
  });

  test('photo picker switch is safe off-Android and the camera needs no photo permission',
      () {
    usePhotoPicker(); // no throw in tests
    expect(CameraPermissions().photosGranted, isTrue);
  });
}
