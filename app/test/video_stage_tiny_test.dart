// Crash reports (OPPO CPH2637/CPH2375, build 10222): VideoStage._area threw
// ArgumentError (clamp lower > upper) when the stage was smaller than
// topInset + tile height (PiP / rotation / keyboard). It must lay out at any size.
import 'package:assisto/calls/video_stage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in const [Size(120, 214), Size(60, 90), Size(360, 800)]) {
    testWidgets('VideoStage lays out at ${size.width}x${size.height}', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VideoStage(
              remote: const ColoredBox(color: Colors.black),
              local: const ColoredBox(color: Colors.grey),
              canSwap: true,
              fullscreen: false,
              onToggleFullscreen: () {},
            ),
          ),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
    });
  }
}
