// Priority 5-6: reminders, notes, todos, money, budgets — each asserts the
// item the UI created comes back from the SERVER (sync round-trip).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

Future<bool> _serverHas(RFlow f, String path, String field, String value) async {
  final api = await f.h.backend();
  final rows = await api.listItems(path);
  return rows.any((r) => '${r[field] ?? ''}'.contains(value));
}

void registerPersonalFlows() {
  realityFlow('08_reminders', 'Personal', 'Reminders: quick-add + form, synced to server', (f) async {
    await f.home();
    final quick = 'Call Ammu tomorrow 9am r$_tag';
    final form = 'Pay electricity bill r$_tag';
    await f.step('open Reminders from the drawer', () async {
      await f.openFeature(f.t.navReminders, 'reminders');
      await f.shot('reminders');
    });
    await f.step('natural-language quick add', () async {
      await f.enter(quick, label: f.t.remQuickAddHint);
      await f.pumpFor(const Duration(seconds: 2)); // live parse preview
      await f.shot('quick-preview');
      await f.tap(find.widgetWithText(FilledButton, f.t.add), settleSeconds: 3);
      await f.shot('quick-added');
      await f.eventually('reminder "$quick" on server',
          () => _serverHas(f, 'reminders', 'title', 'r$_tag'));
    });
    await f.step('full form (+ button)', () async {
      await f.tap(find.widgetWithText(FloatingActionButton, f.t.add));
      await f.enter(form, label: f.t.remWhatToRemind);
      await f.shot('form');
      await f.tapSave();
      await f.shot('saved');
      await f.eventually('reminder "$form" on server',
          () => _serverHas(f, 'reminders', 'title', form));
      f.note('OS alarm firing with the app closed needs a real phone (checklist item)');
    });
  });

  realityFlow('09_notes', 'Personal', 'Notes: create, synced to server', (f) async {
    await f.home();
    final title = 'Reality note n$_tag';
    await f.step('open Notes & tasks', () async {
      await f.openFeature(f.t.navNotesTasks, 'notes');
      await f.shot('notes');
    });
    await f.step('add a note', () async {
      await f.tap(find.byType(FloatingActionButton).hitTestable());
      await f.enter(title, label: f.t.title);
      await f.enter('written by the reality flow', label: f.t.notesBody);
      await f.shot('note-form');
      await f.tapSave();
      await f.waitFor(find.textContaining(title), what: 'note card');
      await f.shot('note-listed');
      await f.eventually('note on server', () => _serverHas(f, 'notes', 'title', title));
    });
  });

  realityFlow('10_todos', 'Personal', 'To-dos: create + tick done, synced', (f) async {
    await f.home();
    final title = 'Reality todo t$_tag';
    await f.step('open the To-do tab', () async {
      await f.openFeature(f.t.navNotesTasks, 'notes');
      await f.tapText(f.t.notesTabTodos);
      await f.shot('todos');
    });
    await f.step('add a task', () async {
      await f.tap(find.byType(FloatingActionButton).hitTestable().last);
      await f.enter(title, label: f.t.notesTaskField);
      await f.tapSave();
      await f.waitFor(find.textContaining(title));
      await f.shot('task-listed');
      await f.eventually('todo on server', () => _serverHas(f, 'todos', 'title', title));
    });
    await f.step('tick it done -> server done=true', () async {
      final box = find.ancestor(of: find.textContaining(title), matching: find.byType(ListTile));
      final cb = find.descendant(of: box.first, matching: find.byType(Checkbox));
      await f.tap(cb.evaluate().isNotEmpty ? cb : box);
      await f.shot('ticked');
      final api = await f.h.backend();
      await f.eventually('todo done on server', () async {
        final rows = await api.listItems('todos');
        return rows.any((r) => r['title'] == title && r['done'] == true);
      });
    });
  });

  realityFlow('11_money', 'Money', 'Money: add an expense, server balance moves', (f) async {
    await f.home();
    final note = 'Reality tea m$_tag';
    await f.step('open Money', () async {
      await f.openFeature(f.t.moduleMoney, 'money');
      await f.shot('money');
      f.expectHttp('GET', '/money/summary');
    });
    await f.step('add a 75 taka expense', () async {
      // Current UI (rt1): Money opens on Summary; adding lives on the
      // Transaction tab's "+ Transaction" button.
      await f.tap(find.descendant(of: find.byType(TabBar),
          matching: find.text(f.t.moneyTransactionFallback)), settleSeconds: 2);
      await f.tap(find.byType(FloatingActionButton).hitTestable());
      await f.waitFor(find.text(f.t.moneyNewTransaction));
      await f.enter('75', label: f.t.moneyFieldAmountRequired);
      await f.enter('food', label: f.t.moneyFieldCategoryHint);
      await f.enter(note, label: f.t.moneyFieldNoteOptional);
      await f.shot('txn-form');
      await f.tapSave();
      await f.shot('txn-saved');
      await f.eventually('transaction on server', () => _serverHas(f, 'transactions', 'note', note));
    });
  });

  realityFlow('12_budget', 'Money', 'Budgets: add a category limit, synced', (f) async {
    await f.home();
    final cat = 'transport$_tag';
    await f.step('open Budget', () async {
      await f.openFeature(f.t.budgetTitle, 'budget');
      await f.shot('budget');
    });
    await f.step('add a 3000 taka transport budget', () async {
      await f.tap(find.byType(FloatingActionButton).hitTestable());
      await f.enter(cat, label: f.t.budgetFieldCategory);
      await f.enter('3000', label: f.t.budgetFieldLimit);
      await f.shot('budget-form');
      await f.tapSave();
      await f.shot('budget-saved');
      await f.eventually('budget on server', () => _serverHas(f, 'budgets', 'category', cat));
    });
  });
}
