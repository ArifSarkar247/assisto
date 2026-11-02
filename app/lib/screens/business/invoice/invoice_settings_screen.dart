// invoices — the seller block + VAT setup every invoice prints. Owner edits;
// staff see it read-only. VAT: only the 15 % standard rate (VAT & SD Act 2012
// s.15) is pre-filled; reduced rates are item-specific (Third Schedule), so
// the owner types theirs — Assisto never guesses a rate.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api.dart' show ApiException;
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart' show withNavBarInset;
import '../selling_common.dart' show showApiError;
import 'invoice_api.dart';
import 'invoice_doc.dart';
import 'invoice_paper.dart' show templateLabel;

/// "15", "7.5", Bangla-digit → basis points (null when not a number).
int? percentToBp(String raw) {
  final s = raw.trim().replaceAllMapped(
      RegExp('[\u09E6-\u09EF]'), (m) => '${m[0]!.codeUnitAt(0) - 0x09E6}');
  if (s.isEmpty) return 0;
  final v = double.tryParse(s);
  if (v == null || v < 0) return null;
  return (v * 100).round();
}

String bpToPercent(int bp) {
  final whole = bp ~/ 100, frac = bp % 100;
  if (frac == 0) return '$whole';
  return '$whole.${frac.toString().padLeft(2, '0').replaceAll(RegExp(r'0$'), '')}';
}

class InvoiceSettingsScreen extends StatefulWidget {
  const InvoiceSettingsScreen({super.key, this.businessId});
  final int? businessId;
  @override
  State<InvoiceSettingsScreen> createState() => _InvoiceSettingsScreenState();
}

