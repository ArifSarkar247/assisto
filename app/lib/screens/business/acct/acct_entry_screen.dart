import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../acct_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../messaging/date_separators.dart' show localDigits;
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart' show withNavBarInset;
import '../business_common.dart' show pair;
import 'acct_common.dart';
import 'acct_party_sheet.dart';

/// acctui — the ONE simple entry screen. The owner says what happened in
/// plain words (sale / purchase / expense / due / money in / money out /
/// transfer), how much, where the money is (cash, bank, bKash, Nagad) and who
/// with (khata / CRM / My Circle in one tap). The server turns it into a
/// balanced double entry (backend/core/logic/ledger_entry.py); the words
/// "debit" and "credit" never appear here. A plain-words line shows what the
/// entry will change before saving. No internet: the entry waits on the phone
/// (AcctQueue) and is sent later, once.
class AcctEntryScreen extends StatefulWidget {
  final int? businessId;
  final String kind;
  const AcctEntryScreen({super.key, this.businessId, this.kind = 'sale'});

  @override
  State<AcctEntryScreen> createState() => _AcctEntryScreenState();
}

class _AcctEntryScreenState extends State<AcctEntryScreen> {
  late String _kind = acctKinds.contains(widget.kind) ? widget.kind : 'sale';
  String _account = 'cash';
  String _toAccount = 'bank';
  String? _pay; // purchase: null = paid now, 'due' = on credit
  String _purposeIn = 'customer';
  String _purposeOut = 'supplier';
  String _category = '6900';
  Map<String, dynamic>? _party;
  DateTime _date = DateTime.now();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _vat = TextEditingController();
  final _cost = TextEditingController();
  final String _clientId = newAcctClientId();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _vat.dispose();
    _cost.dispose();
    super.dispose();
  }

  String get _purpose => _kind == 'money_in' ? _purposeIn : _purposeOut;
  String? get _partyBook => acctPartyBook(_kind, purpose: _purpose, pay: _pay);
  bool get _hasAccount => _kind != 'due' && !(_kind == 'purchase' && _pay == 'due');

  void _setKind(String k) => setState(() {
        if (acctPartyBook(k, purpose: k == 'money_in' ? _purposeIn : _purposeOut, pay: _pay) !=
            _partyBook) {
          _party = null; // a customer is not a supplier
        }
        _kind = k;
        _error = null;
      });

  Future<void> _pickParty() async {
    final book = _partyBook;
    if (book == null) return;
    final r = await pickAcctParty(context, businessId: widget.businessId, book: book);
    if (r != null && mounted) {
      setState(() {
        _party = r;
        _error = null;
      });
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
    );
    if (d != null && mounted) setState(() => _date = d);
  }

  void _vatAt15() {
    final a = parseTakaToPoisha(_amount.text);
    if (a == null) return;
    setState(() => _vat.text = poishaToField((a * 15 / 115).round()));
  }

  Map<String, dynamic>? _body(AppLocalizations t) {
    final amount = parseTakaToPoisha(_amount.text);
    if (amount == null) {
      setState(() => _error = t.acuErrAmount);
      return null;
    }
    if (_kind == 'transfer' && _account == _toAccount) {
      setState(() => _error = t.acuErrSameAccount);
      return null;
    }
    if (_partyBook != null && _party == null) {
      setState(() => _error = t.acuErrParty);
      return null;
    }
    final vat = (_kind == 'sale' || _kind == 'purchase') && _vat.text.trim().isNotEmpty
        ? parseTakaToPoisha(_vat.text)
        : 0;
    if (vat == null || vat >= amount) {
      setState(() => _error = t.acuErrVat);
      return null;
    }
    final cost = (_kind == 'sale' || _kind == 'due') && _cost.text.trim().isNotEmpty
        ? parseTakaToPoisha(_cost.text)
        : 0;
    if (cost == null) {
      setState(() => _error = t.acuErrCost);
      return null;
    }
    return {
      'client_id': _clientId,
      'kind': _kind,
      'amount': amount,
      'date': acctIso(_date),
      if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
      if (_hasAccount) 'account': _account,
      if (_kind == 'purchase' && _pay == 'due') 'pay': 'due',
      if (_kind == 'transfer') 'to_account': _toAccount,
      if (_kind == 'expense') 'category': _category,
      if (_kind == 'money_in' || _kind == 'money_out') 'purpose': _purpose,
      if (vat > 0) 'vat': vat,
      if (cost > 0) 'cost': cost,
      if (_party != null) ...{
        if (_party!['party_id'] != null) 'party_id': _party!['party_id'],
        'party_name': _party!['name'] ?? '',
        if ('${_party!['phone'] ?? ''}'.isNotEmpty) 'party_phone': _party!['phone'],
      },
    };
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final body = _body(t);
    if (body == null) return;
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final r = await api.acctCreateEntry(widget.businessId, body);
      final st = r['_status'] as int? ?? 0;
      if (st == 200 || st == 201) {
        messenger.showSnackBar(SnackBar(content: Text(t.acuSaved)));
        nav.pop(true);
        return;
      }
      if (st >= 400 && st < 500) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = pair(context, r['detail'], fallback: t.acuSaveFailed);
        });
        return;
      }
      await AcctQueue.add(widget.businessId, body); // server trouble: keep it
    } catch (_) {
      await AcctQueue.add(widget.businessId, body); // offline: keep it
    }
    messenger.showSnackBar(SnackBar(content: Text(t.acuQueued)));
    nav.pop(true);
  }

  // ---------------------------------------------------------------- effect
  String _effect(AppLocalizations t) {
    final a = parseTakaToPoisha(_amount.text);
    final amt = a == null ? t.acuFxTheAmount : acctMoney(context, a);
    final acc = acctAccountLabel(t, _account);
    final who = '${_party?['name'] ?? ''}'.isEmpty ? t.acuFxSomeone : '${_party!['name']}';
    switch (_kind) {
      case 'sale':
        return t.acuFxSale(amt, acc);
      case 'purchase':
        return _pay == 'due' ? t.acuFxPurchaseDue(amt, who) : t.acuFxPurchase(amt, acc);
      case 'expense':
        return t.acuFxExpense(amt, acc);
      case 'due':
        return t.acuFxDue(amt, who);
      case 'money_in':
        return _purposeIn == 'customer' ? t.acuFxInCustomer(amt, acc, who) : t.acuFxIn(amt, acc);
      case 'money_out':
        return _purposeOut == 'supplier'
            ? t.acuFxOutSupplier(amt, acc, who)
            : t.acuFxOut(amt, acc);
      default:
        return t.acuFxTransfer(amt, acc, acctAccountLabel(t, _toAccount));
    }
  }

  // ---------------------------------------------------------------- build
  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.sm),
        child: Semantics(
          header: true,
          child: Text(s,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
      );

  Widget _chips<T>(List<T> values, T selected, String Function(T) label, void Function(T) on,
          {Key? key}) =>
      Wrap(key: key, spacing: Gap.sm, runSpacing: Gap.sm, children: [
        for (final v in values)
          ChoiceChip(
            label: Text(label(v)),
            selected: v == selected,
            onSelected: (_) => setState(() {
              on(v);
              _error = null;
            }),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lang = acctLang(context);
    final isToday = acctIso(_date) == acctIso(DateTime.now());
    return Scaffold(
      appBar: AppBar(title: Text(t.acuNewEntry)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl)),
        children: [
          _label(t.acuWhatHappened),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final k in acctKinds)
              ChoiceChip(
                key: ValueKey('acct-kind-$k'),
                avatar: Icon(acctKindIcon(k), size: 18),
                label: Text(acctKindLabel(t, k)),
                selected: _kind == k,
                onSelected: (_) => _setKind(k),
              ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(acctKindHint(t, _kind),
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          _label(t.acuAmount),
          TextField(
            key: const ValueKey('acct-amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              prefixText: '৳ ',
              hintText: localDigits('0', lang),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
          if (_kind == 'purchase') ...[
            _label(t.acuPaidHow),
            _chips<String>(['cash', 'bank', 'bkash', 'nagad', 'due'],
                _pay == 'due' ? 'due' : _account, (v) => acctAccountLabel(t, v), (v) {
              if (v == 'due') {
                _pay = 'due';
              } else {
                _pay = null;
                _account = v;
              }
              if (_partyBook == null) _party = null;
            }, key: const ValueKey('acct-accounts')),
          ] else if (_kind == 'transfer') ...[
            _label(t.acuFromAccount),
            _chips<String>(acctMoneyAccounts, _account, (v) => acctAccountLabel(t, v),
                (v) => _account = v),
            _label(t.acuToAccount),
            _chips<String>(acctMoneyAccounts, _toAccount, (v) => acctAccountLabel(t, v),
                (v) => _toAccount = v),
          ] else if (_kind != 'due') ...[
            _label(_kind == 'sale' || _kind == 'money_in' ? t.acuMoneyCameTo : t.acuMoneyWentFrom),
            _chips<String>(acctMoneyAccounts, _account, (v) => acctAccountLabel(t, v),
                (v) => _account = v,
                key: const ValueKey('acct-accounts')),
          ],
          if (_kind == 'money_in') ...[
            _label(t.acuWhatFor),
            _chips<String>(acctInPurposes, _purposeIn,
                (v) => acctPurposeLabel(t, 'money_in', v), (v) {
              _purposeIn = v;
              if (_partyBook == null) _party = null;
            }),
          ],
          if (_kind == 'money_out') ...[
            _label(t.acuWhatFor),
            _chips<String>(acctOutPurposes, _purposeOut,
                (v) => acctPurposeLabel(t, 'money_out', v), (v) {
              _purposeOut = v;
              if (_partyBook == null) _party = null;
            }),
          ],
          if (_kind == 'expense') ...[
            _label(t.acuExpenseKind),
            _chips<String>(acctExpenseCodes, _category, (v) => acctExpenseLabel(t, v),
                (v) => _category = v),
          ],
          if (_partyBook != null) ...[
            _label(_partyBook == 'customer' ? t.acuWhichCustomer : t.acuWhichSupplier),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('acct-party'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 52), alignment: AlignmentDirectional.centerStart),
                icon: Icon(_party == null ? Icons.person_search_rounded : Icons.person_rounded),
                label: Text(_party == null ? t.acuPickParty : t.acuPartyChosen('${_party!['name']}'),
                    maxLines: 2),
                onPressed: _pickParty,
              ),
            ),
          ],
          const SizedBox(height: Gap.lg),
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(Radii.md)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.lightbulb_outline_rounded, color: scheme.onSecondaryContainer),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text(_effect(t),
                        style: TextStyle(color: scheme.onSecondaryContainer, height: 1.4))),
              ]),
            ),
          ),
          const SizedBox(height: Gap.sm),
          ExpansionTile(
            key: const ValueKey('acct-more'),
            tilePadding: EdgeInsets.zero,
            title: Text(t.acuMore),
            subtitle: Text(isToday ? t.acuDateToday : acctDay(context, acctIso(_date))),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_rounded),
                title: Text(t.acuDate),
                subtitle: Text(acctDay(context, acctIso(_date))),
                trailing: TextButton(onPressed: _pickDate, child: Text(t.acuChange)),
                onTap: _pickDate,
              ),
              TextField(
                controller: _note,
                maxLength: 160,
                decoration: InputDecoration(
                    labelText: t.acuNote, hintText: t.acuNoteHint, border: const OutlineInputBorder()),
              ),
              if (_kind == 'sale' || _kind == 'purchase') ...[
                const SizedBox(height: Gap.sm),
                TextField(
                  controller: _vat,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      prefixText: '৳ ',
                      labelText: t.acuVatAmount,
                      helperText: t.acuVatHelp,
                      helperMaxLines: 3,
                      border: const OutlineInputBorder()),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                      onPressed: _vatAt15,
                      icon: const Icon(Icons.calculate_rounded),
                      label: Text(t.acuVat15)),
                ),
              ],
              if (_kind == 'sale' || _kind == 'due') ...[
                const SizedBox(height: Gap.sm),
                TextField(
                  controller: _cost,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      prefixText: '৳ ',
                      labelText: t.acuCost,
                      helperText: t.acuCostHelp,
                      helperMaxLines: 3,
                      border: const OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: Gap.md),
            ],
          ),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(_error!,
                    key: const ValueKey('acct-error'),
                    style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
              ),
            ),
          const SizedBox(height: Gap.lg),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              key: const ValueKey('acct-save'),
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check_rounded),
              label: Text(t.acuSave),
            ),
          ),
        ],
      ),
    );
  }
}
