// Priority 11-13: documents (vault), the voice screen (speech itself cannot
// run on a CI emulator — typed fallback is exercised), settings + language.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:assisto/l10n/app_localizations.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

void registerDocsVoiceSettingsFlows() {
  realityFlow('21_documents', 'Daily life', 'Documents vault: add a document record (server)', (f) async {
    await f.home();
    final title = 'Reality NID d$_tag';
    await f.step('open the vault (set / enter its PIN first)', () async {
      final mark = f.httpMark;
      await f.openFeature(f.t.moduleVault, 'documents');
      await f.shot('vault');
      // Current UI (rt1): Documents is PIN-locked — the first open asks to
      // set a PIN, later opens ask for it. Nothing loads before that.
      const pin = '4826';
      if (await f.appears(find.text(f.t.vaultSetPinTitle), seconds: 4)) {
        await f.enter(pin, label: f.t.vaultPinLengthHint);
        await f.tap(find.widgetWithText(FilledButton, f.t.vaultSetButton), settleSeconds: 3);
      } else if (await f.appears(find.text(f.t.vaultLockedTitle), seconds: 2)) {
        await f.enter(pin, label: f.t.vaultEnterPinHint);
        await f.tap(find.widgetWithText(FilledButton, f.t.vaultUnlockButton), settleSeconds: 3);
      }
      await f.shot('unlocked');
      f.expectHttp('GET', '/documents', since: mark);
    });
    await f.step('add a document (no file; details only)', () async {
      await f.tap(find.byType(FloatingActionButton));
      await f.waitFor(find.text(f.t.vaultAddDocument));
      await f.enter(title, label: f.t.vaultNameRequired);
      await f.shot('doc-form');
      await f.tap(find.widgetWithText(FilledButton, f.t.save), settleSeconds: 4);
      await f.shot('doc-saved');
      final api = await f.h.backend();
      await f.eventually('document on server', () async =>
          (await api.listDocuments()).any((d) => '${d['title']}' == title));
      f.note('attaching a photo/PDF uses the system picker — phone checklist');
    });
  });

  realityFlow('22_voice_screen', 'Voice', 'Voice assistant screen opens; typed fallback answers', (f) async {
    await f.home();
    await f.step('open Assisto Voice', () async {
      await f.openFeature(f.t.vaTitle, 'voice_assistant');
      await f.shot('voice');
      f.note('speech recognition / TTS cannot run on the CI emulator (no mic, no Google speech) — '
          'hold-to-talk is a phone checklist item');
    });
    await f.step('type instead -> sends to the agent', () async {
      final mark = f.httpMark;
      // rt1: the voice screen ALWAYS has "Type instead". The old step returned
      // quietly when it was missing — run 39859999833 marked this flow A while
      // the drawer search never even opened the voice screen.
      // First open auto-listens, so the app first explains the microphone
      // (modal). A user who wants to type answers "Not now" (run 39878171841:
      // the tap on "Type instead" only dismissed this dialog).
      if (await f.appears(find.text(f.t.permMic), seconds: 4)) {
        await f.tap(find.widgetWithText(TextButton, f.t.notNow), settleSeconds: 1.5);
        await f.shot('mic-reason-not-now');
      }
      final typeBtn = find.byTooltip(f.t.vaTypeInstead);
      await f.waitFor(typeBtn, what: '"Type instead" on the Assisto Voice screen');
      await f.tap(typeBtn);
      await f.enter('what are my reminders today', label: f.t.vaTypeHint);
      await f.tap(find.byTooltip(f.t.vaSend), settleSeconds: 5);
      await f.shot('voice-answer');
      final called = f.h.recorder.hits.skip(mark).where((x) => x.method == 'POST');
      if (called.isEmpty) throw TestFailure('typed voice turn made no server call');
    });
  });

  realityFlow('23_settings_language', 'Settings', 'Settings: switch to Bangla and back; About shows version', (f) async {
    await f.home();
    final bn = lookupAppLocalizations(const Locale('bn'));
    await f.step('open Settings', () async {
      // Settings sits at the bottom of the drawer (not in the search index)
      await f.openDrawer();
      final tile = find.descendant(of: find.byType(Drawer), matching: find.text(f.t.settingsTitle));
      await f.tester.scrollUntilVisible(tile, 300,
          scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first);
      await f.tap(tile, settleSeconds: 3);
      if (find.text(f.t.settingsTitle).evaluate().isEmpty) {
        throw TestFailure('Settings did not open');
      }
      await f.shot('settings-en');
    });
    await f.step('switch to Bangla: UI re-renders in Bangla', () async {
      await f.tap(find.text(f.t.languageBangla), settleSeconds: 2);
      await f.waitFor(find.text(bn.settingsTitle), what: 'Bangla settings title');
      expect(f.app.locale?.languageCode, 'bn');
      await f.shot('settings-bn');
    });
    await f.step('switch back to English', () async {
      await f.tap(find.text(bn.languageEnglish), settleSeconds: 2);
      await f.waitFor(find.text(f.t.settingsTitle));
      expect(f.app.locale?.languageCode, 'en');
    });
    await f.step('About shows the version', () async {
      // About is the LAST Settings row (rt1: the old step looked for it
      // without scrolling, so the lazily-built row was never found).
      final about = find.text(f.t.aboutTitle);
      await f.tester.scrollUntilVisible(about, 400,
          scrollable: find.byType(Scrollable).hitTestable().first);
      await f.tap(about, settleSeconds: 3);
      final info = await f.net(() => PackageInfo.fromPlatform());
      await f.waitFor(find.textContaining(info.version), what: 'version ${info.version} on About');
      await f.shot('about');
    });
  });
}
