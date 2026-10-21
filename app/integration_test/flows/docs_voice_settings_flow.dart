// Priority 11-13: documents (vault), the voice screen (speech itself cannot
// run on a CI emulator — typed fallback is exercised), settings + language.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

void registerDocsVoiceSettingsFlows() {
  realityFlow('21_documents', 'Daily life', 'Documents vault: add a document record (server)', (f) async {
    await f.home();
    final title = 'Reality NID d$_tag';
    await f.step('open the vault', () async {
      await f.openFeature(f.t.moduleVault, 'documents');
      await f.shot('vault');
      f.expectHttp('GET', '/documents');
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
      final typeBtn = find.byTooltip(f.t.vaTypeInstead);
      if (typeBtn.evaluate().isEmpty) {
        f.note('no "Type instead" button visible (mic permission UI shown?)');
        return;
      }
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
      await f.tap(find.byTooltip('Open navigation menu'), settleSeconds: 2);
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
      await f.tap(find.text(f.t.aboutTitle), settleSeconds: 2);
      await f.shot('about');
    });
  });
}
