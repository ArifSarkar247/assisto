// perf2gb: Photo Studio's on-screen preview is decoded at screen size, never
// at the 12 MP camera size (display only; edits/export use the original).
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/photo_studio_screen.dart';

void main() {
  test('premium preview: twice the screen pixels, capped at 2048', () {
    // 360 dp x 2.0 = 720 px screen (a typical 2 GB phone at 320 dpi)
    expect(psPreviewCacheWidth(free: false, previewMaxPx: 1600, screenWidth: 360, dpr: 2), 1440);
    expect(psPreviewCacheWidth(free: false, previewMaxPx: 1600, screenWidth: 412, dpr: 3.5), 2048);
  });

  test('free preview keeps the watermarked preview size', () {
    expect(psPreviewCacheWidth(free: true, previewMaxPx: 800, screenWidth: 360, dpr: 2), 800);
    expect(psPreviewCacheWidth(free: true, previewMaxPx: 4000, screenWidth: 360, dpr: 2), 1024);
  });

  test('no screen metrics: full decode (as before), never a crash', () {
    expect(psPreviewCacheWidth(free: false, previewMaxPx: 1600, screenWidth: 0, dpr: 0), isNull);
  });
}
