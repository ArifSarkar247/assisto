// Priority 1: first run — language picker, login, onboarding.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void registerOnboardingFlows() {
  realityFlow('01_language', 'Start', 'Language picker (first run)', (f) async {
    await f.step('cold start shows the language picker', () async {
      await f.shot('first-run');
      if (find.text('English').evaluate().isEmpty) {
        // already chosen on a previous run of this APK — not a first run
        f.note('language already chosen (not a fresh install)');
        return;
      }
      await f.tapText('English');
      await f.shot('english-selected');
      await f.tapText('Continue', settleSeconds: 3);
    });
    await f.step('left the picker; app is in English', () async {
      expect(f.app.locale?.languageCode, 'en');
      if (f.app.loggedIn) {
        // rt2: a retry on the same AVD (the emulator was restarted) is
        // already past login — there is no login screen to wait for.
        f.note('already logged in (retry on the same device)');
        return;
      }
      await f.waitFor(find.text(f.t.login).hitTestable(), what: 'login screen');
      await f.shot('login-screen-en');
    });
  }, boot: true);

  realityFlow('02_login', 'Start', 'Login (seeded phone + password)', (f) async {
    final mark = f.httpMark;
    await f.step('wrong password shows an honest error', () async {
      if (f.app.loggedIn) {
        f.note('already logged in from a previous run');
        return;
      }
      await f.enter(Seed.phoneA, label: f.t.phoneOrEmail);
      await f.enter('wrong-password', index: 1);
      await f.tap(find.widgetWithText(FilledButton, f.t.login), settleSeconds: 3);
      await f.shot('wrong-password');
      expect(f.app.loggedIn, isFalse);
      expect(find.byWidgetPredicate((w) => w is Text && (w.style?.color == Colors.red)),
          findsWidgets, reason: 'an error line must be visible');
    });
    await f.step('correct password logs in (POST /auth/login 200)', () async {
      if (f.app.loggedIn) return;
      await f.enter(Seed.password, index: 1);
      await f.tap(find.widgetWithText(FilledButton, f.t.login), settleSeconds: 5);
      await f.shot('after-login');
      expect(f.app.loggedIn, isTrue, reason: 'AppState must hold a token + user');
      f.expectHttp('POST', '/auth/login', since: mark);
      f.expectHttp('GET', '/me', since: mark);
    });
  });

  realityFlow('03_onboarding', 'Start', 'Onboarding (first login)', (f) async {
    await f.step('onboarding pages render and can be finished', () async {
      if (f.app.onboarded) {
        f.note('already onboarded');
        return;
      }
      await f.shot('onboarding-1');
      for (var i = 0; i < 3; i++) {
        final next = find.widgetWithText(FilledButton, f.t.next);
        if (next.evaluate().isEmpty) break;
        await f.tap(next);
        await f.shot('onboarding-${i + 2}');
      }
      await f.tapText(f.t.skip, settleSeconds: 3);
    });
    await f.step('lands on home', () async {
      await f.home();
      expect(f.app.onboarded, isTrue);
      await f.shot('home');
    });
  });
}
