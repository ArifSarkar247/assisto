// lostsim — lost-phone intruder photo (Vault PIN, consented, never covert)
// + SIM-change re-check on app open/resume (no missed swaps, no repeats).
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/intruder_consent_screen.dart';
import 'package:assisto/services/antitheft_logic.dart';
import 'package:assisto/services/intruder_snap.dart';
import 'package:assisto/vault/vault_lock.dart';
import 'package:assisto/vault/vault_lock_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const _a = 's1:47001'; // owner's SIM
const _thief = 's7:47002';

Widget _app(Widget home, {String lang = 'en'}) => MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    );

void main() {
  group('SIM change: app open/resume re-check', () {
    test('a swap the receiver missed is caught on the next app open', () {
      final e = SimEngineModel()..armRebaseline();
      e.debounceFired([_a]); // silent baseline
      // the thief swaps the SIM; the broadcast never arrives (OEM saver)
      e.appResume();
      e.debounceFired([_thief]);
      expect(e.alerts, ['inserted']);
    });

    test('re-checking the same SIMs never repeats an alert', () {
      final e = SimEngineModel()..armRebaseline();
      e.debounceFired([_a]);
      e.appResume();
      e.debounceFired([_a]);
      expect(e.alerts, isEmpty);
      e.appResume();
      e.debounceFired(['']); // SIM pulled
      e.appResume();
      e.debounceFired(['']); // opened again, still no SIM
      expect(e.alerts, ['removed']);
      e.appResume();
      e.debounceFired([_a]); // owner's own SIM back: never an alert
      expect(e.alerts, ['removed']);
    });

    test('no baseline yet: resume records nothing and alerts nothing', () {
      final e = SimEngineModel();
      e.appResume();
      e.debounceFired([_thief]);
      expect(e.base, isNull);
      expect(e.alerts, isEmpty);
    });
  });

  group('Intruder photo on wrong Vault PIN', () {
    late int snaps;
    setUp(() {
      snaps = 0;
      IntruderSnap.snapOverride = () async {
        snaps++;
        return true;
      };
    });
    tearDown(() {
      IntruderSnap.snapOverride = null;
      IntruderSnap.debugSetArmed(false);
    });

    test('off (no consent) -> never a photo', () {
      IntruderSnap.debugSetArmed(false);
      expect(IntruderSnap.afterLocalWrong(9), isFalse);
      expect(snaps, 0);
    });

    test('on -> only from the threshold', () {
      IntruderSnap.debugSetArmed(true);
      expect(IntruderSnap.afterLocalWrong(1), isFalse);
      expect(IntruderSnap.afterLocalWrong(IntruderSnap.localThreshold - 1),
          isFalse);
      expect(IntruderSnap.afterLocalWrong(IntruderSnap.localThreshold), isTrue);
      expect(snaps, 1);
    });

    test('consent version 2 covers the Vault PIN', () {
      expect(IntruderConsentScreen.consentVersion, 2);
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('vault lock: notice shown + photo on the 3rd wrong PIN ($lang)',
          (tester) async {
        IntruderSnap.debugSetArmed(true);
        final lock = VaultLock(kv: MemoryKv(), iterations: 10);
        await lock.setPin('4821');
        await tester.pumpWidget(_app(
            Scaffold(
                body: VaultLockView(
                    lock: lock,
                    mode: VaultLockMode.enter,
                    onUnlocked: () {},
                    onForgot: () {})),
            lang: lang));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('lostsim-vault-notice')), findsOneWidget);
        for (var i = 0; i < 3; i++) {
          await tester.enterText(find.byKey(const Key('vault_pin')), '1111');
          await tester.tap(find.byKey(const Key('vault_pin_submit')));
          await tester.pumpAndSettle();
        }
        expect(snaps, 1);
        expect(await lock.wrongInARow(), 3);
      });
    }

    testWidgets('vault lock: no notice and no photo while off', (tester) async {
      IntruderSnap.debugSetArmed(false);
      final lock = VaultLock(kv: MemoryKv(), iterations: 10);
      await lock.setPin('4821');
      await tester.pumpWidget(_app(Scaffold(
          body: VaultLockView(
              lock: lock,
              mode: VaultLockMode.enter,
              onUnlocked: () {},
              onForgot: () {}))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lostsim-vault-notice')), findsNothing);
      for (var i = 0; i < 3; i++) {
        await tester.enterText(find.byKey(const Key('vault_pin')), '1111');
        await tester.tap(find.byKey(const Key('vault_pin_submit')));
        await tester.pumpAndSettle();
      }
      expect(snaps, 0);
    });

    test('a correct PIN resets the counter', () async {
      final lock = VaultLock(kv: MemoryKv(), iterations: 10);
      await lock.setPin('4821');
      await lock.check('1111');
      await lock.check('1111');
      expect(await lock.wrongInARow(), 2);
      await lock.check('4821');
      expect(await lock.wrongInARow(), 0);
    });
  });
}
