// invdesign — "Add invoice details" for a POS sale: the facts only the
// seller knows at the counter (table, token, server, IMEI/serial, warranty,
// courier, case number …). They print on the paper; the money, VAT and the
// QR check page never change (the server ignores anything else).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart';
import '../../../widgets/local_counter.dart';
import '../selling_common.dart' show showApiError;
import 'invoice_api.dart';
import 'invoice_doc.dart';
import 'invoice_paper.dart' show extraLabel, templateLabel;

/// Opens the sheet; returns the server's updated invoice JSON, or null.
Future<Map<String, dynamic>?> showInvoiceDetailsSheet(BuildContext context, InvoiceDoc doc,
        {int? businessId}) =>
    showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => InvoiceDetailsSheet(doc: doc, businessId: businessId),
    );

/// Digits typed in Bangla → int months (0 when blank, null when invalid).
int? typedMonths(String raw) {
  final s = raw.trim().replaceAllMapped(
      RegExp('[০-৯]'), (m) => '${m[0]!.codeUnitAt(0) - 0x09E6}');
  if (s.isEmpty) return 0;
  final v = int.tryParse(s);
  return (v == null || v < 0 || v > 120) ? null : v;
}

class InvoiceDetailsSheet extends StatefulWidget {
  const InvoiceDetailsSheet({super.key, required this.doc, this.businessId});
  final InvoiceDoc doc;
  final int? businessId;
  @override
  State<InvoiceDetailsSheet> createState() => _InvoiceDetailsSheetState();
}

class _InvoiceDetailsSheetState extends State<InvoiceDetailsSheet> {
  late final Map<String, TextEditingController> _x = {
    for (final k in templateFields[widget.doc.template] ?? const <String>[])
      k: TextEditingController(text: widget.doc.extras[k] ?? ''),
  };
  late final List<TextEditingController> _serial = [
    for (final l in widget.doc.lines) TextEditingController(text: l.serial)
  ];
  late final List<TextEditingController> _warranty = [
    for (final l in widget.doc.lines)
      TextEditingController(text: l.warrantyM > 0 ? '${l.warrantyM}' : '')
  ];
  bool _busy = false;
  bool _badMonths = false;

  bool get _perLine => widget.doc.template == 'electronics' ||
      widget.doc.lines.any((l) => l.serial.isNotEmpty || l.warrantyM > 0);

  @override
  void dispose() {
    for (final c in [..._x.values, ..._serial, ..._warranty]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final lines = <String, Map<String, dynamic>>{};
    if (_perLine) {
      for (var i = 0; i < widget.doc.lines.length; i++) {
        final m = typedMonths(_warranty[i].text);
        if (m == null) {
          setState(() => _badMonths = true);
          return;
        }
        final serial = _serial[i].text.trim();
        if (serial.isNotEmpty || m > 0) {
          lines['$i'] = {if (serial.isNotEmpty) 'serial': serial, if (m > 0) 'warranty_m': m};
        }
      }
    }
    setState(() {
      _busy = true;
      _badMonths = false;
    });
    try {
      final j = await context.read<AppState>().api.saleInvoiceDetails(widget.doc.id, {
        'template': widget.doc.template,
        'extras': {
          for (final e in _x.entries)
            if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim()
        },
        'lines': lines,
      }, businessId: widget.businessId);
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.ivdDetailsSaved)));
      Navigator.of(context).pop(j);
      return;
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _tf(TextEditingController c, String label,
          {int max = 160, TextInputType? kb, Key? key, String? error}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: TextField(
          key: key,
          controller: c,
          keyboardType: kb,
          maxLength: max,
          buildCounter: localCounter,
          inputFormatters: [LengthLimitingTextInputFormatter(max)],
          decoration: InputDecoration(labelText: label, errorText: error, errorMaxLines: 3),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final d = widget.doc;
    final keys = _x.keys.toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          children: [
            Text(t.ivdAddDetails, style: tt.titleLarge),
            const SizedBox(height: Gap.xs),
            Text('${t.ivdDesignLabel}: ${templateLabel(t, d.template)}',
                style: tt.titleSmall),
            const SizedBox(height: Gap.xs),
            Text(t.ivdDetailsHelp, style: tt.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            if (keys.isEmpty && !_perLine)
              Text(t.ivdDetailsNone, style: tt.bodyMedium),
            for (final k in keys)
              _tf(_x[k]!, extraLabel(t, k), key: ValueKey('ivd-x-$k')),
            if (_perLine)
              for (var i = 0; i < d.lines.length; i++) ...[
                const SizedBox(height: Gap.xs),
                Text(d.lines[i].desc, style: tt.titleSmall),
                const SizedBox(height: Gap.xs),
                _tf(_serial[i], t.invXSerial, max: 60, key: ValueKey('ivd-serial-$i')),
                _tf(_warranty[i], t.ivdWarrantyMonths,
                    max: 3,
                    kb: TextInputType.number,
                    key: ValueKey('ivd-warranty-$i'),
                    error: _badMonths ? t.ivdWarrantyBad : null),
              ],
            const SizedBox(height: Gap.sm),
            FilledButton(
              key: const ValueKey('ivd-save'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.ivdDetailsSave),
            ),
          ],
        ),
      ),
    );
  }
}
