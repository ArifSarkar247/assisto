// Priority 2-4: home chat send + restore after restart, sidebar history,
// editing the home quick buttons.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/state.dart' show Settings;
import 'package:assisto/screens/home_v2/home_v2_shortcuts.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';

import '../support/harness.dart';

final String _ping = 'Reality ping ${DateTime.now().millisecondsSinceEpoch % 100000}';

void registerHomeFlows() {
  realityFlow('04_home_chat', 'Home', 'Home chat: send a message (saved on server)', (f) async {
    await f.home();
    final mark = f.httpMark;
    await f.step('type + send in the home chat', () async {
      await f.shot('home');
      // home_v2: the Ask Assisto card opens the chat on its own screen
      await f.openHomeChat();
      await f.enter(_ping, label: f.t.inputHint);
      await f.tapSend(settleSeconds: 6);
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
      await f.openHomeChat();
      final ok = await f.appears(find.textContaining(_ping), seconds: 12);
      await f.shot('after-restart');
      if (!ok) throw TestFailure('message "$_ping" not restored after restart');
    });
  });

  realityFlow('06_sidebar_history', 'Home', 'Sidebar chat history', (f) async {
    await f.home();
    // Current UI (rt1): the drawer's "Assisto AI" entry opens the chats page
    // (every saved home + AI chat); history is no longer listed in the drawer.
    final mark = f.httpMark;
    await f.step('drawer -> Assisto AI lists the home chat', () async {
      await f.openDrawer();
      await f.shot('drawer');
      await f.tap(find.byKey(const ValueKey('drawer_assisto_ai')), settleSeconds: 4);
      await f.shot('chats');
      f.expectHttp('GET', '/chat/sessions', since: mark);
      if (!await f.appears(find.textContaining('Reality ping'), seconds: 10)) {
        throw TestFailure('Assisto AI chats page does not list the home chat');
      }
    });
    await f.step('tapping the history row reopens that chat on home', () async {
      await f.tap(find.textContaining('Reality ping'), settleSeconds: 5);
      await f.waitFor(find.text(f.t.inputHint), what: 'home input after reopening');
      await f.waitFor(find.textContaining(_ping), what: 'reopened conversation');
      await f.shot('reopened');
    });
  });

  realityFlow('07_quick_buttons', 'Home', 'Edit the home shortcuts (persists)', (f) async {
    await f.home();
    final v2 = f.isHomeV2;
    Future<List<String>> load() =>
        v2 ? HomeV2Shortcuts.load() : HomeQuickButtons.load();
    late List<String> before;
    await f.step('open the picker', () async {
      before = await f.net(load);
      if (v2) {
        // home_v2: ONE Edit button; My Circle shows locked in the picker
        await f.tap(find.byKey(const ValueKey('hv2_edit')));
        await f.waitFor(find.text(f.t.hv2PickTitle));
        await f.waitFor(find.byKey(const ValueKey('quick_pinned_lock')));
      } else {
        await f.tap(find.widgetWithText(TextButton, f.t.quickEdit));
        await f.waitFor(find.text(f.t.quickPickTitle));
      }
      await f.shot('picker');
    });
    String? added;
    await f.step('swap one shortcut and save', () async {
      // Uncheck the first selected shortcut, then check a DIFFERENT free one
      // (rt1: the one just unchecked is itself "free" and first in the list,
      // so the old step re-added it and only the order changed).
      String label(Widget w) {
        final tt = (w as CheckboxListTile).title;
        return tt is Text ? (tt.data ?? '') : '';
      }
      final checked = find.byWidgetPredicate((w) => w is CheckboxListTile && w.value == true);
      await f.waitFor(checked);
      final removed = label(f.tester.widget(checked.first));
      await f.tap(checked.first, settleSeconds: 0.6);
      final free = find.byWidgetPredicate((w) =>
          w is CheckboxListTile && w.value == false && w.onChanged != null && label(w) != removed);
      await f.tap(free.first, settleSeconds: 0.6);
      await f.shot('changed');
      await f.tapText(f.t.aichatSave, settleSeconds: 2);
      final after = await f.net(load);
      added = after.firstWhere((r) => !before.contains(r), orElse: () => '');
      if (added!.isEmpty) throw TestFailure('saved list did not change: $after');
      await f.shot('home-after-save');
    });
    await f.step('choice survives a restart', () async {
      await f.h.boot(f.tester);
      await f.home();
      final raw = await f.net(() => Settings.getString(
          v2 ? HomeV2Shortcuts.prefsKey : HomeQuickButtons.prefsKey));
      final list = (jsonDecode(raw ?? '[]') as List).cast<String>();
      expect(list, contains(added));
      await f.shot('after-restart');
      f.note('quick buttons are stored on-device by design (no server round-trip); '
          'GET /app/home-defaults supplies the owner default');
    });
  });
}
