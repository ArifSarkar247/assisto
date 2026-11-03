// aifinal round 2 item 1: a Bangla app never listens in English (that wrote
// Bangla speech as romanized English); no Bangla on the phone -> server.
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/widgets/voice_input.dart';

void main() {
  test('Bangla app + engine lists no Bangla -> server, never English', () {
    final p = VoiceDictation.pickLocale(['en_US', 'en_GB'], 'auto', appLang: 'bn')!;
    expect(p.lang, 'bn');
    expect(p.localeId, VoiceDictation.serverLocale);
  });

  test('Bangla app + engine has Bangla -> bn_BD on the phone', () {
    final p = VoiceDictation.pickLocale(['en_US', 'bn_BD'], 'auto', appLang: 'bn')!;
    expect(p.localeId, 'bn_BD');
  });

  test('Bangla rejected once in a Bangla app -> server next time', () {
    final p = VoiceDictation.pickLocale(['bn_BD'], 'auto', bnRejected: true, appLang: 'bn')!;
    expect(p.localeId, VoiceDictation.serverLocale);
  });

  test('mic switch on Bangla with no Bangla engine -> server', () {
    final p = VoiceDictation.pickLocale(['en_US'], 'bn', appLang: 'en')!;
    expect(p.localeId, VoiceDictation.serverLocale);
  });

  test('English switch stays English', () {
    expect(VoiceDictation.pickLocale(['en_US', 'bn_BD'], 'en', appLang: 'bn')!.localeId, 'en_US');
  });
}
