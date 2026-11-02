// invoices — a manual (service) invoice: lawyer, VAT/tax consultant, any
// service — or any business selling outside Quick Sell. The client comes from
// the shop's customers or My Circle in one tap. The server numbers it (SV-…)
// and does the VAT math; this screen only collects the facts.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../business_selling_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart';
import '../../../widgets/cv_empty.dart' show pickCirclePerson;
import '../selling_common.dart' show showApiError;
import 'invoice_api.dart';
import 'invoice_doc.dart';
import 'invoice_paper.dart' show extraLabel, templateLabel;
import 'invoice_screen.dart';

/// Typed money ("1,250.50", Bangla digits ok) → poisha; null when invalid.
int? typedPoisha(String raw) {
  final s = raw.trim().replaceAll(',', '').replaceAllMapped(
      RegExp('[\u09E6-\u09EF]'), (m) => '${m[0]!.codeUnitAt(0) - 0x09E6}');
  if (s.isEmpty) return 0;
  final v = double.tryParse(s);
  if (v == null || v < 0) return null;
  return (v * 100).round();
}

int? typedQty(String raw) {
  final s = raw.trim().replaceAllMapped(
      RegExp('[\u09E6-\u09EF]'), (m) => '${m[0]!.codeUnitAt(0) - 0x09E6}');
  final v = int.tryParse(s.isEmpty ? '1' : s);
  return (v == null || v <= 0) ? null : v;
}

class _LineCtl {
  final desc = TextEditingController();
  final qty = TextEditingController(text: '1');
  final unit = TextEditingController();
  void dispose() {
    desc.dispose();
    qty.dispose();
    unit.dispose();
  }
}

class NewInvoiceScreen extends StatefulWidget {
  const NewInvoiceScreen({super.key, this.businessId});
  final int? businessId;
  @override
  State<NewInvoiceScreen> createState() => _NewInvoiceScreenState();
}