class _InvoiceSettingsScreenState extends State<InvoiceSettingsScreen> {
  bool _loading = true, _saving = false, _canEdit = false;
  Object? _error;
  String _template = 'retail', _vatMode = 'none', _size = '80', _lang = 'bn';
  bool _verifyQr = true;
  final _name = TextEditingController(),
      _address = TextEditingController(),
      _phone = TextEditingController(),
      _bin = TextEditingController(),
      _signatory = TextEditingController(),
      _payLink = TextEditingController(),
      _footer = TextEditingController(),
      _vat = TextEditingController(),
      _sd = TextEditingController(),
      _service = TextEditingController();
  List<String> _badFields = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in [_name, _address, _phone, _bin, _signatory, _payLink, _footer, _vat, _sd, _service]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(Map s) {
    _template = invoiceTemplates.contains(s['template']) ? s['template'] as String : 'retail';
    _vatMode = const ['none', 'exclusive', 'inclusive'].contains(s['vat_mode'])
        ? s['vat_mode'] as String
        : 'none';
    _size = const ['58', '80', 'a4'].contains(s['size']) ? s['size'] as String : '80';
    _lang = s['lang'] == 'en' ? 'en' : 'bn';
    _verifyQr = s['verify_qr'] != false;
    _name.text = '${s['name'] ?? ''}';
    _address.text = '${s['address'] ?? ''}';
    _phone.text = '${s['phone'] ?? ''}';
    _bin.text = '${s['bin'] ?? ''}';
    _signatory.text = '${s['signatory'] ?? ''}';
    _payLink.text = '${s['payment_link'] ?? ''}';
    _footer.text = '${s['footer'] ?? ''}';
    _vat.text = bpToPercent((s['vat_bp'] as num?)?.toInt() ?? 1500);
    _sd.text = bpToPercent((s['sd_bp'] as num?)?.toInt() ?? 0);
    _service.text = bpToPercent((s['service_bp'] as num?)?.toInt() ?? 0);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<AppState>().api.invoiceSettings(businessId: widget.businessId);
      _apply((r['settings'] as Map?) ?? const {});
      _canEdit = r['can_edit'] == true;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final vat = percentToBp(_vat.text), sd = percentToBp(_sd.text), svc = percentToBp(_service.text);
    final bad = <String>[
      if (vat == null || vat > 1500) 'vat_bp',
      if (sd == null) 'sd_bp',
      if (svc == null || svc > 2000) 'service_bp',
      if (_vatMode != 'none' && _bin.text.replaceAll(RegExp(r'\D'), '').isEmpty) 'bin_required',
    ];
    if (bad.isNotEmpty) {
      setState(() => _badFields = bad);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.invSetFixFields)));
      return;
    }
    setState(() {
      _saving = true;
      _badFields = const [];
    });
    try {
      final r = await context.read<AppState>().api.invoiceSettingsSave({
        'template': _template,
        'name': _name.text.trim(),
        'address': _address.text.trim(),
        'phone': _phone.text.trim(),
        'bin': _bin.text.trim(),
        'signatory': _signatory.text.trim(),
        'payment_link': _payLink.text.trim(),
        'footer': _footer.text.trim(),
        'vat_mode': _vatMode,
        'vat_bp': vat,
        'sd_bp': sd,
        'service_bp': svc,
        'verify_qr': _verifyQr,
        'size': _size,
        'lang': _lang,
      }, businessId: widget.businessId);
      if (!mounted) return;
      _apply((r['settings'] as Map?) ?? const {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.invSetSaved)));
      Navigator.of(context).maybePop(true);
    } catch (e) {
      if (mounted) {
        showApiError(context, e);
        final f = e is ApiException ? e.body?['fields'] : null;
        final keys = f is List ? f.map((x) => '$x').toList() : <String>[];
        if (keys.contains('bin')) keys.add('bin_required');
        setState(() => _badFields = keys);
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Widget _field(TextEditingController c, String label,
      {String? helper, String? errorKey, TextInputType? kb, int maxLines = 1, String? errorText}) {
    final t = AppLocalizations.of(context);
    final err = errorKey != null && _badFields.contains(errorKey) ? (errorText ?? t.invSetFieldBad) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: TextField(
        controller: c,
        enabled: _canEdit,
        keyboardType: kb,
        minLines: 1,
        maxLines: maxLines,
        decoration: InputDecoration(
            labelText: label, helperText: helper, helperMaxLines: 4, errorText: err, errorMaxLines: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.invSetTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(t.invLoadFailed, textAlign: TextAlign.center),
                      const SizedBox(height: Gap.md),
                      FilledButton(onPressed: _load, child: Text(t.invRetry)),
                    ]),
                  ),
                )
              : ListView(
                  padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
                  children: [
                    if (!_canEdit)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Gap.md),
                        child: Text(t.invSetStaffNote, style: tt.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      ),
                    Text(t.invSetBusinessType, style: tt.titleMedium),
                    const SizedBox(height: Gap.sm),
                    Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                      for (final k in invoiceTemplates)
                        ChoiceChip(
                          key: ValueKey('inv-tpl-$k'),
                          label: Text(templateLabel(t, k)),
                          selected: _template == k,
                          onSelected: _canEdit ? (_) => setState(() => _template = k) : null,
                        ),
                    ]),
                    const SizedBox(height: Gap.lg),
                    Text(t.invSetSellerBlock, style: tt.titleMedium),
                    const SizedBox(height: Gap.sm),
                    _field(_name, t.invSetName),
                    _field(_address, t.invSetAddress, maxLines: 3),
                    _field(_phone, t.invSetPhone, kb: TextInputType.phone),
                    _field(_signatory, t.invSetSignatory),
                    _field(_footer, t.invSetFooter, maxLines: 2),
                    _field(_payLink, t.invSetPayLink, helper: t.invSetPayLinkHelp, kb: TextInputType.url, errorKey: 'payment_link'),
                    const SizedBox(height: Gap.sm),
                    Text(t.invSetVatTitle, style: tt.titleMedium),
                    const SizedBox(height: Gap.xs),
                    for (final m in const ['none', 'exclusive', 'inclusive'])
                      RadioListTile<String>(
                        key: ValueKey('inv-vat-$m'),
                        contentPadding: EdgeInsets.zero,
                        value: m,
                        groupValue: _vatMode,
                        onChanged: _canEdit ? (v) => setState(() => _vatMode = v ?? 'none') : null,
                        title: Text(switch (m) {
                          'exclusive' => t.invVatExclusive,
                          'inclusive' => t.invVatInclusive,
                          _ => t.invVatNone,
                        }),
                      ),
                    if (_vatMode != 'none') ...[
                      _field(_bin, t.invSetBin,
                          kb: TextInputType.number,
                          errorKey: 'bin_required',
                          errorText: _badFields.contains('bin') ? t.invSetBinBad : t.invSetBinNeeded),
                      _field(_vat, t.invSetVatRate,
                          helper: t.invSetVatRateHelp,
                          kb: const TextInputType.numberWithOptions(decimal: true),
                          errorKey: 'vat_bp'),
                      _field(_sd, t.invSetSd,
                          kb: const TextInputType.numberWithOptions(decimal: true), errorKey: 'sd_bp'),
                      Text(t.invSetPosNote, style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: Gap.xs),
                      Text(t.invSetNotEfd, style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: Gap.md),
                    ],
                    if (foodTemplates.contains(_template))
                      _field(_service, t.invSetService,
                          kb: const TextInputType.numberWithOptions(decimal: true), errorKey: 'service_bp'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _verifyQr,
                      onChanged: _canEdit ? (v) => setState(() => _verifyQr = v) : null,
                      title: Text(t.invSetVerifyQr),
                    ),
                    const SizedBox(height: Gap.sm),
                    Text(t.invSetDefaultPaper, style: tt.titleSmall),
                    const SizedBox(height: Gap.xs),
                    SegmentedButton<String>(
                      style: SegmentedButton.styleFrom(
                          minimumSize: const Size(0, 48), tapTargetSize: MaterialTapTargetSize.padded),
                      segments: [
                        ButtonSegment(value: '58', label: Text(t.invPaper58)),
                        ButtonSegment(value: '80', label: Text(t.invPaper80)),
                        ButtonSegment(value: 'a4', label: Text(t.invPaperA4)),
                      ],
                      selected: {_size},
                      onSelectionChanged: _canEdit ? (s) => setState(() => _size = s.first) : null,
                    ),
                    const SizedBox(height: Gap.md),
                    Text(t.invLangLabel, style: tt.titleSmall),
                    const SizedBox(height: Gap.xs),
                    SegmentedButton<String>(
                      style: SegmentedButton.styleFrom(
                          minimumSize: const Size(0, 48), tapTargetSize: MaterialTapTargetSize.padded),
                      segments: [
                        ButtonSegment(value: 'bn', label: Text(t.invLangBn)),
                        ButtonSegment(value: 'en', label: Text(t.invLangEn)),
                      ],
                      selected: {_lang},
                      onSelectionChanged: _canEdit ? (s) => setState(() => _lang = s.first) : null,
                    ),
                    const SizedBox(height: Gap.lg),
                    if (_canEdit)
                      FilledButton(
                        key: const ValueKey('inv-set-save'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(t.invSetSave),
                      ),
                  ],
                ),
    );
  }
}
