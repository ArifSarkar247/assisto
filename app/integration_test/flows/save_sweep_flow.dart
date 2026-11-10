// savesweep (owner P0, 10 Nov 01:20): "Save does nothing" must never happen.
//
// GENERATED per form from the [_forms] table: for every create form two
// reality flows are registered —
//   SV_<id>_save    open the form, fill it (amounts in BANGLA digits, the way
//                   the owner's keyboard types them), tap the visible Save,
//                   require the POST to reach the server (2xx) and the new
//                   item on screen;
//   SV_<id>_reopen  the app is booted again from scratch (realityFlow boots
//                   per flow: widget tree torn down, storage/token survive —
//                   a close-and-reopen), the form's screen is opened and the
//                   item must still be there.
// Test accounts only (Harness phoneA). A failing row fails the reality run.
//
// Add a form = add one _Form row. Covered elsewhere (not duplicated): CRM
// lead (business_flow 19), documents (docs_voice_settings_flow 21).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/business/products_screen.dart';
import 'package:assisto/screens/mess_accounting_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

String _bn(String latin) => String.fromCharCodes(latin.codeUnits
    .map((c) => c >= 0x30 && c <= 0x39 ? 0x09E6 + (c - 0x30) : c));

/// Text containing [latin] in Latin OR Bangla digits.
Finder _textAny(String latin) => find.byWidgetPredicate((w) {
      final s = w is Text ? (w.data ?? w.textSpan?.toPlainText() ?? '') : null;
      return s != null && (s.contains(latin) || s.contains(_bn(latin)));
    });

Finder _tab(RFlow f, String label) =>
    find.descendant(of: find.byType(TabBar), matching: find.text(label));

class _Form {
  const _Form(this.id, this.section, this.feature,
      {required this.open, required this.fill, required this.shown, this.post});
  final String id, section, feature;
  final Future<void> Function(RFlow f) open;
  final Future<void> Function(RFlow f) fill; // fill + tap Save
  final Finder Function(RFlow f) shown;
  final String? post; // path prefix the save must POST
}

Future<void> _openFamAcct(RFlow f, String inner) async {
  await f.openFeature(f.t.moduleFamily, 'family');
  await f.tap(_tab(f, f.t.faTitle), settleSeconds: 3);
  await f.tap(_tab(f, inner), settleSeconds: 2);
}

Future<int> _bizId(RFlow f) async {
  final api = await f.h.backend();
  final b = await f.net(() => api.getJson('/business/profiles'));
  return (b['selected_id'] as num).toInt();
}

