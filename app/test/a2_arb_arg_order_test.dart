// a2 scope of the systemic gen-l10n arg-order bug (found by a1): parameters
// follow the ARB *metadata* placeholder order, not the text order. These pin
// the signature order the fixed call sites rely on, so a metadata reorder
// breaks this test instead of silently swapping values on screen.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/l10n/app_localizations.dart';

void main() {
  final t = lookupAppLocalizations(const Locale('en'));

  bool before(String s, String a, String b) => s.indexOf(a) >= 0 && s.indexOf(a) < s.indexOf(b);

  test('Business + Money call-site signatures are pinned', () {
    expect(t.plMsgReceivable('AMT', 'PARTY'), startsWith('PARTY'));
    expect(before(t.plMsgPayable('AMT', 'PARTY'), 'PARTY', 'AMT'), isTrue);
    expect(t.splitPaidBySplit('MODE', 'NAME'), 'Paid by NAME · MODE');
    expect(before(t.samityRecordPayoutBody('CYC', 'NAME'), 'NAME', 'CYC'), isTrue);
    expect(t.rentStatusCounts('D', 'P', 'X'), 'P paid · X partial · D due');
    expect(t.rentBillPaid('BILL', 'PAID'), 'PAID of BILL paid');
    expect(t.staffDaysPresent(30, 22), '22/30 days');
    expect(t.pnlRevCost('COST', 'REV'), 'Revenue REV · Cost COST');
    expect(before(t.pnlBreakEvenBody('ADREV', 'USERS'), 'USERS', 'ADREV'), isTrue);
    expect(t.camSentPartial(1, 3), 'Sent to 3, 1 failed.');
    expect(t.spendObsTopCategory('AMT', 'CAT', 40), startsWith('Your top category is CAT: AMT'));
    expect(t.spendObsMomUp('AMT', 12), contains('up 12% (AMT)'));
    expect(t.spendObsMomDown('AMT', 12), contains('down 12% (AMT)'));
    expect(t.spendObsMoverUp('AMT', 'CAT', 5), contains('CAT: up AMT (5%)'));
    expect(t.spendObsMoverDown('AMT', 'CAT', 5), contains('CAT: down AMT (5%)'));
    expect(t.spendObsOverBudget('AMT', 'BUD', 'CAT'), 'CAT is AMT over your BUD budget.');
  });
}
