import 'dart:io';

import 'package:flutter/services.dart';

/// f1-design: loads the app's bundled fonts into the test engine (flutter
/// test has no system fonts), exactly as pubspec.yaml declares them:
/// Inter 400/500/600/700 + Noto Sans Bengali 400/500/600/700.
///
/// Font comparison (BANGLA_FONT_DECISION.md): ASSISTO_BN_FONT=HindSiliguri
/// (or AnekBangla) + ASSISTO_BN_FONT_DIR=<dir with <Family>-<Weight>.ttf>
/// renders the same screens with a candidate Bangla family in the
/// NotoSansBengali slot — no app code changes needed.
Future<void> loadAppFonts() async {
  const weights = ['Regular', 'Medium', 'SemiBold', 'Bold'];
  Future<void> family(String name, List<String> paths) async {
    final l = FontLoader(name);
    var any = false;
    for (final p in paths) {
      if (!File(p).existsSync()) continue;
      any = true;
      l.addFont(File(p).readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    if (any) await l.load();
  }

  await family('Inter', [for (final w in weights) 'assets/fonts/Inter-$w.ttf']);
  final alt = Platform.environment['ASSISTO_BN_FONT'];
  final altDir = Platform.environment['ASSISTO_BN_FONT_DIR'];
  if (alt != null && alt.isNotEmpty && altDir != null) {
    await family('NotoSansBengali', [for (final w in weights) '$altDir/$alt-$w.ttf']);
  } else {
    await family('NotoSansBengali',
        [for (final w in weights) 'assets/fonts/NotoSansBengali-$w.ttf']);
  }
}
