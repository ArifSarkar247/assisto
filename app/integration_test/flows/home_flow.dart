// Priority 2-4: home chat send + restore after restart, sidebar history,
// editing the home quick buttons.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/state.dart' show Settings;
import 'package:assisto/widgets/home_quick_buttons.dart';

import '../support/harness.dart';

final String _ping = 'Reality ping ${DateTime.now().millisecondsSinceEpoch % 100000}';

void registerHomeFlows() {
  realityFlow('04_home_chat', 'Home', 'Home chat: send a message (saved on server)', (f) async {
    await f.home();
    final mark = f.httpMark;
    await f.step('type + send in the home chat', () async {
      await f.shot('home');
      await f.enter(_ping, label: f.t.inputHint);
      await f.tap(find.byIcon(Icons.arrow_upward), settleSeconds: 6);
      await f.shot('after-send');
      await f.waitFor(find.textContaining(_ping), what: 'my message bubble');
    });
    await f.step('assistant answers (honest no-AI-key reply in CI)', () async {
      f.expectHttp('POST', '/agent', since: mark);
      await f.shot('reply');
      f.needsKey('ANTHROPIC_API_KEY (real AI answers; CI shows the honest "needs the AI key" reply)');
    });
    await f.step('backend has the message in a saved home session', () async {
      final api = await f.h.backend();
      await f.eventually('chat session holds "$_ping"', () async {
        final sessions = await api.chatSessions();
        for (final s in sessions.take(5)) {
          final msgs = await api.chatMessages('${s['id']}');
          if (msgs.any((m) => '${m['text'] ?? m['content'] ?? ''}'.contains(_ping))) return true;
        }
        return false;
      });
    });
  });

  realityFlow('05_home_restore', 'Home', 'Home chat restored after app restart', (f) async {
    // realityFlow booted a FRESH AppState + widget tree = app reopened.
    await f.home();
    await f.step('the last home conversation is shown again', () async {
      final ok = await f.appears(find.textContaining(_ping), seconds: 12);
      await f.shot('after-restart');
      if (!ok) throw TestFailure('message "$_ping" not restored after restart');
    });
  });

  realityFlow('06_sidebar_history', 'Home', 'Sidebar chat history', (f) async {
    await f.home();
    await f.step('open the drawer; history lists the chat', () async {
      final open = find.byTooltip('Open navigation menu');
      await f.tap(open, settleSeconds: 3);
      await f.shot('drawer');
      f.expectHttp('GET', '/chat/sessions');
      final row = find.descendant(of: find.byType(Drawer), matching: find.textContaining('Reality ping'));
      if (!await f.appears(row, seconds: 8)) {
        throw TestFailure('sidebar history does not list the home chat');
      }
    });
    await f.step('tapping the history row reopens that chat', () async {
      await f.tap(find.descendant(of: find.byType(Drawer), matching: find.textContaining('Reality ping')),
          settleSeconds: 4);
      await f.shot('reopened');
      await f.waitFor(find.textContaining(_ping), what: 'reopened conversation');
    });
  });

  realityFlow('07_quick_buttons', 'Home', 'Edit the 6 home quick buttons (persists)', (f) async {
    await f.home();
    late List<String> before;
    await f.step('open the picker', () async {
      before = await f.net(() => HomeQuickButtons.load());
      await f.tap(find.widgetWithText(TextButton, f.t.quickEdit));
      await f.waitFor(find.text(f.t.quickPickTitle));
      await f.shot('picker');
    });
    String? added;
    await f.step('swap one shortcut and save', () async {
      // uncheck the first currently-selected shortcut, check the first free one
      final checked = find.byWidgetPredicate((w) => w is CheckboxListTile && w.value == true);
      await f.tap(checked.first, settleSeconds: 0.6);
      final free = find.byWidgetPredicate((w) => w is CheckboxListTile && w.value == false && w.onChanged != null);
      await f.tap(free.first, settleSeconds: 0.6);
      await f.shot('changed');
      await f.tapText(f.t.aichatSave, settleSeconds: 2);
      final after = await f.net(() => HomeQuickButtons.load());
      added = after.firstWhere((r) => !before.contains(r), orElse: () => '');
      if (added!.isEmpty) throw TestFailure('saved list did not change: $after');
      await f.shot('home-after-save');
    });
    await f.step('choice survives a restart', () async {
      await f.h.boot(f.tester);
      await f.home();
      final raw = await f.net(() => Settings.getString(HomeQuickButtons.prefsKey));
      final list = (jsonDecode(raw ?? '[]') as List).cast<String>();
      expect(list, contains(added));
      await f.shot('after-restart');
      f.note('quick buttons are stored on-device by design (no server round-trip); '
          'GET /app/home-defaults supplies the owner default');
    });
  });
}
