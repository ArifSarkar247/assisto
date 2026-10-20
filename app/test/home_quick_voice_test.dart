import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';
import 'package:assisto/widgets/voice_input.dart';

void main() {
  group('voice locale resolution', () {
    test('prefers bn_BD, then bn_IN, then any bn; null when engine has none', () {
      expect(VoiceDictation.resolveLocale(['en_US', 'bn_IN', 'bn_BD'], 'bn'), 'bn_BD');
      expect(VoiceDictation.resolveLocale(['en-US', 'bn-IN'], 'bn'), 'bn-IN');
      expect(VoiceDictation.resolveLocale(['bn'], 'bn'), 'bn');
      expect(VoiceDictation.resolveLocale(['en_US', 'hi_IN'], 'bn'), isNull);
    });
    test('english picks en_US first, any en otherwise', () {
      expect(VoiceDictation.resolveLocale(['en_GB', 'en_US'], 'en'), 'en_US');
      expect(VoiceDictation.resolveLocale(['en_AU'], 'en'), 'en_AU');
    });
    test('engine reports nothing -> try the standard id', () {
      expect(VoiceDictation.resolveLocale([], 'bn'), 'bn_BD');
      expect(VoiceDictation.resolveLocale([], 'en'), 'en_US');
    });
  });

  group('home quick buttons', () {
    test('sanitize keeps order, drops unknown/dupes, tops up to 6', () {
      final r = HomeQuickButtons.sanitize(['budget', 'nope', 'budget', 'money']);
      expect(r.length, 6);
      expect(r.take(2), ['budget', 'money']);
      expect(r.toSet().length, 6);
    });
    test('defaults are all valid routes', () {
      expect(HomeQuickButtons.sanitize(HomeQuickButtons.defaults), HomeQuickButtons.defaults);
    });
    test('save then load round-trips', () async {
      SharedPreferences.setMockInitialValues({});
      final pick = ['emergency', 'budget', 'notes', 'ai_chat', 'nearby', 'scam'];
      await HomeQuickButtons.save(pick);
      expect(await HomeQuickButtons.load(), pick);
    });
    test('corrupt prefs fall back to defaults', () async {
      SharedPreferences.setMockInitialValues({HomeQuickButtons.prefsKey: 'not json'});
      expect(await HomeQuickButtons.load(), HomeQuickButtons.defaults);
    });
  });
}
