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

import 'package:assisto/family_v3/family_v3_screen.dart';
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
      {required this.open, required this.fill, required this.shown, this.post, this.reopen});
  final String id, section, feature;
  final Future<void> Function(RFlow f) open;
  /// gatefix: how the _reopen flow opens the screen when [open] also does
  /// test setup that must not run again (default: [open]).
  final Future<void> Function(RFlow f)? reopen;
  final Future<void> Function(RFlow f) fill; // fill + tap Save
  final Finder Function(RFlow f) shown;
  final String? post; // path prefix the save must POST
}

Future<void> _openFamAcct(RFlow f, String inner) async {
  await f.openFeature(f.t.moduleFamily, 'family');
  // gatefix: Family v3 (switch family_v3, default ON) has no tab bar — family
  // accounting is the "More" row fc3-more-ledger (same FamAcctSection). The
  // old 6-tab screen (switch off) keeps its "Family accounting" tab.
  final v3 = find.byType(FamilyV3Screen);
  final oldTab = _tab(f, f.t.faTitle);
  await f.waitFor(find.byWidgetPredicate((w) => w is FamilyV3Screen || w is TabBar),
      what: 'Family screen');
  if (v3.evaluate().isNotEmpty) {
    final row = find.byKey(const ValueKey('fc3-more-ledger'));
    await f.scrollToBuilt(row, what: 'Family accounting row (fc3-more-ledger)');
    await f.tap(row, settleSeconds: 3);
  } else {
    await f.tap(oldTab, settleSeconds: 3);
  }
  await f.tap(_tab(f, inner), settleSeconds: 2);
}

// gatefix: Mess V2 adds members ONLY from My Circle (no name-only member,
// no POST /mess/members any more — the V1 form this row used is gone). Setup
// by API: A has a mess (free plan: one), and B is not an ACTIVE member (the
// 41_mess_v2 flow added B earlier in the same leg). The add itself is UI.
int? _messId;
int? _messPickB;

Future<void> _openMessMembers(RFlow f, int mid) async {
  await f.pushScreen(const MessAccountingScreen());
  final row = find.byKey(ValueKey('mess-$mid'));
  await f.scrollToBuilt(row, what: 'the mess in the list');
  await f.tap(row, settleSeconds: 3);
  await f.tap(find.text(f.t.mv2TabMembers), settleSeconds: 2);
}

Future<void> _messSetup(RFlow f) async {
  final api = await f.h.backend();
  await f.net(() async {
    var list = ((await api.getJson('/mess/v2'))['messes'] as List).cast<Map>();
    if (list.isEmpty) {
      await api.postJson('/mess/v2', {'name': 'Sweep Mess s$_tag'});
      list = ((await api.getJson('/mess/v2'))['messes'] as List).cast<Map>();
    }
    final mid = (list.first['id'] as num).toInt();
    _messId = mid;
    final d = await api.getJson('/mess/v2/$mid');
    for (final m in (d['members'] as List).cast<Map>()) {
      if (m['name'] == Seed.nameB && m['status'] == 'active') {
        await api.postJson('/mess/v2/$mid/members/${m['id']}', {'action': 'remove'});
      }
    }
    final pick = await api.getJson('/mess/v2/$mid/circle-pick');
    final rows = ((pick['results'] ?? pick['members'] ?? pick['rows'] ?? const []) as List).cast<Map>();
    final b = rows.firstWhere((r) => r['name'] == Seed.nameB,
        orElse: () => throw TestFailure('B not offered by circle-pick: $pick'));
    if (b['in_mess'] == true) throw TestFailure('B still in the mess after setup: $b');
    _messPickB = (b['circle_member_id'] as num).toInt();
  });
}

Finder _messMemberRow(String name) => find.descendant(
    of: find.byWidgetPredicate((w) =>
        w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('mess-member-')),
    matching: find.text(name));

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
      open: (f) async {
        await _messSetup(f);
        await _openMessMembers(f, _messId!);
      },
      reopen: (f) async {
        final api = await f.h.backend();
        final list = await f.net(() => api.getJson('/mess/v2'));
        await _openMessMembers(f, ((list['messes'] as List).first['id'] as num).toInt());
      },
      fill: (f) async {
        final mark = f.httpMark;
        await f.tap(find.byKey(const ValueKey('mess-add-member')), settleSeconds: 3);
        final add = find.descendant(
            of: find.byKey(ValueKey('mess-pick-$_messPickB')), matching: find.text(f.t.mv2Add));
        await f.tap(add, settleSeconds: 3);
        f.expectHttp('POST', '/mess/v2/$_messId/members', since: mark);
        await f.tap(find.byKey(const ValueKey('mess-pick-done')), settleSeconds: 3);
        final api = await f.h.backend();
        await f.eventually('server: B is an active member again', () async {
          final d = await api.getJson('/mess/v2/$_messId');
          return (d['members'] as List).cast<Map>()
              .any((m) => m['name'] == Seed.nameB && m['status'] == 'active');
        });
      },
      shown: (f) => _messMemberRow(Seed.nameB),
      post: '/mess/v2/'),
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
        // gatefix: homeshort moved the ledger into My Business as the FIRST
        // tile, titled "Digital Ledger" (hv2TileLedger) — tap it by its Key.
        final ledger = find.byKey(const ValueKey('biz_hub_ledger'));
        await f.scrollToBuilt(ledger, what: 'Digital Ledger tile (biz_hub_ledger)');
        await f.tap(ledger, settleSeconds: 3);
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
      await f.step('open after a fresh boot', () => (form.reopen ?? form.open)(f));
      await f.step('item still there', () async {
        await f.waitFor(form.shown(f), what: 'item after reopen');
        await f.shot('after-reopen');
      });
    });
  }
}
