// cde-chat (owner order 6 C): the WhatsApp-style video call stage — tap the
// small self-view to swap big / small, drag it to any corner (it snaps),
// pinch-zoom the big view, double-tap for full screen (controls hidden),
// camera-off on the other side keeps them big (no swap), and the call screen
// shows the chat's NICKNAME.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/video_stage.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';

Future<void> _pump(WidgetTester tester, CallController c,
    {Map<String, dynamic> member = const {'id': 7, 'name': 'Nadia'},
    bool video = true}) async {
  await tester.binding.setSurfaceSize(const Size(360, 780));
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: CircleCallScreen(
      key: ObjectKey(c),
      member: member,
      kind: video ? 'video' : 'voice',
      controller: c,
      surface: video ? FakeSurface() : null,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 50));
}

CallController _live({bool remoteCamera = true}) => previewController(
    video: true, outgoing: true, phase: CallPhase.connected, remoteCamera: remoteCamera);

VideoStageState _stage(WidgetTester tester) =>
    tester.state<VideoStageState>(find.byType(VideoStage));

void main() {
  testWidgets('tap the small self-view swaps big and small, and back', (tester) async {
    await _pump(tester, _live());
    expect(find.byKey(const Key('call-big-remote')), findsOneWidget);
    expect(find.byKey(const Key('call-small-local')), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-self-view')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('call-big-local')), findsOneWidget);
    expect(find.byKey(const Key('call-small-remote')), findsOneWidget);
    expect(_stage(tester).swapped, isTrue);
    await tester.tap(find.byKey(const Key('call-self-view')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('call-big-remote')), findsOneWidget);
  });

  testWidgets('drag the small view: it snaps to the nearest corner', (tester) async {
    await _pump(tester, _live());
    expect(_stage(tester).corner, StageCorner.topRight);
    // to the bottom-left
    await tester.drag(find.byKey(const Key('call-self-view')), const Offset(-220, 300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400)); // the snap animation
    expect(_stage(tester).corner, StageCorner.bottomLeft);
    expect(find.byKey(const ValueKey('call-self-corner-bottomLeft')), findsOneWidget);
    // the tile really sits in that corner, inside the safe area above the controls
    final r = tester.getRect(find.byKey(const Key('call-self-view')));
    expect(r.left, closeTo(VideoStage.margin, 1));
    expect(r.bottom, lessThanOrEqualTo(780 - 250 + 1));
    // a small nudge stays in the same corner
    await tester.drag(find.byKey(const Key('call-self-view')), const Offset(30, -20));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_stage(tester).corner, StageCorner.bottomLeft);
    // to the top-right again
    await tester.drag(find.byKey(const Key('call-self-view')), const Offset(240, -330));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_stage(tester).corner, StageCorner.topRight);
  });

  testWidgets('double-tap the big view: full screen hides the controls, again shows them',
      (tester) async {
    await _pump(tester, _live());
    expect(find.byKey(const Key('call-hangup')), findsOneWidget);
    // an empty spot of the big view (between the name and the controls)
    const spot = Offset(60, 380);
    await tester.tapAt(spot);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(spot);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('call-hangup')), findsNothing);
    expect(find.byKey(const Key('call-name')), findsNothing);
    // the self-view is still there (and can still be moved / swapped)
    expect(find.byKey(const Key('call-self-view')), findsOneWidget);
    await tester.tapAt(spot);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(spot);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('call-hangup')), findsOneWidget);
  });

  testWidgets('pinch the big view zooms it (InteractiveViewer 1x–4x)', (tester) async {
    await _pump(tester, _live());
    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(iv.minScale, 1);
    expect(iv.maxScale, 4);
    const center = Offset(180, 380); // empty area of the big view
    final a = await tester.startGesture(center - const Offset(30, 0));
    final b = await tester.startGesture(center + const Offset(30, 0));
    await tester.pump();
    await a.moveBy(const Offset(-60, 0));
    await b.moveBy(const Offset(60, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 300));
    final scale = iv.transformationController!.value.getMaxScaleOnAxis();
    expect(scale, greaterThan(1.2));
    // a swap resets the zoom
    await tester.tap(find.byKey(const Key('call-self-view')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(iv.transformationController!.value.getMaxScaleOnAxis(), 1);
  });

  testWidgets('their camera off: no swap, badge shown; my camera off: placeholder',
      (tester) async {
    await _pump(tester, _live(remoteCamera: false));
    expect(find.byKey(const Key('call-remote-camera-off')), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-self-view')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_stage(tester).swapped, isFalse);
    final c = previewController(
        video: true, outgoing: true, phase: CallPhase.connected, cameraOn: false);
    await _pump(tester, c);
    expect(find.byKey(const Key('call-self-camera-off')), findsOneWidget);
    expect(find.byKey(const Key('call-flip')), findsOneWidget);
  });

  testWidgets('the call screen shows the chat nickname', (tester) async {
    await _pump(tester, _live(),
        member: const {'id': 7, 'name': 'Nadia Rahman', 'nickname': 'Nadu'});
    expect(find.text('Nadu'), findsOneWidget);
    expect(find.text('Nadia Rahman'), findsNothing);
  });

  test('nearest corner maths', () {
    const area = Rect.fromLTRB(16, 80, 344, 530);
    expect(VideoStageState.nearest(const Offset(20, 90), area), StageCorner.topLeft);
    expect(VideoStageState.nearest(const Offset(230, 90), area), StageCorner.topRight);
    expect(VideoStageState.nearest(const Offset(20, 380), area), StageCorner.bottomLeft);
    expect(VideoStageState.nearest(const Offset(230, 380), area), StageCorner.bottomRight);
  });
}
