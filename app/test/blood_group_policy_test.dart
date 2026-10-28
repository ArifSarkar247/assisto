// Owner decision 28 Oct: the family card's blood group shows on every build
// (Play too), stays ONLY on this phone, and is never sent to our server.
// Medicine stays behind the Play health gate.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String src(String p) => File(p).readAsStringSync();

  test('blood group is not behind the medical gate', () {
    final card = src('lib/widgets/fam_card_section.dart');
    expect(card.contains('kMedicalFeaturesAllowed'), isFalse);
    expect(card.contains("famCardBlood"), isTrue);
  });

  test('medicine stays gated on Play', () {
    expect(src('lib/widgets/fam_share_section.dart'), contains('kMedicalFeaturesAllowed'));
  });

  test('blood group is never sent to the server by the family API', () {
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('_api.dart') && !f.path.endsWith('api.dart')) continue;
      expect(f.readAsStringSync().contains("'blood'"), isFalse, reason: f.path);
    }
  });
}