class _NewInvoiceScreenState extends State<NewInvoiceScreen> {
  String _template = 'service';
  bool _vatReady = false;
  bool _noVat = false;
  bool _busy = false;
  final _name = TextEditingController(),
      _phone = TextEditingController(),
      _address = TextEditingController(),
      _bin = TextEditingController(),
      _discount = TextEditingController(),
      _paid = TextEditingController(),
      _note = TextEditingController();
  final Map<String, TextEditingController> _extras = {};
  final List<_LineCtl> _lines = [_LineCtl()];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSettings());
  }

  Future<void> _loadSettings() async {
    try {
      final r = await context.read<AppState>().api.invoiceSettings(businessId: widget.businessId);
      final s = (r['settings'] as Map?) ?? const {};
      if (!mounted) return;
      setState(() {
        if (invoiceTemplates.contains(s['template'])) _template = s['template'] as String;
        _vatReady = s['vat_mode'] != 'none' &&
            '${s['bin'] ?? ''}'.replaceAll(RegExp(r'\D'), '').isNotEmpty;
      });
    } catch (_) {
      // best-effort: the form still works; the server applies the saved settings anyway
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _bin, _discount, _paid, _note, ..._extras.values]) {
      c.dispose();
    }
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  TextEditingController _x(String k) => _extras.putIfAbsent(k, TextEditingController.new);

  Future<void> _fromCustomers() async {
    final t = AppLocalizations.of(context);
    List<Map<String, dynamic>> rows;
    try {
      rows = await context.read<AppState>().api.customersList(businessId: widget.businessId);
    } catch (e) {
      if (mounted) showApiError(context, e);
      return;
    }
    if (!mounted) return;
    final pick = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: rows.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Text(t.invNoCustomers, textAlign: TextAlign.center),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
                    child: Text(t.invPickCustomer, style: Theme.of(ctx).textTheme.titleMedium),
                  ),
                  for (final c in rows)
                    ListTile(
                      minVerticalPadding: Gap.sm,
                      leading: const Icon(Icons.person_outline_rounded),
                      title: Text('${c['name'] ?? ''}'.isEmpty ? '${c['phone'] ?? ''}' : '${c['name']}'),
                      subtitle: Text('${c['phone'] ?? ''}'),
                      onTap: () => Navigator.pop(ctx, c),
                    ),
                ],
              ),
      ),
    );
    if (pick == null || !mounted) return;
    setState(() {
      _name.text = '${pick['name'] ?? ''}';
      _phone.text = '${pick['phone'] ?? ''}';
      final addr = '${pick['address'] ?? pick['area'] ?? ''}';
      if (addr.isNotEmpty) _address.text = addr;
    });
  }

  Future<void> _fromCircle() async {
    final t = AppLocalizations.of(context);
    final p = await pickCirclePerson(context, title: t.invPickCircle);
    if (p == null || !mounted) return;
    setState(() {
      _name.text = '${p['name'] ?? ''}';
      _phone.text = '${p['phone'] ?? ''}';
    });
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (_name.text.trim().isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(t.invNeedClient)));
      return;
    }
    final lines = <Map<String, dynamic>>[];
    for (final l in _lines) {
      final desc = l.desc.text.trim();
      if (desc.isEmpty && l.unit.text.trim().isEmpty) continue;
      final q = typedQty(l.qty.text), u = typedPoisha(l.unit.text);
      if (desc.isEmpty || q == null || u == null) {
        messenger.showSnackBar(SnackBar(content: Text(t.invNeedLine)));
        return;
      }
      lines.add({'desc': desc, 'qty': q, 'unit': u});
    }
    if (lines.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(t.invNeedLine)));
      return;
    }
    final disc = typedPoisha(_discount.text), paid = typedPoisha(_paid.text);
    if (disc == null || paid == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.invNeedLine)));
      return;
    }
    setState(() => _busy = true);
    try {
      final j = await context.read<AppState>().api.manualInvoiceCreate({
        'template': _template,
        'buyer': {
          'name': _name.text.trim(),
          'phone': _phone.text.trim(),
          'address': _address.text.trim(),
          'bin': _bin.text.trim(),
        },
        'extras': {
          for (final k in templateFields[_template] ?? const <String>[])
            if ((_extras[k]?.text.trim() ?? '').isNotEmpty) k: _extras[k]!.text.trim(),
        },
        'lines': lines,
        'discount': disc,
        'paid': paid,
        'no_vat': _noVat,
        'note': _note.text.trim(),
      }, businessId: widget.businessId);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => InvoiceScreen(initial: j, businessId: widget.businessId)));
      return;
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _tf(TextEditingController c, String label,
          {TextInputType? kb, int maxLines = 1, String? prefix, Key? key}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: TextField(
          key: key,
          controller: c,
          keyboardType: kb,
          minLines: 1,
          maxLines: maxLines,
          decoration: InputDecoration(labelText: label, prefixText: prefix),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    const money = TextInputType.numberWithOptions(decimal: true);
    return Scaffold(
      appBar: AppBar(title: Text(t.invNewTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
        children: [
          Text(t.invSetBusinessType, style: tt.titleMedium),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final k in invoiceTemplates)
              ChoiceChip(
                label: Text(templateLabel(t, k)),
                selected: _template == k,
                onSelected: (_) => setState(() => _template = k),
              ),
          ]),
          const SizedBox(height: Gap.lg),
          Text(serviceTemplates.contains(_template) ? t.invClient : t.invBillTo, style: tt.titleMedium),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _fromCustomers,
              icon: const Icon(Icons.storefront_rounded),
              label: Text(t.invPickCustomer),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _fromCircle,
              icon: const Icon(Icons.diversity_3_rounded),
              label: Text(t.invPickCircle),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          _tf(_name, t.invClientName, key: const ValueKey('inv-client-name')),
          _tf(_phone, t.invClientPhone, kb: TextInputType.phone),
          _tf(_address, t.invClientAddress, maxLines: 3),
          _tf(_bin, t.invClientBin, kb: TextInputType.number),
          for (final k in templateFields[_template] ?? const <String>[])
            _tf(_x(k), extraLabel(t, k), maxLines: k == 'delivery_address' ? 3 : 1),
          const SizedBox(height: Gap.md),
          Text(t.invLinesTitle, style: tt.titleMedium),
          const SizedBox(height: Gap.sm),
          for (var i = 0; i < _lines.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
                child: Column(children: [
                  Row(children: [
                    Expanded(
                        child: _tf(_lines[i].desc, t.invLineDesc,
                            maxLines: 3, key: ValueKey('inv-line-desc-$i'))),
                    if (_lines.length > 1)
                      IconButton(
                        tooltip: t.invRemoveLine,
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => setState(() => _lines.removeAt(i).dispose()),
                      ),
                  ]),
                  Wrap(spacing: Gap.sm, children: [
                    SizedBox(width: 110, child: _tf(_lines[i].qty, t.invLineQty, kb: TextInputType.number)),
                    SizedBox(
                        width: 180,
                        child: _tf(_lines[i].unit, t.invLineUnit,
                            kb: money, prefix: '৳ ', key: ValueKey('inv-line-unit-$i'))),
                  ]),
                ]),
              ),
            ),
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () => setState(() => _lines.add(_LineCtl())),
            icon: const Icon(Icons.add_rounded),
            label: Text(t.invAddLine),
          ),
          const SizedBox(height: Gap.sm),
          _tf(_discount, t.invDiscountTk, kb: money, prefix: '৳ '),
          _tf(_paid, t.invPaidTk, kb: money, prefix: '৳ '),
          if (_vatReady)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _noVat,
              onChanged: (v) => setState(() => _noVat = v),
              title: Text(t.invNoVat),
            ),
          _tf(_note, t.invNote, maxLines: 3),
          const SizedBox(height: Gap.md),
          FilledButton(
            key: const ValueKey('inv-create'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(t.invCreate),
          ),
        ],
      ),
    );
  }
}