final List<_Form> _forms = [
  _Form('famacct_pool', 'Family', 'Family accounting: fund goal 15000 (Bangla digits)',
      open: (f) => _openFamAcct(f, f.t.faTabPool),
      fill: (f) async {
        await f.tap(find.text(f.t.faPoolSetTarget));
        await f.tester.enterText(
            find.byKey(const ValueKey('fa-amount-field')), _bn('15000'));
        await f.tap(find.byKey(const ValueKey('fa-amount-save')).hitTestable(),
            settleSeconds: 3);
      },
      shown: (f) => _textAny('15,000'),
      post: '/family/accounting/pool'),
  _Form('famacct_expense', 'Family', 'Family accounting: expense 10000 bazar (Bangla digits)',
      open: (f) => _openFamAcct(f, f.t.faTabExpenses),
      fill: (f) async {
        final fab = find.byTooltip(f.t.faAddExpense).hitTestable();
        await f.tap(fab.evaluate().isNotEmpty
            ? fab
            : find.widgetWithText(FilledButton, f.t.faAddExpense));
        await f.tester.enterText(
            find.byKey(const ValueKey('fa-expense-amount')), _bn('10000'));
        await f.enter('bazar s$_tag', label: f.t.faNote);
        await f.tap(find.byKey(const ValueKey('fa-expense-save')).hitTestable(),
            settleSeconds: 3);
      },
      shown: (f) => find.textContaining('bazar s$_tag'),
      post: '/family/accounting/expenses'),
  _Form('mess_member', 'Money', 'Mess and bachelor: Add member',
      open: (f) => f.pushScreen(const MessAccountingScreen()),
      fill: (f) async {
        await f.tap(find.text(f.t.messAddMember));
        await f.enter('Mess Rafiq s$_tag', label: f.t.messMemberName);
        await f.tapSave(); // the VISIBLE + hit-testable Save (owner's dead Save)
      },
      shown: (f) => find.textContaining('Mess Rafiq s$_tag'),
      post: '/mess/members'),
  _Form('money_txn', 'Money', 'Money: expense with Bangla amount',
      open: (f) async {
        await f.openFeature(f.t.moduleMoney, 'money');
        await f.tap(_tab(f, f.t.moneyTransactionFallback), settleSeconds: 2);
      },
      fill: (f) async {
        await f.tap(find.byType(FloatingActionButton).hitTestable());
        await f.waitFor(find.text(f.t.moneyNewTransaction));
        await f.enter(_bn('85'), label: f.t.moneyFieldAmountRequired);
        await f.enter('Money tea s$_tag', label: f.t.moneyFieldNoteOptional);
        await f.tapSave();
      },
      shown: (f) => find.textContaining('Money tea s$_tag')),
  _Form('reminder', 'Personal', 'Reminders: form',
      open: (f) => f.openFeature(f.t.navReminders, 'reminders'),
      fill: (f) async {
        await f.tap(find.widgetWithText(FloatingActionButton, f.t.add));
        await f.enter('Pay gas bill s$_tag', label: f.t.remWhatToRemind);
        await f.tapSave();
      },
      shown: (f) => find.textContaining('Pay gas bill s$_tag')),
  _Form('note', 'Personal', 'Notes: create',
      open: (f) => f.openFeature(f.t.navNotesTasks, 'notes'),
      fill: (f) async {
        await f.tap(find.byType(FloatingActionButton).hitTestable());
        await f.enter('Save sweep note s$_tag', label: f.t.title);
        await f.enter('body', label: f.t.notesBody);
        await f.tapSave();
      },
      shown: (f) => find.textContaining('Save sweep note s$_tag')),
  _Form('khata_party', 'Business', 'Khata: add a party',
      open: (f) async {
        await f.openFeature(f.t.business, 'business');
        await f.tap(find.text(f.t.khataTitle), settleSeconds: 3);
      },
      fill: (f) async {
        await f.tap(find.byTooltip(f.t.khataAddCustomer));
        await f.enter('Khata Sumon s$_tag', label: f.t.name);
        await f.enter(_bn('01700000041'), label: f.t.phone);
        await f.tapSave();
      },
      shown: (f) => find.textContaining('Khata Sumon s$_tag'),
      post: '/business/khata/parties'),
  _Form('biz_product', 'Business', 'My Business: product with Bangla price',
      open: (f) async {
        final id = await _bizId(f);
        await f.pushScreen(ProductsScreen(businessId: id));
      },
      fill: (f) async {
        await f.tap(find.text(f.t.shopQaAddProduct));
        await f.enter('Sweep Soap s$_tag', label: f.t.biz_product_name);
        await f.enter(_bn('120'), label: f.t.biz_sell_price);
        await f.tapSave();
      },
      shown: (f) => find.textContaining('Sweep Soap s$_tag'),
      post: '/business/products'),
];

void registerSaveSweepFlows() {
  for (final form in _forms) {
    realityFlow('SV_${form.id}_save', form.section, '${form.feature}: fill + Save',
        (f) async {
      await f.home();
      final mark = f.h.recorder.hits.length;
      await f.step('open', () => form.open(f));
      await f.step('fill + tap Save', () async {
        await form.fill(f);
        await f.shot('saved');
      });
      if (form.post != null) {
        await f.step('the save reached the server', () async {
          f.expectHttp('POST', form.post!, since: mark);
        });
      }
      await f.step('saved item shown', () async {
        await f.waitFor(form.shown(f), what: 'saved item');
      });
    });
    realityFlow('SV_${form.id}_reopen', form.section,
        '${form.feature}: still there after reopen', (f) async {
      await f.home();
      await f.step('open after a fresh boot', () => form.open(f));
      await f.step('item still there', () async {
        await f.waitFor(form.shown(f), what: 'item after reopen');
        await f.shot('after-reopen');
      });
    });
  }
}
