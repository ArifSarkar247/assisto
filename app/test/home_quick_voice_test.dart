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

  // Automatic voice language (owner order after build 146). Spoken audio can't
  // run in a unit test, so this pins the SELECTION logic: every kind of
  // sentence — Bangla ("kal shokale ma ke phone korte mone koriye dio"),
  // English ("remind me to call mom") and mixed Banglish ("kal 9 tay meeting
  // ta remind koro") — goes through the bn-BD recogniser in Auto, which
  // transcribes all three; English is used only when Bangla is missing.
  group('automatic voice language', () {
    const phone = ['en_US', 'bn_BD', 'hi_IN'];
    test('auto picks bn-BD for Bangla, English and mixed speech', () {
      final p = VoiceDictation.pickLocale(phone, 'auto')!;
      expect(p.lang, 'bn');
      expect(p.localeId, 'bn_BD');
    });
    test('auto falls back to bn_IN, then English when no Bangla at all', () {
      expect(VoiceDictation.pickLocale(['en-US', 'bn-IN'], 'auto')!.localeId,
          'bn-IN');
      final p = VoiceDictation.pickLocale(['en_GB', 'hi_IN'], 'auto')!;
      expect(p.lang, 'en');
      expect(p.localeId, 'en_GB');
    });
    test('auto with an engine that lists nothing tries bn_BD', () {
      expect(VoiceDictation.pickLocale([], 'auto')!.localeId, 'bn_BD');
    });
    test('auto after the engine rejected Bangla uses English', () {
      final p = VoiceDictation.pickLocale(phone, 'auto', bnRejected: true)!;
      expect(p.lang, 'en');
      expect(p.localeId, 'en_US');
    });
    test('manual override never switches language silently', () {
      expect(VoiceDictation.pickLocale(phone, 'en')!.localeId, 'en_US');
      expect(VoiceDictation.pickLocale(phone, 'bn')!.localeId, 'bn_BD');
      expect(VoiceDictation.pickLocale(['en_US'], 'bn'), isNull);
      expect(VoiceDictation.pickLocale(['bn_BD'], 'en'), isNull);
      expect(VoiceDictation.pickLocale(['hi_IN'], 'auto'), isNull);
    });
    test('missing-language message and fallback trigger', () {
      expect(VoiceDictation.missingLang('auto'), 'bn');
      expect(VoiceDictation.missingLang('bn'), 'bn');
      expect(VoiceDictation.missingLang('en'), 'en');
      expect(
          VoiceDictation.shouldFallBackToEnglish(
              'auto', 'bn', 'error_language_not_supported'),
          isTrue);
      expect(
          VoiceDictation.shouldFallBackToEnglish(
              'auto', 'bn', 'error_language_unavailable'),
          isTrue);
      expect(
          VoiceDictation.shouldFallBackToEnglish(
              'bn', 'bn', 'error_language_not_supported'),
          isFalse);
      expect(VoiceDictation.shouldFallBackToEnglish('auto', 'bn', 'error_no_match'),
          isFalse);
    });
    test('saved mode: default auto, invalid -> auto, round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await VoiceDictation.savedMode(), 'auto');
      SharedPreferences.setMockInitialValues({VoiceDictation.modeKey: 'xx'});
      expect(await VoiceDictation.savedMode(), 'auto');
      await VoiceDictation.saveMode('bn');
      expect(await VoiceDictation.savedMode(), 'bn');
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
